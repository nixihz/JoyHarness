import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceBrowserActionsTests {
    @Test func modelWebsiteCommandOpensYouTubeInChromeOnlyOnce() async throws {
        let environment = BrowserEnvironmentStub()
        let registry = makeRegistry(environment)
        let intent = try AIVoiceProvider.parseIntent(Data(#"{"kind":"action","capabilityID":"open_website","arguments":{"website":"YouTube","browser":"chrome"},"message":"打开YouTube"}"#.utf8), capabilities: registry.descriptors)
        let command = AIVoiceCommand(capabilityID: try #require(intent.capabilityID), parameters: intent.arguments)
        let id = UUID()
        let first = await registry.execute(command, requestID: id)
        let second = await registry.execute(command, requestID: id)
        #expect(first == second)
        #expect(first.status == .unconfirmed)
        #expect(environment.lookups == [.chrome])
        #expect(environment.opened.count == 1)
        #expect(environment.opened.first?.url?.absoluteString == "https://www.youtube.com")
        #expect(environment.opened.first?.applicationURL == environment.applicationURL)
    }

    @Test func searchKeepsQueryAsOneParameterWithoutURLInjection() async throws {
        let environment = BrowserEnvironmentStub()
        let registry = makeRegistry(environment)
        let query = "C++ 教程 & cats #1 ?q=x + 100% / 中文"
        let result = await registry.execute(.init(capabilityID: "search_web", parameters: [
            "query": query, "engine": "youtube", "browser": "safari",
        ]), requestID: UUID())
        let url = try #require(environment.opened.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.host == "www.youtube.com")
        #expect(url.path == "/results")
        #expect(components.queryItems == [URLQueryItem(name: "search_query", value: query)])
        #expect(components.percentEncodedQuery?.contains("C%2B%2B") == true)
        #expect(components.percentEncodedQuery?.contains("+") == false)
        #expect(url.fragment == nil)
        #expect(environment.lookups == [.safari])
        #expect(result.status == .unconfirmed)
    }

    @Test func unspecifiedBrowserUsesDefaultAndUnspecifiedEngineUsesGoogle() async {
        let environment = BrowserEnvironmentStub()
        let registry = makeRegistry(environment)
        _ = await registry.execute(.init(capabilityID: "open_browser", parameters: [:]), requestID: UUID())
        _ = await registry.execute(.init(capabilityID: "search_web", parameters: ["query": "Swift 教程"]), requestID: UUID())
        #expect(environment.lookups == [.systemDefault, .systemDefault])
        #expect(environment.opened.count == 2)
        #expect(environment.opened[0].url == nil)
        #expect(environment.opened[1].url?.host == "www.google.com")
    }

    @Test func longChineseSearchRemainsValidAfterPercentEncoding() async throws {
        let environment = BrowserEnvironmentStub()
        let query = String(repeating: "中文", count: 1_000)
        let result = await makeRegistry(environment).execute(.init(capabilityID: "search_web", parameters: ["query": query]), requestID: UUID())
        let url = try #require(environment.opened.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query)
        #expect(result.status == .unconfirmed)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/html,test", "chrome://settings",
        "https://user:pass@example.com", "https://example.com\nopen", "https://example.com:99999",
        "https://example.com\\@evil.com", "https://", "", "不认识的网站", "https://example..com",
        "https://example.com%0a.evil.com", "https://example.com 搜索教程",
    ])
    func invalidWebsiteNeverReachesBrowser(website: String) async {
        let environment = BrowserEnvironmentStub()
        let result = await makeRegistry(environment).execute(.init(capabilityID: "open_website", parameters: ["website": website]), requestID: UUID())
        #expect(result.status == .failed)
        #expect(environment.lookups.isEmpty)
        #expect(environment.opened.isEmpty)
    }

    @Test(arguments: [
        AIVoiceCommand(capabilityID: "open_browser", parameters: ["browser": "/Applications/Chrome.app"]),
        .init(capabilityID: "open_browser", parameters: ["arguments": "--incognito"]),
        .init(capabilityID: "open_website", parameters: ["website": "YouTube", "script": "alert(1)"]),
        .init(capabilityID: "search_web", parameters: ["query": " "]),
        .init(capabilityID: "search_web", parameters: ["query": "test", "engine": "https://evil.com"]),
        .init(capabilityID: "search_web", parameters: ["query": "test", "browser": "unknown"]),
        .init(capabilityID: "search_web", parameters: ["query": String(repeating: "x", count: 2_001)]),
    ])
    func malformedCommandsCannotDispatch(command: AIVoiceCommand) async {
        let environment = BrowserEnvironmentStub()
        let result = await makeRegistry(environment).execute(command, requestID: UUID())
        #expect(result.status == .failed)
        #expect(environment.opened.isEmpty)
    }

    @Test func missingChromeDoesNotFallBackToAnotherBrowser() async {
        let environment = BrowserEnvironmentStub()
        environment.applicationURL = nil
        let result = await makeRegistry(environment).execute(.init(capabilityID: "open_website", parameters: ["website": "YouTube", "browser": "chrome"]), requestID: UUID())
        #expect(result.status == .failed)
        #expect(result.message.contains("Chrome"))
        #expect(environment.lookups == [.chrome])
        #expect(environment.opened.isEmpty)
    }

    @Test func disabledBrowserCapabilityIsRecheckedBeforeDispatch() async {
        let environment = BrowserEnvironmentStub()
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_website", parameters: ["website": "YouTube"])
        guard case .ready = registry.resolve(command) else { Issue.record("网站应可解析"); return }
        registry.enabledCapabilityIDs.remove("open_website")
        #expect(!registry.descriptors.contains { $0.id == "open_website" })
        let result = await registry.execute(command, requestID: UUID())
        #expect(result.status == .failed)
        #expect(environment.opened.isEmpty)
    }

    @Test func cancellationAndLaunchFailureAreReported() async {
        let environment = BrowserEnvironmentStub()
        let registry = makeRegistry(environment)
        let command = AIVoiceCommand(capabilityID: "open_browser", parameters: ["browser": "chrome"])
        let task = Task { @MainActor in await registry.execute(command, requestID: UUID()) }
        task.cancel()
        #expect(await task.value.status == .cancelled)
        #expect(environment.opened.isEmpty)
        environment.error = CocoaError(.executableNotLoadable)
        #expect(await registry.execute(command, requestID: UUID()).status == .failed)
        environment.error = URLError(.timedOut)
        #expect(await registry.execute(command, requestID: UUID()).status == .unconfirmed)
    }

    @Test(arguments: [
        ("github.com/openai?tab=repositories#top", "https://github.com/openai?tab=repositories#top"),
        ("http://localhost:8080/test", "http://localhost:8080/test"),
        ("B站", "https://www.bilibili.com"),
        ("油管", "https://www.youtube.com"),
    ])
    func websiteAddressesPreservePathsAndResolveKnownNames(input: String, expected: String) async {
        let environment = BrowserEnvironmentStub()
        _ = await makeRegistry(environment).execute(.init(capabilityID: "open_website", parameters: ["website": input]), requestID: UUID())
        #expect(environment.opened.first?.url?.absoluteString == expected)
    }

    private func makeRegistry(_ environment: BrowserEnvironmentStub) -> AIVoiceCapabilityRegistry {
        AIVoiceCapabilityRegistry(browserActions: AIVoiceMacBrowserActions(environment: environment))
    }
}

@MainActor
private final class BrowserEnvironmentStub: AIVoiceBrowserEnvironment {
    struct Opened {
        let url: URL?
        let applicationURL: URL
    }
    var applicationURL: URL? = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    var lookups: [AIVoiceBrowser] = []
    var opened: [Opened] = []
    var error: Error?

    func applicationURL(for browser: AIVoiceBrowser, opening url: URL?) -> URL? {
        lookups.append(browser)
        return applicationURL
    }

    func open(_ url: URL?, withApplicationAt applicationURL: URL) async throws {
        if let error { throw error }
        opened.append(.init(url: url, applicationURL: applicationURL))
    }
}
