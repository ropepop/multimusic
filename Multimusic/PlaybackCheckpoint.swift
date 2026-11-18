import Foundation

struct PlaybackNativeObservation: Equatable, Sendable {
    func acceptsTransport(_ command: PlaybackCommand, from index: Int, to observed: Int?) -> Bool {
        guard let observed else { return false }
        switch command {
        case .next: return observed > index
        case .previous: return observed < index || (observed == index && position < 1)
        default: return false
        }
    }

    let catalogID: String?
    let nativeIndex: Int
    let position: Double
    let duration: Double
    let rawState: Int
    var itemPresent = true

    var state: String { rawState == 1 || rawState == 4 || rawState == 5 ? "playing" : rawState == 2 || rawState == 3 ? "paused" : "stopped" }

    func hasSameItemAndState(as other: Self) -> Bool {
        catalogID == other.catalogID && nativeIndex == other.nativeIndex && rawState == other.rawState && itemPresent == other.itemPresent
    }

    func agrees(with other: Self) -> Bool {
        hasSameItemAndState(as: other) && (0...5).contains(rawState) &&
            position.isFinite && other.position.isFinite && (0...86_400).contains(position) && (0...86_400).contains(other.position) &&
            duration.isFinite && other.duration.isFinite && (0...86_400).contains(duration) && (0...86_400).contains(other.duration) &&
            abs(position - other.position) <= 0.25 && abs(duration - other.duration) <= 0.25
    }
}

struct PlaybackRecoveryConfirmation {
    let rebasedTarget: PlaybackCheckpoint.RecoveryTarget
    private var previous: (value: PlaybackNativeObservation, target: PlaybackCheckpoint.RecoveryTarget, date: Date)?

    init(rebasedTarget: PlaybackCheckpoint.RecoveryTarget) {
        self.rebasedTarget = rebasedTarget
    }

    mutating func reset() { previous = nil }

    mutating func accepts(_ value: PlaybackNativeObservation, target: PlaybackCheckpoint.RecoveryTarget,
                         at now: Date) -> Bool {
        guard value.rawState == 1, value.itemPresent, value.agrees(with: value),
              target.occurrence == rebasedTarget.occurrence,
              (0...rebasedTarget.nativeOffset).contains(target.nativeOffset),
              value.nativeIndex == target.occurrence - target.nativeOffset else { previous = nil; return false }
        if let previous, previous.target == target, previous.value.hasSameItemAndState(as: value) {
            let elapsed = now.timeIntervalSince(previous.date)
            guard elapsed.isFinite, elapsed >= 0, abs(value.duration - previous.value.duration) <= 0.25,
                  value.position >= previous.value.position - 0.25,
                  value.position - previous.value.position <= elapsed + 0.25 else { self.previous = nil; return false }
            return elapsed >= (target.nativeOffset == 0 ? 0.075 : 2)
        }
        previous = (value, target, now)
        return false
    }
}

struct PlaybackOccurrence: Codable, Equatable, Sendable {
    let sourceOrdinal: Int
    let source: SourceTrack
    let match: MatchDecision
}

struct PlaybackQueueIdentity: Codable, Equatable, Sendable {
    let storeIDs: [String]
    init(_ checkpoint: PlaybackCheckpoint) {
        storeIDs = checkpoint.entries[checkpoint.nativeOffset..<checkpoint.submittedCount].map { $0.match.track.id }
    }
    func contains(catalogID: String?, nativeIndex: Int) -> Bool {
        storeIDs.indices.contains(nativeIndex) && storeIDs[nativeIndex] == catalogID
    }
}

struct SkippedRow: Identifiable, Equatable, Sendable {
    enum RetryState: String, Sendable { case retrying = "Retrying…", retried = "Retried" }
    let id: Int
    let source: SourceTrack
    let reason: MatchSkipReason?
    let retryState: RetryState?
}

