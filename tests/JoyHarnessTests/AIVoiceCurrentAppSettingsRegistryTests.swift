import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceCurrentAppSettingsRegistryTests {
    @Test func modelActionUsesTheCapturedApplicationAndCannotReplayWithAnotherTarget() async throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let captured = try #require(registry.captureCurrentApplication())
        let command = try modelCommand(registry)
        #expect(command.capabilityID == "open_current_app_settings")
        #expect(command.parameters.isEmpty)
        // Simulate time spent understanding the request. The registry must
        // forward the saved target, not capture the newly focused app.
        probe.foreground = .init(processID: 900, bundleID: "test.other",
                                 launchDate: Date(timeIntervalSince1970: 300), name: "其他应用")
        let requestID = UUID()

        let first = await registry.execute(command, requestID: requestID, currentApplication: captured)
        let replay = await registry.execute(command, requestID: requestID, currentApplication: probe.foreground)

        #expect(probe.captureCount == 1)
        #expect(probe.receivedTargets == [captured])
        #expect(first == probe.dispatchedResult)
        #expect(first.status == .unconfirmed)
        #expect(replay == first)
    }

    @Test(arguments: ["application", "pid", "key", "keyCode", "modifiers", "bundleID", "launchDate", "path"])
    func extraParametersAreRejectedByTheParserAndRegistry(parameter: String) async throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let arguments = [parameter: "42"]
        let data = try responseData(arguments: arguments)

        #expect(throws: AIVoiceProviderError.self) {
            try AIVoiceProvider.parseIntent(data, capabilities: registry.descriptors)
        }
        // Also check the execution boundary if a caller bypasses parsing.
        let result = await registry.execute(
            .init(capabilityID: "open_current_app_settings", parameters: arguments),
            requestID: UUID(), currentApplication: probe.foreground
        )

        #expect(result.status == .failed)
        #expect(probe.captureCount == 0)
        #expect(probe.receivedTargets.isEmpty)
    }

    @Test func modelCannotSupplyTheApplicationOutsideItsArguments() throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let data = Data(#"{"kind":"action","capabilityID":"open_current_app_settings","arguments":{},"message":"打开设置","currentApplication":{"processID":42,"bundleID":"test.other"}}"#.utf8)

        #expect(throws: AIVoiceProviderError.self) {
            try AIVoiceProvider.parseIntent(data, capabilities: registry.descriptors)
        }
        #expect(probe.receivedTargets.isEmpty)
    }

    @Test func disablingAfterParsingBlocksDispatchAndRemovesTheCapabilityFromModelInput() async throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let command = try modelCommand(registry)
        registry.enabledCapabilityIDs.remove("open_current_app_settings")

        let result = await registry.execute(command, requestID: UUID(), currentApplication: probe.foreground)
        let data = try responseData()

        #expect(result.status == .failed)
        #expect(!registry.descriptors.contains { $0.id == "open_current_app_settings" })
        #expect(throws: AIVoiceProviderError.self) {
            try AIVoiceProvider.parseIntent(data, capabilities: registry.descriptors)
        }
        #expect(probe.captureCount == 0)
        #expect(probe.receivedTargets.isEmpty)
    }

    @Test func cancelledParsedActionNeverReachesTheInjectedExecutor() async throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let command = try modelCommand(registry)
        let target = probe.foreground
        let task = Task { @MainActor in
            await registry.execute(command, requestID: UUID(), currentApplication: target)
        }
        task.cancel()

        let result = await task.value

        #expect(result.status == .cancelled)
        #expect(probe.captureCount == 0)
        #expect(probe.receivedTargets.isEmpty)
    }

    @Test func missingCapturedTargetIsForwardedWithoutRecapturingAnApplication() async throws {
        let probe = CurrentAppSettingsRegistryProbe()
        let registry = AIVoiceCapabilityRegistry(currentAppSettings: probe)
        let command = try modelCommand(registry)

        let result = await registry.execute(command, requestID: UUID(), currentApplication: nil)

        #expect(probe.captureCount == 0)
        try #require(probe.receivedTargets.count == 1)
        #expect(probe.receivedTargets[0] == nil)
        #expect(result.status == .failed)
        #expect(result.message == "测试执行器没有收到提交时的目标")
    }

    private func modelCommand(_ registry: AIVoiceCapabilityRegistry) throws -> AIVoiceCommand {
        let intent = try AIVoiceProvider.parseIntent(responseData(), capabilities: registry.descriptors)
        return .init(capabilityID: try #require(intent.capabilityID), parameters: intent.arguments)
    }

    private func responseData(arguments: [String: String] = [:]) throws -> Data {
        let object: [String: Any] = [
            "kind": "action", "capabilityID": "open_current_app_settings",
            "arguments": arguments, "message": "打开当前应用的设置",
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@MainActor
private final class CurrentAppSettingsRegistryProbe: AIVoiceCurrentAppSettingsOpening {
    var foreground: AIVoiceForegroundApplication? = .init(
        processID: 42, bundleID: "test.editor", launchDate: Date(timeIntervalSince1970: 100), name: "编辑器"
    )
    var captureCount = 0
    var receivedTargets: [AIVoiceForegroundApplication?] = []
    let dispatchedResult = AIVoiceExecutionResult(status: .unconfirmed, message: "测试快捷键已发送；窗口尚未确认")

    func captureTarget() -> AIVoiceForegroundApplication? {
        captureCount += 1
        return foreground
    }

    func execute(target: AIVoiceForegroundApplication?) async -> AIVoiceExecutionResult {
        receivedTargets.append(target)
        guard target != nil else {
            return .init(status: .failed, message: "测试执行器没有收到提交时的目标")
        }
        return dispatchedResult
    }
}
