import XCTest
import MultimusicCore

final class Round2Tests: XCTestCase {
    /// A durationless source with one unique exact title/artist streamable
    /// recording from a single edition is safe to accept as metadata-only.
    func testUnifiedCollectionDurationlessCandidateIsAcceptedAsMetadataOnly() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Bohemian Rhapsody", artist: "Queen")
        let first = CatalogTrack(id: "1", title: "Bohemian Rhapsody", artist: "Queen", duration: 354,
                                 isExplicit: false, collectionID: "100", isStreamable: true)
        let duplicate = CatalogTrack(id: "1", title: "Bohemian Rhapsody", artist: "Queen", duration: 355,
                                     isExplicit: false, collectionID: "100", isStreamable: true)
        let assessment = RecordingMatcher.assessment(source: source, candidates: [first, duplicate])
        XCTAssertEqual(assessment.skipReason, nil)
        XCTAssertEqual(assessment.decision?.track.id, "1")
        XCTAssertEqual(assessment.decision?.confidence, .metadataOnly)
    }

    /// Two editions of the same durationless title must still fail closed with
    /// the strict disagreement reason, never pick an arbitrary winner.
    func testMultiEditionDurationlessStillRejected() {
        let source = SourceTrack(id: "AAAAAAAAAAA", title: "Bohemian Rhapsody", artist: "Queen")
        let thisEdition = CatalogTrack(id: "1", title: "Bohemian Rhapsody", artist: "Queen", duration: 354,
                                       isExplicit: false, collectionID: "100", isStreamable: true)
        let otherEdition = CatalogTrack(id: "2", title: "Bohemian Rhapsody", artist: "Queen", duration: 400,
                                        isExplicit: false, collectionID: "200", isStreamable: true)
        XCTAssertEqual(RecordingMatcher.assessment(source: source,
                                                   candidates: [thisEdition, otherEdition]).skipReason,
                       .insufficientDurationlessAgreement)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [thisEdition, otherEdition]))

        let explicitEdit = CatalogTrack(id: "3", title: "Bohemian Rhapsody", artist: "Queen", duration: 354,
                                        isExplicit: true, collectionID: "100", isStreamable: true)
        XCTAssertEqual(RecordingMatcher.assessment(source: source,
                                                   candidates: [thisEdition, explicitEdit]).skipReason,
                       .contentConflict)
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [thisEdition, explicitEdit]))
    }

    /// PlaybackOutcome carries skip reasons for rejected selections without
    /// changing completed outcomes or losing them across Codable round trips.
    func testSkipReasonsPropagationThroughPlaybackOutcome() throws {
        let reasons = ["thirdPartyEdit", "noResults"]
        let rejected = PlaybackOutcome(status: .rejected, reason: .noMatch,
                                       snapshot: PlaybackSnapshot(), skipReasons: reasons)
        XCTAssertEqual(rejected.skipReasons, reasons)
        XCTAssertEqual(rejected.skipReasons.filter { $0 == MatchSkipReason.thirdPartyEdit.rawValue }.count, 1)
        let encoded = try JSONEncoder().encode(rejected)
        let decoded = try JSONDecoder().decode(PlaybackOutcome.self, from: encoded)
        XCTAssertEqual(decoded, rejected)

        let completed = PlaybackOutcome(status: .completed, snapshot: PlaybackSnapshot())
        XCTAssertEqual(completed.skipReasons, [])
        XCTAssertEqual(try JSONDecoder().decode(PlaybackOutcome.self,
            from: Data(#"{"status":"completed","snapshot":{"title":"","artist":"","duration":0,"position":0,"state":"stopped","synchronized":false,"revision":0}}"#.utf8)).skipReasons, [])
    }

    func testFifteenQueenResultsChooseTheModalDurationAcrossAlbumsWithNoise() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        let studio = (1...5).map { index in
            CatalogTrack(id: String(format: "%02d", index), title: source.title, artist: source.artist,
                         duration: 354 + Double(index % 3), isExplicit: false,
                         collectionID: "album-\(index)", isStreamable: true)
        }
        let alternate = (6...8).map { index in
            CatalogTrack(id: String(format: "%02d", index), title: source.title, artist: source.artist,
                         duration: 400, isExplicit: false, collectionID: "album-\(index)", isStreamable: true)
        }
        let noise = [" (Live)", " (2011 Remaster)", " (Revisited)", " (Karaoke)", " (Instrumental)", " (Cover)"].enumerated().map { index, suffix in
            CatalogTrack(id: "noise-\(index)", title: source.title + suffix, artist: source.artist,
                         duration: 354, isExplicit: false, collectionID: "noise-album-\(index)", isStreamable: true)
        } + [CatalogTrack(id: "cover", title: source.title, artist: "Queen Tribute Band", duration: 354,
                          isExplicit: false, collectionID: "cover-album", isStreamable: true)]
        let candidates = studio + alternate + noise
        XCTAssertEqual(candidates.count, 15)
        XCTAssertEqual(Set(candidates.compactMap(\.collectionID)).count, 15)
        for ordered in [candidates, Array(candidates.reversed()), alternate + noise + studio] {
            let decision = RecordingMatcher.decision(source: source, candidates: ordered)
            XCTAssertEqual(decision?.track.collectionID, "album-1")
            XCTAssertEqual(decision?.track.id, "01")
            XCTAssertEqual(decision?.confidence, .metadataOnly)
        }
        let tied = Array(studio.prefix(3)) + alternate + noise
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: tied).skipReason,
                       .insufficientDurationlessAgreement)
        let conflicting = CatalogTrack(id: "conflict", title: source.title, artist: source.artist,
                                       duration: 355, isrc: "GBABC1234567", isExplicit: false,
                                       collectionID: "conflicting-edition", isStreamable: true)
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: candidates + [conflicting]).skipReason,
                       .insufficientDurationlessAgreement)
    }

    func testQueenLiveRemasterAndRevisitedDoNotBecomeStudioRecordings() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        for suffix in [" (Live)", " (2011 Remaster)", " (Revisited)"] {
            let variant = CatalogTrack(id: "variant", title: source.title + suffix, artist: source.artist,
                                       duration: 354, isExplicit: false, collectionID: "modal", isStreamable: true)
            XCTAssertNil(RecordingMatcher.decision(source: source, candidates: Array(repeating: variant, count: 15)))
            let labelled = CatalogTrack(id: "label-conflict", title: source.title + " (Explicit)", artist: source.artist,
                                       duration: 354, isExplicit: false, collectionID: "modal", isStreamable: true)
            XCTAssertNil(RecordingMatcher.decision(source: source, candidates: [labelled]))
        }
    }

    func testQueenModalRecordingAllowsDifferentISRCsAndChoosesLowestCodeThenID() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        let studio = [("a", "GBABC1234569", 354.0), ("z", "GBABC1234567", 355.0),
                      ("b", "GBABC1234568", 356.0), ("00", "GB-ABC-12-34567", 354.0)].map { id, code, duration in
            CatalogTrack(id: id, title: source.title, artist: source.artist, duration: duration, isrc: code,
                         isExplicit: false, collectionID: "album-\(id)", isStreamable: true)
        }
        let alternate = (1...2).map { index in
            CatalogTrack(id: "alternate-\(index)", title: source.title, artist: source.artist, duration: 400,
                         isrc: "GBABC123457\(index)", isExplicit: false, collectionID: "other-\(index)", isStreamable: true)
        }
        for ordered in [studio + alternate, Array((studio + alternate).reversed()), alternate + studio] {
            let assessment = RecordingMatcher.assessment(source: source, candidates: ordered)
            XCTAssertEqual(assessment.decision?.track.id, "00")
            XCTAssertEqual(assessment.decision?.confidence, .metadataOnly)
            XCTAssertNil(assessment.skipReason)
        }
        let tied = Array(studio.prefix(2)) + alternate
        let rejected = RecordingMatcher.assessment(source: source, candidates: tied)
        XCTAssertEqual(rejected.skipReason, .insufficientDurationlessAgreement)
        XCTAssertEqual(rejected.diagnosticFields, ["durationlessGuard": "tiedDurationGroups",
                                                  "durationGroupCounts": "2,2", "distinctISRCCount": "4", "tiedSpanSeconds": "46.0"])
    }

    func testDurationlessGuardDiagnosticsNameMissingDurationAndRecordingDisagreement() {
        let source = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        let known = CatalogTrack(id: "1", title: source.title, artist: source.artist, duration: 354,
                                 isrc: "GBABC1234567", isExplicit: false, collectionID: "album")
        let missing = CatalogTrack(id: "2", title: source.title, artist: source.artist,
                                   isExplicit: false, collectionID: "album")
        let invalid = RecordingMatcher.assessment(source: source, candidates: [known, missing])
        XCTAssertEqual(invalid.skipReason, .insufficientDurationlessAgreement)
        XCTAssertEqual(invalid.diagnosticFields, ["durationlessGuard": "invalidDuration",
                                                 "durationGroupCounts": "0", "distinctISRCCount": "1"])
        let unknown = CatalogTrack(id: "3", title: source.title, artist: source.artist, duration: 355,
                                   isExplicit: false, collectionID: "album")
        let mixed = RecordingMatcher.assessment(source: source, candidates: [known, unknown])
        XCTAssertEqual(mixed.skipReason, .insufficientDurationlessAgreement)
        XCTAssertEqual(mixed.diagnosticFields, ["durationlessGuard": "recordingAgreement",
                                               "durationGroupCounts": "2", "distinctISRCCount": "1"])
    }

    func testDifferentISRCExceptionStillRejectsTitleArtistLabelAndDurationDisagreement() {
        let queen = SourceTrack(id: "queen", title: "Bohemian Rhapsody", artist: "Queen")
        let first = CatalogTrack(id: "1", title: queen.title, artist: queen.artist, duration: 354,
                                 isrc: "GBABC1234567", isExplicit: false, collectionID: "album")
        let otherTitle = CatalogTrack(id: "2", title: queen.title + " (Official Video)", artist: queen.artist,
                                      duration: 355, isrc: "GBABC1234568", isExplicit: false, collectionID: "single")
        XCTAssertEqual(RecordingMatcher.assessment(source: queen, candidates: [first, otherTitle]).skipReason,
                       .insufficientDurationlessAgreement)
        let source = SourceTrack(id: "collaboration", title: "Under Pressure (with David Bowie)", artist: "Queen & David Bowie")
        let collaboration = CatalogTrack(id: "1", title: source.title, artist: source.artist, duration: 248,
                                         isrc: "GBABC1234567", isExplicit: false, collectionID: "album")
        let solo = CatalogTrack(id: "2", title: source.title, artist: "Queen", duration: 249,
                                isrc: "GBABC1234568", isExplicit: false, collectionID: "single")
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: [collaboration, solo]).skipReason,
                       .insufficientDurationlessAgreement)
        let explicit = CatalogTrack(id: "3", title: queen.title, artist: queen.artist, duration: 355,
                                    isrc: "GBABC1234568", isExplicit: true, collectionID: "single")
        XCTAssertEqual(RecordingMatcher.assessment(source: queen, candidates: [first, explicit]).skipReason, .contentConflict)
        let longer = CatalogTrack(id: "4", title: queen.title, artist: queen.artist, duration: 356.001,
                                  isrc: "GBABC1234568", isExplicit: false)
        XCTAssertEqual(RecordingMatcher.assessment(source: queen, candidates: [first, longer]).skipReason,
                       .insufficientDurationlessAgreement)
    }

}