struct PlaybackCheckpoint: Codable, Equatable, Sendable {
    enum Terminal: String, Codable, Sendable { case active, cleared, completed }
    struct SeekTarget: Equatable, Sendable {
        let queueRevision: UUID
        let occurrence: Int
        let ownershipFence: UUID
    }
    struct RecoveryTarget: Equatable, Sendable {
        let occurrence: Int
        let nativeOffset: Int
    }
    var revision = UUID()
    var sources: [SourceTrack]
    var context: SourceContext?
    var country: String
    var commandID: String?
    var entries: [PlaybackOccurrence] = []
    var processedCount = 0
    var skipReasons: [Int: MatchSkipReason]?
    var retryOf: [Int: Int]?
    var resolutionComplete = false
    var submittedCount = 0
    var nativeOffset = 0
    var cursor = 0
    var position = 0.0
    var intendedPlaying = true
    var terminal = Terminal.active
    var observedAt = Date()
    var pendingAppendEnd: Int?
    var legacy = false

    var retryableRoots: [Int] {
        guard (retryOf?.count ?? 0) < 10 else { return [] }
        let retried = Set(retryOf?.values.map { $0 } ?? [])
        let base = sources.count - (retryOf?.count ?? 0)
        return (0..<base).filter { ordinal in
            !retried.contains(ordinal) && skipReasons?[ordinal].map(RetryPolicy.isRetryable) == true
        }
    }

    var skippedRows: [SkippedRow] {
        let retries = retryOf ?? [:]
        let base = sources.count - retries.count
        let matched = Set(entries.map(\.sourceOrdinal))
        return (0..<min(base, processedCount)).compactMap { ordinal in
            guard !matched.contains(ordinal) else { return nil }
            let retry = retries.first { $0.value == ordinal }?.key
            if let retry, matched.contains(retry) { return nil }
            return SkippedRow(id: ordinal, source: sources[ordinal],
                reason: retry.flatMap { skipReasons?[$0] } ?? skipReasons?[ordinal],
                retryState: retry.map { $0 < processedCount ? .retried : .retrying })
        }
    }

    private var validRetries: Bool {
        let retries = retryOf ?? [:]
        let base = sources.count - retries.count
        guard (1...50).contains(base), retries.count <= 10, retryOf == nil || !retries.isEmpty,
              Set(retries.keys) == Set(base..<sources.count), Set(retries.values).count == retries.count else { return false }
        return retries.allSatisfy { retry, original in
            (0..<base).contains(original) && sources[retry] == sources[original] &&
                skipReasons?[original].map(RetryPolicy.isRetryable) == true
        }
    }

