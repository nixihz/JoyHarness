import Foundation
import Testing
@testable import JoyHarness

struct JoyConAnalogStickTests {
    @Test
    func rightStickUsesItsCalibrationOrderAndAsymmetricRanges() throws {
        let calibration = try #require(JoyConStickCalibration(
            data: [0x00, 0x08, 0x80, 0x00, 0x02, 0x30, 0x00, 0x04, 0x50],
            side: .right,
            source: .user
        ))
        let snapshot = try #require(JoyConHIDStickReportParser.snapshot(
            from: [0x30, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0x00, 0x07, 0x90],
            side: .right,
            calibration: calibration
        ))
        #expect(abs(snapshot.stick.x + 0.5) < 0.000_001)
        #expect(abs(snapshot.stick.y - 0.2) < 0.000_001)
        #expect(snapshot.calibrationSource == .user)
    }

    @Test
    func hidStickKeepsTravelAndDirectionAcrossGripsAndPairing() {
        let snapshot = JoyConHIDStickSnapshot(
            stick: JoyConStick(x: 0.25, y: 0.5), calibrationSource: .factory
        )
        let sample = JoyConProfileSample(snapshot: .neutral, availableInputs: [])
        let scenarios: [(JoyConSide, Bool, JoyConOrientation, JoyConStick, JoyConStick)] = [
            (.left, false, .horizontal, JoyConStick(x: -0.5, y: 0.25), .neutral),
            (.right, false, .horizontal, JoyConStick(x: 0.5, y: -0.25), .neutral),
            (.left, false, .vertical, JoyConStick(x: 0.25, y: 0.5), .neutral),
            (.right, false, .vertical, JoyConStick(x: 0.25, y: 0.5), .neutral),
            (.left, true, .horizontal, JoyConStick(x: 0.25, y: 0.5), .neutral),
            (.right, true, .horizontal, .neutral, JoyConStick(x: 0.25, y: 0.5)),
        ]
        for (side, paired, orientation, primary, secondary) in scenarios {
            let projected = JoyConHIDStickAdapter.apply(
                snapshot, to: sample, side: side, paired: paired, orientation: orientation
            )
            #expect(projected.snapshot.primaryStick == primary)
            #expect(projected.snapshot.secondaryStick == secondary)
        }
    }

    @Test
    func absentHIDStickPreservesTheAvailableAppleAnalogInput() {
        let sample = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [:], primaryStick: JoyConStick(x: 0.4, y: -0.3), secondaryStick: .neutral
            ),
            availableInputs: []
        )
        let projected = JoyConHIDStickAdapter.apply(
            nil, to: sample, side: .left, paired: false, orientation: .horizontal
        )
        #expect(projected.snapshot == sample.snapshot)
    }

    @Test
    func invalidCalibrationAndUnsupportedReportsAreRejected() {
        for bytes in [[UInt8](repeating: 0, count: 9), [UInt8](repeating: 0xff, count: 9), [0, 1]] {
            #expect(JoyConStickCalibration(data: bytes, side: .left, source: .factory) == nil)
            #expect(JoyConStickCalibration(data: bytes, side: .right, source: .factory) == nil)
        }
        for report in [[UInt8](repeating: 0x30, count: 11), [UInt8](repeating: 0x3f, count: 12), []] {
            #expect(JoyConHIDStickReportParser.snapshot(
                from: report, side: .left, calibration: .default
            ) == nil)
        }
    }

    @Test @MainActor
    func hidTravelReachesPointerEvenWhenAppleDirectionPadIsDigital() throws {
        let calibration = try #require(JoyConStickCalibration(
            data: [0x00, 0x04, 0x40, 0x00, 0x08, 0x80, 0x00, 0x04, 0x40],
            side: .left,
            source: .factory
        ))
        let digitalSample = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [.buttonA: true],
                primaryStick: JoyConStick(x: 0, y: 1),
                secondaryStick: .neutral
            ),
            availableInputs: [.buttonA]
        )
        let reports: [[UInt8]] = [
            [0x30, 0, 0, 0, 0, 0, 0x00, 0x09, 0x80, 0, 0, 0],
            [0x30, 0, 0, 0, 0, 0, 0x00, 0x0a, 0x80, 0, 0, 0],
            [0x30, 0, 0, 0, 0, 0, 0x00, 0x0c, 0x80, 0, 0, 0],
            [0x30, 0, 0, 0, 0, 0, 0x00, 0x08, 0x80, 0, 0, 0],
        ]
        let bridge = ButtonBridge()
        var velocities: [CGFloat] = []
        bridge.leftStickHandler = { x, y, _ in
            velocities.append(abs(MouseBridge.pointerVelocity(x: CGFloat(x), y: CGFloat(y)).y))
        }
        for report in reports {
            let snapshot = try #require(JoyConHIDStickReportParser.snapshot(
                from: report, side: .left, calibration: calibration
            ))
            let sample = JoyConHIDStickAdapter.apply(
                snapshot, to: digitalSample, side: .left, paired: false, orientation: .horizontal
            )
            #expect(sample.snapshot.buttons == [.buttonA: true])
            bridge.applyJoyConSnapshot(sample.snapshot)
        }
        #expect(velocities.count == 4)
        guard velocities.count == 4 else { return }
        #expect(velocities[0] > 0 && velocities[0] <= 20)
        #expect(velocities[1] > velocities[0])
        #expect(velocities[2] > velocities[1] * 5)
        #expect(velocities[3] == 0)
    }
}
