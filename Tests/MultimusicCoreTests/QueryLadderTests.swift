import XCTest
import MultimusicCore

final class QueryLadderTests: XCTestCase {
    func testSongSearchTermsPreferTitleAndArtistThenTitleOnly() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Hot Wet Delirious", artist: "Rebecca Black")
        XCTAssertEqual(CatalogQueryLadder.songSearchTerms(for: source),
                       ["Hot Wet Delirious Rebecca Black", "Hot Wet Delirious"])
    }

    func testSongSearchTermsDeduplicateAndDropEmptyArtist() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "  ")
        XCTAssertEqual(CatalogQueryLadder.songSearchTerms(for: source), ["Song"])
    }

    func testArtistSearchTermsStripTopicAndOfferPrimaryArtist() {
        XCTAssertEqual(CatalogQueryLadder.artistSearchTerms("Beyoncé - Topic"), ["Beyoncé"])
        XCTAssertEqual(CatalogQueryLadder.artistSearchTerms("Calvin Harris & Dua Lipa"),
                       ["Calvin Harris & Dua Lipa", "Calvin Harris"])
        XCTAssertEqual(CatalogQueryLadder.artistSearchTerms("A & B & C & D"),
                       ["A & B & C & D", "A"])
        XCTAssertEqual(CatalogQueryLadder.artistSearchTerms("   "), [])
    }

    func testWideningStopsOnPrecisionAnswersAndContinuesOnRecallMisses() {
        let recallMisses: [MatchSkipReason] = [.noResults, .noCompatibleMetadata]
        for reason in recallMisses {
            XCTAssertTrue(CatalogQueryLadder.shouldContinue(after: MatchAssessment(skipReason: reason)), "\(reason)")
        }
        let precisionAnswers: [MatchSkipReason] = [
            .invalidSource, .contentConflict, .ambiguousRecording, .insufficientDurationlessAgreement
        ]
        for reason in precisionAnswers {
            XCTAssertFalse(CatalogQueryLadder.shouldContinue(after: MatchAssessment(skipReason: reason)), "\(reason)")
        }
        let decision = MatchDecision(track: CatalogTrack(id: "1", title: "T", artist: "A"), confidence: .metadataAndDuration)
        XCTAssertFalse(CatalogQueryLadder.shouldContinue(after: MatchAssessment(decision: decision)))
    }

    func testArtistIDPrefersExactNormalizedName() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"artist","artistType":"Artist","artistName":"Rebecca Black Tribute","artistId":1},
          {"wrapperType":"artist","artistType":"Artist","artistName":"Rebecca Black","artistId":426285675},
          {"wrapperType":"artist","artistId":0,"artistName":"Invalid"},
          {"wrapperType":"artist","artistId":3,"artistName":"   "}
        ]}
        """#.utf8)
        XCTAssertEqual(try ITunesCatalog.artistID(from: data, matching: "REBECCA BLACK"), "426285675")
    }

    func testArtistIDFallsBackToFirstValidArtist() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"artist","artistName":"Some Artist","artistId":7}
        ]}
        """#.utf8)
        XCTAssertEqual(try ITunesCatalog.artistID(from: data, matching: "Different"), "7")
        XCTAssertNil(try ITunesCatalog.artistID(from: Data(#"{"results":[]}"#.utf8), matching: "Anyone"))
    }

    /// Regression for the field failure: iTunes Search returned no exact hit for
    /// "Hot Wet Delirious", but the artist catalog lookup contained it at 188.6 s.
    func testArtistCatalogFixtureResolvesTheReportedSong() throws {        let data = Data(#"""
        {"results":[
          {"wrapperType":"track","kind":"song","trackId":6783569946,"trackName":"Anaheim Star","artistName":"Rebecca Black","trackTimeMillis":166800,"trackExplicitness":"explicit","collectionId":6783569945,"collectionName":"Age of the Exhibitionist"},
          {"wrapperType":"track","kind":"song","trackId":6783569947,"trackName":"Hot Wet Delirious","artistName":"Rebecca Black","trackTimeMillis":188600,"trackExplicitness":"explicit","collectionId":6783569945,"collectionName":"Age of the Exhibitionist"},
          {"wrapperType":"track","kind":"song","trackId":6783570228,"trackName":"Speakerphone","artistName":"Rebecca Black","trackTimeMillis":161700,"trackExplicitness":"explicit","collectionId":6783569945,"collectionName":"Age of the Exhibitionist"}
        ]}
        """#.utf8)
        let source = SourceTrack(id: "BBBBBBBBBBB", title: "Hot Wet Delirious", artist: "Rebecca Black", duration: 188, isExplicit: true)
        let decision = try XCTUnwrap(RecordingMatcher.decision(source: source, candidates: ITunesCatalog.tracks(from: data)))
        XCTAssertEqual(decision.track.id, "6783569947")
        XCTAssertEqual(decision.track.title, "Hot Wet Delirious")
        XCTAssertEqual(decision.confidence, .metadataAndDuration)
    }

    func testVerifiedAlbumResolvesDurationlessRowByUniqueTitleAndArtist() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Thriller","artistName":"Michael Jackson"},
          {"kind":"song","trackId":1,"trackName":"Wanna Be Startin' Somethin'","artistName":"Michael Jackson","trackTimeMillis":363000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Thriller"},
          {"kind":"song","trackId":2,"trackName":"The Girl Is Mine","artistName":"Michael Jackson","trackTimeMillis":221000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Thriller"}
        ]}
        """#.utf8)
        let album = try XCTUnwrap(ITunesCatalog.album(from: data))
        let first = SourceTrack(id: "AAAAAAAAAAA", title: "Wanna Be Startin' Somethin'", artist: "Michael Jackson")
        let second = SourceTrack(id: "BBBBBBBBBBB", title: "The Girl Is Mine", artist: "Michael Jackson")
        let context = SourceContext(kind: .album, title: "Thriller", artist: "Michael Jackson", selectedSourceID: first.id)
        let decisions = try XCTUnwrap(album.resolveLenient([first, second], context: context))
        XCTAssertEqual(decisions.map { $0?.track.id }, ["1", "2"])
        XCTAssertEqual(decisions.compactMap { $0?.confidence }, [.metadataOnly, .metadataOnly])
        XCTAssertNil(album.resolveLenient([first], context: SourceContext(kind: .album, title: "Thriller", artist: "Someone Else", selectedSourceID: first.id)))
    }

    func testVerifiedAlbumRejectsAmbiguousDurationlessMatch() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Thriller","artistName":"Michael Jackson"},
          {"kind":"song","trackId":1,"trackName":"Thriller","artistName":"Michael Jackson","trackTimeMillis":357000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Thriller"},
          {"kind":"song","trackId":2,"trackName":"Thriller","artistName":"Michael Jackson","trackTimeMillis":358000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Thriller"}
        ]}
        """#.utf8)
        let album = try XCTUnwrap(ITunesCatalog.album(from: data))
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Thriller", artist: "Michael Jackson")
        let context = SourceContext(kind: .album, title: "Thriller", artist: "Michael Jackson", selectedSourceID: source.id)
        let decisions = try XCTUnwrap(album.resolveLenient([source], context: context))
        XCTAssertNil(decisions[0])
    }

    func testAlbumCandidatesDecodeSearchResults() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Thriller","artistName":"Michael Jackson"},
          {"wrapperType":"collection","collectionType":"Album","collectionId":11,"collectionName":"Bad","artistName":"Michael Jackson"},
          {"wrapperType":"track","kind":"song","trackId":5,"trackName":"Nope","artistName":"X","trackTimeMillis":1000}
        ]}
        """#.utf8)
        let albums = try ITunesCatalog.albumCandidates(from: data)
        XCTAssertEqual(albums.map(\.id), ["10", "11"])
        XCTAssertEqual(albums.map(\.title), ["Thriller", "Bad"])
    }

    func testVerifiedAlbumNeverUpgradesCleanSourceToExplicit() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Record","artistName":"Artist"},
          {"kind":"song","trackId":1,"trackName":"Song","artistName":"Artist","trackTimeMillis":200000,"trackExplicitness":"explicit","collectionId":10,"collectionName":"Record"}
        ]}
        """#.utf8)
        let album = try XCTUnwrap(ITunesCatalog.album(from: data))
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist", isExplicit: false)
        let context = SourceContext(kind: .album, title: "Record", artist: "Artist", selectedSourceID: source.id)
        let decisions = try XCTUnwrap(album.resolveLenient([source], context: context))
        XCTAssertNil(decisions[0])
    }

    func testVerifiedAlbumCleanedTrackForExplicitSourceIsLabelledFallback() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Record","artistName":"Artist"},
          {"kind":"song","trackId":1,"trackName":"Song","artistName":"Artist","trackTimeMillis":200000,"trackExplicitness":"cleaned","collectionId":10,"collectionName":"Record"}
        ]}
        """#.utf8)
        let album = try XCTUnwrap(ITunesCatalog.album(from: data))
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist", isExplicit: true)
        let context = SourceContext(kind: .album, title: "Record", artist: "Artist", selectedSourceID: source.id)
        let decisions = try XCTUnwrap(album.resolveLenient([source], context: context))
        XCTAssertEqual(decisions[0]?.confidence, .cleanFallback)
    }
}
