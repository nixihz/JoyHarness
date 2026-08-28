import CoreAudio
import CoreGraphics
import Foundation
import Testing
@testable import JoyHarness

struct JoyHarnessTests {
    @Test
    func appVersionLoadsFromTheBundledVersionResource() {
        #expect(AppVersion.current == "0.4.0")
        #expect(AppVersion.displayName == "Joy Harness v0.4.0")
    }

    @Test
    func appVersionDoesNotLoadFallbackWhenMainBundleHasVersion() throws {
        let versionFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "0.2.0\n".write(to: versionFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: versionFile) }
        var didLoadFallback = false

        let version = AppVersion.load(primaryURL: versionFile) {
            didLoadFallback = true
            return nil
        }

        #expect(version == "0.2.0")
        #expect(!didLoadFallback)
    }

    @Test
    func rightCommandEventDescriptorKeepsItsDeviceSide() {
        let descriptor = SystemKey.rightCommand.eventDescriptor(pressed: true)

        #expect(descriptor.keyCode == 0x36)
        #expect(descriptor.flags.contains(.maskCommand))
        #expect(descriptor.flags.rawValue & 0x10 != 0)
        #expect(descriptor.flags.rawValue & 0x08 == 0)
        #expect(SystemKey.rightCommand.eventDescriptor(pressed: false).flags.isEmpty)
    }

    @Test
    func clipboardAndScreenshotDescriptorsUseMacShortcuts() {
        let copy = SystemKey.copy.eventDescriptor(pressed: true)
        let paste = SystemKey.paste.eventDescriptor(pressed: true)
        let screenshot = SystemKey.screenshotTool.eventDescriptor(pressed: true)

        #expect(copy.keyCode == 0x08)
        #expect(copy.flags == .maskCommand)
        #expect(paste.keyCode == 0x09)
        #expect(paste.flags == .maskCommand)
        #expect(screenshot.keyCode == 0x00)
        #expect(screenshot.flags.contains(.maskCommand))
        #expect(screenshot.flags.contains(.maskShift))
    }

    @Test
    func enterDescriptorUsesTheUnmodifiedReturnKey() {
        let enter = SystemKey.enter.eventDescriptor(pressed: true)

        #expect(enter.keyCode == 0x24)
        #expect(enter.flags.isEmpty)
    }

    @Test
    func languagePreferenceFollowsChineseSystemsAndDefaultsToEnglishOtherwise() {
        #expect(
            AppLanguagePreference.system.resolved(preferredLanguages: ["zh-Hans-CN"]) ==
                .simplifiedChinese
        )
        #expect(
            AppLanguagePreference.system.resolved(preferredLanguages: ["zh-Hant-TW"]) ==
                .simplifiedChinese
        )
        #expect(
            AppLanguagePreference.system.resolved(preferredLanguages: ["en-US"]) == .english
        )
        #expect(
            AppLanguagePreference.system.resolved(preferredLanguages: ["fr-FR"]) == .english
        )
    }

    @Test
    func explicitLanguagePreferencePersists() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppLanguageSettings(userDefaults: defaults, updatesLocalizer: false)
        #expect(settings.preference == .system)

        settings.preference = .simplifiedChinese

        let reloaded = AppLanguageSettings(userDefaults: defaults, updatesLocalizer: false)
        #expect(reloaded.preference == .simplifiedChinese)
        #expect(reloaded.locale.identifier == "zh-Hans")

        settings.preference = .english
        #expect(settings.preference.resolved() == .english)
        #expect(L10n.text("中文", "English", language: .english) == "English")
    }

    @Test
    func settingsTitleDoesNotUseAnEllipsis() {
        #expect(L10n.settingsTitle(language: .simplifiedChinese) == "设置")
        #expect(L10n.settingsTitle(language: .english) == "Settings")
    }

    @Test
    func singleInstanceLockRejectsASecondOwner() throws {
        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoyHarnessTests.\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockPath) }

        let first = try #require(SingleInstanceLock(path: lockPath.path))
        #expect(SingleInstanceLock(path: lockPath.path) == nil)
        _ = first
    }

    @Test
    func rp2040HandshakeAcceptsCurrentAndLegacyFirmware() {
        #expect(RP2040Bridge.isReadyLine("READY agentdeck-rp2040 0.1.0"))
        #expect(RP2040Bridge.isReadyLine("READY agentdeck-rp2040"))
        #expect(RP2040Bridge.isReadyLine("READY codexpad-rp2040 0.1.0"))
        #expect(RP2040Bridge.isReadyLine("READY codexpad-rp2040"))
        #expect(!RP2040Bridge.isReadyLine("READY other-device 0.1.0"))
        #expect(!RP2040Bridge.isReadyLine("agentdeck-rp2040"))
    }

    @Test
    func stateParsingIsCaseAndWhitespaceInsensitive() {
        #expect(PadState.parse(" Waiting\n") == .waiting)
        #expect(PadState.parse("unknown") == nil)
    }

    @Test
    func dashboardStatusDecodesSixPhysicalMicroSlots() throws {
        let slots = (1...6).map { slot in
            """
            {"slot":\(slot),"selected":\(slot == 3),"thread_id":"","title":"","state":"idle"}
            """
        }.joined(separator: ",")
        let json = """
        {
          "state":"waiting",
          "selected_slot":3,
          "slots":[\(slots)],
          "controller":"Xbox Wireless Controller",
          "controller_battery_level":0.73,
          "controller_battery_state":"discharging",
          "haptics":true,
          "accessibility":false,
          "input_monitoring":false,
          "microphone":false,
          "rp2040":true,
          "mode":"physical-codex-micro",
          "note":"PermissionRequest",
          "ts":"2026-08-23T03:47:42Z"
        }
        """

        let status = try JSONDecoder().decode(DashboardStatus.self, from: Data(json.utf8))
        #expect(status.slots.count == 6)
        #expect(status.selectedSlot == 3)
        #expect(status.selected?.displayTitle == L10n.text("Micro 槽位", "Micro Slot"))
        #expect(status.padState == .waiting)
        #expect(status.rp2040)
        #expect(status.controllerBatteryLevel == 0.73)
        #expect(status.controllerBatteryState == "discharging")
        #expect(status.inputMonitoring == false)
    }

    @Test
    func dashboardStatusDecodesJoyConHIDMotionTelemetry() throws {
        let json = """
        {
          "state":"idle",
          "selected_slot":1,
          "slots":[],
          "controller":"Joy-Con (L)",
          "joycon_mode":"left",
          "joycon_orientation":"vertical",
          "joycon_primary_stick":{"x":0.0,"y":1.0},
          "joycon_secondary_stick":{"x":0.0,"y":0.0},
          "joycon_left_motion":true,
          "joycon_left_imu":{
            "acceleration_g":{"x":0.25,"y":-0.5,"z":1.0},
            "rotation_rate_dps":{"x":12.5,"y":-8.0,"z":0.75},
            "calibration_source":"factory"
          },
          "haptics":true,
          "accessibility":true,
          "microphone":false,
          "rp2040":false,
          "mode":"physical-codex-micro",
          "note":"joycon-motion",
          "ts":"2026-08-28T00:00:00Z"
        }
        """

        let status = try JSONDecoder().decode(DashboardStatus.self, from: Data(json.utf8))

        #expect(status.joyConLeftMotion == true)
        #expect(status.joyConMode == "left")
        #expect(status.joyConOrientation == .vertical)
        #expect(status.joyConPrimaryStick == JoyConStick(x: 0, y: 1))
        #expect(status.joyConSecondaryStick == .neutral)
        #expect(status.joyConLeftIMU?.accelerationG == JoyConVector3(x: 0.25, y: -0.5, z: 1))
        #expect(status.joyConLeftIMU?.rotationRateDPS == JoyConVector3(x: 12.5, y: -8, z: 0.75))
        #expect(status.joyConLeftIMU?.calibrationSource == .factory)
    }

    @Test
    func controllerBatterySnapshotClampsAndRoundsLevel() {
        #expect(ControllerBatterySnapshot(level: 0.734, state: .discharging).percentage == 73)
        #expect(ControllerBatterySnapshot(level: 1.2, state: .full).percentage == 100)
        #expect(ControllerBatterySnapshot(level: -0.1, state: .unknown).percentage == 0)
    }

    @Test
    func codexThreadListProvidesTaskNamesAndFallbackPreviews() throws {
        let response = """
        {"id":2,"result":{"data":[
          {"id":"thread-1","name":"修复任务槽位状态和名称","preview":"ignored","status":{"type":"active","activeFlags":[]}},
          {"id":"thread-2","name":null,"preview":"Fallback title\\nsecond line","status":{"type":"idle"}}
        ]}}
        """

        let threads = try #require(CodexThreadProvider.decodeThreads(from: Data(response.utf8)))
        #expect(threads.count == 2)
        #expect(threads[0] == CodexThreadSummary(
            id: "thread-1",
            title: "修复任务槽位状态和名称",
            status: "active"
        ))
        #expect(threads[1].title == "Fallback title")
    }

    @Test
    func padCommandDecodesTheOriginatingThread() throws {
        let data = Data(#"{"state":"waiting","thread_id":"thread-123"}"#.utf8)
        let command = try JSONDecoder().decode(PadCommand.self, from: data)
        #expect(command.state == "waiting")
        #expect(command.threadID == "thread-123")
    }

    @Test
    func visualSlotSelectionUsesTheNativeMicroAgentKey() {
        let bridge = ButtonBridge()
        var sent: [(String, Int)] = []
        bridge.keyHandler = { key, action in
            sent.append((key, action))
            return true
        }

        bridge.selectSlot(4)

        #expect(bridge.selectedSlot == 4)
        #expect(sent.first?.0 == "AG04")
        #expect(sent.first?.1 == 1)
    }

    @Test
    func slotSynchronizationDoesNotSendAnotherMicroKey() {
        let bridge = ButtonBridge()
        var sent = false
        bridge.keyHandler = { _, _ in
            sent = true
            return true
        }

        bridge.syncSelectedSlot(3)

        #expect(bridge.selectedSlot == 3)
        #expect(!sent)
    }

    @Test
    func faceButtonsControlMouseAndKeyboardByDefault() {
        #expect(ButtonBridge.faceAction(for: .a, functionPressed: false) == .mouseButton(.left))
        #expect(ButtonBridge.faceAction(for: .b, functionPressed: false) == .mouseButton(.right))
        #expect(ButtonBridge.faceAction(for: .x, functionPressed: false) == .systemKey(.backspace))
        #expect(ButtonBridge.faceAction(for: .y, functionPressed: false) == .systemKey(.escape))
    }

    @Test
    func functionModifierProvidesApprovalAndYesNoActions() {
        #expect(ButtonBridge.faceAction(for: .a, functionPressed: true) == .microKey("ACT07"))
        #expect(ButtonBridge.faceAction(for: .b, functionPressed: true) == .microKey("ACT08"))
        #expect(ButtonBridge.faceAction(for: .x, functionPressed: true) == .textInput("no"))
        #expect(ButtonBridge.faceAction(for: .y, functionPressed: true) == .textInput("yes"))
    }

    @Test
    func functionModifiedDPadSelectsSlotsCounterclockwise() {
        #expect(ButtonBridge.slot(for: .up) == 0)
        #expect(ButtonBridge.slot(for: .left) == 1)
        #expect(ButtonBridge.slot(for: .down) == 2)
        #expect(ButtonBridge.slot(for: .right) == 3)
    }

    @Test
    func joyConInputPublishesPressAndReleaseEvenWhenTheActionIsDisabled() {
        let bridge = ButtonBridge { _ in .disabled }
        var changes: [(ControllerInput, Bool)] = []
        bridge.onInputStateChange = { changes.append(($0, $1)) }

        var pressed = JoyConInputSnapshot.neutral
        pressed.buttons[.buttonA] = true
        bridge.applyJoyConSnapshot(pressed)
        bridge.applyJoyConSnapshot(.neutral)

        #expect(changes.count == 2)
        #expect(changes[0].0 == .buttonA)
        #expect(changes[0].1)
        #expect(changes[1].0 == .buttonA)
        #expect(!changes[1].1)
    }

    @Test
    func joyConAxisTelemetryTracksThePublishedStickChannels() {
        let bridge = ButtonBridge { _ in .disabled }
        let expected = JoyConStickProjection(
            primary: JoyConStick(x: 0.25, y: 0.75),
            secondary: JoyConStick(x: -0.5, y: -1)
        )

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [:],
            primaryStick: expected.primary,
            secondaryStick: expected.secondary
        ))
        #expect(bridge.joyConSticks == expected)

        bridge.resetInputState()
        #expect(bridge.joyConSticks == JoyConStickProjection(
            primary: .neutral,
            secondary: .neutral
        ))
    }

    @Test
    func controllerArtworkLayoutsCoverCommonPhysicalButtons() {
        let xbox = ControllerInputHighlightModel.layout(for: .xbox)
        let playStation = ControllerInputHighlightModel.layout(for: .dualSense)

        for input in [
            ControllerInput.buttonA, .buttonB, .buttonX, .buttonY,
            .dpadUp, .dpadLeft, .dpadDown, .dpadRight,
            .leftTrigger, .rightTrigger, .leftShoulder, .rightShoulder,
        ] {
            #expect(xbox[input] != nil)
            #expect(playStation[input] != nil)
        }
        #expect(xbox[.touchpadButton] == nil)
        #expect(playStation[.touchpadButton] != nil)
    }

    @Test
    func defaultMappingsUseUnifiedFaceButtonLayout() {
        let store = ControllerMappingStore()
        #expect(store.action(for: .buttonA).controllerAction == .mouseButton(.left))
        #expect(store.action(for: .buttonB).controllerAction == .mouseButton(.right))
        #expect(store.action(for: .leftTrigger) == .functionModifier)
        #expect(store.action(for: .dpadUp).controllerAction == .systemKey(.rightCommand))
        #expect(store.action(for: .options).controllerAction == .systemKey(.screenshotTool))
        #expect(store.action(for: .functionButtonX).controllerAction == .textInput("no"))
        #expect(store.action(for: .functionButtonY).controllerAction == .textInput("yes"))
        #expect(store.action(for: .rightTrigger).controllerAction == .microKey("ACT12"))
        #expect(store.action(for: .functionRightTrigger).controllerAction == .systemKey(.enter))
        #expect(store.action(for: .functionLeftThumbstickButton).controllerAction == .systemKey(.copy))
        #expect(store.action(for: .functionRightThumbstickButton).controllerAction == .systemKey(.paste))
        #expect(store.action(for: .functionDpadUp).controllerAction == .selectSlot(0))
        #expect(store.action(for: .functionDpadLeft).controllerAction == .selectSlot(1))
        #expect(store.action(for: .functionDpadDown).controllerAction == .selectSlot(2))
        #expect(store.action(for: .functionDpadRight).controllerAction == .selectSlot(3))
        #expect(store.action(for: .functionRightStickUp) == .disabled)
        #expect(store.action(for: .functionRightStickLeft) == .browserBack)
        #expect(store.action(for: .functionRightStickDown) == .disabled)
        #expect(store.action(for: .functionRightStickRight) == .browserForward)
        #expect(store.action(for: .leftThumbstickButton) == .mouseSpeedBoost)
    }

    @Test
    func leftThumbstickPrecisionDefaultMigratesBackToBoost() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            [ControllerInput.leftThumbstickButton.rawValue: ControllerMappedAction.mousePrecision.rawValue],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)
        #expect(store.action(for: .leftThumbstickButton) == .mouseSpeedBoost)
    }

    @Test
    func playStationDefaultsMatchXboxFaceButtonPositions() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)

        store.setControllerFamily(.dualSense)

        #expect(store.action(for: .functionButtonY).controllerAction == .textInput("yes"))
        #expect(store.action(for: .functionButtonB).controllerAction == .microKey("ACT08"))
        #expect(store.action(for: .functionButtonX).controllerAction == .textInput("no"))
        #expect(store.action(for: .functionLeftThumbstickButton).controllerAction == .systemKey(.copy))
        #expect(store.action(for: .functionRightThumbstickButton).controllerAction == .systemKey(.paste))
    }

    @Test
    func yesNoMigrationPreservesUnrelatedCustomMappings() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                ControllerInput.buttonA.rawValue: ControllerMappedAction.mouseMiddle.rawValue,
                ControllerInput.functionButtonA.rawValue: ControllerMappedAction.approve.rawValue,
                ControllerInput.functionButtonB.rawValue: ControllerMappedAction.deny.rawValue,
                ControllerInput.functionButtonX.rawValue: ControllerMappedAction.toggleFastMode.rawValue,
                ControllerInput.functionButtonY.rawValue: ControllerMappedAction.splitThread.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .buttonA) == .mouseMiddle)
        #expect(store.action(for: .functionButtonX) == .answerNo)
        #expect(store.action(for: .functionButtonY) == .answerYes)
        #expect(store.action(for: .options) == .screenshotTool)
    }

    @Test
    func unifiedLayoutMigrationUpdatesOldPlayStationDefaults() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(ControllerFamily.dualSense.rawValue, forKey: "controllerMappings.v1.controllerFamily")
        defaults.set(true, forKey: "controllerMappings.v1.yesNoFaceButtonsMigrated")
        defaults.set(
            [
                ControllerInput.functionButtonA.rawValue: ControllerMappedAction.approve.rawValue,
                ControllerInput.functionButtonB.rawValue: ControllerMappedAction.answerNo.rawValue,
                ControllerInput.functionButtonX.rawValue: ControllerMappedAction.deny.rawValue,
                ControllerInput.functionButtonY.rawValue: ControllerMappedAction.answerYes.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .functionButtonA) == .approve)
        #expect(store.action(for: .functionButtonB) == .deny)
        #expect(store.action(for: .functionButtonX) == .answerNo)
        #expect(store.action(for: .functionButtonY) == .answerYes)
    }

    @Test
    func clipboardMigrationPreservesCustomizedFunctionButtons() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "controllerMappings.v1.yesNoFaceButtonsMigrated")
        defaults.set(true, forKey: "controllerMappings.v1.unifiedFaceButtonLayoutMigrated")
        defaults.set(
            [
                ControllerInput.options.rawValue: ControllerMappedAction.disabled.rawValue,
                ControllerInput.functionButtonX.rawValue: ControllerMappedAction.answerNo.rawValue,
                ControllerInput.functionButtonY.rawValue: ControllerMappedAction.mouseMiddle.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .options) == .screenshotTool)
        #expect(store.action(for: .functionButtonX) == .answerNo)
        #expect(store.action(for: .functionButtonY) == .mouseMiddle)
    }

    @Test
    func clipboardMigrationMovesTemporaryFaceButtonDefaultsToThumbsticks() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "controllerMappings.v1.yesNoFaceButtonsMigrated")
        defaults.set(true, forKey: "controllerMappings.v1.unifiedFaceButtonLayoutMigrated")
        defaults.set(true, forKey: "controllerMappings.v1.clipboardAndScreenshotDefaultsMigrated")
        defaults.set(
            [
                ControllerInput.functionButtonX.rawValue: ControllerMappedAction.copy.rawValue,
                ControllerInput.functionButtonY.rawValue: ControllerMappedAction.paste.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .functionButtonX) == .answerNo)
        #expect(store.action(for: .functionButtonY) == .answerYes)
        #expect(store.action(for: .functionLeftThumbstickButton) == .copy)
        #expect(store.action(for: .functionRightThumbstickButton) == .paste)
    }

    @Test
    func customMappingPersistsAndCanBeReset() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.toggleFastMode, for: .buttonA)

        let reloaded = ControllerMappingStore(userDefaults: defaults)
        #expect(reloaded.action(for: .buttonA) == .toggleFastMode)
        reloaded.resetDefaults()
        #expect(reloaded.action(for: .buttonA) == .mouseLeft)
    }

    @Test
    func rightCommandIsAvailableForCustomMappings() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.rightCommand, for: .buttonA)

        #expect(store.action(for: .buttonA).controllerAction == .systemKey(.rightCommand))
        #expect(ControllerInput.buttonA.availableActions.contains(.rightCommand))
    }

    @Test
    func oldDefaultDPadUpMappingMigratesToRightCommand() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ControllerInput.dpadUp.rawValue: ControllerMappedAction.radialInput.rawValue],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .dpadUp) == .rightCommand)
    }

    @Test
    func dPadUpMigrationPreservesCustomMappings() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ControllerInput.dpadUp.rawValue: ControllerMappedAction.escape.rawValue],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .dpadUp) == .escape)
    }

    @Test
    func playStationLabelsAndTouchpadMappingAreAvailable() {
        #expect(ControllerInput.buttonA.displayName(for: .dualSense) == "×")
        #expect(ControllerInput.buttonB.displayName(for: .dualSense) == "○")
        #expect(ControllerInput.functionButtonX.displayName(for: .dualSense) == "L2 + □")
        #expect(ControllerInput.functionLeftThumbstickButton.displayName(for: .xbox) == "LT + L3")
        #expect(ControllerInput.functionRightThumbstickButton.displayName(for: .dualSense) == "L2 + R3")
        #expect(ControllerInput.functionRightTrigger.displayName(for: .xbox) == "LT + RT")
        #expect(ControllerInput.functionRightTrigger.displayName(for: .dualSense) == "L2 + R2")
        let previousLanguage = L10n.language
        L10n.language = .simplifiedChinese
        #expect(ControllerInput.functionRightStickUp.displayName(for: .dualSense) == "L2 + 右摇杆 上")
        #expect(ControllerInput.functionRightStickLeft.displayName(for: .xbox) == "LT + 右摇杆 左")
        L10n.language = previousLanguage
        #expect(ControllerMappingStore.defaultMappings[.touchpadButton] == .mouseLeft)
    }

    @Test
    func touchpadOldPushToTalkDefaultMigratesToMouseLeft() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ControllerInput.touchpadButton.rawValue: ControllerMappedAction.pushToTalk.rawValue],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .touchpadButton) == .mouseLeft)
    }

    @Test
    func touchpadDefaultMigrationPreservesCustomMapping() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [ControllerInput.touchpadButton.rawValue: ControllerMappedAction.screenshotTool.rawValue],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .touchpadButton) == .screenshotTool)
    }

    @Test
    func functionRightStickBrowserDefaultsMigrateFromDisabled() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                ControllerInput.functionRightStickLeft.rawValue: ControllerMappedAction.disabled.rawValue,
                ControllerInput.functionRightStickRight.rawValue: ControllerMappedAction.disabled.rawValue,
                ControllerInput.functionRightStickUp.rawValue: ControllerMappedAction.openApplication.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .functionRightStickLeft) == .browserBack)
        #expect(store.action(for: .functionRightStickRight) == .browserForward)
        #expect(store.action(for: .functionRightStickUp) == .openApplication)
    }

    @Test
    func functionRightStickBrowserMigrationPreservesCustomMappings() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                ControllerInput.functionRightStickLeft.rawValue: ControllerMappedAction.copy.rawValue,
                ControllerInput.functionRightStickRight.rawValue: ControllerMappedAction.disabled.rawValue,
            ],
            forKey: "controllerMappings.v1"
        )

        let store = ControllerMappingStore(userDefaults: defaults)

        #expect(store.action(for: .functionRightStickLeft) == .copy)
        #expect(store.action(for: .functionRightStickRight) == .browserForward)
    }

    @Test
    func browserNavigationAndOpenApplicationMappingsAreAvailable() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.browserBack, for: .functionRightStickLeft)
        store.setAction(.browserForward, for: .functionRightStickRight)
        store.setAction(.openApplication, for: .functionRightStickUp)
        store.setOpenApplicationTarget("com.apple.Safari", for: .functionRightStickUp)

        #expect(store.action(for: .functionRightStickLeft).controllerAction == .systemKey(.browserBack))
        #expect(store.action(for: .functionRightStickRight).controllerAction == .systemKey(.browserForward))
        #expect(store.action(for: .functionRightStickUp) == .openApplication)
        #expect(store.openApplicationTarget(for: .functionRightStickUp) == "com.apple.Safari")

        let reloaded = ControllerMappingStore(userDefaults: defaults)
        #expect(reloaded.action(for: .functionRightStickLeft) == .browserBack)
        #expect(reloaded.openApplicationTarget(for: .functionRightStickUp) == "com.apple.Safari")
        #expect(SystemKey.browserBack.eventDescriptor(pressed: true).keyCode == 0x21)
        #expect(SystemKey.browserForward.eventDescriptor(pressed: true).keyCode == 0x1E)
    }

    @Test
    func recordedShortcutPersistsKeyCombinationAndNote() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = RecordedKeyboardShortcut(
            keyCode: 0x2D,
            keyName: "N",
            modifiers: [.shift, .command]
        )

        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.recordedShortcut, for: .functionRightStickUp)
        store.setRecordedShortcut(shortcut, for: .functionRightStickUp)
        store.setRecordedShortcutNote("新建窗口", for: .functionRightStickUp)

        let reloaded = ControllerMappingStore(userDefaults: defaults)
        let configuration = reloaded.recordedShortcutConfiguration(for: .functionRightStickUp)
        #expect(reloaded.action(for: .functionRightStickUp) == .recordedShortcut)
        #expect(configuration.shortcut == shortcut)
        #expect(configuration.note == "新建窗口")
        #expect(configuration.shortcut?.displayName == "⇧⌘N")
        #expect(reloaded.mappedActionDisplayName(for: .functionRightStickUp) == "新建窗口")

        reloaded.setRecordedShortcutNote("", for: .functionRightStickUp)
        #expect(reloaded.mappedActionDisplayName(for: .functionRightStickUp) == "⇧⌘N")
    }

    @Test
    func recordedShortcutDescriptorContainsEveryModifier() {
        let shortcut = RecordedKeyboardShortcut(
            keyCode: 0x31,
            keyName: "Space",
            modifiers: [.function, .command, .shift, .option, .control]
        )

        let descriptor = shortcut.eventDescriptor

        #expect(descriptor.keyCode == 0x31)
        #expect(descriptor.flags.contains(.maskControl))
        #expect(descriptor.flags.contains(.maskAlternate))
        #expect(descriptor.flags.contains(.maskShift))
        #expect(descriptor.flags.contains(.maskCommand))
        #expect(descriptor.flags.contains(.maskSecondaryFn))
        #expect(shortcut.displayName == "⌃⌥⇧⌘fnSpace")
        #expect(shortcut.recorderDisplayName == "⌃ ⌥ ⇧ ⌘ fn Space")
        #expect(ControllerInput.buttonA.availableActions.contains(.recordedShortcut))
    }

    @Test
    func functionRightStickUsesDominantDirectionWithHysteresis() {
        #expect(ButtonBridge.dominantStickDirection(x: 0.8, y: 0.1) == .right)
        #expect(ButtonBridge.dominantStickDirection(x: -0.2, y: 0.9) == .up)
        #expect(ButtonBridge.dominantStickDirection(x: 0.2, y: -0.2) == nil)

        #expect(
            ButtonBridge.functionRightStickInput(x: 0.8, y: 0.1, current: nil)
                == .functionRightStickRight
        )
        #expect(
            ButtonBridge.functionRightStickInput(
                x: 0.4,
                y: 0.05,
                current: .functionRightStickRight
            ) == .functionRightStickRight
        )
        #expect(
            ButtonBridge.functionRightStickInput(
                x: 0.2,
                y: 0.05,
                current: .functionRightStickRight
            ) == nil
        )
    }

    @Test
    func controllerFamiliesSelectMatchingDashboardArtwork() {
        #expect(
            ControllerFamily.dualSense.dashboardArtworkDescriptors() == [
                ControllerArtworkDescriptor(
                    resource: "controller-dashboard-dualsense-transparent",
                    rotationDegrees: 0
                ),
            ]
        )
        #expect(ControllerFamily.dualShock.dashboardArtworkDescriptors().isEmpty)
    }

    @Test
    func joyConArtworkMatchesSideAndGripOrientation() {
        let left = "controller-dashboard-joycon-left"
        let right = "controller-dashboard-joycon-right"

        #expect(ControllerFamily.joyConPair.dashboardArtworkDescriptors() == [
            ControllerArtworkDescriptor(resource: left, rotationDegrees: 0),
            ControllerArtworkDescriptor(resource: right, rotationDegrees: 0),
        ])
        #expect(ControllerFamily.joyConLeft.dashboardArtworkDescriptors(orientation: .vertical) == [
            ControllerArtworkDescriptor(resource: left, rotationDegrees: 0),
        ])
        #expect(ControllerFamily.joyConLeft.dashboardArtworkDescriptors(orientation: .horizontal) == [
            ControllerArtworkDescriptor(resource: left, rotationDegrees: -90),
        ])
        #expect(ControllerFamily.joyConRight.dashboardArtworkDescriptors(orientation: .vertical) == [
            ControllerArtworkDescriptor(resource: right, rotationDegrees: 0),
        ])
        #expect(ControllerFamily.joyConRight.dashboardArtworkDescriptors(orientation: .horizontal) == [
            ControllerArtworkDescriptor(resource: right, rotationDegrees: 90),
        ])
    }

    @Test
    func dualSenseAudioDeviceNamesAreRecognizedWithoutMatchingUnrelatedInputs() {
        #expect(ControllerAudioSupport.matchesDualSenseAudioDevice("DualSense Wireless Controller"))
        #expect(ControllerAudioSupport.matchesDualSenseAudioDevice("Wireless Controller"))
        #expect(!ControllerAudioSupport.matchesDualSenseAudioDevice("Mac Studio Microphone"))
        #expect(!ControllerAudioSupport.matchesDualSenseAudioDevice("Yamaha AG06MK2"))
        #expect(ControllerAudioSupport.transportDescription(kAudioDeviceTransportTypeUSB) == "USB")
        #expect(
            ControllerAudioSupport.transportDescription(kAudioDeviceTransportTypeBluetooth) ==
                L10n.text("蓝牙", "Bluetooth")
        )
    }

    @Test
    func adaptiveTriggerConfirmsOncePerFullPressAndResetsAfterRelease() {
        var state = RightTriggerPressState()

        let initialPosition = state.update(value: 0.02)
        let lightPress = state.update(value: 0.08)
        let resistanceWall = state.update(value: 0.60)
        let firstRelease = state.update(value: 0.72)
        let heldDown = state.update(value: 0.95)
        let partialRelease = state.update(value: 0.40)
        let fullRelease = state.update(value: 0.18)
        let secondRelease = state.update(value: 0.80)

        #expect(initialPosition == nil)
        #expect(lightPress == .lightTouch)
        #expect(resistanceWall == nil)
        #expect(firstRelease == .confirmation)
        #expect(heldDown == nil)
        #expect(partialRelease == nil)
        #expect(fullRelease == nil)
        #expect(secondRelease == .confirmation)
    }

    @Test
    func adaptiveTriggerUsesAStrongButReachableResistanceWall() {
        #expect(RightTriggerPressState.resistanceStart == 0.35)
        #expect(RightTriggerPressState.releasePoint == 0.72)
        #expect(RightTriggerPressState.resistanceStrength == 0.90)
        #expect(RightTriggerPressState.resetPoint < RightTriggerPressState.resistanceStart)
    }

    @Test
    func rightTriggerActionRequiresCrossingTheResistanceWall() {
        var state = AnalogButtonPressState(
            pressPoint: RightTriggerPressState.releasePoint,
            resetPoint: RightTriggerPressState.resetPoint
        )

        #expect(state.update(value: 0.20) == nil)
        #expect(state.update(value: 0.60) == nil)
        #expect(state.update(value: 0.72) == true)
        #expect(state.update(value: 0.95) == nil)
        #expect(state.update(value: 0.40) == nil)
        #expect(state.update(value: 0.18) == false)
        #expect(state.update(value: 0.90) == true)
    }

    @Test
    func dualSenseUSBWeaponReportOnlyUpdatesTheRightTrigger() {
        let report = DualSenseUSBOutputReport.weapon(
            startPosition: 0.35,
            endPosition: 0.72,
            strength: 0.90
        )

        #expect(report.count == 48)
        #expect(report[0] == 0x02)
        #expect(report[1] == 0x04)
        #expect(report[2] == 0)
        #expect(Array(report[11...14]) == [0x25, 0x48, 0x00, 0x06])
        #expect(report[22] == 0)
    }

    @Test
    func dualSenseUSBOffReportOnlyClearsTheRightTrigger() {
        let report = DualSenseUSBOutputReport.off()

        #expect(report.count == 48)
        #expect(report[0] == 0x02)
        #expect(report[1] == 0x04)
        #expect(report[11] == 0x05)
        #expect(report.filter { $0 != 0 }.count == 3)
    }

    @Test
    func fastAdaptiveTriggerPressSkipsTheLightPulse() {
        var state = RightTriggerPressState()
        let feedback = state.update(value: 0.90)
        #expect(feedback == .confirmation)
    }

    @Test
    func rightStickUsesScreenOrientedRadialAngles() {
        #expect(abs(ButtonBridge.radialAngle(x: 1, y: 0) - 0) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: 0, y: -1) - 0.25) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: -1, y: 0) - 0.5) < 0.000_001)
        #expect(abs(ButtonBridge.radialAngle(x: 0, y: 1) - 0.75) < 0.000_001)
    }

    @Test
    func mouseStickUsesADeadZoneAndAcceleratesTowardTheEdge() {
        #expect(MouseBridge.pointerVelocity(x: 0.1, y: 0.1) == .zero)

        let precision = MouseBridge.pointerVelocity(x: 0.2, y: 0)
        let medium = MouseBridge.pointerVelocity(x: 0.5, y: 0)
        let maximum = MouseBridge.pointerVelocity(x: 1, y: 0)
        #expect(precision.x > 0)
        #expect(medium.x > precision.x)
        #expect(maximum.x > medium.x)
        #expect(maximum.y == 0)
    }

    @Test
    func mouseStickKeepsEnoughTravelForPrecisionAdjustments() {
        let quarter = MouseBridge.pointerVelocity(x: 0.25, y: 0).x
        let precisionEdge = MouseBridge.pointerVelocity(x: 0.35, y: 0).x
        let fast = MouseBridge.pointerVelocity(x: 0.75, y: 0).x
        let maximum = MouseBridge.pointerVelocity(x: 1, y: 0).x

        #expect(quarter > 0 && quarter <= 20)
        #expect(precisionEdge > quarter && precisionEdge <= 45)
        #expect(fast >= 450)
        #expect(abs(maximum - 1_250) < 0.000_001)
    }

    @Test
    func mouseStickConvertsControllerUpToScreenUp() {
        let velocity = MouseBridge.pointerVelocity(x: 0, y: 1)
        #expect(velocity.x == 0)
        #expect(velocity.y < 0)
    }

    @Test
    func mouseClicksExposeDoubleAndTripleClickState() throws {
        var tracker = MouseClickSequenceTracker()
        let location = CGPoint(x: 320, y: 240)

        for expectedCount in 1...3 {
            let timestamp = TimeInterval(expectedCount - 1) * 0.1
            let downCount = tracker.clickCount(
                for: .left,
                pressed: true,
                at: timestamp,
                location: location,
                doubleClickInterval: 0.2
            )
            let upCount = tracker.clickCount(
                for: .left,
                pressed: false,
                at: timestamp + 0.02,
                location: location,
                doubleClickInterval: 0.2
            )
            let down = try #require(MouseBridge.mouseButtonEvent(
                button: .left,
                pressed: true,
                location: location,
                clickCount: downCount
            ))
            let up = try #require(MouseBridge.mouseButtonEvent(
                button: .left,
                pressed: false,
                location: location,
                clickCount: upCount
            ))

            #expect(down.getIntegerValueField(.mouseEventClickState) == Int64(expectedCount))
            #expect(up.getIntegerValueField(.mouseEventClickState) == Int64(expectedCount))
        }
    }

    @Test
    func mouseClickSequenceResetsAfterTimeoutOrPointerMovement() {
        var tracker = MouseClickSequenceTracker()
        let location = CGPoint(x: 100, y: 100)

        #expect(tracker.clickCount(
            for: .left,
            pressed: true,
            at: 0,
            location: location,
            doubleClickInterval: 0.2
        ) == 1)
        #expect(tracker.clickCount(
            for: .left,
            pressed: false,
            at: 0.02,
            location: location,
            doubleClickInterval: 0.2
        ) == 1)
        #expect(tracker.clickCount(
            for: .left,
            pressed: true,
            at: 0.3,
            location: location,
            doubleClickInterval: 0.2
        ) == 1)
        #expect(tracker.clickCount(
            for: .left,
            pressed: false,
            at: 0.32,
            location: location,
            doubleClickInterval: 0.2
        ) == 1)
        #expect(tracker.clickCount(
            for: .left,
            pressed: true,
            at: 0.4,
            location: CGPoint(x: 110, y: 100),
            doubleClickInterval: 0.2
        ) == 1)
    }

    @Test
    func mouseVelocitySmoothingIsFrameRateIndependent() {
        let oneFrame = MouseBridge.smoothingFactor(
            deltaTime: 1.0 / 120.0,
            responseTime: 0.05
        )
        let twoFrames = 1 - pow(1 - oneFrame, 2)
        let direct = MouseBridge.smoothingFactor(
            deltaTime: 1.0 / 60.0,
            responseTime: 0.05
        )

        #expect(abs(twoFrames - direct) < 0.000_001)
    }

    @Test
    func mouseSpeedBoostScalesVelocityWithoutChangingDirection() {
        let normal = MouseBridge.pointerVelocity(x: 0.6, y: -0.3)
        let boosted = MouseBridge.pointerVelocity(
            x: 0.6,
            y: -0.3,
            speedMultiplier: MouseBridge.boostSpeedMultiplier
        )

        #expect(abs(boosted.x - normal.x * MouseBridge.boostSpeedMultiplier) < 0.000_001)
        #expect(abs(boosted.y - normal.y * MouseBridge.boostSpeedMultiplier) < 0.000_001)
    }

    @Test
    func mousePrecisionScalesVelocityDownForFineAiming() {
        let normal = MouseBridge.pointerVelocity(x: 0.6, y: -0.3)
        let precise = MouseBridge.pointerVelocity(
            x: 0.6,
            y: -0.3,
            speedMultiplier: MouseBridge.precisionSpeedMultiplier
        )

        #expect(abs(precise.x - normal.x * MouseBridge.precisionSpeedMultiplier) < 0.000_001)
        #expect(abs(precise.y - normal.y * MouseBridge.precisionSpeedMultiplier) < 0.000_001)
        #expect(MouseBridge.pointerSpeedMultiplier(
            precisionActive: true,
            speedBoostActive: true
        ) == MouseBridge.precisionSpeedMultiplier)
        #expect(MouseBridge.pointerSpeedMultiplier(
            precisionActive: false,
            speedBoostActive: true
        ) == MouseBridge.boostSpeedMultiplier)
    }

    @Test
    func pointerSpeedModesUseIndependentSensitivities() {
        let sensitivities = PointerSensitivityValues(normal: 0.8, fast: 2.4, slow: 0.2)

        #expect(MouseBridge.pointerSpeedMultiplier(
            precisionActive: false,
            speedBoostActive: false,
            sensitivities: sensitivities
        ) == 0.8)
        #expect(MouseBridge.pointerSpeedMultiplier(
            precisionActive: false,
            speedBoostActive: true,
            sensitivities: sensitivities
        ) == 2.4)
        #expect(MouseBridge.pointerSpeedMultiplier(
            precisionActive: true,
            speedBoostActive: true,
            sensitivities: sensitivities
        ) == 0.2)
        #expect(abs(MouseBridge.touchpadSensitivityScale(slowSensitivity: 0.2) - 0.625) < 0.000_001)
    }

    @Test
    func pointerLocationStaysInsideDisplayBounds() {
        let display = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: 100, y: 200), displays: [display])
                == CGPoint(x: 100, y: 200)
        )
        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: 100, y: -400), displays: [display])
                == CGPoint(x: 100, y: 0)
        )
        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: 2_500, y: 500), displays: [display])
                == CGPoint(x: 1_919, y: 500)
        )
        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: -50, y: 2_000), displays: [display])
                == CGPoint(x: 0, y: 1_079)
        )
    }

    @Test
    func pointerLocationDoesNotAccumulateOffscreenDebt() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        // Simulate holding the stick past the top edge for several frames.
        var location = CGPoint(x: 720, y: 0)
        for _ in 0..<120 {
            location = MouseBridge.clampPointerLocation(
                CGPoint(x: location.x, y: location.y - 20),
                displays: [display]
            )
        }
        #expect(location == CGPoint(x: 720, y: 0))

        // One frame of reverse travel should move the cursor immediately.
        location = MouseBridge.clampPointerLocation(
            CGPoint(x: location.x, y: location.y + 20),
            displays: [display]
        )
        #expect(location == CGPoint(x: 720, y: 20))
    }

    @Test
    func pointerLocationCanCrossOntoAnAdjacentDisplay() {
        let left = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let right = CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080)
        let displays = [left, right]

        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: 1_930, y: 100), displays: displays)
                == CGPoint(x: 1_930, y: 100)
        )
        #expect(
            MouseBridge.clampPointerLocation(CGPoint(x: 4_000, y: -200), displays: displays)
                == CGPoint(x: 3_839, y: 0)
        )
    }

    @Test
    func touchpadTrackerIgnoresTheFirstContactAndEmitsRelativeDeltas() {
        var tracker = TouchpadPointerTracker()

        #expect(tracker.update(x: 0.2, y: -0.1) == nil)

        let delta = tracker.update(x: 0.3, y: -0.1)
        #expect(delta != nil)
        #expect(abs((delta?.x ?? 0) - 0.1 * TouchpadPointerTracker.sensitivity) < 0.000_01)
        #expect(abs(delta?.y ?? 1) < 0.000_01)

        let upward = tracker.update(x: 0.3, y: 0.0)
        #expect(upward != nil)
        #expect(abs(upward?.x ?? 1) < 0.000_01)
        #expect((upward?.y ?? 0) < 0)

        #expect(tracker.update(x: 0, y: 0) == nil)
        #expect(tracker.update(x: 0.4, y: 0.2) == nil)
    }

    @Test
    func scrollStickUsesDeadZoneAndPreservesBothAxes() {
        #expect(MouseBridge.scrollVelocity(x: 0.1, y: 0.1) == .zero)

        let vertical = MouseBridge.scrollVelocity(x: 0, y: 0.6)
        let horizontal = MouseBridge.scrollVelocity(x: -0.6, y: 0)
        let diagonal = MouseBridge.scrollVelocity(x: 0.5, y: -0.5)

        #expect(vertical.x == 0)
        #expect(vertical.y > 0)
        #expect(horizontal.x < 0)
        #expect(horizontal.y == 0)
        #expect(diagonal.x > 0)
        #expect(diagonal.y < 0)
    }

    @Test
    func naturalScrollDirectionInvertsTraditionalAxes() {
        let traditional = MouseBridge.scrollVelocity(
            x: 0.5,
            y: -0.6,
            direction: .traditional
        )
        let natural = MouseBridge.scrollVelocity(
            x: 0.5,
            y: -0.6,
            direction: .natural
        )

        #expect(abs(natural.x + traditional.x) < 0.000_001)
        #expect(abs(natural.y + traditional.y) < 0.000_001)
    }

    @Test
    func scrollDirectionPreferencePersists() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ScrollDirectionSettings(userDefaults: defaults)
        #expect(settings.preference == .traditional)

        settings.preference = .natural
        let reloaded = ScrollDirectionSettings(userDefaults: defaults)
        #expect(reloaded.preference == .natural)
    }

    @Test
    func pointerSensitivitySettingsPersistIndependently() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PointerSensitivitySettings(userDefaults: defaults)
        #expect(settings.values == .defaults)

        settings.normal = 0.75
        settings.fast = 2.25
        settings.slow = 0.2

        let reloaded = PointerSensitivitySettings(userDefaults: defaults)
        #expect(reloaded.normal == 0.75)
        #expect(reloaded.fast == 2.25)
        #expect(reloaded.slow == 0.2)
    }

    @Test
    func joyConIdentityRecognizesOriginalSidesAndCombinedProfile() {
        #expect(
            JoyConHardwareKind.detect(
                vendorName: "Nintendo",
                productCategory: "Nintendo Switch JoyCon (L)"
            ) == .left
        )
        #expect(
            JoyConHardwareKind.detect(
                vendorName: "Nintendo",
                productCategory: "Nintendo Switch JoyCon (R)"
            ) == .right
        )
        #expect(
            JoyConHardwareKind.detect(
                vendorName: "Nintendo",
                productCategory: "Nintendo Switch JoyCon (L/R)"
            ) == .pair
        )
        #expect(
            JoyConHardwareKind.detect(vendorName: "Microsoft", productCategory: "Xbox One") == nil
        )
        #expect(
            JoyConHardwareKind.detect(vendorName: "Nintendo", productCategory: "Joy-Con Controller") == nil
        )
    }

    @Test
    func joyConIMUReportParsesThreeLittleEndianSamplesInPhysicalUnits() throws {
        var report = [UInt8](repeating: 0, count: 49)
        report[0] = 0x30
        writeInt16(4_096, to: &report, at: 13)
        writeInt16(-4_096, to: &report, at: 15)
        writeInt16(2_048, to: &report, at: 17)
        writeInt16(14_247, to: &report, at: 19)
        writeInt16(-14_247, to: &report, at: 21)
        writeInt16(0, to: &report, at: 23)

        let samples = try #require(JoyConIMUReportParser.samples(
            from: report,
            side: .left,
            calibration: .default
        ))

        #expect(samples.count == 3)
        #expect(abs(samples[0].accelerationG.x - 1) < 0.000_1)
        #expect(abs(samples[0].accelerationG.y + 1) < 0.000_1)
        #expect(abs(samples[0].accelerationG.z - 0.5) < 0.000_1)
        #expect(abs(samples[0].rotationRateDPS.x - 1_000) < 0.1)
        #expect(abs(samples[0].rotationRateDPS.y + 1_000) < 0.1)
        #expect(abs(samples[0].rotationRateDPS.z) < 0.000_1)
        #expect(samples[1].accelerationG == .zero)
        #expect(samples[2].rotationRateDPS == .zero)
    }

    @Test
    func joyConIMUCalibrationParsesFactoryLayout() throws {
        var bytes = [UInt8](repeating: 0, count: 24)
        let values: [Int16] = [
            1, -2, 3,
            16_385, 16_382, 16_387,
            4, -5, 6,
            13_375, 13_366, 13_377,
        ]
        for (index, value) in values.enumerated() {
            writeInt16(value, to: &bytes, at: index * 2)
        }

        let calibration = try #require(JoyConIMUCalibration(data: bytes, source: .factory))

        #expect(calibration.accelerometer.offset == JoyConVector3(x: 1, y: -2, z: 3))
        #expect(calibration.accelerometer.scale == JoyConVector3(x: 16_385, y: 16_382, z: 16_387))
        #expect(calibration.gyroscope.offset == JoyConVector3(x: 4, y: -5, z: 6))
        #expect(calibration.gyroscope.scale == JoyConVector3(x: 13_375, y: 13_366, z: 13_377))
        #expect(calibration.source == .factory)
    }

    @Test
    func joyConHIDSubcommandUsesNeutralRumbleAndSPIReadLayout() {
        let report = JoyConHIDSubcommand.spiRead(
            packetNumber: 0x1f,
            address: 0x6020,
            length: 24
        )

        #expect(report == [
            0x01, 0x0f,
            0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
            0x10, 0x20, 0x60, 0x00, 0x00, 0x18,
        ])
    }

    @Test
    func joyConHIDReportsDistinguishRailAndOuterShoulders() throws {
        var report = Array(repeating: UInt8(0), count: JoyConIMUReportParser.reportLength)
        report[0] = JoyConHIDInputReportParser.fullInputReportID
        report[3] = 0b0101_0000
        report[4] = 0b0011_0011
        report[5] = 0b1010_0000

        let left = try #require(JoyConHIDInputReportParser.shoulders(from: report, side: .left))
        #expect(!left.sr)
        #expect(left.sl)
        #expect(!left.outerShoulder)
        #expect(left.outerTrigger)
        #expect(left.capture)
        #expect(left.minus)
        #expect(!left.home)
        #expect(!left.plus)

        let right = try #require(JoyConHIDInputReportParser.shoulders(from: report, side: .right))
        #expect(right.sr)
        #expect(!right.sl)
        #expect(right.outerShoulder)
        #expect(!right.outerTrigger)
        #expect(!right.capture)
        #expect(!right.minus)
        #expect(right.home)
        #expect(right.plus)

        report[0] = JoyConHIDInputReportParser.subcommandReplyReportID
        #expect(JoyConHIDInputReportParser.shoulders(from: report, side: .left) == left)
        report[0] = 0xff
        #expect(JoyConHIDInputReportParser.shoulders(from: report, side: .left) == nil)
        #expect(JoyConHIDInputReportParser.shoulders(from: [0x30, 0, 0], side: .left) == nil)
    }

    @Test
    func singleJoyConLeftHIDCaptureMapsToOptionsAndFiresScreenshot() {
        let bridge = ButtonBridge { input in
            switch input {
            case .options: .screenshotTool
            default: .disabled
            }
        }
        var systemKeyEvents: [(SystemKey, Bool)] = []
        bridge.systemKeyHandler = { systemKeyEvents.append(($0, $1)) }

        let sampleWithCapture = JoyConSingleShoulderAdapter.apply(
            JoyConHIDShoulderSnapshot(
                sl: false,
                sr: false,
                outerShoulder: false,
                outerTrigger: false,
                capture: true
            ),
            to: JoyConProfileSample(
                snapshot: JoyConInputSnapshot(
                    buttons: [.options: false],
                    primaryStick: .neutral,
                    secondaryStick: .neutral
                ),
                availableInputs: [.options]
            ),
            side: .left,
            orientation: .vertical
        )
        #expect(sampleWithCapture.snapshot.buttons[.options] == true)

        bridge.applyJoyConSnapshot(sampleWithCapture.snapshot)
        #expect(systemKeyEvents.contains { $0.0 == .screenshotTool && $0.1 == true })

        let sampleReleased = JoyConSingleShoulderAdapter.apply(
            JoyConHIDShoulderSnapshot(
                sl: false,
                sr: false,
                outerShoulder: false,
                outerTrigger: false,
                capture: false
            ),
            to: JoyConProfileSample(
                snapshot: JoyConInputSnapshot(
                    buttons: [.options: false],
                    primaryStick: .neutral,
                    secondaryStick: .neutral
                ),
                availableInputs: [.options]
            ),
            side: .left,
            orientation: .vertical
        )
        #expect(sampleReleased.snapshot.buttons[.options] == false)

        bridge.applyJoyConSnapshot(sampleReleased.snapshot)
        #expect(systemKeyEvents.contains { $0.0 == .screenshotTool && $0.1 == false })
    }

    @Test
    func singleJoyConLeftHIDDirectionalAndShoulderButtonsMapCorrectly() {
        let snapshot = JoyConHIDShoulderSnapshot(
            sl: false,
            sr: false,
            outerShoulder: true,
            outerTrigger: false,
            up: true,
            left: true
        )
        let sample = JoyConSingleShoulderAdapter.apply(
            snapshot,
            to: JoyConProfileSample(
                snapshot: .neutral,
                availableInputs: []
            ),
            side: .left,
            orientation: .vertical
        )
        #expect(sample.snapshot.buttons[.leftShoulder] == true)
        #expect(sample.snapshot.buttons[.buttonX] == true) // Up arrow
        #expect(sample.snapshot.buttons[.buttonA] == true) // Left arrow
        #expect(sample.snapshot.buttons[.buttonB] == nil)
        #expect(sample.snapshot.buttons[.buttonY] == nil)
    }

    @Test
    func joyConHIDSnapshotsAreRejectedWhenOneSideHasMultipleEndpoints() {
        let onePerSide: [(side: JoyConSide, snapshot: Int?)] = [
            (.left, 10),
            (.right, 20),
        ]
        #expect(JoyConHIDSnapshotResolver.unambiguous(
            for: .left,
            candidates: onePerSide
        ) == 10)

        let ambiguous: [(side: JoyConSide, snapshot: Int?)] = [
            (.left, 10),
            (.left, 11),
            (.right, 20),
        ]
        #expect(JoyConHIDSnapshotResolver.unambiguous(
            for: .left,
            candidates: ambiguous
        ) == nil)
        #expect(JoyConHIDSnapshotResolver.unambiguous(
            for: .right,
            candidates: ambiguous
        ) == 20)
    }

    @Test
    func singleJoyConHIDShouldersSelectTheConfiguredGripPair() {
        let snapshot = JoyConHIDShoulderSnapshot(
            sl: true,
            sr: false,
            outerShoulder: false,
            outerTrigger: true
        )

        for side in JoyConSide.allCases {
            #expect(JoyConSingleShoulderAdapter.buttons(
                side: side,
                orientation: .horizontal,
                snapshot: snapshot
            ) == [
                .leftShoulder: true,
                .rightShoulder: false,
            ])
        }
        #expect(JoyConSingleShoulderAdapter.buttons(
            side: .left,
            orientation: .vertical,
            snapshot: snapshot
        ) == [
            .leftShoulder: false,
            .rightShoulder: true,
        ])
        #expect(JoyConSingleShoulderAdapter.buttons(
            side: .right,
            orientation: .vertical,
            snapshot: snapshot
        ) == [
            .leftShoulder: true,
            .rightShoulder: false,
        ])
    }

    @Test
    func singleJoyConHIDShouldersReplaceAmbiguousGameControllerInputs() {
        let sample = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [
                    .buttonA: true,
                    .leftShoulder: true,
                    .rightShoulder: true,
                    .leftTrigger: true,
                    .rightTrigger: true,
                ],
                primaryStick: JoyConStick(x: 0.25, y: -0.75),
                secondaryStick: .neutral
            ),
            availableInputs: [
                .buttonA,
                .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
                .functionLeftShoulder, .functionRightShoulder, .functionRightTrigger,
            ]
        )
        let projected = JoyConSingleShoulderAdapter.apply(
            JoyConHIDShoulderSnapshot(
                sl: false,
                sr: true,
                outerShoulder: true,
                outerTrigger: false
            ),
            to: sample,
            side: .left,
            orientation: .vertical
        )

        #expect(projected.snapshot.buttons == [
            .buttonA: true,
            .leftShoulder: true,
            .rightShoulder: false,
        ])
        #expect(projected.availableInputs == [.buttonA, .leftShoulder, .rightShoulder])
        #expect(projected.snapshot.primaryStick == sample.snapshot.primaryStick)
        #expect(projected.snapshot.secondaryStick == .neutral)

        let suppressed = JoyConSingleShoulderAdapter.suppressAmbiguousShoulders(in: sample)
        #expect(suppressed.snapshot.buttons == [.buttonA: true])
        #expect(suppressed.availableInputs == [.buttonA])
        #expect(suppressed.snapshot.primaryStick == sample.snapshot.primaryStick)
    }

    @Test
    func separatelyEnumeratedJoyConPairUsesOnlyOuterHIDShoulders() {
        let leftSample = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [.dpadUp: true, .leftShoulder: true, .leftTrigger: false],
                primaryStick: JoyConStick(x: 0.25, y: -0.75),
                secondaryStick: .neutral
            ),
            availableInputs: [
                .dpadUp, .leftShoulder, .leftTrigger,
                .functionDpadUp, .functionLeftShoulder,
            ]
        )
        let left = JoyConPairedShoulderAdapter.apply(
            JoyConHIDShoulderSnapshot(
                sl: true,
                sr: true,
                outerShoulder: false,
                outerTrigger: true
            ),
            to: leftSample,
            side: .left
        )
        #expect(left.snapshot.buttons == [
            .dpadUp: true,
            .leftShoulder: false,
            .leftTrigger: true,
        ])

        let rightSample = JoyConProfileSample(
            snapshot: JoyConInputSnapshot(
                buttons: [.buttonA: true, .rightShoulder: false, .rightTrigger: true],
                primaryStick: .neutral,
                secondaryStick: JoyConStick(x: -0.5, y: 0.8)
            ),
            availableInputs: [.buttonA, .rightShoulder, .rightTrigger]
        )
        let right = JoyConPairedShoulderAdapter.apply(
            JoyConHIDShoulderSnapshot(
                sl: false,
                sr: true,
                outerShoulder: true,
                outerTrigger: false
            ),
            to: rightSample,
            side: .right
        )
        #expect(right.snapshot.buttons == [
            .buttonA: true,
            .rightShoulder: true,
            .rightTrigger: false,
        ])

        let bases = left.availableInputs.union(right.availableInputs)
        let available = JoyConProfileReader.expandedAvailableInputs(
            from: bases,
            hasSecondaryStick: true
        )
        #expect(available.contains(.functionDpadUp))
        #expect(available.contains(.functionButtonA))
        #expect(available.contains(.functionRightShoulder))
        #expect(available.contains(.functionRightTrigger))

        let suppressed = JoyConPairedShoulderAdapter.suppressAmbiguousShoulders(
            in: leftSample,
            side: .left
        )
        #expect(suppressed.snapshot.buttons == [.dpadUp: true])
        #expect(!suppressed.availableInputs.contains(.leftTrigger))
        #expect(!suppressed.availableInputs.contains(.functionDpadUp))
    }

    @Test
    func joyConPhysicalDirectionsReachTheExpectedScreenDirections() {
        let standardDirections: [(name: String, raw: JoyConStick, expected: JoyConStick)] = [
            ("up", JoyConStick(x: 0, y: 1), JoyConStick(x: 0, y: 1)),
            ("right", JoyConStick(x: 1, y: 0), JoyConStick(x: 1, y: 0)),
            ("down", JoyConStick(x: 0, y: -1), JoyConStick(x: 0, y: -1)),
            ("left", JoyConStick(x: -1, y: 0), JoyConStick(x: -1, y: 0)),
        ]
        let leftVerticalDirections: [(name: String, raw: JoyConStick, expected: JoyConStick)] = [
            ("up", JoyConStick(x: -1, y: 0), JoyConStick(x: 0, y: 1)),
            ("right", JoyConStick(x: 0, y: 1), JoyConStick(x: 1, y: 0)),
            ("down", JoyConStick(x: 1, y: 0), JoyConStick(x: 0, y: -1)),
            ("left", JoyConStick(x: 0, y: -1), JoyConStick(x: -1, y: 0)),
        ]
        let rightVerticalDirections: [(name: String, raw: JoyConStick, expected: JoyConStick)] = [
            ("up", JoyConStick(x: 1, y: 0), JoyConStick(x: 0, y: 1)),
            ("right", JoyConStick(x: 0, y: -1), JoyConStick(x: 1, y: 0)),
            ("down", JoyConStick(x: -1, y: 0), JoyConStick(x: 0, y: -1)),
            ("left", JoyConStick(x: 0, y: 1), JoyConStick(x: -1, y: 0)),
        ]
        let pointerScenarios: [(
            name: String,
            side: JoyConSide,
            paired: Bool,
            orientation: JoyConOrientation,
            directions: [(String, JoyConStick, JoyConStick)]
        )] = [
            ("left horizontal", .left, false, .horizontal, standardDirections),
            ("right horizontal", .right, false, .horizontal, standardDirections),
            ("left vertical", .left, false, .vertical, leftVerticalDirections),
            ("right vertical", .right, false, .vertical, rightVerticalDirections),
            ("separated pair left", .left, true, .horizontal, leftVerticalDirections),
        ]

        for scenario in pointerScenarios {
            for direction in scenario.directions {
                let sticks = JoyConStickProjector.sideProfile(
                    side: scenario.side,
                    paired: scenario.paired,
                    orientation: scenario.orientation,
                    raw: direction.1
                )
                #expect(sticks.primary == direction.2, "\(scenario.name): \(direction.0)")
                #expect(sticks.secondary == .neutral, "\(scenario.name): \(direction.0)")

                let velocity = MouseBridge.pointerVelocity(
                    x: CGFloat(sticks.primary.x),
                    y: CGFloat(sticks.primary.y)
                )
                #expect((velocity.x > 0) == (direction.2.x > 0), "\(scenario.name): \(direction.0)")
                #expect((velocity.x < 0) == (direction.2.x < 0), "\(scenario.name): \(direction.0)")
                #expect((velocity.y < 0) == (direction.2.y > 0), "\(scenario.name): \(direction.0)")
                #expect((velocity.y > 0) == (direction.2.y < 0), "\(scenario.name): \(direction.0)")
            }
        }

        for direction in rightVerticalDirections {
            let sticks = JoyConStickProjector.sideProfile(
                side: .right,
                paired: true,
                orientation: .horizontal,
                raw: direction.raw
            )
            #expect(sticks.primary == .neutral, "separated pair right: \(direction.name)")
            #expect(sticks.secondary == direction.expected, "separated pair right: \(direction.name)")
            #expect(
                abs(ButtonBridge.radialAngle(x: sticks.secondary.x, y: sticks.secondary.y) -
                    Self.radialAngle(for: direction.expected)) < 0.000_001,
                "separated pair right: \(direction.name)"
            )
        }

        for (index, primaryDirection) in standardDirections.enumerated() {
            let secondaryDirection = standardDirections[(index + 1) % standardDirections.count]
            let sticks = JoyConStickProjector.combinedPair(
                primaryRaw: primaryDirection.raw,
                secondaryRaw: secondaryDirection.raw
            )
            #expect(sticks.primary == primaryDirection.expected, "combined primary: \(primaryDirection.name)")
            #expect(
                sticks.secondary == secondaryDirection.expected,
                "combined secondary: \(secondaryDirection.name)"
            )

            let velocity = MouseBridge.pointerVelocity(
                x: CGFloat(sticks.primary.x),
                y: CGFloat(sticks.primary.y)
            )
            #expect(
                (velocity.x > 0) == (primaryDirection.expected.x > 0),
                "combined primary: \(primaryDirection.name)"
            )
            #expect(
                (velocity.y < 0) == (primaryDirection.expected.y > 0),
                "combined primary: \(primaryDirection.name)"
            )
            #expect(
                abs(ButtonBridge.radialAngle(x: sticks.secondary.x, y: sticks.secondary.y) -
                    Self.radialAngle(for: secondaryDirection.expected)) < 0.000_001,
                "combined secondary: \(secondaryDirection.name)"
            )
        }
    }

    @Test
    func publicJoyConProfileUsesItsOnlyDirectionPadAsTheStick() {
        let profileElements = ["Direction Pad"]

        #expect(JoyConProfileLayout.stickElementName(in: profileElements) == "directionpad")
    }

    @Test
    func singleJoyConSubscribesToMicroGamepadChanges() {
        let sources = JoyConInputMonitoringPolicy.sources(
            kind: .left,
            hasMicroGamepad: true,
            hasExtendedGamepad: false
        )

        #expect(sources == [.physicalProfile, .microGamepad])
    }

    @Test
    func singleJoyConAppleButtonsKeepStablePhysicalIdentities() {
        #expect(JoyConProfileLayout.singleInput(side: .left, appleButtonName: "Button X") == .buttonA)
        #expect(JoyConProfileLayout.singleInput(side: .left, appleButtonName: "Button Y") == .buttonB)
        #expect(JoyConProfileLayout.singleInput(side: .left, appleButtonName: "Button A") == .buttonX)
        #expect(JoyConProfileLayout.singleInput(side: .left, appleButtonName: "Button B") == .buttonY)

        #expect(JoyConProfileLayout.singleInput(side: .right, appleButtonName: "Button A") == .buttonA)
        #expect(JoyConProfileLayout.singleInput(side: .right, appleButtonName: "Button B") == .buttonB)
        #expect(JoyConProfileLayout.singleInput(side: .right, appleButtonName: "Button X") == .buttonX)
        #expect(JoyConProfileLayout.singleInput(side: .right, appleButtonName: "Button Y") == .buttonY)
    }

    @Test
    func singleJoyConShoulderLabelsFollowGripOrientation() {
        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .horizontal
        ) == "SL")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .horizontal
        ) == "SR")
        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .horizontal
        ) == "SL")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .horizontal
        ) == "SR")

        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .vertical
        ) == "L")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .vertical
        ) == "ZL")
        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .vertical
        ) == "ZR")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .vertical
        ) == "R")
    }

    @Test
    func pairedJoyConAppleButtonsMapFromHorizontalProfilesToVerticalLayout() {
        #expect(JoyConProfileLayout.pairedInput(side: .left, appleButtonName: "Button X") == .dpadLeft)
        #expect(JoyConProfileLayout.pairedInput(side: .left, appleButtonName: "Button Y") == .dpadDown)
        #expect(JoyConProfileLayout.pairedInput(side: .left, appleButtonName: "Button A") == .dpadUp)
        #expect(JoyConProfileLayout.pairedInput(side: .left, appleButtonName: "Button B") == .dpadRight)

        #expect(JoyConProfileLayout.pairedInput(side: .right, appleButtonName: "Button A") == .buttonB)
        #expect(JoyConProfileLayout.pairedInput(side: .right, appleButtonName: "Button B") == .buttonY)
        #expect(JoyConProfileLayout.pairedInput(side: .right, appleButtonName: "Button X") == .buttonA)
        #expect(JoyConProfileLayout.pairedInput(side: .right, appleButtonName: "Button Y") == .buttonX)
    }

    @Test
    func pairedJoyConShouldersUseCompleteControllerIdentities() {
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .left,
            appleButtonName: "Left Shoulder"
        ) == .leftShoulder)
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .left,
            appleButtonName: "Right Shoulder"
        ) == .leftTrigger)
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .right,
            appleButtonName: "Left Shoulder"
        ) == .rightTrigger)
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .right,
            appleButtonName: "Right Shoulder"
        ) == .rightShoulder)
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .left,
            appleButtonName: "Button ZL"
        ) == .leftTrigger)
        #expect(JoyConProfileLayout.pairedShoulderInput(
            side: .right,
            appleButtonName: "Button ZR"
        ) == .rightTrigger)
    }

    @Test
    func separatelyEnumeratedJoyConPairKeepsBothStickAxes() {
        let left = JoyConInputSnapshot(
            buttons: [.dpadUp: true],
            primaryStick: JoyConStick(x: 0.25, y: -0.75),
            secondaryStick: .neutral
        )
        let right = JoyConInputSnapshot(
            buttons: [.buttonA: true],
            primaryStick: .neutral,
            secondaryStick: JoyConStick(x: -0.5, y: 0.8)
        )

        let pair = left.merging(right)

        #expect(pair.primaryStick == left.primaryStick)
        #expect(pair.secondaryStick == right.secondaryStick)
        #expect(pair.buttons == [.dpadUp: true, .buttonA: true])
    }

    @Test
    func joyConModeResetReleasesHeldActionsAndNeutralizesAxes() {
        let bridge = ButtonBridge { input in
            switch input {
            case .buttonA: .mouseLeft
            case .menu: .pushToTalk
            case .leftTrigger: .functionModifier
            case .functionButtonB: .rightCommand
            default: .disabled
            }
        }
        var mouseEvents: [(MouseButton, Bool)] = []
        var microEvents: [(String, Int)] = []
        var systemKeyEvents: [(SystemKey, Bool)] = []
        var stickEvents: [(Float, Float, Bool)] = []
        bridge.mouseButtonHandler = { mouseEvents.append(($0, $1)) }
        bridge.keyHandler = {
            microEvents.append(($0, $1))
            return true
        }
        bridge.systemKeyHandler = { systemKeyEvents.append(($0, $1)) }
        bridge.leftStickHandler = { stickEvents.append(($0, $1, $2)) }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true, .menu: true],
            primaryStick: JoyConStick(x: 0.8, y: -0.4),
            secondaryStick: .neutral
        ))
        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true, .menu: true, .leftTrigger: true],
            primaryStick: JoyConStick(x: 0.8, y: -0.4),
            secondaryStick: .neutral
        ))
        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true, .buttonB: true, .menu: true, .leftTrigger: true],
            primaryStick: JoyConStick(x: 0.8, y: -0.4),
            secondaryStick: .neutral
        ))

        bridge.resetInputState()

        #expect(mouseEvents.map(\.1) == [true, false])
        #expect(microEvents.map(\.0) == ["ACT10", "ACT10"])
        #expect(microEvents.map(\.1) == [1, 0])
        #expect(systemKeyEvents.map(\.0) == [.rightCommand, .rightCommand])
        #expect(systemKeyEvents.map(\.1) == [true, false])
        #expect(stickEvents.last?.0 == 0)
        #expect(stickEvents.last?.1 == 0)
        #expect(stickEvents.last?.2 == false)
    }

    @Test
    func joyConDisconnectNeutralizesTheRadialJoystickOutput() {
        let bridge = ButtonBridge()
        var joystickEvents: [(angle: Float, distance: Float)] = []
        bridge.joystickHandler = { angle, distance in
            joystickEvents.append((angle, distance))
            return true
        }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [:],
            primaryStick: .neutral,
            secondaryStick: JoyConStick(x: 0.6, y: -0.8)
        ))
        bridge.resetInputState()

        #expect(joystickEvents.first?.distance == 1)
        #expect(joystickEvents.last?.angle == 0)
        #expect(joystickEvents.last?.distance == 0)
    }

    @Test
    func changingJoyConOrientationReleasesHeldActionsAndNeutralizesAxes() {
        let bridge = ButtonBridge { input in
            input == .buttonA ? .mouseLeft : .disabled
        }
        var mouseEvents: [(MouseButton, Bool)] = []
        var stickEvents: [(Float, Float, Bool)] = []
        bridge.mouseButtonHandler = { mouseEvents.append(($0, $1)) }
        bridge.leftStickHandler = { stickEvents.append(($0, $1, $2)) }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true],
            primaryStick: JoyConStick(x: 0.8, y: -0.4),
            secondaryStick: .neutral
        ))
        bridge.refreshJoyConOrientation()

        #expect(mouseEvents.map(\.1) == [true, false])
        #expect(stickEvents.last?.0 == 0)
        #expect(stickEvents.last?.1 == 0)
    }

    @Test
    func joyConCompositionIsIndependentOfConnectionOrder() {
        let left = JoyConEndpointDescriptor(id: "left-1", kind: .left)
        let right = JoyConEndpointDescriptor(id: "right-1", kind: .right)
        var first = JoyConCompositionCoordinator()
        _ = first.reconcile([left])
        let leftThenRight = first.reconcile([left, right])
        var second = JoyConCompositionCoordinator()
        _ = second.reconcile([right])
        let rightThenLeft = second.reconcile([right, left])

        #expect(leftThenRight.mode == .pair)
        #expect(rightThenLeft.mode == .pair)
        #expect(leftThenRight.leftID == rightThenLeft.leftID)
        #expect(leftThenRight.rightID == rightThenLeft.rightID)
    }

    @Test
    func currentStandardControllerOverridesPreviouslyAttachedJoyCon() {
        #expect(!JoyConControllerSelectionPolicy.shouldUseJoyCon(
            hasJoyCon: true,
            hasStandardController: true,
            currentIsJoyCon: false,
            currentIsStandardController: true,
            attachedIsJoyCon: true
        ))
        #expect(JoyConControllerSelectionPolicy.shouldUseJoyCon(
            hasJoyCon: true,
            hasStandardController: true,
            currentIsJoyCon: true,
            currentIsStandardController: false,
            attachedIsJoyCon: false
        ))
        #expect(JoyConControllerSelectionPolicy.shouldUseJoyCon(
            hasJoyCon: true,
            hasStandardController: false,
            currentIsJoyCon: false,
            currentIsStandardController: false,
            attachedIsJoyCon: false
        ))
    }

    @Test
    func joyConCompositionRetainsActiveSideAndRejectsStaleGeneration() {
        let left1 = JoyConEndpointDescriptor(id: "left-1", kind: .left)
        let left2 = JoyConEndpointDescriptor(id: "left-2", kind: .left)
        let right = JoyConEndpointDescriptor(id: "right-1", kind: .right)
        var coordinator = JoyConCompositionCoordinator()
        let initial = coordinator.reconcile([left1, right])
        let withExtra = coordinator.reconcile([left2, right, left1])

        #expect(withExtra.leftID == "left-1")
        #expect(withExtra.inactiveIDs == ["left-2"])
        #expect(withExtra.generation == initial.generation)

        let promoted = coordinator.reconcile([left2, right])
        #expect(promoted.leftID == "left-2")
        #expect(promoted.generation > initial.generation)
        #expect(!promoted.accepts(endpointID: "left-1", generation: initial.generation))
        #expect(promoted.accepts(endpointID: "left-2", generation: promoted.generation))
    }

    @Test
    func combinedJoyConProfileTakesPrecedenceOverSeparateDuplicates() {
        let endpoints = [
            JoyConEndpointDescriptor(id: "left", kind: .left),
            JoyConEndpointDescriptor(id: "right", kind: .right),
            JoyConEndpointDescriptor(id: "combined", kind: .pair),
        ]
        var coordinator = JoyConCompositionCoordinator()
        let composition = coordinator.reconcile(endpoints)

        #expect(composition.mode == .pair)
        #expect(composition.combinedID == "combined")
        #expect(composition.leftID == nil)
        #expect(composition.rightID == nil)
        #expect(composition.inactiveIDs == ["left", "right"])
    }

    @Test
    func singleJoyConMappingsHideAbsentSideAndKeepCoreDefaults() {
        for family in [ControllerFamily.joyConLeft, .joyConRight] {
            let available = ControllerInput.availableInputs(for: family)
            let defaults = ControllerMappingStore.defaultMappings(for: family)
            #expect(!available.contains(.rightThumbstickButton))
            #expect(!available.contains(.functionRightStickLeft))
            #expect(!available.contains(.leftTrigger))
            #expect(!available.contains(.rightTrigger))
            #expect(defaults[.buttonA] == .mouseLeft)
            #expect(defaults[.buttonB] == .mouseRight)
            #expect(defaults[.leftShoulder] == .previousSlot)
            #expect(defaults[.rightShoulder] == .nextSlot)
            #expect(defaults[.leftTrigger] == .disabled)
            #expect(defaults[.menu] == .pushToTalk)
            #expect(defaults[.functionRightStickLeft] == .disabled)
        }
    }

    @Test
    func insufficientJoyConProfileExposesNoMappingInputs() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setControllerFamily(.joyConLeft)

        store.setAvailableInputs([])

        #expect(store.availableInputs.isEmpty)
    }

    @Test
    func joyConLabelsMatchPhysicalNintendoControls() {
        #expect(ControllerInput.buttonA.displayName(for: .joyConPair) == "B")
        #expect(ControllerInput.buttonB.displayName(for: .joyConPair) == "A")
        #expect(ControllerInput.buttonA.displayName(for: .joyConLeft) == "←")
        #expect(ControllerInput.buttonA.displayName(for: .joyConRight) == "A")
        #expect(ControllerInput.leftShoulder.displayName(for: .joyConLeft) == "SL")
        #expect(ControllerInput.rightShoulder.displayName(for: .joyConRight) == "SR")
        #expect(ControllerInput.leftShoulder.displayName(for: .joyConPair) == "L")
        #expect(ControllerInput.leftTrigger.displayName(for: .joyConPair) == "ZL")
        #expect(ControllerInput.rightShoulder.displayName(for: .joyConPair) == "R")
        #expect(ControllerInput.rightTrigger.displayName(for: .joyConPair) == "ZR")
        #expect(ControllerInput.options.displayName(for: .joyConPair) == "−")
        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .vertical
        ) == "L")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConLeft,
            joyConOrientation: .vertical
        ) == "ZL")
        #expect(ControllerInput.leftShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .vertical
        ) == "ZR")
        #expect(ControllerInput.rightShoulder.displayName(
            for: .joyConRight,
            joyConOrientation: .vertical
        ) == "R")
    }

    @Test
    func mappingStorePropagatesJoyConOrientationToVisibleLabels() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)

        store.setControllerFamily(.joyConLeft)
        #expect(store.displayName(for: .leftShoulder) == "SL")
        #expect(store.displayName(for: .rightShoulder) == "SR")
        store.setJoyConOrientation(.vertical)
        #expect(store.displayName(for: .leftShoulder) == "L")
        #expect(store.displayName(for: .rightShoulder) == "ZL")

        store.setControllerFamily(.joyConRight)
        store.setJoyConOrientation(.vertical)
        #expect(store.displayName(for: .leftShoulder) == "ZR")
        #expect(store.displayName(for: .rightShoulder) == "R")
    }

    @Test
    func joyConMappingsPersistIndependentlyByMode() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)

        store.setControllerFamily(.joyConLeft)
        store.setAction(.copy, for: .buttonA)
        store.setOpenApplicationTarget("com.apple.Safari", for: .buttonX)
        let shortcut = RecordedKeyboardShortcut(
            keyCode: 3,
            keyName: "F",
            modifiers: [.command, .shift]
        )
        store.setRecordedShortcut(shortcut, for: .buttonY)
        store.setRecordedShortcutNote("Left shortcut", for: .buttonY)
        store.setControllerFamily(.joyConRight)
        store.setAction(.paste, for: .buttonA)
        store.setControllerFamily(.joyConPair)
        store.setAction(.mouseMiddle, for: .buttonA)

        store.setControllerFamily(.joyConLeft)
        #expect(store.action(for: .buttonA) == .copy)
        #expect(store.openApplicationTarget(for: .buttonX) == "com.apple.Safari")
        #expect(store.recordedShortcutConfiguration(for: .buttonY) == RecordedShortcutConfiguration(
            shortcut: shortcut,
            note: "Left shortcut"
        ))
        store.setControllerFamily(.joyConRight)
        #expect(store.action(for: .buttonA) == .paste)
        #expect(store.openApplicationTarget(for: .buttonX) == nil)
        #expect(store.recordedShortcutConfiguration(for: .buttonY).shortcut == nil)
        store.setControllerFamily(.joyConPair)
        #expect(store.action(for: .buttonA) == .mouseMiddle)

        let relaunched = ControllerMappingStore(userDefaults: defaults)
        relaunched.setControllerFamily(.joyConLeft)
        #expect(relaunched.action(for: .buttonA) == .copy)
        #expect(relaunched.openApplicationTarget(for: .buttonX) == "com.apple.Safari")
        #expect(relaunched.recordedShortcutConfiguration(for: .buttonY).shortcut == shortcut)
    }

    @Test
    func singleJoyConOrientationsPersistIndependentlyBySide() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)

        store.setControllerFamily(.joyConLeft)
        #expect(store.joyConOrientation == .horizontal)
        store.setJoyConOrientation(.vertical)
        store.setControllerFamily(.joyConRight)
        #expect(store.joyConOrientation == .horizontal)
        store.setJoyConOrientation(.horizontal)

        store.setControllerFamily(.joyConLeft)
        #expect(store.joyConOrientation == .vertical)
        let relaunched = ControllerMappingStore(userDefaults: defaults)
        relaunched.setControllerFamily(.joyConRight)
        #expect(relaunched.joyConOrientation == .horizontal)
        relaunched.setControllerFamily(.joyConLeft)
        #expect(relaunched.joyConOrientation == .vertical)
    }

    @Test
    func existingMappingSurvivesJoyConRoundTrip() throws {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ControllerMappingStore(userDefaults: defaults)
        store.setAction(.copy, for: .buttonA)

        store.setControllerFamily(.joyConLeft)
        store.setAction(.paste, for: .buttonA)
        store.setControllerFamily(.xbox)

        #expect(store.action(for: .buttonA) == .copy)
    }

    @Test
    func joyConArtworkHighlightLayoutsCoverPhysicalButtons() {
        let pair = ControllerInputHighlightModel.layout(for: .joyConPair)
        for input in [
            ControllerInput.buttonA, .buttonB, .buttonX, .buttonY,
            .dpadUp, .dpadLeft, .dpadDown, .dpadRight,
            .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
            .leftThumbstickButton, .rightThumbstickButton,
            .menu, .options, .home,
        ] {
            #expect(pair[input] != nil)
        }

        let leftHorizontal = ControllerInputHighlightModel.layout(for: .joyConLeft, orientation: .horizontal)
        let leftVertical = ControllerInputHighlightModel.layout(for: .joyConLeft, orientation: .vertical)
        for input in [
            ControllerInput.buttonA, .buttonB, .buttonX, .buttonY,
            .leftShoulder, .rightShoulder, .menu, .options, .leftThumbstickButton,
        ] {
            #expect(leftHorizontal[input] != nil)
            #expect(leftVertical[input] != nil)
        }

        let rightHorizontal = ControllerInputHighlightModel.layout(for: .joyConRight, orientation: .horizontal)
        let rightVertical = ControllerInputHighlightModel.layout(for: .joyConRight, orientation: .vertical)
        for input in [
            ControllerInput.buttonA, .buttonB, .buttonX, .buttonY,
            .leftShoulder, .rightShoulder, .menu, .options, .leftThumbstickButton,
        ] {
            #expect(rightHorizontal[input] != nil)
            #expect(rightVertical[input] != nil)
        }
    }

    @Test
    func singleJoyConSupportsCustomFunctionModifierAndFunctionLayer() {
        for input in [
            ControllerInput.leftShoulder, .rightShoulder,
            .leftThumbstickButton, .menu, .options, .leftTrigger,
        ] {
            #expect(input.availableActions.contains(.functionModifier))
        }

        let bridge = ButtonBridge { input in
            switch input {
            case .leftShoulder: .functionModifier
            case .functionButtonA: .approve
            case .buttonA: .mouseLeft
            default: .disabled
            }
        }

        var keyEvents: [(String, Int)] = []
        var mouseEvents: [(MouseButton, Bool)] = []
        var stickEvents: [(Float, Float, Bool)] = []

        bridge.keyHandler = { key, action in
            keyEvents.append((key, action))
            return true
        }
        bridge.mouseButtonHandler = { mouseEvents.append(($0, $1)) }
        bridge.leftStickHandler = { stickEvents.append(($0, $1, $2)) }

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.leftShoulder: true],
            primaryStick: JoyConStick(x: 0, y: 0.8),
            secondaryStick: .neutral
        ))
        #expect(stickEvents.last?.2 == true)

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.leftShoulder: true, .buttonA: true],
            primaryStick: .neutral,
            secondaryStick: .neutral
        ))
        #expect(keyEvents.contains { $0.0 == "ACT07" && $0.1 == 1 })
        #expect(mouseEvents.isEmpty)

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [:],
            primaryStick: .neutral,
            secondaryStick: .neutral
        ))
        #expect(keyEvents.contains { $0.0 == "ACT07" && $0.1 == 0 })
    }

    @Test
    func hapticEngineAttachTriggersSingleConnectionChangeCallback() {
        let engine = HapticEngine()
        var callbackCount = 0
        engine.onConnectionChange = {
            callbackCount += 1
        }
        engine.attach([])
        #expect(callbackCount == 0)

        engine.attach([])
        #expect(callbackCount == 0)
    }

    @Test
    func nativeGamepadAppSettingsIncludesJoyDSHByDefault() {
        let settings = NativeGamepadAppSettings(userDefaults: UserDefaults(suiteName: "JoyHarnessTests.\(UUID().uuidString)")!)
        #expect(settings.autoSwitchEnabled == true)
        #expect(settings.apps.contains { $0.appName == "JoyDSH" && $0.bundleIdentifier == "com.joydsh.desktop" })
        #expect(settings.matches(bundleIdentifier: "com.joydsh.desktop", localizedName: "JoyDSH"))
        #expect(settings.matches(bundleIdentifier: "COM.JOYDSH.DESKTOP", localizedName: nil))
        #expect(settings.matches(bundleIdentifier: nil, localizedName: "joydsh"))
    }

    @Test
    func nativeGamepadAppSettingsMatchesBundleIDAndAppNameCaseInsensitively() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NativeGamepadAppSettings(userDefaults: defaults)
        settings.addApp(bundleIdentifier: "com.valvesoftware.steam", appName: "Steam")

        #expect(settings.matches(bundleIdentifier: "com.valvesoftware.steam", localizedName: "Steam"))
        #expect(settings.matches(bundleIdentifier: "COM.VALVESOFTWARE.STEAM", localizedName: "other"))
        #expect(settings.matches(bundleIdentifier: "unrelated", localizedName: "STEAM"))
        #expect(!settings.matches(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode"))
    }

    @Test
    func nativeGamepadAppSettingsDisabledAppDoesNotMatch() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NativeGamepadAppSettings(userDefaults: defaults)
        let joyDshApp = settings.apps.first { $0.bundleIdentifier == "com.joydsh.desktop" }!
        settings.setAppEnabled(id: joyDshApp.id, isEnabled: false)

        #expect(!settings.matches(bundleIdentifier: "com.joydsh.desktop", localizedName: "JoyDSH"))

        settings.autoSwitchEnabled = false
        settings.setAppEnabled(id: joyDshApp.id, isEnabled: true)
        #expect(!settings.matches(bundleIdentifier: "com.joydsh.desktop", localizedName: "JoyDSH"))
    }

    @Test
    func nativeGamepadAppSettingsPersistsAndRestores() {
        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NativeGamepadAppSettings(userDefaults: defaults)
        settings.addApp(bundleIdentifier: "tech.keli.app", appName: "KeliApp")
        settings.autoSwitchEnabled = false

        let reloaded = NativeGamepadAppSettings(userDefaults: defaults)
        #expect(reloaded.autoSwitchEnabled == false)
        #expect(reloaded.apps.contains { $0.bundleIdentifier == "tech.keli.app" && $0.appName == "KeliApp" })
    }

    @Test
    func homeButtonDefaultsToToggleOperationModeAndMigrates() {
        let store = ControllerMappingStore.defaultMappings(for: .xbox)
        #expect(store[.home] == .toggleOperationMode)

        let suiteName = "JoyHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let customStore = ControllerMappingStore(userDefaults: defaults, storageKey: "testMappings.\(UUID().uuidString)")
        #expect(customStore.action(for: .home) == .toggleOperationMode)
        #expect(ControllerMappedAction.toggleOperationMode.displayName == "切换原生/映射模式" ||
                ControllerMappedAction.toggleOperationMode.displayName == "Toggle Native/Mapping Mode")
    }

    @Test
    func buttonBridgeSuppressesMappingsInNativeMode() {
        let bridge = ButtonBridge()
        var mouseClicks: [(MouseButton, Bool)] = []
        var stickMovements: [(Float, Float, Bool)] = []
        bridge.mouseButtonHandler = { mouseClicks.append(($0, $1)) }
        bridge.leftStickHandler = { stickMovements.append(($0, $1, $2)) }

        bridge.setOperationMode(.native)
        #expect(bridge.operationMode == .native)
        stickMovements.removeAll()
        mouseClicks.removeAll()

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true],
            primaryStick: JoyConStick(x: 0.5, y: 0.5),
            secondaryStick: .neutral
        ))

        #expect(mouseClicks.isEmpty)
        #expect(stickMovements.isEmpty)

        bridge.setOperationMode(.mapping)
        #expect(bridge.operationMode == .mapping)
        stickMovements.removeAll()
        mouseClicks.removeAll()

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.buttonA: true],
            primaryStick: JoyConStick(x: 0.5, y: 0.5),
            secondaryStick: .neutral
        ))

        #expect(!mouseClicks.isEmpty)
        #expect(!stickMovements.isEmpty)
    }

    @Test
    func buttonBridgeHomeButtonTogglesNativeModeAndFiresCallback() {
        let bridge = ButtonBridge()
        var toggledCount = 0
        bridge.onToggleOperationMode = { toggledCount += 1 }

        #expect(bridge.operationMode == .mapping)
        bridge.setOperationMode(.native)
        #expect(bridge.operationMode == .native)

        bridge.applyJoyConSnapshot(JoyConInputSnapshot(
            buttons: [.home: true],
            primaryStick: .neutral,
            secondaryStick: .neutral
        ))

        #expect(bridge.operationMode == .mapping)
        #expect(toggledCount == 1)
    }

    @Test
    func dashboardStatusDecodesOperationModeAndFrontmostApp() throws {
        let json = """
        {
          "state":"idle",
          "selected_slot":1,
          "slots":[],
          "controller":"Xbox Wireless Controller",
          "haptics":true,
          "accessibility":true,
          "microphone":false,
          "rp2040":false,
          "mode":"physical-codex-micro",
          "operation_mode":"native",
          "frontmost_app_name":"JoyDSH",
          "frontmost_app_bundle_id":"com.joydsh.desktop",
          "note":"auto-switch: JoyDSH",
          "ts":"2026-08-28T00:00:00Z"
        }
        """

        let status = try JSONDecoder().decode(DashboardStatus.self, from: Data(json.utf8))
        #expect(status.operationMode == "native")
        #expect(status.isNativeMode == true)
        #expect(status.activeOperationMode == .native)
        #expect(status.frontmostAppName == "JoyDSH")
        #expect(status.frontmostAppBundleID == "com.joydsh.desktop")
    }

    private func writeInt16(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let raw = UInt16(bitPattern: value)
        bytes[offset] = UInt8(raw & 0xff)
        bytes[offset + 1] = UInt8(raw >> 8)
    }

    private static func radialAngle(for direction: JoyConStick) -> Float {
        switch (direction.x, direction.y) {
        case (1, 0): 0
        case (0, -1): 0.25
        case (-1, 0): 0.5
        case (0, 1): 0.75
        default: -1
        }
    }
}
