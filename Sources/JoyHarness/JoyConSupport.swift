import Foundation
import GameController

enum JoyConSide: String, Codable, CaseIterable {
    case left
    case right
}

enum JoyConOrientation: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horizontal: L10n.text("横握", "Horizontal")
        case .vertical: L10n.text("竖握", "Vertical")
        }
    }
}

enum JoyConMode: String, Codable {
    case pair
    case left
    case right

    var controllerFamily: ControllerFamily {
        switch self {
        case .pair: .joyConPair
        case .left: .joyConLeft
        case .right: .joyConRight
        }
    }
}

enum JoyConControllerSelectionPolicy {
    static func shouldUseJoyCon(
        hasJoyCon: Bool,
        hasStandardController: Bool,
        currentIsJoyCon: Bool,
        currentIsStandardController: Bool,
        attachedIsJoyCon: Bool
    ) -> Bool {
        guard hasJoyCon else { return false }
        return currentIsJoyCon || (!currentIsStandardController && (
            attachedIsJoyCon || !hasStandardController
        ))
    }
}

enum JoyConHardwareKind: Equatable {
    case left
    case right
    case pair

    static func detect(vendorName: String?, productCategory: String) -> Self? {
        let identity = JoyConIdentity.normalized("\(vendorName ?? "") \(productCategory)")
        guard identity.contains("joycon") else { return nil }
        if identity.contains("joyconlr") ||
            identity.contains("joyconleftright") ||
            identity.contains("joyconcombined") {
            return .pair
        }
        if identity.contains("joyconleft") || identity.hasSuffix("joyconl") { return .left }
        if identity.contains("joyconright") || identity.hasSuffix("joyconr") { return .right }
        return nil
    }
}

private enum JoyConIdentity {
    static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

struct JoyConCapabilities: Equatable {
    var hasBattery: Bool
    var hasHaptics: Bool
    var hasMotion: Bool
    var profileElements: [String]

    static let none = JoyConCapabilities(
        hasBattery: false,
        hasHaptics: false,
        hasMotion: false,
        profileElements: []
    )
}

struct JoyConEndpointDescriptor: Equatable, Identifiable {
    let id: String
    let kind: JoyConHardwareKind
    let capabilities: JoyConCapabilities

    init(id: String, kind: JoyConHardwareKind, capabilities: JoyConCapabilities = .none) {
        self.id = id
        self.kind = kind
        self.capabilities = capabilities
    }
}

struct JoyConComposition: Equatable {
    let mode: JoyConMode?
    let combinedID: String?
    let leftID: String?
    let rightID: String?
    let inactiveIDs: [String]
    let generation: UInt64

    static let disconnected = JoyConComposition(
        mode: nil,
        combinedID: nil,
        leftID: nil,
        rightID: nil,
        inactiveIDs: [],
        generation: 0
    )

    func accepts(endpointID: String, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration else { return false }
        return endpointID == combinedID || endpointID == leftID || endpointID == rightID
    }
}

struct JoyConCompositionCoordinator {
    private(set) var composition = JoyConComposition.disconnected

    mutating func reconcile(_ endpoints: [JoyConEndpointDescriptor]) -> JoyConComposition {
        let combined = preferred(
            from: endpoints.filter { $0.kind == .pair },
            retaining: composition.combinedID
        )
        let left = combined == nil ? preferred(
            from: endpoints.filter { $0.kind == .left },
            retaining: composition.leftID
        ) : nil
        let right = combined == nil ? preferred(
            from: endpoints.filter { $0.kind == .right },
            retaining: composition.rightID
        ) : nil

        let mode: JoyConMode? = if combined != nil || (left != nil && right != nil) {
            .pair
        } else if left != nil {
            .left
        } else if right != nil {
            .right
        } else {
            nil
        }
        let activeIDs = Set([combined?.id, left?.id, right?.id].compactMap { $0 })
        let inactiveIDs = endpoints.map(\.id).filter { !activeIDs.contains($0) }.sorted()
        let identityChanged = composition.mode != mode ||
            composition.combinedID != combined?.id ||
            composition.leftID != left?.id ||
            composition.rightID != right?.id
        composition = JoyConComposition(
            mode: mode,
            combinedID: combined?.id,
            leftID: left?.id,
            rightID: right?.id,
            inactiveIDs: inactiveIDs,
            generation: identityChanged ? composition.generation &+ 1 : composition.generation
        )
        return composition
    }

