import CoreAudio
import CoreGraphics
import Foundation
import Testing
@testable import JoyHarness

struct JoyHarnessTests {
    @Test
    func appVersionLoadsFromTheBundledVersionResource() {
        #expect(AppVersion.current == "0.2.3")
        #expect(AppVersion.displayName == "Joy Harness v0.2.3")
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
        #expect(ControllerMappingStore.defaultMappings[.touchpadButton] == .pushToTalk)
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
            ControllerFamily.dualSense.dashboardArtworkResource ==
                "controller-dashboard-dualsense-transparent"
        )
        #expect(ControllerFamily.xbox.dashboardArtworkResource == "controller-dashboard")
        #expect(ControllerFamily.dualShock.dashboardArtworkResource == nil)
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
}
