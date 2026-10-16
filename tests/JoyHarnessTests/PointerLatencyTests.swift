import Foundation
import Testing
@testable import JoyHarness

struct PointerLatencyTests {
    @Test(arguments: [60.0, 120.0])
    func reversingTheStickChangesPointerDirectionOnTheNextFrame(frameRate: Double) {
        let frameDuration = CGFloat(1 / frameRate)
        var channel = MotionChannel()
        channel.targetVelocity = CGPoint(x: 1250, y: 0)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: frameDuration) }

        channel.targetVelocity = CGPoint(x: -1250, y: 0)
        let nextFrame = channel.advance(deltaTime: frameDuration)
        #expect(nextFrame.x < 0)
    }

    @Test(arguments: [60.0, 120.0])
    func releasingTheStickDoesNotLeaveVisiblePointerDrift(frameRate: Double) {
        let frameDuration = CGFloat(1 / frameRate)
        var channel = MotionChannel()
        channel.targetVelocity = CGPoint(x: 1250, y: 0)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: frameDuration) }

        channel.targetVelocity = .zero
        let firstFrame = channel.advance(deltaTime: frameDuration)
        let secondFrame = channel.advance(deltaTime: frameDuration)
        #expect(firstFrame.x + secondFrame.x <= 1)
    }

    @Test(arguments: [60.0, 120.0])
    func pushingTheStickStartsNearTheRequestedSpeedOnTheFirstFrame(frameRate: Double) {
        let frameDuration = CGFloat(1 / frameRate)
        var channel = MotionChannel()
        channel.targetVelocity = CGPoint(x: 1250, y: 0)
        let firstFrame = channel.advance(deltaTime: frameDuration)
        #expect(firstFrame.x >= 1250 * frameDuration * 0.75)
    }
}
