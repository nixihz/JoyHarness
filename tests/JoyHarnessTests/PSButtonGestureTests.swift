import Foundation
import GameController
import Testing
@testable import JoyHarness

struct PSButtonGestureTests {
    private func sample(_ pressed: Bool, _ time: TimeInterval, l2: Float = 0,
                        canStart: Bool = true) -> DualSensePSInputSample {
        DualSensePSInputSample(isPressed: pressed, leftTriggerValue: l2,
                              timestamp: time, allowsVoiceStart: canStart)
    }

    private func armed() -> PSButtonGesture {
        var gesture = PSButtonGesture()
        _ = gesture.ingest(sample(false, -0.01), voiceEnabled: true)
        return gesture
    }

    @Test(arguments: [false, true])
    func ordinaryPSAlwaysShowsSwitcherOnDown(enabled: Bool) {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0), voiceEnabled: enabled) == [.showSwitcher])
        for tick in 1...80 {
            #expect(gesture.ingest(sample(true, Double(tick) / 100), voiceEnabled: enabled).isEmpty)
        }
        #expect(gesture.ingest(sample(false, 0.81), voiceEnabled: enabled).isEmpty)
    }

    @Test func l2ThenPSStartsImmediatelyAndOnlyL2ReleaseSubmits() {
        var gesture = armed()
        #expect(gesture.ingest(sample(false, 0, l2: 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.05, l2: 0.8), voiceEnabled: true) == [.beginVoice])
        #expect(gesture.ingest(sample(false, 0.06, l2: 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.2, l2: 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.3, l2: 0.1), voiceEnabled: true) == [.submitVoice])
        #expect(gesture.ingest(sample(false, 0.31), voiceEnabled: true).isEmpty)
    }

    @Test func triggerThresholdAndReleaseWhilePSRemainsDownNeverOpenSwitcher() {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0, l2: 0.55), voiceEnabled: true) == [.beginVoice])
        #expect(gesture.ingest(sample(true, 0.1, l2: 0.55), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.2, l2: 0.54), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.3), voiceEnabled: true) == [.submitVoice])
        #expect(gesture.ingest(sample(false, 0.4), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.5), voiceEnabled: true) == [.showSwitcher])
    }

    @Test func disabledChordAndEnablingMidChordStayConsumedUntilBothNeutral() {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0, l2: 0.8), voiceEnabled: false).isEmpty)
        #expect(gesture.ingest(sample(false, 0.1, l2: 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.2, l2: 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.3), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.4), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.5), voiceEnabled: true) == [.showSwitcher])
    }

    @Test func l2PressedAfterPSDoesNotChangeTheChosenBranch() {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0), voiceEnabled: true) == [.showSwitcher])
        #expect(gesture.ingest(sample(true, 0.1, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.2, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.3, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.4), voiceEnabled: true).isEmpty)
    }

    @Test func repeatedPSDuringRecordingNeverRestartsOrReopensSwitcher() {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0, l2: 1), voiceEnabled: true) == [.beginVoice])
        #expect(gesture.ingest(sample(false, 0.1, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.2, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.3, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.4), voiceEnabled: true) == [.submitVoice])
    }

    @Test func nativeModeAndExistingOverlayTakePriorityOverChord() {
        var native = armed()
        #expect(native.ingest(sample(true, 0, l2: 1), voiceEnabled: true, priority: .nativeMode) == [.restoreMapping])
        #expect(native.ingest(sample(false, 0.1, l2: 1), voiceEnabled: true).isEmpty)
        #expect(native.ingest(sample(false, 0.2), voiceEnabled: true).isEmpty)
        var overlay = armed()
        #expect(overlay.ingest(sample(true, 0, l2: 1), voiceEnabled: true, priority: .intercepted).isEmpty)
        #expect(overlay.ingest(sample(false, 0.1), voiceEnabled: true).isEmpty)
    }

    @Test func lostReportsWhilePSReleasedCancelVoiceAndRequireBothNeutral() {
        var gesture = armed()
        _ = gesture.ingest(sample(true, 0, l2: 1), voiceEnabled: true)
        _ = gesture.ingest(sample(false, 0.1, l2: 1), voiceEnabled: true)
        #expect(gesture.ingest(sample(false, 0.5, l2: 1), voiceEnabled: true) == [.cancelVoice])
        #expect(gesture.ingest(sample(true, 0.6, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.7), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.8), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.9), voiceEnabled: true) == [.showSwitcher])
    }

    @Test func cancelAndInterruptNeverSubmitAndRequireFullTriggerRelease() {
        for disconnect in [false, true] {
            var gesture = armed()
            _ = gesture.ingest(sample(true, 0, l2: 1), voiceEnabled: true)
            _ = gesture.ingest(sample(false, 0.1, l2: 1), voiceEnabled: true)
            #expect((disconnect ? gesture.interrupt() : gesture.cancel()) == [.cancelVoice])
            #expect(gesture.ingest(sample(false, 0.2, l2: 0.4), voiceEnabled: true).isEmpty)
            #expect(gesture.ingest(sample(true, 0.3, l2: 1), voiceEnabled: true).isEmpty)
            #expect(gesture.ingest(sample(false, 0.4), voiceEnabled: true).isEmpty)
            #expect(gesture.ingest(sample(true, 0.5, l2: 1), voiceEnabled: true) == [.beginVoice])
        }
    }

    @Test func stalePressCannotStartOnLaterFreshHeartbeat() {
        var gesture = armed()
        #expect(gesture.ingest(sample(true, 0, l2: 1, canStart: false), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(true, 0.1, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.2, l2: 1), voiceEnabled: true).isEmpty)
        #expect(gesture.ingest(sample(false, 0.3), voiceEnabled: true).isEmpty)
    }

    @Test(arguments: [false, true])
    func freshBatchedPressStartsWhileTriggerRemainsHeld(psReleased: Bool) {
        let mailbox = DualSensePSInputMailbox()
        _ = mailbox.append(sample(false, -0.01))
        _ = mailbox.append(sample(true, 0, l2: 1))
        _ = mailbox.append(sample(!psReleased, 0.05, l2: 1))
        var gesture = PSButtonGesture()
        let effects = mailbox.drain(now: 0.1).flatMap { gesture.ingest($0, voiceEnabled: true) }
        #expect(effects == [.beginVoice])
        #expect(gesture.ingest(sample(false, 0.15), voiceEnabled: true) == [.submitVoice])
    }

    @Test func completedExpiredOrInterruptedBatchesNeverStartVoice() {
        let cases: [(samples: [DualSensePSInputSample], now: TimeInterval)] = [
            ([sample(false, -0.01), sample(true, 0, l2: 1), sample(false, 0.1)], 0.15),
            ([sample(false, -0.01), sample(true, 0, l2: 1), sample(false, 0.1, l2: 1)], 0.4),
            ([sample(false, -0.01), sample(true, 0, l2: 1), sample(false, 0.3, l2: 1)], 0.31),
            ([sample(false, -0.01), sample(true, 0, l2: 1), sample(true, 0.1), sample(true, 0.2, l2: 1)], 0.21),
        ]
        for entry in cases {
            let mailbox = DualSensePSInputMailbox()
            for sample in entry.samples { _ = mailbox.append(sample) }
            var gesture = PSButtonGesture()
            let effects = mailbox.drain(now: entry.now).flatMap { gesture.ingest($0, voiceEnabled: true) }
            #expect(!effects.contains(.beginVoice))
            #expect(!effects.contains(.submitVoice))
        }
    }

    @Test func deliveryRechecksAgeAndAnyL2ReleaseAfterDraining() throws {
        let mailbox = DualSensePSInputMailbox()
        _ = mailbox.append(sample(false, -0.01))
        _ = mailbox.append(sample(true, 0, l2: 1))
        _ = mailbox.append(sample(false, 0.05, l2: 1))
        let pressedSample = mailbox.drain(now: 0.1).first { $0.isPressed }
        let down = try #require(pressedSample)
        #expect(down.allowsVoiceStart)
        #expect(mailbox.canStartVoice(down, now: 0.1))
        #expect(!mailbox.canStartVoice(down, now: 0.26))
        _ = mailbox.append(sample(false, 0.15))
        #expect(!mailbox.canStartVoice(down, now: 0.16))
        // A later trigger press cannot make this old chord valid again.
        _ = mailbox.append(sample(false, 0.17, l2: 1))
        #expect(!mailbox.canStartVoice(down, now: 0.18))
    }

    @Test func deliveryRejectsReportGapAndResetAfterDraining() throws {
        for reset in [false, true] {
            let mailbox = DualSensePSInputMailbox()
            _ = mailbox.append(sample(false, -0.01))
            _ = mailbox.append(sample(true, 0, l2: 1))
            let pressedSample = mailbox.drain(now: 0.05).first { $0.isPressed }
            let down = try #require(pressedSample)
            #expect(down.allowsVoiceStart)
            if reset { mailbox.reset(now: 0.1) }
            else { _ = mailbox.append(sample(false, 0.3, l2: 1)) }
            #expect(!mailbox.canStartVoice(down, now: 0.1))
        }
    }

    @Test func USBAndBluetoothReportsReadPSAndL2FromTheSameFrame() {
        var usb = [UInt8](repeating: 0, count: 64)
        usb[0] = 0x01; usb[5] = 204; usb[10] = 1
        let usbSample = usb.withUnsafeBufferPointer {
            DualSenseInputReport.psInputSample(in: $0, transport: .usb, timestamp: 10)
        }
        #expect(usbSample?.isPressed == true)
        #expect(usbSample?.leftTriggerValue == 0.8)
        var bluetooth = [UInt8](repeating: 0, count: 78)
        bluetooth[0] = 0x31; bluetooth[1] = 0x01; bluetooth[6] = 0; bluetooth[11] = 1
        let bluetoothSample = bluetooth.withUnsafeBufferPointer {
            DualSenseInputReport.psInputSample(in: $0, transport: .bluetooth, timestamp: 11)
        }
        #expect(bluetoothSample?.isPressed == true)
        #expect(bluetoothSample?.leftTriggerValue == 0)
        let truncated = Array(usb.prefix(5)).withUnsafeBufferPointer {
            DualSenseInputReport.psInputSample(in: $0, transport: .usb, timestamp: 12)
        }
        #expect(truncated == nil)
    }
}

