import Foundation

@main
struct PlaybackCheckpointChecks {
    static func main() async throws {
        let source = SourceTrack(id: "repeat", title: "Song", artist: "Artist", duration: 100)
        let match = MatchDecision(track: CatalogTrack(id: "42", title: "Song", artist: "Artist", duration: 100), confidence: .metadataAndDuration)
        let now = Date(timeIntervalSince1970: 10_000)
        var checkpoint = PlaybackCheckpoint(sources: [source, source], country: "us")
        checkpoint.entries = [0, 1].map { PlaybackOccurrence(sourceOrdinal: $0, source: source, match: match) }
        checkpoint.processedCount = 2
        checkpoint.resolutionComplete = true
        checkpoint.submittedCount = 2
        checkpoint.cursor = 1
        checkpoint.position = 40
        checkpoint.observedAt = now
        assert(checkpoint.isValid)
        assert(checkpoint.occurrence(catalogID: "42", nativeIndex: 1) == 1)
        // A seek drag belongs to an occurrence, even when both songs have the same source/catalog ID.
        let ownershipFence = UUID()
        let firstSeek = checkpoint.seekTarget(catalogID: "42", nativeIndex: 0, ownershipFence: ownershipFence)
        let secondSeek = checkpoint.seekTarget(catalogID: "42", nativeIndex: 1, ownershipFence: ownershipFence)
        assert(firstSeek != nil && secondSeek != nil && firstSeek != secondSeek)
        var replacementSeek = checkpoint
        replacementSeek.revision = UUID()
        assert(replacementSeek.seekTarget(catalogID: "42", nativeIndex: 1, ownershipFence: ownershipFence) != secondSeek)
        // Restore may reuse its checkpoint revision; the shared fence still invalidates an earlier drag.
        assert(checkpoint.seekTarget(catalogID: "42", nativeIndex: 1, ownershipFence: UUID()) != secondSeek)
        for terminal in [PlaybackCheckpoint.Terminal.cleared, .completed] {
            var endedSeek = checkpoint
            endedSeek.terminal = terminal
            assert(endedSeek.seekTarget(catalogID: "42", nativeIndex: 1, ownershipFence: ownershipFence) == nil)
        }
        for invalid in [NSNotFound, -1, 2] {
            assert(checkpoint.seekTarget(catalogID: "42", nativeIndex: invalid, ownershipFence: ownershipFence) == nil)
        }
        assert(checkpoint.seekTarget(catalogID: "foreign", nativeIndex: 1, ownershipFence: ownershipFence) == nil)
        checkpoint.nativeOffset = 1
        assert(checkpoint.occurrence(catalogID: "42", nativeIndex: 0) == 1)
        assert(checkpoint.seekTarget(catalogID: "42", nativeIndex: 0, ownershipFence: ownershipFence) == secondSeek)
        assert(checkpoint.occurrence(catalogID: "other", nativeIndex: 0) == nil)
        assert(checkpoint.occurrence(catalogID: "42", nativeIndex: NSNotFound) == nil)
        assert(checkpoint.occurrence(catalogID: "42", nativeIndex: -1) == nil)
        assert(checkpoint.observedSubmittedEnd(index: 1, position: 99, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(2)))
        // The first reset cannot finish a second that was still left to play.
        assert(!checkpoint.observedSubmittedEnd(index: 1, position: 99, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(0.25)))
        assert(!checkpoint.observedSubmittedEnd(index: 0, position: 99, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(2)))
        assert(!checkpoint.observedSubmittedEnd(index: 1, position: 50, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(2)))
        assert(!checkpoint.observedSubmittedEnd(index: 1, position: 99, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(6)))
        // Actual build17 final-song sequence: 368.715/429.533, then zero/reset 60.946 seconds later.
        let endSource = SourceTrack(id: "end", title: "Song", artist: "Artist", duration: 429.533)
        var actualEnd = PlaybackCheckpoint(sources: [endSource, endSource, endSource], country: "us")
        actualEnd.entries = [0, 1, 2].map {
            PlaybackOccurrence(sourceOrdinal: $0, source: endSource,
                match: MatchDecision(track: CatalogTrack(id: String($0 + 1), title: "Song", artist: "Artist", duration: 429.533), confidence: .metadataAndDuration))
        }
        actualEnd.processedCount = 3
        actualEnd.submittedCount = 3
        actualEnd.cursor = 2
        actualEnd.resolutionComplete = true
        assert(actualEnd.observedSubmittedEnd(index: 2, position: 368.715, nativeDuration: 429.533, observedAt: now, now: now.addingTimeInterval(60.946)))
        assert(!actualEnd.observedSubmittedEnd(index: 2, position: 368.715, nativeDuration: 429.533, observedAt: now, now: now.addingTimeInterval(60.7)))
        assert(!actualEnd.observedSubmittedEnd(index: 2, position: 368.715, nativeDuration: 0, observedAt: now, now: now.addingTimeInterval(60.946)))
        var catalogDurationDiffers = actualEnd
        catalogDurationDiffers.entries[2] = PlaybackOccurrence(sourceOrdinal: 2, source: endSource,
            match: MatchDecision(track: CatalogTrack(id: "3", title: "Song", artist: "Artist", duration: 432.093), confidence: .metadataAndDuration))
        assert(catalogDurationDiffers.observedSubmittedEnd(index: 2, position: 368.715, nativeDuration: 429.533, observedAt: now, now: now.addingTimeInterval(60.946)))
        assert(actualEnd.isSubmittedEndReset(catalogID: "3", nativeIndex: 2, position: 0.002))
        assert(actualEnd.isSubmittedEndReset(catalogID: "1", nativeIndex: 0, position: 0))
        assert(!actualEnd.isSubmittedEndReset(catalogID: "3", nativeIndex: 2, position: 428.5))
        assert(!actualEnd.isSubmittedEndReset(catalogID: "2", nativeIndex: 1, position: 0))
        assert(!actualEnd.isSubmittedEndReset(catalogID: "foreign", nativeIndex: 0, position: 0))
        assert(!actualEnd.isSubmittedEndReset(catalogID: "3", nativeIndex: 0, position: 0))
        var repeatedEnd = actualEnd
        repeatedEnd.entries = actualEnd.entries.map {
            PlaybackOccurrence(sourceOrdinal: $0.sourceOrdinal, source: $0.source, match: actualEnd.entries[2].match)
        }
        assert(!repeatedEnd.isSubmittedEndReset(catalogID: "3", nativeIndex: 1, position: 0))
        assert(checkpoint.mayAutomaticallyRestore(at: now.addingTimeInterval(59)))
        assert(!checkpoint.mayAutomaticallyRestore(at: now.addingTimeInterval(60)))
        assert(!checkpoint.mayAutomaticallyRestore(at: now.addingTimeInterval(-1)))
        // Missing metadata in a live/loading, paused, or interrupted player is not an empty queue.
        assert(!checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: false, latestPlayingIntent: true, at: now))
        assert(!checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: true, nativeStopped: true, latestPlayingIntent: true, at: now))
        assert(checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: true, latestPlayingIntent: true, at: now.addingTimeInterval(59)))
        assert(!checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: true, latestPlayingIntent: true, at: now.addingTimeInterval(60)))
        assert(!checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: true, latestPlayingIntent: true, at: now.addingTimeInterval(-1)))
        // A completed newer Pause still wins after its temporary desired-playing override has gone away.
        assert(checkpoint.intendedPlaying)
        assert(!checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: true, latestPlayingIntent: false, at: now))
        assert(checkpoint.mayAutomaticallyResume(catalogID: "42", nativeIndex: 0, at: now.addingTimeInterval(59)))
        assert(!checkpoint.mayAutomaticallyResume(catalogID: "42", nativeIndex: 0, at: now.addingTimeInterval(60)))
        assert(!checkpoint.mayAutomaticallyResume(catalogID: "42", nativeIndex: 0, at: now.addingTimeInterval(-1)))
        assert(!checkpoint.mayAutomaticallyResume(catalogID: "foreign", nativeIndex: 0, at: now))
        assert(!checkpoint.mayAutomaticallyResume(catalogID: "42", nativeIndex: NSNotFound, at: now))
        var wrongOccurrence = checkpoint
        wrongOccurrence.nativeOffset = 0
        assert(!wrongOccurrence.mayAutomaticallyResume(catalogID: "42", nativeIndex: 0, at: now))
        // A repeated recording earlier than the saved cursor cannot authorize automatic playback.
        assert(wrongOccurrence.mayAutomaticallyResume(catalogID: "42", nativeIndex: 1, at: now))
        // Music may advance while this app is closed; resume its verified later occurrence in place.
        var advanced = wrongOccurrence
        advanced.cursor = 0
        advanced.position = 40
        assert(advanced.mayAutomaticallyResume(catalogID: "42", nativeIndex: 1, at: now.addingTimeInterval(1)))
        // The original saved remaining time is the deadline, even when a later item is observed.
        assert(!advanced.mayAutomaticallyResume(catalogID: "42", nativeIndex: 1, at: now.addingTimeInterval(160)))
        assert(!advanced.mayAutomaticallyResume(catalogID: "foreign", nativeIndex: 1, at: now))
        // Music can retain a unique later song while rebasing its native queue index after closing.
        var rebased = actualEnd
        rebased.observedAt = now
        rebased.position = 100
        assert(rebased.mayAutomaticallyResume(catalogID: "3", nativeIndex: 1, at: now.addingTimeInterval(1)))
        assert(rebased.recoveryTarget(catalogID: "3", nativeIndex: 1) ==
            PlaybackCheckpoint.RecoveryTarget(occurrence: 2, nativeOffset: 1))
        assert(rebased.recoveryTarget(catalogID: "3", nativeIndex: 2) ==
            PlaybackCheckpoint.RecoveryTarget(occurrence: 2, nativeOffset: 0))
        for invalid in [-1, NSNotFound, 3] {
            assert(rebased.recoveryTarget(catalogID: "3", nativeIndex: invalid) == nil)
        }
        assert(rebased.recoveryTarget(catalogID: "1", nativeIndex: 0) == nil)
        assert(rebased.recoveryTarget(catalogID: "foreign", nativeIndex: 1) == nil)
        assert(!rebased.mayAutomaticallyResume(catalogID: "3", nativeIndex: 1, at: now.addingTimeInterval(330)))
        assert(!rebased.mayAutomaticallyResume(catalogID: "3", nativeIndex: 1, at: now.addingTimeInterval(-1)))
        var repeatedRebase = rebased
        repeatedRebase.entries[0] = PlaybackOccurrence(sourceOrdinal: 0, source: endSource, match: rebased.entries[2].match)
        assert(repeatedRebase.recoveryTarget(catalogID: "3", nativeIndex: 1) == nil)
        var existingOffset = rebased
        existingOffset.nativeOffset = 1
        assert(existingOffset.recoveryTarget(catalogID: "3", nativeIndex: 0) ==
            PlaybackCheckpoint.RecoveryTarget(occurrence: 2, nativeOffset: 2))
        assert(existingOffset.recoveryTarget(catalogID: "3", nativeIndex: 2) == nil)
        // Actual original27 recovery2: an already-rebased song played at index0, then healed to1 after298ms.
        let savedMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 5, nativeOffset: 5)
        let savedPlaying = PlaybackNativeObservation(catalogID: "6", nativeIndex: 0, position: 70, duration: 429.533, rawState: 1)
        let healedMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 5, nativeOffset: 4)
        let healedPlaying = PlaybackNativeObservation(catalogID: "6", nativeIndex: 1, position: 70, duration: 429.533, rawState: 1)
        var secondRecovery = PlaybackRecoveryConfirmation(rebasedTarget: savedMapping)
        assert(!secondRecovery.accepts(savedPlaying, target: savedMapping, at: now))
        assert(!secondRecovery.accepts(savedPlaying, target: savedMapping, at: now.addingTimeInterval(0.1)))
        assert(!secondRecovery.accepts(healedPlaying, target: healedMapping, at: now.addingTimeInterval(0.298)))
        assert(!secondRecovery.accepts(healedPlaying, target: healedMapping, at: now.addingTimeInterval(2.1)))
        assert(secondRecovery.accepts(healedPlaying, target: healedMapping, at: now.addingTimeInterval(2.31)))
        var twiceRebased = PlaybackCheckpoint(sources: Array(repeating: endSource, count: 6), country: "us")
        twiceRebased.entries = (0..<6).map { ordinal in
            PlaybackOccurrence(sourceOrdinal: ordinal, source: endSource,
                match: MatchDecision(track: CatalogTrack(id: String(ordinal + 1), title: "Song", artist: "Artist", duration: 429.533), confidence: .metadataAndDuration))
        }
        twiceRebased.processedCount = 6
        twiceRebased.submittedCount = 6
        twiceRebased.cursor = 5
        twiceRebased.nativeOffset = 5
        twiceRebased.position = 70
        twiceRebased.observedAt = now
        assert(twiceRebased.isValid)
        assert(twiceRebased.playingRecoveryTarget(catalogID: "6", nativeIndex: 0, recovering: savedMapping) == savedMapping)
        assert(twiceRebased.playingRecoveryTarget(catalogID: "6", nativeIndex: 1, recovering: savedMapping) == healedMapping)
        assert(twiceRebased.recoveryTarget(catalogID: "6", nativeIndex: 1) == nil, "stopped recovery must not infer a backwards offset")
        for invalid in [-1, NSNotFound, 6] {
            assert(twiceRebased.playingRecoveryTarget(catalogID: "6", nativeIndex: invalid, recovering: savedMapping) == nil)
        }
        for wrongID in ["foreign", "5"] {
            assert(twiceRebased.playingRecoveryTarget(catalogID: wrongID, nativeIndex: 1, recovering: savedMapping) == nil)
        }
        assert(twiceRebased.playingRecoveryTarget(catalogID: "5", nativeIndex: 0,
            recovering: PlaybackCheckpoint.RecoveryTarget(occurrence: 4, nativeOffset: 4)) == nil)
        var ambiguousHealing = twiceRebased
        ambiguousHealing.entries[0] = PlaybackOccurrence(sourceOrdinal: 0, source: endSource, match: twiceRebased.entries[5].match)
        assert(ambiguousHealing.playingRecoveryTarget(catalogID: "6", nativeIndex: 1, recovering: savedMapping) == nil)
        twiceRebased.nativeOffset = healedMapping.nativeOffset
        assert(twiceRebased.occurrence(catalogID: "6", nativeIndex: 1) == 5)
        assert(twiceRebased.captureObservation(healedPlaying, confirmedBy: healedPlaying, desiredPlaying: true, at: now.addingTimeInterval(2.31)))
        assert(twiceRebased.cursor == 5 && twiceRebased.position == 70)
        var discontinuous = PlaybackRecoveryConfirmation(rebasedTarget: savedMapping)
        assert(!discontinuous.accepts(savedPlaying, target: savedMapping, at: now))
        for position in [10.0, 100.0] {
            let jumped = PlaybackNativeObservation(catalogID: "6", nativeIndex: 0, position: position, duration: 429.533, rawState: 1)
            assert(!discontinuous.accepts(jumped, target: savedMapping, at: now.addingTimeInterval(2.1)))
            discontinuous.reset()
            assert(!discontinuous.accepts(savedPlaying, target: savedMapping, at: now))
        }
        // Actual Spotify12: first playing index1 normalized to index3 after610ms.
        let initialMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 3, nativeOffset: 2)
        let canonicalMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 3, nativeOffset: 0)
        let firstPlaying = PlaybackNativeObservation(catalogID: "unique", nativeIndex: 1, position: 30, duration: 224.693, rawState: 1)
        let canonicalPlaying = PlaybackNativeObservation(catalogID: "unique", nativeIndex: 3, position: 30.002, duration: 224.693, rawState: 1)
        var confirmation = PlaybackRecoveryConfirmation(rebasedTarget: initialMapping)
        assert(!confirmation.accepts(firstPlaying, target: initialMapping, at: now))
        assert(!confirmation.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(0.5)))
        assert(!confirmation.accepts(canonicalPlaying, target: canonicalMapping, at: now.addingTimeInterval(0.61)))
        assert(confirmation.accepts(canonicalPlaying, target: canonicalMapping, at: now.addingTimeInterval(0.70)))
        var retainedPrefix = PlaybackRecoveryConfirmation(rebasedTarget: initialMapping)
        assert(!retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now))
        assert(!retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(1.99)))
        assert(retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(2.01)))
        let wrongMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 3, nativeOffset: 3)
        let changedIndex = PlaybackNativeObservation(catalogID: "unique", nativeIndex: 0, position: 30.002, duration: 224.693, rawState: 1)
        assert(!retainedPrefix.accepts(changedIndex, target: wrongMapping, at: now.addingTimeInterval(2.1)))
        let pausedDuringConfirmation = PlaybackNativeObservation(catalogID: "unique", nativeIndex: 1, position: 30, duration: 224.693, rawState: 2)
        assert(!retainedPrefix.accepts(pausedDuringConfirmation, target: initialMapping, at: now.addingTimeInterval(2.2)))
        assert(!retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(2.3)))
        retainedPrefix.reset()
        assert(!retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(5)))
        assert(!retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(6.99)))
        assert(retainedPrefix.accepts(firstPlaying, target: initialMapping, at: now.addingTimeInterval(7.01)))
        var restoredSuffix = PlaybackRecoveryConfirmation(
            rebasedTarget: PlaybackCheckpoint.RecoveryTarget(occurrence: 3, nativeOffset: 2))
        assert(!restoredSuffix.accepts(canonicalPlaying, target: canonicalMapping, at: now))
        let suffixPlaying = PlaybackNativeObservation(catalogID: "unique", nativeIndex: 2, position: 30.002, duration: 224.693, rawState: 1)
        let suffixMapping = PlaybackCheckpoint.RecoveryTarget(occurrence: 3, nativeOffset: 1)
        assert(!restoredSuffix.accepts(suffixPlaying, target: suffixMapping, at: now.addingTimeInterval(0.1)))
        assert(!restoredSuffix.accepts(suffixPlaying, target: suffixMapping, at: now.addingTimeInterval(0.2)))
        assert(restoredSuffix.accepts(suffixPlaying, target: suffixMapping, at: now.addingTimeInterval(2.11)))
        for blocked in ["paused", "cleared", "completed", "legacy", "append"] {
            var blockedRebase = rebased
            switch blocked {
            case "paused": blockedRebase.intendedPlaying = false
            case "cleared": blockedRebase.terminal = .cleared
            case "completed": blockedRebase.terminal = .completed
            case "legacy": blockedRebase.legacy = true
            default: blockedRebase.pendingAppendEnd = 3
            }
            assert(!blockedRebase.mayAutomaticallyResume(catalogID: "3", nativeIndex: 1, at: now))
        }
        for blocked in ["paused", "cleared", "completed", "legacy", "append"] {
            var blockedCheckpoint = checkpoint
            switch blocked {
            case "paused": blockedCheckpoint.intendedPlaying = false
            case "cleared": blockedCheckpoint.terminal = .cleared
            case "completed": blockedCheckpoint.terminal = .completed
            case "legacy": blockedCheckpoint.legacy = true
            default: blockedCheckpoint.pendingAppendEnd = 2
            }
            assert(!blockedCheckpoint.mayAutomaticallyResume(catalogID: "42", nativeIndex: 0, at: now))
            assert(!blockedCheckpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: false, nativeStopped: true, latestPlayingIntent: true, at: now))
            assert(!blockedCheckpoint.observedSubmittedEnd(index: 1, position: 99, nativeDuration: 100, observedAt: now, now: now.addingTimeInterval(2)))
        }
        var unsubmitted = checkpoint
        unsubmitted.sources.append(source)
        unsubmitted.processedCount = 3
        unsubmitted.entries.append(PlaybackOccurrence(sourceOrdinal: 2, source: source, match: match))
        assert(unsubmitted.remainingSubmittedDuration == 60)
        assert(!unsubmitted.mayAutomaticallyRestore(at: now.addingTimeInterval(60)))
        checkpoint.pendingAppendEnd = 2
        assert(!checkpoint.mayAutomaticallyRestore(at: now))
        checkpoint.pendingAppendEnd = nil
        checkpoint.terminal = .cleared
        assert(!checkpoint.mayAutomaticallyRestore(at: now))
        checkpoint.terminal = .completed
        assert(!checkpoint.mayAutomaticallyRestore(at: now))
        checkpoint.terminal = .active
        checkpoint.intendedPlaying = false
        assert(!checkpoint.mayAutomaticallyRestore(at: now))
        assert(!checkpoint.observedSubmittedEnd(index: 1, position: 99, nativeDuration: 100, observedAt: now, now: now))
        let legacy = try JSONEncoder().encode(["handoff": QueueHandoff(tracks: [HandedOffTrack(source: source, catalog: match.track)])])
        let migrated = try PlaybackJournal.decode(legacy)
        assert(migrated.current?.legacy == true && migrated.current?.intendedPlaying == false)
        assert(migrated.current?.mayAutomaticallyRestore(at: now) == false)
        var replacement = PlaybackCheckpoint(sources: [source], country: "us")
        replacement.entries = [PlaybackOccurrence(sourceOrdinal: 0, source: source,
            match: MatchDecision(track: CatalogTrack(id: "84", title: "Song", artist: "Artist", duration: 100), confidence: .metadataAndDuration))]
        replacement.processedCount = 1
        replacement.submittedCount = 1
        let owners = [PlaybackQueueIdentity(checkpoint), PlaybackQueueIdentity(replacement)]
        let pending = PlaybackJournal(sequence: 5, current: checkpoint, pendingReplacement: unsubmitted, clearPending: true, clearOwners: owners)
        let recovered = try PlaybackJournal.decode(JSONEncoder().encode(pending))
        assert(recovered.current == checkpoint && recovered.pendingReplacement == unsubmitted && recovered.clearPending == true)
        assert(recovered.clearOwners?.contains { $0.contains(catalogID: "42", nativeIndex: 0) } == true)
        assert(recovered.clearOwners?.contains { $0.contains(catalogID: "84", nativeIndex: 0) } == true)
        assert(recovered.clearOwners?.contains { $0.contains(catalogID: "foreign", nativeIndex: 0) } == false)
        assert(!owners[0].contains(catalogID: "42", nativeIndex: NSNotFound))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The actual persistence owner rejects transient readings and retains a stopped recovery deadline.
        var captured = advanced
        let beforeCapture = captured
        let stopped = PlaybackNativeObservation(catalogID: "42", nativeIndex: 1, position: 50, duration: 100, rawState: 0)
        let playing = PlaybackNativeObservation(catalogID: "42", nativeIndex: 1, position: 50, duration: 100, rawState: 1)
        let staleOccurrence = PlaybackNativeObservation(catalogID: "42", nativeIndex: 0, position: 50, duration: 100, rawState: 1)
        let paused = PlaybackNativeObservation(catalogID: "42", nativeIndex: 1, position: 50, duration: 100, rawState: 2)
        assert(!captured.captureObservation(playing, confirmedBy: stopped, desiredPlaying: nil, at: now.addingTimeInterval(1)))
        assert(!captured.captureObservation(staleOccurrence, confirmedBy: playing, desiredPlaying: nil, at: now.addingTimeInterval(1)))
        for offset in [1.0, 2.0] {
            assert(!captured.captureObservation(stopped, confirmedBy: stopped, desiredPlaying: nil, at: now.addingTimeInterval(offset)))
        }
        assert(captured == beforeCapture)
        assert(captured.captureObservation(paused, confirmedBy: paused, desiredPlaying: nil, at: now.addingTimeInterval(3)))
        let observationStore = PlaybackCheckpointStore(url: folder.appendingPathComponent("observed.json"))
        try await observationStore.save(PlaybackJournal(sequence: 1, current: captured))
        let persistedPause = await PlaybackCheckpointStore(url: folder.appendingPathComponent("observed.json")).load()
        assert(persistedPause?.current?.intendedPlaying == false && persistedPause?.current?.cursor == 1)
        assert(persistedPause?.current?.position == 50 && persistedPause?.current?.observedAt == now.addingTimeInterval(3))
        let store = PlaybackCheckpointStore(url: folder.appendingPathComponent("checkpoint.json"))
        var latest = PlaybackJournal(sequence: 2, current: checkpoint)
        try await store.save(latest)
        latest.sequence = 1
        latest.current?.position = 0
        try await store.save(latest)
        let restored = await store.load()
        assert(restored?.sequence == 2 && restored?.current?.position == 40)
        try await store.remove(ifNotNewerThan: 1)
        let afterStaleClear = await store.load()
        assert(afterStaleClear?.sequence == 2)
        // A callback receipt must survive a process restart, including preparation errors.
        let clearID = UUID()
        var clearing = PlaybackJournal(sequence: 3, current: checkpoint, clearPending: true,
                                       clearRequestID: clearID, clearOwners: owners)
        clearing.current?.terminal = .cleared
        try await store.save(clearing)
        let interrupted = await PlaybackCheckpointStore(url: folder.appendingPathComponent("checkpoint.json")).load()
        assert(interrupted?.clearPending == true && interrupted?.clearRequestID == clearID)
        assert(!clearing.settleClear(requestID: UUID()))
        assert(clearing.clearPending == true)
        assert(clearing.settleClear(requestID: clearID))
        clearing.sequence = 4
        try await store.save(clearing)
        let settled = await PlaybackCheckpointStore(url: folder.appendingPathComponent("checkpoint.json")).load()
        assert(settled?.clearPending == false && settled?.current?.terminal == .cleared)
        assert(settled?.clearOwners == nil)
        assert(settled?.current?.mayAutomaticallyRestore(at: now) == false)
        // A late receipt cannot settle a later request or erase a replacement selection.
        let laterClearID = UUID()
        clearing.clearRequestID = laterClearID
        clearing.clearPending = true
        assert(!clearing.settleClear(requestID: clearID) && clearing.clearPending == true)
        clearing.clearPending = false
        clearing.clearRequestID = nil
        clearing.current = replacement
        assert(!clearing.settleClear(requestID: laterClearID) && clearing.current == replacement)
        assert(recovered.clearPending == true && recovered.clearRequestID == nil)
        assert(recovered.current?.skipReasons == nil)
        // Repeated source IDs keep separate explanations across an actual saved-file restart.
        var explained = PlaybackCheckpoint(sources: [source, source, source], country: "us")
        explained.processedCount = 3
        explained.entries = [PlaybackOccurrence(sourceOrdinal: 1, source: source, match: match)]
        explained.skipReasons = [0: .noResults, 2: .ambiguousRecording]
        let explainedJournal = PlaybackJournal(sequence: 5, current: explained)
        try await store.save(explainedJournal)
        let savedExplanations = await PlaybackCheckpointStore(url: folder.appendingPathComponent("checkpoint.json")).load()
        assert(savedExplanations?.current?.skipReasons == [0: .noResults, 2: .ambiguousRecording])
        assert(savedExplanations?.current?.entries.map(\.sourceOrdinal) == [1])
        // Unprocessed, matched, negative, and out-of-range positions cannot enter the durable journal.
        for invalidOrdinal in [-1, 1, 3] {
            var invalid = explainedJournal
            invalid.sequence = 6
            invalid.current?.skipReasons = [invalidOrdinal: .noResults]
            do {
                try await store.save(invalid)
                assertionFailure("Invalid skip occurrence was saved")
            } catch {
                assert((error as? CocoaError)?.code == .coderInvalidValue)
            }
        }
        var unprocessedReason = explainedJournal
        unprocessedReason.sequence = 6
        unprocessedReason.current?.processedCount = 2
        do {
            try await store.save(unprocessedReason)
            assertionFailure("An unchecked source was saved as skipped")
        } catch {
            assert((error as? CocoaError)?.code == .coderInvalidValue)
        }
        let afterRejectedReasons = await store.load()
        assert(afterRejectedReasons == explainedJournal)
        // Retry copies remain append-only and keep original occurrence identities.
        var retryBatch = PlaybackCheckpoint(sources: Array(repeating: source, count: 50), country: "us")
        retryBatch.processedCount = 50
        retryBatch.skipReasons = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, .noResults) })
        retryBatch.entries = (10..<50).map { PlaybackOccurrence(sourceOrdinal: $0, source: source, match: match) }
        retryBatch.submittedCount = 40
        retryBatch.resolutionComplete = true
        let oldJSON = try JSONEncoder().encode(PlaybackJournal(current: retryBatch))
        assert(!(String(decoding: oldJSON, as: UTF8.self).contains("retryOf")))
        let decodedOldJSON = try PlaybackJournal.decode(oldJSON)
        assert(decodedOldJSON.current == retryBatch)
        assert(retryBatch.retryableRoots == Array(0..<10))
        let oldEntries = retryBatch.entries
        retryBatch.sources += Array(repeating: source, count: 10)
        retryBatch.retryOf = Dictionary(uniqueKeysWithValues: (0..<10).map { (50 + $0, $0) })
        retryBatch.resolutionComplete = false
        assert(retryBatch.isValid && retryBatch.entries == oldEntries)
        assert(retryBatch.retryableRoots.isEmpty)
        assert(retryBatch.skippedRows.count == 10 && retryBatch.skippedRows.allSatisfy { $0.retryState == .retrying })
        let retryJSON = try JSONEncoder().encode(PlaybackJournal(current: retryBatch))
        let retryObject = try JSONSerialization.jsonObject(with: retryJSON) as! [String: Any]
        let checkpointObject = retryObject["current"] as! [String: Any]
        assert((checkpointObject["retryOf"] as? [String: Int])?["50"] == 0)
        let decodedRetryJSON = try PlaybackJournal.decode(retryJSON)
        assert(decodedRetryJSON.current == retryBatch)
        func rejectsRetry(_ change: (inout PlaybackCheckpoint) -> Void) {
            var invalid = retryBatch
            change(&invalid)
            assert(!invalid.isValid)
        }
        rejectsRetry { $0.sources.append(source); $0.retryOf?[60] = 10 } // Eleven retries.
        rejectsRetry { $0.sources = []; $0.retryOf = nil } // No original songs.
        rejectsRetry { $0.sources.append(source); $0.retryOf = nil } // More than fifty originals.
        rejectsRetry { $0.retryOf = [:] } // Empty maps are never stored.
        rejectsRetry { $0.retryOf?.removeValue(forKey: 50) } // Missing append ordinal.
        rejectsRetry { value in let root = value.retryOf?.removeValue(forKey: 50); value.retryOf?[49] = root } // Noncontiguous keys.
        rejectsRetry { $0.retryOf?[50] = 50 } // Retry chains.
        rejectsRetry { $0.retryOf?[50] = -1 } // Negative original ordinal.
        rejectsRetry { $0.retryOf?[51] = 0 } // An original can be retried only once.
        rejectsRetry { $0.sources[50] = SourceTrack(id: "different", title: "Song", artist: "Artist", duration: 100) }
        rejectsRetry { $0.skipReasons?[0] = .ambiguousRecording }
        rejectsRetry { $0.skipReasons?.removeValue(forKey: 0) }
        // Recovered copies fold into the original report row, but append as new playable occurrences.
        retryBatch.processedCount = 52
        retryBatch.entries.append(PlaybackOccurrence(sourceOrdinal: 50, source: source, match: match))
        retryBatch.skipReasons?[51] = .noCompatibleMetadata
        assert(retryBatch.isValid)
        assert(retryBatch.skippedRows.count == 9 && !retryBatch.skippedRows.contains { $0.id == 0 })
        assert(retryBatch.skippedRows.first?.id == 1 && retryBatch.skippedRows.first?.retryState == .retried)
        assert(retryBatch.skippedRows.first?.reason == .noCompatibleMetadata)
        assert(retryBatch.skippedRows.last?.retryState == .retrying)
        retryBatch.submittedCount = 41
        assert(retryBatch.entries.last?.sourceOrdinal == 50)
        assert(retryBatch.occurrence(catalogID: "42", nativeIndex: 40) == 40)
        assert(retryBatch.entries.prefix(40) == oldEntries[...])
        try await store.save(PlaybackJournal(sequence: 7, current: retryBatch))
        let roundTripRetries = await PlaybackCheckpointStore(url: folder.appendingPathComponent("checkpoint.json")).load()
        assert(roundTripRetries?.current == retryBatch)
        // Duplicate source IDs without a retry link remain separate original skipped occurrences.
        var repeated = PlaybackCheckpoint(sources: [source, source, source], country: "us")
        repeated.processedCount = 3
        repeated.skipReasons = [0: .noResults, 1: .noCompatibleMetadata, 2: .contentConflict]
        assert(repeated.skippedRows.map(\.id) == [0, 1, 2])
        assert(repeated.retryableRoots == [0, 1])
        repeated.sources.append(source)
        repeated.retryOf = [3: 0]
        repeated.processedCount = 4
        repeated.skipReasons?[3] = .noResults
        assert(repeated.isValid && repeated.retryableRoots == [1])
        assert(repeated.skippedRows.map(\.retryState) == [.retried, nil, nil])
        for count in [60, 61] {
            let ownerData = try JSONSerialization.data(withJSONObject: ["storeIDs": Array(repeating: "42", count: count)])
            let owner = try JSONDecoder().decode(PlaybackQueueIdentity.self, from: ownerData)
            assert(PlaybackJournal(clearOwners: [owner]).isValid == (count == 60))
        }
        // A journal above fifty sources with no retry map fails closed on load.
        var missingMap = checkpointObject
        missingMap.removeValue(forKey: "retryOf")
        let invalidData = try JSONSerialization.data(withJSONObject: ["version": 2, "sequence": 8, "current": missingMap])
        let invalidURL = folder.appendingPathComponent("invalid-retries.json")
        try invalidData.write(to: invalidURL)
        let invalidLoad = await PlaybackCheckpointStore(url: invalidURL).load()
        assert(invalidLoad == nil)
        print("Retry checkpoint contracts passed: old JSON, 50+10 bounds, all retry-map clauses, round-trip persistence, 60/61 clear identities, folded reports, and appended occurrences.")
        print("Checkpoint contracts passed: occurrence-bound seek targets, guarded recovery, verified forward-occurrence resume, captured final-end timing and reset identity, migration, append uncertainty, ordered saves, durable Clear receipts, and per-occurrence skip explanations.")
    }
}
