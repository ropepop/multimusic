import Foundation

public enum CatalogExplicitness: String, Codable, Sendable { case explicit, notExplicit, cleaned }

public struct CatalogTrack: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let duration: Double?
    public let isrc: String?
    public let isExplicit: Bool?
    public let isStreamable: Bool?
    public let explicitness: CatalogExplicitness?
    public let collectionID: String?
    public let collectionName: String?

    public init(id: String, title: String, artist: String, duration: Double? = nil, isrc: String? = nil, isExplicit: Bool? = nil,
                collectionID: String? = nil, collectionName: String? = nil,
                isStreamable: Bool? = nil, explicitness: CatalogExplicitness? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.isrc = isrc
        self.isExplicit = isExplicit
        self.isStreamable = isStreamable
        self.explicitness = explicitness ?? isExplicit.map { $0 ? .explicit : .notExplicit }
        self.collectionID = collectionID
        self.collectionName = collectionName
    }
}

public enum MatchConfidence: String, Codable, Sendable {
    case recordingIdentity, metadataAndDuration, metadataOnly, cleanFallback
}

public struct MatchDecision: Codable, Equatable, Sendable {
    public let track: CatalogTrack
    public let confidence: MatchConfidence

    public init(track: CatalogTrack, confidence: MatchConfidence) {
        self.track = track
        self.confidence = confidence
    }
}

public enum MatchSkipReason: String, Codable, Sendable {
    case invalidSource, noResults, noCompatibleMetadata, contentConflict
    case insufficientDurationlessAgreement, ambiguousRecording
    case unavailableInStorefront, thirdPartyEdit

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Preserve saved queues from before cleaned recordings were allowed.
        if value == "explicitOriginalUnavailable" { self = .noCompatibleMetadata; return }
        guard let reason = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown match skip reason")
        }
        self = reason
    }
}

public struct MatchAssessment: Equatable, Sendable {
    public let decision: MatchDecision?
    public let skipReason: MatchSkipReason?
    public let diagnosticFields: [String: String]

    public init(decision: MatchDecision) {
        self.decision = decision
        self.skipReason = nil
        self.diagnosticFields = [:]
    }

    public init(skipReason: MatchSkipReason, diagnosticFields: [String: String] = [:]) {
        self.decision = nil
        self.skipReason = skipReason
        self.diagnosticFields = diagnosticFields
    }
}

public enum RecordingMatcher {
    public static func match(source: SourceTrack, candidates: [CatalogTrack]) -> CatalogTrack? {
        decision(source: source, candidates: candidates)?.track
    }

    public static func decision(source: SourceTrack, candidates: [CatalogTrack]) -> MatchDecision? {
        assessment(source: source, candidates: candidates).decision
    }

    public static func assessment(source: SourceTrack, candidates allCandidates: [CatalogTrack]) -> MatchAssessment {
        let title = normalizedTitle(source.title)
        let artist = normalizedArtist(source.artist)
        guard !source.id.isEmpty, !title.isEmpty, !artist.isEmpty else { return MatchAssessment(skipReason: .invalidSource) }
        if let duration = source.duration, !duration.isFinite || duration <= 0 { return MatchAssessment(skipReason: .invalidSource) }
        if let label = contentLabel(source.title), let explicit = source.isExplicit, label != explicit { return MatchAssessment(skipReason: .invalidSource) }
        if let plain = derivativePlainTitle(source.title), !allCandidates.contains(where: {
            contentVariantTitle($0.title) == plain && artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                candidateTitle: $0.title, candidateArtist: $0.artist)
        }) { return MatchAssessment(skipReason: .thirdPartyEdit) }
        guard !allCandidates.isEmpty else { return MatchAssessment(skipReason: .noResults) }
        let candidates = allCandidates.filter { $0.isStreamable != false }
        guard !candidates.isEmpty else { return MatchAssessment(skipReason: .unavailableInStorefront) }
        let sourceISRC = normalizedISRC(source.isrc)
        let sourceExplicit = source.isExplicit ?? contentLabel(source.title)

        if sourceExplicit == nil, sourceISRC == nil {
            let variants = candidates.filter {
                artistMatches(sourceArtist: source.artist, sourceTitle: source.title, candidateTitle: $0.title, candidateArtist: $0.artist) && contentVariantTitle($0.title) == contentVariantTitle(source.title)
            }
            let explicitValues = Set(variants.compactMap { $0.isExplicit ?? contentLabel($0.title) })
            guard explicitValues.count < 2 else { return MatchAssessment(skipReason: .contentConflict) }
        }

