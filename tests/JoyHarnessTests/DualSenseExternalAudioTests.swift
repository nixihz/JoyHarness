import Foundation
import GameController
import Testing
@testable import JoyHarness

private final class ExternalAudioTestController: GCController {
    private let pad = GCDualSenseGamepad()
    override var extendedGamepad: GCExtendedGamepad? { pad }
    override var vendorName: String? { "DualSense Wireless Controller" }
}

@MainActor
struct DualSenseExternalAudioTests {
    @Test func multipleControllersKeepOrdinaryPSButRejectUnattributedVoice() async throws {
        let first = ExternalAudioTestController(), second = ExternalAudioTestController()
        var controllers: [GCController] = [first]
        let hub = ControllerHub(mappingProvider: { _, _ in .disabled },
            controllerProvider: { controllers }, currentControllerProvider: { first })
        defer { hub.stop() }
        var presented = 0, began = 0
        hub.onHarnessSwitcherPresent = { presented += 1 }
        hub.onAIVoiceBegin = { began += 1 }
        hub.aiVoiceEnabled = true
        hub.refreshControllers()
        hub.setExternalAudioState(available: true, capturing: false)
        controllers.append(second)
        hub.refreshControllers()
        for controller in controllers {
            let home = try #require(controller.extendedGamepad?.buttonHome)
            home.pressedChangedHandler?(home, 1, true)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            home.pressedChangedHandler?(home, 0, false)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            hub.finishHarnessSwitcher()
        }
        hub.handleExternalAudioControl(.ps(.init(isPressed: false, leftTriggerValue: 0, timestamp: 1)))
        hub.handleExternalAudioControl(.ps(.init(isPressed: true, leftTriggerValue: 1, timestamp: 1.02)))
        #expect(presented == 2)
        #expect(began == 0)
    }

    // Fixed packets sealed independently using Python binascii, not the parser under test.
    private let neutral = dualSenseFixtureBytes("31018080808000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b8d2fc3")
    private let options = dualSenseFixtureBytes("310180808080000000082000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010638124")
    private let chord = dualSenseFixtureBytes("310180808080c8000008000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001fa16269")
    private let held = dualSenseFixtureBytes("310180808080c800000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c3cbd139")

