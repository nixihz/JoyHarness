import Foundation

struct JoyConStickCalibration: Equatable {
    struct Axis: Equatable {
        let center: Int
        let negativeRange: Int
        let positiveRange: Int

        var isValid: Bool {
            center > 0 && center < 0xfff &&
                negativeRange > 0 && positiveRange > 0 &&
                center - negativeRange >= 0 && center + positiveRange <= 0xfff
        }

        func normalize(_ value: Int) -> Float {
            let delta = value - center
            let range = delta < 0 ? negativeRange : positiveRange
            return min(max(Float(delta) / Float(range), -1), 1)
        }
    }

    let x: Axis
    let y: Axis
    let source: JoyConIMUCalibrationSource

    static let `default` = JoyConStickCalibration(
        x: Axis(center: 2048, negativeRange: 1433, positiveRange: 1433),
        y: Axis(center: 2048, negativeRange: 1433, positiveRange: 1433),
        source: .default
    )

    init(x: Axis, y: Axis, source: JoyConIMUCalibrationSource) {
        self.x = x
        self.y = y
        self.source = source
    }

    init?(data: [UInt8], side: JoyConSide, source: JoyConIMUCalibrationSource) {
        guard data.count == 9 else { return nil }
        let pairs = stride(from: 0, to: 9, by: 3).map {
            JoyConHIDStickReportParser.unpack(data, at: $0)
        }
        // 左右手柄的校准字段顺序不同，不能复用同一组偏移。
        let center = pairs[side == .left ? 1 : 0]
        let negative = pairs[side == .left ? 2 : 1]
        let positive = pairs[side == .left ? 0 : 2]
        let x = Axis(center: center.x, negativeRange: negative.x, positiveRange: positive.x)
        let y = Axis(center: center.y, negativeRange: negative.y, positiveRange: positive.y)
        guard x.isValid, y.isValid else { return nil }
        self.init(x: x, y: y, source: source)
    }
}

struct JoyConHIDStickSnapshot: Equatable {
    let stick: JoyConStick
    let calibrationSource: JoyConIMUCalibrationSource
}

enum JoyConHIDStickReportParser {
    static func snapshot(
        from report: [UInt8],
        side: JoyConSide,
        calibration: JoyConStickCalibration
    ) -> JoyConHIDStickSnapshot? {
        guard let id = report.first,
              id == JoyConHIDInputReportParser.fullInputReportID ||
                id == JoyConHIDInputReportParser.subcommandReplyReportID,
              report.count >= 12 else { return nil }
        let raw = unpack(report, at: side == .left ? 6 : 9)
        return JoyConHIDStickSnapshot(
            stick: JoyConStick(x: calibration.x.normalize(raw.x), y: calibration.y.normalize(raw.y)),
            calibrationSource: calibration.source
        )
    }

    static func unpack(_ bytes: [UInt8], at offset: Int) -> (x: Int, y: Int) {
        (
            Int(bytes[offset]) | ((Int(bytes[offset + 1]) & 0x0f) << 8),
            (Int(bytes[offset + 1]) >> 4) | (Int(bytes[offset + 2]) << 4)
        )
    }
}

enum JoyConHIDStickAdapter {
    static func apply(
        _ snapshot: JoyConHIDStickSnapshot?,
        to sample: JoyConProfileSample,
        side: JoyConSide,
        paired: Bool,
        orientation: JoyConOrientation
    ) -> JoyConProfileSample {
        guard let snapshot else { return sample }
        var stick = snapshot.stick
        // HID 是竖握物理坐标，横握时才旋转，避免重复应用 Apple 的横握转换。
        if !paired && orientation == .horizontal {
            stick = side == .left
                ? JoyConStick(x: -stick.y, y: stick.x)
                : JoyConStick(x: stick.y, y: -stick.x)
        }
        var inputs = sample.snapshot
        if paired && side == .right {
            inputs.secondaryStick = stick
        } else {
            inputs.primaryStick = stick
        }
        return JoyConProfileSample(snapshot: inputs, availableInputs: sample.availableInputs)
    }
}
