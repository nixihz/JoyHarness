// Audio output framing adapted from ControlDeck, commit
// 4282692787c2c6640946302d45205740e84c3b15.
// Copyright (c) 2026 Ian Hansel. MIT License; see
// Sources/JoyHarness/Resources/ThirdPartyLicenses/ControlDeck-MIT.txt.
// Input validation and mute-preserving state handling are JoyHarness changes.

import Foundation

struct DualSenseBluetoothMicrophonePacket: Equatable, Sendable {
    /// Raw four-bit transport sequence (modulo 16). A per-microphone-packet
    /// increment has NOT been established on our supported hardware. Do not
    /// infer a loss count from this field alone.
    let sequence: UInt8
    let opusPayload: Data
    /// Host monotonic arrival time, not the controller's sampling timestamp.
    let arrivalNanoseconds: UInt64
}

struct DualSenseBluetoothControlFrame: Equatable, Sendable {
    let leftStickX: UInt8
    let leftStickY: UInt8
    let rightStickX: UInt8
    let rightStickY: UInt8
    let leftTrigger: UInt8
    let rightTrigger: UInt8
    let buttons0: UInt8
    let buttons1: UInt8
    let buttons2: UInt8
    /// The controller-reported mute bit. Hardware validation is still required
    /// before treating this as evidence of the physical microphone's state.
    let microphoneMuted: Bool

    var isNeutral: Bool {
        [leftStickX, leftStickY, rightStickX, rightStickY].allSatisfy { (112...144).contains($0) }
            && leftTrigger <= 8 && rightTrigger <= 8
            && buttons0 == 0x08 && buttons1 == 0 && buttons2 & 0x07 == 0
    }
}

enum DualSenseBluetoothInputRejection: Equatable, Sendable {
    case unsupportedReportID(UInt32)
    case invalidLength(Int)
    case mismatchedReportID
    case invalidCRC
    case unknownSubtype(UInt8)
}

enum DualSenseBluetoothInputReport: Equatable, Sendable {
    case control(DualSenseBluetoothControlFrame)
    case microphone(DualSenseBluetoothMicrophonePacket)
    case unknown(DualSenseBluetoothInputRejection)
}

/// Sony's vendor HID audio transport, not a standard Bluetooth audio profile.
///
/// All outbound buffers include their report ID. The owner must serialize
/// writes with other controller output and provide its shared four-bit sequence.
/// Input is fail-closed: exact supported layout and HIDP-input CRC are required.
/// IOHID layout/CRC acceptance still needs a physical-controller capture; these
/// checks deliberately do not fall back to accepting unverified audio bytes.
enum DualSenseBluetoothAudioProtocol {
    static let microphoneSampleRate = 48_000
    static let microphoneFrameCount = 480
    static let microphoneOpusByteCount = 71
    static let bluetoothInputReportByteCount = 78
    static let sequenceModulus = 16

