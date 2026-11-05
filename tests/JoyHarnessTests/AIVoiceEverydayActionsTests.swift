import ApplicationServices
import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceEverydayActionsTests {
    @Test(arguments: [
        ("minimize", kAXMinimizedAttribute, true),
        ("fullscreen", "AXFullScreen", true),
        ("exit_fullscreen", "AXFullScreen", false),
    ])
    func windowCommandsWriteTheRequestedStateAndVerifyIt(action: String, attribute: String, desired: Bool) async {
        let environment = EverydayEnvironmentStub()
        environment.state = !desired
        let result = await makeRegistry(environment).execute(.init(capabilityID: "control_window", parameters: ["action": action]), requestID: UUID(), currentApplication: environment.target)
        #expect(result.status == .succeeded)
        #expect(environment.windowProcessIDs == [environment.target.processID])
        #expect(environment.writes == [.init(attribute: attribute, value: desired)])
        #expect(environment.state == desired)
    }

    @Test func foregroundChangeBeforeDispatchNeverTouchesAnotherApp() async {
        let environment = EverydayEnvironmentStub()
        let original = environment.target
        environment.frontmost = .init(processID: 99, bundleID: "other.app", launchDate: Date(), name: "Other")
        let result = await makeRegistry(environment).execute(windowCommand, requestID: UUID(), currentApplication: original)
        #expect(result.status == .failed)
        #expect(environment.windowProcessIDs.isEmpty)
        #expect(environment.writes.isEmpty)
    }

    @Test func samePIDWithANewLaunchDateCannotReplaceTheCapturedApplication() async {
        let environment = EverydayEnvironmentStub()
        let target = environment.target
        environment.frontmost = .init(processID: target.processID, bundleID: target.bundleID,
                                      launchDate: target.launchDate.addingTimeInterval(1), name: target.name)
        let result = await makeRegistry(environment).execute(windowCommand, requestID: UUID(), currentApplication: target)
        #expect(result.status == .failed)
        #expect(environment.writes.isEmpty)
    }

    @Test func focusChangeDuringWindowLookupOrMissingPermissionPreventsTheWrite() async {
        let environment = EverydayEnvironmentStub()
        let registry = makeRegistry(environment)
        environment.changeFocusOnWindowLookup = true
        let changed = await registry.execute(windowCommand, requestID: UUID(), currentApplication: environment.target)
        #expect(changed.status == .failed)
        #expect(environment.writes.isEmpty)
        environment.frontmost = environment.target
        environment.changeFocusOnWindowLookup = false
        environment.canControlWindows = false
        let denied = await registry.execute(windowCommand, requestID: UUID(), currentApplication: environment.target)
        #expect(denied.status == .failed)
        #expect(environment.writes.isEmpty)
    }

    @Test func unsupportedOrMissingWindowAndRejectedWriteReportFailure() async {
        let environment = EverydayEnvironmentStub()
        let registry = makeRegistry(environment)
        environment.hasWindow = false
        #expect(await registry.execute(windowCommand, requestID: UUID(), currentApplication: environment.target).status == .failed)
        environment.hasWindow = true
        environment.state = nil
        #expect(await registry.execute(windowCommand, requestID: UUID(), currentApplication: environment.target).status == .failed)
        #expect(environment.writes.isEmpty)
        environment.state = false
        environment.acceptWrites = false
        #expect(await registry.execute(windowCommand, requestID: UUID(), currentApplication: environment.target).status == .failed)
        #expect(environment.state == false)
    }

    @Test func acceptedButUnobservedWindowChangeIsUnconfirmedAndNotRepeated() async {
        let environment = EverydayEnvironmentStub()
        environment.updateStateOnWrite = false
        let registry = makeRegistry(environment)
        let id = UUID()
        let first = await registry.execute(windowCommand, requestID: id, currentApplication: environment.target)
        let second = await registry.execute(windowCommand, requestID: id, currentApplication: environment.target)
        #expect(first.status == .unconfirmed)
        #expect(second == first)
        #expect(environment.writes.count == 1)
    }

    @Test func alreadyFullscreenDoesNotToggleOutOfFullscreen() async {
        let environment = EverydayEnvironmentStub()
        environment.state = true
        let result = await makeRegistry(environment).execute(.init(capabilityID: "control_window", parameters: ["action": "fullscreen"]), requestID: UUID(), currentApplication: environment.target)
        #expect(result.status == .succeeded)
        #expect(environment.writes.isEmpty)
    }

    @Test func delayedWindowReadbackIsEventuallyReportedAsSuccess() async {
        let environment = EverydayEnvironmentStub()
        environment.readStates = [false, false, true]
        let result = await makeRegistry(environment).execute(windowCommand, requestID: UUID(), currentApplication: environment.target)
        #expect(result.status == .succeeded)
        #expect(environment.writes.count == 1)
    }

    @Test func delayedHideReadbackIsEventuallyReportedAsSuccess() async {
        let environment = EverydayEnvironmentStub()
        environment.hiddenStates = [false, false, true]
        let result = await makeRegistry(environment).execute(.init(capabilityID: "control_window", parameters: ["action": "hide"]), requestID: UUID(), currentApplication: environment.target)
        #expect(result.status == .succeeded)
        #expect(environment.hiddenTargets == [environment.target])
    }

    @Test func hideUsesCapturedAppAndNeedsObservedHiddenStateForSuccess() async {
        let environment = EverydayEnvironmentStub()
        environment.canControlWindows = false
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "control_window", parameters: ["action": "hide"])
        #expect(await registry.execute(command, requestID: UUID(), currentApplication: environment.target).status == .succeeded)
        #expect(environment.hiddenTargets == [environment.target])
        #expect(environment.windowProcessIDs.isEmpty)
        environment.hidden = false
        #expect(await registry.execute(command, requestID: UUID(), currentApplication: environment.target).status == .unconfirmed)
    }

    @Test func localSearchLockAndSleepDispatchOnceAndKeepResultsUnconfirmed() async throws {
        let environment = EverydayEnvironmentStub()
        let registry = makeRegistry(environment)
        let data = Data(#"{"kind":"action","capabilityID":"search_files","arguments":{"query":"2026 预算表"},"message":"查找预算表"}"#.utf8)
        let intent = try AIVoiceProvider.parseIntent(data, capabilities: registry.descriptors)
        let search = AIVoiceCommand(capabilityID: try #require(intent.capabilityID), parameters: intent.arguments)
        let commands = [search, .init(capabilityID: "lock_screen", parameters: [:]), .init(capabilityID: "sleep_system", parameters: [:])]
        for command in commands {
            let id = UUID()
            let first = await registry.execute(command, requestID: id)
            let second = await registry.execute(command, requestID: id)
            #expect(first.status == .unconfirmed)
            #expect(second == first)
        }
        #expect(environment.searches == ["2026 预算表"])
        #expect(environment.lockCount == 1)
        #expect(environment.sleepCount == 1)
    }

    @Test(arguments: [
        AIVoiceCommand(capabilityID: "control_window", parameters: ["action": "close"]),
        .init(capabilityID: "control_window", parameters: ["action": "minimize", "pid": "99"]),
        .init(capabilityID: "search_files", parameters: ["query": " "]),
        .init(capabilityID: "search_files", parameters: ["query": "a\nb"]),
        .init(capabilityID: "search_files", parameters: ["query": "test", "open": "true"]),
        .init(capabilityID: "lock_screen", parameters: ["shortcut": "custom"]),
        .init(capabilityID: "sleep_system", parameters: ["force": "true"]),
    ])
    func invalidCommandsNeverDispatch(command: AIVoiceCommand) async {
        let environment = EverydayEnvironmentStub()
        let result = await makeRegistry(environment).execute(command, requestID: UUID(), currentApplication: environment.target)
        #expect(result.status == .failed)
        #expect(environment.writes.isEmpty)
        #expect(environment.searches.isEmpty)
        #expect(environment.lockCount == 0)
        #expect(environment.sleepCount == 0)
    }

    @Test func disabledAndCancelledCommandsMakeNoSystemRequests() async {
        let environment = EverydayEnvironmentStub()
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "sleep_system", parameters: [:])
        registry.enabledCapabilityIDs.remove("sleep_system")
        #expect(!registry.descriptors.contains { $0.id == "sleep_system" })
        #expect(await registry.execute(command, requestID: UUID()).status == .failed)
        registry.enabledCapabilityIDs.insert("sleep_system")
        let task = Task { @MainActor in await registry.execute(command, requestID: UUID()) }
        task.cancel()
        #expect(await task.value.status == .cancelled)
        #expect(environment.sleepCount == 0)
    }

    @Test func systemRejectionIsNotReportedAsSuccess() async {
        let environment = EverydayEnvironmentStub()
        environment.acceptSystemRequests = false
        let registry = makeRegistry(environment)
        for command in [AIVoiceCommand(capabilityID: "search_files", parameters: ["query": "test"]),
                        .init(capabilityID: "lock_screen", parameters: [:]), .init(capabilityID: "sleep_system", parameters: [:])] {
            #expect(await registry.execute(command, requestID: UUID()).status == .failed)
        }
    }

    private var windowCommand: AIVoiceCommand { .init(capabilityID: "control_window", parameters: ["action": "minimize"]) }
    private func makeRegistry(_ environment: EverydayEnvironmentStub) -> AIVoiceCapabilityRegistry {
        AIVoiceCapabilityRegistry(everydayActions: AIVoiceMacEverydayActions(environment: environment))
    }
}

