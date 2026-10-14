import XCTest

@testable import MochiProviders

private final class PingCallbackFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Error?) -> Void)?
    func install(_ callback: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }
    func complete(_ error: Error?) {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        callback?(error)
    }
}

final class RealtimePingTests: XCTestCase {
    func testPongThenRepeatedCloseErrorsDoNotCompleteTheWaitTwice() async throws {
        try await RealtimeChannel.awaitPing { completion in
            completion(nil)
            completion(URLError(.networkConnectionLost))
            completion(URLError(.cancelled))
        }
    }
    func testFirstFailureWinsOverALaterPongOrFailure() async throws {
        do {
            try await RealtimeChannel.awaitPing { completion in
                completion(URLError(.networkConnectionLost))
                completion(nil)
                completion(URLError(.cancelled))
            }
            XCTFail("Expected the original connection failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }
    func testCancellationUnblocksAPingThatNeverCallsBackAndIgnoresLateCallbacks() async throws {
        let fixture = PingCallbackFixture()
        let waiting = expectation(description: "Ping registered")
        let task = Task {
            try await RealtimeChannel.awaitPing {
                fixture.install($0)
                waiting.fulfill()
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        fixture.complete(nil)
        fixture.complete(URLError(.cancelled))
    }
    func testAlreadyCancelledPingDoesNotTouchTheSocket() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await RealtimeChannel.awaitPing { _ in XCTFail("Do not ping after cancellation") }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
    func testConcurrentPongsAndCloseCallbacksSettleOnlyOnce() async throws {
        let completed = expectation(description: "All racing callbacks finished")
        completed.expectedFulfillmentCount = 100
        try await RealtimeChannel.awaitPing { completion in
            completion(nil)
            for index in 0..<100 {
                DispatchQueue.global().async {
                    completion(index % 2 == 0 ? nil : URLError(.cancelled))
                    completed.fulfill()
                }
            }
        }
        await fulfillment(of: [completed], timeout: 2)
    }
    func testDeadlineClosingTheSocketTwiceProducesTimeoutInsteadOfACrash() async throws {
        let fixture = PingCallbackFixture()
        do {
            try await RealtimeDeadline.run(
                nanoseconds: 10_000_000,
                close: {
                    fixture.complete(URLError(.networkConnectionLost))
                    fixture.complete(URLError(.cancelled))
                }
            ) {
                try await RealtimeChannel.awaitPing { fixture.install($0) }
            }
            XCTFail("Expected timeout")
        } catch {
            XCTAssertTrue(error is RealtimeTimeout)
        }
    }
}
