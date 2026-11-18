import Foundation

// Compile with the unchanged MusicSession.restore body in an extension of this boundary fixture.
@MainActor
final class RestoreSessionFixture {
    var active = true, playbackEnabled = true, authorized = true, nativeBusy = false, preparing = false
    var selection: Task<Void, Never>?
    var journal: PlaybackJournal
    var commandVersion: UInt64 = 0
    var desiredPlaying: Bool?
    var generation = UUID()
    var status = ""
    var queueStatus = "", canRestore = false, skipped: [String] = []
    var skippedRows: [SkippedRow] = []
    func updateFooter() {}
    var replacements: [(PlaybackCheckpoint, Int)] = []
    var takeovers: [Bool] = []

    init(_ journal: PlaybackJournal) { self.journal = journal }
    func run() async -> PlaybackOutcome { await restore(automatic: false, userTakeover: true) }
    func updateSetup() { updateQueueStatus() }
    func currentIndex() -> Int? { nil }
    func skipExplanation(_ reason: MatchSkipReason?) -> String { "" }
    func readNativePlayer() -> PlaybackNativeObservation {
        PlaybackNativeObservation(catalogID: nil, nativeIndex: 0, position: 0, duration: 0,
                                  rawState: 0, itemPresent: false)
    }
    func invalidateSelection() { generation = UUID() }
    func resumeMatchingIfUseful() {}
    func logQueue(_ phase: String, count: Int) {}
    func outcome(_ reason: PlaybackOutcome.Reason? = nil) -> PlaybackOutcome {
        PlaybackOutcome(status: reason == nil ? .completed : .rejected, reason: reason, snapshot: PlaybackSnapshot())
    }
    func replace(_ checkpoint: PlaybackCheckpoint, start: Int, end: Int?, requireEmpty: Bool, userTakeover: Bool = false,
                 automaticCommandVersion: UInt64?, token: UUID) async -> PlaybackOutcome {
        replacements.append((checkpoint, start))
        takeovers.append(userTakeover)
        return outcome()
    }
}

@main
struct RestoreSavedQueueChecks {
    @MainActor
    static func main() async throws {
        func checkpoint(_ id: String) -> PlaybackCheckpoint {
            let source = SourceTrack(id: id, title: "Song", artist: "Artist", duration: 225)
            let match = MatchDecision(track: CatalogTrack(id: id, title: "Song", artist: "Artist", duration: 224.482),
                                      confidence: .metadataAndDuration)
            var value = PlaybackCheckpoint(sources: [source], country: "us")
            value.entries = [PlaybackOccurrence(sourceOrdinal: 0, source: source, match: match)]
            value.processedCount = 1
            value.submittedCount = 1
            value.resolutionComplete = true
            value.position = 51.393
            value.intendedPlaying = false
            return value
        }
        let saved = checkpoint("1541771175")
        var failed = checkpoint("1360226636")
        failed.resolutionComplete = false
        failed.position = 0
        failed.intendedPlaying = true
        let savedJournal = PlaybackJournal(current: saved, pendingReplacement: failed)
        let reopened = try PlaybackJournal.decode(JSONEncoder().encode(savedJournal))
        let fixture = RestoreSessionFixture(reopened)
        fixture.updateSetup()
        assert(!fixture.canRestore, "A pending replacement hides Restore")
        let idle = RestoreSessionFixture(PlaybackJournal(current: saved))
        idle.updateSetup()
        assert(idle.canRestore)
        idle.nativeBusy = true
        idle.updateSetup()
        assert(!idle.canRestore)
        idle.nativeBusy = false
        idle.preparing = true
        idle.updateSetup()
        assert(!idle.canRestore)
        // Run eligibility independently so its baseline failure is observable before Restore's failure.
        if CommandLine.arguments.contains("--eligibility-only") {
            for current in [PlaybackCheckpoint?.none, { var value = saved; value.terminal = .cleared; return value }()] {
                let unavailable = RestoreSessionFixture(PlaybackJournal(current: current, pendingReplacement: failed))
                unavailable.updateSetup()
                assert(!unavailable.canRestore, "Setup must not offer an unfinished replacement as a saved queue")
            }
            print("Restore eligibility checks passed: pending-only and cleared saved queues stay disabled.")
            return
        }
        let result = await fixture.run()
        assert(result.status == .completed && fixture.replacements.count == 1)
        assert(fixture.takeovers == [true], "Only explicit Restore requests takeover")
        let restored = fixture.replacements[0].0
        assert(restored.revision == saved.revision, "Restore must select the last successful queue, not the failed replacement")
        assert(restored.entries == saved.entries && restored.position == saved.position)
        assert(restored.intendedPlaying && restored.terminal == .active)
        assert(fixture.journal == reopened, "Choosing Restore must not rewrite either persisted checkpoint before replacement")

        for pending in [PlaybackCheckpoint?.none, failed] {
            let empty = RestoreSessionFixture(PlaybackJournal(pendingReplacement: pending))
            empty.updateSetup()
            assert(!empty.canRestore)
            let result = await empty.run()
            assert(result.reason == .noMatch && empty.replacements.isEmpty)
        }
        var cleared = saved
        cleared.terminal = .cleared
        let clearedFixture = RestoreSessionFixture(PlaybackJournal(current: cleared, pendingReplacement: failed))
        clearedFixture.updateSetup()
        assert(!clearedFixture.canRestore)
        let clearedResult = await clearedFixture.run()
        assert(clearedResult.reason == .cleared && clearedFixture.replacements.isEmpty)

        var completed = saved
        completed.terminal = .completed
        completed.cursor = completed.submittedCount
        let completedFixture = RestoreSessionFixture(PlaybackJournal(current: completed, pendingReplacement: failed))
        completedFixture.updateSetup()
        assert(!completedFixture.canRestore)
        let completedResult = await completedFixture.run()
        assert(completedResult.status == .completed && completedFixture.replacements.count == 1)
        assert(completedFixture.replacements[0].0.revision == saved.revision)
        assert(completedFixture.replacements[0].0.position == 0 && completedFixture.replacements[0].1 == 0)

        var legacy = saved
        legacy.legacy = true
        let legacyFixture = RestoreSessionFixture(PlaybackJournal(current: legacy, pendingReplacement: failed))
        legacyFixture.updateSetup()
        assert(!legacyFixture.canRestore)
        let legacyResult = await legacyFixture.run()
        assert(legacyResult.status == .completed && legacyFixture.replacements.count == 1)
        assert(legacyFixture.replacements[0].0.revision == saved.revision)
        print("Restore saved queue checks passed: idle eligibility; explicit takeover; successful checkpoint wins; pending-only and cleared reject; completed restarts; legacy remains explicitly restorable.")
    }
}
