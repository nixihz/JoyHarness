import AppKit

enum AIVoiceBrowser: String, Sendable {
    case systemDefault = "default"
    case chrome, safari, edge, firefox, brave

    var title: String {
        switch self {
        case .systemDefault: "系统默认浏览器"
        case .chrome: "Chrome"
        case .safari: "Safari"
        case .edge: "Edge"
        case .firefox: "Firefox"
        case .brave: "Brave"
        }
    }

    var bundleID: String? {
        switch self {
        case .systemDefault: nil
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        case .edge: "com.microsoft.edgemac"
        case .firefox: "org.mozilla.firefox"
        case .brave: "com.brave.Browser"
        }
    }
}

enum AIVoiceSearchEngine: String, Sendable {
    case google, bing, baidu, duckduckgo, youtube, bilibili

    func url(query: String) -> URL? {
        let endpoint: String
        let parameter: String
        switch self {
        case .google: endpoint = "https://www.google.com/search"; parameter = "q"
        case .bing: endpoint = "https://www.bing.com/search"; parameter = "q"
        case .baidu: endpoint = "https://www.baidu.com/s"; parameter = "wd"
        case .duckduckgo: endpoint = "https://duckduckgo.com/"; parameter = "q"
        case .youtube: endpoint = "https://www.youtube.com/results"; parameter = "search_query"
        case .bilibili: endpoint = "https://search.bilibili.com/all"; parameter = "keyword"
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        // Search services decode queries as form data, where a raw + means
        // space. URLQueryItem leaves + legal under RFC 3986, so encode it.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }
}

struct AIVoiceBrowserAction: Equatable, Sendable {
    let browser: AIVoiceBrowser
    /// nil launches the browser without inventing a website to visit.
    let url: URL?
}

enum AIVoiceBrowserCommands {
    static let descriptors: [AIVoiceCapabilityDescriptor] = [
        .init(id: "open_browser", summary: "启动浏览器。browser 可选 default/chrome/safari/edge/firefox/brave，省略为系统默认浏览器。用户只要求打开Chrome或浏览器时使用；要打开网站或搜索则直接使用open_website/search_web，不要拆成多项操作。不修改系统默认浏览器。", parameterNames: ["browser"], examples: ["打开 Chrome", "打开浏览器"]),
        .init(id: "open_website", summary: "用浏览器打开网站。website 必填，为用户提供的HTTP(S)网址或明确的网站名；本机支持YouTube/油管、哔哩哔哩/B站、Google/谷歌、Bing/必应、百度、GitHub、Wikipedia/维基百科。未知网站名要追问网址，不猜测域名。browser 可选 default/chrome/safari/edge/firefox/brave，省略为系统默认浏览器；用户明确指定时必须保留。仅打开，不操作网页内容。", parameterNames: ["website", "browser"], examples: ["用 Chrome 打开 YouTube", "打开 github.com"]),
        .init(id: "search_web", summary: "在浏览器中打开搜索结果。query 为用户要搜索的原始内容（保留空格和符号）；engine 可选 google/bing/baidu/duckduckgo/youtube/bilibili，省略默认google，用户说在YouTube或B站搜索时分别用youtube或bilibili。browser 可选 default/chrome/safari/edge/firefox/brave，省略为系统默认浏览器。缺少搜索内容要追问。搜索URL由本机构造，不生成URL，不读取结果、自动播放或执行网页后续操作。", parameterNames: ["query", "engine", "browser"], examples: ["用 Chrome 搜索 Swift 教程", "在 YouTube 搜索爵士乐"]),
    ]

    static func resolve(_ command: AIVoiceCommand) -> AIVoiceBuiltInResolution {
        let p = command.parameters
        let browserValue = p["browser"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        guard let browser = AIVoiceBrowser(rawValue: browserValue) else {
            return .invalid("浏览器支持系统默认、Chrome、Safari、Edge、Firefox 或 Brave。")
        }
        switch command.capabilityID {
        case "open_browser":
            guard Set(p.keys).isSubset(of: ["browser"]) else { return .invalid("打开浏览器不接受额外参数。") }
            return .ready(.browser(.init(browser: browser, url: nil)), summary: "打开\(browser.title)")
        case "open_website":
            guard Set(p.keys).isSubset(of: ["website", "browser"]),
                  let website = p["website"], let url = websiteURL(website) else {
                return .invalid("请提供明确的网站名称或 HTTP(S) 网址，例如 YouTube 或 github.com。")
            }
            return .ready(.browser(.init(browser: browser, url: url)), summary: "用\(browser.title)打开 \(url.absoluteString)")
        case "search_web":
            guard Set(p.keys).isSubset(of: ["query", "engine", "browser"]),
                  let query = p["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty, query.count <= 2_000,
                  query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  let engine = AIVoiceSearchEngine(rawValue: p["engine"].flatMap { $0.isEmpty ? nil : $0 } ?? "google"),
                  let url = engine.url(query: query) else {
                return .invalid("请提供搜索内容（最多 2000 字）；支持 Google、Bing、百度、DuckDuckGo、YouTube 和哔哩哔哩。")
            }
            return .ready(.browser(.init(browser: browser, url: url)), summary: "用\(browser.title)搜索“\(query)”")
        default: return .unknown
        }
    }

    static func websiteURL(_ website: String, maximumLength: Int = 4_096) -> URL? {
        let sites = [
            "youtube": "https://www.youtube.com", "油管": "https://www.youtube.com",
            "哔哩哔哩": "https://www.bilibili.com", "b站": "https://www.bilibili.com", "bilibili": "https://www.bilibili.com",
            "google": "https://www.google.com", "谷歌": "https://www.google.com",
            "bing": "https://www.bing.com", "必应": "https://www.bing.com", "百度": "https://www.baidu.com",
            "github": "https://github.com", "wikipedia": "https://www.wikipedia.org", "维基百科": "https://www.wikipedia.org",
        ]
        let text = website.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = sites[text.lowercased()] ?? text
        guard !address.isEmpty, address.count <= maximumLength,
              !address.contains("\\"),
              address.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        // A bare domain receives HTTPS; all other schemes remain explicit and
        // are rejected below rather than being dispatched through Launch Services.
        let value = address.contains("://") ? address : "https://" + address
        guard let components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url, let host = url.host, !host.isEmpty,
              host == "localhost" || host.contains(".") || host.hasPrefix("["),
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]").contains($0) }),
              !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else { return nil }
        return url
    }
}

@MainActor
protocol AIVoiceBrowserActing {
    func execute(_ action: AIVoiceBrowserAction) async -> AIVoiceExecutionResult
}

@MainActor
protocol AIVoiceBrowserEnvironment {
    func applicationURL(for browser: AIVoiceBrowser, opening url: URL?) -> URL?
    func open(_ url: URL?, withApplicationAt applicationURL: URL) async throws
}

@MainActor
final class AIVoiceMacBrowserActions: AIVoiceBrowserActing {
    private let environment: any AIVoiceBrowserEnvironment

    init(environment: (any AIVoiceBrowserEnvironment)? = nil) {
        self.environment = environment ?? AIVoiceMacBrowserEnvironment()
    }

    func execute(_ action: AIVoiceBrowserAction) async -> AIVoiceExecutionResult {
        do {
            try Task.checkCancellation()
            // The URL is created by resolve(_:), after website and search
            // parameters have been validated. Do not reparse its encoded form:
            // a valid 2,000-character Unicode query can exceed URL text limits.
            guard let applicationURL = environment.applicationURL(for: action.browser, opening: action.url) else {
                return .init(status: .failed, message: action.browser == .systemDefault
                             ? "未找到系统默认浏览器，请在系统设置中配置。"
                             : "未找到已安装的 \(action.browser.title)，请安装后重试或指定其他浏览器。")
            }
            try Task.checkCancellation()
            try await environment.open(action.url, withApplicationAt: applicationURL)
            return .init(status: .unconfirmed, message: action.url == nil
                         ? "已请求打开\(action.browser.title)，尚未确认浏览器窗口。"
                         : "已请求用\(action.browser.title)打开网页，尚未确认页面是否加载。")
        } catch is CancellationError {
            return .init(status: .cancelled, message: "已停止后续处理；已发起的浏览器请求可能仍会完成。")
        } catch let error as URLError where error.code == .timedOut {
            return .init(status: .unconfirmed, message: "浏览器打开请求已超时，尚无法确认结果；没有自动重试。")
        } catch {
            return .init(status: .failed, message: "无法打开浏览器：\(error.localizedDescription)")
        }
    }
}

@MainActor
final class AIVoiceMacBrowserEnvironment: AIVoiceBrowserEnvironment {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func applicationURL(for browser: AIVoiceBrowser, opening url: URL?) -> URL? {
        if let bundleID = browser.bundleID { return workspace.urlForApplication(withBundleIdentifier: bundleID) }
        // Launch Services lookup only; no request to this site is sent.
        guard let target = url ?? URL(string: "https://example.com") else { return nil }
        return workspace.urlForApplication(toOpen: target)
    }

    func open(_ url: URL?, withApplicationAt applicationURL: URL) async throws {
        let request = AIVoiceApplicationLaunch()
        _ = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
                    Task { @MainActor in
                        if let error { request.complete(.failure(error)) }
                        else if let app { request.complete(.success(app.processIdentifier)) }
                        else { request.complete(.failure(CocoaError(.executableNotLoadable))) }
                    }
                }
                if let url {
                    workspace.open([url], withApplicationAt: applicationURL, configuration: configuration, completionHandler: completion)
                } else {
                    workspace.openApplication(at: applicationURL, configuration: configuration, completionHandler: completion)
                }
            }
        } onCancel: {
            Task { @MainActor in request.complete(.failure(CancellationError())) }
        }
    }
}