private final class VoiceTestDualSenseController: GCController {
    private let pad = GCDualSenseGamepad()
    override var extendedGamepad: GCExtendedGamepad? { pad }
    override var vendorName: String? { "DualSense Wireless Controller" }
}

@MainActor
struct PSButtonBridgeTests {
    private func send(_ bridge: ButtonBridge, _ pressed: Bool, _ time: Double, l2: Float = 0) {
        bridge.handleDualSensePSInput(.init(isPressed: pressed, leftTriggerValue: l2, timestamp: time))
    }

    @Test func voiceReleaseCarriesL2PhysicalTimestampWithoutAlsoCallingLegacyEnd() {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        bridge.homeButtonClock = { 40 }
        var releasedAt: [TimeInterval] = []
        var legacyEnds = 0, began = 0
        bridge.onAIVoiceBegin = { began += 1 }
        bridge.onAIVoiceRelease = { releasedAt.append($0) }
        bridge.onAIVoiceEnd = { legacyEnds += 1 }
        send(bridge, false, -0.01)
        send(bridge, true, 0, l2: 1)
        #expect(began == 1)
        bridge.setAIVoiceCaptureActive(true)
        send(bridge, false, 0.1, l2: 1)
        #expect(releasedAt.isEmpty)
        send(bridge, false, 0.2, l2: 1)
        send(bridge, false, 0.325)
        send(bridge, false, 0.4)
        #expect(releasedAt == [0.325])
        #expect(legacyEnds == 0)
        bridge.resetInputState()
    }

