import Foundation

// Compile beside the production retry and invalidation methods, using the same boundary-fixture pattern as Restore.
@MainActor
final class MatchingRetryFixture {
    var active = true, authorized = true, playbackEnabled = true, nativeBusy = false
    var owned = true
    var index: Int? = 0
    struct Player { var nowPlayingItem: Int? = 1 }
    var player = Player()
    var journal: PlaybackJournal
    var selection: Task<Void, Never>?
    var automaticResume: Task<Void, Never>?
    var resumeAttempt = 0
    var generation = UUID()
    var resolutionFailure: (revision: UUID, kind: RetryClass)?
    var requestRetry: (attempt: Int, limit: Int)?
    var problem: String?
    var preparing = false
    var observingEnd = false, awaitingPlay = false, continuingSuffix = false
    var endCandidate: Int?
    var intentVersion: UInt64 = 0
    var desiredPlaying: Bool?
    var starts: [(revision: UUID, base: Int)] = []
    var saves: [PlaybackJournal] = []
    var afterSave: (() -> Void)?

    init(_ journal: PlaybackJournal) { self.journal = journal }
    func currentIndex() -> Int? { index }
    func ownedNativeIndex() -> Int? { index }
    func ownsSharedQueue(_ checkpoint: PlaybackCheckpoint) -> Bool { owned }
    func isCurrent(_ token: UUID) -> Bool { active && authorized && generation == token && !Task.isCancelled }
    func persist() async throws {
        assert(journal.isValid)
        saves.append(journal)
        afterSave?()
        await Task.yield()
    }
    func storageFailure(_ error: Error, generation token: UUID? = nil) -> PlaybackOutcome {
        problem = "Save failed"
        return outcome(.nativeFailure)
    }
    func beginResolution(revision: UUID, base: Int) {
        starts.append((revision, base))
        selection = Task { try? await Task.sleep(for: .seconds(60)) }
    }
    func updateFooter() {}
    func finishSelection(_ value: PlaybackOutcome) {}
    func outcome(_ reason: PlaybackOutcome.Reason? = nil) -> PlaybackOutcome {
        PlaybackOutcome(status: reason == nil ? .completed : .rejected, reason: reason, snapshot: PlaybackSnapshot())
    }
    func schedule() {
        if let revision = journal.current?.revision ?? journal.pendingReplacement?.revision {
            scheduleMatchingResume(batch: revision, token: generation)
        }
    }
    func cancel() { invalidateSelection() }
}

