import Combine
import Foundation
import Security

/// Test-build diagnostics are opt-in and never part of a playback operation.
@MainActor
final class TestDiagnostics: ObservableObject {
    static let shared = TestDiagnostics()
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "multimusic.testDiagnostics.enabled") {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: "multimusic.testDiagnostics.enabled")
            status = isEnabled ? "Diagnostics starting…" : "Diagnostics off"
            let enabled = isEnabled
            let revision = DiagnosticsGate.shared.configure(enabled)
            Task { await store.setEnabled(enabled, revision: revision) }
        }
    }
    @Published private(set) var status = "Diagnostics off"
    @Published private(set) var publicIdentity = ""
    @Published private(set) var bufferedEventCount = 0
    private let store = DiagnosticsStore()

    private init() {
        let enabled = isEnabled
        let revision = DiagnosticsGate.shared.configure(enabled)
        Task { await store.setEnabled(enabled, revision: revision) }
    }

    nonisolated static func record(_ event: String, fields: [String: String] = [:]) {
        guard let revision = DiagnosticsGate.shared.recordingRevision() else { return }
        Task { @MainActor in
            guard shared.isEnabled, DiagnosticsGate.shared.isCurrent(revision) else { return }
            shared.accept(event, fields: fields, revision: revision)
        }
    }

    nonisolated static func nativeControlRevision() -> UInt64? {
        DiagnosticsGate.shared.recordingRevision()
    }

    static func nativeControlClockMillis() -> Double {
        shared.store.clockMillis()
    }

    nonisolated static func recordNativeControl(fields: [String: String], revision: UInt64) {
        guard DiagnosticsGate.shared.recordingRevision() == revision else { return }
        Task { @MainActor in
            guard shared.isEnabled, DiagnosticsGate.shared.isCurrent(revision) else { return }
            shared.accept("native.controls", fields: fields, revision: revision)
        }
    }

    private func accept(_ event: String, fields: [String: String], revision: UInt64) {
        Task { await store.record(event, fields: fields, revision: revision) }
    }

    fileprivate func update(_ state: DiagnosticsState) {
        guard isEnabled == state.enabled, DiagnosticsGate.shared.isCurrent(state.revision) else { return }
        status = state.status
        publicIdentity = state.identity
        bufferedEventCount = state.count
    }
}

// The switch cancels transport synchronously, before a queued actor call can run.
private final class DiagnosticsGate: @unchecked Sendable {
    static let shared = DiagnosticsGate()
    private let lock = NSLock()
    private var enabled = false
    private var revision: UInt64 = 0
    private var loop: Task<Void, Never>?

    func configure(_ value: Bool) -> UInt64 {
        lock.lock()
        enabled = value
        revision &+= 1
        let current = revision
        let old = loop
        loop = nil
        lock.unlock()
        old?.cancel()
        return current
    }

    func recordingRevision() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? revision : nil
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == value
    }

    func install(_ task: Task<Void, Never>, revision value: UInt64) {
        lock.lock()
        let accepted = enabled && revision == value
        if accepted { loop = task }
        lock.unlock()
        if !accepted { task.cancel() }
    }
}

private struct DiagnosticsState: Sendable {
    let revision: UInt64
    let enabled: Bool
    let status: String
    let identity: String
    let count: Int
}

private struct DiagnosticsCredentials: Codable, Sendable {
    let identity: String
    let token: String
}

private struct DiagnosticEvent: Codable, Sendable {
    let eventId: String
    let buildId: String
    let runId: String
    let sequence: UInt64
    let elapsedMillis: UInt64
    let event: String
    let fieldsJson: String
}

private struct BufferedDiagnostic: Codable, Sendable {
    let createdAt: Date
    let payload: DiagnosticEvent
    var pendingNativeControl: Bool? = nil
}

