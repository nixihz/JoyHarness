import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceExpandedCapabilitiesTests {
    @Test func modelOutputUsesDefaultRelativeStepAndCannotReplayIt() async throws {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        let data = Data(#"{"kind":"action","capabilityID":"adjust_volume","arguments":{"direction":"down"},"message":"调小声音"}"#.utf8)
        let intent = try AIVoiceProvider.parseIntent(data, capabilities: registry.descriptors)
        let command = AIVoiceCommand(capabilityID: try #require(intent.capabilityID), parameters: intent.arguments)
        let id = UUID()
        let first = await registry.execute(command, requestID: id)
        let second = await registry.execute(command, requestID: id)
        #expect(first == second)
        #expect(probe.system == [.volumeAdjust(-10)])
    }

    @Test func percentageTargetsRemainDistinctFromRelativeChanges() async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        _ = await registry.execute(.init(capabilityID: "set_brightness", parameters: ["percent": "20"]), requestID: UUID())
        _ = await registry.execute(.init(capabilityID: "adjust_brightness", parameters: ["direction": "up", "amount": "20"]), requestID: UUID())
        #expect(probe.system == [.brightnessSet(20), .brightnessAdjust(20)])
    }

    @Test(arguments: ["-1", "101", "NaN", "inf", "0.5", "50%", "1;open /tmp", "", "999999999999999999999999"])
    func invalidPercentagesNeverReachHardware(value: String) async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        for capability in ["set_volume", "set_brightness"] {
            let result = await registry.execute(.init(capabilityID: capability, parameters: ["percent": value]), requestID: UUID())
            #expect(result.status == .failed)
        }
        #expect(probe.system.isEmpty)
    }

    @Test func malformedCommandsAndArbitraryPathsCannotDispatch() async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        let invalid: [AIVoiceCommand] = [
            .init(capabilityID: "adjust_volume", parameters: ["direction": "louder"]),
            .init(capabilityID: "adjust_volume", parameters: ["direction": "up", "amount": "0"]),
            .init(capabilityID: "adjust_volume", parameters: ["direction": "down", "amount": "-10"]),
            .init(capabilityID: "set_mute", parameters: ["muted": "toggle"]),
            .init(capabilityID: "get_volume", parameters: ["device": "another"]),
            .init(capabilityID: "open_folder", parameters: ["folder": "../../Library"]),
            .init(capabilityID: "open_screenshot_tool", parameters: ["path": "/tmp/capture.png"]),
            .init(capabilityID: "media_control", parameters: ["action": "pause"]),
            .init(capabilityID: "media_control", parameters: ["action": "next", "player": "unknown"]),
        ]
        for command in invalid {
            let result = await registry.execute(command, requestID: UUID())
            #expect(result.status == .failed)
        }
        #expect(probe.system.isEmpty)
        #expect(probe.desktop.isEmpty)
    }

    @Test func disabledCapabilityIsRemovedFromModelCatalogAndRecheckedBeforeExecution() async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        let command = AIVoiceCommand(capabilityID: "set_mute", parameters: ["muted": "true"])
        guard case .ready = registry.resolve(command) else { Issue.record("静音应可准备"); return }
        registry.enabledCapabilityIDs.remove("set_mute")
        #expect(!registry.descriptors.contains { $0.id == "set_mute" })
        let denied = await registry.execute(command, requestID: UUID())
        #expect(denied.status == .failed)
        #expect(probe.system.isEmpty)
    }

    @Test func desktopRequestUsesValidatedEnumAndPreservesUnconfirmedResult() async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        let result = await registry.execute(.init(capabilityID: "open_folder", parameters: ["folder": "downloads"]), requestID: UUID())
        #expect(probe.desktop == [.openFolder(.downloads)])
        #expect(result.status == .unconfirmed)
    }

    @Test func cancellationBeforeHardwareDispatchMakesNoChange() async {
        let probe = VoiceActionProbe()
        let registry = AIVoiceCapabilityRegistry(systemControls: probe, desktopActions: probe)
        let task = Task { @MainActor in
            await registry.execute(.init(capabilityID: "set_volume", parameters: ["percent": "90"]), requestID: UUID())
        }
        task.cancel()
        let result = await task.value
        #expect(result.status == .cancelled)
        #expect(probe.system.isEmpty)
    }
}

@MainActor
private final class VoiceActionProbe: AIVoiceSystemControlling, AIVoiceDesktopActing {
    var system: [AIVoiceSystemControlAction] = []
    var desktop: [AIVoiceDesktopAction] = []
    func execute(_ action: AIVoiceSystemControlAction) async -> AIVoiceExecutionResult {
        system.append(action)
        return .init(status: .succeeded, message: "已完成")
    }
    func execute(_ action: AIVoiceDesktopAction) async -> AIVoiceExecutionResult {
        desktop.append(action)
        return .init(status: .unconfirmed, message: "已发送请求")
    }
}