    private func preferred(
        from endpoints: [JoyConEndpointDescriptor],
        retaining activeID: String?
    ) -> JoyConEndpointDescriptor? {
        if let activeID, let active = endpoints.first(where: { $0.id == activeID }) { return active }
        return endpoints.sorted { $0.id < $1.id }.first
    }
}

struct JoyConStick: Codable, Equatable {
    let x: Float
    let y: Float

    static let neutral = JoyConStick(x: 0, y: 0)
}

enum JoyConAxisSource {
    case single(side: JoyConSide, orientation: JoyConOrientation)
    case separatedPair(side: JoyConSide)
    case combinedPair
}

enum JoyConAxisNormalizer {
    static func normalize(
        source: JoyConAxisSource,
        x: Float,
        y: Float
    ) -> JoyConStick {
        // Apple side profiles are player-relative mini controllers, so their axes
        // already match horizontal grip. Upright and separated-pair layouts undo it.
        switch source {
        case .single(_, .horizontal), .combinedPair:
            JoyConStick(x: x, y: y)
        case .single(.left, .vertical), .separatedPair(.left):
            JoyConStick(x: y, y: -x)
        case .single(.right, .vertical), .separatedPair(.right):
            JoyConStick(x: -y, y: x)
        }
    }
}

struct JoyConStickProjection: Equatable {
    let primary: JoyConStick
    let secondary: JoyConStick
}

enum JoyConStickProjector {
    static func sideProfile(
        side: JoyConSide,
        paired: Bool,
        orientation: JoyConOrientation,
        raw: JoyConStick
    ) -> JoyConStickProjection {
        let source: JoyConAxisSource = paired
            ? .separatedPair(side: side)
            : .single(side: side, orientation: orientation)
        let normalized = JoyConAxisNormalizer.normalize(source: source, x: raw.x, y: raw.y)
        if paired && side == .right {
            return JoyConStickProjection(primary: .neutral, secondary: normalized)
        }
        return JoyConStickProjection(primary: normalized, secondary: .neutral)
    }

    static func combinedPair(
        primaryRaw: JoyConStick,
        secondaryRaw: JoyConStick
    ) -> JoyConStickProjection {
        JoyConStickProjection(
            primary: JoyConAxisNormalizer.normalize(
                source: .combinedPair,
                x: primaryRaw.x,
                y: primaryRaw.y
            ),
            secondary: JoyConAxisNormalizer.normalize(
                source: .combinedPair,
                x: secondaryRaw.x,
                y: secondaryRaw.y
            )
        )
    }
}

struct JoyConInputSnapshot: Equatable {
    var buttons: [ControllerInput: Bool]
    var primaryStick: JoyConStick
    var secondaryStick: JoyConStick

    static let neutral = JoyConInputSnapshot(
        buttons: [:],
        primaryStick: .neutral,
        secondaryStick: .neutral
    )

    func merging(_ other: JoyConInputSnapshot) -> JoyConInputSnapshot {
        JoyConInputSnapshot(
            buttons: buttons.merging(other.buttons) { _, right in right },
            primaryStick: primaryStick == .neutral ? other.primaryStick : primaryStick,
            secondaryStick: secondaryStick == .neutral ? other.secondaryStick : secondaryStick
        )
    }
}

struct JoyConControllerSnapshot: Equatable {
    let mode: JoyConMode
    let left: JoyConCapabilities?
    let right: JoyConCapabilities?
    let inactiveEndpointCount: Int

