import Foundation
import Security

/// Cooperating apps must hold this durable lock until their actual native request settles.
@MainActor
final class SharedPlaybackOwnership {
    enum State: String, Codable, Sendable { case active, cleared, completed, uncertain }
    enum Mode { case replacement, ownedMutation, clear(takeover: Bool) }
    struct Record: Codable, Equatable, Sendable {
        let ownerBundleID: String
        let queueRevision: UUID
        let fence: UUID
        let operationID: UUID
        var state: State
    }
    struct Lease: Codable, Equatable, Sendable {
        let ownerBundleID: String
        let queueRevision: UUID
        let fence: UUID
        let operationID: UUID
        let previousRecord: Record?
    }
    enum Cause: String, Codable { case unobservedTransport, callbackOutstanding, legacy }
    struct Reading {
        let stable: Bool
        let queueRevision: UUID?
        let emptyAndStopped: Bool
    }
    private struct Lock: Codable {
        let lease: Lease
        var nativeRequestStarted = false
        var cause: Cause
        var quarantinedAt: Date?
        var launchID: UUID?

        init(lease: Lease, nativeRequestStarted: Bool = false, cause: Cause = .callbackOutstanding,
             quarantinedAt: Date? = nil, launchID: UUID? = nil) {
            self.lease = lease
            self.nativeRequestStarted = nativeRequestStarted
            self.cause = cause
            self.quarantinedAt = quarantinedAt
            self.launchID = launchID
        }
        private enum CodingKeys: CodingKey { case lease, nativeRequestStarted, cause, quarantinedAt, launchID }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lease = try values.decode(Lease.self, forKey: .lease)
            nativeRequestStarted = try values.decodeIfPresent(Bool.self, forKey: .nativeRequestStarted) ?? false
            cause = try values.decodeIfPresent(Cause.self, forKey: .cause) ?? .legacy
            quarantinedAt = try values.decodeIfPresent(Date.self, forKey: .quarantinedAt)
            launchID = try values.decodeIfPresent(UUID.self, forKey: .launchID)
        }
    }
    enum Failure: Error, Equatable {
        case unavailable(OSStatus), corrupt, busy, foreignOwner, staleLease, nativeRequestUnsettled
    }

    private let ownerBundleID: String
    private let primaryOwnerBundleID: String
    private let accessGroup: String?
    private let privateKeychain: Bool
    private let service: String
    private static var launchProbeHandled = false
    private static let processLaunchID = UUID()
    private let launchID: UUID
    private let now: () -> Date

    init(ownerBundleID: String = AppConfiguration.current.bundleIdentifier,
         primaryOwnerBundleID: String = AppConfiguration.current.ownershipPrimaryBundleIdentifier,
         accessGroup: String? = AppConfiguration.current.sharedPlaybackAccessGroup,
         privateKeychain: Bool = AppConfiguration.current.sharedPlaybackPrivate,
         service: String? = nil,
         launchID: UUID? = nil, now: @escaping () -> Date = Date.init) {
        self.ownerBundleID = ownerBundleID
        self.primaryOwnerBundleID = primaryOwnerBundleID
        self.accessGroup = privateKeychain ? nil : accessGroup
        self.privateKeychain = privateKeychain
        self.service = service ?? primaryOwnerBundleID + ".sharedPlayback.v1"
        self.launchID = launchID ?? Self.processLaunchID
        self.now = now
    }

    func snapshot() throws -> Record? { try read(Record.self, account: "owner") }

    /// Only the original app may adopt its existing journal, and only before any shared owner exists.
    @discardableResult
    func bootstrap(revision: UUID, terminal: State) throws -> Record {
        guard !primaryOwnerBundleID.isEmpty, ownerBundleID == primaryOwnerBundleID else { throw Failure.foreignOwner }
        if let existing = try snapshot() { return existing }
        let operationID = UUID()
        let lease = Lease(ownerBundleID: ownerBundleID, queueRevision: revision, fence: UUID(),
                          operationID: operationID, previousRecord: nil)
        try acquire(Lock(lease: lease), account: "mutation", operationID: operationID)
        var retainingUncertainLock = false
        do {
            if let existing = try snapshot() {
                try release(account: "mutation", operationID: operationID)
                return existing
            }
            let record = record(for: lease, state: terminal)
            if terminal == .uncertain {
                retainingUncertainLock = true
                try update(Lock(lease: lease, nativeRequestStarted: true, cause: .legacy, quarantinedAt: now(), launchID: launchID), account: "mutation", operationID: operationID)
            }
            try write(record, account: "owner")
            if !retainingUncertainLock { try release(account: "mutation", operationID: operationID) }
            return record
        } catch {
            // An older app's interrupted request has no callback we can safely reconcile here.
            if !retainingUncertainLock { _ = try? release(account: "mutation", operationID: operationID) }
            throw error
        }
    }

    func begin(operationID: UUID, revision: UUID, mode: Mode, expectedFence: UUID? = nil, userTakeover: Bool = false) throws -> Lease {
        let placeholder = Lease(ownerBundleID: ownerBundleID, queueRevision: revision, fence: UUID(),
                                operationID: operationID, previousRecord: nil)
        var tookOver = false
        do {
            try acquire(Lock(lease: placeholder, launchID: launchID), account: "mutation", operationID: operationID)
        } catch Failure.busy {
            guard userTakeover, let stale = try read(Lock.self, account: "mutation"),
                  stale.nativeRequestStarted || stale.cause == .legacy,
                  stale.cause != .callbackOutstanding || stale.launchID != launchID ||
                    stale.quarantinedAt.map({ now().timeIntervalSince($0) >= 30 }) == true else { throw Failure.busy }
            try release(account: "mutation", operationID: stale.lease.operationID)
            try acquire(Lock(lease: placeholder, launchID: launchID), account: "mutation", operationID: operationID)
            tookOver = true
        }
        do {
            let previous = try snapshot()
            guard previous?.state != .uncertain || userTakeover else { throw Failure.nativeRequestUnsettled }
            let owns = previous?.ownerBundleID == ownerBundleID && previous?.queueRevision == revision &&
                expectedFence != nil && previous?.fence == expectedFence
            let fence: UUID
            let state: State
            switch mode {
            case .replacement:
                fence = UUID()
                state = .active
            case .ownedMutation:
                guard owns, previous?.state == .active else { throw Failure.foreignOwner }
                fence = previous!.fence
                state = .active
            case .clear(let takeover):
                guard owns || takeover else { throw Failure.foreignOwner }
                fence = owns && !tookOver ? previous!.fence : UUID()
                state = .cleared
            }
            let lease = Lease(ownerBundleID: ownerBundleID, queueRevision: revision, fence: fence,
                              operationID: operationID, previousRecord: previous)
            try update(Lock(lease: lease, launchID: launchID), account: "mutation", operationID: operationID)
            try write(record(for: lease, state: state), account: "owner")
            return lease
        } catch {
            // A failed preflight has not touched Music or published a usable lease.
            _ = try? release(account: "mutation", operationID: operationID)
            throw error
        }
    }

    func verify(_ lease: Lease) throws {
        _ = try matchingLock(lease)
        guard let current = try snapshot(), current.ownerBundleID == lease.ownerBundleID,
              current.queueRevision == lease.queueRevision, current.fence == lease.fence,
              current.operationID == lease.operationID else { throw Failure.staleLease }
    }

    /// Call before the first native mutation, even when it has no completion callback.
    func markNativeRequest(_ lease: Lease, callbackOutstanding: Bool = false) throws {
        try verify(lease)
        var lock = try matchingLock(lease)
        lock.nativeRequestStarted = true
        lock.cause = callbackOutstanding ? .callbackOutstanding : .unobservedTransport
        lock.quarantinedAt = lock.quarantinedAt ?? now()
        try update(lock, account: "mutation", operationID: lease.operationID)
    }

    func cancelBeforeMutation(_ lease: Lease) throws {
        try verify(lease)
        guard try !matchingLock(lease).nativeRequestStarted else { throw Failure.nativeRequestUnsettled }
        if let previous = lease.previousRecord { try write(previous, account: "owner") }
        else { try remove(account: "owner") }
        try release(account: "mutation", operationID: lease.operationID)
    }

    /// Finish after all native requests settle; an unenumerable archived tail is kept in the local journal.
    @discardableResult
    func finish(_ lease: Lease, state: State) throws -> Record {
        try verify(lease)
        guard state != .uncertain else { throw Failure.nativeRequestUnsettled }
        let settled = record(for: lease, state: state)
        try write(settled, account: "owner")
        try release(account: "mutation", operationID: lease.operationID)
        return settled
    }

    func quarantine(_ lease: Lease, cause: Cause = .unobservedTransport) throws {
        try verify(lease)
        var lock = try matchingLock(lease)
        lock.nativeRequestStarted = true
        lock.cause = cause
        lock.quarantinedAt = now()
        try update(lock, account: "mutation", operationID: lease.operationID)
        try write(record(for: lease, state: .uncertain), account: "owner")
    }

    @discardableResult
    func settleQuarantine(reading: Reading) throws -> Record? {
        guard reading.stable, let lock = try read(Lock.self, account: "mutation"),
              lock.lease.ownerBundleID == ownerBundleID,
              !(lock.cause == .callbackOutstanding && lock.launchID == launchID),
              let current = try snapshot(), current.state == .uncertain,
              current.fence == lock.lease.fence, current.operationID == lock.lease.operationID else { return nil }
        let state: State
        if reading.emptyAndStopped { state = .cleared }
        else if reading.queueRevision == lock.lease.queueRevision { state = .active }
        else { return nil }
        return try finish(lock.lease, state: state)
    }

    func hasOutstandingRequest() throws -> Bool { try read(Lock.self, account: "mutation") != nil }

    // Nonsecret, isolated capability probe; never touches the Music ownership record.
    func writeProbeNonce(_ nonce: UUID) throws { try write(nonce, account: "probe-nonce") }
    func readProbeNonce() throws -> UUID? { try read(UUID.self, account: "probe-nonce") }
    func acquireProbe(operationID: UUID) throws -> Bool {
        do { try acquire(operationID, account: "probe-lock", operationID: operationID); return true }
        catch Failure.busy { return false }
    }
    @discardableResult
    func releaseProbe(operationID: UUID) throws -> Bool {
        try release(account: "probe-lock", operationID: operationID, missingAllowed: true)
    }

    /// Device-only operator check: a probe launch must not initialize or change native playback.
    static func runLaunchProbeIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--multimusic-shared-keychain-probe") else { return false }
        if launchProbeHandled { return true }
        launchProbeHandled = true
        let action = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let nonce = argument("--probe-nonce").flatMap(UUID.init(uuidString:))
        let operationID = argument("--probe-operation").flatMap(UUID.init(uuidString:))
        var report: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "action": ["write", "read", "acquire", "release"].contains(action) ? action : "invalid",
            "outcome": "invalid", "time": Date().ISO8601Format()]
        if let operationID { report["operationId"] = operationID.uuidString }
        if let nonce { report["nonce"] = nonce.uuidString }
        do {
            let store = SharedPlaybackOwnership()
            switch action {
            case "write":
                if let nonce { try store.writeProbeNonce(nonce); report["outcome"] = "written" }
            case "read":
                report["nonce"] = try store.readProbeNonce()?.uuidString ?? "none"
                report["outcome"] = "read"
            case "acquire":
                if let operationID { report["outcome"] = try store.acquireProbe(operationID: operationID) ? "acquired" : "busy" }
            case "release":
                if let operationID { report["outcome"] = try store.releaseProbe(operationID: operationID) ? "released" : "not_owner" }
            default: break
            }
        } catch {
            report["outcome"] = "error"
            if case Failure.unavailable(let code) = error { report["errorCode"] = code }
        }
        let destination = URL.documentsDirectory.appendingPathComponent("SharedPlaybackProbe.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), data.count <= 4096 {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return true
    }

    private func matchingLock(_ lease: Lease) throws -> Lock {
        guard lease.ownerBundleID == ownerBundleID,
              let lock = try read(Lock.self, account: "mutation"), lock.lease == lease else { throw Failure.staleLease }
        return lock
    }

    private func record(for lease: Lease, state: State) -> Record {
        Record(ownerBundleID: lease.ownerBundleID, queueRevision: lease.queueRevision, fence: lease.fence,
               operationID: lease.operationID, state: state)
    }

    private func query(_ account: String, operationID: UUID? = nil) throws -> [String: Any] {
        guard !ownerBundleID.isEmpty else { throw Failure.unavailable(errSecParam) }
        #if os(iOS)
        guard privateKeychain || !(accessGroup ?? "").isEmpty else { throw Failure.unavailable(errSecMissingEntitlement) }
        #endif
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false]
        if let accessGroup = self.accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        if let operationID { query[kSecAttrGeneric as String] = Data(operationID.uuidString.utf8) }
        return query
    }

    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var query = try query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
        guard let data = result as? Data, data.count <= 16_384,
              let value = try? JSONDecoder().decode(type, from: data) else { throw Failure.corrupt }
        return value
    }

    private func acquire<T: Encodable>(_ value: T, account: String, operationID: UUID) throws {
        var item = try query(account, operationID: operationID)
        item[kSecValueData as String] = try JSONEncoder().encode(value)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw Failure.busy }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }

    private func update<T: Encodable>(_ value: T, account: String, operationID: UUID) throws {
        let attributes = [kSecValueData as String: try JSONEncoder().encode(value)]
        let status = SecItemUpdate(try query(account, operationID: operationID) as CFDictionary, attributes as CFDictionary)
        guard status != errSecItemNotFound else { throw Failure.staleLease }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }

    private func write<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query = try query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure.unavailable(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.unavailable(added) }
    }

    @discardableResult
    private func release(account: String, operationID: UUID, missingAllowed: Bool = false) throws -> Bool {
        let status = SecItemDelete(try query(account, operationID: operationID) as CFDictionary)
        if status == errSecItemNotFound, missingAllowed { return false }
        guard status != errSecItemNotFound else { throw Failure.staleLease }
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
        return true
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(try query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unavailable(status) }
    }
}
