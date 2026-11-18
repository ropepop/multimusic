import XCTest
import MultimusicCore

final class MatchingTests: XCTestCase {
    func testITunesCatalogKeepsValidSongsAndRejectsMalformedRecords() throws {
        let data = Data(#"""
        {"resultCount": 18, "results": [
          {"kind":"song","trackId":1440783625,"trackName":"Hello","artistName":"Adele","trackTimeMillis":295502,"trackExplicitness":"notExplicit"},
          {"kind":"song","trackId":2,"trackName":"Explicit","artistName":"Artist","trackTimeMillis":1000,"trackExplicitness":"explicit"},
          {"kind":"song","trackId":3,"trackName":"Clean","artistName":"Artist","trackTimeMillis":2000,"trackExplicitness":"cleaned"},
          {"kind":"song","trackId":4,"trackName":"Unknown","artistName":"Artist","trackTimeMillis":3000,"trackExplicitness":"unknown"},
          {"kind":"song","trackId":0,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":"5","trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":true,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":5.5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"music-video","trackId":5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":5,"trackName":12,"artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":5,"trackName":"  ","artistName":"Artist","trackTimeMillis":1000},
          {"kind":"song","trackId":5,"trackName":"Invalid","artistName":"  ","trackTimeMillis":1000},
          {"kind":"song","trackId":5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":"1000"},
          {"kind":"song","trackId":5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":0},
          {"kind":"song","trackId":5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":-1000},
          {"kind":"song","trackId":5,"trackName":"Invalid","artistName":"Artist","trackTimeMillis":1000,"trackExplicitness":true},
          null,
          "invalid"
        ]}
        """#.utf8)

        XCTAssertEqual(try ITunesCatalog.tracks(from: data), [
            CatalogTrack(id: "1440783625", title: "Hello", artist: "Adele", duration: 295.502, isExplicit: false),
            CatalogTrack(id: "2", title: "Explicit", artist: "Artist", duration: 1, isExplicit: true),
            CatalogTrack(id: "3", title: "Clean", artist: "Artist", duration: 2, isExplicit: false, explicitness: .cleaned),
            CatalogTrack(id: "4", title: "Unknown", artist: "Artist", duration: 3)
        ])
        for malformed in [#"{}"#, #"{"results":{}}"#, #"{"results":null}"#, #"[]"#, #"{"results":["#] {
            XCTAssertThrowsError(try ITunesCatalog.tracks(from: Data(malformed.utf8)), malformed)
        }
    }

    func testFindsRecordingDespitePresentationLabelsAndPunctuation() {
        let source = SourceTrack(id: "youtube", title: "Déjà Vu (Official Music Video)", artist: "Beyoncé - Topic", duration: 240, isExplicit: true)
        let studio = CatalogTrack(id: "studio", title: "Deja Vu", artist: "Beyonce", duration: 241, isExplicit: true)
        let live = CatalogTrack(id: "live", title: "Déjà Vu (Live)", artist: "Beyoncé", duration: 240, isExplicit: true)

        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [live, studio]), studio)
    }

    func testSkipsWrongVersionsAndInsufficientRecordingEvidence() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let rejected: [CatalogTrack] = [
            CatalogTrack(id: "live", title: "Song (Live)", artist: "Artist", duration: 200, isExplicit: true),
            CatalogTrack(id: "remix", title: "Song - Remix", artist: "Artist", duration: 200, isExplicit: true),
            CatalogTrack(id: "acoustic", title: "Song (Acoustic)", artist: "Artist", duration: 200, isExplicit: true),
            CatalogTrack(id: "remaster", title: "Song (2026 Remaster)", artist: "Artist", duration: 200, isExplicit: true),
            CatalogTrack(id: "instrumental", title: "Song (Instrumental)", artist: "Artist", duration: 200, isExplicit: true),
            CatalogTrack(id: "unknown-content", title: "Song", artist: "Artist", duration: 200),
            CatalogTrack(id: "duration", title: "Song", artist: "Artist", duration: 230, isExplicit: true),
            CatalogTrack(id: "missing-duration", title: "Song", artist: "Artist", isExplicit: true),
            CatalogTrack(id: "artist", title: "Song", artist: "Another Artist", duration: 200, isExplicit: true)
        ]

        for candidate in rejected {
            XCTAssertNil(RecordingMatcher.match(source: source, candidates: [candidate]), candidate.id)
        }
        // User decision: a clean-only catalog recording is accepted for an
        // explicit source, but flagged as a lower-confidence fallback.
        let clean = CatalogTrack(id: "clean", title: "Song", artist: "Artist", duration: 200, isExplicit: false)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [clean])?.confidence, .cleanFallback)
    }

    func testAcceptsEquivalentReleasesWithoutGuessingContentVariants() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist", duration: 200)
        let first = CatalogTrack(id: "one", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let second = CatalogTrack(id: "two", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let clean = CatalogTrack(id: "clean", title: "Song (Clean)", artist: "Artist", duration: 200, isExplicit: false)

        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [first, second]), first)
        XCTAssertNil(RecordingMatcher.match(source: source, candidates: [first, clean]))
        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [first, first]), first)
    }

    func testMetadataEquivalentReleasesUseClosestDurationThenCatalogRelevance() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let distant = CatalogTrack(id: "distant", title: "Song", artist: "Artist", duration: 203, isExplicit: true)
        let first = CatalogTrack(id: "z-first", title: "Song", artist: "Artist", duration: 199, isExplicit: true)
        let second = CatalogTrack(id: "a-second", title: "Song", artist: "Artist", duration: 201, isExplicit: true)
        let outside = CatalogTrack(id: "outside", title: "Song", artist: "Artist", duration: 204, isExplicit: true)
        let known = CatalogTrack(id: "known", title: "Song", artist: "Artist", duration: 200, isrc: "USABC1234567", isExplicit: true)
        let conflicting = CatalogTrack(id: "conflicting", title: "Song", artist: "Artist", duration: 200, isrc: "USABC1234568", isExplicit: true)

        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [distant, first, second, first]), first)
        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [distant, second, first]), second)
        XCTAssertNil(RecordingMatcher.match(source: source, candidates: [distant, outside]))
        XCTAssertNil(RecordingMatcher.match(source: source, candidates: [first, known]))
        XCTAssertNil(RecordingMatcher.match(source: source, candidates: [known, conflicting]))
    }

    func testDurationlessMatchingUsesOnlyConsistentCatalogMetadata() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist")
        let first = CatalogTrack(id: "first", title: "Song", artist: "Artist", duration: 200, isExplicit: false)
        let second = CatalogTrack(id: "second", title: "Song", artist: "Artist", duration: 202, isExplicit: false)
        let spread = CatalogTrack(id: "spread", title: "Song", artist: "Artist", duration: 202.001, isExplicit: false)
        let unknownContent = CatalogTrack(id: "unknown", title: "Song", artist: "Artist", duration: 200)
        let explicit = CatalogTrack(id: "explicit", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let missingDuration = CatalogTrack(id: "missing", title: "Song", artist: "Artist", isExplicit: false)
        let known = CatalogTrack(id: "known", title: "Song", artist: "Artist", duration: 200, isrc: "USABC1234567", isExplicit: false)
        let conflicting = CatalogTrack(id: "conflicting", title: "Song", artist: "Artist", duration: 200, isrc: "USABC1234568", isExplicit: false)
        let duplicateSpread = CatalogTrack(id: first.id, title: "Song", artist: "Artist", duration: 210, isExplicit: false)
        let duplicateUnknownContent = CatalogTrack(id: first.id, title: "Song", artist: "Artist", duration: 200)
        let duplicateMissingDuration = CatalogTrack(id: first.id, title: "Song", artist: "Artist", isExplicit: false)

        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [first, second]), first)
        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [first]), first)
        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [first, first]), first)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [first, second])?.confidence, .metadataOnly)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [conflicting, known])?.track, known)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [conflicting, known])?.confidence, .metadataOnly)
        for candidates in [[first, spread], [first, unknownContent], [first, explicit], [missingDuration], [first, missingDuration], [first, known],
                           [first, duplicateSpread], [first, duplicateUnknownContent], [first, duplicateMissingDuration]] {
            XCTAssertNil(RecordingMatcher.match(source: source, candidates: candidates))
        }
    }

    func testISRCDisambiguatesEquivalentAlbumsWithoutGuessingContent() {
        let code = "USABC1234567"
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist", isrc: "US-ABC-12-34567", isExplicit: true)
        let album = CatalogTrack(id: "album", title: "Song", artist: "Artist", isrc: code, isExplicit: true)
        let single = CatalogTrack(id: "single", title: "Song", artist: "Artist", isrc: code, isExplicit: true)
        let other = CatalogTrack(id: "other", title: "Song", artist: "Artist", isrc: "USABC1234568", isExplicit: true)
        let clean = CatalogTrack(id: "clean", title: "Song", artist: "Artist", isrc: code, isExplicit: false)

        XCTAssertEqual(RecordingMatcher.match(source: source, candidates: [single, other, album, clean]), album)
        XCTAssertNil(RecordingMatcher.match(source: source, candidates: [other]))
        let invalidDuration = SourceTrack(id: "source", title: "Song", artist: "Artist", duration: .nan, isrc: code, isExplicit: true)
        XCTAssertNil(RecordingMatcher.match(source: invalidDuration, candidates: [album]))
        let unknownContent = SourceTrack(id: "source", title: "Song", artist: "Artist", isrc: code)
        XCTAssertNil(RecordingMatcher.match(source: unknownContent, candidates: [album, clean]))
        let conflictingMetadata = CatalogTrack(id: album.id, title: album.title, artist: album.artist, isrc: code, isExplicit: false)
        XCTAssertNil(RecordingMatcher.match(source: unknownContent, candidates: [album, conflictingMetadata]))
    }

    func testInvalidOrMissingMetadataCannotAccidentallyMatch() {
        let candidate = CatalogTrack(id: "one", title: "Song", artist: "Artist", duration: 200)
        let sources: [SourceTrack] = [
            SourceTrack(id: "source", title: "Song", artist: "Artist"),
            SourceTrack(id: "source", title: "Song", artist: "Artist", duration: .nan),
            SourceTrack(id: "source", title: "Song", artist: "Artist", duration: -.infinity),
            SourceTrack(id: "source", title: "Song", artist: "", duration: 200),
            SourceTrack(id: "source", title: "", artist: "Artist", duration: 200),
            SourceTrack(id: "", title: "Song", artist: "Artist", duration: 200)
        ]

        for source in sources {
            XCTAssertNil(RecordingMatcher.match(source: source, candidates: [candidate]))
        }
    }

    func testSkippedAssessmentsExplainUncertaintyWithoutGuessingCauses() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Artist", duration: 200)
        let durationless = SourceTrack(id: "source", title: "Song", artist: "Artist")
        let valid = CatalogTrack(id: "valid", title: "Song", artist: "Artist", duration: 200, isExplicit: false)
        let mixedFailure = CatalogTrack(id: "different", title: "Song (Live)", artist: "Other Artist", duration: 250, isExplicit: true)
        let explicit = CatalogTrack(id: "explicit", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let spread = CatalogTrack(id: "spread", title: "Song", artist: "Artist", duration: 203, isExplicit: false)
        let conflictingRecording = CatalogTrack(id: "known", title: "Song", artist: "Artist", duration: 200, isrc: "USABC1234567", isExplicit: false)
        let cases: [(SourceTrack, [CatalogTrack], MatchSkipReason)] = [
            (SourceTrack(id: "source", title: "", artist: "Artist", duration: 200), [valid], .invalidSource),
            (source, [], .noResults),
            (source, [mixedFailure], .noCompatibleMetadata),
            (source, [valid, explicit], .contentConflict),
            (durationless, [valid, spread], .insufficientDurationlessAgreement),
            (source, [valid, conflictingRecording], .ambiguousRecording)
        ]
        for (source, candidates, reason) in cases {
            let result = RecordingMatcher.assessment(source: source, candidates: candidates)
            XCTAssertNil(result.decision)
            XCTAssertEqual(result.skipReason, reason)
        }
        let accepted = RecordingMatcher.assessment(source: source, candidates: [valid])
        XCTAssertEqual(accepted.decision?.track, valid)
        XCTAssertNil(accepted.skipReason)
    }

    func testCollaboratorSuffixInSourceTitleMatchesCatalogTitle() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "The Girl Is Mine (with Paul McCartney)",
                                 artist: "Michael Jackson & Paul McCartney", duration: 221, isExplicit: false)
        let catalog = CatalogTrack(id: "1", title: "The Girl Is Mine", artist: "Michael Jackson & Paul McCartney",
                                   duration: 221.5, isExplicit: false)
        let decision = RecordingMatcher.decision(source: source, candidates: [catalog])
        XCTAssertEqual(decision?.track.id, "1")
    }

    func testLiveAndRemixParentheticalsAreStillRejected() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song (Live)", artist: "Artist", duration: 200, isExplicit: true)
        let catalog = CatalogTrack(id: "1", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [catalog]))
    }

    func testCollaboratorCreditedOnlyInSourceArtistStillMatches() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "The Girl Is Mine (with Paul McCartney)",
                                 artist: "Michael Jackson & Paul McCartney", duration: 221, isExplicit: false)
        let catalog = CatalogTrack(id: "1", title: "The Girl Is Mine (with Paul McCartney)",
                                   artist: "Michael Jackson", duration: 222.2, isExplicit: false)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [catalog])?.track.id, "1")
    }

    func testUnknownExtraArtistIsStillRejected() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist & Friend",
                                 duration: 200, isExplicit: true)
        let catalog = CatalogTrack(id: "1", title: "Song", artist: "Artist & Stranger",
                                   duration: 200, isExplicit: true)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [catalog]))
        XCTAssertFalse(RecordingMatcher.artistMatches(sourceArtist: "Paul McCartney", sourceTitle: "Song", candidateTitle: "Song",
                                                      candidateArtist: "Michael Jackson"))
    }

    func testArtistCreditOrderAndSpacingAreEquivalent() {
        XCTAssertTrue(RecordingMatcher.artistMatches(sourceArtist: "Safety Trance & Arca", sourceTitle: "El Alma Que Te Trajo",
                                                     candidateTitle: "El Alma Que Te Trajo", candidateArtist: "Arca & Safety Trance"))
        XCTAssertTrue(RecordingMatcher.artistMatches(sourceArtist: "Hankook & FM-3", sourceTitle: "Welcome To London",
                                                     candidateTitle: "Welcome to London", candidateArtist: "Hankook & FM3"))
        XCTAssertTrue(RecordingMatcher.artistMatches(sourceArtist: "Frank Sinatra & Nancy Sinatra", sourceTitle: "Somethin' Stupid",
                                                     candidateTitle: "Somethin' Stupid", candidateArtist: "Frank Sinatra & Nancy Sinatra"))
    }

    func testCollaboratorCreditedInCatalogTitleIsAccepted() {
        XCTAssertTrue(RecordingMatcher.artistMatches(sourceArtist: "Armin van Buuren & Sharon Den Adel",
                                                     sourceTitle: "In And Out Of Love",
                                                     candidateTitle: "In and Out of Love (feat. Sharon den Adel)",
                                                     candidateArtist: "Armin van Buuren"))
        XCTAssertFalse(RecordingMatcher.artistMatches(sourceArtist: "Armin van Buuren & Sharon Den Adel",
                                                      sourceTitle: "In And Out Of Love",
                                                      candidateTitle: "In and Out of Love (feat. Someone Else)",
                                                      candidateArtist: "Armin van Buuren"))
    }

    func testContentLabelIsNotPartOfTheTitleComparison() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Escapism. (4am Remix) [Clean]", artist: "RAYE",
                                 duration: 209, isExplicit: nil)
        let catalog = CatalogTrack(id: "1", title: "Escapism. (4am Remix)", artist: "RAYE",
                                   duration: 208.5, isExplicit: false)
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [catalog])?.track.id, "1")
    }

    func testCleanOnlyCatalogRecordingCountsForExplicitSource() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "loml", artist: "Taylor Swift",
                                 duration: 278, isExplicit: true)
        let cleaned = CatalogTrack(id: "1", title: "loml", artist: "Taylor Swift",
                                   duration: 277.2, isExplicit: false)
        let decision = RecordingMatcher.decision(source: source, candidates: [cleaned])
        XCTAssertEqual(decision?.track.id, "1")
        XCTAssertEqual(decision?.confidence, .cleanFallback)
    }

    func testExplicitRecordingIsPreferredOverClean() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist",
                                 duration: 200, isExplicit: true)
        let clean = CatalogTrack(id: "1", title: "Song", artist: "Artist", duration: 200, isExplicit: false)
        let explicit = CatalogTrack(id: "2", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        let decision = RecordingMatcher.decision(source: source, candidates: [clean, explicit])
        XCTAssertEqual(decision?.track.id, "2")
        XCTAssertEqual(decision?.confidence, .metadataAndDuration)
    }

    func testExplicitCatalogRecordingIsNotUsedForCleanSource() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist",
                                 duration: 200, isExplicit: false)
        let explicit = CatalogTrack(id: "2", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [explicit]))
    }

    func testOneLetterCreditSpellingDriftStillMatches() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Bounce (feat. Dr. Dre)",
                                 artist: "Timbaland & Missy Elliott & Justin Timberlake",
                                 duration: 245, isExplicit: true)
        let catalog = CatalogTrack(id: "1", title: "Bounce (feat. Missy Elliot, Justin Timberlake & Dr. Dre)",
                                   artist: "Timbaland", duration: 244.3, isExplicit: false)
        let decision = RecordingMatcher.decision(source: source, candidates: [catalog])
        XCTAssertEqual(decision?.track.id, "1")
        XCTAssertEqual(decision?.confidence, .cleanFallback)
    }

    func testCleanEditDoesNotWinWhenAnExplicitRecordingExists() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Song", artist: "Artist",
                                 duration: 200, isExplicit: true)
        let explicitWrongDuration = CatalogTrack(id: "1", title: "Song", artist: "Artist",
                                                 duration: 230, isExplicit: true)
        let cleanRightDuration = CatalogTrack(id: "2", title: "Song", artist: "Artist",
                                              duration: 200, isExplicit: false)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [explicitWrongDuration, cleanRightDuration]))
    }

    func testDurationlessUsesModalCollectionAndStillChecksItsRecordingAgreement() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        func track(_ id: String, _ collection: String, _ duration: Double, _ isrc: String? = nil) -> CatalogTrack {
            CatalogTrack(id: id, title: source.title, artist: source.artist, duration: duration, isrc: isrc,
                         isExplicit: false, collectionID: collection, isStreamable: true)
        }
        let modal = [track("3", "album", 354), track("2", "album", 355)]
        let alternate = track("1", "single", 400)
        for candidates in [[alternate] + modal, modal.reversed() + [alternate]] {
            let result = RecordingMatcher.assessment(source: source, candidates: candidates)
            XCTAssertEqual(result.decision?.track.id, "2")
            XCTAssertEqual(result.decision?.confidence, .metadataOnly)
        }
        XCTAssertEqual(RecordingMatcher.assessment(source: source,
            candidates: [track("2", "album", 354), track("3", "album", 360), alternate]).skipReason,
                       .insufficientDurationlessAgreement)
        let differingCodes = RecordingMatcher.assessment(source: source,
            candidates: [track("2", "album", 354, "GBABC1234567"),
                         track("3", "album", 354, "GBABC1234568"), alternate])
        XCTAssertEqual(differingCodes.decision?.track.id, "2")
        XCTAssertEqual(differingCodes.decision?.confidence, .metadataOnly)
    }

    func testDurationlessTiesUseNormalizedISRCThenSmallestIDWithoutHidingDisagreement() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        func track(_ id: String, _ collection: String, _ code: String? = nil, duration: Double = 354) -> CatalogTrack {
            CatalogTrack(id: id, title: source.title, artist: source.artist, duration: duration, isrc: code,
                         isExplicit: false, collectionID: collection, isStreamable: true)
        }
        for code in [nil, "GB-ABC-12-34567"] {
            let low = track("1", "album", code), high = track("2", "single", code?.replacingOccurrences(of: "-", with: ""))
            XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: [high, low])?.track.id, "1")
        }
        let differingCodes = RecordingMatcher.decision(source: source,
            candidates: [track("2", "album", "GBABC1234568"), track("1", "single", "GBABC1234567")])
        XCTAssertEqual(differingCodes?.track.id, "1")
        XCTAssertEqual(differingCodes?.confidence, .metadataOnly)
        XCTAssertNil(RecordingMatcher.decision(source: source,
            candidates: [track("1", "album"), track("2", "single", duration: 400)]))
    }

    func testBothCleanCatalogLabelsTransferExplicitSourcesAsReportedFallbacks() throws {
        let source = SourceTrack(id: "explicit", title: "Song", artist: "Artist", duration: 200, isExplicit: true)
        for label in [CatalogExplicitness.cleaned, .notExplicit] {
            let clean = CatalogTrack(id: "clean", title: "Song", artist: "Artist", duration: 200,
                                     isExplicit: false, isStreamable: true, explicitness: label)
            let assessment = RecordingMatcher.assessment(source: source, candidates: [clean])
            XCTAssertNil(assessment.skipReason)
            XCTAssertEqual(assessment.decision?.confidence, .cleanFallback)
            XCTAssertEqual(try JSONDecoder().decode(MatchDecision.self,
                from: JSONEncoder().encode(XCTUnwrap(assessment.decision))).confidence, .cleanFallback)
        }
        XCTAssertNil(MatchSkipReason(rawValue: "explicitOriginalUnavailable"))
        XCTAssertEqual(try JSONDecoder().decode(MatchSkipReason.self,
            from: Data(#""explicitOriginalUnavailable""#.utf8)), .noCompatibleMetadata)
    }
}
