import Foundation

enum AIVoiceBuiltInAction {
    case system(AIVoiceSystemControlAction)
    case desktop(AIVoiceDesktopAction)
    case systemAppearance(AIVoiceSystemAppearance)
    case currentAppSettings
}

enum AIVoiceBuiltInResolution {
    case ready(AIVoiceBuiltInAction, summary: String)
    case invalid(String)
    case unknown
}

/// Fixed commands and typed arguments form the boundary between model output
/// and macOS. No user-supplied paths, key codes or executable text reach it.
enum AIVoiceBuiltInCommands {
    static let descriptors: [AIVoiceCapabilityDescriptor] = [
        .init(id: "adjust_volume", summary: "调大或调小系统输出音量。direction 必须为 up/down；amount 为可选的 1...100 整数字符串，单位为百分点，没指定时省略并默认 10。调大将解除静音。", parameterNames: ["direction", "amount"], examples: ["声音大一点", "音量调低20个百分点"]),
        .init(id: "set_volume", summary: "把系统输出音量设为绝对百分比。percent 必须为 0...100 整数字符串；大于0时解除静音。", parameterNames: ["percent"], examples: ["音量设为50%", "把声音调到百分之三十"]),
        .init(id: "set_mute", summary: "系统输出静音或取消静音。muted 必须为 true/false 字符串。取消静音不提高原有音量。", parameterNames: ["muted"], examples: ["静音", "取消静音"]),
        .init(id: "get_volume", summary: "查询当前系统输出音量和静音状态，无参数。", parameterNames: [], examples: ["现在音量是多少"]),
        .init(id: "adjust_brightness", summary: "调高或调低显示器硬件亮度，优先内建屏，否则主屏。direction 必须为 up/down；amount 为可选 1...100 整数字符串，单位百分点，没指定时省略并默认10。不支持指定另一块屏幕。", parameterNames: ["direction", "amount"], examples: ["屏幕暗一点", "亮度提高20个百分点"]),
        .init(id: "set_brightness", summary: "设置显示器硬件亮度，优先内建屏，否则主屏。percent 为 0...100 整数字符串。不代表键盘背光、光缝亮度或指定其他显示器。", parameterNames: ["percent"], examples: ["屏幕亮度设为60%"]),
        .init(id: "get_brightness", summary: "查询内建屏（没有则主屏）的硬件亮度，无参数。", parameterNames: [], examples: ["屏幕亮度是多少"]),
        .init(id: "set_system_appearance", summary: "设置 macOS 系统全局外观。mode 只能为 light（日间/浅色）、dark（夜间/深色）、auto（自动）。打开日间模式/打开夜间模式分别对应light/dark；跟随系统/自动外观对应auto，按系统日程切换。不会修改Joy Harness自身主题偏好，也不代表夜览Night Shift、屏幕亮度或打开设置页面。", parameterNames: ["mode"], examples: ["打开日间模式", "打开夜间模式", "跟随系统"]),
        .init(id: "media_control", summary: "向系统媒体会话发送播放/暂停切换、下一首或上一首。action 仅 play_pause/next/previous。不知道当前播放状态；仅明确要求切换播放/暂停时使用 play_pause，单独要求播放或暂停必须说明只能切换并追问，不能假定会变成指定状态。不支持指定播放器或歌曲。", parameterNames: ["action"], examples: ["切换播放暂停", "下一首", "上一首"]),
        .init(id: "open_folder", summary: "在Finder打开固定常用目录。folder 只能 home/desktop/downloads/documents/applications/utilities/pictures/movies/music，不接受任意路径或文件名。", parameterNames: ["folder"], examples: ["打开下载文件夹", "打开桌面文件夹", "打开实用工具"]),
        .init(id: "open_screenshot_tool", summary: "打开系统截屏工具，由用户选择区域与保存操作。无参数；不会立即截屏或录屏。", parameterNames: [], examples: ["打开截屏工具"]),
        .init(id: "open_current_app_settings", summary: "打开当前前台应用的设置或偏好设置，向提交语音时的前台应用发送一次Command+逗号。无参数，目标由本机捕获，不能指定其他应用、PID、路径或快捷键。执行时前台已变化则不发送。仅请求打开，不能保证所有应用支持；不是打开macOS系统设置，也不是微信输入法专用设置入口。", parameterNames: [], examples: ["打开当前应用的设置", "打开这个软件的偏好设置"]),
        .init(id: "get_datetime", summary: "查询本机当前日期、星期和时间，无参数。", parameterNames: [], examples: ["现在几点", "今天几号"]),
        .init(id: "get_battery", summary: "查询Mac内建电池电量及充电状态，无参数。不查询手柄/鼠标/耳机电池。", parameterNames: [], examples: ["电脑还剩多少电"]),
    ]
    static let ids = Set(descriptors.map(\.id))

