import Foundation

struct DashboardPresentation {
    let status: DashboardStatus
    let freshness: StatusFreshness
    var orientation: JoyConOrientation = .vertical

    var isFresh: Bool { freshness == .fresh }
    var unknown: String { L10n.text("未知", "Unknown") }
    var family: ControllerFamily { status.controllerFamily.flatMap(ControllerFamily.init(rawValue:)) ?? .generic }
    var connected: Bool? {
        guard isFresh else { return nil }
        return status.controllerConnected
    }
    var connectionTitle: String {
        guard let connected else { return L10n.text("连接状态未知", "Connection unknown") }
        return connected ? L10n.text("已连接", "Connected") : L10n.text("未连接控制器", "No controller connected")
    }
    var permissionSummary: String {
        guard isFresh else { return L10n.text("权限未知", "Permissions unknown") }
        if !status.accessibility || status.inputMonitoring == false { return L10n.text("需要授权", "Permissions needed") }
        if status.inputMonitoring == nil { return L10n.text("权限待确认", "Check permissions") }
        return L10n.text("权限已授权", "Permissions granted")
    }
    var connectionSymbol: String {
        connected == true ? "checkmark.circle.fill" : connected == false ? "gamecontroller" : "questionmark.circle"
    }
    var canTestHaptics: Bool { connected == true && status.haptics }
    var mappingPaused: Bool { !isFresh || status.isNativeMode || connected != true }
    func capability(_ value: Bool?) -> String {
        guard isFresh, let value else { return unknown }
        return value ? L10n.text("可用", "Available") : L10n.text("不可用", "Unavailable")
    }
    func authorization(_ value: Bool?) -> String {
        guard isFresh, let value else { return unknown }
        return value ? L10n.text("已授权", "Authorized") : L10n.text("未授权", "Not authorized")
    }
    func batteryDescription(_ level: Float?) -> String {
        guard isFresh, let level, level.isFinite else { return unknown }
        return "\(Int((min(max(level, 0), 1) * 100).rounded()))%"
    }
    var controllerFamilyName: String {
        guard let raw = status.controllerFamily,
              let family = ControllerFamily(rawValue: raw) else {
            return unknown
        }
        return family.displayName
    }

    var controllerRows: [(String, String)] {
        var rows: [(String, String)] = [
            (L10n.text("设备", "Device"), connected == false ? connectionTitle : status.controller),
            (L10n.text("类型", "Type"), controllerFamilyName),
            (L10n.text("震动", "Haptics"), capability(status.haptics)),
            (L10n.text("触控板", "Touchpad"), capability(status.controllerTouchpad)),
        ]
        if family != .xiaomiRemote, !family.isJoyCon {
            rows.append((L10n.text("RT / R2 扳机", "RT / R2 Trigger"), rightTriggerDescription))
        }
        rows.append((L10n.text("电量", "Battery"), batteryDescription(status.controllerBatteryLevel)))
        if let state = status.controllerBatteryState, state == "charging" || state == "full" {
            rows.append((L10n.text("充电状态", "Charging"), state == "full" ? L10n.text("已充满", "Fully charged") : L10n.text("正在充电", "Charging")))
        }
        if let mode = status.joyConMode {
            let modeName = switch JoyConMode(rawValue: mode) {
            case .pair: L10n.text("双支组合", "Paired")
            case .left: "\(L10n.text("左单支", "Left Solo")) · \(orientation.displayName)"
            case .right: "\(L10n.text("右单支", "Right Solo")) · \(orientation.displayName)"
            case nil: mode
            }
            rows.append((L10n.text("Joy-Con 模式", "Joy-Con Mode"), modeName))
            rows.append(("Joy-Con L", joyConSideDescription(
                connected: status.joyConLeftConnected,
                battery: status.joyConLeftBatteryLevel,
                haptics: status.joyConLeftHaptics,
                motion: status.joyConLeftMotion
            )))
            rows.append(("Joy-Con R", joyConSideDescription(
                connected: status.joyConRightConnected,
                battery: status.joyConRightBatteryLevel,
                haptics: status.joyConRightHaptics,
                motion: status.joyConRightMotion
            )))
            appendMotionRows(status.joyConLeftIMU, side: "L", to: &rows)
            appendMotionRows(status.joyConRightIMU, side: "R", to: &rows)
        }
        return rows.map { ($0.0, isFresh ? $0.1 : unknown) }
    }

