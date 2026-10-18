import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceCapabilitiesTests {
    @Test func applicationDiscoveryIncludesFinderHiddenAppsLikeTheSystemSafariLink() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("JoyHarnessVoiceApps-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        var application = root.appendingPathComponent("Browser.app")
        let contents = application.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Browser")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info = ["CFBundleIdentifier": "org.example.voice-browser", "CFBundleName": "Browser",
                    "CFBundleExecutable": "Browser", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        var resourceValues = URLResourceValues()
        resourceValues.isHidden = true
        try application.setResourceValues(resourceValues)
        let environment = AIVoiceMacCapabilityEnvironment(applicationDirectories: [root])

        let applications = environment.installedApplications()

        #expect(applications.map(\.bundleID) == ["org.example.voice-browser"])
        #expect(applications.first?.url.resolvingSymlinksInPath().path == application.resolvingSymlinksInPath().path)
    }

    @Test func modelCommandsCannotLaunchPathsURLsOrUnregisteredOperations() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)
        let invalid = [
            AIVoiceCommand(capabilityID: "run_shell", parameters: ["command": "open /Applications/Safari.app"]),
            AIVoiceCommand(capabilityID: "open_application", parameters: ["application": "/Applications/Safari.app"]),
            AIVoiceCommand(capabilityID: "open_system_settings", parameters: ["page": "https://example.com"]),
            AIVoiceCommand(capabilityID: "open_application", parameters: ["application": "Safari", "arguments": "--delete"]),
            AIVoiceCommand(capabilityID: "open_wetype_settings", parameters: ["url": "wetype://unknown"]),
        ]
        for command in invalid {
            let result = await registry.execute(command, requestID: UUID())
            #expect(result.status == .failed)
        }
        #expect(environment.openedApplications.isEmpty)
        #expect(environment.openedPages.isEmpty)
    }

    @Test func disabledCapabilityIsRecheckedAfterIntentResolution() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)
        guard case .ready(let command, _) = registry.parseLocal("打开 Safari") else {
            Issue.record("Expected installed app to resolve before disabling its capability")
            return
        }
        registry.enabledCapabilityIDs.remove("open_application")

        let result = await registry.execute(command, requestID: UUID())

        #expect(result.status == .failed)
        #expect(environment.openedApplications.isEmpty)
        #expect(!registry.descriptors.contains { $0.id == "open_application" })
        #expect(registry.allDescriptors.contains { $0.id == "open_application" })
    }

    @Test func ambiguousInstalledNamesRequireChoiceWithoutLaunchingAnything() async {
        let environment = VoiceCapabilityEnvironmentStub()
        environment.applications.append(.init(
            bundleID: "org.example.otherSafari", name: "Safari", aliases: [],
            url: URL(fileURLWithPath: "/Applications/Other Safari.app")
        ))
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_application", parameters: ["application": "Safari"])
        guard case .needsChoice(_, let choices) = registry.resolve(command) else {
            Issue.record("Multiple exact names must not silently choose an app")
            return
        }
        #expect(Set(choices.map(\.command.parameters)) == Set([
            ["application": "com.apple.Safari"], ["application": "org.example.otherSafari"],
        ]))
        let result = await registry.execute(command, requestID: UUID())
        #expect(result.status == .failed)
        #expect(environment.openedApplications.isEmpty)

        let selected = choices.first { $0.command.parameters["application"] == "org.example.otherSafari" }!
        let selectionResult = await registry.execute(selected.command, requestID: UUID())
        #expect(selectionResult.status == .succeeded)
        #expect(environment.openedApplications == [URL(fileURLWithPath: "/Applications/Other Safari.app")])
    }

    @Test func localFallbackDoesNotTurnAnAppSettingsRequestIntoAnAppLaunch() {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)

        guard case .needsChoice(_, let choices) = registry.parseLocal("打开微信设置") else {
            Issue.record("The ambiguous WeChat settings phrase must ask which product")
            return
        }
        #expect(choices.count == 1)
        #expect(choices[0].command.capabilityID == "open_wetype_settings")
        guard case .unavailable = registry.parseLocal("打开 Safari 然后删除文件") else {
            Issue.record("Local matching must not ignore trailing operations")
            return
        }
        guard case .unavailable = registry.parseLocal("打开 Safari 设置") else {
            Issue.record("Unadapted app settings must not be downgraded to opening the app")
            return
        }
        #expect(environment.openedApplications.isEmpty)
    }

    @Test func weTypeUsesOnlyItsVerifiedSettingsAppAndNeedsAnActualWindow() async {
        let environment = VoiceCapabilityEnvironmentStub()
        environment.windowVisible = false
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_wetype_settings", parameters: [:])

        let unconfirmed = await registry.execute(command, requestID: UUID())

        #expect(unconfirmed.status == .unconfirmed)
        #expect(environment.openedApplications == [environment.weType!.settingsURL!])
        #expect(!unconfirmed.message.hasPrefix("已打开"))

        environment.windowVisible = true
        let confirmed = await registry.execute(command, requestID: UUID())
        #expect(confirmed.status == .succeeded)
    }

    @Test func missingOrUnverifiedWeTypeDoesNotOpenAReplacement() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let command = AIVoiceCommand(capabilityID: "open_wetype_settings", parameters: [:])
        environment.weType = nil
        let absent = await makeRegistry(environment).execute(command, requestID: UUID())
        #expect(absent.status == .failed)

        environment.weType = .init(applicationVersion: "4.0.0", settingsVersion: "4.0.0",
                                   settingsURL: URL(fileURLWithPath: "/Applications/WeTypeSettings.app"))
        let unsupported = await makeRegistry(environment).execute(command, requestID: UUID())
        #expect(unsupported.status == .failed)
        #expect(unsupported.message.contains("4.0.0"))
        #expect(environment.openedApplications.isEmpty)
    }

    @Test func repeatedSubmissionCannotReexecuteOrChangeItsCommand() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_application", parameters: ["application": "Safari"])
        let requestID = UUID()

        let first = await registry.execute(command, requestID: requestID)
        let repeated = await registry.execute(command, requestID: requestID)
        let changed = await registry.execute(.init(capabilityID: "open_wetype_settings", parameters: [:]), requestID: requestID)

        #expect(first.status == .succeeded)
        #expect(repeated == first)
        #expect(changed.status == .failed)
        #expect(environment.openedApplications.count == 1)
    }

    @Test func enablingCapabilityDoesNotReplayAPreviouslyRejectedRequest() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_application", parameters: ["application": "Safari"])
        let requestID = UUID()
        registry.enabledCapabilityIDs = []
        let denied = await registry.execute(command, requestID: requestID)
        registry.enabledCapabilityIDs = AIVoiceCapabilityRegistry.allCapabilityIDs
        let replayed = await registry.execute(command, requestID: requestID)

        #expect(denied.status == .failed)
        #expect(replayed == denied)
        #expect(environment.openedApplications.isEmpty)
        let explicitRetry = await registry.execute(command, requestID: UUID())
        #expect(explicitRetry.status == .succeeded)
        #expect(environment.openedApplications.count == 1)
    }

    @Test func settingsRequestAcceptanceIsNotReportedAsPageVerification() async {
        let environment = VoiceCapabilityEnvironmentStub()
        environment.pageVisible = false
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_system_settings", parameters: ["page": "sound"])

        let result = await registry.execute(command, requestID: UUID())

        #expect(environment.openedPages == [.sound])
        #expect(result.status == .unconfirmed)
        #expect(!result.message.hasPrefix("已打开"))
    }

    @Test func cancellationBeforeDispatchDoesNotOpenAnything() async {
        let environment = VoiceCapabilityEnvironmentStub()
        let registry = makeRegistry(environment)
        let requestID = UUID()
        let command = AIVoiceCommand(capabilityID: "open_wetype_settings", parameters: [:])
        let task = Task { @MainActor in
            await registry.execute(command, requestID: requestID)
        }
        task.cancel()
        let result = await task.value
        let replayed = await registry.execute(command, requestID: requestID)

        #expect(result.status == .cancelled)
        #expect(replayed == result)
        #expect(environment.openedApplications.isEmpty)
    }

    @Test func cancellationDuringVerificationDoesNotRetryAnAlreadyDispatchedLaunch() async {
        let environment = VoiceCapabilityEnvironmentStub()
        environment.windowVisible = false
        let registry = AIVoiceCapabilityRegistry(environment: environment, verificationTimeout: 30,
                                                 pollingNanoseconds: 1_000_000)
        let requestID = UUID()
        let command = AIVoiceCommand(capabilityID: "open_wetype_settings", parameters: [:])
        let task = Task { @MainActor in await registry.execute(command, requestID: requestID) }
        // The fake records a real dispatch before the executor begins waiting.
        while environment.openedApplications.isEmpty { await Task.yield() }
        task.cancel()
        let cancelled = await task.value
        let repeated = await registry.execute(command, requestID: requestID)

        #expect(cancelled.status == .cancelled)
        #expect(repeated == cancelled)
        #expect(environment.openedApplications.count == 1)
    }

    private func makeRegistry(_ environment: VoiceCapabilityEnvironmentStub) -> AIVoiceCapabilityRegistry {
        AIVoiceCapabilityRegistry(environment: environment, verificationTimeout: 0)
    }
}

