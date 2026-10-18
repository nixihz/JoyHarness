import Foundation
import Testing
@testable import JoyHarness

struct AIVoiceProviderTests {
    private let capabilities = [AIVoiceCapabilityDescriptor(
        id: "open.application", summary: "打开已安装应用", parameterNames: ["target"], examples: []
    )]

    @Test
    func localModeRejectsRemoteAndMisleadingLoopbackHosts() throws {
        for address in ["https://example.com/v1", "http://localhost.example.com/v1", "http://127.0.0.1.example.com/v1"] {
            let endpoint = AIVoiceServiceEndpoint(baseURL: try #require(URL(string: address)), model: "model", apiKey: "")
            #expect(throws: AIVoiceProviderError.self) {
                try AIVoiceProvider.validateEndpoint(endpoint, requireLoopback: true)
            }
        }
        for address in ["http://localhost:1234/v1", "http://127.0.0.1:11434/v1", "http://[::1]:1234/v1"] {
            try AIVoiceProvider.validateEndpoint(
                .init(baseURL: try #require(URL(string: address)), model: "model", apiKey: ""),
                requireLoopback: true
            )
        }
    }

    @Test
    func remoteEndpointRequiresTLSAndRejectsURLSecretsAndHeaderInjection() throws {
        for address in ["http://example.com/v1", "https://user:secret@example.com/v1",
                        "https://example.com/v1?token=secret", "https://example.com/v1#fragment"] {
            let endpoint = AIVoiceServiceEndpoint(baseURL: try #require(URL(string: address)), model: "model", apiKey: "")
            #expect(throws: AIVoiceProviderError.self) {
                try AIVoiceProvider.validateEndpoint(endpoint, requireLoopback: false)
            }
        }
        let endpoint = AIVoiceServiceEndpoint(baseURL: try #require(URL(string: "https://example.com/v1")),
                                             model: "model", apiKey: "secret\r\nInjected: yes")
        #expect(throws: AIVoiceProviderError.self) {
            try AIVoiceProvider.validateEndpoint(endpoint, requireLoopback: false)
        }
    }

    @Test
    func multipartPreservesWAVBytesAndUsesConfiguredAPIBase() throws {
        let recording = AIVoiceWAV.recording(samples: [0, -1, 32767], sampleRate: 16_000)
        let endpoint = AIVoiceServiceEndpoint(baseURL: try #require(URL(string: "https://example.com/custom/v1/")),
                                             model: "user-selected-model", apiKey: "test-token")
        let request = try AIVoiceProvider.transcriptionRequest(recording, endpoint: endpoint)
        #expect(request.url?.absoluteString == "https://example.com/custom/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try #require(request.httpBody)
        let range = try #require(body.range(of: recording.wavData))
        #expect(body.subdata(in: range) == recording.wavData)
        let header = String(decoding: body.prefix(range.lowerBound), as: UTF8.self)
        #expect(header.contains("name=\"file\"; filename=\"command.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(header.contains("\r\n\r\nuser-selected-model\r\n"))
        #expect(String(decoding: body.suffix(4), as: UTF8.self) == "--\r\n")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test
    func structuredResponseAcceptsRegisteredActionButRejectsInjectedExecution() throws {
        let valid = Data(#"{"kind":"action","capabilityID":"open.application","arguments":{"target":"微信输入法"},"message":"打开设置"}"#.utf8)
        let result = try AIVoiceProvider.parseIntent(valid, capabilities: capabilities)
        #expect(result.capabilityID == "open.application")
        #expect(result.arguments["target"] == "微信输入法")
        for json in [
            #"{"kind":"action","capabilityID":"run.shell","arguments":{},"message":"执行"}"#,
            #"{"kind":"action","capabilityID":"open.application","arguments":{"shell":"rm"},"message":"执行"}"#,
            #"{"kind":"action","capabilityID":"open.application","arguments":{},"message":"执行","script":"danger"}"#,
            #"{"kind":"clarification","capabilityID":"open.application","arguments":{},"message":"哪一个？"}"#,
            #"{"kind":"action","capabilityID":"open.application","arguments":{"target":123},"message":"执行"}"#,
        ] {
            #expect(throws: AIVoiceProviderError.self) {
                try AIVoiceProvider.parseIntent(Data(json.utf8), capabilities: capabilities)
            }
        }
    }

    @Test
    func clarificationCannotCarryAnActionAndAllowsNoCapability() throws {
        let data = Data(#"{"kind":"clarification","capabilityID":null,"arguments":{},"message":"打开微信还是微信输入法？"}"#.utf8)
        let result = try AIVoiceProvider.parseIntent(data, capabilities: capabilities)
        #expect(result.kind == .clarification)
        #expect(result.capabilityID == nil)
        #expect(result.arguments.isEmpty)
    }

    @Test
    func cloudRequiresASRConfigurationBeforeAnyRequest() throws {
        let endpoint = AIVoiceServiceEndpoint(baseURL: try #require(URL(string: "https://example.com/v1")), model: "model", apiKey: "")
        let config = AIVoiceProviderConfiguration(route: .cloud, transcription: nil, intent: endpoint)
        #expect(throws: AIVoiceProviderError.self) {
            try AIVoiceProvider.validateConfiguration(config)
        }
    }
}
