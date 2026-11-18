import XCTest
import MultimusicCore

final class OpusFixTests: XCTestCase {
    func testStorefrontAvailabilityIsDecodedAndUnavailableSongsAreNeverChosen() throws {
        let data = Data(#"{"results":[{"kind":"song","trackId":1360226636,"trackName":"Moscow Never Sleeps","artistName":"DJ Smash","trackTimeMillis":234307,"trackExplicitness":"notExplicit","isStreamable":false}]}"#.utf8)
        let track = try XCTUnwrap(ITunesCatalog.tracks(from: data).first)
        XCTAssertEqual(track.isStreamable, false)
        let source = SourceTrack(id: "8IMXEkbit8w", title: track.title, artist: track.artist, duration: 235)
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: [track]).skipReason, .unavailableInStorefront)
        XCTAssertFalse(CatalogQueryLadder.shouldContinue(after: .init(skipReason: .unavailableInStorefront)))
        let available = CatalogTrack(id: "available", title: track.title, artist: track.artist, duration: 235, isExplicit: false, isStreamable: true)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [track, available])?.track.id, "available")
        let decoded = try JSONDecoder().decode(CatalogTrack.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(decoded, track)
        let old = try JSONDecoder().decode(CatalogTrack.self, from: Data(#"{"id":"old","title":"Song","artist":"Artist","duration":200,"isExplicit":false}"#.utf8))
        XCTAssertNil(old.isStreamable)
        XCTAssertNil(old.explicitness)
    }

    func testExplicitNotExplicitAndCleanedRemainDistinct() throws {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        func track(_ value: String, streamable: Bool = true) throws -> CatalogTrack {
            let json = "{\"results\":[{\"kind\":\"song\",\"trackId\":1,\"trackName\":\"Song\",\"artistName\":\"Artist\",\"trackTimeMillis\":200000,\"trackExplicitness\":\"\(value)\",\"isStreamable\":\(streamable)}]}"
            return try XCTUnwrap(ITunesCatalog.tracks(from: Data(json.utf8)).first)
        }
        let explicit = try track("explicit"), notExplicit = try track("notExplicit"), cleaned = try track("cleaned")
        XCTAssertEqual([explicit.explicitness, notExplicit.explicitness, cleaned.explicitness], [.explicit, .notExplicit, .cleaned])
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [explicit])?.confidence, .metadataAndDuration)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [notExplicit])?.confidence, .cleanFallback)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [cleaned])?.confidence, .cleanFallback)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [cleaned, explicit])?.track.explicitness, .explicit)
        XCTAssertEqual(RecordingMatcher.decision(source: source,
            candidates: [try track("explicit", streamable: false), notExplicit])?.confidence, .cleanFallback)
        let context = SourceContext(kind: .album, title: "Record", artist: "Artist", selectedSourceID: source.id)
        let durationless = SourceTrack(id: source.id, title: source.title, artist: source.artist, isExplicit: true)
        for (candidate, confidence) in [(explicit, MatchConfidence.metadataOnly), (notExplicit, .cleanFallback), (cleaned, .cleanFallback)] {
            let album = CatalogAlbum(id: "record", title: "Record", artist: "Artist", tracks: [candidate])
            XCTAssertEqual(album.resolveLenient([durationless], context: context)?[0]?.confidence, confidence)
        }
        let cleanedAlbum = CatalogAlbum(id: "record", title: "Record", artist: "Artist", tracks: [cleaned])
        XCTAssertEqual(cleanedAlbum.resolveLenient([durationless], context: context)?[0]?.confidence, .cleanFallback)
        let unavailableOriginal = CatalogAlbum(id: "record", title: "Record", artist: "Artist",
            tracks: [try track("explicit", streamable: false), cleaned])
        XCTAssertEqual(unavailableOriginal.resolveLenient([durationless], context: context)?[0]?.confidence, .cleanFallback)
        let conflicting = CatalogTrack(id: "conflict", title: "Song (Explicit)", artist: "Artist",
            duration: 200, isExplicit: false, isStreamable: true, explicitness: .cleaned)
        let conflictingAlbum = CatalogAlbum(id: "record", title: "Record", artist: "Artist", tracks: [conflicting])
        XCTAssertNil(conflictingAlbum.resolveLenient([durationless], context: context)?[0])
    }

    func testDerivativeEditsNeedTheSameArtistsPlainTitle() {
        for marker in ["slowed", "slowed + reverb", "slowed down", "reverb", "sped up", "sped-up", "nightcore", "8D", "fan-made"] {
            let source = SourceTrack(id: "edit", title: "Song (\(marker))", artist: "Artist", duration: 200)
            let edit = CatalogTrack(id: "edit", title: source.title, artist: source.artist, duration: 200, isExplicit: false, isStreamable: true)
            let original = CatalogTrack(id: "original", title: "Song", artist: "Artist", duration: 220, isExplicit: false, isStreamable: true)
            let unrelated = CatalogTrack(id: "other", title: "Song", artist: "Other Artist", duration: 220, isExplicit: false)
            XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: [edit, unrelated]).skipReason, .thirdPartyEdit, marker)
            XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [edit, original])?.track.id, "edit", marker)
            XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [original]), "Never substitute the plain recording for the edit")
        }
        XCTAssertNil(RecordingMatcher.derivativePlainTitle("Ordinary Song"))
    }

    func testFooterShowsCommitAndConfirmedResetAndOnlyOffersIdleRestore() {
        var input = FooterInput()
        input.savedRemaining = 1
        XCTAssertEqual(FooterState.make(input).action, .restore)
        input.committing = true
        XCTAssertEqual(FooterState.make(input).text, "Starting in Music…")
        XCTAssertNil(FooterState.make(input).action)
        input.committing = false
        input.pendingReplacement = true
        XCTAssertNotEqual(FooterState.make(input).action, .restore)
        input.pendingReplacement = false
        input.matching = true
        XCTAssertNotEqual(FooterState.make(input).action, .restore)
        input.finished = true
        XCTAssertNil(FooterState.make(input).action)
        input.matching = false
        input.pendingReplacement = true
        XCTAssertNil(FooterState.make(input).action)
        input.unconfirmed = true
        input.problem = "Music took too long to respond."
        XCTAssertEqual(FooterState.make(input).action, .reset)
        XCTAssertTrue(FooterState.make(input).announce)
        XCTAssertEqual(FooterState.make(input).text, "Music’s last request is unconfirmed")
    }
}