    /// Initialize only the audio routing fields. This does not open or close
    /// the stream; use the explicit stream command for startup cleanup.
    /// No microphone mute, LED, trigger or lightbar validity bits.
    static func audioInitializationReport(sequence: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 142)
        report[0] = 0x32
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x90
        report[3] = 63
        report[4] = 0x80 // Audio control valid; no microphone-volume validity.
        report[4 + 7] = 0x09 // Internal microphone with voice processing.
        sealOutput(&report)
        return report
    }

    /// Configure gain/routing without asserting either mute/LED validity bit.
    /// A prior input snapshot can race a physical mute press, so `muted` is an
    /// admission hint for the owner, never a state to write back to hardware.
    /// Firmware requiring an explicit mic-gate clear remains unsupported until
    /// tested; never silently add an unmute write to make capture work.
    /// Stop the wireless stream with microphoneStreamReport(active: false).
    static func microphoneStateReport(active: Bool, muted _: Bool, sequence: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 78)
        report[0] = 0x31
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x10
        let state = 3
        report[state] = 0xc0 // Audio control and microphone volume valid.
        report[state + 1] = 0x80 // Audio control 2 only; do NOT write mute/LED.
        // Keep gain prepared even when physically muted: otherwise releasing
        // the controller's mute button would leave a live session at zero gain.
        report[state + 6] = active ? 0x08 : 0
        report[state + 7] = 0x09
        report[state + 37] = 0x01
        sealOutput(&report)
        return report
    }

    /// Uses ControlDeck's complete control + silent-haptic framing. This is
    /// deliberately kept together, rather than mixing templates from unrelated
    /// firmware experiments. No speaker payload is transmitted.
    static func microphoneStreamReport(active: Bool, sequence: UInt8) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 142)
        report[0] = 0x32
        report[1] = (sequence & 0x0f) << 4
        report[2] = 0x91
        report[3] = 0x07
        report[4] = active ? 0xff : 0xfe
        for index in 5...9 { report[index] = 0x40 }
        report[10] = sequence & 0x0f
        report[11] = 0x92
        report[12] = 0x40
        sealOutput(&report)
        return report
    }

    /// IOHID supplies the report ID separately and may also leave it in the
    /// buffer. Exact size disambiguates a stripped header which itself is 0x31.
    /// This does not accept a raw L2CAP/HIDP prefix (0xA1) or truncated buffers.
    static func classifyInput(
        reportID: UInt32,
        bytes: [UInt8],
        arrivalNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> DualSenseBluetoothInputReport {
        guard reportID == 0x31 else { return .unknown(.unsupportedReportID(reportID)) }
        let report: [UInt8]
        switch bytes.count {
        case bluetoothInputReportByteCount:
            guard bytes[0] == 0x31 else { return .unknown(.mismatchedReportID) }
            report = bytes
        case bluetoothInputReportByteCount - 1:
            report = [0x31] + bytes
        default:
            return .unknown(.invalidLength(bytes.count))
        }
        let checksumOffset = report.count - 4
        let expected = (0..<4).reduce(UInt32(0)) {
            $0 | UInt32(report[checksumOffset + $1]) << (8 * $1)
        }
        guard transportCRC(prefix: 0xa1, bytes: report[..<checksumOffset]) == expected else {
            return .unknown(.invalidCRC)
        }
        let subtype = report[1] & 0x0f
        switch subtype {
        case 0x01:
            // State starts at byte 2; the report's tag at byte 1 is not state.
            return .control(DualSenseBluetoothControlFrame(
                leftStickX: report[2], leftStickY: report[3],
                rightStickX: report[4], rightStickY: report[5],
                leftTrigger: report[6], rightTrigger: report[7],
                buttons0: report[9], buttons1: report[10], buttons2: report[11],
                microphoneMuted: report[55] & 0x04 != 0
            ))
        case 0x02, 0x03:
            // Both subtype forms are documented in community captures. Never
            // route either to the controls, even if Opus later fails to decode.
            return .microphone(DualSenseBluetoothMicrophonePacket(
                sequence: report[1] >> 4,
                opusPayload: Data(report[3..<(3 + microphoneOpusByteCount)]),
                arrivalNanoseconds: arrivalNanoseconds
            ))
        default:
            return .unknown(.unknownSubtype(subtype))
        }
    }

    static func outputCRC(for bytesWithoutChecksum: [UInt8]) -> UInt32 {
        transportCRC(prefix: 0xa2, bytes: bytesWithoutChecksum[...])
    }

    private static func transportCRC(prefix: UInt8, bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        func accumulate(_ byte: UInt8) {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320)
            }
        }
        accumulate(prefix)
        for byte in bytes { accumulate(byte) }
        return ~crc
    }

    private static func sealOutput(_ report: inout [UInt8]) {
        let offset = report.count - 4
        let crc = outputCRC(for: Array(report[..<offset]))
        for byte in 0..<4 { report[offset + byte] = UInt8(truncatingIfNeeded: crc >> (8 * byte)) }
    }
}
