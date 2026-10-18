import Foundation
import Testing
@testable import JoyHarness

@Suite(.serialized)
struct JoyConDirectionalMergeTests {
    private let faceInputs: Set<ControllerInput> = [.buttonA, .buttonB, .buttonX, .buttonY]

    @Test(arguments: JoyConOrientation.allCases, JoyConSide.allCases)
    func onePhysicalDirectionDoesNotAlsoPressAnAppleAlias(orientation: JoyConOrientation, side: JoyConSide) throws {
        let directions: [(UInt8, ControllerInput, ControllerInput)] = side == .left ? [
            (0x01, .buttonB, .buttonY), // down
            (0x02, .buttonX, .buttonA), // up
            (0x04, .buttonY, .buttonX), // right
            (0x08, .buttonA, .buttonB), // left
        ] : [
            (0x01, .buttonY, .buttonA), // printed Y
            (0x02, .buttonB, .buttonX), // printed X
            (0x04, .buttonX, .buttonB), // printed B
            (0x08, .buttonA, .buttonY), // printed A
        ]
        for (bits, expected, appleAlias) in directions {
            let bridge = ButtonBridge { _ in .disabled }
            var pressed: Set<ControllerInput> = []
            bridge.onInputStateChange = { input, down in
                if down { pressed.insert(input) } else { pressed.remove(input) }
            }
            let apple = JoyConProfileSample(
                snapshot: JoyConInputSnapshot(
                    buttons: [appleAlias: true], primaryStick: .neutral, secondaryStick: .neutral
                ),
                availableInputs: faceInputs
            )
            for mask: UInt8 in [bits, 0] {
                var report: [UInt8] = [0x30, 0, 0, 0, 0, 0]
                report[side == .left ? 5 : 3] = mask
                let hid = try #require(JoyConHIDInputReportParser.shoulders(
                    from: report, side: side
                ))
                let sample = JoyConSingleShoulderAdapter.apply(
                    hid, to: apple, side: side, orientation: orientation
                )
                bridge.applyJoyConSnapshot(sample.snapshot)
                #expect(pressed.intersection(faceInputs) == (mask == 0 ? [] : [expected]))
            }
        }
    }

    @Test(arguments: JoyConSide.allCases)
    func pairedHIDReplacesItsOwnDirectionsAndPreservesTheOtherSide(side: JoyConSide) throws {
        let alias: ControllerInput = side == .left ? .dpadRight : .buttonY
        let expected: ControllerInput = side == .left ? .dpadUp : .buttonA
        let peer: ControllerInput = side == .left ? .buttonB : .dpadDown
        let apple = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [alias: true, peer: true], primaryStick: .neutral, secondaryStick: .neutral
            ), availableInputs: [alias, peer]
        )
        for mask: UInt8 in [side == .left ? 0x02 : 0x08, 0] {
            var report: [UInt8] = [0x30, 0, 0, 0, 0, 0]
            report[side == .left ? 5 : 3] = mask
            let hid = try #require(JoyConHIDInputReportParser.shoulders(from: report, side: side))
            let sample = JoyConPairedShoulderAdapter.apply(hid, to: apple, side: side)
            let pressed = Set(sample.snapshot.buttons.filter { $0.value }.map(\.key))
            #expect(pressed == (mask == 0 ? [peer] : [peer, expected]))
        }
    }

    @Test
    func realSimultaneousDirectionsArePreserved() throws {
        let hid = try #require(JoyConHIDInputReportParser.shoulders(
            from: [0x30, 0, 0, 0, 0, 0x0a], side: .left
        ))
        let sample = JoyConSingleShoulderAdapter.apply(
            hid,
            to: JoyConProfileSample(snapshot: .neutral, availableInputs: []),
            side: .left, orientation: .vertical
        )
        let pressed = Set(sample.snapshot.buttons.filter { $0.value }.map(\.key))
        #expect(pressed.intersection(faceInputs) == [.buttonA, .buttonX])
    }

    @Test(arguments: [false, true])
    func upDoesNotAlsoRunTheLeftButtonAction(withZL: Bool) throws {
        let defaults = ControllerMappingStore.defaultMappings(for: .joyConLeft, provider: .codex)
        let bridge = ButtonBridge { input in
            input == .rightShoulder ? .functionModifier : defaults[input] ?? .disabled
        }
        var actions: [String] = []
        bridge.mouseButtonHandler = { _, down in if down { actions.append("mouse") } }
        bridge.systemKeyHandler = { key, down in
            if down {
                #expect(key == .escape)
                actions.append("escape")
            }
        }
        bridge.textInputHandler = { actions.append($0); return true }
        bridge.keyHandler = { key, pressed in
            if pressed != 0 { actions.append(key) }
            return true
        }
        let hid = try #require(JoyConHIDInputReportParser.shoulders(
            from: [0x30, 0, 0, 0, 0, withZL ? 0x82 : 0x02], side: .left
        ))
        let projected = JoyConSingleShoulderAdapter.apply(
            hid,
            to: JoyConProfileSample(
                snapshot: JoyConInputSnapshot(
                    buttons: [.buttonA: true], primaryStick: .neutral, secondaryStick: .neutral
                ), availableInputs: faceInputs
            ), side: .left, orientation: .vertical
        )
        bridge.applyJoyConSnapshot(projected.snapshot)
        #expect(actions == [withZL ? "AG00" : "escape"])
        bridge.applyJoyConSnapshot(.neutral)
    }
}