    var availableInputs: Set<ControllerInput> {
        ControllerInput.availableInputs(for: mode.controllerFamily)
    }
}

struct JoyConProfileSample {
    let snapshot: JoyConInputSnapshot
    let availableInputs: Set<ControllerInput>
}

enum JoyConSingleShoulderAdapter {
    private static let physicalInputs: Set<ControllerInput> = [
        .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
    ]
    private static let derivedInputs: Set<ControllerInput> = [
        .functionLeftShoulder, .functionRightShoulder, .functionRightTrigger,
    ]

    static func buttons(
        side: JoyConSide,
        orientation: JoyConOrientation,
        snapshot: JoyConHIDShoulderSnapshot
    ) -> [ControllerInput: Bool] {
        var projected: [ControllerInput: Bool] = switch (side, orientation) {
        case (_, .horizontal):
            [
                .leftShoulder: snapshot.sl,
                .rightShoulder: snapshot.sr,
            ]
        case (.left, .vertical):
            [
                .leftShoulder: snapshot.outerShoulder,
                .rightShoulder: snapshot.outerTrigger,
            ]
        case (.right, .vertical):
            [
                .leftShoulder: snapshot.outerTrigger,
                .rightShoulder: snapshot.outerShoulder,
            ]
        }
        if side == .left {
            if snapshot.capture {
                projected[.options] = true
            }
            if snapshot.minus {
                projected[.menu] = true
            }
            if snapshot.left {
                projected[.buttonA] = true
            }
            if snapshot.down {
                projected[.buttonB] = true
            }
            if snapshot.up {
                projected[.buttonX] = true
            }
            if snapshot.right {
                projected[.buttonY] = true
            }
        } else {
            if snapshot.home {
                projected[.options] = true
            }
            if snapshot.plus {
                projected[.menu] = true
            }
            if snapshot.right {
                projected[.buttonA] = true
            }
            if snapshot.down {
                projected[.buttonB] = true
            }
            if snapshot.up {
                projected[.buttonX] = true
            }
            if snapshot.left {
                projected[.buttonY] = true
            }
        }
        return projected
    }

    static func apply(
        _ hidSnapshot: JoyConHIDShoulderSnapshot,
        to sample: JoyConProfileSample,
        side: JoyConSide,
        orientation: JoyConOrientation
    ) -> JoyConProfileSample {
        let projectedButtons = buttons(
            side: side,
            orientation: orientation,
            snapshot: hidSnapshot
        )
        return replacingShoulders(in: sample, with: projectedButtons)
    }

    static func suppressAmbiguousShoulders(in sample: JoyConProfileSample) -> JoyConProfileSample {
        replacingShoulders(in: sample, with: [:])
    }

    private static func replacingShoulders(
        in sample: JoyConProfileSample,
        with projectedButtons: [ControllerInput: Bool]
    ) -> JoyConProfileSample {
        var buttonStates = sample.snapshot.buttons
        for input in physicalInputs { buttonStates.removeValue(forKey: input) }
        buttonStates.merge(projectedButtons) { _, projected in projected }

        var availableInputs = sample.availableInputs
        availableInputs.subtract(physicalInputs)
        availableInputs.subtract(derivedInputs)
        availableInputs.formUnion(projectedButtons.keys)
        return JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: buttonStates,
                primaryStick: sample.snapshot.primaryStick,
                secondaryStick: sample.snapshot.secondaryStick
            ),
            availableInputs: availableInputs
        )
    }
}

enum JoyConPairedShoulderAdapter {
    static func apply(
        _ hidSnapshot: JoyConHIDShoulderSnapshot,
        to sample: JoyConProfileSample,
        side: JoyConSide
    ) -> JoyConProfileSample {
        var projectedButtons: [ControllerInput: Bool] = switch side {
        case .left:
            [
                .leftShoulder: hidSnapshot.outerShoulder,
                .leftTrigger: hidSnapshot.outerTrigger,
            ]
        case .right:
            [
                .rightShoulder: hidSnapshot.outerShoulder,
                .rightTrigger: hidSnapshot.outerTrigger,
            ]
        }
        if side == .left {
            if hidSnapshot.minus { projectedButtons[.options] = true }
            if hidSnapshot.up { projectedButtons[.dpadUp] = true }
            if hidSnapshot.down { projectedButtons[.dpadDown] = true }
            if hidSnapshot.left { projectedButtons[.dpadLeft] = true }
            if hidSnapshot.right { projectedButtons[.dpadRight] = true }
        } else {
            if hidSnapshot.home { projectedButtons[.home] = true }
            if hidSnapshot.plus { projectedButtons[.menu] = true }
            if hidSnapshot.up { projectedButtons[.buttonX] = true }
            if hidSnapshot.down { projectedButtons[.buttonB] = true }
            if hidSnapshot.left { projectedButtons[.buttonY] = true }
            if hidSnapshot.right { projectedButtons[.buttonA] = true }
        }
        return replacingShoulders(in: sample, side: side, with: projectedButtons)
    }

