import Combine
import CryptoKit
import Foundation
@preconcurrency import MediaPlayer
@preconcurrency import MusicKit

@MainActor
final class MusicSession: ObservableObject {
    typealias SeekTarget = PlaybackCheckpoint.SeekTarget
    @Published private(set) var snapshot = PlaybackSnapshot()
    @Published private(set) var status = "Connect Apple Music to begin." {
        didSet { updateFooter() }
    }
    @Published private(set) var queueStatus = "No saved queue."
    @Published private(set) var canRestore = false
    @Published private(set) var skipped: [String] = []
    @Published private(set) var skippedRows: [SkippedRow] = []
    @Published private(set) var footer: FooterState = {
        var input = FooterInput()
        input.playbackEnabled = AppConfiguration.current.playbackEnabled
        input.site = AppConfiguration.current.websiteName
        input.authorized = false
        return .make(input)
    }()
    @Published private(set) var authorized = false
    @Published private(set) var preparing = false

    var intendedPlaying: Bool {
        desiredPlaying ?? journal.pendingReplacement?.intendedPlaying ?? journal.current?.intendedPlaying ?? false
    }

    var canPausePreparation: Bool {
        active && playbackEnabled && authorized && (preparing || nativeBusy) && intendedPlaying
    }

    var seekTarget: SeekTarget? { snapshot.synchronized ? verifiedSeekTarget() : nil }

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let resolver = CatalogResolver.shared
    private let store = PlaybackCheckpointStore()
    private let ownership = SharedPlaybackOwnership()
    private var sharedRecord: SharedPlaybackOwnership.Record?
    private var sharedBusy = false
    private var nativeLease: SharedPlaybackOwnership.Lease?
    private var nativeMutationIssued = false
    private var nativeNeedsObservation = false
    private var nativeObservation: (@MainActor () -> Bool)?
    private var nativeCallbackOutstanding = false
    private var lastSharedRefresh = Date.distantPast
    private var lastQuarantineSettlement = Date.distantPast
    private var journal = PlaybackJournal()
    private var loading: Task<PlaybackJournal?, Never>?
    private var loaded = false
    private var active = false
    private var generation = UUID()
    private var observation: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var selection: Task<Void, Never>?
    private var resolutionFailure: (revision: UUID, kind: RetryClass)?
    private var requestRetry: (attempt: Int, limit: Int)?
    private var automaticResume: Task<Void, Never>?
    private var resumeAttempt = 0
    private var noMatchUntil: Date?
    private var problem: String? {
        didSet { updateFooter() }
    }
    // Includes the real native callback, even after the caller's visible deadline.
    private var playerOperation: Task<Void, Never>?
    private var nativeBusy = false
    private var firstSelection: Completion?
    private var commandTasks: [String: Task<PlaybackOutcome, Never>] = [:]
    private var commandFinished: [String: Date] = [:]
    private var selectionCommands: [UUID: String] = [:]
    private var lastPersistedAt = Date.distantPast
    private var lastOwned: (index: Int, position: Double, duration: Double, date: Date)?
    private var playerReading: PlaybackNativeObservation?
    private var playerReadingIsStable = true
    private var playerSettled = false
    private var settlingReading: (value: PlaybackNativeObservation, date: Date)?
    private struct EndCandidate {
        let revision: UUID
        let generation: UUID
        let submittedCount: Int
        let nativeOffset: Int
        let command: UInt64
        let intent: UInt64
        let date: Date
        let intendedPlaying: Bool
    }
    private var endCandidate: EndCandidate?
    private var missingSince: Date?
    private var starvedWhileActive = false
    private var observingEnd = false
    private var continuingSuffix = false
    private var awaitingPlay = false
    private var recoveryAttempted = false
    private var recoveryPending = false
    private var recoveryAwaitingStableMetadata = false
    private var inconsistentNativeObservations: UInt64 = 0
    private var stoppedObservation: (revision: UUID, id: String, index: Int, offset: Int,
                                     target: PlaybackCheckpoint.RecoveryTarget, position: Double, date: Date)?
    private var coldObservationPending = false
    private var intentVersion: UInt64 = 0
    private var commandVersion: UInt64 = 0
    private var desiredPlaying: Bool?
    private var lastDiagnosticState = ""
    private var queueProbeSubscriptions: [AnyCancellable] = []
    private var queueProbeSignals = 0
    private var queueProbeStateSignals = 0
    private var queueProbePrevious: (id: String?, index: Int, occurrence: Int?, revision: UUID?)?


    @MainActor
    private final class Completion {
        var result: PlaybackOutcome?
        var expired = false
        private var waiters: [CheckedContinuation<PlaybackOutcome, Never>] = []
        func finish(_ value: PlaybackOutcome) {
            guard result == nil else { return }
            result = value
            waiters.forEach { $0.resume(returning: value) }
            waiters.removeAll()
        }
        func value() async -> PlaybackOutcome {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }

    func authorize() async {
        let started = Date()
        stage("authorization", phase: "begin")
        let result = await MusicAuthorization.request()
        guard result == .authorized, MusicAuthorization.currentStatus == .authorized else {
            authorized = false
            status = "Allow music access in Settings to connect Apple Music."
            stage("authorization", phase: "end", started: started, outcome: "error")
            refresh()
            return
        }
        do {
            let subscription = try await MusicSubscription.current
            authorized = MusicAuthorization.currentStatus == .authorized && subscription.canPlayCatalogContent
            if !preparing {
                status = authorized ? "Apple Music is ready. Keep Autoplay (∞) off in Music."
                    : "An active Apple Music subscription is needed."
            }
        } catch {
            authorized = false
            status = "Could not check Apple Music access. \(diagnosticCode(error))"
        }
        stage("authorization", phase: "end", started: started, outcome: authorized ? "success" : "error")
        refresh()
        if authorized { resumeMatchingIfUseful() }
    }

    func playReferenceQueue() async {
        await select([
            SourceTrack(id: "reference-billie-jean", title: "Billie Jean", artist: "Michael Jackson", duration: 294),
            SourceTrack(id: "reference-dreams", title: "Dreams", artist: "Fleetwood Mac", duration: 257),
            SourceTrack(id: "reference-around-the-world", title: "Around the World", artist: "Daft Punk", duration: 429)
        ])
    }

    @discardableResult
    func select(_ tracks: [SourceTrack], context: SourceContext? = nil, commandID: String? = nil) async -> PlaybackOutcome {
        let id = commandID ?? opaqueID(UUID())
        let batchRevision = UUID()
        return await deduplicated(id) { [self] in
            await ensureLoaded()
            func done(_ result: PlaybackOutcome) -> PlaybackOutcome {
                var fields = ["phase": result.status == .completed ? "completed" : "rejected",
                    "trackCount": String(tracks.count), "commandId": id, "selectionId": opaqueID(batchRevision)]
                switch result.reason {
                case .inactive: fields["reason"] = "inactive"
                case .unauthorized: fields["reason"] = "unauthorized"
                case .invalidSelection: fields["reason"] = "invalid"
                case .noMatch: fields["reason"] = "no_matches"
                default: break
                }
                if result.status == .rejected {
                    if !result.skipReasons.isEmpty { fields["skipReasons"] = result.skipReasons.joined(separator: ",") }
                    fields["thirdPartyEditCount"] = String(result.skipReasons.filter { $0 == MatchSkipReason.thirdPartyEdit.rawValue }.count)
                }
                if let explicit = tracks.first?.isExplicit { fields["sourceIsExplicit"] = String(explicit) }
                TestDiagnostics.record("native.selection", fields: fields)
                return result
            }
            TestDiagnostics.record("native.selection", fields: ["phase": "received", "trackCount": String(tracks.count), "commandId": id, "selectionId": opaqueID(batchRevision)])
            guard active, playbackEnabled else { return done(outcome(.inactive)) }
            guard authorized, MusicAuthorization.currentStatus == .authorized else { return done(outcome(.unauthorized)) }
            guard valid(tracks), context.map({ $0.isValid && $0.provider == AppConfiguration.current.provider && $0.selectedSourceID == tracks.first?.id }) ?? true else {
                status = "The website did not provide a usable song batch. Select a song again."
                return done(outcome(.invalidSelection))
            }
            invalidateSelection()
            problem = nil
            noMatchUntil = nil
            generation = batchRevision
            let token = generation
            if selectionCommands.count >= 128 { selectionCommands.removeAll(keepingCapacity: true) }
            selectionCommands[token] = id
            var pending = PlaybackCheckpoint(sources: tracks, context: context, country: "")
            pending.revision = token
            pending.commandID = id
            journal.pendingReplacement = pending
            journal.clearPending = false
            journal.clearRequestID = nil
            journal.clearOwners = nil
            skipped = []
            preparing = true
            awaitingPlay = false
            starvedWhileActive = false
            recoveryAttempted = false
            status = "Finding the first matching song…"
            let completion = Completion()
            firstSelection = completion
            do { try await persist() } catch { return done(storageFailure(error, completion: completion, generation: token)) }
            guard generation == token else { return done(outcome(.cancelled)) }
            beginResolution(revision: token, base: 0)
            return done(await completion.value())
        }
    }

    @discardableResult
    func command(_ command: PlaybackCommand, commandID: String? = nil,
                 expectedSeekTarget: SeekTarget? = nil) async -> PlaybackOutcome {
        await deduplicated(commandID, name: commandName(command)) { [self] in
            await ensureLoaded()
            guard active, playbackEnabled else { return outcome(.inactive) }
            guard authorized else { return outcome(.unauthorized) }
            refresh()
            commandVersion &+= 1
            let intent: UInt64?
            switch command {
            case .play, .pause:
                intentVersion &+= 1
                intent = intentVersion
                desiredPlaying = command == .play
            default: intent = nil
            }
            defer {
                if let intent, intentVersion == intent { desiredPlaying = nil; captureProgress(force: true) }
            }
            // Pause interrupts preparation: save intent before its uncancelable callback.
            if case .pause = command {
                automaticResume?.cancel()
                automaticResume = nil
                guard currentIndex() != nil || preparing || nativeBusy || starvedWhileActive || observingEnd ||
                    journal.current?.terminal == .active else { return outcome(.unmappedQueue) }
                journal.current?.intendedPlaying = false
                journal.pendingReplacement?.intendedPlaying = false
                if starvedWhileActive || observingEnd {
                    let submittedCount = journal.current?.submittedCount ?? 0
                    journal.current?.cursor = submittedCount
                    journal.current?.position = 0
                    awaitingPlay = true
                }
                starvedWhileActive = false
                do { try await persist() } catch { return storageFailure(error) }
                guard intent == intentVersion else { return outcome(.cancelled) }
                if nativeLease != nil {
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    player.pause()
                    return await observe(generation, intent: intent) { self.nativeRawState != 1 }
                }
                let token = generation
                return await serialized(token) { [self] ticket in
                    guard intent == intentVersion else { return outcome(.cancelled) }
                    guard currentIndex() != nil else { return outcome(.unmappedQueue) }
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    player.pause()
                    return await observe(token, ticket: ticket, intent: intent) { self.nativeRawState != 1 }
                }
            }
            if case .play = command, preparing, journal.pendingReplacement != nil {
                journal.pendingReplacement?.intendedPlaying = true
                do { try await persist() } catch { return storageFailure(error) }
                return await observe(generation, seconds: 10, intent: intent) { self.currentIndex() != nil && self.nativeRawState == 1 }
            }
            if case .play = command, currentIndex() == nil {
                guard player.nowPlayingItem == nil || ((observingEnd || awaitingPlay) && ownedNativeIndex() != nil) else { return outcome(.foreignPlayback) }
                return await restore(automatic: false)
            }
            guard currentIndex() != nil else {
                status = "Music changed. Select a song or restore the saved queue."
                return outcome(.unmappedQueue)
            }
            let token = generation
            return await serialized(token) { [self] ticket in
                guard let index = currentIndex(), var current = journal.current else { return outcome(.unmappedQueue) }
                switch command {
                case .play:
                    guard intent == intentVersion else { return outcome(.cancelled) }
                    current.intendedPlaying = true
                    current.terminal = .active
                    journal.current = current
                    do { try await persist() } catch { return storageFailure(error) }
                    guard intent == intentVersion, isCurrent(token) else { return outcome(.cancelled) }
                    guard currentIndex() == index else { return outcome(.foreignPlayback) }
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    player.play()
                    return await observe(token, ticket: ticket, intent: intent) { self.nativeRawState == 1 && self.currentIndex() == index }
                case .pause: return outcome(.cancelled)
                case .next:
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    if index + 1 >= current.submittedCount {
                        journal.current?.intendedPlaying = false
                        player.pause()
                        persistLater()
                        status = current.resolutionComplete ? "The prepared queue has ended." : "Finding the next song…"
                        let result = await observe(token, ticket: ticket) { self.nativeRawState != 1 }
                        return result.status == .completed ? outcome(.nativeNoChange) : result
                    }
                    player.skipToNextItem()
                    return await observeTransport(.next, from: index, token: token, ticket: ticket)
                case .previous:
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    if index > current.nativeOffset {
                        player.skipToPreviousItem()
                        return await observeTransport(.previous, from: index, token: token, ticket: ticket)
                    }
                    player.skipToBeginning()
                    return await observeTransport(.previous, from: index, token: token, ticket: ticket)
                case .seek(let seconds):
                    guard seconds.isFinite, seconds >= 0, snapshot.duration > 0 else { return outcome(.invalidSelection) }
                    let destination = min(seconds, max(0, snapshot.duration - 0.25))
                    if let expectedSeekTarget {
                        guard let verified = verifiedSeekTarget(), verified == expectedSeekTarget,
                              verified.occurrence == index else { return outcome(.foreignPlayback) }
                    }
                    do { try markNativeMutation(observationRequired: true) }
                    catch { return ownershipFailure(error) }
                    player.currentPlaybackTime = destination
                    let result = await observe(token, ticket: ticket) {
                        self.currentIndex() == index && abs(self.position - destination) < 1.5
                    }
                    captureProgress(force: true)
                    return result
                }
            }
        }
    }