@MainActor
private final class VoiceCapabilityEnvironmentStub: AIVoiceCapabilityEnvironment {
    var applications: [AIVoiceInstalledApplication] = [
        .init(bundleID: "com.apple.Safari", name: "Safari", aliases: [],
              url: URL(fileURLWithPath: "/Applications/Safari.app")),
    ]
    var weType: AIVoiceWeTypeInstallation? = .init(
        applicationVersion: "3.0.0", settingsVersion: "3.0.0",
        settingsURL: URL(fileURLWithPath: "/Library/Input Methods/WeType.app/Contents/MacOS/WeTypeSettings.app")
    )
    var windowVisible = true
    var pageVisible = true
    var canVerifySystemSettings = true
    var openedApplications: [URL] = []
    var openedPages: [AIVoiceSystemSettingsPage] = []

    func installedApplications() -> [AIVoiceInstalledApplication] { applications }
    func weTypeInstallation() -> AIVoiceWeTypeInstallation? { weType }
    func openApplication(at url: URL) async throws -> Int32 {
        openedApplications.append(url)
        return 42
    }
    func hasVisibleWindow(processID: Int32) -> Bool { processID == 42 && windowVisible }
    func openSystemSettings(_ page: AIVoiceSystemSettingsPage) -> Bool {
        openedPages.append(page)
        return true
    }
    func hasVisibleSystemSettingsPage(_ page: AIVoiceSystemSettingsPage) -> Bool { pageVisible }
}