    @Test func duplicateGameControllerAndFilteredHIDCopiesCannotStartOrSubmitAgain() {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        var began = 0, submitted = 0, switched = 0
        bridge.onAIVoiceBegin = { began += 1 }
        bridge.onAIVoiceEnd = { submitted += 1 }
        bridge.onHarnessSwitcherPresent = { switched += 1 }
        send(bridge, false, -0.01)
        send(bridge, true, 0, l2: 1)
        bridge.handleHomeButton(isPressed: true)
        send(bridge, false, 0.1, l2: 1)
        bridge.handleRawHomeButton(isPressed: false)
        bridge.handleHomeButton(isPressed: false)
        send(bridge, true, 0.2, l2: 1)
        send(bridge, true, 0.3)
        send(bridge, false, 0.4)
        #expect(began == 1)
        #expect(submitted == 1)
        #expect(switched == 0)
        bridge.resetInputState()
    }

    @Test func inputResetCancelsRecordingAndLateReleaseDoesNotSubmit() {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        var cancelled = 0, submitted = 0
        bridge.onAIVoiceCancel = { cancelled += 1 }
        bridge.onAIVoiceEnd = { submitted += 1 }
        send(bridge, false, -0.01)
        send(bridge, true, 0, l2: 1)
        send(bridge, false, 0.1, l2: 1)
        bridge.resetInputState()
        send(bridge, false, 0.2)
        #expect(cancelled == 1)
        #expect(submitted == 0)
    }

