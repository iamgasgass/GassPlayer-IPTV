import XCTest
@testable import GassPlayer

final class RetryPolicyTests: XCTestCase {
    struct DummyError: Error {}

    func testSucceedsOnFirstAttempt() async throws {
        var callCount = 0
        let result = try await RetryPolicy.withRetry(maxAttempts: 3) {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }

    func testRetriesUntilSuccess() async throws {
        var callCount = 0
        let result = try await RetryPolicy.withRetry(maxAttempts: 3, initialDelay: 0.01) {
            callCount += 1
            if callCount < 3 { throw DummyError() }
            return "ok dopo retry"
        }
        XCTAssertEqual(result, "ok dopo retry")
        XCTAssertEqual(callCount, 3)
    }

    func testThrowsAfterMaxAttempts() async {
        var callCount = 0
        do {
            _ = try await RetryPolicy.withRetry(maxAttempts: 2, initialDelay: 0.01) {
                callCount += 1
                throw DummyError()
            }
            XCTFail("Doveva lanciare un errore dopo il numero massimo di tentativi")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }
}