    static func suppressAmbiguousShoulders(
        in sample: JoyConProfileSample,
        side: JoyConSide
    ) -> JoyConProfileSample {
        replacingShoulders(in: sample, side: side, with: [:])
    }

    private static func replacingShoulders(
        in sample: JoyConProfileSample,
        side: JoyConSide,
        with projectedButtons: [ControllerInput: Bool]
    ) -> JoyConProfileSample {
        let physicalInputs: Set<ControllerInput> = switch side {
        case .left: [.leftShoulder, .leftTrigger]
        case .right: [.rightShoulder, .rightTrigger]
        }
        var buttonStates = sample.snapshot.buttons
        for input in physicalInputs { buttonStates.removeValue(forKey: input) }
        buttonStates.merge(projectedButtons) { _, projected in projected }

        var availableInputs = sample.availableInputs
        availableInputs.subtract(physicalInputs)
        availableInputs.formUnion(projectedButtons.keys)
        if side == .left, !projectedButtons.keys.contains(.leftTrigger) {
            availableInputs = availableInputs.filter { $0.group != .functionLayer }
        }
        return JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: buttonStates,
                primaryStick: sample.snapshot.primaryStick,
                secondaryStick: sample.snapshot.secondaryStick
            ),
            availableInputs: availableInputs
        )
    }
}

enum JoyConProfileLayout {
    static func stickElementName(in names: [String]) -> String? {
        let normalized = names.map(normalize)
        let aliases = ["leftthumbstick", "rightthumbstick", "thumbstick", "stick"]
        if let exact = aliases.first(where: normalized.contains) { return exact }
        if let partial = aliases.first(where: { alias in
            normalized.contains(where: { $0.contains(alias) })
        }) {
            return normalized.first(where: { $0.contains(partial) })
        }
        if normalized.count == 1, let only = normalized.first,
           only.contains("directionpad") || only.contains("dpad") {
            return only
        }
        return normalized.first(where: { !$0.contains("directionpad") && !$0.contains("dpad") })
    }

    static func normalize(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }

    static func singleInput(side: JoyConSide, appleButtonName: String) -> ControllerInput? {
        switch (side, normalize(appleButtonName)) {
        case (.left, "buttonx"): .buttonA
        case (.left, "buttony"): .buttonB
        case (.left, "buttona"): .buttonX
        case (.left, "buttonb"): .buttonY
        case (.right, "buttona"): .buttonA
        case (.right, "buttonb"): .buttonB
        case (.right, "buttonx"): .buttonX
        case (.right, "buttony"): .buttonY
        default: nil
        }
    }

    static func pairedInput(side: JoyConSide, appleButtonName: String) -> ControllerInput? {
        // Apple exposes each side in its horizontal position layout. Pair mode rotates those
        // positions back to the printed vertical Nintendo layout before merging both profiles.
        switch (side, normalize(appleButtonName)) {
        case (.left, "buttonx"): .dpadLeft
        case (.left, "buttony"): .dpadDown
        case (.left, "buttona"): .dpadUp
        case (.left, "buttonb"): .dpadRight
        case (.right, "buttona"): .buttonB
        case (.right, "buttonb"): .buttonY
        case (.right, "buttonx"): .buttonA
        case (.right, "buttony"): .buttonX
        default: nil
        }
    }

