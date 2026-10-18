import CJoyHarnessOpus
import Foundation

/// One 48 kHz mono decoder per microphone session. Confined to the session's
/// serial decoding worker; deliberately neither Sendable nor internally locked.
final class DualSenseOpusDecoder {
    enum Failure: Error, Equatable, LocalizedError {
        case codec(Int32)
        case invalidPacketLength(Int)
        case unexpectedFrameCount(Int)
        case concealmentBeforeAudio
        case concealmentLimit

        var errorDescription: String? {
            switch self {
            case .codec(let code):
                return "DualSense 音频解码失败：\(String(cString: jh_opus_error_string(code)))"
            case .invalidPacketLength(let count): return "DualSense 音频包长度无效：\(count)"
            case .unexpectedFrameCount(let count): return "DualSense 音频帧长度不受支持：\(count)"
            case .concealmentBeforeAudio: return "尚未收到可解码的 DualSense 音频"
            case .concealmentLimit: return "DualSense 连续音频缺口超出恢复上限"
            }
        }
    }

    static let sampleRate = 48_000
    static let frameCount = 480
    static let maximumConsecutiveConcealedFrames = 3
    static var libraryVersion: String { String(cString: jh_opus_version()) }

    private let decoder: OpaquePointer
    private var hasDecodedAudio = false
    private var consecutiveConcealedFrames = 0

    init() throws {
        var error: Int32 = 0
        guard let decoder = jh_opus_decoder_create(&error) else { throw Failure.codec(error) }
        self.decoder = decoder
    }

    deinit { jh_opus_decoder_destroy(decoder) }

    func reset() throws {
        let result = jh_opus_decoder_reset(decoder)
        guard result == 0 else { throw Failure.codec(result) }
        hasDecodedAudio = false
        consecutiveConcealedFrames = 0
    }

    func decode(_ payload: Data) throws -> [Float] {
        guard payload.count == DualSenseBluetoothAudioProtocol.microphoneOpusByteCount else {
            throw Failure.invalidPacketLength(payload.count)
        }
        return try payload.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = jh_opus_packet_samples(bytes.baseAddress, Int32(bytes.count))
            guard count >= 0 else { throw Failure.codec(count) }
            guard count == Self.frameCount else { throw Failure.unexpectedFrameCount(Int(count)) }
            // Real controller packets commonly use TOC 0xD4, which signals
            // stereo on the wire. The mono Opus decoder performs the required
            // downmix; mono PCM output must not imply a mono-only packet gate.
            let result = try decodeFrame(bytes.baseAddress, length: bytes.count)
            hasDecodedAudio = true
            consecutiveConcealedFrames = 0
            return result
        }
    }

    /// The caller may request a bounded PLC frame only after establishing a
    /// short gap. Raw four-bit report sequence alone is not sufficient proof.
    func concealLostFrame() throws -> [Float] {
        guard hasDecodedAudio else { throw Failure.concealmentBeforeAudio }
        guard consecutiveConcealedFrames < Self.maximumConsecutiveConcealedFrames else {
            throw Failure.concealmentLimit
        }
        let result = try decodeFrame(nil, length: 0)
        consecutiveConcealedFrames += 1
        return result
    }

    private func decodeFrame(_ packet: UnsafePointer<UInt8>?, length: Int) throws -> [Float] {
        var pcm = [Float](repeating: 0, count: Self.frameCount)
        let count = pcm.withUnsafeMutableBufferPointer {
            jh_opus_decode(decoder, packet, Int32(length), $0.baseAddress)
        }
        guard count >= 0 else { throw Failure.codec(count) }
        guard count == Self.frameCount else { throw Failure.unexpectedFrameCount(Int(count)) }
        return pcm
    }
}
