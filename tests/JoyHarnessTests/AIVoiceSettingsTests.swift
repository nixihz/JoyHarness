import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceSettingsTests {
    @Test func firstLaunchIsDisabledAndUsesOnlyALoopbackModelAddress() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }

        #expect(!fixture.settings.isEnabled)
        #expect(fixture.settings.route == .local)
        #expect(URL(string: fixture.settings.intentBaseURL)?.host == "127.0.0.1")
        #expect(fixture.settings.transcriptionBaseURL.isEmpty)
        #expect(fixture.credentials.readAccounts.isEmpty)
        #expect(fixture.credentials.values.isEmpty)

        fixture.settings.intentModel = "local-model"
        let configuration = try fixture.settings.configuration()
        #expect(configuration.route == .local)
        #expect(configuration.transcription == nil)
        #expect(configuration.intent.apiKey.isEmpty)
    }

    @Test func changingEndpointCannotForwardThePreviousServersCredential() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.routeID = "hybrid"
        fixture.settings.intentBaseURL = "https://ai-one.example/v1"
        fixture.settings.intentModel = "example-model"
        try fixture.settings.storeCredential("test-provider-one-secret", for: .intent)
        #expect(try fixture.settings.configuration().intent.apiKey == "test-provider-one-secret")

        fixture.settings.intentBaseURL = "https://ai-two.example/v1"
        #expect(try fixture.settings.configuration().intent.apiKey.isEmpty)
        fixture.settings.intentBaseURL = "https://ai-one.example/other-path"
        #expect(try fixture.settings.configuration().intent.apiKey.isEmpty)
        fixture.settings.intentBaseURL = "https://ai-one.example/v1"
        #expect(try fixture.settings.configuration().intent.apiKey == "test-provider-one-secret")
        #expect(fixture.credentials.values.count == 1)
    }

    @Test func credentialsAreAbsentFromDefaultsAndOnlyReloadFromTheCredentialStore() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.intentModel = "local-model"
        let secret = "test-secret-must-never-be-in-user-defaults"
        try fixture.settings.storeCredential(secret, for: .intent)
        fixture.settings.isEnabled = true

        let persisted = try #require(fixture.defaults.data(forKey: "aiVoice.configuration.v1"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains(secret))
        let withCredentials = AIVoiceSettings(defaults: fixture.defaults, credentials: fixture.credentials)
        let withoutCredentials = AIVoiceSettings(defaults: fixture.defaults, credentials: VoiceSettingsCredentials())

        #expect(withCredentials.isEnabled)
        #expect(try withCredentials.configuration().intent.apiKey == secret)
        #expect(try withoutCredentials.configuration().intent.apiKey.isEmpty)
    }

    @Test func speechAndIntentKeysAreSeparateEvenAtTheSameServer() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.routeID = "cloud"
        fixture.settings.intentBaseURL = "https://provider.example/v1"
        fixture.settings.transcriptionBaseURL = "https://provider.example/v1"
        fixture.settings.intentModel = "intent-model"
        fixture.settings.transcriptionModel = "speech-model"
        try fixture.settings.storeCredential("test-intent-key", for: .intent)
        try fixture.settings.storeCredential("test-speech-key", for: .transcription)

        let configuration = try fixture.settings.configuration()

        #expect(configuration.intent.apiKey == "test-intent-key")
        #expect(configuration.transcription?.apiKey == "test-speech-key")
        #expect(fixture.credentials.values.count == 2)
    }

    @Test func inspectingConfigurationDoesNotReadCredentialsOrPromptTheKeychain() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.intentModel = "local-model"
        fixture.credentials.readError = NSError(domain: "KeychainLocked", code: 1)

        #expect(fixture.settings.configurationIssue == nil)
        #expect(fixture.credentials.readAccounts.isEmpty)
        #expect(throws: (any Error).self) { try fixture.settings.configuration() }
        #expect(fixture.credentials.readAccounts.count == 1)
    }

    @Test func remoteEndpointCannotBeUsedByTheLocalRouteAndPlainHTTPIsRejected() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.intentModel = "example-model"
        fixture.settings.intentBaseURL = "https://provider.example/v1"
        #expect(throws: (any Error).self) { try fixture.settings.configuration() }
        #expect(throws: (any Error).self) { try fixture.settings.storeCredential("test-secret", for: .intent) }
        #expect(fixture.credentials.values.isEmpty)

        fixture.settings.routeID = "hybrid"
        fixture.settings.intentBaseURL = "http://provider.example/v1"
        #expect(throws: (any Error).self) { try fixture.settings.configuration() }
        #expect(throws: (any Error).self) { try fixture.settings.storeCredential("test-secret", for: .intent) }
        #expect(fixture.credentials.values.isEmpty)
    }

    @Test func disabledCapabilitiesAndOffSwitchSurviveReload() throws {
        let fixture = try VoiceSettingsFixture()
        defer { fixture.cleanup() }
        fixture.settings.intentModel = "local-model"
        fixture.settings.isEnabled = true
        fixture.settings.setCapability("open_wetype_settings", enabled: false)
        fixture.settings.isEnabled = false

        let reloaded = AIVoiceSettings(defaults: fixture.defaults, credentials: fixture.credentials)

        #expect(!reloaded.isEnabled)
        #expect(reloaded.disabledCapabilities == ["open_wetype_settings"])
        #expect(reloaded.intentModel == "local-model")
    }
}

@MainActor
private final class VoiceSettingsFixture {
    let suiteName = "AIVoiceSettingsTests." + UUID().uuidString
    let defaults: UserDefaults
    let credentials = VoiceSettingsCredentials()
    let settings: AIVoiceSettings

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AIVoiceSettings(defaults: defaults, credentials: credentials)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suiteName) }
}

private final class VoiceSettingsCredentials: AIVoiceCredentialStore {
    var values: [String: String] = [:]
    var readAccounts: [String] = []
    var readError: Error?

    func read(account: String) throws -> String {
        readAccounts.append(account)
        if let readError { throw readError }
        return values[account, default: ""]
    }

    func write(_ value: String, account: String) throws { values[account] = value }
}