    @discardableResult
    func restoreSavedQueue() async -> PlaybackOutcome {
        await deduplicated(nil, name: "restore") { [self] in
            await ensureLoaded()
            problem = nil
            noMatchUntil = nil
            return await restore(automatic: false, userTakeover: true)
        }
    }

    @discardableResult
    func clearQueue() async -> PlaybackOutcome {
        await deduplicated(nil, name: "clear") { [self] in
            await ensureLoaded()
            guard active, playbackEnabled else { return outcome(.inactive) }
            invalidateSelection()
            problem = nil
            noMatchUntil = nil
            intentVersion &+= 1
            desiredPlaying = false
            let token = generation
            journal.clearOwners = [journal.current, journal.pendingReplacement].compactMap { $0.map(PlaybackQueueIdentity.init) }
            journal.current = journal.current ?? journal.pendingReplacement
            journal.pendingReplacement = nil
            journal.clearPending = true
            journal.clearRequestID = token
            journal.current?.terminal = .cleared
            journal.current?.intendedPlaying = false
            awaitingPlay = false
            starvedWhileActive = false
            preparing = false
            // The shared Clear tombstone is also written before Music is touched.
            do { try await persist() }
            catch {
                guard generation == token else { return outcome(.cancelled) }
                do { try await store.remove(ifNotNewerThan: journal.sequence) }
                catch {
                    status = "Music stopped; its saved state remains. Its old recovery state could not be invalidated."
                    problem = status
                }
            }
            guard generation == token else { return outcome(.cancelled) }
            logQueue("clear_requested", count: 0)
            status = "Clearing Music’s queue…"
            return await finishClear(token)
        }
    }

    func retryMatching() async {
        guard selection == nil, active, authorized, playbackEnabled, !nativeBusy, problem == nil else { return }
        automaticResume?.cancel()
        automaticResume = nil
        resumeAttempt = 0
        if let failure = resolutionFailure, let checkpoint = checkpoint(failure.revision) {
            if journal.pendingReplacement?.revision == checkpoint.revision, checkpoint.submittedCount == 0 {
                var pending = checkpoint
                pending.entries = []
                pending.skipReasons = nil
                pending.processedCount = 0
                pending.resolutionComplete = false
                setCheckpoint(pending)
                let token = generation
                do { try await persist() } catch { _ = storageFailure(error, generation: token); return }
                guard isCurrent(token), journal.pendingReplacement?.revision == pending.revision else { return }
                resolutionFailure = nil
                preparing = true
                beginResolution(revision: pending.revision, base: 0)
            } else if failure.kind != .never, mayRetryResolution(checkpoint) {
                resolutionFailure = nil
                beginResolution(revision: checkpoint.revision, base: checkpoint.processedCount)
            }
        } else {
            await retrySkipped()
        }
        updateFooter()
    }

    var retryableSkippedCount: Int {
        guard selection == nil, active, authorized, playbackEnabled, !nativeBusy, problem == nil,
              journal.pendingReplacement == nil, let checkpoint = journal.current,
              checkpoint.terminal == .active, ownsSharedQueue(checkpoint), currentIndex() != nil,
              checkpoint.resolutionComplete, checkpoint.pendingAppendEnd == nil,
              checkpoint.entries.count == checkpoint.submittedCount else { return 0 }
        return min(10 - (checkpoint.retryOf?.count ?? 0), checkpoint.retryableRoots.count)
    }

    func retrySkipped() async {
        guard retryableSkippedCount > 0, var checkpoint = journal.current else { return }
        let roots = Array(checkpoint.retryableRoots.prefix(10 - (checkpoint.retryOf?.count ?? 0)))
        guard !roots.isEmpty else { return }
        automaticResume?.cancel()
        automaticResume = nil
        resumeAttempt = 0
        let base = checkpoint.processedCount
        var retries = checkpoint.retryOf ?? [:]
        for root in roots {
            retries[checkpoint.sources.count] = root
            checkpoint.sources.append(checkpoint.sources[root])
        }
        checkpoint.retryOf = retries
        checkpoint.resolutionComplete = false
        journal.current = checkpoint
        let token = generation
        do { try await persist() } catch { _ = storageFailure(error, generation: token); return }
        guard isCurrent(token), journal.current?.revision == checkpoint.revision else { return }
        resolutionFailure = nil
        beginResolution(revision: checkpoint.revision, base: base)
        updateFooter()
    }

    private func mayRetryResolution(_ checkpoint: PlaybackCheckpoint) -> Bool {
        journal.pendingReplacement == nil && checkpoint.terminal == .active && ownsSharedQueue(checkpoint) &&
            checkpoint.pendingAppendEnd == nil && !checkpoint.resolutionComplete &&
            checkpoint.processedCount < checkpoint.sources.count &&
            (player.nowPlayingItem == nil || currentIndex() != nil || ((observingEnd || awaitingPlay) && ownedNativeIndex() != nil))
    }

    private func scheduleMatchingResume(batch: UUID, token: UUID) {
        guard automaticResume == nil, resumeAttempt < RetryPolicy.resumeDelays.count,
              let checkpoint = checkpoint(batch), checkpoint.intendedPlaying, problem == nil,
              resolutionFailure?.kind != .never, mayRetryResolution(checkpoint) else { return }
        let delay = RetryPolicy.resumeDelays[resumeAttempt]
        resumeAttempt += 1
        automaticResume = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.automaticResume = nil
            guard self.isCurrent(token), self.selection == nil, !self.nativeBusy, self.problem == nil,
                  self.resolutionFailure?.revision == batch,
                  let checkpoint = self.checkpoint(batch), checkpoint.intendedPlaying,
                  self.mayRetryResolution(checkpoint) else { return }
            self.resolutionFailure = nil
            self.beginResolution(revision: batch, base: checkpoint.processedCount)
        }
    }