        func eligible(_ candidate: CatalogTrack, allowClean: Bool) -> Bool {
            guard !candidate.id.isEmpty,
                  contentVariantTitle(candidate.title) == contentVariantTitle(source.title),
                  artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                                candidateTitle: candidate.title, candidateArtist: candidate.artist) else { return false }
            if let duration = candidate.duration, !duration.isFinite || duration <= 0 { return false }
            if let label = contentLabel(candidate.title), let explicit = candidate.isExplicit, label != explicit { return false }
            if let sourceExplicit {
                let candidateExplicit = candidate.isExplicit ?? contentLabel(candidate.title)
                if candidateExplicit != sourceExplicit {
                    let cleanFallback = allowClean && sourceExplicit == true && candidateExplicit == false &&
                        (candidate.explicitness == .notExplicit || candidate.explicitness == .cleaned)
                    if !cleanFallback { return false }
                }
            }
            let candidateISRC = normalizedISRC(candidate.isrc)
            // Sources currently carry no ISRC. If an ISRC is ever added, a clean
            // edit with its own ISRC would stop matching on this line.
            if let sourceISRC, sourceISRC != candidateISRC { return false }
            if let sourceDuration = source.duration, let candidateDuration = candidate.duration {
                return abs(sourceDuration - candidateDuration) <= max(2, min(5, sourceDuration * 0.02))
            }
            return source.duration == nil || (sourceISRC != nil && sourceISRC == candidateISRC)
        }

        var matches = candidates.filter { eligible($0, allowClean: false) }
        var cleanFallback = false
        if matches.isEmpty, sourceExplicit == true {
            // Only fall back to a clean recording when no streamable explicit recording
            // passes title+artist at all. An explicit version that merely
            // missed on duration must not lose to a clean edit.
            let hasExplicitTitleArtist = candidates.contains { candidate in
                !candidate.id.isEmpty &&
                contentVariantTitle(candidate.title) == contentVariantTitle(source.title) &&
                artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                              candidateTitle: candidate.title, candidateArtist: candidate.artist) &&
                (candidate.isExplicit ?? contentLabel(candidate.title)) == true
            }
            if !hasExplicitTitleArtist {
                let clean = candidates.filter { eligible($0, allowClean: true) }
                if !clean.isEmpty {
                    matches = clean
                    cleanFallback = true
                }
            }
        }
        guard Set(matches.compactMap { $0.isExplicit ?? contentLabel($0.title) }).count < 2 else { return MatchAssessment(skipReason: .contentConflict) }
        guard !matches.isEmpty else { return MatchAssessment(skipReason: .noCompatibleMetadata) }
        if source.duration == nil, sourceISRC == nil {
            func rejected(_ guardName: String, groups: [Int], tracks: [CatalogTrack], tiedSpan: Double? = nil) -> MatchAssessment {
                var fields = [
                    "durationlessGuard": guardName,
                    "durationGroupCounts": groups.prefix(16).map(String.init).joined(separator: ","),
                    "distinctISRCCount": String(Set(tracks.compactMap { normalizedISRC($0.isrc) }).count)
                ]
                if let tiedSpan { fields["tiedSpanSeconds"] = String((tiedSpan * 1000).rounded() / 1000) }
                return MatchAssessment(skipReason: .insufficientDurationlessAgreement, diagnosticFields: fields)
            }
            let agreeing = candidates.filter {
                contentVariantTitle($0.title) == contentVariantTitle(source.title) &&
                artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                              candidateTitle: $0.title, candidateArtist: $0.artist)
            }
            let labels = agreeing.compactMap { $0.isExplicit ?? contentLabel($0.title) }
            if labels.count == agreeing.count, Set(labels).count == 1,
               agreeing.allSatisfy({ $0.collectionID != nil }) {
                guard agreeing.allSatisfy({ $0.duration.map { $0.isFinite && $0 > 0 } == true }) else {
                    return rejected("invalidDuration", groups: [0], tracks: agreeing)
                }
                var groups: [[CatalogTrack]] = []
                for candidate in agreeing.sorted(by: { $0.duration! < $1.duration! }) {
                    if let shortest = groups.last?.first?.duration, candidate.duration! - shortest <= 2 {
                        groups[groups.count - 1].append(candidate)
                    } else {
                        groups.append([candidate])
                    }
                }
                let ranked = groups.sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    let left = lhs.map { normalizedISRC($0.isrc) ?? "~" }.min()!
                    let right = rhs.map { normalizedISRC($0.isrc) ?? "~" }.min()!
                    if left != right { return left < right }
                    return lhs.map(\.id).min()! < rhs.map(\.id).min()!
                }
                if let modal = ranked.first {
                    var selected = modal
                    let tied = ranked.filter { $0.count == modal.count }
                    if tied.count > 1 {
                        let durations = tied.flatMap { $0.compactMap(\.duration) }
                        let span = durations.max()! - durations.min()!
                        guard modal.count >= 2, span <= 15,
                              let first = agreeing.first,
                              let group = tied.first(where: { $0.contains(first) }) else {
                            return rejected("tiedDurationGroups", groups: ranked.map(\.count), tracks: agreeing, tiedSpan: span)
                        }
                        selected = group
                    }
                    matches = matches.filter { selected.contains($0) }
                }
            }
            matches.sort {
                let left = normalizedISRC($0.isrc) ?? "~", right = normalizedISRC($1.isrc) ?? "~"
                return left == right ? $0.id < $1.id : left < right
            }
            let explicitness = matches.compactMap { $0.isExplicit ?? contentLabel($0.title) }
            let durations = matches.compactMap(\.duration)
            let codes = matches.compactMap { normalizedISRC($0.isrc) }
            let sameMetadata = matches.allSatisfy {
                normalized($0.title) == normalized(matches[0].title) &&
                normalizedArtist($0.artist) == normalizedArtist(matches[0].artist)
            }
            guard durations.count == matches.count, explicitness.count == matches.count,
                  Set(explicitness).count == 1,
                  let shortest = durations.min(), let longest = durations.max(), longest - shortest <= 2,
                  codes.isEmpty || (codes.count == matches.count && (Set(codes).count == 1 || sameMetadata)) else {
                return rejected("recordingAgreement", groups: [matches.count], tracks: matches)
            }
            // shortcut: source duration is unavailable, replace this evidence with recording identity when supplied.
            return MatchAssessment(decision: MatchDecision(track: matches[0], confidence: cleanFallback ? .cleanFallback : .metadataOnly))
        }
        var seen = Set<String>()
        let unique = matches.filter { seen.insert($0.id).inserted }
        let codes = unique.compactMap { normalizedISRC($0.isrc) }
        let confidence: MatchConfidence = cleanFallback ? .cleanFallback : (sourceISRC == nil ? .metadataAndDuration : .recordingIdentity)
        if unique.count == 1 { return MatchAssessment(decision: MatchDecision(track: unique[0], confidence: confidence)) }
        if codes.count == unique.count, Set(codes).count == 1, let first = unique.min(by: { $0.id < $1.id }) {
            return MatchAssessment(decision: MatchDecision(track: first, confidence: confidence))
        }
        guard codes.isEmpty, let sourceDuration = source.duration else { return MatchAssessment(skipReason: .ambiguousRecording) }
        // shortcut: metadata can conceal unlabeled versions, prefer ISRC when the catalog provides it.
        let equivalents = unique.compactMap { candidate -> (track: CatalogTrack, distance: Double)? in
            guard let duration = candidate.duration else { return nil }
            let distance = abs(sourceDuration - duration)
            return distance <= 2 ? (candidate, distance) : nil
        }
        guard let closest = equivalents.min(by: { $0.distance < $1.distance }) else { return MatchAssessment(skipReason: .ambiguousRecording) }
        return MatchAssessment(decision: MatchDecision(track: closest.track, confidence: confidence))
    }

    /// Artist credits differ by service: a source may list collaborators that
    /// the catalog keeps only in the title ("The Girl Is Mine (with Paul
    /// McCartney)" is credited to Michael Jackson alone on Apple Music).
    /// Accept only when the primary artist agrees and every extra collaborator
    /// is named by the source title or the other credit.
    public static func artistMatches(sourceArtist: String, sourceTitle: String,
                                     candidateTitle: String, candidateArtist: String) -> Bool {
        let source = artistComponents(sourceArtist)
        let candidate = artistComponents(candidateArtist)
        // Same collaborators in a different order or punctuation: "Safety
        // Trance & Arca" vs "Arca & Safety Trance", "FM-3" vs "FM3".
        if source.count == candidate.count,
           source.allSatisfy({ item in candidate.contains { sameArtistComponent($0, item) } }) {
            return true
        }
        guard let sourcePrimary = source.first, let candidatePrimary = candidate.first,
              sameArtistComponent(sourcePrimary, candidatePrimary) else { return false }
        let text = normalized(sourceTitle) + " " + normalized(candidateTitle)
        for extra in source.dropFirst()
        where !candidate.contains(where: { sameArtistComponent($0, extra) }) && !mentions(extra, in: text) {
            return false
        }
        for extra in candidate.dropFirst()
        where !source.contains(where: { sameArtistComponent($0, extra) }) && !mentions(extra, in: text) {
            return false
        }
        return true
    }

    private static func sameArtistComponent(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.replacingOccurrences(of: " ", with: "") == rhs.replacingOccurrences(of: " ", with: "")
    }

    private static func mentions(_ component: String, in text: String) -> Bool {
        if text.contains(component) { return true }
        let compact = component.replacingOccurrences(of: " ", with: "")
        if compact.count > 2 && text.replacingOccurrences(of: " ", with: "").contains(compact) { return true }
        // One-letter spelling drift is common in credits (Elliott / Elliot),
        // but only inside a feat./with clause and with the same initial.
        guard component.count >= 6 else { return false }
        let clause: String
        if let range = text.range(of: "feat ") ?? text.range(of: "with ") {
            clause = String(text[range.lowerBound...])
        } else {
            clause = text
        }
        let target = component.split(separator: " ").map(String.init)
        let words = clause.split(separator: " ").map(String.init)
        guard let first = component.first, words.count >= target.count else { return false }
        for start in 0...(words.count - target.count) {
            let window = words[start..<(start + target.count)].joined(separator: " ")
            guard window.first == first, abs(window.count - component.count) <= 2 else { continue }
            if editDistance(window, component) <= 1 { return true }
        }
        return false
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for i in 1...max(a.count, 1) {
            var current = [i]
            for j in 1...max(b.count, 1) {
                let cost = i <= a.count && j <= b.count && a[i - 1] == b[j - 1] ? 0 : 1
                current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func artistComponents(_ artist: String) -> [String] {
        let cleaned = artist.replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic\s*$"#, with: "", options: .regularExpression)
        var parts = [cleaned]
        for separator in ["&", ",", " feat. ", " featuring "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { normalized($0) }.filter { !$0.isEmpty }
    }

    public static func derivativePlainTitle(_ title: String) -> String? {
        let pattern = #"\b(?:slowed(?:\s+down)?|reverb(?:ed)?|sped\s+up|nightcore|8d|fan\s*made)\b"#
        let title = normalized(title)
        guard title.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:audio|version)\b"#, with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func normalizedTitle(_ title: String) -> String {
        let presentation = #"(?i)\s*(?:[\(\[]\s*(?:official(?:\s+(?:music|lyric))?\s+(?:video|audio)|lyrics?|lyric video|visuali[sz]er)\s*[\)\]]|[-–—]\s*(?:official(?:\s+music)?\s+(?:video|audio)|lyric video))\s*$"#
        let collaboration = #"(?i)\s*[\(\[]\s*(?:with|feat\.?|featuring|ft\.?)\s+[^\)\]]+[\)\]]\s*$"#
        var cleaned = title
        // Streaming titles often repeat the collaborator already present in the
        // artist field: "The Girl Is Mine (with Paul McCartney)".
        for _ in 0..<3 {
            let next = cleaned.replacingOccurrences(of: collaboration, with: "", options: .regularExpression)
            if next == cleaned { break }
            cleaned = next
        }
        return normalized(cleaned.replacingOccurrences(of: presentation, with: "", options: .regularExpression))
    }

    private static func normalizedArtist(_ artist: String) -> String {
        normalized(artist.replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic\s*$"#, with: "", options: .regularExpression))
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let code = value.uppercased().replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
        return code.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) == nil ? nil : code
    }

    static func contentLabel(_ title: String) -> Bool? {
        guard let range = title.range(of: #"(?i)(?:[\(\[]|[-–—]\s*)(clean|explicit|censored)(?:\s+version)?[\)\]]?\s*$"#, options: .regularExpression) else { return nil }
        return title[range].lowercased().contains("explicit")
    }

    static func contentVariantTitle(_ title: String) -> String {
        normalizedTitle(title.replacingOccurrences(of: #"(?i)\s*(?:[\(\[]|[-–—]\s*)(?:clean|explicit|censored)(?:\s+version)?[\)\]]?\s*$"#, with: "", options: .regularExpression))
    }
}
