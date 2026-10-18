import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceSystemAppearanceTests {
    @Test(arguments: [AIVoiceSystemAppearance.light, .dark])
    func explicitModeDisablesAutoEvenWhenTheCurrentColorAlreadyMatches(_ mode: AIVoiceSystemAppearance) async throws {
        let environment = AppearanceEnvironmentProbe(automatic: true, dark: mode == .dark)
        let controller = AIVoiceMacSystemAppearance(environment: environment, verificationDelayNanoseconds: 0)
        let registry = AIVoiceCapabilityRegistry(systemAppearance: controller)
        let json = """
        {"kind":"action","capabilityID":"set_system_appearance","arguments":{"mode":"\(mode.rawValue)"},"message":"切换系统外观"}
        """
        let intent = try AIVoiceProvider.parseIntent(Data(json.utf8), capabilities: registry.descriptors)
        let result = await registry.execute(.init(capabilityID: try #require(intent.capabilityID), parameters: intent.arguments), requestID: UUID())
        #expect(result.status == .succeeded)
        #expect(environment.changes == [.automatic(false), .dark(mode == .dark)])
        #expect(!environment.state.isAutomatic)
        #expect(environment.state.isDark == (mode == .dark))
        #expect(environment.reads == 2)
    }

    @Test(arguments: [false, true])
    func autoLeavesTheCurrentColorToTheSystemAndIsNotReplayed(dark: Bool) async {
        let environment = AppearanceEnvironmentProbe(automatic: false, dark: dark)
        let controller = AIVoiceMacSystemAppearance(environment: environment, verificationDelayNanoseconds: 0)
        let registry = AIVoiceCapabilityRegistry(systemAppearance: controller)
        let command = AIVoiceCommand(capabilityID: "set_system_appearance", parameters: ["mode": "auto"])
        let id = UUID()
        let first = await registry.execute(command, requestID: id)
        // A later manual setting must not be overwritten by replaying the old request.
        environment.state = .init(isAutomatic: false, isDark: dark)
        let replay = await registry.execute(command, requestID: id)
        #expect(first.status == .succeeded)
        #expect(replay == first)
        #expect(environment.changes == [.automatic(true)])
        #expect(!environment.state.isAutomatic)
        #expect(environment.state.isDark == dark)
    }

    @Test func invalidOrDisabledCommandsNeverAccessSystemAppearance() async {
        let environment = AppearanceEnvironmentProbe(automatic: false, dark: false)
        let registry = AIVoiceCapabilityRegistry(systemAppearance: AIVoiceMacSystemAppearance(environment: environment))
        for parameters in [["mode": "system"], ["mode": "night_shift"], ["mode": "toggle"],
                           ["mode": "dark", "target": "Joy Harness"], [:]] {
            let result = await registry.execute(.init(capabilityID: "set_system_appearance", parameters: parameters), requestID: UUID())
            #expect(result.status == .failed)
        }
        let valid = AIVoiceCommand(capabilityID: "set_system_appearance", parameters: ["mode": "dark"])
        guard case .ready = registry.resolve(valid) else { Issue.record("应接受深色参数"); return }
        registry.enabledCapabilityIDs.remove("set_system_appearance")
        #expect(!registry.descriptors.contains { $0.id == "set_system_appearance" })
        let disabled = await registry.execute(valid, requestID: UUID())
        #expect(disabled.status == .failed)
        #expect(environment.reads == 0)
        #expect(environment.changes.isEmpty)
    }

    @Test func acceptedWritesWithMismatchedReadbackAreNotSuccessAndAreNotRetried() async {
        let environment = AppearanceEnvironmentProbe(automatic: false, dark: false)
        environment.ignoresWrites = true
        let controller = AIVoiceMacSystemAppearance(environment: environment, verificationAttempts: 3, verificationDelayNanoseconds: 0)
        let result = await controller.execute(.dark)
        #expect(result.status == .unconfirmed)
        #expect(environment.changes == [.dark(true)])
        #expect(environment.reads == 4)
    }

    @Test func partialFailureAfterDisablingAutoDoesNotClaimAnUnchangedSystem() async {
        let environment = AppearanceEnvironmentProbe(automatic: true, dark: false)
        environment.rejectsDarkWrite = true
        let result = await AIVoiceMacSystemAppearance(environment: environment).execute(.dark)
        #expect(result.status == .unconfirmed)
        #expect(!environment.state.isAutomatic)
        #expect(!environment.state.isDark)
        #expect(environment.changes == [.automatic(false), .dark(true)])
    }

    @Test func unavailableReaderMakesNoChanges() async {
        let environment = AppearanceEnvironmentProbe(automatic: true, dark: false)
        environment.rejectsRead = true
        let result = await AIVoiceMacSystemAppearance(environment: environment).execute(.dark)
        #expect(result.status == .failed)
        #expect(environment.changes.isEmpty)
    }

    @Test func cancellationBeforeDispatchDoesNotReadOrWriteAppearance() async {
        let environment = AppearanceEnvironmentProbe(automatic: false, dark: false)
        let controller = AIVoiceMacSystemAppearance(environment: environment)
        let operation = Task { await controller.execute(.dark) }
        operation.cancel()
        let result = await operation.value
        #expect(result.status == .cancelled)
        #expect(environment.reads == 0)
        #expect(environment.changes.isEmpty)
    }
}

@MainActor
private final class AppearanceEnvironmentProbe: AIVoiceSystemAppearanceEnvironment {
    enum Change: Equatable { case automatic(Bool), dark(Bool) }
    var state: AIVoiceSystemAppearanceState
    var changes: [Change] = []
    var reads = 0
    var ignoresWrites = false
    var rejectsDarkWrite = false
    var rejectsRead = false

    init(automatic: Bool, dark: Bool) {
        state = .init(isAutomatic: automatic, isDark: dark)
    }

    func read() throws -> AIVoiceSystemAppearanceState {
        reads += 1
        if rejectsRead { throw AIVoiceSystemControlError("读取不可用") }
        return state
    }

    func setAutomatic(_ enabled: Bool) throws {
        changes.append(.automatic(enabled))
        if !ignoresWrites { state = .init(isAutomatic: enabled, isDark: state.isDark) }
    }

    func setDark(_ dark: Bool) throws {
        changes.append(.dark(dark))
        if rejectsDarkWrite { throw AIVoiceSystemControlError("写入失败") }
        if !ignoresWrites { state = .init(isAutomatic: state.isAutomatic, isDark: dark) }
    }
}
