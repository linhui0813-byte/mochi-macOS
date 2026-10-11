import Darwin
import MochiKernel
import XCTest

final class AppFailureTests: XCTestCase {
    func testOutOfSpaceIsFoundBeneathManyWrappers() {
        var error: Error = POSIXError(.ENOSPC)
        for i in 0..<10 { error = AppFailure("Wrapper \(i)", underlying: error) }
        XCTAssertTrue(ErrorChain.isOutOfSpace(error))
        XCTAssertEqual(ErrorChain.causes(of: error).count, 6)
    }

    func testOutOfSpaceIsRecognisedThroughTheCauseChain() {
        XCTAssertTrue(ErrorChain.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertTrue(ErrorChain.isOutOfSpace(POSIXError(.ENOSPC)))
        XCTAssertTrue(ErrorChain.isOutOfSpace(AppFailure("Could not save.", underlying: POSIXError(.EDQUOT))))
        XCTAssertFalse(ErrorChain.isOutOfSpace(POSIXError(.EACCES)))
        XCTAssertFalse(ErrorChain.isOutOfSpace(AppFailure("The disk is full.")))
    }
}
