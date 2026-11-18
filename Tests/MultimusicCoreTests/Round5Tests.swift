import XCTest
import MultimusicCore

final class Round5Tests: XCTestCase {
    func testSavedQueenPackets() throws {
        let packets = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Queen")
        for (id, title, expected) in [
            ("0xcWxI1fUxfD6LrrljUH7L", "Love of My Life", "6781023655"),
            ("68Fa3IMF05Rj9lX3TRJepp", "A Kind of Magic", "6781023235"),
            ("11fDQmW6T3zyX6OEKKF11O", "Friends Will Be Friends", "6781074821"),
            ("4GHk8YtewHGbk6HsVJ0mcT", "The Show Must Go On", "6781078887"),
            ("1OuuQNfGJ0KwD4KUJ7tuzj", "Hammer To Fall", "")
        ] {
            let tracks = try ITunesCatalog.tracks(from: Data(contentsOf: packets.appendingPathComponent(id + ".json")))
            XCTAssertEqual(tracks.count, 25)
            let assessment = RecordingMatcher.assessment(source: SourceTrack(id: id, title: title, artist: "Queen"), candidates: tracks)
            if expected.isEmpty {
                XCTAssertNil(assessment.decision)
                XCTAssertEqual(assessment.skipReason, .insufficientDurationlessAgreement)
                XCTAssertEqual(assessment.diagnosticFields["durationlessGuard"], "tiedDurationGroups")
                XCTAssertEqual(assessment.diagnosticFields["tiedSpanSeconds"], "48.602")
            } else {
                XCTAssertEqual(assessment.decision?.track.id, expected, title)
                XCTAssertEqual(assessment.decision?.confidence, .metadataOnly)
                XCTAssertNil(assessment.skipReason)
            }
            print("Queen replay: \(title) -> \(assessment.decision?.track.id ?? assessment.skipReason!.rawValue)" +
                  (assessment.diagnosticFields["tiedSpanSeconds"].map { " (\($0)s span)" } ?? ""))
        }
    }

    func testTiedGroupsUseSearchOrderAndTheFullFifteenSecondSpan() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Queen")
        func track(_ id: String, _ duration: Double) -> CatalogTrack {
            CatalogTrack(id: id, title: source.title, artist: source.artist, duration: duration,
                         isExplicit: false, collectionID: id)
        }
        let first = [track("a", 200), track("b", 201)]
        let second = [track("c", 214), track("d", 215)]
        for (ordered, expected) in [(first + second, "a"), (second + first, "c")] {
            XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: ordered)?.track.id, expected)
        }
        let tooWide = first + [track("c", 214), track("d", 215.001)]
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: tooWide).diagnosticFields["tiedSpanSeconds"], "15.001")
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: tooWide))
        let third = [track("e", 220), track("f", 220)]
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: first + second + third))
    }

    func testTiedGroupsRejectTopRankedMinorityAndSingletonTies() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Queen")
        func track(_ id: String, _ duration: Double) -> CatalogTrack {
            CatalogTrack(id: id, title: source.title, artist: source.artist, duration: duration,
                         isExplicit: false, collectionID: id)
        }
        let tied = [track("a", 200), track("b", 200), track("c", 210), track("d", 210)]
        let minority = track("top", 205)
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: [minority] + tied).diagnosticFields["durationlessGuard"], "tiedDurationGroups")
        XCTAssertEqual(RecordingMatcher.decision(source: source, candidates: tied + [minority])?.track.id, "a")
        let singles = RecordingMatcher.assessment(source: source, candidates: [track("a", 200), track("b", 205)])
        XCTAssertNil(singles.decision)
        XCTAssertEqual(singles.diagnosticFields["durationGroupCounts"], "1,1")
        XCTAssertEqual(singles.diagnosticFields["tiedSpanSeconds"], "5.0")
    }

    func testTiedDurationExceptionDoesNotAdmitLiveOrExplicitnessConflicts() {
        let source = SourceTrack(id: "source", title: "Song", artist: "Queen")
        func tracks(_ title: String, explicit: Bool = false) -> [CatalogTrack] {
            [200.0, 201, 210, 211].enumerated().map { index, duration in
                CatalogTrack(id: String(index), title: title, artist: source.artist, duration: duration,
                             isExplicit: explicit, collectionID: String(index))
            }
        }
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: tracks("Song (Live)")))
        XCTAssertNil(RecordingMatcher.decision(source: SourceTrack(id: "live", title: "Song (Live)", artist: "Queen"), candidates: tracks("Song")))
        XCTAssertNil(RecordingMatcher.decision(source: source, candidates: tracks("Song (Explicit)")))
        XCTAssertEqual(RecordingMatcher.assessment(source: source, candidates: tracks("Song") + tracks("Song", explicit: true)).skipReason, .contentConflict)
    }
}