@main
struct MatchingRetryChecks {
    @MainActor
    static func main() async {
        let songs = (0..<3).map { SourceTrack(id: "song-\($0)", title: "Song \($0)", artist: "Artist", duration: 100) }
        let match = MatchDecision(track: CatalogTrack(id: "42", title: "Song", artist: "Artist", duration: 100), confidence: .metadataAndDuration)
        var original = PlaybackCheckpoint(sources: songs, country: "us")
        original.entries = [PlaybackOccurrence(sourceOrdinal: 0, source: songs[0], match: match)]
        original.processedCount = 2
        original.skipReasons = [1: .noResults]
        original.submittedCount = 1
        assert(original.isValid)

        var pending = PlaybackCheckpoint(sources: songs, country: "us")
        pending.processedCount = 1
        pending.skipReasons = [0: .noResults]
        let pre = MatchingRetryFixture(PlaybackJournal(current: original, pendingReplacement: pending))
        pre.resolutionFailure = (pending.revision, .never)
        pre.schedule()
        assert(pre.automaticResume == nil, "never auto-resume a pending replacement")
        await pre.retryMatching()
        assert(pre.starts.count == 1 && pre.starts[0].base == 0)
        assert(pre.journal.pendingReplacement?.sources == songs && pre.journal.pendingReplacement?.sources.first == songs.first)
        assert(pre.journal.pendingReplacement?.processedCount == 0 && pre.journal.current == original)
        pre.cancel()

        let post = MatchingRetryFixture(PlaybackJournal(current: original))
        post.resolutionFailure = (original.revision, .transport)
        post.schedule()
        let delayed = post.automaticResume
        assert(delayed != nil && post.resumeAttempt == 1)
        await post.retryMatching()
        assert(delayed?.isCancelled == true && post.automaticResume == nil)
        assert(post.starts.count == 1 && post.starts[0].base == 2)
        assert(post.journal.current == original, "resume does not rewrite submitted entries")
        await post.retryMatching()
        assert(post.starts.count == 1, "a live selection blocks another retry")
        post.cancel()

        var settled = original
        settled.processedCount = 3
        settled.resolutionComplete = true
        settled.skipReasons?[2] = .contentConflict
        let skipped = MatchingRetryFixture(PlaybackJournal(current: settled))
        assert(skipped.retryableSkippedCount == 1)
        await skipped.retrySkipped()
        assert(skipped.starts.count == 1 && skipped.starts[0].base == 3)
        assert(skipped.saves.count == 1 && skipped.saves[0].current?.retryOf == [3: 1])
        assert(skipped.journal.current?.sources == songs + [songs[1]])
        assert(skipped.journal.current?.entries == settled.entries)
        assert(skipped.journal.current?.processedCount == 3 && skipped.journal.current?.resolutionComplete == false)
        assert(skipped.journal.current?.skippedRows.first?.retryState == .retrying)
        await skipped.retrySkipped()
        assert(skipped.starts.count == 1)
        skipped.cancel()
        skipped.journal.current?.processedCount = 4
        skipped.journal.current?.resolutionComplete = true
        skipped.journal.current?.skipReasons?[3] = .noResults
        await skipped.retrySkipped()
        assert(skipped.starts.count == 1 && skipped.retryableSkippedCount == 0, "no retry chains or unsafe skip retries")

        for boundary in ["busy", "foreign", "append", "unsubmitted", "replacement", "cleared", "selection", "problem", "incomplete"] {
            let blocked = MatchingRetryFixture(PlaybackJournal(current: settled))
            switch boundary {
            case "busy": blocked.nativeBusy = true
            case "foreign": blocked.owned = false
            case "append": blocked.journal.current?.pendingAppendEnd = 1
            case "unsubmitted": blocked.journal.current?.submittedCount = 0
            case "replacement": blocked.journal.pendingReplacement = pending
            case "cleared": blocked.journal.current?.terminal = .cleared
            case "selection": blocked.selection = Task {}
            case "problem": blocked.problem = "Unconfirmed Music request"
            default: blocked.journal.current?.resolutionComplete = false
            }
            await blocked.retrySkipped()
            assert(blocked.starts.isEmpty && blocked.saves.isEmpty, "blocked at \(boundary)")
            blocked.cancel()
        }
        let noAutomatic = MatchingRetryFixture(PlaybackJournal(current: original))
        noAutomatic.resolutionFailure = (original.revision, .never)
        noAutomatic.schedule()
        await noAutomatic.retryMatching()
        assert(noAutomatic.automaticResume == nil && noAutomatic.starts.isEmpty)
        noAutomatic.resolutionFailure = (original.revision, .transport)
        noAutomatic.schedule()
        let cancelled = noAutomatic.automaticResume
        noAutomatic.requestRetry = (2, 3)
        noAutomatic.cancel()
        assert(cancelled?.isCancelled == true && noAutomatic.resolutionFailure == nil && noAutomatic.requestRetry == nil)
        let paused = MatchingRetryFixture(PlaybackJournal(current: original))
        paused.journal.current?.intendedPlaying = false
        paused.resolutionFailure = (original.revision, .transport)
        paused.schedule()
        assert(paused.automaticResume == nil)

        let changedWhileSaving = MatchingRetryFixture(PlaybackJournal(current: original, pendingReplacement: pending))
        changedWhileSaving.resolutionFailure = (pending.revision, .transport)
        changedWhileSaving.afterSave = { changedWhileSaving.generation = UUID() }
        await changedWhileSaving.retryMatching()
        assert(changedWhileSaving.starts.isEmpty, "a new generation fences the retry after saving")
        print("Matching retry checks passed: pre-submission restarts at zero, submitted prefix resumes in place, skips append, no chains, delayed-task cancellation, safety boundaries, and selection changes during saving.")
    }
}
