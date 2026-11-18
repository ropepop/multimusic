import Foundation
import Security

private enum MusicAuthorization { static let currentStatus = Status.authorized; enum Status { case authorized } }

// Compile beside the production transport observation and cursor reconciliation methods.
@MainActor
final class TransportSessionFixture {
    var journal: PlaybackJournal
    var reading: PlaybackNativeObservation
    var playerReading: PlaybackNativeObservation?
    var playerReadingIsStable = true, playerSettled = false
    var inconsistentNativeObservations: UInt64 = 0
    var status = "", saves = 0
    var problem: String?
    var active = true, authorized = true, playbackEnabled = true, preparing = false
    var generation = UUID()
    var playerOperation: Task<Void, Never>?
    var nativeBusy = false, sharedBusy = false
    var nativeLease: SharedPlaybackOwnership.Lease?
    var sharedRecord: SharedPlaybackOwnership.Record?
    var nativeMutationIssued = false, nativeNeedsObservation = false, nativeCallbackOutstanding = false
    var nativeObservation: (@MainActor () -> Bool)?
    var lastSharedRefresh = Date.distantPast
    let ownership: SharedPlaybackOwnership
    let service = "org.multimusic.app.checks.\(UUID().uuidString)"

    init(_ checkpoint: PlaybackCheckpoint, _ reading: PlaybackNativeObservation) {
        journal = PlaybackJournal(current: checkpoint)
        self.reading = reading
        ownership = SharedPlaybackOwnership(ownerBundleID: "org.multimusic.app", accessGroup: nil, service: service)
    }
    func readNativePlayer() -> PlaybackNativeObservation { reading }
    func currentIndex() -> Int? {
        journal.current?.occurrence(catalogID: reading.catalogID, nativeIndex: reading.nativeIndex)
    }
    func persistLater() { saves += 1 }
    func accept(_ reading: PlaybackNativeObservation) -> Bool { acceptOwnedReading(reading, revision: journal.current!.revision) }
    func outcome(_ reason: PlaybackOutcome.Reason? = nil) -> PlaybackOutcome {
        PlaybackOutcome(status: reason == nil ? .completed : .rejected, reason: reason, snapshot: PlaybackSnapshot())
    }
    private func observe(_ token: UUID, ticket: Completion, _ predicate: @MainActor () -> Bool) async -> PlaybackOutcome {
        confirmsNativeObservation(predicate) ? outcome() : outcome(.timedOut)
    }
    func refreshSharedOwnership(force: Bool) { sharedRecord = try? ownership.snapshot() }
    func refresh() {}
    func captureProgress(force: Bool) {}
    func ownershipFailure(_ error: Error) -> PlaybackOutcome { outcome(.nativeFailure) }
    func cleanUp() {
        assert(service.hasPrefix("org.multimusic.app.checks."))
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
    func run(_ command: PlaybackCommand, from index: Int, callbackOutstanding: Bool = false) async -> PlaybackOutcome {
        await serialized(generation, mode: .replacement, revision: journal.current!.revision) { [self] ticket in
            do { try ownership.markNativeRequest(nativeLease!, callbackOutstanding: callbackOutstanding) }
            catch { return ownershipFailure(error) }
            nativeMutationIssued = true
            nativeCallbackOutstanding = callbackOutstanding
            return await observeTransport(command, from: index, token: generation, ticket: ticket)
        }
    }
}

@main
struct TransportObservationChecks {
    @MainActor
    static func main() async {
        let songs = (0..<4).map { SourceTrack(id: "source\($0)", title: "Song \($0)", artist: "Artist", duration: 200) }
        var checkpoint = PlaybackCheckpoint(sources: songs, country: "us")
        checkpoint.entries = songs.enumerated().map { index, source in
            PlaybackOccurrence(sourceOrdinal: index, source: source,
                match: MatchDecision(track: CatalogTrack(id: String(index), title: source.title, artist: source.artist, duration: 200),
                                     confidence: .metadataAndDuration))
        }
        checkpoint.processedCount = 4
        checkpoint.submittedCount = 4
        checkpoint.resolutionComplete = true
        checkpoint.cursor = 1
        let jump = PlaybackNativeObservation(catalogID: "3", nativeIndex: 3, position: 0, duration: 200, rawState: 1)
        let next = TransportSessionFixture(checkpoint, jump)
        defer { next.cleanUp() }
        let nextResult = await next.run(.next, from: 1)
        assert(nextResult.status == .completed)
        assert(next.journal.current?.cursor == 3 && next.journal.current?.terminal == .active && next.saves == 1)
        assert(next.status == "Skipped 1 unavailable")
        assert(next.sharedRecord?.state == .active)
        assert(try! !next.ownership.hasOutstandingRequest(), "Mapped index jumps must release the real shared lock")
        let backward = PlaybackNativeObservation(catalogID: "1", nativeIndex: 1, position: 0, duration: 200, rawState: 1)
        let previous = TransportSessionFixture(checkpoint, backward)
        defer { previous.cleanUp() }
        let previousResult = await previous.run(.previous, from: 3)
        assert(previousResult.status == .completed && previous.status == "Skipped 1 unavailable")
        for position in [0.0, 0.999, 1.0, 20.0] {
            let unchanged = PlaybackNativeObservation(catalogID: "1", nativeIndex: 1, position: position, duration: 200, rawState: 1)
            let fixture = TransportSessionFixture(checkpoint, unchanged)
            defer { fixture.cleanUp() }
            let nextResult = await fixture.run(.next, from: 1)
            assert(nextResult.reason == .nativeNoChange && fixture.journal.current?.terminal == .active)
            assert(try! !fixture.ownership.hasOutstandingRequest())
            let previousResult = await fixture.run(.previous, from: 1)
            assert(position < 1 ? previousResult.status == .completed : previousResult.reason == .nativeNoChange)
        }
        assert(!jump.acceptsTransport(.next, from: 1, to: nil))
        let unknown = PlaybackNativeObservation(catalogID: "foreign", nativeIndex: 3, position: 0, duration: 200, rawState: 1)
        let unmapped = TransportSessionFixture(checkpoint, unknown)
        defer { unmapped.cleanUp() }
        assert(!unmapped.accept(unknown))
        assert(unmapped.journal.current?.cursor == 1 && unmapped.saves == 0)
        let unknownResult = await unmapped.run(.next, from: 1)
        assert(unknownResult.reason == .timedOut && unmapped.sharedRecord?.state == .uncertain)
        assert(try! unmapped.ownership.hasOutstandingRequest())
        let callback = TransportSessionFixture(checkpoint, jump)
        defer { callback.cleanUp() }
        _ = await callback.run(.next, from: 1, callbackOutstanding: true)
        assert(callback.sharedRecord?.state == .uncertain)
        assert(try! callback.ownership.hasOutstandingRequest())
        print("Transport observation checks passed: fake native jump 1→3 completes and saves cursor 3; backward jumps; previous restart <1s; unchanged Next rejects nativeNoChange; mapped observations release the shared lock; unmapped readings and outstanding callbacks quarantine.")
    }
}
