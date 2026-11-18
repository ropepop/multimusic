import Foundation

public struct SourceTrack: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let duration: Double?
    public let isrc: String?
    public let isExplicit: Bool?

    public init(id: String, title: String, artist: String, duration: Double? = nil, isrc: String? = nil, isExplicit: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.duration = duration
        self.isrc = isrc
        self.isExplicit = isExplicit
    }
}

public enum PlaybackCommand: Equatable, Sendable {
    case play, pause, next, previous
    case seek(Double)
}

public struct PlaybackSnapshot: Codable, Equatable, Sendable {
    public var sourceID: String?
    public var title: String
    public var artist: String
    public var duration: Double
    public var position: Double
    public var state: String
    public var synchronized: Bool
    public var revision: UInt64

    public init(sourceID: String? = nil, title: String = "", artist: String = "", duration: Double = 0, position: Double = 0, state: String = "stopped", synchronized: Bool = false, revision: UInt64 = 0) {
        self.sourceID = sourceID
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        self.state = state
        self.synchronized = synchronized
        self.revision = revision
    }
}

public struct PlaybackOutcome: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case completed, rejected }
    public enum Reason: String, Codable, Sendable {
        case inactive, unauthorized, invalidSelection, unmappedQueue, awaitingNext, cancelled
        case nativeFailure, nativeNoChange, timedOut, foreignPlayback, noMatch, cleared
    }
    public let status: Status
    public let reason: Reason?
    public let snapshot: PlaybackSnapshot
    /// Raw `MatchSkipReason` values from the checkpoint that produced a rejection.
    /// Diagnostic only: never used to authorize a playback mutation.
    public let skipReasons: [String]

    public init(status: Status, reason: Reason? = nil, snapshot: PlaybackSnapshot, skipReasons: [String] = []) {
        self.status = status
        self.reason = reason
        self.snapshot = snapshot
        self.skipReasons = skipReasons
    }

    private enum CodingKeys: String, CodingKey { case status, reason, snapshot, skipReasons }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(status: try values.decode(Status.self, forKey: .status),
                  reason: try values.decodeIfPresent(Reason.self, forKey: .reason),
                  snapshot: try values.decode(PlaybackSnapshot.self, forKey: .snapshot),
                  skipReasons: try values.decodeIfPresent([String].self, forKey: .skipReasons) ?? [])
    }
}

public enum SourceProvider: String, Codable, Sendable {
    case youtubeMusic, spotify

    public func acceptsTrackID(_ id: String) -> Bool {
        let pattern = self == .spotify ? #"^[A-Za-z0-9]{22}\z"# : #"^[A-Za-z0-9_-]{11}\z"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    func acceptsCollectionID(_ id: String) -> Bool {
        if self == .spotify { return acceptsTrackID(id) }
        return id.range(of: #"^[A-Za-z0-9_-]{1,256}\z"#, options: .regularExpression) != nil
    }
}

public struct SourceContext: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case album, playlist, search, radio, home, watch, unknown }
    public let provider: SourceProvider
    public let kind: Kind
    public let collectionID: String?
    public let title: String?
    public let artist: String?
    public let edition: String?
    public let selectedSourceID: String
    public let selectedOrdinal: Int?

    public init(provider: SourceProvider = .youtubeMusic, kind: Kind, collectionID: String? = nil, title: String? = nil, artist: String? = nil,
                edition: String? = nil, selectedSourceID: String, selectedOrdinal: Int? = nil) {
        self.provider = provider
        self.kind = kind
        self.collectionID = collectionID
        self.title = title
        self.artist = artist
        self.edition = edition
        self.selectedSourceID = selectedSourceID
        self.selectedOrdinal = selectedOrdinal
    }

    public var isValid: Bool {
        provider.acceptsTrackID(selectedSourceID) &&
        (selectedOrdinal.map { (0..<10_000).contains($0) } ?? true) &&
        (collectionID.map { provider.acceptsCollectionID($0) } ?? true) &&
        [title, artist, edition].allSatisfy { $0.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 } ?? true } &&
        (kind != .album || (title != nil && artist != nil))
    }

    private enum CodingKeys: String, CodingKey { case provider, kind, collectionID, title, artist, edition, selectedSourceID, selectedOrdinal }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provider: try values.decodeIfPresent(SourceProvider.self, forKey: .provider) ?? .youtubeMusic,
                  kind: try values.decode(Kind.self, forKey: .kind),
                  collectionID: try values.decodeIfPresent(String.self, forKey: .collectionID),
                  title: try values.decodeIfPresent(String.self, forKey: .title),
                  artist: try values.decodeIfPresent(String.self, forKey: .artist),
                  edition: try values.decodeIfPresent(String.self, forKey: .edition),
                  selectedSourceID: try values.decode(String.self, forKey: .selectedSourceID),
                  selectedOrdinal: try values.decodeIfPresent(Int.self, forKey: .selectedOrdinal))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid source context."))
        }
    }

    var albumTitle: String? {
        guard kind == .album, isValid, let title else { return nil }
        let normalized = RecordingMatcher.normalized(title)
        guard let edition else { return normalized }
        let label = RecordingMatcher.normalized(edition)
        return (" " + normalized + " ").contains(" " + label + " ") ? normalized : normalized + " " + label
    }
}

