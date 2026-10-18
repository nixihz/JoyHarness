import Combine
import Foundation
import Security

protocol AIVoiceCredentialStore {
    func read(account: String) throws -> String
    func write(_ value: String, account: String) throws
}

struct AIVoiceKeychain: AIVoiceCredentialStore {
    private let service = "tech.keli.joyharness.ai-voice"

    func read(account: String) throws -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }

    func write(_ value: String, account: String) throws {
        let query = baseQuery(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "AIVoiceKeychain", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: L10n.text("无法访问语音服务凭据（\(status)）。", "Could not access voice service credentials (\(status)).")
        ])
    }
}

@MainActor
final class AIVoiceSettings: ObservableObject {
    enum Credential: String { case intent, transcription }
    private let defaults: UserDefaults
    private let credentials: any AIVoiceCredentialStore
    private static let key = "aiVoice.configuration.v1"
    var onChange: (() -> Void)?

    @Published var isEnabled: Bool { didSet { save() } }
    @Published var routeID: String { didSet { save() } }
    @Published var intentBaseURL: String { didSet { save() } }
    @Published var intentModel: String { didSet { save() } }
    @Published var transcriptionBaseURL: String { didSet { save() } }
    @Published var transcriptionModel: String { didSet { save() } }
    @Published var localeIdentifier: String { didSet { save() } }
    @Published var disabledCapabilities: Set<String> { didSet { save() } }

    private struct Stored: Codable {
        var isEnabled = false
        var routeID = "local"
        var intentBaseURL = "http://127.0.0.1:1234/v1"
        var intentModel = ""
        var transcriptionBaseURL = ""
        var transcriptionModel = ""
        var localeIdentifier = "zh-CN"
        var disabledCapabilities: Set<String> = []
    }

    init(defaults: UserDefaults = .standard, credentials: any AIVoiceCredentialStore = AIVoiceKeychain()) {
        self.defaults = defaults
        self.credentials = credentials
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        isEnabled = stored.isEnabled
        routeID = stored.routeID
        intentBaseURL = stored.intentBaseURL
        intentModel = stored.intentModel
        transcriptionBaseURL = stored.transcriptionBaseURL
        transcriptionModel = stored.transcriptionModel
        localeIdentifier = stored.localeIdentifier
        disabledCapabilities = stored.disabledCapabilities
    }

    var route: AIVoiceProcessingRoute? { AIVoiceProcessingRoute(rawValue: routeID) }

    func configuration() throws -> AIVoiceProviderConfiguration {
        guard let route else { throw invalid(L10n.text("请在 AI 语音设置中选择处理方式。", "Choose a processing route in AI Voice settings.")) }
        let intent = try endpoint(.intent)
        let transcription = route == .cloud ? try endpoint(.transcription) : nil
        let configuration = AIVoiceProviderConfiguration(
            route: route, transcription: transcription, intent: intent, localeIdentifier: localeIdentifier
        )
        try AIVoiceProvider.validateConfiguration(configuration)
        return configuration
    }

    /// UI inspection never reads a secret or contacts a service.
    var configurationIssue: String? {
        guard let route else { return L10n.text("尚未选择处理方式", "No processing route selected") }
        do {
            let intent = try endpoint(.intent, includeCredential: false)
            let transcription = route == .cloud ? try endpoint(.transcription, includeCredential: false) : nil
            try AIVoiceProvider.validateConfiguration(.init(route: route, transcription: transcription, intent: intent, localeIdentifier: localeIdentifier))
            return nil
        } catch { return error.localizedDescription }
    }

    func storeCredential(_ value: String, for kind: Credential) throws {
        let endpoint = try endpoint(kind, includeCredential: false)
        try AIVoiceProvider.validateEndpoint(endpoint, requireLoopback: kind == .intent && route == .local)
        try credentials.write(value.trimmingCharacters(in: .whitespacesAndNewlines), account: credentialAccount(kind, url: endpoint.baseURL))
        onChange?()
    }

    func setCapability(_ id: String, enabled: Bool) {
        if enabled { disabledCapabilities.remove(id) }
        else { disabledCapabilities.insert(id) }
    }

    private func endpoint(_ kind: Credential, includeCredential: Bool = true) throws -> AIVoiceServiceEndpoint {
        let text = (kind == .intent ? intentBaseURL : transcriptionBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (kind == .intent ? intentModel : transcriptionModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text), !model.isEmpty else {
            throw invalid(L10n.text("请填写服务地址和模型名称。", "Enter the service URL and model name."))
        }
        let token = includeCredential ? try credentials.read(account: credentialAccount(kind, url: url)) : ""
        return AIVoiceServiceEndpoint(baseURL: url, model: model, apiKey: token)
    }

    private func credentialAccount(_ kind: Credential, url: URL) -> String {
        // Bind credentials to the exact endpoint, so editing a URL never forwards
        // an old provider's key to a different server.
        "\(kind.rawValue):\(url.absoluteString)"
    }

    private func invalid(_ message: String) -> NSError {
        NSError(domain: "AIVoiceSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func save() {
        let stored = Stored(isEnabled: isEnabled, routeID: routeID, intentBaseURL: intentBaseURL,
                            intentModel: intentModel, transcriptionBaseURL: transcriptionBaseURL,
                            transcriptionModel: transcriptionModel, localeIdentifier: localeIdentifier,
                            disabledCapabilities: disabledCapabilities)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
        onChange?()
    }
}

extension AIVoiceProcessingRoute {
    var displayName: String {
        switch self {
        case .local: L10n.text("本地识别 + 本机模型", "On-device speech + local model")
        case .hybrid: L10n.text("本地识别 + 云端模型", "On-device speech + cloud model")
        case .cloud: L10n.text("云端识别 + 云端模型", "Cloud speech + cloud model")
        }
    }

    var dataNotice: String {
        switch self {
        case .local:
            L10n.text("Joy Harness 使用设备端语音识别，只向本机模型地址发送文字与能力说明。请自行确认本机模型服务没有转发请求。", "Joy Harness uses on-device recognition and sends text and capability descriptions only to a loopback model endpoint. Verify that your local server does not forward requests.")
        case .hybrid:
            L10n.text("音频在本机识别。松开 L2 后，文字、能力说明与必要参数会发送到配置的模型服务。", "Audio is recognized on this Mac. After releasing L2, text, capability descriptions and necessary arguments are sent to the configured model service.")
        case .cloud:
            L10n.text("松开 L2 后，音频发送到识别服务；转写文字、能力说明与必要参数发送到模型服务。服务方的数据留存政策独立适用。", "After releasing L2, audio goes to the speech service; transcription, capability descriptions and arguments go to the model service. Provider retention policies apply separately.")
        }
    }
}