    static func resolve(_ command: AIVoiceCommand) -> AIVoiceBuiltInResolution {
        let p = command.parameters
        switch command.capabilityID {
        case "adjust_volume", "adjust_brightness":
            guard Set(p.keys).isSubset(of: ["direction", "amount"]),
                  let direction = p["direction"], ["up", "down"].contains(direction),
                  let amount = integer(p["amount"] ?? "10", in: 1...100) else {
                return .invalid("请指定调高或调低，以及 1–100 的整数百分点；未指定幅度时调整 10 个百分点。")
            }
            let delta = direction == "up" ? amount : -amount
            let volume = command.capabilityID == "adjust_volume"
            return .ready(.system(volume ? .volumeAdjust(delta) : .brightnessAdjust(delta)),
                          summary: "将\(volume ? "音量" : "屏幕亮度")\(delta > 0 ? "调高" : "调低") \(amount) 个百分点")
        case "set_volume", "set_brightness":
            guard Set(p.keys) == ["percent"], let value = integer(p["percent"], in: 0...100) else {
                return .invalid("请提供 0–100 的整数百分比。")
            }
            let volume = command.capabilityID == "set_volume"
            return .ready(.system(volume ? .volumeSet(value) : .brightnessSet(value)),
                          summary: "将\(volume ? "音量" : "屏幕亮度")设为 \(value)%")
        case "set_mute":
            guard Set(p.keys) == ["muted"], let muted = p["muted"], ["true", "false"].contains(muted) else {
                return .invalid("请明确要静音还是取消静音。")
            }
            return .ready(.system(.muteSet(muted == "true")), summary: muted == "true" ? "静音" : "取消静音")
        case "set_system_appearance":
            guard Set(p.keys) == ["mode"], let value = p["mode"],
                  let mode = AIVoiceSystemAppearance(rawValue: value) else {
                return .invalid("请指定 macOS 的日间（浅色）、夜间（深色）或自动外观。")
            }
            return .ready(.systemAppearance(mode), summary: "将 macOS 外观设为\(mode.title)")
        case "media_control":
            guard Set(p.keys) == ["action"], let value = p["action"], let action = AIVoiceMediaAction(rawValue: value) else {
                return .invalid("媒体控制支持切换播放/暂停、下一首和上一首。")
            }
            return .ready(.desktop(.media(action)), summary: "发送媒体控制")
        case "open_folder":
            guard Set(p.keys) == ["folder"], let value = p["folder"], let folder = AIVoiceFolder(rawValue: value) else {
                return .invalid("请指定主目录、桌面、下载、文稿、应用程序、实用工具、图片、影片或音乐文件夹。")
            }
            return .ready(.desktop(.openFolder(folder)), summary: "打开\(folder.title)")
        case "get_volume", "get_brightness", "open_screenshot_tool", "open_current_app_settings", "get_datetime", "get_battery":
            guard p.isEmpty else { return .invalid("这项操作不接受额外参数。") }
            switch command.capabilityID {
            case "get_volume": return .ready(.system(.volumeRead), summary: "查询音量")
            case "get_brightness": return .ready(.system(.brightnessRead), summary: "查询屏幕亮度")
            case "open_screenshot_tool": return .ready(.desktop(.openScreenshotTool), summary: "打开截屏工具")
            case "open_current_app_settings": return .ready(.currentAppSettings, summary: "打开当前应用的设置")
            case "get_datetime": return .ready(.desktop(.dateTime), summary: "查询日期和时间")
            default: return .ready(.desktop(.batteryStatus), summary: "查询电脑电量")
            }
        default: return .unknown
        }
    }

    private static func integer(_ text: String?, in range: ClosedRange<Int>) -> Int? {
        guard let text, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), range.contains(number) else { return nil }
        return number
    }
}
