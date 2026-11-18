import Foundation
import Security

@main
struct SharedPlaybackOwnershipChecks {
    @MainActor
    static func main() {
        do { try checks() }
        catch {
            FileHandle.standardError.write(Data("Shared ownership checks failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func checks() throws {
        let originalID = "org.multimusic.app"
        let companionID = "org.multimusic.app.Spotify"
        if CommandLine.arguments.count == 4, ["--contend", "--orphan"].contains(CommandLine.arguments[1]) {
            let guardStore = SharedPlaybackOwnership(ownerBundleID: originalID, accessGroup: nil,
                                                     service: CommandLine.arguments[2])
            do {
                let lease = try guardStore.begin(operationID: UUID(uuidString: CommandLine.arguments[3])!,
                                                  revision: UUID(), mode: .replacement)
                if CommandLine.arguments[1] == "--orphan" {
                    try guardStore.markNativeRequest(lease)
                    FileHandle.standardOutput.write(Data("retained\n".utf8))
                    return
                }
                FileHandle.standardOutput.write(Data("acquired\n".utf8))
                _ = readLine()
                try guardStore.cancelBeforeMutation(lease)
            } catch SharedPlaybackOwnership.Failure.busy {
                FileHandle.standardOutput.write(Data("blocked\n".utf8))
            }
            return
        }
        try recoveryChecks()
        try recipientIdentityChecks()
        let service = "org.multimusic.app.checks.\(UUID().uuidString)"
        defer { removeFixture(service) }
        let original = SharedPlaybackOwnership(ownerBundleID: originalID, accessGroup: nil, service: service)
        let companion = SharedPlaybackOwnership(ownerBundleID: companionID, accessGroup: nil, service: service)
        let firstRevision = UUID()
        let adopted = try original.bootstrap(revision: firstRevision, terminal: .active)
        assert(adopted.ownerBundleID == originalID && adopted.queueRevision == firstRevision)
        try check(original.bootstrap(revision: UUID(), terminal: .cleared) == adopted)
        expect(.foreignOwner) { _ = try companion.bootstrap(revision: UUID(), terminal: .active) }
        expect(.foreignOwner) {
            _ = try companion.begin(operationID: UUID(), revision: firstRevision, mode: .ownedMutation, expectedFence: adopted.fence)
        }
        try check(!original.hasOutstandingRequest())
        // Explicit replacement can claim a settled foreign queue, but looking it up cannot.
        try check(companion.snapshot() == adopted)
        let replacement = try companion.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        try check(original.hasOutstandingRequest())
        expect(.busy) { _ = try original.begin(operationID: UUID(), revision: firstRevision, mode: .replacement) }
        try companion.cancelBeforeMutation(replacement)
        try check(original.snapshot() == adopted)
        try check(!original.hasOutstandingRequest())
        // Clear is durable before native dispatch; a stale caller cannot release the new holder.
        let clear = try original.begin(operationID: UUID(), revision: firstRevision,
                                       mode: .clear(takeover: false), expectedFence: adopted.fence)
        try check(companion.snapshot()?.state == .cleared)
        try original.markNativeRequest(clear)
        expect(.nativeRequestUnsettled) { try original.cancelBeforeMutation(clear) }
        let cleared = try original.finish(clear, state: .cleared)
        let newer = try companion.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        expect(.staleLease) { _ = try original.finish(clear, state: .active) }
        try check(companion.hasOutstandingRequest())
        try companion.cancelBeforeMutation(newer)
        try check(original.snapshot() == cleared)
        expect(.foreignOwner) {
            _ = try original.begin(operationID: UUID(), revision: firstRevision, mode: .ownedMutation, expectedFence: cleared.fence)
        }
        let foreignLease = try companion.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        let foreignRecord = try companion.finish(foreignLease, state: .active)
        try check(original.bootstrap(revision: firstRevision, terminal: .uncertain) == foreignRecord)
        try check(!original.hasOutstandingRequest())
        // A cold instance has no expiry/steal path for an interrupted real native request.
        let uncertain = try companion.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        try companion.markNativeRequest(uncertain)
        try companion.quarantine(uncertain)
        let restarted = SharedPlaybackOwnership(ownerBundleID: companionID, accessGroup: nil, service: service)
        try check(restarted.snapshot()?.state == .uncertain)
        expect(.busy) { _ = try restarted.begin(operationID: UUID(), revision: UUID(), mode: .replacement) }
        expect(.nativeRequestUnsettled) { try restarted.cancelBeforeMutation(uncertain) }
        // A callback that still owns the exact request may eventually settle it.
        _ = try restarted.finish(uncertain, state: .active)
        try check(!original.hasOutstandingRequest())
        // Actual conditional Keychain deletion must not remove a different operation's lock.
        let nonce = UUID(), probeA = UUID(), probeB = UUID()
        try original.writeProbeNonce(nonce)
        try check(companion.readProbeNonce() == nonce)
        try check(original.acquireProbe(operationID: probeA))
        try check(!companion.acquireProbe(operationID: probeB))
        try check(!companion.releaseProbe(operationID: probeB))
        try check(!companion.acquireProbe(operationID: probeB))
        try check(original.releaseProbe(operationID: probeA))
        try check(companion.acquireProbe(operationID: probeB))
        try check(!original.releaseProbe(operationID: probeA))
        try check(companion.releaseProbe(operationID: probeB))

        let migrationService = service + ".migration"
        defer { removeFixture(migrationService) }
        let migration = SharedPlaybackOwnership(ownerBundleID: originalID, accessGroup: nil, service: migrationService)
        let migratedBarrier = try migration.bootstrap(revision: UUID(), terminal: .uncertain)
        assert(migratedBarrier.state == .uncertain)
        try check(migration.hasOutstandingRequest())
        try check(migration.bootstrap(revision: UUID(), terminal: .active) == migratedBarrier)
        let migrationCompanion = SharedPlaybackOwnership(ownerBundleID: companionID, accessGroup: nil, service: migrationService)
        expect(.busy) { _ = try migrationCompanion.begin(operationID: UUID(), revision: UUID(), mode: .replacement) }

        #if os(macOS)
        // Independent processes race the production SecItemAdd boundary; the winner stays held.
        let raceService = service + ".race"
        defer { removeFixture(raceService) }
        var contenders: [(Process, Pipe, Pipe)] = []
        for _ in 0..<12 {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            process.arguments = ["--contend", raceService, UUID().uuidString]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            contenders.append((process, input, output))
        }
        var winners = 0, blocked = 0
        for (_, _, output) in contenders {
            var data = Data()
            while data.count < 64, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                data.append(byte)
                if byte.last == 10 { break }
            }
            let result = String(decoding: data, as: UTF8.self)
            if result == "acquired\n" { winners += 1 }
            else if result == "blocked\n" { blocked += 1 }
            else { assertionFailure("Unexpected contender output: \(result)") }
        }
        assert(winners == 1 && blocked == 11)
        for (process, input, _) in contenders {
            if process.isRunning { try? input.fileHandleForWriting.write(contentsOf: Data("release\n".utf8)) }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            assert(process.terminationStatus == 0)
        }
        let afterRace = SharedPlaybackOwnership(ownerBundleID: originalID, accessGroup: nil, service: raceService)
        try check(!afterRace.hasOutstandingRequest())
        let orphan = Process(), orphanOutput = Pipe()
        orphan.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        orphan.arguments = ["--orphan", raceService, UUID().uuidString]
        orphan.standardOutput = orphanOutput
        try orphan.run()
        orphan.waitUntilExit()
        assert(orphan.terminationStatus == 0)
        let orphanReceipt = try orphanOutput.fileHandleForReading.readToEnd() ?? Data()
        assert(String(decoding: orphanReceipt, as: UTF8.self) == "retained\n")
        try check(afterRace.hasOutstandingRequest())
        expect(.busy) { _ = try afterRace.begin(operationID: UUID(), revision: UUID(), mode: .replacement) }
        expect(.busy) { _ = try afterRace.begin(operationID: UUID(), revision: UUID(), mode: .clear(takeover: true)) }
        print("Shared ownership checks passed: cross-process exclusion (1/12 acquired), process-exit retention, stale-release fencing, durable Clear, rollback, restart quarantine, and shared nonsecret probe.")
        #else
        print("Shared ownership checks passed; cross-process race requires macOS fixture or the two installed phone apps.")
        #endif
    }

    @MainActor
    private static func recoveryChecks() throws {
        let ownerID = "org.multimusic.app", launch = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        for scenario in ["sameLaunch", "newLaunch", "legacy", "29seconds", "30seconds", "transport"] {
            let service = "org.multimusic.app.checks.\(UUID().uuidString)"
            defer { removeFixture(service) }
            let original = SharedPlaybackOwnership(ownerBundleID: ownerID, accessGroup: nil, service: service,
                                                   launchID: launch, now: { now })
            let lease = try original.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
            try original.markNativeRequest(lease, callbackOutstanding: true)
            try original.quarantine(lease, cause: scenario == "transport" ? .unobservedTransport : .callbackOutstanding)
            if scenario == "legacy" {
                let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                             kSecAttrAccount as String: "mutation"] as [String: Any]
                var item: CFTypeRef?
                var read = query
                read[kSecReturnData as String] = true
                assert(SecItemCopyMatching(read as CFDictionary, &item) == errSecSuccess)
                var legacy = try JSONSerialization.jsonObject(with: item as! Data) as! [String: Any]
                for key in ["cause", "quarantinedAt", "launchID"] { legacy.removeValue(forKey: key) }
                let data = try JSONSerialization.data(withJSONObject: legacy)
                assert(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess)
            }
            let elapsed: Double = scenario == "30seconds" ? 30 : scenario == "29seconds" ? 29 : 0
            let recovered = SharedPlaybackOwnership(ownerBundleID: ownerID, accessGroup: nil, service: service,
                launchID: scenario == "newLaunch" ? UUID() : launch, now: { now.addingTimeInterval(elapsed) })
            // Every automatic path stays blocked, including stale/legacy requests eligible for an explicit takeover.
            for mode in [SharedPlaybackOwnership.Mode.replacement, .ownedMutation, .clear(takeover: true)] {
                expect(.busy) {
                    _ = try recovered.begin(operationID: UUID(), revision: lease.queueRevision, mode: mode, expectedFence: lease.fence)
                }
            }
            if ["sameLaunch", "29seconds"].contains(scenario) {
                expect(.busy) {
                    _ = try recovered.begin(operationID: UUID(), revision: UUID(), mode: .replacement, userTakeover: true)
                }
                try check(recovered.hasOutstandingRequest())
            } else {
                let replacement = try recovered.begin(operationID: UUID(), revision: UUID(), mode: .replacement, userTakeover: true)
                assert(replacement.fence != lease.fence)
                expect(.staleLease) { _ = try original.finish(lease, state: .active) }
                _ = try recovered.finish(replacement, state: .active)
                try check(!recovered.hasOutstandingRequest())
            }
        }
        for empty in [false, true] {
            let service = "org.multimusic.app.checks.\(UUID().uuidString)"
            defer { removeFixture(service) }
            let original = SharedPlaybackOwnership(ownerBundleID: ownerID, accessGroup: nil, service: service, launchID: launch)
            let foreign = SharedPlaybackOwnership(ownerBundleID: ownerID + ".Spotify", accessGroup: nil, service: service)
            let lease = try original.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
            try original.quarantine(lease, cause: .callbackOutstanding)
            let reading = SharedPlaybackOwnership.Reading(stable: true, queueRevision: lease.queueRevision, emptyAndStopped: empty)
            try check(original.settleQuarantine(reading: reading) == nil)
            try check(foreign.settleQuarantine(reading: reading) == nil)
            try original.markNativeRequest(lease, callbackOutstanding: false)
            try check(original.settleQuarantine(reading: .init(stable: false, queueRevision: lease.queueRevision, emptyAndStopped: empty)) == nil)
            try check(original.settleQuarantine(reading: .init(stable: true, queueRevision: UUID(), emptyAndStopped: false)) == nil)
            let settled = try original.settleQuarantine(reading: reading)
            assert(settled?.state == (empty ? .cleared : .active))
            try check(!original.hasOutstandingRequest())
        }
        let service = "org.multimusic.app.checks.\(UUID().uuidString)"
        defer { removeFixture(service) }
        let old = SharedPlaybackOwnership(ownerBundleID: ownerID, accessGroup: nil, service: service, launchID: launch)
        let lease = try old.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        try old.quarantine(lease, cause: .callbackOutstanding)
        let relaunched = SharedPlaybackOwnership(ownerBundleID: ownerID, accessGroup: nil, service: service, launchID: UUID())
        try check(relaunched.settleQuarantine(reading: .init(stable: true, queueRevision: lease.queueRevision, emptyAndStopped: false))?.state == .active)
        print("Quarantine recovery checks passed: same-launch/29s refused; new-launch/legacy/30s/transport takeover fenced; automatic paths refused; owner-only stable settling; outstanding callbacks preserved.")
    }

    @MainActor
    private static func recipientIdentityChecks() throws {
        let base = "org.multimusic.app.checks.\(UUID().uuidString)"
        let otherBase = "org.multimusic.app.checks.\(UUID().uuidString)"
        defer {
            removeFixture(base + ".sharedPlayback.v1")
            removeFixture(otherBase + ".sharedPlayback.v1")
        }
        let original = SharedPlaybackOwnership(ownerBundleID: base, primaryOwnerBundleID: base,
                                              accessGroup: nil)
        let companion = SharedPlaybackOwnership(ownerBundleID: base + ".Spotify", primaryOwnerBundleID: base,
                                               accessGroup: nil)
        let other = SharedPlaybackOwnership(ownerBundleID: otherBase, primaryOwnerBundleID: otherBase,
                                           accessGroup: nil)
        let revision = UUID()
        let record = try original.bootstrap(revision: revision, terminal: .active)
        assert(record.ownerBundleID == base && record.queueRevision == revision)
        try check(companion.snapshot() == record)
        try check(other.snapshot() == nil)
        expect(.foreignOwner) { _ = try companion.bootstrap(revision: UUID(), terminal: .active) }
        let lease = try companion.begin(operationID: UUID(), revision: UUID(), mode: .replacement)
        try check(original.hasOutstandingRequest())
        try check(!other.hasOutstandingRequest())
        try companion.cancelBeforeMutation(lease)
        try check(original.snapshot() == record && !original.hasOutstandingRequest())
        print("Recipient identity checks passed: the pair shares ownership and lock state, only its primary adopts a journal, and a separate app base sees neither record.")
    }

    private static func check(_ passed: Bool, file: StaticString = #file, line: UInt = #line) {
        assert(passed, file: file, line: line)
    }

    @MainActor
    private static func expect(_ expected: SharedPlaybackOwnership.Failure, _ operation: () throws -> Void) {
        do { try operation(); assertionFailure("Expected \(expected)") }
        catch { assert(error as? SharedPlaybackOwnership.Failure == expected, "Unexpected failure: \(error)") }
    }

    private static func removeFixture(_ service: String) {
        assert(service.hasPrefix("org.multimusic.app.checks."))
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}
