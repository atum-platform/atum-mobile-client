@testable import AtumMobile
import SwiftUI
import XCTest

final class MotionTests: XCTestCase {
    func testTokensUseTheAgreedCurves() {
        XCTAssertEqual(Motion.quick.animation, .snappy(duration: 0.2))
        XCTAssertEqual(Motion.standard.animation, .smooth(duration: 0.3))
        XCTAssertEqual(Motion.send.animation, .spring(duration: 0.3, bounce: 0.15))
    }

    func testReduceMotionTurnsEveryTokenIntoTheShortEase() {
        for motion in Motion.allCases {
            XCTAssertEqual(motion.animation(reduceMotion: false), motion.animation)
            XCTAssertEqual(motion.animation(reduceMotion: true), .easeInOut(duration: 0.15))
        }
        XCTAssertEqual(Motion.reducedDuration, 0.15)
    }

    @MainActor
    func testWithMotionReturnsTheBodyResult() {
        XCTAssertEqual(withMotion(.quick, reduceMotion: true) { 7 }, 7)
    }
}