/// Ordered, public-catalog query terms used when a direct song search misses.
///
/// The bug this exists for: iTunes Search can omit an exact track even when the
/// track is present in the artist's catalog (seen with "Hot Wet Delirious" by
/// Rebecca Black, 3:08). The artist endpoint + `lookup?entity=song` finds it.
public enum CatalogQueryLadder {
    /// Terms to try against `search?entity=song`, most specific first.
    public static func songSearchTerms(for source: SourceTrack) -> [String] {
        let title = clean(source.title)
        let artist = artistTerm(source.artist)
        var terms: [String] = []
        if !title.isEmpty, let artist, !artist.isEmpty {
            terms.append("\(title) \(artist)")
        }
        if !title.isEmpty { terms.append(title) }
        return deduplicate(terms)
    }

    /// Terms to try against `search?entity=musicArtist`, most specific first.
    /// Bounded to two terms so one miss cannot fan out into many requests.
    public static func artistSearchTerms(_ artist: String) -> [String] {
        guard let cleaned = artistTerm(artist), !cleaned.isEmpty else { return [] }
        var terms = [cleaned]
        // "A & B", "A, B", "A feat. B" -> primary artist as a fallback term.
        let separators = ["&", ",", " feat. ", " featuring ", " x "]
        for separator in separators {
            if let first = cleaned.components(separatedBy: separator).first {
                let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != cleaned {
                    terms.append(trimmed)
                    break
                }
            }
        }
        return deduplicate(terms)
    }

    /// Whether a failed assessment is a recall miss worth widening, or a
    /// precision answer that must stand.
    public static func shouldContinue(after assessment: MatchAssessment) -> Bool {
        guard let reason = assessment.skipReason else { return false }
        switch reason {
        case .invalidSource, .contentConflict, .ambiguousRecording, .insufficientDurationlessAgreement,
             .unavailableInStorefront, .thirdPartyEdit:
            return false
        case .noResults, .noCompatibleMetadata:
            return true
        }
    }

