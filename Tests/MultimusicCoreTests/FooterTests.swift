import XCTest
import MultimusicCore

final class FooterTests: XCTestCase {
    private func state(_ configure: (inout FooterInput) -> Void = { _ in }) -> FooterState {
        var input = FooterInput()
        configure(&input)
        return .make(input)
    }

    func testEveryFooterRowAndAction() {
        let cases: [(String, FooterState.Action?, (inout FooterInput) -> Void)] = [
            ("Choose a song", nil, { _ in }),
            ("Browse Spotify", nil, { $0.playbackEnabled = false; $0.site = "Spotify" }),
            ("Apple Music not connected", .connect, { $0.authorized = false }),
            ("Could not save queue", .details, { $0.problem = "Could not save queue. More details." }),
            ("No match · Music unchanged", nil, { $0.noMatch = true }),
            ("Matching 3 of 12", nil, { $0.preSubmission = true; $0.processedCount = 2; $0.sourceCount = 12 }),
            ("Retrying 2 of 3…", nil, { $0.preSubmission = true; $0.retryAttempt = 2 }),
            ("Couldn't reach catalog · Music unchanged", .retry, { $0.preSubmission = true; $0.failed = true }),
            ("12 in Music", nil, { $0.owned = true; $0.submittedCount = 12 }),
            ("12 in Music", .retry, { $0.owned = true; $0.submittedCount = 12; $0.retryableSkips = 2 }),
            ("12 in Music · matching 10 of 12", nil, { $0.owned = true; $0.submittedCount = 12; $0.matching = true; $0.processedCount = 9; $0.sourceCount = 12 }),
            ("12 in Music · retrying 2 of 3", nil, { $0.owned = true; $0.submittedCount = 12; $0.retryAttempt = 2 }),
            ("12 in Music · retrying 2 skipped", nil, { $0.owned = true; $0.submittedCount = 12; $0.retryingSkipped = 2 }),
            ("12 in Music · matching paused", .retry, { $0.owned = true; $0.submittedCount = 12; $0.paused = true; $0.failed = true }),
            ("12 in Music · matching paused", nil, { $0.owned = true; $0.submittedCount = 12; $0.paused = true }),
            ("12 in Music · matching paused", nil, { $0.owned = true; $0.submittedCount = 12; $0.paused = true; $0.failed = true; $0.canRetryMatching = false }),
            ("Saved queue · 8 left", .restore, { $0.savedRemaining = 8 }),
            ("Queue finished", .replay, { $0.finished = true; $0.savedRemaining = 8; $0.owned = true }),
            ("Queue cleared", nil, { $0.cleared = true; $0.savedRemaining = 8; $0.owned = true })
        ]
        for (text, action, configure) in cases {
            let result = state(configure)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.action, action, text)
            XCTAssertLessThanOrEqual(result.text.count, 40, text)
        }
    }

    func testPrecedence() {
        var input = FooterInput()
        input.cleared = true
        XCTAssertEqual(FooterState.make(input).text, "Queue cleared")
        input.finished = true
        XCTAssertEqual(FooterState.make(input).text, "Queue finished")
        input.finished = false; input.cleared = false
        input.savedRemaining = 8
        XCTAssertEqual(FooterState.make(input).action, .restore)
        input.owned = true
        XCTAssertEqual(FooterState.make(input).text, "0 in Music")
        input.preSubmission = true
        XCTAssertEqual(FooterState.make(input).text, "Matching 0 of 0")
        input.noMatch = true
        XCTAssertEqual(FooterState.make(input).text, "No match · Music unchanged")
        input.problem = "Storage problem. Details."
        XCTAssertEqual(FooterState.make(input).text, "Storage problem")
        input.authorized = false
        XCTAssertEqual(FooterState.make(input).action, .connect)
        input.playbackEnabled = false
        XCTAssertEqual(FooterState.make(input).text, "Browse YouTube Music")
    }

    func testChipVisibilityAnnouncementsAndFullSentences() {
        var input = FooterInput()
        input.owned = true; input.submittedCount = 12; input.matching = true
        input.processedCount = 9; input.sourceCount = 12; input.skippedCount = 2
        XCTAssertEqual(FooterState.make(input).accessibilityText, "12 songs in Apple Music, matching song 10 of 12")
        XCTAssertEqual(FooterState.make(input).skippedCount, 2)
        input.paused = true; input.failed = true
        XCTAssertEqual(FooterState.make(input).skippedCount, 0)
        XCTAssertTrue(FooterState.make(input).announce)
        input.paused = false; input.failed = false; input.problem = "Queue uncertain. Details."
        XCTAssertTrue(FooterState.make(input).announce)
        XCTAssertEqual(FooterState.make(input).skippedCount, 0)
        input.problem = nil; input.noMatch = true
        XCTAssertEqual(FooterState.make(input).skippedCount, 0)
        input.noMatch = false; input.preSubmission = true; input.failed = true
        XCTAssertTrue(FooterState.make(input).announce)
        XCTAssertEqual(FooterState.make(input).skippedCount, 0)
    }

    func testLargestBatchCopyFits() {
        let value = state { $0.owned = true; $0.submittedCount = 60; $0.matching = true; $0.processedCount = 59; $0.sourceCount = 60 }
        XCTAssertLessThanOrEqual(value.text.count, 40)
    }

    func testProblemFirstSentencesFitAndKeepDetailsAvailable() {
        for message in [
            "Could not safely save the queue. Error details.",
            "Music queue protection is unavailable. Playback has been preserved.",
            "Music took too long to respond. Open Setup to inspect its current state.",
            "Music’s last request is unconfirmed. Its queue has been preserved.",
            "Music could not prepare the queue. Error details.",
            "An append was interrupted. Use Restore before adding more songs.",
            "An interrupted request is unconfirmed. Its queue has been preserved.",
            "Music stopped; its saved state remains. Its old recovery state could not be invalidated.",
            "The saved Clear could not be recorded. It may retry when reopened."
        ] {
            let value = state { $0.problem = message }
            XCTAssertEqual(value.text, message.components(separatedBy: ".")[0])
            XCTAssertLessThanOrEqual(value.text.count, 40)
            XCTAssertEqual(value.action, .details)
        }
    }
}