@MainActor
private final class EverydayEnvironmentStub: AIVoiceEverydayEnvironment {
    struct Write: Equatable {
        let attribute: String
        let value: Bool
    }
    let target = AIVoiceForegroundApplication(processID: 42, bundleID: "test.app", launchDate: Date(timeIntervalSince1970: 123), name: "Test")
    var frontmost: AIVoiceForegroundApplication?
    var canControlWindows = true
    var state: Bool? = false
    var hasWindow = true
    var changeFocusOnWindowLookup = false
    var acceptWrites = true
    var updateStateOnWrite = true
    var hidden = true
    var readStates: [Bool?] = []
    var hiddenStates: [Bool] = []
    var acceptSystemRequests = true
    var windowProcessIDs: [Int32] = []
    var writes: [Write] = []
    var hiddenTargets: [AIVoiceForegroundApplication] = []
    var searches: [String] = []
    var lockCount = 0
    var sleepCount = 0

    init() { frontmost = target }
    func frontmostApplication() -> AIVoiceForegroundApplication? { frontmost }
    func focusedWindow(processID: Int32) -> AXUIElement? {
        windowProcessIDs.append(processID)
        if changeFocusOnWindowLookup { frontmost = nil }
        return hasWindow ? AXUIElementCreateApplication(processID) : nil
    }
    func readWindowFlag(_ attribute: String, window: AXUIElement) -> Bool? {
        readStates.isEmpty ? state : readStates.removeFirst()
    }
    func setWindowFlag(_ attribute: String, value: Bool, window: AXUIElement) -> Bool {
        writes.append(.init(attribute: attribute, value: value))
        if acceptWrites && updateStateOnWrite { state = value }
        return acceptWrites
    }
    func hideApplication(_ target: AIVoiceForegroundApplication) -> Bool { hiddenTargets.append(target); return true }
    func isApplicationHidden(_ target: AIVoiceForegroundApplication) -> Bool {
        hiddenStates.isEmpty ? hidden : hiddenStates.removeFirst()
    }
    func searchFiles(_ query: String) -> Bool { searches.append(query); return acceptSystemRequests }
    func postLockScreenShortcut() -> Bool { lockCount += 1; return acceptSystemRequests }
    func sleepSystem() -> Bool { sleepCount += 1; return acceptSystemRequests }
}