    /// Removes YouTube's auto-generated "- Topic" suffix and surrounding space.
    static func artistTerm(_ artist: String) -> String? {
        let cleaned = artist
            .replacingOccurrences(of: #"(?i)\s*[-–—]\s*Topic\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicate(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}

public struct CatalogAlbum: Equatable, Sendable {    public let id: String
    public let title: String
    public let artist: String
    public let tracks: [CatalogTrack]

    public init(id: String, title: String, artist: String, tracks: [CatalogTrack]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.tracks = tracks
    }

    public func resolve(_ sources: [SourceTrack], context: SourceContext) -> [MatchDecision?]? {
        guard let title = context.albumTitle, let artist = context.artist,
              RecordingMatcher.normalized(self.title) == title,
              RecordingMatcher.normalized(self.artist) == RecordingMatcher.normalized(artist) else { return nil }
        return sources.map { RecordingMatcher.decision(source: $0, candidates: tracks) }
    }

    /// Album verification is itself strong evidence. For a source row that has
    /// no published duration, accept the unique exact title+artist track inside
    /// the verified edition instead of rejecting every multiple-version result.
    public func resolveLenient(_ sources: [SourceTrack], context: SourceContext) -> [MatchDecision?]? {
        guard let title = context.albumTitle, let artist = context.artist,
              RecordingMatcher.normalized(self.title) == title,
              RecordingMatcher.normalized(self.artist) == RecordingMatcher.normalized(artist) else { return nil }
        return sources.map { source in
            if source.duration != nil {
                return RecordingMatcher.decision(source: source, candidates: tracks)
            }
            let sourceExplicit = source.isExplicit ?? RecordingMatcher.contentLabel(source.title)
            if let label = RecordingMatcher.contentLabel(source.title), let explicit = source.isExplicit, label != explicit { return nil }
            let hasExplicitOriginal = tracks.contains {
                $0.isStreamable != false && ($0.isExplicit ?? RecordingMatcher.contentLabel($0.title)) == true &&
                RecordingMatcher.contentVariantTitle($0.title) == RecordingMatcher.contentVariantTitle(source.title) &&
                RecordingMatcher.artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                    candidateTitle: $0.title, candidateArtist: $0.artist)
            }
            let unverifiedEdit = RecordingMatcher.derivativePlainTitle(source.title) != nil &&
                RecordingMatcher.assessment(source: source, candidates: tracks).skipReason == .thirdPartyEdit
            let matches = tracks.filter { candidate in
                let candidateExplicit = candidate.isExplicit ?? RecordingMatcher.contentLabel(candidate.title)
                // Never upgrade a clean source to an explicit recording; the
                // semantics of the user's policy only run clean for explicit.
                if candidate.isStreamable == false { return false }
                if let label = RecordingMatcher.contentLabel(candidate.title), let explicit = candidate.isExplicit, label != explicit { return false }
                if unverifiedEdit { return false }
                if sourceExplicit == false, candidateExplicit == true { return false }
                if sourceExplicit == true, candidateExplicit != true, ((candidate.explicitness != .notExplicit && candidate.explicitness != .cleaned) || hasExplicitOriginal) { return false }
                return RecordingMatcher.contentVariantTitle(candidate.title) == RecordingMatcher.contentVariantTitle(source.title) &&
                    RecordingMatcher.artistMatches(sourceArtist: source.artist, sourceTitle: source.title,
                                                   candidateTitle: candidate.title, candidateArtist: candidate.artist)
            }
            guard matches.count == 1 else { return nil }
            let candidateExplicit = matches[0].isExplicit ?? RecordingMatcher.contentLabel(matches[0].title)
            let confidence: MatchConfidence = (sourceExplicit == true && candidateExplicit == false)
                ? .cleanFallback : .metadataOnly
            return MatchDecision(track: matches[0], confidence: confidence)
        }
    }
}

public enum ITunesCatalog {
    public static func tracks(from data: Data) throws -> [CatalogTrack] {
        try JSONDecoder().decode(Response.self, from: data).results.compactMap(\.track)
    }

    /// Best artist ID for a name from a `search?entity=musicArtist` response.
    /// Exact normalized matches win; otherwise the first valid artist is used.
    public static func artistID(from data: Data, matching name: String) throws -> String? {
        let artists = try JSONDecoder().decode(Response.self, from: data).results.compactMap { result -> (id: String, name: String)? in
            guard let id = result.artistID, let artistName = result.artistName else { return nil }
            return (id, artistName)
        }
        guard !artists.isEmpty else { return nil }
        let target = RecordingMatcher.normalized(name)
        let exact = artists.filter { RecordingMatcher.normalized($0.name) == target }
        return (exact.first ?? artists[0]).id
    }

    /// Album metadata from a `search?entity=album` response.
    public static func albumCandidates(from data: Data) throws -> [(id: String, title: String, artist: String)] {
        try JSONDecoder().decode(Response.self, from: data).results.compactMap { result in
            guard let album = result.album else { return nil }
            return (album.id, album.title, album.artist)
        }
    }

    public static func album(from data: Data) throws -> CatalogAlbum? {        let results = try JSONDecoder().decode(Response.self, from: data).results
        let albums = results.compactMap(\.album)
        guard albums.count == 1, let album = albums.first else { return nil }
        return CatalogAlbum(id: album.id, title: album.title, artist: album.artist,
                            tracks: results.compactMap(\.track).filter { $0.collectionID == album.id })
    }

    private struct AlbumMetadata {
        let id: String
        let title: String
        let artist: String
    }

    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        var track: CatalogTrack?
        var album: AlbumMetadata?
        var artistID: String?
        var artistName: String?

        private enum CodingKeys: String, CodingKey {
            case kind, trackId, trackName, artistName, trackTimeMillis, trackExplicitness
            case wrapperType, collectionType, collectionId, collectionName
            case artistId, isStreamable
        }

        init(from decoder: Decoder) throws {
            do {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                let wrapperType = try values.decodeIfPresent(String.self, forKey: .wrapperType)
                if wrapperType == "artist" {
                    if let id = try values.decodeIfPresent(Int64.self, forKey: .artistId),
                       let name = try values.decodeIfPresent(String.self, forKey: .artistName),
                       id > 0, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 500 {
                        artistID = String(id)
                        artistName = name
                    }
                    return
                }
                if wrapperType == "collection" {
                    let type = try values.decode(String.self, forKey: .collectionType)
                    let id = try values.decode(Int64.self, forKey: .collectionId)
                    let title = try values.decode(String.self, forKey: .collectionName)
                    let artist = try values.decode(String.self, forKey: .artistName)
                    if type == "Album", id > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500, artist.count <= 500 {
                        album = AlbumMetadata(id: String(id), title: title, artist: artist)
                    }
                    return
                }
                let kind = try values.decode(String.self, forKey: .kind)
                let id = try values.decode(Int64.self, forKey: .trackId)
                let title = try values.decode(String.self, forKey: .trackName)
                let artist = try values.decode(String.self, forKey: .artistName)
                let milliseconds = try values.decode(Double.self, forKey: .trackTimeMillis)
                let explicitness = try values.decodeIfPresent(String.self, forKey: .trackExplicitness)
                guard kind == "song", id > 0,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      title.count <= 500, artist.count <= 500,
                      milliseconds.isFinite, milliseconds > 0, milliseconds <= 86_400_000 else {
                    track = nil
                    return
                }
                let content = explicitness.flatMap(CatalogExplicitness.init(rawValue:))
                let streamable = try values.decodeIfPresent(Bool.self, forKey: .isStreamable)
                let isExplicit: Bool? = switch explicitness {
                case "explicit": true
                case "notExplicit", "cleaned": false
                default: nil
                }
                let collectionID = try values.decodeIfPresent(Int64.self, forKey: .collectionId)
                let collectionName = try values.decodeIfPresent(String.self, forKey: .collectionName)
                track = CatalogTrack(id: String(id), title: title, artist: artist,
                                     duration: milliseconds / 1_000, isExplicit: isExplicit,
                                     collectionID: collectionID.flatMap { $0 > 0 ? String($0) : nil },
                                     collectionName: collectionName.flatMap { !$0.isEmpty && $0.count <= 500 ? $0 : nil },
                                     isStreamable: streamable, explicitness: content)
            } catch {
                track = nil
            }
        }
    }
}
