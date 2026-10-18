import CoreGraphics
import Testing
@testable import JoyHarness

struct MotionJumpPointerTargetTests {
    @Test func quadrantsAreCentersOfThePressedDisplay() {
        let target = MotionJumpPointerTarget(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(target.point(for: .upperLeft) == CGPoint(x: 480, y: 270))
        #expect(target.point(for: .upperRight) == CGPoint(x: 1440, y: 270))
        #expect(target.point(for: .lowerLeft) == CGPoint(x: 480, y: 810))
        #expect(target.point(for: .lowerRight) == CGPoint(x: 1440, y: 810))
    }

    @Test func displayLeftAndAboveMainUsesItsOwnQuartzOrigin() {
        let target = MotionJumpPointerTarget(displayID: 2, bounds: CGRect(x: -2560, y: -720, width: 2560, height: 1440))
        #expect(target.point(for: .upperLeft) == CGPoint(x: -1920, y: -360))
        #expect(target.point(for: .lowerRight) == CGPoint(x: -640, y: 360))
    }
}
