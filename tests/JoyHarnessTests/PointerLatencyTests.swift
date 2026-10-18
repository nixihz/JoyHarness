import Foundation
import Testing
@testable import JoyHarness

struct PointerLatencyTests {
    @Test
    func fullDiagonalTravelDoesNotAcceleratePastTheCardinalSpeed() {
        let straight = MouseBridge.pointerVelocity(x: 1, y: 0)
        let diagonal = MouseBridge.pointerVelocity(x: 1, y: 1)
        #expect(abs(hypot(diagonal.x, diagonal.y) - straight.x) < 0.001)
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func obliqueTurnsFollowTheNewDirectionWithinOnePoint(frameRate: Double) {
        var channel = MotionChannel()
        channel.targetVelocity = MouseBridge.pointerVelocity(x: 0.9, y: 0.2)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: 1 / frameRate) }
        let next = MouseBridge.pointerVelocity(x: 0.2, y: 0.9)
        channel.targetVelocity = next
        let delta = channel.advance(deltaTime: 1 / frameRate)
        #expect(abs(delta.x - next.x / frameRate) < 1)
        #expect(abs(delta.y - next.y / frameRate) < 1)
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func lightPushMovesAVisiblePointWithin50Milliseconds(frameRate: Double) {
        var channel = MotionChannel()
        channel.targetVelocity = MouseBridge.pointerVelocity(x: 0.20, y: 0)
        var distance: CGFloat = 0
        for _ in 0..<Int(frameRate * 0.05) {
            distance += channel.advance(deltaTime: 1 / frameRate).x
        }
        #expect(distance >= 1, "20% stick travel moved only \(distance) points in 50 ms")
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func slowingDownDoesNotCarryBoostedVelocityIntoFineAiming(frameRate: Double) {
        var channel = MotionChannel()
        channel.targetVelocity = MouseBridge.pointerVelocity(x: 1, y: 0, speedMultiplier: 2.1)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: 1 / frameRate) }
        let aim = MouseBridge.pointerVelocity(x: 0.25, y: 0)
        channel.targetVelocity = aim
        let distance = channel.advance(deltaTime: 1 / frameRate).x
        #expect(distance <= aim.x / frameRate + 1,
                "First aiming frame overshot by \(distance - aim.x / frameRate) points")
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func gentleReversalNeverContinuesInThePreviousDirection(frameRate: Double) {
        let frameDuration = CGFloat(1 / frameRate)
        var channel = MotionChannel()
        channel.targetVelocity = MouseBridge.pointerVelocity(x: 1, y: 0, speedMultiplier: 2.1)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: frameDuration) }

        channel.targetVelocity = MouseBridge.pointerVelocity(x: -0.35, y: 0)
        let nextFrame = channel.advance(deltaTime: frameDuration)
        #expect(nextFrame.x <= 0)
        var displacement = nextFrame.x
        for _ in 0..<Int(frameRate / 10) {
            let frame = channel.advance(deltaTime: frameDuration)
            #expect(frame.x <= 0)
            displacement += frame.x
        }
        #expect(displacement < 0)
    }

    @Test(arguments: [60.0, 120.0, 240.0])
    func releasingBoostedStickStopsWithoutCoasting(frameRate: Double) {
        let frameDuration = CGFloat(1 / frameRate)
        var channel = MotionChannel()
        channel.targetVelocity = MouseBridge.pointerVelocity(x: 1, y: 0, speedMultiplier: 2.1)
        for _ in 0..<Int(frameRate) { _ = channel.advance(deltaTime: frameDuration) }

        channel.targetVelocity = .zero
        for _ in 0..<3 {
            #expect(channel.advance(deltaTime: frameDuration) == .zero)
        }
    }

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