    @Test func optionsStillTapsExactlyOncePerPressWhileDriverOwnsController() {
        var router = DualSenseExternalControlRouter()
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { $0 == .menu ? .pushToTalk : .disabled })
        defer { bridge.stop() }
        bridge.usesExternalVoiceControls = true
        var keys: [Int] = []
        bridge.keyHandler = { key, action in
            #expect(key == "ACT10"); keys.append(action); return true
        }
        func feed(_ packet: [UInt8], _ t: Double) {
            for effect in router.receive(packet, timestamp: t, now: t) {
                if effect == .optionsTap { bridge.tapExternalVoiceShortcut() }
            }
        }
        feed(neutral, 1)
        feed(options, 1.02)
        bridge.setExternalAudioCaptureActive(true)
        feed(options, 1.04) // held key/heartbeat must not retrigger
        feed(neutral, 1.06)
        feed(options, 1.08) // second press can stop the external recorder
        feed(options, 1.10)
        #expect(keys == [1, 0, 1, 0])
    }

    @Test func aiReleaseSurvivesExclusiveCaptureAndGameControllerEchoIsSuppressed() async throws {
        let controller = GCController.withExtendedGamepad()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { $0 == .menu ? .pushToTalk : .disabled })
        bridge.attachController(controller)
        defer { bridge.stop() }
        bridge.usesExternalVoiceControls = true
        bridge.aiVoiceEnabled = true
        var now = 1.0, began = 0, cancelled = 0
        var released: [Double] = [], keys: [Int] = []
        bridge.homeButtonClock = { now }
        bridge.onAIVoiceBegin = { began += 1 }
        bridge.onAIVoiceCancel = { cancelled += 1 }
        bridge.onAIVoiceRelease = { released.append($0) }
        bridge.keyHandler = { _, action in keys.append(action); return true }
        var router = DualSenseExternalControlRouter()
        func feed(_ bytes: [UInt8], _ t: Double) {
            now = t
            for effect in router.receive(bytes, timestamp: t, now: t) {
                switch effect {
                case .ps(let sample): bridge.handleExternalAudioPSInput(sample)
                case .optionsTap: bridge.tapExternalVoiceShortcut()
                case .cancelTap: bridge.cancelExternalVoiceInput()
                case .interrupted: bridge.interruptDualSensePSInput(allowLegacyFallback: false)
                }
            }
        }
        feed(neutral, 1)
        feed(chord, 1.02)
        #expect(began == 1)
        bridge.setExternalAudioCaptureActive(true)
        feed(held, 1.04) // PS released; L2 still held
        #expect(released.isEmpty && cancelled == 0)
        feed(neutral, 1.06)
        #expect(released == [1.06] && cancelled == 0)
        bridge.setExternalAudioCaptureActive(false)
        // The same Options press from GameController must not produce a second shortcut.
        gamepad.buttonMenu.setValue(1)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonMenu)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(keys.isEmpty)
        feed(options, 1.08)
        #expect(keys == [1, 0])
    }

    @Test func staleCorruptAudioAndReconnectHeldKeysCannotStartVoice() {
        var router = DualSenseExternalControlRouter()
        #expect(router.receive(options, timestamp: 1, now: 1).isEmpty)
        _ = router.receive(neutral, timestamp: 1.02, now: 1.02)
        var corrupt = options; corrupt[20] ^= 1
        #expect(router.receive(corrupt, timestamp: 1.04, now: 1.04).isEmpty)
        #expect(router.receive(options, timestamp: 1.04, now: 2).isEmpty)
        var audio = options; audio[1] = 2
        #expect(router.receive(audio, timestamp: 1.06, now: 1.06).isEmpty)
        #expect(router.receive(options, timestamp: 2, now: 2) == [.interrupted])
        _ = router.receive(neutral, timestamp: 2.02, now: 2.02)
        #expect(router.receive(options, timestamp: 2.04, now: 2.04).contains(.optionsTap))
        #expect(router.receive(options, timestamp: 2.04, now: 2.04).isEmpty)
    }

    @Test func cancelDuringExclusiveCaptureWinsOverSimultaneousTriggerRelease() {
        // Circle held, L2 released: sealed with Python binascii independently.
        let cancel = dualSenseFixtureBytes("31018080808000000048000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009e873e96")
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { _ in .mouseLeft })
        defer { bridge.stop() }
        bridge.usesExternalVoiceControls = true
        bridge.aiVoiceEnabled = true
        var now = 1.0, began = 0, cancelled = 0, submitted = 0, mapped = 0
        bridge.homeButtonClock = { now }
        bridge.onAIVoiceBegin = { began += 1 }
        bridge.onAIVoiceCancel = { cancelled += 1 }
        bridge.onAIVoiceRelease = { _ in submitted += 1 }
        bridge.mouseButtonHandler = { _, _ in mapped += 1 }
        bridge.inputInterceptor = { input, pressed in
            guard input == .buttonB else { return false }
            if pressed { bridge.cancelAIVoiceInput() }
            return true
        }
        var router = DualSenseExternalControlRouter()
        func feed(_ packet: [UInt8], _ timestamp: Double) {
            now = timestamp
            for effect in router.receive(packet, timestamp: timestamp, now: timestamp) {
                switch effect {
                case .ps(let sample): bridge.handleExternalAudioPSInput(sample)
                case .cancelTap: bridge.cancelExternalVoiceInput()
                case .optionsTap: bridge.tapExternalVoiceShortcut()
                case .interrupted: bridge.interruptDualSensePSInput(allowLegacyFallback: false)
                }
            }
        }
        feed(neutral, 1)
        feed(chord, 1.02)
        bridge.setExternalAudioCaptureActive(true)
        feed(held, 1.04)
        feed(cancel, 1.06)
        feed(cancel, 1.08)
        feed(neutral, 1.10)
        #expect(began == 1 && cancelled == 1 && submitted == 0)
        #expect(mapped == 0)
    }

    @Test func reportsFlushedAfterMicrophoneCloseWaitForNeutralBeforeMapping() async throws {
        let controller = ExternalAudioTestController()
        let gamepad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { input in
            input == .buttonY ? .screenshotTool : .disabled
        })
        bridge.attachController(controller)
        defer { bridge.stop() }
        var screenshots = 0
        var now = 1.0
        bridge.homeButtonClock = { now }
        bridge.systemKeyHandler = { key, pressed in
            if key == .screenshotTool, pressed { screenshots += 1 }
        }

        bridge.setExternalAudioCaptureActive(true)
        // The driver releases HID while this stale report is still reflected
        // by GameController. It must not become a screenshot shortcut.
        gamepad.buttonY.setValue(1)
        bridge.setExternalAudioCaptureActive(false)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonY)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(screenshots == 0)

        now = 1.3
        gamepad.buttonY.setValue(0)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonY)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        gamepad.buttonY.setValue(1)
        gamepad.valueChangedHandler?(gamepad, gamepad.buttonY)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(screenshots == 1)
    }

    @Test(arguments: [0.1, 0.3, 1.0], [false, true])
    func lateReportAfterNeutralCloseIsStillQuarantined(delay: Double, earlyNeutral: Bool) async throws {
        let controller = ExternalAudioTestController()
        let gamepad = try #require(controller.extendedGamepad)
        let create = try #require(gamepad.buttonOptions)
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { input in
            input == .options ? .screenshotTool : .disabled
        })
        bridge.attachController(controller)
        bridge.usesExternalVoiceControls = true
        defer { bridge.stop() }
        var screenshots = 0
        var now = 1.0
        bridge.homeButtonClock = { now }
        bridge.systemKeyHandler = { key, pressed in
            if key == .screenshotTool, pressed { screenshots += 1 }
        }

        // The GameController snapshot is neutral when capture ends, but the
        // HID release can still enqueue a non-neutral report afterwards.
        bridge.setExternalAudioCaptureActive(true)
        bridge.setExternalAudioCaptureActive(false)
        if earlyNeutral {
            // Neutral callbacks in the flush window cannot rearm mapping.
            gamepad.valueChangedHandler?(gamepad, create)
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        // Exercise both sides of the old 250ms cutoff, including a full second
        // of delay, with the actual physical Create/screenshot mapping.
        now = 1.0 + delay
        create.setValue(1)
        gamepad.valueChangedHandler?(gamepad, create)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(screenshots == 0)

        now = 1.0 + max(delay, 0.3) + 0.1
        create.setValue(0)
        gamepad.valueChangedHandler?(gamepad, create)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        create.setValue(1)
        gamepad.valueChangedHandler?(gamepad, create)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(screenshots == 1)
    }

    @Test func neutralRecoveryToleratesStickDriftAndPreservesNextCreatePress() async throws {
        let controller = ExternalAudioTestController()
        let gamepad = try #require(controller.extendedGamepad)
        let create = try #require(gamepad.buttonOptions)
        let bridge = ButtonBridge(controllerFamily: .dualSense, mappingProvider: { input in
            input == .options ? .screenshotTool : .disabled
        })
        bridge.attachController(controller)
        defer { bridge.stop() }
        var now = 1.0, screenshots = 0
        bridge.homeButtonClock = { now }
        bridge.systemKeyHandler = { key, pressed in
            if key == .screenshotTool, pressed { screenshots += 1 }
        }
        bridge.setExternalAudioCaptureActive(true)
        // Within the right stick's 0.15 radial dead zone, above the synthetic
        // direction button's 0.1 value. This must still count as neutral.
        gamepad.rightThumbstick.xAxis.setValue(0.12)
        bridge.setExternalAudioCaptureActive(false)
        // A fresh neutral callback must rearm mapping despite harmless drift.
        now = 1.3
        create.setValue(0)
        gamepad.valueChangedHandler?(gamepad, create)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        create.setValue(1)
        gamepad.valueChangedHandler?(gamepad, create)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(screenshots == 1)
    }
}