    func appendMotionRows(
        _ snapshot: JoyConHIDMotionSnapshot?,
        side: String,
        to rows: inout [(String, String)]
    ) {
        guard let snapshot else { return }
        rows.append((
            "Joy-Con \(side) " + L10n.text("加速度 (g)", "Acceleration (g)"),
            vectorDescription(snapshot.accelerationG)
        ))
        rows.append((
            "Joy-Con \(side) " + L10n.text("角速度 (°/s)", "Rotation (°/s)"),
            vectorDescription(snapshot.rotationRateDPS)
                + " · " + calibrationDescription(snapshot.calibrationSource)
        ))
    }

    func vectorDescription(_ vector: JoyConVector3) -> String {
        String(format: "X %.2f · Y %.2f\nZ %.2f", vector.x, vector.y, vector.z)
    }

    func calibrationDescription(_ source: JoyConIMUCalibrationSource) -> String {
        switch source {
        case .user: L10n.text("用户校准", "User calibration")
        case .factory: L10n.text("工厂校准", "Factory calibration")
        case .default: L10n.text("默认校准", "Default calibration")
        }
    }

    func joyConSideDescription(
        connected: Bool?,
        battery: Float?,
        haptics: Bool?,
        motion: Bool?
    ) -> String {
        guard let connected else { return unknown }
        guard connected else { return L10n.text("未连接", "Disconnected") }
        var details: [String] = []
        if let battery { details.append("\(Int((battery * 100).rounded()))%") }
        if haptics == true { details.append(L10n.text("震动", "Haptics")) }
        if motion == true { details.append(L10n.text("体感", "Motion")) }
        return details.isEmpty ? L10n.text("已连接", "Connected") : details.joined(separator: " · ")
    }

    var rightTriggerDescription: String {
        switch status.controllerFamily.flatMap(ControllerFamily.init(rawValue:)) {
        case .dualSense:
            L10n.text("自适应反馈：", "Adaptive feedback: ") + capability(status.controllerAdaptiveTrigger)
        case .xbox:
            L10n.text("扳机震动：", "Impulse haptics: ") + capability(status.controllerImpulseTrigger)
        default:
            L10n.text("标准输入", "Standard Input")
        }
    }

    private func localizedRemoteVoiceStatus(_ value: String) -> String {
        let messages = [
            ("遥控器麦克风未连接", "Remote microphone disconnected"),
            ("遥控器麦克风连接超时；请按键唤醒", "Remote microphone connection timed out; press a button to wake it"),
            ("遥控器麦克风已连接；请在设置中启用麦克风组件", "Remote microphone connected; enable the microphone component in Settings"),
            ("遥控器麦克风已连接；请在设置中选择语音输入", "Remote microphone connected; select the voice input in Settings"),
            ("遥控器麦克风已连接（Joy Harness）", "Remote microphone connected (Joy Harness)"),
            ("遥控器麦克风已连接", "Remote microphone connected"),
            ("遥控器语音协议不受支持", "Remote voice protocol is unsupported"),
            ("遥控器返回了不受支持的语音格式", "Remote returned an unsupported voice format"),
            ("遥控器麦克风已断开，等待重连", "Remote microphone disconnected; waiting to reconnect"),
            ("遥控器语音通知订阅失败", "Remote voice notification subscription failed"),
            ("语音设备型号不是 RC003-MS", "Voice device is not an RC003-MS"),
        ]
        if let message = messages.first(where: { $0.0 == value }) { return L10n.text(message.0, message.1) }
        return value
    }

    var voiceInputDescription: String {
        if status.controllerFamily == ControllerFamily.xiaomiRemote.rawValue,
           let remoteStatus = status.remoteVoiceStatus {
            return localizedRemoteVoiceStatus(remoteStatus)
        }
        guard status.microphone, let name = status.voiceInput, !name.isEmpty else {
            guard let defaultInput = status.defaultVoiceInput, !defaultInput.isEmpty else {
                return status.controllerFamily == ControllerFamily.dualSense.rawValue
                    ? L10n.text(
                        "手柄未提供；系统也无可用输入",
                        "Controller input unavailable; no system input available"
                    )
                    : L10n.text("系统无可用输入", "No system input available")
            }
            return status.controllerFamily == ControllerFamily.dualSense.rawValue
                ? L10n.text(
                    "手柄未提供；当前用 \(defaultInput)",
                    "Controller input unavailable; using \(defaultInput)"
                )
                : L10n.text("当前用 \(defaultInput)", "Using \(defaultInput)")
        }
        let transport = status.voiceInputTransport.flatMap { $0.isEmpty ? nil : $0 }
            ?? L10n.text("未知连接", "Unknown connection")
        return status.voiceInputDefault == true
            ? L10n.text("\(name)（\(transport)，默认）", "\(name) (\(transport), default)")
            : L10n.text("\(name)（\(transport)，未选中）", "\(name) (\(transport), not selected)")
    }


}