    static func pairedShoulderInput(
        side: JoyConSide,
        appleButtonName: String
    ) -> ControllerInput? {
        switch (side, normalize(appleButtonName)) {
        case (.left, "leftshoulder"), (.left, "buttonl"), (.left, "l"):
            .leftShoulder
        case (.left, "rightshoulder"), (.left, "lefttrigger"),
             (.left, "buttonzl"), (.left, "zl"):
            .leftTrigger
        case (.right, "rightshoulder"), (.right, "buttonr"), (.right, "r"):
            .rightShoulder
        case (.right, "leftshoulder"), (.right, "righttrigger"),
             (.right, "buttonzr"), (.right, "zr"):
            .rightTrigger
        default:
            nil
        }
    }
}

enum JoyConInputCallbackSource: Hashable {
    case physicalProfile
    case microGamepad
    case extendedGamepad
}

enum JoyConInputMonitoringPolicy {
    static func sources(
        kind: JoyConHardwareKind,
        hasMicroGamepad: Bool,
        hasExtendedGamepad: Bool
    ) -> Set<JoyConInputCallbackSource> {
        var result: Set<JoyConInputCallbackSource> = [.physicalProfile]
        if kind != .pair, hasMicroGamepad { result.insert(.microGamepad) }
        if hasExtendedGamepad { result.insert(.extendedGamepad) }
        return result
    }
}

enum JoyConProfileReader {
    static func sample(
        controller: GCController,
        kind: JoyConHardwareKind,
        paired: Bool,
        orientation: JoyConOrientation = .horizontal
    ) -> JoyConProfileSample {
        if kind == .pair, let gamepad = controller.extendedGamepad {
            return completePair(gamepad)
        }
        guard kind != .pair else {
            return JoyConProfileSample(snapshot: .neutral, availableInputs: [])
        }
        return side(
            controller.physicalInputProfile,
            kind: kind,
            paired: paired,
            orientation: orientation
        )
    }

