import Foundation

public enum RetryClass: Equatable, Sendable {
    case transport, throttled, never
}

public enum RetryPolicy {
    public static let resumeDelays: [Duration] = [.seconds(15), .seconds(45)]
    public static let maximumRetries = 6

    public static func classify(_ error: Error) -> RetryClass {
        if error is CancellationError { return .never }
        let error = error as NSError
        if error.domain == "iTunesHTTP" {
            if [403, 429].contains(error.code) { return .throttled }
            return [500, 502, 503, 504].contains(error.code) ? .transport : .never
        }
        guard error.domain == NSURLErrorDomain else { return .never }
        return [URLError.timedOut, .notConnectedToInternet, .networkConnectionLost,
                .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed].contains { $0.rawValue == error.code }
            ? .transport : .never
    }

    public static func delay(afterFailure failure: Int, _ kind: RetryClass, retryAfter: Double? = nil) -> Duration? {
        switch (kind, failure) {
        case (.transport, 1): .seconds(2)
        case (.transport, 2): .seconds(6)
        case (.throttled, 1): .seconds(max(10, min(30, retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? 0)))
        default: nil
        }
    }

    public static func isRetryable(_ reason: MatchSkipReason) -> Bool {
        reason == .noResults || reason == .noCompatibleMetadata
    }
}

public struct RetryBudget: Sendable {
    public private(set) var retries = 0
    public init() {}
    public mutating func take() -> Bool {
        guard retries < RetryPolicy.maximumRetries else { return false }
        retries += 1
        return true
    }
}

public struct FooterInput: Sendable {
    public var playbackEnabled = true
    public var authorized = true
    public var site = "YouTube Music"
    public var problem: String?
    public var unconfirmed = false
    public var committing = false
    public var pendingReplacement = false
    public var noMatch = false
    public var preSubmission = false
    public var failed = false
    public var canRetryMatching = true
    public var owned = false
    public var matching = false
    public var paused = false
    public var retryAttempt: Int?
    public var retryLimit = 3
    public var retryingSkipped = 0
    public var submittedCount = 0
    public var processedCount = 0
    public var sourceCount = 0
    public var skippedCount = 0
    public var retryableSkips = 0
    public var savedRemaining: Int?
    public var finished = false
    public var cleared = false
    public init() {}
}

public struct FooterState: Equatable, Sendable {
    public enum Action: String, Sendable { case reset = "Reset", retry = "Retry", connect = "Connect", restore = "Restore", replay = "Replay", details = "Details" }
    public let text: String
    public let accessibilityText: String
    public let action: Action?
    public let skippedCount: Int
    public let announce: Bool

    public static func make(_ input: FooterInput) -> Self {
        func row(_ text: String, _ accessibility: String? = nil, action: Action? = nil,
                 chip: Bool = false, announce: Bool = false) -> Self {
            Self(text: text, accessibilityText: accessibility ?? text, action: action,
                 skippedCount: chip ? input.skippedCount : 0, announce: announce)
        }
        if !input.playbackEnabled { return row("Browse \(input.site)") }
        if !input.authorized { return row("Apple Music not connected", action: .connect) }
        if input.unconfirmed { return row("Music’s last request is unconfirmed", action: .reset, announce: true) }
        if let problem = input.problem {
            let sentence = problem.split(separator: ".", maxSplits: 1).first.map(String.init) ?? problem
            return row(sentence, action: .details, announce: true)
        }
        if input.committing { return row("Starting in Music…") }
        if input.noMatch { return row("No match · Music unchanged") }
        if input.preSubmission {
            if input.failed { return row("Couldn't reach catalog · Music unchanged", action: .retry, announce: true) }
            if let attempt = input.retryAttempt {
                return row("Retrying \(attempt) of \(input.retryLimit)…", "Retrying catalog request, attempt \(attempt) of \(input.retryLimit)", chip: true)
            }
            return row("Matching \(min(input.processedCount + 1, input.sourceCount)) of \(input.sourceCount)",
                       "Matching song \(min(input.processedCount + 1, input.sourceCount)) of \(input.sourceCount)", chip: true)
        }
        if input.owned && !input.finished && !input.cleared {
            let title = "\(input.submittedCount) in Music"
            let spoken = "\(input.submittedCount) songs in Apple Music"
            if input.paused { return row(title + " · matching paused", spoken + ", matching paused", action: input.failed && input.canRetryMatching ? .retry : nil, announce: input.failed) }
            if let attempt = input.retryAttempt {
                return row(title + " · retrying \(attempt) of \(input.retryLimit)", spoken + ", retrying catalog request, attempt \(attempt) of \(input.retryLimit)", chip: true)
            }
            if input.retryingSkipped > 0 {
                return row(title + " · retrying \(input.retryingSkipped) skipped", spoken + ", retrying \(input.retryingSkipped) skipped songs", chip: true)
            }
            if input.matching {
                let ordinal = min(input.processedCount + 1, input.sourceCount)
                return row(title + " · matching \(ordinal) of \(input.sourceCount)", spoken + ", matching song \(ordinal) of \(input.sourceCount)", chip: true)
            }
            return row(title, spoken, action: input.retryableSkips > 0 ? .retry : nil, chip: true)
        }
        if let remaining = input.savedRemaining, !input.finished, !input.cleared, !input.matching, !input.pendingReplacement {
            return row("Saved queue · \(remaining) left", "Saved queue, \(remaining) songs left", action: .restore, chip: true)
        }
        if input.finished { return row("Queue finished", action: !input.matching && !input.pendingReplacement ? .replay : nil, chip: true) }
        if input.cleared { return row("Queue cleared") }
        return row("Choose a song")
    }
}