    func resume() {
        if SharedPlaybackOwnership.runLaunchProbeIfRequested() { return }
        guard !active else { refresh(); return }
        active = true
        recoveryAttempted = false
        stoppedObservation = nil
        missingSince = nil
        starvedWhileActive = false
        observingEnd = false
        lastOwned = nil
        endCandidate = nil
        playerSettled = false
        settlingReading = nil
        coldObservationPending = true
        player.beginGeneratingPlaybackNotifications()
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.recordQueueProbe(trigger: name == .MPMusicPlayerControllerNowPlayingItemDidChange ? "itemNotification" : "stateNotification")
                    self?.refresh()
                }
            })
        }
        TestDiagnostics.record("native.lifecycle", fields: ["phase": "resume", "active": "true", "preparing": String(preparing), "queueCount": String(journal.current?.submittedCount ?? 0)])
        observation = Task { [weak self] in
            guard let self else { return }
            await self.ensureLoaded()
            guard self.active else { return }
            if MusicAuthorization.currentStatus == .authorized { await self.authorize() }
            if self.playbackEnabled, self.journal.clearPending == true {
                _ = await self.finishClear(self.generation, preserveForeign: true)
            }
            self.refresh()
            self.resumeMatchingIfUseful()
            while !Task.isCancelled, self.active {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self.refresh()
            }
        }
    }

    func suspend() {
        guard active else { return }
        refresh()
        captureProgress(force: true)
        TestDiagnostics.record("native.lifecycle", fields: ["phase": "suspend", "active": "false", "preparing": String(preparing), "queueCount": String(journal.current?.submittedCount ?? 0)])
        active = false
        observation?.cancel()
        observation = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        player.endGeneratingPlaybackNotifications()
        invalidateSelection()
        preparing = false
        publishSnapshot(synchronized: false)
    }

    private func beginResolution(revision batch: UUID, base: Int) {
        guard selection == nil, active, playbackEnabled,
              let checkpoint = checkpoint(batch), (0..<checkpoint.sources.count).contains(base) else { return }
        requestRetry = nil
        selection = Task { [weak self] in
            guard let self else { return }
            let token = self.generation
            var searchStarted = Date()
            do {
                guard var checkpoint = self.checkpoint(batch) else { return }
                if checkpoint.country.isEmpty {
                    self.stage("region", phase: "begin", batch: batch)
                    let country = try await MusicDataRequest.currentCountryCode
                    try self.requireCurrent(token)
                    guard country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                        throw NSError(domain: "AppleCatalogRegion", code: 1)
                    }
                    checkpoint.country = country
                    self.setCheckpoint(checkpoint)
                    self.stage("region", phase: "end", started: searchStarted, batch: batch)
                }
                let remaining = Array(checkpoint.sources.dropFirst(base))
                let context = self.context(checkpoint.context, for: remaining.first, base: checkpoint.retryOf?[base] ?? base)
                searchStarted = Date()
                self.stage("catalog_search", phase: "begin", batch: batch)
                _ = try await self.resolver.resolve(tracks: remaining, context: context, country: checkpoint.country,
                    onRetry: { [weak self] attempt, limit in
                        await self?.catalogRetry(attempt: attempt, limit: limit, token: token, batch: batch)
                    }, onProgress: { [weak self] prefix in
                        await self?.accept(prefix, base: base, batch: batch, generation: token)
                    })
                try self.requireCurrent(token)
                if var finished = self.checkpoint(batch) {
                    finished.resolutionComplete = true
                    if self.starvedWhileActive, finished.entries.count == finished.submittedCount {
                        finished.terminal = .completed
                        finished.intendedPlaying = false
                        self.starvedWhileActive = false
                        self.status = "The prepared queue has finished."
                        self.logQueue("completed", count: finished.submittedCount)
                    }
                    self.setCheckpoint(finished)
                    if finished.entries.isEmpty {
                        self.journal.pendingReplacement = nil
                        self.noMatchUntil = Date().addingTimeInterval(10)
                        let ordered = (finished.skipReasons ?? [:]).sorted { $0.key < $1.key }
                        let reason = ordered.first?.value
                        let skipReasons = ordered.map { $0.value.rawValue }
                        let preserved = self.journal.current == nil ? "Your current music is unchanged."
                            : "Your previous batch and its skipped-song report are unchanged."
                        self.status = "No confident match for the new selection. \(self.skipExplanation(reason)) \(preserved)"
                        self.finishSelection(self.outcome(.noMatch, skipReasons: skipReasons))
                    }
                    do { try await self.persist() }
                    catch { _ = self.storageFailure(error); throw CancellationError() }
                }
                self.resolutionFailure = nil
                self.resumeAttempt = 0
                self.stage("catalog_search", phase: "end", started: searchStarted, batch: batch)
            } catch is CancellationError {
                if self.generation == token { self.finishSelection(self.outcome(.cancelled)) }
                self.stage("catalog_search", phase: "end", started: searchStarted, outcome: "cancelled", batch: batch)
            } catch {
                guard self.generation == token else { return }
                self.resolutionFailure = (batch, RetryPolicy.classify(error))
                self.status = "Matching paused. The prepared songs remain available. \(self.diagnosticCode(error))"
                self.scheduleMatchingResume(batch: batch, token: token)
                self.finishSelection(self.outcome(.nativeFailure))
                self.stage("catalog_search", phase: "end", started: searchStarted, outcome: "error", batch: batch)
            }
            if self.generation == token {
                self.selection = nil
                self.requestRetry = nil
                self.preparing = false
                self.refresh()
            }
        }
    }

    private func catalogRetry(attempt: Int, limit: Int, token: UUID, batch: UUID) {
        guard isCurrent(token), checkpoint(batch) != nil else { return }
        requestRetry = attempt > 0 ? (attempt, limit) : nil
        if attempt > 0 { stage("catalog_search", phase: "retry", batch: batch) }
        updateFooter()
    }

    private func finishClear(_ token: UUID, preserveForeign: Bool = false) async -> PlaybackOutcome {
        let requestID = journal.clearRequestID ?? token
        journal.clearRequestID = requestID
        return await serialized(token, mustRun: true, mode: .clear(takeover: !preserveForeign),
                                revision: journal.current?.revision ?? token, userTakeover: !preserveForeign) { [self] ticket in
            guard journal.clearPending == true, journal.clearRequestID == requestID else { return outcome(.cancelled) }
            let requestOwners = journal.clearOwners ?? journal.current.map { [PlaybackQueueIdentity($0)] } ?? []
            let matchesClearOwner: @MainActor () -> Bool = { [self] in
                (!nativeItemPresent && nativeRawState == 0) || requestOwners.contains {
                    $0.contains(catalogID: nativeCatalogID, nativeIndex: nativeIndex)
                }
            }
            guard !preserveForeign || confirmsNativeObservation(matchesClearOwner) else {
                if let failure = await settleClearReceipt(requestID, generation: token) { return failure }
                guard generation == token else { return outcome(.cancelled) }
                return outcome(.foreignPlayback)
            }
            let musicKitPlayer = SystemMusicPlayer.shared
            let originalEntry = musicKitPlayer.queue.currentEntry
            let originalEntryID: String?
            if let originalEntry, case .song(let song)? = originalEntry.item,
               confirmsNativeObservation({ song.id.rawValue == nativeCatalogID && matchesClearOwner() }) {
                originalEntryID = originalEntry.id
            } else { originalEntryID = nil }
            let mayMutateMusicKitQueue = { [self] in
                confirmsNativeObservation {
                    guard matchesClearOwner() else { return false }
                    guard let entry = musicKitPlayer.queue.currentEntry else { return true }
                    return originalEntryID == entry.id
                }
            }
            do { try markNativeMutation() }
            catch { return ownershipFailure(error) }
            player.stop()
            let query = MPMediaQuery(filterPredicates: [
                MPMediaPropertyPredicate(value: NSNumber(value: 0), forProperty: MPMediaItemPropertyPersistentID),
                MPMediaPropertyPredicate(value: NSNumber(value: 1), forProperty: MPMediaItemPropertyPersistentID)
            ])
            // Contradictory AND predicates give the public library API an empty source.
            guard query.items?.isEmpty != false else {
                if let failure = await settleClearReceipt(requestID, generation: token) { return failure }
                guard generation == token else { return outcome(.cancelled) }
                status = "The saved batch is cleared and Music has stopped. The empty queue request could not be safely formed."
                return outcome(.nativeFailure)
            }
            player.setQueue(with: MPMusicPlayerMediaItemQueueDescriptor(query: query))
            let started = Date()
            let batch = journal.current?.revision ?? token
            stage("prepare_queue", phase: "begin", batch: batch)
            var preparationError: Error?
            do { try await prepareNative() }
            catch { preparationError = error }
            stage("prepare_queue", phase: "end", started: started,
                  outcome: preparationError == nil ? "success" : "error", batch: batch, error: preparationError)
            var fallbackError: Error?
            if generation == token, active, !ticket.expired,
               journal.clearPending == true, journal.clearRequestID == requestID {
                guard mayMutateMusicKitQueue() else {
                    if let failure = await settleClearReceipt(requestID, generation: token) { return failure }
                    guard generation == token else { return outcome(.cancelled) }
                    status = "The saved batch is cleared. Music’s queue ownership changed or could not be confirmed, so its current queue was preserved."
                    return outcome(.foreignPlayback)
                }
                status = "Trying Music’s empty queue request…"
                do { try markNativeMutation(callbackOutstanding: true) }
                catch { return ownershipFailure(error) }
                musicKitPlayer.stop()
                musicKitPlayer.queue = []
                let fallbackStarted = Date()
                stage("prepare_queue", phase: "begin", batch: batch)
                nativeCallbackOutstanding = true
                do { try await musicKitPlayer.prepareToPlay() }
                catch { fallbackError = error }
                nativeCallbackOutstanding = false
                if let lease = nativeLease { try? ownership.markNativeRequest(lease) }
                stage("prepare_queue", phase: "end", started: fallbackStarted,
                      outcome: fallbackError == nil ? "success" : "error", batch: batch, error: fallbackError)
            }
            // The callback receipt settles this request even if the app suspended or timed out.
            // A newer Clear/selection has a different identity and must remain untouched.
            if let failure = await settleClearReceipt(requestID, generation: token) { return failure }
            guard generation == token, active else { return outcome(.cancelled) }
            guard !ticket.expired else { return outcome(.timedOut) }
            guard mayMutateMusicKitQueue() else {
                status = "The saved batch is cleared. Music changed during the request, so its current queue was preserved."
                return outcome(.foreignPlayback)
            }
            do { try markNativeMutation() }
            catch { return ownershipFailure(error) }
            musicKitPlayer.stop()
            // A callback applies the request; a local nil immediately after setQueue does not.
            // shortcut: system MediaPlayer cannot enumerate Up Next; never infer full clearing from cached nil.
            let clock = ContinuousClock()
            let settling = clock.now.advanced(by: .seconds(2))
            repeat {
                guard generation == token, active else { return outcome(.cancelled) }
                guard !ticket.expired else { return outcome(.timedOut) }
                refresh()
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return outcome(.cancelled) }
            } while clock.now < settling
            guard confirmsNativeObservation(matchesClearOwner) else {
                status = "The saved batch is cleared. Music changed during the request, so its current queue was preserved."
                return outcome(.foreignPlayback)
            }
            let detail = (fallbackError ?? preparationError).map { " \(diagnosticCode($0))" } ?? ""
            status = "The saved batch is cleared. Music’s remaining queue could not be confirmed empty.\(detail)"
            return outcome(.nativeFailure)
        }
    }

    private func settleClearReceipt(_ requestID: UUID, generation token: UUID) async -> PlaybackOutcome? {
        guard journal.settleClear(requestID: requestID) else { return nil }
        do { try await persist() }
        catch {
            guard journal.clearRequestID == requestID, journal.pendingReplacement == nil else { return outcome(.cancelled) }
            do { try await store.remove(ifNotNewerThan: journal.sequence) }
            catch {
                if generation == token {
                    status = "The saved Clear could not be recorded. It could not be invalidated either and may retry when reopened."
                    problem = status
                }
                return outcome(.nativeFailure)
            }
            if generation == token { return storageFailure(error, generation: token) }
        }
        return nil
    }

    private func accept(_ prefix: [MatchAssessment], base: Int, batch: UUID, generation token: UUID) async {
        guard isCurrent(token), var checkpoint = checkpoint(batch), base >= 0,
              base + prefix.count <= checkpoint.sources.count else { return }
        requestRetry = nil
        checkpoint.entries.removeAll { $0.sourceOrdinal >= base }
        var reasons = checkpoint.skipReasons?.filter { $0.key < base } ?? [:]
        for (offset, assessment) in prefix.enumerated() {
            let ordinal = base + offset
            if let decision = assessment.decision {
                checkpoint.entries.append(PlaybackOccurrence(sourceOrdinal: ordinal, source: checkpoint.sources[ordinal], match: decision))
            } else if let reason = assessment.skipReason {
                reasons[ordinal] = reason
            }
        }
        checkpoint.processedCount = base + prefix.count
        checkpoint.skipReasons = reasons
        setCheckpoint(checkpoint)
        updateQueueStatus()
        do { try await persist() }
        catch {
            guard generation == token else { return }
            finishSelection(storageFailure(error))
            selection?.cancel()
            return
        }
        guard isCurrent(token) else { return }
        guard let latest = self.checkpoint(batch) else { return }
        checkpoint = latest
        guard !checkpoint.entries.isEmpty else { return }
        if journal.pendingReplacement?.revision == batch {
            let result = await replace(checkpoint, start: 0, userTakeover: firstSelection != nil, token: token)
            guard generation == token else { return }
            finishSelection(result)
            if result.status == .rejected { selection?.cancel() }
        } else if checkpoint.entries.count > checkpoint.submittedCount, checkpoint.pendingAppendEnd == nil {
            if starvedWhileActive {
                guard !continuingSuffix else { return }
                continuingSuffix = true
                var suffix = checkpoint
                suffix.cursor = checkpoint.submittedCount
                suffix.position = 0
                let result = await replace(suffix, start: suffix.cursor, ownedOnly: true, token: token)
                finishSuffixAttempt(result, token: token)
            } else if currentIndex() != nil {
                _ = await appendTail(batch: batch, token: token)
            }
        }
        refresh()
    }

    private func replace(_ checkpoint: PlaybackCheckpoint, start: Int, end: Int? = nil, requireEmpty: Bool = false,
                         ownedOnly: Bool = false, userTakeover: Bool = false,
                         automaticCommandVersion: UInt64? = nil, token: UUID) async -> PlaybackOutcome {
        guard checkpoint.entries.indices.contains(start) else { return outcome(.noMatch) }
        let requestedIntentVersion = intentVersion
        let mayReplaceAutomatically = { [self] in
            let first = readNativePlayer()
            let second = readNativePlayer()
            return first.agrees(with: second) &&
                (automaticCommandVersion == nil || commandVersion == automaticCommandVersion) && desiredPlaying != false &&
            checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: second.itemPresent,
                nativeStopped: second.rawState == 0,
                latestPlayingIntent: journal.current?.revision == checkpoint.revision && journal.current?.intendedPlaying == true &&
                    journal.pendingReplacement?.intendedPlaying != false, at: Date())
        }
        let mayContinueOwnedSuffix = { [self] in
            let first = readNativePlayer()
            let second = readNativePlayer()
            guard first.agrees(with: second), second.rawState == 0 || second.rawState == 2,
                  let current = journal.current, current.revision == checkpoint.revision,
                  current.intendedPlaying, desiredPlaying != false, ownsSharedQueue(current) else { return false }
            return current.isSubmittedEndReset(catalogID: second.catalogID, nativeIndex: second.nativeIndex, position: second.position)
        }
        return await serialized(token, mode: requireEmpty || ownedOnly ? .ownedMutation : .replacement,
                                revision: checkpoint.revision, userTakeover: userTakeover) { [self] ticket in
            defer { if generation == token { preparing = false } }
            guard checkpoint.entries.indices.contains(start) else { return outcome(.noMatch) }
            guard !requireEmpty || mayReplaceAutomatically() else { return outcome(.foreignPlayback) }
            guard !ownedOnly || mayContinueOwnedSuffix() else { return outcome(.foreignPlayback) }
            var candidate = checkpoint
            if let latest = self.checkpoint(checkpoint.revision) {
                candidate.entries = latest.entries
                candidate.processedCount = latest.processedCount
                candidate.skipReasons = latest.skipReasons
                candidate.resolutionComplete = latest.resolutionComplete
                if intentVersion != requestedIntentVersion {
                    candidate.intendedPlaying = desiredPlaying ?? latest.intendedPlaying
                }
            }
            candidate.nativeOffset = start
            candidate.cursor = start
            candidate.submittedCount = end ?? candidate.entries.count
            candidate.pendingAppendEnd = nil
            candidate.terminal = .active
            candidate.legacy = false
            candidate.observedAt = Date()
            // Preserve the previous successful queue until the replacement is observed.
            journal.pendingReplacement = candidate
            journal.clearPending = false
            journal.clearRequestID = nil
            journal.clearOwners = nil
            do { try await persist() } catch { return storageFailure(error, generation: token) }
            guard isCurrent(token), !ticket.expired else { return outcome(.cancelled) }
            if (requireEmpty && !mayReplaceAutomatically()) || (ownedOnly && !mayContinueOwnedSuffix()) {
                journal.pendingReplacement = nil
                try? await persist()
                return outcome(.foreignPlayback)
            }
            logQueue("replacement_requested", count: candidate.submittedCount - start, batch: candidate.revision)
            do { try markNativeMutation() }
            catch { return ownershipFailure(error) }
            if requireEmpty { recoveryAttempted = true }
            player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: candidate.entries[start..<candidate.submittedCount].map { $0.match.track.id }))
            player.repeatMode = .none
            player.shuffleMode = .off
            preparing = true
            status = "Preparing Music…"
            let started = Date()
            stage("prepare_queue", phase: "begin", batch: candidate.revision)
            do {
                // At most one retry, only after the previous native callback actually returns.
                for attempt in 0...1 {
                    do { try await prepareNative(); break }
                    catch { guard attempt == 0, isCurrent(token), !ticket.expired else { throw error } }
                }
                try requireCurrent(token)
                guard !ticket.expired else { return outcome(.timedOut) }
                guard let latest = journal.pendingReplacement, latest.revision == candidate.revision else { return outcome(.cancelled) }
                candidate.intendedPlaying = latest.intendedPlaying
                stage("prepare_queue", phase: "end", started: started, batch: candidate.revision)
                let prepared = candidate
                let mapped = await observe(token, ticket: ticket) {
                    prepared.occurrence(catalogID: self.nativeCatalogID,
                                        nativeIndex: self.nativeIndex) == start
                }
                guard mapped.status == .completed, isCurrent(token), !ticket.expired else {
                    return outcome(player.nowPlayingItem == nil ? .timedOut : .foreignPlayback)
                }
                if requireEmpty, !checkpoint.mayAutomaticallyRestore(at: Date()) {
                    journal.pendingReplacement = nil
                    journal.current?.cursor = checkpoint.submittedCount
                    journal.current?.position = 0
                    journal.current?.intendedPlaying = false
                    awaitingPlay = true
                    try? await persist()
                    guard isCurrent(token) else { return outcome(.cancelled) }
                    status = "The saved prefix may have ended. Tap Play or Restore to continue."
                    return outcome(.awaitingNext)
                }
                candidate.intendedPlaying = journal.pendingReplacement?.intendedPlaying ?? false
                if candidate.position > 0 {
                    try markNativeMutation()
                    player.currentPlaybackTime = candidate.position
                }
                let playbackStarted = Date()
                if candidate.intendedPlaying { stage("play_queue", phase: "begin", batch: candidate.revision) }
                try markNativeMutation(observationRequired: true)
                if candidate.intendedPlaying { player.play() } else { player.pause() }
                let expected = candidate
                let result = await observe(token, ticket: ticket) {
                    let desired = self.journal.pendingReplacement?.intendedPlaying ?? false
                    return expected.occurrence(catalogID: self.nativeCatalogID, nativeIndex: self.nativeIndex) == start &&
                        (desired ? self.nativeRawState == 1 : self.nativeRawState != 1)
                }
                if candidate.intendedPlaying {
                    stage("play_queue", phase: "end", started: playbackStarted,
                          outcome: result.status == .completed ? "success" : "error", batch: candidate.revision)
                }
                guard result.status == .completed, !ticket.expired, isCurrent(token) else { return result }
                if let latest = journal.pendingReplacement, latest.revision == candidate.revision {
                    candidate.intendedPlaying = latest.intendedPlaying
                    candidate.entries = latest.entries
                    candidate.processedCount = latest.processedCount
                    candidate.skipReasons = latest.skipReasons
                    candidate.resolutionComplete = latest.resolutionComplete
                }
                candidate.position = position
                candidate.observedAt = Date()
                journal.current = candidate
                journal.pendingReplacement = nil
                starvedWhileActive = false
                observingEnd = false
                awaitingPlay = false
                preparing = false
                let played = readNativePlayer()
                let confirmed = readNativePlayer()
                lastOwned = played.agrees(with: confirmed) && confirmed.rawState == 1 && confirmed.duration > 0 &&
                    candidate.occurrence(catalogID: confirmed.catalogID, nativeIndex: confirmed.nativeIndex) == start
                    ? (start, confirmed.position, confirmed.duration, Date()) : nil
                do { try await persist() } catch { return storageFailure(error, generation: token) }
                guard isCurrent(token) else { return outcome(.cancelled) }
                status = "Music is \(candidate.intendedPlaying ? "playing" : "paused"). Keep Autoplay (∞) off."
                refresh()
                return outcome()
            } catch is CancellationError { return outcome(.cancelled) }
            catch {
                stage("prepare_queue", phase: "end", started: started, outcome: "error", batch: candidate.revision)
                if generation == token {
                    status = "Music could not prepare the queue. \(diagnosticCode(error))"
                    problem = status
                    preparing = false
                }
                return outcome(.nativeFailure)
            }
        }
    }

    private func appendTail(batch: UUID, token: UUID) async -> PlaybackOutcome {
        let result = await serialized(token) { [self] ticket in
            guard var checkpoint = journal.current, checkpoint.revision == batch,
                  checkpoint.pendingAppendEnd == nil, let index = currentIndex(),
                  checkpoint.entries.count > checkpoint.submittedCount else { return outcome(.unmappedQueue) }
            let end = checkpoint.entries.count
            let beforePosition = position
            checkpoint.pendingAppendEnd = end
            journal.current = checkpoint
            do { try await persist() } catch { return storageFailure(error) }
            guard isCurrent(token), !ticket.expired else { return outcome(.cancelled) }
            guard currentIndex() == index else {
                journal.current?.pendingAppendEnd = nil
                try? await persist()
                return outcome(.foreignPlayback)
            }
            let wasPaused = player.playbackState != .playing || journal.current?.intendedPlaying == false
            logQueue("append_requested", count: end - checkpoint.submittedCount, batch: batch)
            do { try markNativeMutation(observationRequired: true) }
            catch { return ownershipFailure(error) }
            player.append(MPMusicPlayerStoreQueueDescriptor(storeIDs: checkpoint.entries[checkpoint.submittedCount..<end].map { $0.match.track.id }))
            // Up Next cannot be enumerated. A returned append plus unchanged current occurrence
            // is the public API's available confirmation; an interrupted append is never repeated.
            let result = await observe(token, ticket: ticket) {
                self.currentIndex() == index && self.position >= max(0, beforePosition - 1.5) &&
                (!wasPaused || self.nativeRawState != 1)
            }
            guard result.status == .completed, isCurrent(token) else { return result }
            journal.current?.submittedCount = end
            journal.current?.pendingAppendEnd = nil
            do { try await persist() } catch { return storageFailure(error) }
            logQueue("append_returned", count: end, batch: batch)
            return outcome()
        }
        // Progress can settle while a saved append is pending. Drain that later suffix after
        // this writer has returned, rather than depending on another search callback/resume.
        if result.status == .completed, isCurrent(token), let current = journal.current,
           current.revision == batch, current.pendingAppendEnd == nil,
           current.entries.count > current.submittedCount, currentIndex() != nil {
            return await appendTail(batch: batch, token: token)
        }
        return result
    }

    private func restore(automatic: Bool, expectedCommandVersion: UInt64? = nil, userTakeover: Bool = false) async -> PlaybackOutcome {
        guard active, playbackEnabled else { return outcome(.inactive) }
        guard authorized else { return outcome(.unauthorized) }
        guard var checkpoint = journal.current, !checkpoint.entries.isEmpty else { return outcome(.noMatch) }
        guard checkpoint.terminal != .cleared else { return outcome(.cleared) }
        let recoveryCommand = automatic ? expectedCommandVersion ?? commandVersion : nil
        if automatic {
            let first = readNativePlayer()
            let second = readNativePlayer()
            guard commandVersion == recoveryCommand, journal.pendingReplacement == nil, desiredPlaying != false,
                  first.agrees(with: second),
                  checkpoint.mayAutomaticallyRestoreEmptyQueue(itemPresent: second.itemPresent,
                      nativeStopped: second.rawState == 0,
                      latestPlayingIntent: journal.current?.intendedPlaying == true, at: Date()) else { return outcome(.awaitingNext) }
        }
        invalidateSelection()
        let token = generation
        if checkpoint.terminal == .completed { checkpoint.cursor = 0; checkpoint.position = 0 }
        if checkpoint.cursor >= checkpoint.entries.count {
            if !checkpoint.resolutionComplete {
                status = "Finding the next song. Tap Play when it is ready."
                resumeMatchingIfUseful()
                return outcome(.awaitingNext)
            }
            checkpoint.cursor = 0
            checkpoint.position = 0
        }
        desiredPlaying = nil
        checkpoint.intendedPlaying = true
        checkpoint.terminal = .active
        checkpoint.pendingAppendEnd = nil
        logQueue(automatic ? "recovery_started" : "restore_requested", count: checkpoint.entries.count)
        let result = await replace(checkpoint, start: checkpoint.cursor, end: automatic ? checkpoint.submittedCount : nil,
                                   requireEmpty: automatic, userTakeover: !automatic && userTakeover, automaticCommandVersion: recoveryCommand, token: token)
        if result.status == .completed { resumeMatchingIfUseful() }
        return result
    }

    private func resumeMatchingIfUseful() {
        guard active, authorized, playbackEnabled, selection == nil, !nativeBusy,
              journal.current.map(ownsSharedQueue) == true, resolutionFailure == nil, problem == nil else { return }
        if let current = journal.current, current.pendingAppendEnd == nil,
           current.entries.count > current.submittedCount, currentIndex() != nil {
            let token = generation
            Task { [weak self] in _ = await self?.appendTail(batch: current.revision, token: token) }
        }
        // An interrupted, never-confirmed replacement needs an explicit Restore/selection.
        guard journal.pendingReplacement == nil, let checkpoint = journal.current,
              checkpoint.terminal == .active, !checkpoint.resolutionComplete,
              checkpoint.pendingAppendEnd == nil, checkpoint.processedCount < checkpoint.sources.count else { return }
        guard player.nowPlayingItem == nil || currentIndex() != nil || ((observingEnd || awaitingPlay) && ownedNativeIndex() != nil) else { return }
        preparing = checkpoint.submittedCount == 0
        beginResolution(revision: checkpoint.revision, base: checkpoint.processedCount)
    }

    private func serialized(_ token: UUID, mustRun: Bool = false,
                            mode: SharedPlaybackOwnership.Mode = .ownedMutation, revision: UUID? = nil, userTakeover: Bool = false,
                            action: @escaping @MainActor (Completion) async -> PlaybackOutcome) async -> PlaybackOutcome {
        let previous = playerOperation
        let completion = Completion()
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, completion.result == nil else { return }
            completion.expired = true
            if self.generation == token {
                self.preparing = false
                self.status = "Music took too long to respond. Its outstanding preparation must finish before another attempt."
                self.problem = self.status
            }
            completion.finish(self.outcome(.timedOut))
        }
        playerOperation = Task { [self] in
            await previous?.value
            guard playbackEnabled, generation == token, (active || mustRun), (!completion.expired || mustRun),
                  (mustRun || (authorized && MusicAuthorization.currentStatus == .authorized)) else {
                completion.finish(outcome(.cancelled)); deadline.cancel(); return
            }
            let lease: SharedPlaybackOwnership.Lease
            do {
                refreshSharedOwnership(force: true)
                lease = try ownership.begin(operationID: UUID(), revision: revision ?? journal.current?.revision ?? token,
                    mode: mode, expectedFence: sharedRecord?.fence, userTakeover: userTakeover)
                nativeLease = lease
                sharedRecord = try ownership.snapshot()
                sharedBusy = false
                nativeMutationIssued = false
                nativeNeedsObservation = false
                nativeObservation = nil
                nativeCallbackOutstanding = false
            } catch {
                if let lease = nativeLease {
                    try? ownership.cancelBeforeMutation(lease)
                    nativeLease = nil
                }
                completion.finish(ownershipFailure(error)); deadline.cancel(); return
            }
            nativeBusy = true
            let result = await action(completion)
            if nativeNeedsObservation, let predicate = nativeObservation {
                let clock = ContinuousClock()
                let end = clock.now.advanced(by: .seconds(2))
                repeat {
                    if confirmsNativeObservation(predicate) { nativeNeedsObservation = false; break }
                    do { try await Task.sleep(for: .milliseconds(75)) } catch { break }
                } while clock.now < end
            }
            do {
                if !nativeMutationIssued {
                    try ownership.cancelBeforeMutation(lease)
                } else {
                    let first = readNativePlayer()
                    let second = readNativePlayer()
                    if !nativeCallbackOutstanding, first.agrees(with: second),
                       acceptOwnedReading(second, revision: lease.queueRevision) {
                        sharedRecord = try ownership.finish(lease, state: .active)
                    } else if !nativeCallbackOutstanding, first.agrees(with: second), !second.itemPresent, second.rawState == 0 {
                        sharedRecord = try ownership.finish(lease, state: .cleared)
                    } else {
                        try ownership.quarantine(lease, cause: nativeCallbackOutstanding ? .callbackOutstanding : .unobservedTransport)
                        sharedRecord = try ownership.snapshot()
                        status = "Music’s last request is unconfirmed. Its queue has been preserved."
                        problem = status
                    }
                    if sharedRecord?.state != .uncertain,
                       problem == "Music’s last request is unconfirmed. Its queue has been preserved." ||
                       problem == "Music took too long to respond. Its outstanding preparation must finish before another attempt." {
                        problem = nil
                    }
                }
            } catch { _ = ownershipFailure(error) }
            nativeObservation = nil
            nativeNeedsObservation = false
            nativeMutationIssued = false
            nativeLease = nil
            nativeBusy = false
            lastSharedRefresh = .distantPast
            deadline.cancel()
            refresh()
            captureProgress(force: true)
            completion.finish(outcome(result.reason))
        }
        return await completion.value()
    }

    private func prepareNative() async throws {
        try markNativeMutation(callbackOutstanding: true)
        nativeCallbackOutstanding = true
        defer {
            nativeCallbackOutstanding = false
            if let lease = nativeLease { try? ownership.markNativeRequest(lease) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.prepareToPlay { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func observe(_ token: UUID, ticket: Completion? = nil, seconds: Double = 2, intent: UInt64? = nil,
                         transport: UInt64? = nil,
                         predicate: @escaping @MainActor () -> Bool) async -> PlaybackOutcome {
        if nativeNeedsObservation { nativeObservation = predicate }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .milliseconds(Int(seconds * 1_000)))
        repeat {
            guard generation == token, active else { return outcome(.cancelled) }
            guard intent == nil || intentVersion == intent else { return outcome(.cancelled) }
            guard transport == nil || commandVersion == transport else { return outcome(.cancelled) }
            guard ticket?.expired != true else { return outcome(.timedOut) }
            refresh()
            if confirmsNativeObservation(predicate) {
                if nativeMutationIssued { playerSettled = true; settlingReading = nil }
                nativeNeedsObservation = false
                nativeObservation = nil
                return outcome()
            }
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return outcome(.cancelled) }
        } while clock.now < end
        return outcome(.timedOut)
    }

    private func observeTransport(_ command: PlaybackCommand, from index: Int, token: UUID, ticket: Completion) async -> PlaybackOutcome {
        let result = await observe(token, ticket: ticket) {
            (self.playerReading ?? self.readNativePlayer()).acceptsTransport(command, from: index, to: self.currentIndex())
        }
        if result.status == .completed, let moved = currentIndex() {
            let skipped = abs(moved - index) - 1
            if skipped > 0 { status = "Skipped \(skipped) unavailable" }
        } else if result.reason == .timedOut, confirmsNativeObservation({ self.currentIndex() == index }) {
            status = "Music did not change songs."
            return outcome(.nativeNoChange)
        }
        return result
    }

    @discardableResult
    private func acceptOwnedReading(_ reading: PlaybackNativeObservation, revision: UUID) -> Bool {
        guard var checkpoint = [journal.pendingReplacement, journal.current].compactMap({ $0 }).first(where: {
            $0.revision == revision && $0.occurrence(catalogID: reading.catalogID, nativeIndex: reading.nativeIndex) != nil
        }), let index = checkpoint.occurrence(catalogID: reading.catalogID, nativeIndex: reading.nativeIndex) else { return false }
        checkpoint.cursor = index
        checkpoint.position = reading.position.isFinite ? max(0, reading.position) : 0
        checkpoint.observedAt = Date()
        checkpoint.terminal = .active
        journal.current = checkpoint
        if journal.pendingReplacement?.revision == revision { journal.pendingReplacement = nil }
        playerSettled = true
        persistLater()
        return true
    }

    private func settleQuarantine(_ reading: PlaybackNativeObservation) {
        guard loaded, nativeLease == nil, !nativeCallbackOutstanding,
              Date().timeIntervalSince(lastQuarantineSettlement) >= 1,
              sharedRecord?.state == .uncertain else { return }
        lastQuarantineSettlement = Date()
        let revision = sharedRecord?.queueRevision
        let mapped = [journal.pendingReplacement, journal.current].compactMap { $0 }.first {
            $0.revision == revision && $0.occurrence(catalogID: reading.catalogID, nativeIndex: reading.nativeIndex) != nil
        }
        do {
            if let settled = try ownership.settleQuarantine(reading: .init(stable: true,
                queueRevision: mapped?.revision, emptyAndStopped: !reading.itemPresent && reading.rawState == 0)) {
                sharedRecord = settled
                sharedBusy = false
                if settled.state == .active { acceptOwnedReading(reading, revision: settled.queueRevision) }
                if problem?.contains("unconfirmed") == true { problem = nil }
                status = settled.state == .active ? "Music’s queue is connected again." : "Music’s queue is empty and stopped."
            }
        } catch { _ = ownershipFailure(error) }
    }

    private func refresh() {
        defer { recordQueueProbe(trigger: "poll") }
        if MusicAuthorization.currentStatus != .authorized { authorized = false }
        refreshSharedOwnership()
        let first = readNativePlayer()
        let second = readNativePlayer()
        playerReading = second
        playerReadingIsStable = first.agrees(with: second)
        defer { playerReading = nil; playerReadingIsStable = true }
        guard playerReadingIsStable else {
            inconsistentNativeObservations &+= 1
            settlingReading = nil
            stoppedObservation = nil
            if missingSince == nil { missingSince = Date() }
            if Date().timeIntervalSince(missingSince!) >= 10 {
                status = "Music is still loading. Wait, or open Setup and tap Restore saved queue."
            }
            publishSnapshot(synchronized: false)
            updateQueueStatus()
            recordDiagnosticState()
            return
        }
        settleQuarantine(second)
        if !playerSettled, journal.current?.occurrence(catalogID: second.catalogID, nativeIndex: second.nativeIndex) != nil {
            if let previous = settlingReading, previous.value.hasSameItemAndState(as: second) {
                if Date().timeIntervalSince(previous.date) >= 0.075 { playerSettled = true }
            } else {
                settlingReading = (second, Date())
            }
        }
        publishSharedCompletionIfNeeded()
        reconcileInterruptedAppend()
        if reconcileObservedEnd() {
            publishSharedCompletionIfNeeded()
            publishSnapshot(synchronized: false)
            updateQueueStatus()
            recordDiagnosticState()
            continueStarvedSuffixIfReady()
            return
        }
        if !starvedWhileActive { observingEnd = false }
        let observedRecoveryPause = second.rawState == 2 && second.itemPresent &&
            journal.current.map { ownsSharedQueue($0) } == true
        if playbackEnabled, journal.pendingReplacement == nil, (!nativeBusy || recoveryAwaitingStableMetadata),
           state == "paused", journal.current?.intendedPlaying == true,
           ((playerSettled && currentIndex() != nil) || observedRecoveryPause), !starvedWhileActive, desiredPlaying != true {
            journal.current?.intendedPlaying = false
            journal.pendingReplacement?.intendedPlaying = false
            stoppedObservation = nil
            persistLater()
        }
        reconcileColdStoppedPrefix()
        resumeOwnedStoppedQueueIfUseful()
        let index = currentIndex()
        if let index {
            missingSince = nil
            if playerSettled, !nativeBusy, second.rawState == 1, second.duration > 0 {
                lastOwned = (index, second.position, second.duration, Date())
            }
            if !nativeBusy { captureProgress(force: false) }
        } else if active, !nativeBusy, loaded, authorized, journal.current?.terminal == .active {
            if missingSince == nil { missingSince = Date() }
            if Date().timeIntervalSince(missingSince!) >= 2 { reconcileMissingQueue() }
        }
        publishSnapshot(synchronized: active && authorized && index != nil && !nativeBusy)
        updateObservedPlaybackStatus()
        updateQueueStatus()
        recordDiagnosticState()
        continueStarvedSuffixIfReady()
    }

    private func reconcileMissingQueue() {
        guard var current = journal.current else { return }
        guard ownsSharedQueue(current), !starvedWhileActive, journal.pendingReplacement == nil else { return }
        let observed = playerReading ?? readNativePlayer()
        if observed.itemPresent {
            status = "Music’s current queue is unconfirmed. Select a song or restore the saved queue."
            return
        }
        switch observed.rawState {
        case 1, 4, 5:
            let missingFor = missingSince.map { Date().timeIntervalSince($0) } ?? 0
            status = missingFor >= 10
                ? "Music is still loading. Wait, or open Setup and tap Restore saved queue."
                : "Music is loading. Its queue has been preserved."
            return
        case 2, 3:
            if current.intendedPlaying { current.intendedPlaying = false; journal.current = current; persistLater() }
            let playback = observed.rawState == 2 ? "paused" : "interrupted"
            status = "Music is \(playback). Its queue has been preserved. Use Restore saved queue if needed."
            return
        case 0: break
        default:
            status = "Music’s current song is unavailable. Its queue has been preserved. Use Restore saved queue if needed."
            return
        }
        guard !recoveryAttempted, !recoveryPending else { return }
        if current.mayAutomaticallyRestoreEmptyQueue(itemPresent: observed.itemPresent,
            nativeStopped: observed.rawState == 0, latestPlayingIntent: current.intendedPlaying, at: Date()) {
            recoveryPending = true
            let token = generation
            let command = commandVersion
            Task { [weak self] in
                guard let self else { return }
                defer { self.recoveryPending = false }
                guard self.generation == token, self.commandVersion == command else { return }
                _ = await self.restore(automatic: true, expectedCommandVersion: command)
            }
        } else {
            recoveryAttempted = true
            awaitingPlay = true
            if current.intendedPlaying, let remaining = current.remainingSubmittedDuration,
               Date().timeIntervalSince(current.observedAt) >= remaining {
                current.cursor = current.submittedCount
                current.position = 0
                current.intendedPlaying = false
                journal.current = current
                persistLater()
            }
            status = "Music’s queue is empty. Tap Play or Restore saved queue to continue."
            logQueue("recovery_suppressed", count: current.submittedCount)
        }
    }

    private func reconcileColdStoppedPrefix() {
        guard coldObservationPending, loaded, authorized, !nativeBusy else { return }
        coldObservationPending = false
        let observed = playerReading ?? readNativePlayer()
        guard observed.rawState == 0, var current = journal.current, current.terminal == .active,
              current.intendedPlaying, ownedNativeIndex() != nil,
              let remaining = current.remainingSubmittedDuration else { return }
        let elapsed = Date().timeIntervalSince(current.observedAt)
        guard elapsed.isFinite, elapsed >= 0, elapsed >= remaining else { return }
        current.cursor = current.submittedCount
        current.position = 0
        current.intendedPlaying = false
        journal.current = current
        awaitingPlay = true
        status = "The prepared prefix may have ended while closed. Tap Play or Restore to continue."
        persistLater()
    }

    private func resumeOwnedStoppedQueueIfUseful() {
        let observed = playerReading ?? readNativePlayer()
        guard active, loaded, authorized, !nativeBusy, !recoveryAttempted, !recoveryPending,
              journal.pendingReplacement == nil, journal.clearPending != true,
              observed.rawState == 0, desiredPlaying != false,
              let checkpoint = journal.current, ownsSharedQueue(checkpoint),
              let id = observed.catalogID,
              let target = checkpoint.recoveryTarget(catalogID: id, nativeIndex: observed.nativeIndex),
              playerSettled || target.nativeOffset > checkpoint.nativeOffset,
              checkpoint.mayAutomaticallyResume(catalogID: id, nativeIndex: observed.nativeIndex, at: Date()) else {
            if !nativeBusy && !recoveryPending { stoppedObservation = nil }
            return
        }
        let nativeIndex = observed.nativeIndex
        let nativePosition = observed.position
        guard nativePosition.isFinite, nativePosition >= 0, nativePosition <= 86_400 else {
            stoppedObservation = nil
            return
        }
        guard let previous = stoppedObservation, previous.revision == checkpoint.revision,
              previous.id == id, previous.index == nativeIndex, previous.offset == checkpoint.nativeOffset,
              previous.target == target,
              abs(previous.position - nativePosition) <= 0.25 else {
            stoppedObservation = (checkpoint.revision, id, nativeIndex, checkpoint.nativeOffset, target, nativePosition, Date())
            return
        }
        guard Date().timeIntervalSince(previous.date) >= 0.075 else { return }
        recoveryPending = true
        let token = generation
        let command = commandVersion
        let intent = intentVersion
        Task { [weak self] in
            guard let self else { return }
            defer { self.recoveryPending = false }
            _ = await self.serialized(token) { [self] ticket in
                let fresh = readNativePlayer()
                let confirmed = readNativePlayer()
                guard isCurrent(token), commandVersion == command, intentVersion == intent,
                      desiredPlaying != false, journal.pendingReplacement == nil, journal.clearPending != true,
                      fresh.agrees(with: confirmed), confirmed.rawState == 0, let current = journal.current,
                      current.revision == checkpoint.revision, current.nativeOffset == previous.offset,
                      confirmed.catalogID == previous.id, confirmed.nativeIndex == previous.index,
                      abs(confirmed.position - previous.position) <= 0.25,
                      checkpoint.mayAutomaticallyResume(catalogID: previous.id, nativeIndex: previous.index, at: Date()),
                      current.mayAutomaticallyResume(catalogID: previous.id, nativeIndex: previous.index, at: Date()),
                      current.recoveryTarget(catalogID: previous.id, nativeIndex: previous.index) == previous.target else { return outcome(.cancelled) }
                logQueue("recovery_started", count: current.submittedCount, batch: current.revision)
                status = "Resuming your stopped Music queue…"
                let started = Date()
                stage("play_queue", phase: "begin", batch: current.revision)
                do { try markNativeMutation(observationRequired: true) }
                catch { return ownershipFailure(error) }
                recoveryAttempted = true
                player.play()
                var confirmation = PlaybackRecoveryConfirmation(rebasedTarget: previous.target)
                var confirmationObservation = inconsistentNativeObservations
                var observedPause = false
                defer { self.recoveryAwaitingStableMetadata = false }
                let result = await observe(token, ticket: ticket, seconds: 4, intent: intent, transport: command) {
                    if confirmationObservation != self.inconsistentNativeObservations {
                        confirmation.reset()
                        confirmationObservation = self.inconsistentNativeObservations
                    }
                    guard self.isCurrent(token), self.commandVersion == command, self.intentVersion == intent,
                          self.desiredPlaying != false, self.journal.pendingReplacement == nil, self.journal.clearPending != true,
                          var recovered = self.journal.current, recovered.revision == checkpoint.revision,
                          recovered.nativeOffset == previous.offset, self.ownsSharedQueue(recovered) else { confirmation.reset(); return false }
                    if self.recoveryAwaitingStableMetadata, self.nativeRawState == 2,
                       !recovered.intendedPlaying {
                        observedPause = true
                        return true
                    }
                    guard let playing = self.playerReading, playing.itemPresent, playing.rawState == 1,
                          playing.catalogID == previous.id,
                          playing.position >= previous.position - 0.25,
                          playing.position - previous.position <= Date().timeIntervalSince(started) + 0.25,
                          recovered.intendedPlaying,
                          checkpoint.mayAutomaticallyRestore(at: Date()), recovered.mayAutomaticallyRestore(at: Date()),
                          let mapping = recovered.playingRecoveryTarget(catalogID: playing.catalogID,
                              nativeIndex: playing.nativeIndex, recovering: previous.target),
                          mapping.occurrence == previous.target.occurrence else { confirmation.reset(); return false }
                    self.recoveryAwaitingStableMetadata = true
                    self.nativeNeedsObservation = false
                    guard confirmation.accepts(playing, target: mapping, at: Date()) else { return false }
                    // Only confirmed playback can adopt Music's observed prefix rebase; Play never seeks or rebuilds it.
                    recovered.nativeOffset = mapping.nativeOffset
                    guard recovered.captureObservation(playing, confirmedBy: playing, desiredPlaying: true, at: Date()) else { return false }
                    self.journal.current = recovered
                    self.stoppedObservation = nil
                    self.persistLater()
                    return true
                }
                stage("play_queue", phase: "end", started: started,
                      outcome: result.status == .completed && !observedPause ? "success" : "error", batch: current.revision)
                if generation == token, commandVersion == command, intentVersion == intent {
                    status = observedPause ? "Music is paused. Its queue has been preserved."
                        : result.status == .completed ? "Music is playing. Keep Autoplay (∞) off."
                        : "Music did not resume. Tap Play to try again."
                }
                return observedPause ? outcome(.cancelled) : result
            }
        }
    }

    private func reconcileObservedEnd() -> Bool {
        guard active, !nativeBusy else { return false }
        guard var current = journal.current, ownsSharedQueue(current) else {
            endCandidate = nil
            lastOwned = nil
            return false
        }
        let observed = playerReading ?? readNativePlayer()
        guard observed.rawState == 2 || observed.rawState == 0 else {
            endCandidate = nil
            return false
        }
        let now = Date()
        let reset = current.isSubmittedEndReset(catalogID: observed.catalogID,
            nativeIndex: observed.nativeIndex, position: observed.position)
        let candidate: EndCandidate
        if let existing = endCandidate {
            guard existing.revision == current.revision, existing.generation == generation,
                  existing.command == commandVersion, existing.intent == intentVersion,
                  existing.submittedCount == current.submittedCount, existing.nativeOffset == current.nativeOffset,
                  reset, now.timeIntervalSince(existing.date) >= 0, now.timeIntervalSince(existing.date) <= 5 else {
                endCandidate = nil
                lastOwned = nil
                return false
            }
            candidate = existing
        } else {
            // Discard an early Stop at its first observation; elapsed wall time cannot promote it later.
            guard reset, let lastOwned,
                  current.observedSubmittedEnd(index: lastOwned.index, position: lastOwned.position, nativeDuration: lastOwned.duration,
                      observedAt: lastOwned.date, now: now) else {
                self.lastOwned = nil
                return false
            }
            candidate = EndCandidate(revision: current.revision, generation: generation,
                submittedCount: current.submittedCount, nativeOffset: current.nativeOffset,
                command: commandVersion, intent: intentVersion, date: now, intendedPlaying: current.intendedPlaying)
            endCandidate = candidate
            current.intendedPlaying = false
            journal.current = current
            stoppedObservation = nil
            persistLater()
        }
        observingEnd = true
        guard now.timeIntervalSince(candidate.date) >= 2 else { return true }
        current.cursor = current.submittedCount
        current.position = 0
        if current.resolutionComplete && current.submittedCount == current.entries.count {
            current.terminal = .completed
            current.intendedPlaying = false
            status = "The prepared queue has finished."
            logQueue("completed", count: current.submittedCount)
        } else {
            current.intendedPlaying = candidate.intendedPlaying
            starvedWhileActive = candidate.intendedPlaying
            status = "The prepared songs have ended. Finding the next song…"
            logQueue("starved", count: current.submittedCount)
        }
        journal.current = current
        lastOwned = nil
        endCandidate = nil
        persistLater()
        return true
    }

    private func continueStarvedSuffixIfReady() {
        guard active, starvedWhileActive, !nativeBusy, !continuingSuffix,
              let current = journal.current, ownsSharedQueue(current), current.entries.count > current.submittedCount else { return }
        continuingSuffix = true
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            var suffix = current
            suffix.cursor = current.submittedCount
            suffix.position = 0
            let result = await self.replace(suffix, start: suffix.cursor, ownedOnly: true, token: token)
            self.finishSuffixAttempt(result, token: token)
        }
    }

    private func finishSuffixAttempt(_ result: PlaybackOutcome, token: UUID) {
        guard generation == token else { return }
        continuingSuffix = false
        if result.status == .rejected {
            starvedWhileActive = false
            awaitingPlay = true
            journal.current?.intendedPlaying = false
            journal.pendingReplacement?.intendedPlaying = false
            persistLater()
        }
    }

    private func reconcileInterruptedAppend() {
        let observed = playerReading ?? readNativePlayer()
        guard var current = journal.current, let pendingEnd = current.pendingAppendEnd,
              ownsSharedQueue(current),
              observed.nativeIndex != NSNotFound, observed.nativeIndex >= 0,
              observed.nativeIndex < pendingEnd - current.nativeOffset else { return }
        let ordinal = current.nativeOffset + observed.nativeIndex
        guard ordinal >= current.submittedCount, current.entries.indices.contains(ordinal),
              current.entries[ordinal].match.track.id == observed.catalogID else { return }
        current.submittedCount = pendingEnd
        current.pendingAppendEnd = nil
        journal.current = current
        persistLater()
    }

    private func currentIndex() -> Int? {
        guard !starvedWhileActive, !observingEnd else { return nil }
        if awaitingPlay, let current = journal.current, current.cursor >= current.submittedCount { return nil }
        return ownedNativeIndex()
    }

    private func verifiedSeekTarget() -> SeekTarget? {
        var target: SeekTarget?
        _ = confirmsNativeObservation {
            guard nativeItemPresent, currentIndex() != nil, let current = journal.current,
                  let fence = sharedRecord?.fence else { return false }
            target = current.seekTarget(catalogID: nativeCatalogID, nativeIndex: nativeIndex, ownershipFence: fence)
            return target != nil
        }
        return target
    }

    private func ownedNativeIndex() -> Int? {
        guard playerReadingIsStable, let current = journal.current, current.terminal == .active, ownsSharedQueue(current) else { return nil }
        let observed = playerReading ?? readNativePlayer()
        return current.occurrence(catalogID: observed.catalogID, nativeIndex: observed.nativeIndex)
    }

    private func readNativePlayer() -> PlaybackNativeObservation {
        let item = player.nowPlayingItem
        return PlaybackNativeObservation(catalogID: item?.playbackStoreID, nativeIndex: player.indexOfNowPlayingItem,
            position: player.currentPlaybackTime, duration: item?.playbackDuration ?? 0,
            rawState: player.playbackState.rawValue, itemPresent: item != nil)
    }

    private func confirmsNativeObservation(_ predicate: @MainActor () -> Bool) -> Bool {
        let first = readNativePlayer()
        let second = readNativePlayer()
        guard first.agrees(with: second) else { inconsistentNativeObservations &+= 1; return false }
        let previous = playerReading
        let wasStable = playerReadingIsStable
        playerReading = second
        playerReadingIsStable = true
        defer { playerReading = previous; playerReadingIsStable = wasStable }
        return predicate()
    }

    private var nativeRawState: Int { playerReading?.rawState ?? player.playbackState.rawValue }
    private var nativeIndex: Int { playerReading?.nativeIndex ?? player.indexOfNowPlayingItem }
    private var nativeItemPresent: Bool { playerReading?.itemPresent ?? (player.nowPlayingItem != nil) }
    private var nativeCatalogID: String? {
        if let playerReading { return playerReading.catalogID }
        return player.nowPlayingItem?.playbackStoreID
    }

    private var playbackEnabled: Bool { AppConfiguration.current.playbackEnabled }

    private func ownsSharedQueue(_ checkpoint: PlaybackCheckpoint) -> Bool {
        playbackEnabled && !sharedBusy && sharedRecord?.ownerBundleID == AppConfiguration.current.bundleIdentifier &&
            sharedRecord?.queueRevision == checkpoint.revision && sharedRecord?.state == .active
    }

    private func refreshSharedOwnership(force: Bool = false) {
        guard loaded, nativeLease == nil, force || Date().timeIntervalSince(lastSharedRefresh) >= 1 else { return }
        lastSharedRefresh = Date()
        do {
            var record = try ownership.snapshot()
            if record == nil, playbackEnabled, AppConfiguration.current.provider == .youtubeMusic {
                if journal.clearPending == true || (journal.pendingReplacement?.submittedCount ?? 0) > 0 || journal.current?.pendingAppendEnd != nil {
                    let revision = journal.pendingReplacement?.revision ?? journal.current?.revision ?? journal.clearRequestID ?? generation
                    record = try ownership.bootstrap(revision: revision, terminal: .uncertain)
                    status = "An earlier Music request is unconfirmed. Its queue has been preserved."
                    problem = status
                } else if let current = journal.current {
                    let terminal = SharedPlaybackOwnership.State(rawValue: current.terminal.rawValue) ?? .active
                    record = try ownership.bootstrap(revision: current.revision, terminal: terminal)
                }
            }
            sharedRecord = record
            sharedBusy = try ownership.hasOutstandingRequest() && nativeLease == nil
        } catch {
            sharedRecord = nil
            sharedBusy = true
            _ = ownershipFailure(error)
        }
    }

    private func markNativeMutation(observationRequired: Bool = false, callbackOutstanding: Bool = false) throws {
        guard playbackEnabled, let lease = nativeLease else { throw SharedPlaybackOwnership.Failure.foreignOwner }
        try ownership.markNativeRequest(lease, callbackOutstanding: callbackOutstanding)
        nativeMutationIssued = true
        nativeNeedsObservation = nativeNeedsObservation || observationRequired
    }

    private func publishSharedCompletionIfNeeded() {
        guard playbackEnabled, nativeLease == nil, !sharedBusy, let current = journal.current, current.terminal == .completed,
              sharedRecord?.ownerBundleID == AppConfiguration.current.bundleIdentifier,
              sharedRecord?.queueRevision == current.revision, sharedRecord?.state == .active else { return }
        do {
            let lease = try ownership.begin(operationID: UUID(), revision: current.revision, mode: .ownedMutation,
                                            expectedFence: sharedRecord?.fence)
            sharedRecord = try ownership.finish(lease, state: .completed)
        } catch { _ = ownershipFailure(error) }
    }

    private func ownershipFailure(_ error: Error) -> PlaybackOutcome {
        if case SharedPlaybackOwnership.Failure.busy = error {
            status = "Another Music request is still pending. Its queue has been preserved."
        } else if case SharedPlaybackOwnership.Failure.foreignOwner = error {
            status = "Music is controlled elsewhere. Select a song or use Restore saved queue to replace it."
        } else if case SharedPlaybackOwnership.Failure.nativeRequestUnsettled = error {
            status = "An interrupted request is unconfirmed. Its queue has been preserved."
        } else {
            // The first sentence stays the footer headline; the cause is for Details and bug reports.
            let cause: String
            switch error {
            case SharedPlaybackOwnership.Failure.unavailable(let code): cause = "Keychain error \(code)"
            case SharedPlaybackOwnership.Failure.corrupt: cause = "Unreadable ownership record"
            case SharedPlaybackOwnership.Failure.staleLease: cause = "Stale ownership lease"
            default: cause = "Unexpected ownership error"
            }
            status = "Music queue protection is unavailable. Playback has been preserved. " +
                "\(cause); \(AppConfiguration.current.sharedPlaybackDescription); app \(AppConfiguration.current.bundleIdentifier)."
        }
        problem = status
        return outcome(.foreignPlayback)
    }

    private var position: Double {
        let value = playerReading?.position ?? player.currentPlaybackTime
        return value.isFinite ? min(86_400, max(0, value)) : 0
    }

    private var state: String {
        (playerReading ?? readNativePlayer()).state
    }

    private func publishSnapshot(synchronized: Bool) {
        let currentItem = player.nowPlayingItem
        let item = playerReading == nil || currentItem?.playbackStoreID == playerReading?.catalogID ? currentItem : nil
        let source = currentIndex().flatMap { journal.current?.entries[$0].source }
        let sourceID = source?.id.hasPrefix("reference-") == true ? nil : source?.id
        let duration = playerReading?.duration ?? item?.playbackDuration ?? 0
        snapshot = PlaybackSnapshot(sourceID: sourceID, title: item?.title ?? "", artist: item?.artist ?? "",
            duration: duration.isFinite ? max(0, duration) : 0, position: position, state: state,
            synchronized: synchronized, revision: snapshot.revision &+ 1)
    }

    private func captureProgress(force: Bool) {
        guard !nativeBusy, currentIndex() != nil, var current = journal.current,
              playerSettled || desiredPlaying != nil else { return }
        let first = playerReading ?? readNativePlayer()
        let second = playerReading ?? readNativePlayer()
        let previous = current
        guard current.captureObservation(first, confirmedBy: second, desiredPlaying: desiredPlaying, at: Date()) else { return }
        let changed = previous.cursor != current.cursor || previous.intendedPlaying != current.intendedPlaying
        journal.current = current
        if force || changed || Date().timeIntervalSince(lastPersistedAt) >= 5 { persistLater() }
    }

    private func updateQueueStatus() {
        defer { updateFooter() }
        let checkpoint = journal.pendingReplacement ?? journal.current
        guard let checkpoint else {
            queueStatus = "No saved queue."
            canRestore = false
            skipped = []
            skippedRows = []
            return
        }
        canRestore = !nativeBusy && !preparing && selection == nil && journal.pendingReplacement == nil &&
            (journal.current.map { !$0.entries.isEmpty && $0.terminal != .cleared } ?? false)
        skippedRows = checkpoint.skippedRows
        skipped = skippedRows.map { "\($0.source.title) — \($0.source.artist)\n\(skipExplanation($0.reason))" }
        if journal.pendingReplacement != nil {
            let previous: String
            if currentIndex() != nil, let current = journal.current {
                previous = "\(current.submittedCount - current.nativeOffset) previously prepared songs are connected to Music until replacement succeeds."
            } else {
                previous = "Music’s current queue is unconfirmed."
            }
            queueStatus = "Selected batch: checked \(checkpoint.processedCount) of \(checkpoint.sources.count), \(skipped.count) skipped. \(previous)"
        }
        else if checkpoint.terminal == .cleared {
            queueStatus = "Saved batch cleared. Music’s remaining queue is unconfirmed."
        }
        else if checkpoint.terminal == .completed { queueStatus = "Queue finished. \(checkpoint.entries.count) prepared, \(skipped.count) skipped." }
        else {
            let progress = checkpoint.resolutionComplete ? "Matching complete." : "Checked \(checkpoint.processedCount) of \(checkpoint.sources.count)."
            let uncertainty = checkpoint.pendingAppendEnd == nil ? "" : " An interrupted append needs Restore before more songs can be added."
            if checkpoint.legacy {
                queueStatus = "Saved song list: \(checkpoint.entries.count) songs. Tap Restore to prepare it in Music."
            } else if currentIndex() == nil {
                queueStatus = "Saved batch: \(checkpoint.entries.count) matched, \(skipped.count) skipped. Music’s current queue is unconfirmed. \(progress)\(uncertainty)"
            } else {
                queueStatus = "\(checkpoint.submittedCount - checkpoint.nativeOffset) connected to Music; \(skipped.count) skipped. \(progress)\(uncertainty)"
            }
        }
    }

    private func updateFooter() {
        var input = FooterInput()
        input.playbackEnabled = playbackEnabled
        input.authorized = authorized
        input.site = AppConfiguration.current.websiteName
        input.problem = problem
        input.unconfirmed = sharedRecord?.state == .uncertain || (nativeCallbackOutstanding && problem != nil)
        input.committing = nativeBusy && journal.pendingReplacement != nil
        input.pendingReplacement = journal.pendingReplacement != nil
        if input.problem == nil, sharedRecord?.state == .uncertain {
            input.problem = "Music’s last request is unconfirmed. Its queue has been preserved."
        }
        input.noMatch = noMatchUntil.map { Date() < $0 } ?? false
        let checkpoint = journal.pendingReplacement ?? journal.current
        if let checkpoint {
            if input.problem == nil, checkpoint.pendingAppendEnd != nil, !nativeBusy {
                input.problem = "An append was interrupted. Use Restore before adding more songs."
            }
            input.preSubmission = journal.pendingReplacement != nil && checkpoint.submittedCount == 0
            let failed = resolutionFailure?.revision == checkpoint.revision
            input.failed = failed
            input.canRetryMatching = resolutionFailure?.kind != .never && !nativeBusy && problem == nil &&
                checkpoint.pendingAppendEnd == nil
            input.owned = journal.pendingReplacement == nil && ownsSharedQueue(checkpoint) &&
                (currentIndex() != nil || checkpoint.submittedCount > 0)
            input.matching = selection != nil
            input.paused = failed || (!checkpoint.resolutionComplete && selection == nil)
            input.retryAttempt = requestRetry?.attempt
            input.retryLimit = requestRetry?.limit ?? 3
            input.retryingSkipped = selection != nil ? (checkpoint.retryOf?.keys.filter { $0 >= checkpoint.processedCount }.count ?? 0) : 0
            input.submittedCount = checkpoint.submittedCount - checkpoint.nativeOffset
            input.processedCount = checkpoint.processedCount
            input.sourceCount = checkpoint.sources.count
            input.skippedCount = skippedRows.count
            input.retryableSkips = retryableSkippedCount
            if !nativeBusy && !preparing && selection == nil && journal.pendingReplacement == nil && !checkpoint.entries.isEmpty { input.savedRemaining = max(0, checkpoint.entries.count - checkpoint.cursor) }
            input.finished = checkpoint.terminal == .completed
            input.cleared = checkpoint.terminal == .cleared
        }
        let value = FooterState.make(input)
        if footer != value { footer = value }
    }

    private func skipExplanation(_ reason: MatchSkipReason?) -> String {
        switch reason {
        case .invalidSource: "The source song details could not be used."
        case .noResults: "Apple’s catalog returned no usable song results."
        case .unavailableInStorefront: "This song is unavailable in your Apple Music storefront."
        case .thirdPartyEdit: "This third-party edit could not be verified against the artist’s original."
        case .noCompatibleMetadata: "No result matched the artist, title, version, and available recording details."
        case .contentConflict: "The clean or explicit versions could not be matched confidently."
        case .insufficientDurationlessAgreement: "The source had no duration, and the catalog results lacked consistent recording details." +
            (AppConfiguration.current.provider == .spotify ? " Open the song page and press Play." : "")
        case .ambiguousRecording: "More than one recording remained possible."
        case nil: "No confident recording match was saved."
        }
    }

    private func updateObservedPlaybackStatus() {
        guard active, authorized, !preparing, !nativeBusy, journal.pendingReplacement == nil,
              currentIndex() != nil,
              status == "Apple Music is ready. Keep Autoplay (∞) off in Music." ||
                status == "Music’s current queue is unconfirmed. Select a song or restore the saved queue." ||
                status.hasPrefix("Music is playing.") || status.hasPrefix("Music is paused.") ||
                status.hasPrefix("Music is loading.") || status.hasPrefix("Music is still loading.") ||
                status.hasPrefix("Music is interrupted.") || status.hasPrefix("Music’s current song is unavailable.") ||
                status.hasPrefix("Music is stopped.") else { return }
        status = "Music is \(state). Keep Autoplay (∞) off."
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        if loading == nil { loading = Task { await store.load() } }
        let value = await loading?.value
        guard !loaded else { return }
        journal = value ?? PlaybackJournal()
        if let current = journal.current, current.terminal == .active, current.submittedCount > 0,
           current.cursor >= current.submittedCount { awaitingPlay = true }
        loaded = true
        loading = nil
        if journal.current?.legacy == true { status = "A saved song list is available. Tap Restore to use it." }
        updateQueueStatus()
    }

    private func persist() async throws {
        journal.sequence &+= 1
        let value = journal
        try await store.save(value)
        lastPersistedAt = Date()
        updateQueueStatus()
    }

    private func persistLater() {
        journal.sequence &+= 1
        let value = journal
        lastPersistedAt = Date()
        Task { [weak self] in
            do { try await self?.store.save(value) }
            catch {
                self?.status = "The queue could not be saved. Keep Multimusic open to retain progress."
                self?.problem = self?.status
            }
        }
    }

    private func checkpoint(_ revision: UUID) -> PlaybackCheckpoint? {
        if journal.pendingReplacement?.revision == revision { return journal.pendingReplacement }
        if journal.current?.revision == revision { return journal.current }
        return nil
    }

    private func setCheckpoint(_ value: PlaybackCheckpoint) {
        if journal.pendingReplacement?.revision == value.revision { journal.pendingReplacement = value }
        else if journal.current?.revision == value.revision { journal.current = value }
    }

    private func context(_ original: SourceContext?, for first: SourceTrack?, base: Int) -> SourceContext? {
        guard let original, let first else { return nil }
        return SourceContext(provider: original.provider, kind: original.kind, collectionID: original.collectionID, title: original.title,
            artist: original.artist, edition: original.edition, selectedSourceID: first.id,
            selectedOrdinal: original.selectedOrdinal.map { $0 + base })
    }

    private func invalidateSelection() {
        generation = UUID()
        automaticResume?.cancel()
        automaticResume = nil
        resumeAttempt = 0
        resolutionFailure = nil
        requestRetry = nil
        endCandidate = nil
        observingEnd = false
        continuingSuffix = false
        intentVersion &+= 1
        desiredPlaying = nil
        selection?.cancel()
        selection = nil
        finishSelection(outcome(.cancelled))
    }

    private func finishSelection(_ value: PlaybackOutcome) {
        firstSelection?.finish(value)
        firstSelection = nil
    }

    private func isCurrent(_ token: UUID) -> Bool {
        active && authorized && generation == token && !Task.isCancelled && MusicAuthorization.currentStatus == .authorized
    }

    private func requireCurrent(_ token: UUID) throws {
        guard isCurrent(token) else { throw CancellationError() }
    }

    private func outcome(_ reason: PlaybackOutcome.Reason? = nil, skipReasons: [String] = []) -> PlaybackOutcome {
        if reason == .timedOut, problem == nil {
            status = "Music took too long to respond. Open Setup to inspect its current state."
            problem = status
        }
        publishSnapshot(synchronized: active && authorized && currentIndex() != nil && !nativeBusy)
        return PlaybackOutcome(status: reason == nil ? .completed : .rejected, reason: reason,
                               snapshot: snapshot, skipReasons: skipReasons)
    }

    private func storageFailure(_ error: Error, completion: Completion? = nil, generation token: UUID? = nil) -> PlaybackOutcome {
        guard token == nil || generation == token else { return outcome(.cancelled) }
        status = "Could not safely save the queue. \(diagnosticCode(error))"
        problem = status
        preparing = false
        let result = outcome(.nativeFailure)
        completion?.finish(result)
        return result
    }

    private func deduplicated(_ supplied: String?, name: String? = nil,
                              operation: @escaping @MainActor () async -> PlaybackOutcome) async -> PlaybackOutcome {
        let id = supplied ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if let existing = commandTasks[id] { return await existing.value }
        for (old, date) in commandFinished where Date().timeIntervalSince(date) >= 60 {
            commandTasks.removeValue(forKey: old)
            commandFinished.removeValue(forKey: old)
        }
        guard commandTasks.count < 128 else { return outcome(.nativeFailure) }
        if let name { TestDiagnostics.record("native.command", fields: ["phase": "received", "command": name, "commandId": id]) }
        let task = Task { await operation() }
        commandTasks[id] = task
        let result = await task.value
        commandFinished[id] = Date()
        if let name {
            var fields = ["phase": result.status == .completed ? "completed" : "rejected", "command": name, "commandId": id]
            if let reason = result.reason { fields["reason"] = reason.rawValue }
            TestDiagnostics.record("native.command", fields: fields)
        }
        return result
    }

    private func valid(_ tracks: [SourceTrack]) -> Bool {
        !tracks.isEmpty && tracks.count <= 50 && tracks.allSatisfy {
            !$0.id.isEmpty && $0.id.count <= 128 && !$0.title.isEmpty && $0.title.count <= 512 &&
            !$0.artist.isEmpty && $0.artist.count <= 512 &&
            ($0.duration.map { $0.isFinite && $0 > 0 && $0 <= 86_400 } ?? true) && ($0.isrc.map { $0.count <= 32 } ?? true)
        }
    }

    private func commandName(_ command: PlaybackCommand) -> String {
        switch command { case .play: "play"; case .pause: "pause"; case .next: "next"; case .previous: "previous"; case .seek: "seek" }
    }

    private func stage(_ name: String, phase: String, started: Date = Date(), outcome: String = "success", batch: UUID? = nil, error: Error? = nil) {
        let selection = batch ?? (journal.pendingReplacement ?? journal.current)?.revision ?? generation
        var fields = ["stage": name, "phase": phase, "outcome": outcome,
            "elapsedMs": String(Int(max(0, Date().timeIntervalSince(started)) * 1_000)), "selectionId": opaqueID(selection)]
        fields["commandId"] = checkpoint(selection)?.commandID ?? selectionCommands[selection]
        if let error = error as NSError? {
            fields["domain"] = ["MPErrorDomain", "MPMusicPlayerControllerErrorDomain", "NSOSStatusErrorDomain", "NSURLErrorDomain"].contains(error.domain) ? error.domain : "other"
            fields["code"] = String(error.code)
        }
        TestDiagnostics.record("native.stage", fields: fields)
    }

    private func logQueue(_ phase: String, count: Int, batch: UUID? = nil) {
        let selection = batch ?? (journal.pendingReplacement ?? journal.current)?.revision ?? generation
        var fields = ["phase": phase, "queueCount": String(count), "skippedCount": String(skipped.count), "selectionId": opaqueID(selection)]
        fields["commandId"] = checkpoint(selection)?.commandID ?? selectionCommands[selection]
        fields["metadataOnlyCount"] = String(checkpoint(selection)?.entries.filter { $0.match.confidence == .metadataOnly }.count ?? 0)
        fields["cleanFallbackCount"] = String(checkpoint(selection)?.entries.filter { $0.match.confidence == .cleanFallback }.count ?? 0)
        TestDiagnostics.record("native.queue", fields: fields)
        recordQueueProbe(trigger: phase)
        if phase == "recovery_started" || phase == "recovery_suppressed" { recordDiagnosticState() }
    }

    private nonisolated func opaqueID(_ value: UUID) -> String {
        value.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func diagnosticCode(_ value: Error) -> String {
        if let value = value as? MusicTokenRequestError { return "Diagnostic: MusicKit \(value.rawValue)." }
        let error = value as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        return "Diagnostic: \(error.domain), code \(error.code)." + (underlying.map { " Underlying: \($0.domain), code \($0.code)." } ?? "")
    }

    // Diagnostic reads only: never reconcile, persist, or mutate the player from this probe.
    private func recordQueueProbe(trigger: String) {
        guard TestDiagnostics.shared.isEnabled else {
            queueProbeSubscriptions.removeAll()
            queueProbePrevious = nil
            return
        }
        if queueProbeSubscriptions.isEmpty {
            queueProbeSubscriptions = [
                SystemMusicPlayer.shared.queue.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self, TestDiagnostics.shared.isEnabled else { return }
                        self.queueProbeSignals += 1
                        self.recordQueueProbe(trigger: "queueSignal")
                    }
                },
                SystemMusicPlayer.shared.state.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self, TestDiagnostics.shared.isEnabled else { return }
                        self.queueProbeStateSignals += 1
                        self.recordQueueProbe(trigger: "modeSignal")
                    }
                }
            ]
        }
        func hash(_ value: String?) -> String {
            guard let value, !value.isEmpty else { return "none" }
            return SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        let observed = readNativePlayer()
        let current = journal.current
        let occurrence = current?.occurrence(catalogID: observed.catalogID, nativeIndex: observed.nativeIndex)
        let predicted = observed.nativeIndex + (current?.nativeOffset ?? 0)
        let predictedID = current.flatMap { $0.entries.indices.contains(predicted) ? $0.entries[predicted].match.track.id : nil }
        let matching = current?.entries.indices.filter { current?.entries[$0].match.track.id == observed.catalogID } ?? []
        var classification = "initial"
        var delta = 0
        if let previous = queueProbePrevious {
            delta = (occurrence ?? observed.nativeIndex) - (previous.occurrence ?? previous.index)
            if previous.revision != current?.revision { classification = "rebase" }
            else if previous.id == observed.catalogID { classification = previous.index == observed.nativeIndex ? "unchanged" : "rebase" }
            else if occurrence == nil { classification = matching.isEmpty ? "foreign" : "rebase" }
            else { classification = delta == 1 ? "sequential" : "jump" }
        }
        queueProbePrevious = (observed.catalogID, observed.nativeIndex, occurrence, current?.revision)
        let mkState = SystemMusicPlayer.shared.state
        let fields: [String: String] = [
            "qpTrigger": trigger, "qpIndex": String((0...100000).contains(player.indexOfNowPlayingItem) ? player.indexOfNowPlayingItem : -1), "qpRaw": String((0...100000).contains(observed.nativeIndex) ? observed.nativeIndex : -1),
            "qpStore": hash(observed.catalogID), "qpPredict": hash(predictedID), "qpOcc": String(occurrence ?? -1),
            "qpCursor": String(current?.cursor ?? -1), "qpOffset": String(current?.nativeOffset ?? -1),
            "qpSubmitted": String(current?.submittedCount ?? 0), "qpPending": String(current?.pendingAppendEnd ?? -1),
            "qpRev": hash(current?.revision.uuidString), "qpFence": hash(sharedRecord?.fence.uuidString),
            "qpOwner": hash(sharedRecord?.ownerBundleID), "qpOwnState": sharedRecord?.state.rawValue ?? "none",
            "qpCmd": hash(current?.commandID), "qpGen": hash(generation.uuidString),
            "qpCV": String(commandVersion), "qpIV": String(intentVersion),
            "qpMPS": String(player.shuffleMode.rawValue), "qpMPR": String(player.repeatMode.rawValue),
            "qpMKS": mkState.shuffleMode.map { String(describing: $0) } ?? "nil",
            "qpMKR": mkState.repeatMode.map { String(describing: $0) } ?? "nil",
            "qpEntry": hash(SystemMusicPlayer.shared.queue.currentEntry.map { String(describing: $0.id) }),
            // shortcut: the public system-player Queue has no entries collection; revisit when Apple exposes it.
            "qpEntries": "-1", "qpQSig": String(queueProbeSignals), "qpSSig": String(queueProbeStateSignals),
            "qpClass": classification, "qpDelta": String(delta),
            "qpPos": String(observed.position.isFinite ? Int(max(0, min(86400, observed.position)) * 1000) : -1),
            "qpState": String(observed.rawState), "qpFooter": hash(footer.text), "qpAction": footer.action?.rawValue ?? "none"
        ]
        TestDiagnostics.record("native.queueProbe", fields: fields)
    }

    private func recordDiagnosticState() {
        guard TestDiagnostics.shared.isEnabled else { lastDiagnosticState = ""; return }
        let current = journal.current
        let observed = playerReading ?? readNativePlayer()
        let catalogID = observed.catalogID
        let nativeIndex = observed.nativeIndex
        let catalogIDPresent = catalogID.map { !$0.isEmpty } ?? false
        let occurrence = current?.occurrence(catalogID: catalogID, nativeIndex: nativeIndex)
        let indexUnavailable = !playerReadingIsStable || starvedWhileActive || observingEnd ||
            (awaitingPlay && current.map { $0.cursor >= $0.submittedCount } == true)
        let index = current?.terminal == .active && !indexUnavailable ? occurrence : nil
        let ownershipReason: String
        if let current {
            if current.terminal != .active { ownershipReason = "inactive_checkpoint" }
            else if !observed.itemPresent { ownershipReason = "missing_item" }
            else if !catalogIDPresent { ownershipReason = "missing_catalog_id" }
            else if nativeIndex < 0 || nativeIndex >= current.submittedCount - current.nativeOffset {
                ownershipReason = "invalid_native_index"
            } else { ownershipReason = occurrence == nil ? "id_mismatch" : "mapped" }
        } else { ownershipReason = "no_checkpoint" }
        let catalogMatchCount = current.map { checkpoint in
            checkpoint.entries[checkpoint.nativeOffset..<checkpoint.submittedCount].filter {
                catalogIDPresent && $0.match.track.id == catalogID
            }.count
        } ?? 0
        let fields = ["state": state, "index": String(index ?? -1), "queueCount": String(current?.submittedCount ?? 0),
            "rawPlaybackState": String(observed.rawState),
            "itemPresent": String(observed.itemPresent), "synchronized": String(snapshot.synchronized),
            "preparing": String(preparing), "active": String(active), "authorized": String(authorized),
            "rawNativeIndex": String((0...1000).contains(nativeIndex) ? nativeIndex : -1),
            "catalogIDPresent": String(catalogIDPresent), "savedCursor": String(current?.cursor ?? -1),
            "nativeOffset": String(current?.nativeOffset ?? -1), "catalogMatchCount": String(catalogMatchCount),
            "matchAtNativeIndex": String(occurrence != nil), "ownershipReason": ownershipReason]
        let key = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
        guard key != lastDiagnosticState else { return }
        lastDiagnosticState = key
        TestDiagnostics.record("native.state", fields: fields.merging(["positionMs": String(Int(position * 1_000))]) { _, new in new })
    }
}
