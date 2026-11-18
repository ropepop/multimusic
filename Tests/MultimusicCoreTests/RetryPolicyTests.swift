import XCTest
import MultimusicCore

final class RetryPolicyTests: XCTestCase {
    func testErrorClassificationTable() {
        for code in [500, 502, 503, 504] {
            XCTAssertEqual(RetryPolicy.classify(NSError(domain: "iTunesHTTP", code: code)), .transport)
        }
        for code in [403, 429] {
            XCTAssertEqual(RetryPolicy.classify(NSError(domain: "iTunesHTTP", code: code)), .throttled)
        }
        for code in [400, 401, 404, 408, 409, 422, 501, 505] {
            XCTAssertEqual(RetryPolicy.classify(NSError(domain: "iTunesHTTP", code: code)), .never)
        }
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .networkConnectionLost,
                                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertEqual(RetryPolicy.classify(URLError(code)), .transport)
        }
        for error: Error in [CancellationError(), URLError(.cancelled), URLError(.badURL),
                             URLError(.dataLengthExceedsMaximum), CocoaError(.coderReadCorrupt),
                             NSError(domain: "NativeCommand", code: 500)] {
            XCTAssertEqual(RetryPolicy.classify(error), .never)
        }
    }

    func testAttemptAndDelayTables() {
        XCTAssertEqual(RetryPolicy.delay(afterFailure: 1, .transport), .seconds(2))
        XCTAssertEqual(RetryPolicy.delay(afterFailure: 2, .transport), .seconds(6))
        XCTAssertNil(RetryPolicy.delay(afterFailure: 3, .transport))
        for (header, seconds) in [(nil, 10.0), (-1, 10), (5, 10), (20, 20), (90, 30), (.nan, 10), (.infinity, 10)] as [(Double?, Double)] {
            XCTAssertEqual(RetryPolicy.delay(afterFailure: 1, .throttled, retryAfter: header), .seconds(seconds))
        }
        XCTAssertNil(RetryPolicy.delay(afterFailure: 2, .throttled))
        for count in [0, 1, 2, 3, 100] { XCTAssertNil(RetryPolicy.delay(afterFailure: count, .never)) }
        XCTAssertEqual(RetryPolicy.resumeDelays, [.seconds(15), .seconds(45)])
    }

    func testBudgetIsSharedAcrossRequestsInOneResolution() {
        var budget = RetryBudget()
        for _ in 0..<3 {
            XCTAssertTrue(budget.take())
            XCTAssertTrue(budget.take())
        }
        XCTAssertEqual(budget.retries, 6)
        XCTAssertFalse(budget.take())
        XCTAssertFalse(budget.take())
        var nextResolution = RetryBudget()
        XCTAssertTrue(nextResolution.take())
    }

    func testOnlyRecallSkipsPermitOneManualSecondLook() {
        for reason: MatchSkipReason in [.noResults, .noCompatibleMetadata] { XCTAssertTrue(RetryPolicy.isRetryable(reason)) }
        for reason: MatchSkipReason in [.invalidSource, .contentConflict, .insufficientDurationlessAgreement, .ambiguousRecording] {
            XCTAssertFalse(RetryPolicy.isRetryable(reason))
        }
    }
}
