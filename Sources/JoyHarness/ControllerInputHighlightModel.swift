import Foundation

struct ControllerInputHighlightModel: Identifiable, Equatable {
    let input: ControllerInput
    let center: CGPoint
    let size: CGSize
    let cornerRadius: CGFloat

    var id: ControllerInput { input }

    static func layout(
        for family: ControllerFamily,
        orientation: JoyConOrientation = .vertical
    ) -> [ControllerInput: Self] {
        switch family {
        case .dualSense, .dualShock: playStationLayout
        case .xbox, .generic: xboxLayout
        case .xiaomiRemote: xiaomiRemoteLayout
        case .joyConPair: joyConPairLayout
        case .joyConLeft:
            orientation == .horizontal ? joyConLeftHorizontalLayout : joyConLeftVerticalLayout
        case .joyConRight:
            orientation == .horizontal ? joyConRightHorizontalLayout : joyConRightVerticalLayout
        }
    }

    private static let xiaomiRemoteLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.options, 0.76, 0.075, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.buttonA, 0.50, 0.235, size: CGSize(width: 38, height: 38), cornerRadius: 19),
        marker(.dpadUp, 0.50, 0.15, size: CGSize(width: 38, height: 18), cornerRadius: 7),
        marker(.dpadDown, 0.50, 0.31, size: CGSize(width: 38, height: 18), cornerRadius: 7),
        marker(.dpadLeft, 0.20, 0.235, size: CGSize(width: 18, height: 38), cornerRadius: 7),
        marker(.dpadRight, 0.80, 0.235, size: CGSize(width: 18, height: 38), cornerRadius: 7),
        marker(.buttonB, 0.28, 0.39, size: CGSize(width: 30, height: 30), cornerRadius: 15),
        marker(.rightShoulder, 0.72, 0.39, size: CGSize(width: 30, height: 30), cornerRadius: 15),
        marker(.home, 0.28, 0.495, size: CGSize(width: 30, height: 30), cornerRadius: 15),
        marker(.leftShoulder, 0.72, 0.495, size: CGSize(width: 30, height: 30), cornerRadius: 15),
        marker(.menu, 0.28, 0.60, size: CGSize(width: 30, height: 30), cornerRadius: 15),
        marker(.buttonY, 0.72, 0.60, size: CGSize(width: 30, height: 30), cornerRadius: 15),
    ].map { ($0.input, $0) })

    private static func marker(
        _ input: ControllerInput,
        _ x: CGFloat,
        _ y: CGFloat,
        size: CGSize = CGSize(width: 31, height: 31),
        cornerRadius: CGFloat = 16
    ) -> Self {
        Self(input: input, center: CGPoint(x: x, y: y), size: size, cornerRadius: cornerRadius)
    }

    private static let xboxLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.75, 0.40), marker(.buttonB, 0.82, 0.30),
        marker(.buttonX, 0.68, 0.30), marker(.buttonY, 0.75, 0.20),
        marker(.dpadUp, 0.37, 0.45), marker(.dpadLeft, 0.33, 0.51),
        marker(.dpadDown, 0.37, 0.57), marker(.dpadRight, 0.41, 0.51),
        marker(.leftThumbstickButton, 0.24, 0.29, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.rightThumbstickButton, 0.63, 0.50, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.menu, 0.58, 0.30, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.options, 0.42, 0.30, size: CGSize(width: 28, height: 28), cornerRadius: 14),
        marker(.home, 0.50, 0.187, size: CGSize(width: 32, height: 32), cornerRadius: 16),
        marker(.leftShoulder, 0.27, 0.07, size: CGSize(width: 64, height: 22), cornerRadius: 9),
        marker(.rightShoulder, 0.73, 0.07, size: CGSize(width: 64, height: 22), cornerRadius: 9),
        marker(.leftTrigger, 0.24, 0.035, size: CGSize(width: 58, height: 18), cornerRadius: 8),
        marker(.rightTrigger, 0.76, 0.035, size: CGSize(width: 58, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let playStationLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.78, 0.37), marker(.buttonB, 0.85, 0.27),
        marker(.buttonX, 0.72, 0.27), marker(.buttonY, 0.78, 0.16),
        marker(.dpadUp, 0.21, 0.20), marker(.dpadLeft, 0.15, 0.27),
        marker(.dpadDown, 0.21, 0.34), marker(.dpadRight, 0.27, 0.27),
        marker(.leftThumbstickButton, 0.34, 0.45, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.rightThumbstickButton, 0.66, 0.45, size: CGSize(width: 46, height: 46), cornerRadius: 23),
        marker(.menu, 0.72, 0.12, size: CGSize(width: 25, height: 31), cornerRadius: 10),
        marker(.options, 0.28, 0.12, size: CGSize(width: 25, height: 31), cornerRadius: 10),
        marker(.home, 0.50, 0.54, size: CGSize(width: 31, height: 18), cornerRadius: 8),
        marker(.touchpadButton, 0.50, 0.18, size: CGSize(width: 126, height: 68), cornerRadius: 12),
        marker(.leftShoulder, 0.24, 0.065, size: CGSize(width: 64, height: 20), cornerRadius: 8),
        marker(.rightShoulder, 0.76, 0.065, size: CGSize(width: 64, height: 20), cornerRadius: 8),
        marker(.leftTrigger, 0.20, 0.025, size: CGSize(width: 55, height: 18), cornerRadius: 8),
        marker(.rightTrigger, 0.80, 0.025, size: CGSize(width: 55, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    // Coordinates are measured against the full 1024 × 1536 source PNGs.
    // Rotation and pair composition transform these anchors with the artwork.
    private static let joyConLeftVerticalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.leftThumbstickButton, 0.470, 0.265, size: CGSize(width: 80, height: 80), cornerRadius: 40),
        marker(.buttonA, 0.363, 0.495, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonB, 0.466, 0.563, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonX, 0.466, 0.426, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonY, 0.572, 0.495, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.menu, 0.594, 0.128, size: CGSize(width: 29, height: 12), cornerRadius: 5),
        marker(.options, 0.538, 0.664, size: CGSize(width: 34, height: 34), cornerRadius: 7),
        marker(.leftShoulder, 0.400, 0.057, size: CGSize(width: 58, height: 18), cornerRadius: 9),
        marker(.rightShoulder, 0.530, 0.028, size: CGSize(width: 54, height: 18), cornerRadius: 8),
    ].map { ($0.input, $0) })

    private static let joyConRightVerticalLayout: [ControllerInput: Self] = Dictionary(uniqueKeysWithValues: [
        marker(.buttonA, 0.640, 0.255, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonB, 0.534, 0.187, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonX, 0.534, 0.326, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.buttonY, 0.428, 0.255, size: CGSize(width: 40, height: 40), cornerRadius: 20),
        marker(.leftThumbstickButton, 0.530, 0.496, size: CGSize(width: 82, height: 82), cornerRadius: 41),
        marker(.menu, 0.402, 0.117, size: CGSize(width: 30, height: 30), cornerRadius: 8),
        marker(.options, 0.451, 0.653, size: CGSize(width: 44, height: 44), cornerRadius: 22),
        marker(.leftShoulder, 0.480, 0.025, size: CGSize(width: 54, height: 18), cornerRadius: 8),
        marker(.rightShoulder, 0.650, 0.060, size: CGSize(width: 58, height: 18), cornerRadius: 9),
    ].map { ($0.input, $0) })

    private static var joyConLeftHorizontalLayout: [ControllerInput: Self] {
        horizontal(joyConLeftVerticalLayout, clockwise: false)
    }
    private static var joyConRightHorizontalLayout: [ControllerInput: Self] {
        horizontal(joyConRightVerticalLayout, clockwise: true)
    }
    private static func horizontal(_ source: [ControllerInput: Self], clockwise: Bool) -> [ControllerInput: Self] {
        var result = source.mapValues { item in
            Self(input: item.input,
                 center: clockwise ? CGPoint(x: 1 - item.center.y, y: item.center.x)
                    : CGPoint(x: item.center.y, y: 1 - item.center.x),
                 size: CGSize(width: item.size.height, height: item.size.width), cornerRadius: item.cornerRadius)
        }
        // SL/SR sit on the exposed rail; they replace L/ZL or ZR/R for solo horizontal grip.
        result[.leftShoulder] = marker(.leftShoulder, clockwise ? 0.365 : 0.275, 0.285,
            size: CGSize(width: 48, height: 12), cornerRadius: 6)
        result[.rightShoulder] = marker(.rightShoulder, clockwise ? 0.735 : 0.650, 0.285,
            size: CGSize(width: 48, height: 12), cornerRadius: 6)
        return result
    }
    private static var joyConPairLayout: [ControllerInput: Self] {
        let left: [(ControllerInput, ControllerInput)] = [
            (.leftThumbstickButton, .leftThumbstickButton), (.dpadLeft, .buttonA),
            (.dpadDown, .buttonB), (.dpadUp, .buttonX), (.dpadRight, .buttonY),
            (.options, .menu), (.leftShoulder, .leftShoulder), (.leftTrigger, .rightShoulder),
        ]
        let right: [(ControllerInput, ControllerInput)] = [
            (.buttonA, .buttonX), (.buttonB, .buttonA), (.buttonX, .buttonY), (.buttonY, .buttonB),
            (.rightThumbstickButton, .leftThumbstickButton), (.menu, .menu), (.home, .options),
            (.rightShoulder, .rightShoulder), (.rightTrigger, .leftShoulder),
        ]
        var result: [ControllerInput: Self] = [:]
        for (mapping, source, offset) in [(left, joyConLeftVerticalLayout, 0.0), (right, joyConRightVerticalLayout, 0.5)] {
            for (input, sourceInput) in mapping {
                guard let anchor = source[sourceInput] else { continue }
                result[input] = Self(input: input, center: CGPoint(x: offset + anchor.center.x / 2, y: anchor.center.y),
                                     size: anchor.size, cornerRadius: anchor.cornerRadius)
            }
        }
        return result
    }

}

extension ControllerInput {
    var physicalInput: ControllerInput {
        switch self {
        case .functionButtonA: .buttonA
        case .functionButtonB: .buttonB
        case .functionButtonX: .buttonX
        case .functionButtonY: .buttonY
        case .functionLeftShoulder: .leftShoulder
        case .functionRightShoulder: .rightShoulder
        case .functionRightTrigger: .rightTrigger
        case .functionLeftThumbstickButton: .leftThumbstickButton
        case .functionRightThumbstickButton: .rightThumbstickButton
        case .functionDpadUp: .dpadUp
        case .functionDpadLeft: .dpadLeft
        case .functionDpadDown: .dpadDown
        case .functionDpadRight: .dpadRight
        case .functionRightStickUp, .functionRightStickLeft,
             .functionRightStickDown, .functionRightStickRight: .rightThumbstickButton
        default: self
        }
    }
}
