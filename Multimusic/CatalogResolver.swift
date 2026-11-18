import Foundation

private actor ResolutionRetries {
    var budget = RetryBudget()
    let onRetry: @Sendable (Int, Int) async -> Void
    init(onRetry: @escaping @Sendable (Int, Int) async -> Void) { self.onRetry = onRetry }
    func take() -> Bool { budget.take() }
}

private enum CatalogRequestContext {
    @TaskLocal static var retries: ResolutionRetries?
}

actor CatalogResolver {
    static let shared = CatalogResolver()

    private let clock = ContinuousClock()
    private var lastRequestStart: ContinuousClock.Instant?
    private var throttledUntil: ContinuousClock.Instant?
    private var cache = CatalogMatchCache()
    private var artistIDCache: [String: String] = [:]
    private var dirty = false
    private let cacheURL = URL.applicationSupportDirectory.appendingPathComponent("Multimusic/catalog-cache.json")

    private init() {
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152,
           let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode(CatalogMatchCache.self, from: data) {
            cache = saved
        }
    }

    func resolve(tracks: [SourceTrack], context: SourceContext?, country: String,
                 onRetry: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                 onProgress: @Sendable ([MatchAssessment]) async -> Void) async throws -> [MatchAssessment] {
        try await CatalogRequestContext.$retries.withValue(ResolutionRetries(onRetry: onRetry)) {
            try await resolveBatch(tracks: tracks, context: context, country: country, onProgress: onProgress)
        }
    }

    private func resolveBatch(tracks: [SourceTrack], context: SourceContext?, country: String,
                              onProgress: @Sendable ([MatchAssessment]) async -> Void) async throws -> [MatchAssessment] {
        guard !tracks.isEmpty, tracks.count <= 50,
              country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
              context.map({ $0.isValid && $0.selectedSourceID == tracks.first?.id }) ?? true else { throw URLError(.badURL) }
        defer { persistCache() }
        var settled: [MatchAssessment] = []
        var initialAlbum: CatalogAlbum?
        var albumResults: [MatchDecision?]?
        if let context, context.kind == .album {
            initialAlbum = try await findAlbum(context, country: country)
            albumResults = initialAlbum?.resolveLenient(tracks, context: context)
        }
        var attemptedAlbum = false
        for (index, source) in tracks.enumerated() {
            try Task.checkCancellation()
            let albumDecision = albumResults?[index]
            var cached = cache.decision(source: source, country: country)
            // Old cache entries predate storefront and content-variant checks.
            if cached?.track.isStreamable != true || RecordingMatcher.derivativePlainTitle(source.title) != nil ||
                cached.map({ RecordingMatcher.decision(source: source, candidates: [$0.track]) == nil }) == true { cached = nil }
            var decision = albumDecision ?? cached
            var fresh = albumDecision != nil
            if index == 0, let title = context?.albumTitle,
               decision?.track.collectionName.map(RecordingMatcher.normalized) != title {
                decision = nil
            }
            var assessment: MatchAssessment
            var candidates: [CatalogTrack] = []
            if let decision {
                assessment = MatchAssessment(decision: decision)
            } else {
                (candidates, assessment) = try await searchCandidates(source, country: country)
                decision = assessment.decision
                fresh = true
                if decision != nil, let title = context?.albumTitle {
                    let sameAlbum = candidates.filter { $0.collectionName.map(RecordingMatcher.normalized) == title }
                    if let sameAlbumDecision = RecordingMatcher.decision(source: source, candidates: sameAlbum) {
                        decision = sameAlbumDecision
                        assessment = MatchAssessment(decision: sameAlbumDecision)
                    }
                }
            }
            try Task.checkCancellation()
            if let decision, fresh {
                cache.store(decision, source: source, country: country)
                dirty = true
            }
            if !assessment.diagnosticFields.isEmpty {
                TestDiagnostics.record("native.match", fields: assessment.diagnosticFields)
            }
            settled.append(assessment)
            await onProgress(settled)
            try Task.checkCancellation()
            if !attemptedAlbum, let context, context.kind == .album,
               let collectionID = decision?.track.collectionID,
               tracks.dropFirst(index + 1).contains(where: { cache.decision(source: $0, country: country) == nil }) {
                attemptedAlbum = true
                do {
                    // Reuse the album only when it supplied this match. A song search may recover a partial or different edition.
                    let album: CatalogAlbum? = if let initialAlbum, initialAlbum.id == collectionID, decision == albumDecision {
                        initialAlbum
                    } else {
                        try await lookupAlbum(id: collectionID, country: country)
                    }
                    try Task.checkCancellation()
                    if let album {
                        albumResults = album.resolve(tracks, context: context)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // Album lookup is an optimization; unresolved songs retain the paced search path.
                }
            }
        }
        return settled
    }

    private func findAlbum(_ context: SourceContext, country: String) async throws -> CatalogAlbum? {
        guard let title = context.albumTitle, let artist = context.artist else { return nil }
        try Task.checkCancellation()
        let data = try await fetch(path: "search", parameters: [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ])
        let albums = try ITunesCatalog.albumCandidates(from: data)
        guard let candidate = albums.first(where: {
            RecordingMatcher.normalized($0.title) == title &&
            RecordingMatcher.normalized($0.artist) == RecordingMatcher.normalized(artist)
        }) else { return nil }
        try Task.checkCancellation()
        return try await lookupAlbum(id: candidate.id, country: country)
    }

    private func lookupAlbum(id: String, country: String) async throws -> CatalogAlbum? {
        let songs = try await fetch(path: "lookup", parameters: [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200")
        ])
        try Task.checkCancellation()
        guard let album = try ITunesCatalog.album(from: songs), album.id == id else { return nil }
        return album
    }

    /// Direct song search first, then progressively broader terms, then the
    /// artist's own catalog. iTunes Search can omit an exact track that exists
    /// (e.g. "Hot Wet Delirious"): `lookup?entity=song` by artist finds it.
    private func searchCandidates(_ source: SourceTrack, country: String) async throws -> ([CatalogTrack], MatchAssessment) {
        var plainTitleEvidence: [CatalogTrack] = []
        if let plain = RecordingMatcher.derivativePlainTitle(source.title) {
            plainTitleEvidence = try await search(term: "\(plain) \(source.artist)", country: country)
        }
        var bestCandidates: [CatalogTrack] = []
        var bestAssessment = MatchAssessment(skipReason: .noResults)
        for term in CatalogQueryLadder.songSearchTerms(for: source) {
            try Task.checkCancellation()
            let candidates = try await search(term: term, country: country) + plainTitleEvidence
            let assessment = RecordingMatcher.assessment(source: source, candidates: candidates)
            if assessment.decision != nil {
                return (candidates, assessment)
            }
            // A conflict, ambiguous recording, or durationless disagreement is a
            // precision answer, not a recall miss: never widen to overrule it.
            guard CatalogQueryLadder.shouldContinue(after: assessment) else {
                return (candidates, assessment)
            }
            if bestCandidates.isEmpty {
                bestCandidates = candidates
                bestAssessment = assessment
            }
        }
        if let (artistCandidates, assessment) = try await artistCatalogCandidates(source: source, country: country) {
            if assessment.decision != nil {
                return (artistCandidates, assessment)
            }
            // Do not let a broader catalog replace a more specific explanation
            // unless the earlier queries returned nothing usable at all.
            if bestCandidates.isEmpty {
                return (artistCandidates, assessment)
            }
        }
        return (bestCandidates, bestAssessment)
    }

    /// Tries each bounded artist term and assesses the catalog before stopping,
    /// so one non-matching artist result cannot block the primary-artist term.
    private func artistCatalogCandidates(source: SourceTrack, country: String)
        async throws -> ([CatalogTrack], MatchAssessment)? {
        var firstNonEmpty: ([CatalogTrack], MatchAssessment)?
        var seenArtistIDs = Set<String>()
        for term in CatalogQueryLadder.artistSearchTerms(source.artist) {
            try Task.checkCancellation()
            let artistID: String
            if let cached = artistIDCache[term.lowercased()] {
                artistID = cached
            } else {
                let data = try await fetch(path: "search", parameters: [
                    URLQueryItem(name: "term", value: term),
                    URLQueryItem(name: "country", value: country.lowercased()),
                    URLQueryItem(name: "media", value: "music"),
                    URLQueryItem(name: "entity", value: "musicArtist"),
                    URLQueryItem(name: "limit", value: "10")
                ])
                guard let found = try ITunesCatalog.artistID(from: data, matching: term) else { continue }
                artistID = found
                artistIDCache[term.lowercased()] = found
            }
            guard seenArtistIDs.insert(artistID).inserted else { continue }
            try Task.checkCancellation()
            let songs = try await fetch(path: "lookup", parameters: [
                URLQueryItem(name: "id", value: artistID),
                URLQueryItem(name: "country", value: country.lowercased()),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "200")
            ])
            let tracks = try ITunesCatalog.tracks(from: songs)
            guard !tracks.isEmpty else { continue }
            let assessment = RecordingMatcher.assessment(source: source, candidates: tracks)
            if assessment.decision != nil { return (tracks, assessment) }
            if firstNonEmpty == nil { firstNonEmpty = (tracks, assessment) }
        }
        return firstNonEmpty
    }

    private func search(term: String, country: String) async throws -> [CatalogTrack] {
        let data = try await fetch(path: "search", parameters: [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country.lowercased()),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25")
        ])
        return try ITunesCatalog.tracks(from: data)
    }

    private func fetch(path: String, parameters: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = parameters
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var failures = 0
        while true {
            try Task.checkCancellation()
            // Recheck after every suspension: other resolves share this request-start gate.
            while let lastRequestStart {
                let interval: Duration = throttledUntil.map { clock.now < $0 } == true ? .milliseconds(6_200) : .milliseconds(3_100)
                let next = lastRequestStart.advanced(by: interval)
                guard clock.now < next else { break }
                try await clock.sleep(until: next)
                try Task.checkCancellation()
            }
            lastRequestStart = clock.now
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard response.statusCode == 200 else {
                    let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { value -> Double? in
                        if let seconds = Double(value), seconds.isFinite { return seconds }
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.timeZone = TimeZone(secondsFromGMT: 0)
                        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                        return formatter.date(from: value)?.timeIntervalSinceNow
                    }
                    throw NSError(domain: "iTunesHTTP", code: response.statusCode,
                                  userInfo: retryAfter.map { ["retryAfter": $0] } ?? [:])
                }
                let maximumBytes = 1_048_576
                guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                try Task.checkCancellation()
                if failures > 0 { await CatalogRequestContext.retries?.onRetry(0, 0) }
                return data
            } catch {
                try Task.checkCancellation()
                failures += 1
                let kind = RetryPolicy.classify(error)
                if kind == .throttled { throttledUntil = clock.now.advanced(by: .seconds(120)) }
                guard let delay = RetryPolicy.delay(afterFailure: failures, kind,
                          retryAfter: (error as NSError).userInfo["retryAfter"] as? Double),
                      let retries = CatalogRequestContext.retries, await retries.take() else { throw error }
                await retries.onRetry(failures + 1, kind == .throttled ? 2 : 3)
                try await Task.sleep(for: delay)
            }
        }
    }

    private func persistCache() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            dirty = false
        } catch {
            // A cache write failure must not interrupt playback or discard its in-memory matches.
        }
    }
}