    var isValid: Bool {
        validRetries && entries.count <= sources.count &&
        (0...sources.count).contains(processedCount) && (0...entries.count).contains(submittedCount) &&
        (0...submittedCount).contains(nativeOffset) && (0...entries.count).contains(cursor) &&
        position.isFinite && position >= 0 && position <= 86_400 &&
        (commandID.map { $0.range(of: #"^[a-f0-9]{32}\z"#, options: .regularExpression) != nil } ?? true) &&
        entries.allSatisfy { sources.indices.contains($0.sourceOrdinal) && $0.sourceOrdinal < processedCount &&
            sources[$0.sourceOrdinal] == $0.source && !$0.match.track.id.isEmpty &&
            ($0.match.track.duration.map { $0.isFinite && $0 > 0 && $0 <= 86_400 } ?? false) } &&
        zip(entries, entries.dropFirst()).allSatisfy { $0.sourceOrdinal < $1.sourceOrdinal } &&
        (skipReasons.map { reasons in
            reasons.count <= processedCount && reasons.keys.allSatisfy { ordinal in
                sources.indices.contains(ordinal) && ordinal < processedCount &&
                    !entries.contains { $0.sourceOrdinal == ordinal }
            }
        } ?? true) &&
        (pendingAppendEnd.map { $0 >= submittedCount && $0 <= entries.count } ?? true)
    }

    func occurrence(catalogID: String?, nativeIndex: Int) -> Int? {
        guard nativeIndex >= 0, nativeIndex < submittedCount - nativeOffset else { return nil }
        let ordinal = nativeOffset + nativeIndex
        guard entries.indices.contains(ordinal), entries[ordinal].match.track.id == catalogID else { return nil }
        return ordinal
    }

    func recoveryTarget(catalogID: String?, nativeIndex: Int) -> RecoveryTarget? {
        if let ordinal = occurrence(catalogID: catalogID, nativeIndex: nativeIndex) {
            return ordinal >= cursor ? RecoveryTarget(occurrence: ordinal, nativeOffset: nativeOffset) : nil
        }
        guard nativeIndex >= 0, nativeIndex < submittedCount - nativeOffset else { return nil }
        let matches = entries.prefix(submittedCount).indices.filter { entries[$0].match.track.id == catalogID }
        guard matches.count == 1, let ordinal = matches.first, ordinal >= cursor,
              ordinal - nativeIndex >= nativeOffset else { return nil }
        return RecoveryTarget(occurrence: ordinal, nativeOffset: ordinal - nativeIndex)
    }

    func playingRecoveryTarget(catalogID: String?, nativeIndex: Int, recovering target: RecoveryTarget) -> RecoveryTarget? {
        guard target.occurrence >= cursor, target.occurrence < submittedCount,
              nativeIndex >= 0, nativeIndex <= target.occurrence,
              entries[target.occurrence].match.track.id == catalogID else { return nil }
        let offset = target.occurrence - nativeIndex
        guard offset <= target.nativeOffset else { return nil }
        // An index correction is identifiable only for a unique prepared occurrence.
        if offset != target.nativeOffset,
           entries.prefix(submittedCount).filter({ $0.match.track.id == catalogID }).count != 1 { return nil }
        return RecoveryTarget(occurrence: target.occurrence, nativeOffset: offset)
    }

    func seekTarget(catalogID: String?, nativeIndex: Int, ownershipFence: UUID) -> SeekTarget? {
        guard terminal == .active, let ordinal = occurrence(catalogID: catalogID, nativeIndex: nativeIndex) else { return nil }
        return SeekTarget(queueRevision: revision, occurrence: ordinal, ownershipFence: ownershipFence)
    }

    var remainingSubmittedDuration: Double? {
        guard cursor < submittedCount, entries.indices.contains(cursor) else { return nil }
        let durations = entries[cursor..<submittedCount].compactMap { $0.match.track.duration }
        guard durations.count == submittedCount - cursor else { return nil }
        return max(0, durations.reduce(0, +) - position)
    }

    func mayAutomaticallyRestore(at now: Date) -> Bool {
        guard isValid, !legacy, terminal == .active, intendedPlaying, pendingAppendEnd == nil,
              let remaining = remainingSubmittedDuration, remaining > 0 else { return false }
        let elapsed = now.timeIntervalSince(observedAt)
        return elapsed.isFinite && elapsed >= 0 && elapsed < remaining
    }

    func mayAutomaticallyResume(catalogID: String?, nativeIndex: Int, at now: Date) -> Bool {
        mayAutomaticallyRestore(at: now) && recoveryTarget(catalogID: catalogID, nativeIndex: nativeIndex) != nil
    }

    func mayAutomaticallyRestoreEmptyQueue(itemPresent: Bool, nativeStopped: Bool, latestPlayingIntent: Bool, at now: Date) -> Bool {
        !itemPresent && nativeStopped && latestPlayingIntent && mayAutomaticallyRestore(at: now)
    }

    @discardableResult
    mutating func captureObservation(_ first: PlaybackNativeObservation, confirmedBy second: PlaybackNativeObservation,
                                    desiredPlaying: Bool?, at now: Date) -> Bool {
        // A stopped retained queue keeps its original recovery intent and deadline.
        guard terminal == .active, second.itemPresent, first.agrees(with: second),
              let index = occurrence(catalogID: second.catalogID, nativeIndex: second.nativeIndex),
              second.rawState != 0 || !intendedPlaying || desiredPlaying == false else { return false }
        cursor = index
        position = second.position
        intendedPlaying = desiredPlaying ?? (second.state == "playing")
        observedAt = now
        return true
    }

    func observedSubmittedEnd(index: Int, position: Double, nativeDuration: Double, observedAt: Date, now: Date) -> Bool {
        guard terminal == .active, !legacy, intendedPlaying, pendingAppendEnd == nil, submittedCount > 0,
              index == submittedCount - 1, entries.indices.contains(index),
              nativeDuration.isFinite, nativeDuration > 0, nativeDuration <= 86_400,
              position.isFinite, position >= 0 else { return false }
        let remaining = max(0, nativeDuration - position)
        let elapsed = now.timeIntervalSince(observedAt)
        return elapsed.isFinite && elapsed >= remaining && elapsed - remaining <= 2
    }

    func isSubmittedEndReset(catalogID: String?, nativeIndex: Int, position: Double) -> Bool {
        guard position.isFinite, position >= 0, position <= 0.25,
              let index = occurrence(catalogID: catalogID, nativeIndex: nativeIndex) else { return false }
        return index == submittedCount - 1 || (nativeIndex == 0 && index == nativeOffset)
    }
}

struct PlaybackJournal: Codable, Equatable, Sendable {
    var version = 2
    var sequence: UInt64 = 0
    var current: PlaybackCheckpoint?
    var pendingReplacement: PlaybackCheckpoint?
    var clearPending: Bool?
    var clearRequestID: UUID?
    var clearOwners: [PlaybackQueueIdentity]?

    @discardableResult
    mutating func settleClear(requestID: UUID) -> Bool {
        guard clearPending == true, clearRequestID == requestID else { return false }
        clearPending = false
        clearOwners = nil
        return true
    }

    var isValid: Bool {
        version == 2 && (current.map(\.isValid) ?? true) && (pendingReplacement.map(\.isValid) ?? true) &&
        (clearOwners.map { $0.count <= 2 && $0.allSatisfy { $0.storeIDs.count <= 60 && $0.storeIDs.allSatisfy { !$0.isEmpty && $0.count <= 128 } } } ?? true)
    }

    static func decode(_ data: Data) throws -> PlaybackJournal {
        let decoder = JSONDecoder()
        if let journal = try? decoder.decode(PlaybackJournal.self, from: data), journal.isValid { return journal }
        struct Legacy: Decodable { let handoff: QueueHandoff }
        let old = try decoder.decode(Legacy.self, from: data).handoff
        var checkpoint = PlaybackCheckpoint(sources: old.tracks.map(\.source), country: "")
        checkpoint.revision = old.revision
        checkpoint.entries = old.tracks.enumerated().map {
            PlaybackOccurrence(sourceOrdinal: $0.offset, source: $0.element.source,
                               match: MatchDecision(track: $0.element.catalog, confidence: .metadataAndDuration))
        }
        checkpoint.processedCount = old.tracks.count
        checkpoint.resolutionComplete = true
        checkpoint.submittedCount = old.tracks.count
        checkpoint.intendedPlaying = false
        checkpoint.legacy = true
        guard checkpoint.isValid else { throw CocoaError(.coderReadCorrupt) }
        return PlaybackJournal(current: checkpoint)
    }
}

actor PlaybackCheckpointStore {
    private let url: URL
    private var sequence: UInt64 = 0

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("Multimusic/handoff.json")) {
        self.url = url
    }

    func load() -> PlaybackJournal? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 524_288, let data = try? Data(contentsOf: url),
              let journal = try? PlaybackJournal.decode(data) else { return nil }
        sequence = journal.sequence
        return journal
    }

    func save(_ journal: PlaybackJournal) throws {
        guard journal.isValid else { throw CocoaError(.coderInvalidValue) }
        guard journal.sequence >= sequence else { return }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 524_288 else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sequence = journal.sequence
    }

    func remove(ifNotNewerThan expected: UInt64? = nil) throws {
        guard expected.map({ sequence <= $0 }) ?? true else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
