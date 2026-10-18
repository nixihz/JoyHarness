import AppKit
import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceCurrentAppSettingsTests {
    @Test func capturedTargetDoesNotFollowLaterForegroundChanges() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.foreground = .init(processID: 92, bundleID: "test.other",
                                        launchDate: Date(timeIntervalSince1970: 300), name: "其他应用")

        let result = await opener.execute(target: target)

        #expect(target.processID == 42)
        #expect(target.bundleID == "test.editor")
        #expect(result.status == .failed)
        #expect(result.message.contains("已切换或重新启动"))
        #expect(environment.posted.isEmpty)
    }

    @Test func missingCapturedTargetNeverFallsBackToTheCurrentApplication() async {
        let environment = CurrentAppSettingsEnvironmentStub()
        let result = await AIVoiceMacCurrentAppSettings(environment: environment).execute(target: nil)

        #expect(result.status == .failed)
        #expect(result.message.contains("提交语音时"))
        #expect(environment.makeEventsCount == 0)
        #expect(environment.posted.isEmpty)
    }

    @Test func captureRejectsAnUnavailableOrInvalidIdentity() {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        environment.foreground = nil
        #expect(opener.captureTarget() == nil)
        environment.foreground = .init(processID: 0, bundleID: "test.editor",
                                        launchDate: Date(timeIntervalSince1970: 100), name: "编辑器")
        #expect(opener.captureTarget() == nil)
        environment.foreground = .init(processID: 42, bundleID: "",
                                        launchDate: Date(timeIntervalSince1970: 100), name: "编辑器")
        #expect(opener.captureTarget() == nil)
    }

    @Test func disappearedTargetChangedBundleAndReusedPIDCannotReceiveTheShortcut() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        let changed: [AIVoiceForegroundApplication?] = [
            nil,
            .init(processID: target.processID, bundleID: "test.other", launchDate: target.launchDate, name: target.name),
            .init(processID: target.processID, bundleID: target.bundleID,
                  launchDate: target.launchDate.addingTimeInterval(1), name: target.name),
        ]
        for foreground in changed {
            environment.foreground = foreground
            let result = await opener.execute(target: target)
            #expect(result.status == .failed)
        }
        #expect(environment.makeEventsCount == 0)
        #expect(environment.posted.isEmpty)
    }

    @Test func missingPermissionDoesNotConstructOrSendEvents() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.canPostEvents = false

        let result = await opener.execute(target: target)

        #expect(result.status == .failed)
        #expect(result.message.contains("辅助功能权限"))
        #expect(environment.makeEventsCount == 0)
        #expect(environment.posted.isEmpty)
    }

    @Test func foregroundIsCheckedAgainAfterEventConstruction() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.onMakeEvents = { [weak environment] in environment?.foreground = nil }

        let result = await opener.execute(target: target)

        #expect(result.status == .failed)
        #expect(environment.makeEventsCount == 1)
        #expect(environment.posted.isEmpty)
    }

    @Test func permissionRevokedDuringConstructionPreventsDispatch() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.onMakeEvents = { [weak environment] in environment?.canPostEvents = false }

        let result = await opener.execute(target: target)

        #expect(result.status == .failed)
        #expect(result.message.contains("辅助功能权限"))
        #expect(environment.posted.isEmpty)
    }

    @Test func eventConstructionFailureNeverPostsAPartialKeyPress() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.eventConstructionFails = true

        let result = await opener.execute(target: target)

        #expect(result.status == .failed)
        #expect(environment.posted.isEmpty)
    }

    @Test func oneFixedCommandCommaPairTargetsTheCapturedPIDAndRemainsUnconfirmed() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        // A changed display name does not indicate a restarted process.
        environment.foreground = .init(processID: target.processID, bundleID: target.bundleID,
                                        launchDate: target.launchDate, name: "新的显示名称")

        let result = await opener.execute(target: target)

        #expect(environment.posted.count == 1)
        let sent = try #require(environment.posted.first)
        #expect(sent.processID == 42)
        #expect(sent.down.type == .keyDown)
        #expect(sent.up.type == .keyUp)
        for event in [sent.down, sent.up] {
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 43)
            #expect(event.getIntegerValueField(.keyboardEventAutorepeat) == 0)
            #expect(event.flags == .maskCommand)
        }
        #expect(result.status == .unconfirmed)
        #expect(result.message.contains("已向“编辑器”发送"))
        #expect(result.message.contains("尚无法确认设置窗口"))
        #expect(!result.message.contains("设置窗口已打开"))
    }

    @Test func cancellationBeforeExecutionPreventsShortcutDispatch() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        let task = Task { @MainActor in await opener.execute(target: target) }
        task.cancel()

        let result = await task.value

        #expect(result.status == .cancelled)
        #expect(environment.makeEventsCount == 0)
        #expect(environment.posted.isEmpty)
    }

    @Test func cancellationDuringConstructionNeverPostsThePreparedKeyPair() async throws {
        let environment = CurrentAppSettingsEnvironmentStub()
        let opener = AIVoiceMacCurrentAppSettings(environment: environment)
        let target = try #require(opener.captureTarget())
        environment.onMakeEvents = {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        let task = Task { @MainActor in await opener.execute(target: target) }

        let result = await task.value

        #expect(result.status == .cancelled)
        #expect(environment.makeEventsCount == 1)
        #expect(environment.posted.isEmpty)
    }
}

@MainActor
private final class CurrentAppSettingsEnvironmentStub: AIVoiceCurrentAppSettingsEnvironment {
    struct PostedPair {
        let processID: Int32
        let down: CGEvent
        let up: CGEvent
    }

    var foreground: AIVoiceForegroundApplication? = .init(
        processID: 42, bundleID: "test.editor", launchDate: Date(timeIntervalSince1970: 100), name: "编辑器"
    )
    var canPostEvents = true
    var eventConstructionFails = false
    var onMakeEvents: (() -> Void)?
    var makeEventsCount = 0
    var posted: [PostedPair] = []

    func frontmostApplication() -> AIVoiceForegroundApplication? { foreground }

    func makeSettingsEvents() -> (down: CGEvent, up: CGEvent)? {
        makeEventsCount += 1
        onMakeEvents?()
        guard !eventConstructionFails else { return nil }
        // Build actual packets for inspection, without using the real sender.
        return AIVoiceMacCurrentAppSettingsEnvironment.settingsEvents()
    }

    func postSettingsEvents(_ events: (down: CGEvent, up: CGEvent), to processID: Int32) {
        posted.append(.init(processID: processID, down: events.down, up: events.up))
    }
}