private final class DiagnosticsRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor DiagnosticsStore {
    private let upload = AppConfiguration.current.diagnosticsUpload
    private let runId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
    private let start = ContinuousClock.now
    private let buildId: String
    private let directory = URL.documentsDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    private let session: URLSession
    private var enabled = false
    private var loaded = false
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var events: [BufferedDiagnostic] = []
    private var storedBytes = 0
    private var dropped = 0
    private var credentials: DiagnosticsCredentials?
    private var loop: Task<Void, Never>?
    private var status = "Diagnostics off"
    private var lastPublish = Date.distantPast
    private var lastSuccess: Date?
    private var lastUploadFailureCategory: String?
    private var lastUploadFailureCode: Int?
    private var nativeControls: [String] = []
    private var nativePendingCommandIDs: Set<String> = []
    private var nativeControlIDs: [String] = []
    private var nativeControlDropped = 0
    private var nativeControlLoop: Task<Void, Never>?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        buildId = "\(AppConfiguration.current.diagnosticsBuildPrefix)-\(info["CFBundleShortVersionString"] as? String ?? "unknown")-\(info["CFBundleVersion"] as? String ?? "0")"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: DiagnosticsRedirectBlocker(), delegateQueue: nil)
    }

    nonisolated func clockMillis() -> Double {
        let elapsed = start.duration(to: .now).components
        return max(0, Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000)
    }

    func setEnabled(_ value: Bool, revision: UInt64) async {
        guard DiagnosticsGate.shared.isCurrent(revision) else { return }
        let discardPending = !value || loaded && generation != revision
        generation = revision
        enabled = value
        loop?.cancel()
        loop = nil
        nativeControlLoop?.cancel()
        nativeControlLoop = nil
        nativeControls.removeAll()
        nativePendingCommandIDs.removeAll()
        nativeControlIDs.removeAll()
        nativeControlDropped = 0
        if !loaded { load() }
        if discardPending {
            let before = events.count
            events.removeAll { $0.pendingNativeControl == true }
            nativeControls.removeAll()
            nativePendingCommandIDs.removeAll()
            if before != events.count { rewrite() }
        } else { rebuildNativeControls() }
        prune()
        status = value ? (upload == nil ? "Diagnostics stored on this phone" : "Diagnostics waiting to upload") : "Diagnostics off"
        await publish(force: true)
        if value && enabled && generation == revision && DiagnosticsGate.shared.isCurrent(revision) {
            let revision = generation
            if upload != nil {
                let task = Task { await self.flushLoop(revision) }
                loop = task
                DiagnosticsGate.shared.install(task, revision: revision)
            }
            startNativeControls(revision)
        }
    }

    func record(_ event: String, fields: [String: String], revision: UInt64) async {
        guard enabled, generation == revision, DiagnosticsGate.shared.isCurrent(revision) else { return }
        guard Self.allowedEvents.contains(event), fields.count <= 48 else { dropped += 1; return }
        var safe = fields.filter {
            Self.safeField($0.key, $0.value) && Self.permitsField($0.key, event: event)
        }
        if event == "native.controls" {
            guard fields["commandTimingDroppedCount"] == nil || safe["commandTimingDroppedCount"] != nil else { dropped += 1; return }
            safe["commandTimingDroppedCount"] = safe["commandTimingDroppedCount"] ?? "0"
        }
        guard Self.hasRequiredFields(event, fields: safe) else { dropped += 1; return }
        guard let detail = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]),
              detail.count <= 1024, let json = String(data: detail, encoding: .utf8) else { dropped += 1; return }
        if event == "native.controls", let id = safe["commandId"] {
            guard !nativeControlIDs.contains(id), !nativePendingCommandIDs.contains(id) else { return }
            nativeControlIDs.append(id)
            if nativeControlIDs.count > 256 { nativeControlIDs.removeFirst() }
            guard nativeControls.count < 128 else { nativeControlDropped += 1; dropped += 1; return }
            await persistEvent(event, json: json, nativeCommandID: id)
            startNativeControls(revision)
            return
        }
        await persistEvent(event, json: json)
    }

    private func startNativeControls(_ revision: UInt64) {
        guard enabled, generation == revision, DiagnosticsGate.shared.isCurrent(revision),
              nativeControlLoop == nil, !nativeControls.isEmpty else { return }
        nativeControlLoop = Task { await self.drainNativeControls(revision) }
    }

    private func drainNativeControls(_ revision: UInt64) async {
        defer { if generation == revision { nativeControlLoop = nil } }
        while enabled && generation == revision && DiagnosticsGate.shared.isCurrent(revision) && !Task.isCancelled {
            guard !nativeControls.isEmpty else { return }
            let id = nativeControls.removeFirst()
            guard let index = events.firstIndex(where: { $0.payload.eventId == id }),
                  let data = events[index].payload.fieldsJson.data(using: .utf8),
                  var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { continue }
            if let command = fields["commandId"] { nativePendingCommandIDs.remove(command) }
            fields["commandTimingDroppedCount"] = String(min(1_000_000_000,
                (Int(fields["commandTimingDroppedCount"] ?? "0") ?? 0) + nativeControlDropped))
            nativeControlDropped = 0
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               data.count <= 1024, let json = String(data: data, encoding: .utf8) {
                let old = events[index]
                let payload = old.payload
                events[index] = BufferedDiagnostic(createdAt: old.createdAt, payload: DiagnosticEvent(
                    eventId: payload.eventId, buildId: payload.buildId, runId: payload.runId,
                    sequence: payload.sequence, elapsedMillis: payload.elapsedMillis, event: payload.event, fieldsJson: json))
                rewrite()
                await publish()
            } else { dropped += 1 }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func persistEvent(_ event: String, json: String, nativeCommandID: String? = nil) async {
        sequence &+= 1
        let elapsed = start.duration(to: .now)
        let millis = max(0, elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        var item = BufferedDiagnostic(createdAt: Date(), payload: DiagnosticEvent(
            eventId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            buildId: buildId, runId: runId, sequence: sequence, elapsedMillis: UInt64(millis), event: event, fieldsJson: json))
        if nativeCommandID != nil { item.pendingNativeControl = true }
        guard let line = try? JSONEncoder().encode(item), line.count <= 2048 else { dropped += 1; return }
        events.append(item)
        storedBytes += line.count + 1
        append(line)
        if let nativeCommandID {
            nativeControls.append(item.payload.eventId)
            nativePendingCommandIDs.insert(nativeCommandID)
        }
        prune()
        await publish()
    }

    private func load() {
        loaded = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var excludedDirectory = directory; try? excludedDirectory.setResourceValues(excluded)
        if upload != nil { credentials = Self.loadCredentials() }
        let url = directory.appendingPathComponent("events.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 2_097_152,
              let data = try? Data(contentsOf: url) else { rewrite(); return }
        let decoded = data.split(separator: 10).compactMap { try? JSONDecoder().decode(BufferedDiagnostic.self, from: Data($0)) }
        events = decoded.filter { item in
            guard let data = item.payload.fieldsJson.data(using: .utf8), data.count <= 1024,
                  let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return false }
            return Self.allowedEvents.contains(item.payload.event) && Self.hasRequiredFields(item.payload.event, fields: fields)
                && fields.allSatisfy {
                    Self.safeField($0.key, $0.value) && Self.permitsField($0.key, event: item.payload.event)
                }
                && item.payload.eventId.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
                && item.payload.runId.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil
                && item.payload.buildId.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$", options: .regularExpression) != nil
                && item.payload.elapsedMillis <= 604_800_000 && item.payload.sequence <= 1_000_000_000
                && (item.pendingNativeControl != true || item.payload.event == "native.controls" && fields["commandTimingDroppedCount"] != nil)
        }
        rebuildNativeControls()
        nativeControlIDs = events.filter { $0.payload.event == "native.controls" }.suffix(256).compactMap(Self.nativeCommandID)
        dropped += decoded.count - events.count
        storedBytes = data.count
        if decoded.count != events.count { rewrite() }
    }

    private static func nativeCommandID(_ item: BufferedDiagnostic) -> String? {
        let fields = try? JSONSerialization.jsonObject(with: Data(item.payload.fieldsJson.utf8)) as? [String: String]
        return fields?["commandId"]
    }

    private func rebuildNativeControls() {
        var seen = Set(events.filter { $0.payload.event == "native.controls" && $0.pendingNativeControl != true }.compactMap(Self.nativeCommandID))
        var pending: [String] = []
        var commands: Set<String> = []
        events.removeAll { item in
            guard item.pendingNativeControl == true else { return false }
            guard pending.count < 128, let id = Self.nativeCommandID(item), seen.insert(id).inserted else { return true }
            pending.append(item.payload.eventId); commands.insert(id)
            return false
        }
        nativeControls = pending
        nativePendingCommandIDs = commands
    }

    private func prune() {
        let before = events.count
        let cutoff = Date().addingTimeInterval(-432_000)
        events.removeAll { $0.createdAt < cutoff }
        if events.count != before {
            storedBytes = events.reduce(0) { $0 + ((try? JSONEncoder().encode($1).count) ?? 0) + 1 }
        }
        while events.count > 5000 || storedBytes > 2_097_152 {
            guard !events.isEmpty else { break }
            let first = events.removeFirst()
            storedBytes -= ((try? JSONEncoder().encode(first).count) ?? 0) + 1
            dropped += 1
        }
        if events.count != before { rebuildNativeControls(); rewrite() }
    }

    private func append(_ line: Data) {
        let url = directory.appendingPathComponent("events.jsonl")
        do {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([10]))
        } catch { status = "Diagnostics local storage unavailable" }
    }

    private func rewrite() {
        let data = events.reduce(into: Data()) { output, event in
            if let line = try? JSONEncoder().encode(event) { output.append(line); output.append(10) }
        }
        storedBytes = data.count
        try? data.write(to: directory.appendingPathComponent("events.jsonl"), options: [.atomic])
    }

    private func flushLoop(_ revision: UInt64) async {
        guard let upload else { return }
        var retry: UInt64 = 2
        while enabled && generation == revision && !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(retry))
                try Task.checkCancellation()
                guard enabled && generation == revision else { return }
                if credentials == nil {
                    let data = try await request(path: "/v1/identity", body: Data(), token: nil)
                    let issued = try JSONDecoder().decode(DiagnosticsCredentials.self, from: data)
                    guard issued.identity.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                          !issued.token.isEmpty, issued.token.utf8.count < 16_384 else { throw URLError(.cannotParseResponse) }
                    try Task.checkCancellation()
                    guard enabled && generation == revision else { return }
                    try Self.saveCredentials(issued)
                    credentials = issued
                    lastUploadFailureCategory = nil
                    lastUploadFailureCode = nil
                    await publish(force: true)
                }
                guard enabled && generation == revision, let credentials else { return }
                prune()
                if events.isEmpty { status = "Diagnostics ready"; retry = 2; await publish(); continue }
                var batch: [DiagnosticEvent] = []
                for item in events.lazy.filter({ $0.pendingNativeControl != true }).prefix(32) {
                    let candidate = batch + [item.payload]
                    guard let encoded = try? JSONEncoder().encode([candidate]), encoded.count <= 32_768 else { break }
                    batch = candidate
                }
                guard !batch.isEmpty else { retry = 2; await publish(); continue }
                let body = try JSONEncoder().encode([batch])
                _ = try await request(path: "/v1/database/\(upload.database)/call/operationallog_append_multimusic_test_events", body: body, token: credentials.token)
                try Task.checkCancellation()
                guard enabled && generation == revision else { return }
                let ids = Set(batch.map(\.eventId))
                events.removeAll { ids.contains($0.payload.eventId) }
                rewrite()
                lastSuccess = Date()
                lastUploadFailureCategory = nil
                lastUploadFailureCode = nil
                status = "Diagnostics uploaded"
                retry = 2
                await publish(force: true)
            } catch {
                guard enabled && generation == revision && !Task.isCancelled else { return }
                if error is CancellationError { return }
                let nativeError = error as NSError
                lastUploadFailureCategory = nativeError.domain == NSURLErrorDomain ? "transport"
                    : nativeError.domain == NSCocoaErrorDomain ? "local" : "unknown"
                lastUploadFailureCode = nativeError.code
                if case DiagnosticsHTTPError.rejected(let code, let category) = error {
                    lastUploadFailureCategory = "http"
                    lastUploadFailureCode = code
                    status = category == "enrollment" ? "Diagnostics waiting for reporter enrollment"
                        : category == "capacity" ? "Diagnostics waiting for upload capacity"
                        : "Diagnostics upload rejected (\(code))"
                } else if case DiagnosticsHTTPError.keychain(let code) = error {
                    lastUploadFailureCategory = "keychain"
                    lastUploadFailureCode = Int(code)
                    status = "Diagnostics secure storage unavailable"
                } else { status = "Diagnostics offline; stored on this phone" }
                retry = min(60, retry * 2)
                await publish(force: true)
            }
        }
    }

    private func request(path: String, body: Data, token: String?) async throws -> Data {
        guard let upload else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: upload.origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 32_768 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let category = response.statusCode == 401 || response.statusCode == 403
                || body.contains("authorized domain reporter") || body.contains("authenticated reporter") ? "enrollment"
                : body.contains("admission limit") ? "capacity" : "rejected"
            throw DiagnosticsHTTPError.rejected(response.statusCode, category)
        }
        return data
    }

    private func publish(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastPublish) >= 1 else { return }
        lastPublish = Date()
        let state = DiagnosticsState(revision: generation, enabled: enabled, status: status, identity: credentials?.identity ?? "", count: events.count)
        var metadata: [String: Any] = ["enabled": enabled, "buildId": buildId, "runId": runId,
            "publicIdentity": state.identity, "bufferedEventCount": events.count, "droppedEventCount": dropped,
            "status": status, "lastSuccess": lastSuccess?.ISO8601Format() ?? "none"]
        if let lastUploadFailureCategory, let lastUploadFailureCode {
            metadata["lastUploadFailureCategory"] = lastUploadFailureCategory
            metadata["lastUploadFailureCode"] = lastUploadFailureCode
        }
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: [.atomic])
        }
        await TestDiagnostics.shared.update(state)
    }

    private static func loadCredentials() -> DiagnosticsCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfiguration.current.diagnosticsKeychainService, kSecAttrAccount as String: "maincloud",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(DiagnosticsCredentials.self, from: data)
    }

    private static func saveCredentials(_ credentials: DiagnosticsCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConfiguration.current.diagnosticsKeychainService, kSecAttrAccount as String: "maincloud"]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw DiagnosticsHTTPError.keychain(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw DiagnosticsHTTPError.keychain(added) }
    }

    private static let allowedEvents: Set<String> = ["native.queueProbe", "web.queueProbe", "native.match", "native.lifecycle", "native.command", "native.controls", "native.selection", "native.stage", "native.state", "native.queue",
        "web.aggregate", "web.snapshot.queue", "web.snapshot.completed", "web.snapshot.failed", "web.snapshot.painted", "web.navigation.start", "web.navigation.finish",
        "web.navigation.fail", "web.navigation.cancel", "web.navigation.policy", "web.navigation.terminated", "web.bridge.activation", "web.bridge.receive"]
    private static let requiredFields: [String: Set<String>] = [
        "native.queueProbe": ["qpTrigger", "qpIndex", "qpClass"],
        "web.queueProbe": ["qpKind", "qpCapture"],
        "native.match": ["durationlessGuard", "durationGroupCounts", "distinctISRCCount"],
        "native.lifecycle": ["phase", "active", "preparing", "queueCount"],
        "native.command": ["command", "phase"], "native.selection": ["phase", "trackCount"],
        "native.controls": ["command", "commandId", "commandStartedMs", "commandFrameOutcome"],
        "native.stage": ["stage", "phase", "elapsedMs", "outcome"],
        "native.state": ["state", "index", "positionMs", "queueCount", "itemPresent", "synchronized", "preparing", "active", "authorized"],
        "native.queue": ["phase", "queueCount", "skippedCount"],
        "web.snapshot.queue": ["delivery", "pending"], "web.snapshot.completed": ["delivery", "pending", "elapsedMs"],
        "web.snapshot.failed": ["delivery", "pending", "elapsedMs", "domain", "code"], "web.snapshot.painted": ["delivery"],
        "web.navigation.start": ["navigation"], "web.navigation.finish": ["navigation", "musicOrigin"],
        "web.navigation.fail": ["navigation", "code"], "web.navigation.cancel": ["navigation", "code"],
        "web.navigation.policy": ["type", "mainFrame", "musicOrigin"], "web.bridge.activation": ["ready"],
        "web.bridge.receive": ["sequence", "type"]]
    private static func hasRequiredFields(_ event: String, fields: [String: String]) -> Bool {
        guard (requiredFields[event] ?? []).isSubset(of: Set(fields.keys)) else { return false }
        guard event == "native.controls" || event == "web.aggregate" && !timingSampleFields.isDisjoint(with: fields.keys) else { return true }
        guard fields["commandId"] != nil, fields["commandStartedMs"] != nil,
              let outcome = fields["commandFrameOutcome"] else { return false }
        guard (outcome == "1") == (fields["completedFrameMs"] != nil) else { return false }
        if event == "native.controls" {
            guard ["play", "pause", "next", "previous", "seek"].contains(fields["command"] ?? "") else { return false }
            if ["2", "3"].contains(outcome), fields["nativeConfirmedMs"] != nil { return false }
            if outcome == "1" {
                guard let confirmed = fields["nativeConfirmedMs"].flatMap(Double.init),
                      let frame = fields["completedFrameMs"].flatMap(Double.init), frame >= confirmed else { return false }
            }
        }
        return true
    }
    private static func permitsField(_ key: String, event: String) -> Bool {
        if event == "native.queueProbe" { return queueProbeNativeFields.contains(key) }
        if event == "web.queueProbe" { return queueProbeWebFields.contains(key) || key == "documentId" }
        if key.hasPrefix("qp") { return false }
        if event == "native.controls" { return nativeControlFields.contains(key) }
        return key != "nativeConfirmedMs" && (!["metadataOnlyCount", "cleanFallbackCount"].contains(key) || event == "native.queue")
            && (!performanceFields.contains(key) || event == "web.aggregate")
            && (!ownershipFields.contains(key) || event == "native.state")
    }
    private static let queueProbeNumbers: Set<String> = ["qpIndex", "qpRaw", "qpOcc", "qpCursor", "qpOffset", "qpSubmitted", "qpPending", "qpCV", "qpIV", "qpMPS", "qpMPR", "qpEntries", "qpQSig", "qpSSig", "qpDelta", "qpPos", "qpState", "qpCapture", "qpRows", "qpSelected", "qpTime", "qpRendered", "qpRow"]
    private static let queueProbeHashes: Set<String> = ["qpStore", "qpPredict", "qpRev", "qpFence", "qpOwner", "qpCmd", "qpGen", "qpEntry", "qpFooter", "qpHash", "qpSelectedID", "qpV", "qpList", "qpRowID"]
    private static let queueProbeNativeFields: Set<String> = ["qpIndex", "qpRaw", "qpOcc", "qpCursor", "qpOffset", "qpSubmitted", "qpPending", "qpCV", "qpIV", "qpMPS", "qpMPR", "qpEntries", "qpQSig", "qpSSig", "qpDelta", "qpPos", "qpState", "qpStore", "qpPredict", "qpRev", "qpFence", "qpOwner", "qpCmd", "qpGen", "qpEntry", "qpFooter", "qpTrigger", "qpClass", "qpOwnState", "qpMKS", "qpMKR", "qpAction"]
    private static let queueProbeWebFields: Set<String> = ["qpCapture", "qpRows", "qpSelected", "qpTime", "qpRendered", "qpRow", "qpHash", "qpSelectedID", "qpV", "qpList", "qpRowID", "qpKind", "qpPaused"]
    private static let numberFields: Set<String> = ["queueCount", "trackCount", "elapsedMs", "index", "positionMs", "skippedCount", "thirdPartyEditCount", "miniTapUnmapped", "delivery", "pending", "code", "navigation", "musicOrigin", "mainFrame", "ready", "sequence", "type", "renders", "renderTotalMs", "renderMaxMs", "rowsScanned", "observerCallbacks", "mutations", "framesQueued", "renderQueueMaxMs", "intents", "gestureToSendMaxMs", "viewportWidth", "viewportHeight", "devicePixelRatio", "visualWidth", "visualHeight", "visualScale", "hitX", "hitY"]
    private static let booleanFields: Set<String> = ["active", "preparing", "itemPresent", "synchronized", "authorized", "sourceIsExplicit", "seekResolved", "sliderVis"]
    private static let skipReasonValues: Set<String> = ["invalidSource", "noResults", "noCompatibleMetadata", "contentConflict",
        "insufficientDurationlessAgreement", "ambiguousRecording", "unavailableInStorefront", "thirdPartyEdit"]
    private static let performanceCounts: Set<String> = ["renderAtLeast4Count", "adapterOver50Count", "progressRenders", "progressRowsScanned", "commandTimingDroppedCount"]
    private static let timingClocks: Set<String> = ["commandStartedMs", "feedbackFrameMs", "completedFrameMs"]
    private static let timingSampleFields = timingClocks.union(["commandFrameOutcome"])
    private static let nativeControlFields = timingSampleFields.union(["command", "commandId", "nativeConfirmedMs", "commandTimingDroppedCount"])
    private static let performanceFields = performanceCounts.union(["adapterTaskMaxMs"]).union(timingSampleFields)
    private static let ownershipFields: Set<String> = ["rawNativeIndex", "catalogIDPresent", "savedCursor", "nativeOffset", "catalogMatchCount", "matchAtNativeIndex", "ownershipReason", "rawPlaybackState"]
    private static let ownershipReasons: Set<String> = ["no_checkpoint", "inactive_checkpoint", "missing_item", "missing_catalog_id", "invalid_native_index", "id_mismatch", "mapped"]
    private static let enumFields: Set<String> = ["phase", "command", "reason", "stage", "outcome", "state", "domain", "type"]
    private static let values: Set<String> = ["resume", "suspend", "play", "pause", "next", "previous", "seek", "clear", "restore", "received", "rejected", "completed", "cancelled", "error", "inactive", "unavailable", "unmapped", "invalid_seek", "unauthorized", "invalid", "no_matches", "authorization", "subscription", "region", "catalog_search", "retry", "save_queue", "prepare_queue", "play_queue", "begin", "end", "success", "playing", "paused", "stopped", "replacement_requested", "append_requested", "append_returned", "clear_requested", "restore_requested", "recovery_started", "recovery_suppressed", "starved", "invalidSelection", "unmappedQueue", "awaitingNext", "nativeFailure", "nativeNoChange", "timedOut", "foreignPlayback", "noMatch", "cleared", "WKErrorDomain", "NSURLErrorDomain", "MPErrorDomain", "MPMusicPlayerControllerErrorDomain", "NSOSStatusErrorDomain", "other", "selection", "command", "status"]
    private static func safeField(_ key: String, _ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        if queueProbeNumbers.contains(key) {
            return Int64(value).map { (-1_000_000_000_000...1_000_000_000_000).contains($0) && String($0) == value } ?? false
        }
        if queueProbeHashes.contains(key) { return value.range(of: "^(?:none|[a-f0-9]{8}|[a-f0-9]{12})$", options: .regularExpression) != nil }
        if key == "qpTrigger" { return ["poll", "itemNotification", "stateNotification", "queueSignal", "modeSignal", "replacement_requested", "append_requested", "append_returned", "clear_requested", "restore_requested", "recovery_started", "recovery_suppressed", "completed", "starved"].contains(value) }
        if key == "qpClass" { return ["initial", "unchanged", "sequential", "jump", "rebase", "foreign"].contains(value) }
        if key == "qpOwnState" { return ["none", "active", "cleared", "completed", "uncertain"].contains(value) }
        if key == "qpMKS" { return ["nil", "off", "songs"].contains(value) }
        if key == "qpMKR" { return ["nil", "none", "one", "all"].contains(value) }
        if key == "qpAction" { return ["none", "Reset", "Retry", "Connect", "Restore", "Replay", "Details"].contains(value) }
        if key == "qpKind" { return ["poll", "enabled", "capture", "plus1", "plus10", "row", "readError", "headerPlay", "headerShuffle", "queueTap"].contains(value) }
        if key == "qpPaused" { return ["true", "false", "none"].contains(value) }
        if ["hitStack0", "hitStack1", "hitStack2", "hitStack3", "hitStack4"].contains(key) {
            return value.utf8.count <= 64 && value.range(of: "^(?:none|[a-z][a-z0-9-]*(?:#[A-Za-z0-9_-]+)?(?:\\.[A-Za-z0-9_-]+)*(?:\\[[A-Za-z0-9_-]+\\])?@-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+\\^[a-z][a-z0-9-]*)\\z", options: .regularExpression) != nil
        }
        if key == "aggregateRoot" { return ["ytmusic-player-bar", "ytmusic-player-page", "ytmusic-player", "ytmusic-miniplayer", "none"].contains(value) }
        if key == "seekMissReason" { return ["row", "volume", "transportOther", "notVisible", "noRoot", "narrow", "outside", "navigation", "none"].contains(value) }
        if key == "rawPlaybackState" {
            return Int(value).map { (0...5).contains($0) && String($0) == value } ?? false
        }
        if key == "rawNativeIndex" {
            return Int(value).map { (-1...1000).contains($0) && String($0) == value } ?? false
        }
        if key == "savedCursor" || key == "nativeOffset" {
            return Int(value).map { (-1...60).contains($0) && String($0) == value } ?? false
        }
        if key == "catalogMatchCount" {
            return Int(value).map { (0...60).contains($0) && String($0) == value } ?? false
        }
        if key == "catalogIDPresent" || key == "matchAtNativeIndex" { return value == "true" || value == "false" }
        if key == "skipReasons" {
            let reasons = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            return !reasons.isEmpty && reasons.allSatisfy { skipReasonValues.contains($0) }
        }
        if key == "durationlessGuard" { return ["invalidDuration", "tiedDurationGroups", "recordingAgreement"].contains(value) }
        if key == "durationGroupCounts" {
            return value.range(of: "^(0|[1-9][0-9]{0,2})(,(0|[1-9][0-9]{0,2})){0,15}\\z", options: .regularExpression) != nil
        }
        if key == "distinctISRCCount" {
            return Int(value).map { (0...200).contains($0) && String($0) == value } ?? false
        }
        if key == "tiedSpanSeconds" {
            return Double(value).map { $0.isFinite && $0 >= 0 } == true &&
                value.range(of: "^(0|[1-9][0-9]*)(\\.[0-9]{1,3})?\\z", options: .regularExpression) != nil
        }
        if key == "composedPathTags" {
            return value.range(of: "^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*){0,7}\\z", options: .regularExpression) != nil
        }
        if key == "ownershipReason" { return ownershipReasons.contains(value) }
        if key == "collapsePath" { return value == "arrow" }
        if key == "expandPath" { return ["title", "cover", "keyboard"].contains(value) }
        if key == "metadataOnlyCount" || key == "cleanFallbackCount" {
            return Int(value).map { (0...60).contains($0) && String($0) == value } ?? false
        }
        if key == "code" { return Int32(value).map { String($0) == value } ?? false }
        if key == "commandFrameOutcome" {
            return Int(value).map { (1...6).contains($0) && String($0) == value } ?? false
        }
        if performanceCounts.contains(key) {
            return Int(value).map { (0...1_000_000_000).contains($0) && String($0) == value } ?? false
        }
        if key == "adapterTaskMaxMs" || key == "nativeConfirmedMs" || timingClocks.contains(key) {
            let maximum: Double = key == "feedbackFrameMs" || key == "completedFrameMs" || key == "nativeConfirmedMs" ? 60_000 : 604_800_000
            return Double(value).map {
                $0.isFinite && (0...maximum).contains($0)
                    && value.range(of: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?$", options: .regularExpression) != nil
            } ?? false
        }
        if ["commandId", "selectionId", "documentId", "snapshotId"].contains(key) {
            return value.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
        }
        if booleanFields.contains(key) { return value == "true" || value == "false" }
        let rectangle = ["bar", "play", "next", "previous", "slider", "seekRect"].contains { prefix in
            ["X", "Y", "Width", "Height"].contains { key == prefix + $0 }
        }
        if numberFields.contains(key) || rectangle {
            if let number = Double(value), number.isFinite, abs(number) < 1_000_000_000_000 { return true }
        }
        return enumFields.contains(key) && values.contains(value)
    }
}

private enum DiagnosticsHTTPError: Error {
    case rejected(Int, String)
    case keychain(OSStatus)
}
