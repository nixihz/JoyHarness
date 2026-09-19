import Foundation

// ATVV wire constants and the IMA/DVI algorithm are documented in
// docs/xiaomi-remote-voice.md. Audio is signed mono PCM at 16 kHz.
struct RemoteVoiceCapabilities: Equatable {
    let version: UInt16
    let frameBytes: Int

    init?(_ packet: Data) {
        let bytes = Array(packet)
        guard bytes.count >= 7, bytes[0] == 0x0B else { return nil }
        version = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        guard version == 0x0100 else { return nil }
        // RC003 v1 firmware uses the older two-byte codec field in its reply.
        let codecs = bytes[3] == 0 && bytes.count >= 9 ? bytes[4] : bytes[3]
        guard codecs & 2 != 0 else { return nil }
        let size = Int(bytes[5]) * 256 + Int(bytes[6])
        guard size == 120 else { return nil }
        frameBytes = size
    }
}

struct RemoteADPCMDecoder {
    private static let steps = [
        7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,
        73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,
        449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,
        2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,
        7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,
        24623,27086,29794,32767,
    ]
    private var sample = 0
    private var index = 0

    mutating func reset(sample: Int16 = 0, index: Int = 0) {
        self.sample = Int(sample)
        self.index = min(88, max(0, index))
    }

    mutating func decode(_ bytes: Data) -> [Int16] {
        var pcm: [Int16] = []
        pcm.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            for shift in [4, 0] {
                let code = Int(byte >> shift) & 15
                let step = Self.steps[index]
                var delta = step / 8
                for bit in 0..<3 where code & (1 << bit) != 0 {
                    delta += step >> (2 - bit)
                }
                sample = min(32767, max(-32768, sample + (code & 8 == 0 ? delta : -delta)))
                let magnitude = code & 7
                index = min(88, max(0, index + (magnitude < 4 ? -1 : (magnitude - 3) * 2)))
                pcm.append(Int16(sample))
            }
        }
        return pcm
    }
}

/// Small, stateful speech enhancer for the RC003's quiet 16 kHz PCM stream.
///
/// The remote already performs codec-level processing, so this deliberately
/// stays conservative: remove rumble, attenuate low-level room noise, add a
/// fixed amount of headroom, and catch unexpected peaks before CoreAudio sees
/// the samples. State is kept between BLE packets so packet boundaries do not
/// create clicks or reset the filter envelope.
struct RemoteVoiceEnhancer {
    private let highPassCoefficient: Float
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private let inputGain: Float
    private let gateThreshold: Float
    private let gateFloor: Float
    private var previousInput: Float = 0
    private var previousFilterOutput: Float = 0
    private var previousSmoothedOutput: Float = 0
    private var envelope: Float = 0

    init(sampleRate: Float = 16_000, highPassHz: Float = 80, gainDB: Float = 12) {
        let safeRate = max(sampleRate, 1)
        let safeCutoff = min(max(highPassHz, 1), safeRate * 0.45)
        let timeConstant = 1 / (2 * Float.pi * safeCutoff)
        let samplePeriod = 1 / safeRate
        highPassCoefficient = timeConstant / (timeConstant + samplePeriod)
        attackCoefficient = exp(-1 / (safeRate * 0.005))
        releaseCoefficient = exp(-1 / (safeRate * 0.12))
        inputGain = pow(10, gainDB / 20)
        // Keep the gate below normal quiet speech so consonants do not get
        // chopped. It only attenuates the very low-level room noise.
        gateThreshold = pow(10, -56 / 20)
        gateFloor = pow(10, -12 / 20)
    }

    mutating func reset() {
        previousInput = 0
        previousFilterOutput = 0
        previousSmoothedOutput = 0
        envelope = 0
    }

    mutating func process(_ samples: [Int16]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        var output: [Float] = []
        output.reserveCapacity(samples.count)
        for sample in samples {
            let input = Float(sample) / 32_768
            let filtered = highPassCoefficient * (previousFilterOutput + input - previousInput)
            previousInput = input
            previousFilterOutput = filtered

            // A causal approximation of the three-point moving average used
            // for this codec: enough to hide ADPCM grit without blurring
            // speech transients or introducing a packet-sized delay.
            let smoothed = 0.75 * filtered + 0.25 * previousSmoothedOutput
            previousSmoothedOutput = smoothed

            let magnitude = abs(smoothed)
            let coefficient = magnitude > envelope ? attackCoefficient : releaseCoefficient
            envelope = coefficient * envelope + (1 - coefficient) * magnitude
            let normalizedEnvelope = min(1, envelope / gateThreshold)
            let gateGain = gateFloor + (1 - gateFloor) * normalizedEnvelope * normalizedEnvelope
            output.append(softLimit(smoothed * gateGain * inputGain))
        }
        return output
    }

    mutating func processInt16(_ samples: [Int16]) -> [Int16] {
        process(samples).map { value in
            Int16((max(-1, min(1, value)) * 32_767).rounded())
        }
    }

    private func softLimit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > 0.92 else { return sample }
        let limited = min(0.999, 0.92 + (magnitude - 0.92) * 0.18)
        return sample < 0 ? -limited : limited
    }
}

struct RemoteVoiceStream {
    private var decoder = RemoteADPCMDecoder()
    private var pending = Data()
    private(set) var session: UInt8?
    private(set) var sampleCount = 0
    private(set) var peak: Int = 0

    mutating func start(session: UInt8) {
        self = RemoteVoiceStream()
        self.session = session
    }

    mutating func synchronize(sample: Int16, index: Int) {
        pending.removeAll()
        decoder.reset(sample: sample, index: index)
    }

    mutating func append(_ data: Data, frameBytes: Int) -> [Int16] {
        guard session != nil, frameBytes > 0 else { return [] }
        pending.append(data)
        var result: [Int16] = []
        while pending.count >= frameBytes {
            result += decoder.decode(Data(pending.prefix(frameBytes)))
            pending.removeFirst(frameBytes)
        }
        sampleCount += result.count
        peak = max(peak, result.map { abs(Int($0)) }.max() ?? 0)
        return result
    }

    mutating func stop() {
        session = nil
        pending.removeAll()
        decoder.reset()
    }
}