    private static func completePair(_ gamepad: GCExtendedGamepad) -> JoyConProfileSample {
        var buttons: [ControllerInput: Bool] = [
            .buttonA: gamepad.buttonA.isPressed,
            .buttonB: gamepad.buttonB.isPressed,
            .buttonX: gamepad.buttonX.isPressed,
            .buttonY: gamepad.buttonY.isPressed,
            .leftShoulder: gamepad.leftShoulder.isPressed,
            .rightShoulder: gamepad.rightShoulder.isPressed,
            .leftTrigger: gamepad.leftTrigger.isPressed,
            .rightTrigger: gamepad.rightTrigger.isPressed,
            .menu: gamepad.buttonMenu.isPressed,
            .dpadUp: gamepad.dpad.up.isPressed,
            .dpadLeft: gamepad.dpad.left.isPressed,
            .dpadDown: gamepad.dpad.down.isPressed,
            .dpadRight: gamepad.dpad.right.isPressed,
        ]
        if let input = gamepad.buttonOptions { buttons[.options] = input.isPressed }
        if let input = gamepad.buttonHome { buttons[.home] = input.isPressed }
        if let input = gamepad.leftThumbstickButton { buttons[.leftThumbstickButton] = input.isPressed }
        if let input = gamepad.rightThumbstickButton { buttons[.rightThumbstickButton] = input.isPressed }
        let sticks = JoyConStickProjector.combinedPair(
            primaryRaw: JoyConStick(
                x: gamepad.leftThumbstick.xAxis.value,
                y: gamepad.leftThumbstick.yAxis.value
            ),
            secondaryRaw: JoyConStick(
                x: gamepad.rightThumbstick.xAxis.value,
                y: gamepad.rightThumbstick.yAxis.value
            )
        )
        return JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: buttons,
                primaryStick: sticks.primary,
                secondaryStick: sticks.secondary
            ),
            availableInputs: expandedAvailableInputs(from: Set(buttons.keys), hasSecondaryStick: true)
        )
    }

    private static func side(
        _ profile: GCPhysicalInputProfile,
        kind: JoyConHardwareKind,
        paired: Bool,
        orientation: JoyConOrientation
    ) -> JoyConProfileSample {
        let side: JoyConSide = kind == .left ? .left : .right
        let lookup = ProfileLookup(profile: profile)
        let stick = lookup.stick
        let rawStick = JoyConStick(x: stick?.xAxis.value ?? 0, y: stick?.yAxis.value ?? 0)
        let sticks = JoyConStickProjector.sideProfile(
            side: side,
            paired: paired,
            orientation: orientation,
            raw: rawStick
        )
        var buttons: [ControllerInput: Bool] = [:]

        if paired {
            if side == .left {
                for appleName in ["buttona", "buttonb", "buttonx", "buttony"] {
                    if let input = JoyConProfileLayout.pairedInput(
                        side: side,
                        appleButtonName: appleName
                    ) {
                        assign(lookup.button(appleName), to: input, in: &buttons)
                    }
                }
                assignPairedShoulder(
                    lookup.button("leftshoulder", "buttonl", "l"),
                    side: side,
                    appleButtonName: "leftshoulder",
                    in: &buttons
                )
                assignPairedShoulder(
                    lookup.button("rightshoulder", "lefttrigger", "buttonzl", "zl"),
                    side: side,
                    appleButtonName: "rightshoulder",
                    in: &buttons
                )
                assign(lookup.button("buttonmenu", "buttonoptions", "buttonminus", "minus"), to: .options, in: &buttons)
                assign(lookup.stickButton, to: .leftThumbstickButton, in: &buttons)
            } else {
                for appleName in ["buttona", "buttonb", "buttonx", "buttony"] {
                    if let input = JoyConProfileLayout.pairedInput(
                        side: side,
                        appleButtonName: appleName
                    ) {
                        assign(lookup.button(appleName), to: input, in: &buttons)
                    }
                }
                assignPairedShoulder(
                    lookup.button("rightshoulder", "buttonr", "r"),
                    side: side,
                    appleButtonName: "rightshoulder",
                    in: &buttons
                )
                assignPairedShoulder(
                    lookup.button("leftshoulder", "righttrigger", "buttonzr", "zr"),
                    side: side,
                    appleButtonName: "leftshoulder",
                    in: &buttons
                )
                assign(lookup.button("buttonmenu", "buttonplus", "plus"), to: .menu, in: &buttons)
                assign(lookup.button("buttonhome", "home"), to: .home, in: &buttons)
                assign(lookup.stickButton, to: .rightThumbstickButton, in: &buttons)
            }
        } else {
            for appleName in ["buttona", "buttonb", "buttonx", "buttony"] {
                if let input = JoyConProfileLayout.singleInput(
                    side: side,
                    appleButtonName: appleName
                ) {
                    assign(lookup.button(appleName), to: input, in: &buttons)
                }
            }
            assign(lookup.button("leftshoulder", "buttonsl", "sl"), to: .leftShoulder, in: &buttons)
            assign(lookup.button("rightshoulder", "buttonsr", "sr"), to: .rightShoulder, in: &buttons)
            if side == .left {
                assign(lookup.button("buttonmenu", "buttonoptions", "buttonminus", "minus"), to: .menu, in: &buttons)
                assign(lookup.button("buttonhome", "buttonshare", "capture"), to: .options, in: &buttons)
                if buttons[.options] == nil {
                    buttons[.options] = false
                }
            } else {
                assign(lookup.button("buttonmenu", "buttonplus", "plus"), to: .menu, in: &buttons)
                assign(lookup.button("buttonhome", "home"), to: .options, in: &buttons)
                if buttons[.options] == nil {
                    buttons[.options] = false
                }
            }
            assign(lookup.stickButton, to: .leftThumbstickButton, in: &buttons)
        }

        return JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: buttons,
                primaryStick: sticks.primary,
                secondaryStick: sticks.secondary
            ),
            availableInputs: expandedAvailableInputs(from: Set(buttons.keys), hasSecondaryStick: paired)
        )
    }

    private static func assign(
        _ button: GCControllerButtonInput?,
        to input: ControllerInput,
        in buttons: inout [ControllerInput: Bool]
    ) {
        guard let button else { return }
        buttons[input] = button.isPressed
    }

    private static func assignPairedShoulder(
        _ button: GCControllerButtonInput?,
        side: JoyConSide,
        appleButtonName: String,
        in buttons: inout [ControllerInput: Bool]
    ) {
        guard let input = JoyConProfileLayout.pairedShoulderInput(
            side: side,
            appleButtonName: appleButtonName
        ) else { return }
        assign(button, to: input, in: &buttons)
    }

    static func expandedAvailableInputs(
        from buttons: Set<ControllerInput>,
        hasSecondaryStick: Bool
    ) -> Set<ControllerInput> {
        var result = buttons
        if buttons.contains(.leftTrigger) {
            let variants: [(ControllerInput, ControllerInput)] = [
                (.buttonA, .functionButtonA), (.buttonB, .functionButtonB),
                (.buttonX, .functionButtonX), (.buttonY, .functionButtonY),
                (.leftShoulder, .functionLeftShoulder), (.rightShoulder, .functionRightShoulder),
                (.rightTrigger, .functionRightTrigger),
                (.leftThumbstickButton, .functionLeftThumbstickButton),
                (.rightThumbstickButton, .functionRightThumbstickButton),
                (.dpadUp, .functionDpadUp), (.dpadLeft, .functionDpadLeft),
                (.dpadDown, .functionDpadDown), (.dpadRight, .functionDpadRight),
            ]
            for (base, modified) in variants where buttons.contains(base) { result.insert(modified) }
            if hasSecondaryStick {
                result.formUnion([
                    .functionRightStickUp, .functionRightStickLeft,
                    .functionRightStickDown, .functionRightStickRight,
                ])
            }
        }
        return result
    }

    private struct ProfileLookup {
        let buttons: [(String, GCControllerButtonInput)]
        let dpads: [(String, GCControllerDirectionPad)]

        init(profile: GCPhysicalInputProfile) {
            buttons = profile.buttons.map { (Self.normalized($0.key), $0.value) }
            dpads = profile.dpads.map { (Self.normalized($0.key), $0.value) }
        }

        var directionPad: GCControllerDirectionPad? {
            dpad("directionpad", "dpad")
        }

        var stick: GCControllerDirectionPad? {
            guard let name = JoyConProfileLayout.stickElementName(in: dpads.map(\.0)) else { return nil }
            return dpads.first(where: { $0.0 == name })?.1
        }

        var stickButton: GCControllerButtonInput? {
            button("leftthumbstickbutton", "rightthumbstickbutton", "stickbutton", "buttonstick")
        }

        func button(_ aliases: String...) -> GCControllerButtonInput? {
            value(in: buttons, aliases: aliases)
        }

        func dpad(_ aliases: String...) -> GCControllerDirectionPad? {
            value(in: dpads, aliases: aliases)
        }

        private func value<T>(in values: [(String, T)], aliases: [String]) -> T? {
            let normalizedAliases = aliases.map(Self.normalized)
            for alias in normalizedAliases {
                if let exact = values.first(where: { $0.0 == alias }) { return exact.1 }
            }
            for alias in normalizedAliases where alias.count > 2 {
                if let partial = values.first(where: { $0.0.contains(alias) }) { return partial.1 }
            }
            return nil
        }

        private static func normalized(_ value: String) -> String {
            JoyConProfileLayout.normalize(value)
        }
    }
}

extension GCController {
    var joyConHardwareKind: JoyConHardwareKind? {
        JoyConHardwareKind.detect(vendorName: vendorName, productCategory: productCategory)
    }

    var joyConEndpointID: String {
        let identity = "\(vendorName ?? "Controller")|\(productCategory)"
        return "\(identity)|\(ObjectIdentifier(self).hashValue)"
    }

    var joyConCapabilities: JoyConCapabilities {
        JoyConCapabilities(
            hasBattery: battery != nil,
            hasHaptics: haptics != nil,
            hasMotion: motion != nil,
            profileElements: physicalInputProfile.elements.keys.sorted()
        )
    }
}