    @Test func disablingVoiceAfterPSTapCancelsAndConsumesBothHeldInputs() {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        var cancelled = 0, submitted = 0, switched = 0
        bridge.onAIVoiceCancel = { cancelled += 1 }
        bridge.onAIVoiceEnd = { submitted += 1 }
        bridge.onHarnessSwitcherPresent = { switched += 1 }
        send(bridge, false, -0.01)
        send(bridge, true, 0, l2: 1)
        send(bridge, false, 0.1, l2: 1)
        bridge.aiVoiceEnabled = false
        send(bridge, true, 0.2, l2: 1)
        send(bridge, true, 0.3)
        #expect(cancelled == 1)
        #expect(submitted == 0)
        #expect(switched == 0)
        send(bridge, false, 0.4)
        send(bridge, true, 0.5)
        #expect(switched == 1)
        send(bridge, false, 0.6)
    }

    @Test func fallbackPSOpensImmediatelyButNeverGuessesVoiceFromChord() throws {
        let controller = VoiceTestDualSenseController()
        let pad = try #require(controller.extendedGamepad)
        let bridge = ButtonBridge()
        bridge.attachController(controller)
        defer { bridge.stop() }
        bridge.aiVoiceEnabled = true
        var switched = 0, began = 0
        bridge.onHarnessSwitcherPresent = { switched += 1 }
        bridge.onAIVoiceBegin = { began += 1 }
        bridge.handleHomeButton(isPressed: true)
        #expect(switched == 1)
        bridge.handleHomeButton(isPressed: false)
        #expect(switched == 1)
        pad.leftTrigger.setValue(1)
        bridge.handleHomeButton(isPressed: true)
        pad.leftTrigger.setValue(0)
        bridge.handleHomeButton(isPressed: false)
        #expect(switched == 1)
        #expect(began == 0)
    }

    @Test func watchdogContinuesAfterPSReleaseWhileL2HoldsVoice() async throws {
        let bridge = ButtonBridge()
        bridge.aiVoiceEnabled = true
        var cancelled = 0, submitted = 0
        bridge.onAIVoiceCancel = { cancelled += 1 }
        bridge.onAIVoiceEnd = { submitted += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        send(bridge, false, now - 0.02)
        send(bridge, true, now - 0.01, l2: 1)
        send(bridge, false, now, l2: 1)
        try await Task.sleep(for: .milliseconds(350))
        #expect(cancelled == 1)
        #expect(submitted == 0)
        send(bridge, false, ProcessInfo.processInfo.systemUptime)
        #expect(submitted == 0)
        bridge.resetInputState()
    }
}
