import AppKit
import ApplicationServices
import IOKit.hidsystem
import IOKit.ps

enum AIVoiceMediaAction: String, CaseIterable, Sendable {
    case playPause = "play_pause"
    case next, previous

    var title: String {
        switch self {
        case .playPause: "切换播放／暂停"
        case .next: "下一首"
        case .previous: "上一首"
        }
    }
}

enum AIVoiceFolder: String, CaseIterable, Sendable {
    case home, desktop, downloads, documents, applications, utilities, pictures, movies, music

    var title: String {
        switch self {
        case .home: "个人文件夹"
        case .desktop: "桌面"
        case .downloads: "下载"
        case .documents: "文稿"
        case .applications: "应用程序"
        case .utilities: "实用工具"
        case .pictures: "图片"
        case .movies: "影片"
        case .music: "音乐"
        }
    }
}

enum AIVoiceDesktopAction: Equatable, Sendable {
    case media(AIVoiceMediaAction)
    case openFolder(AIVoiceFolder)
    case openScreenshotTool
    case dateTime
    case batteryStatus
}

@MainActor
protocol AIVoiceDesktopActing {
    func execute(_ action: AIVoiceDesktopAction) async -> AIVoiceExecutionResult
}

enum AIVoiceBatteryPower: Equatable, Sendable {
    case charging, externalPower, battery, unknown
}

enum AIVoiceBatteryReading: Equatable, Sendable {
    case unavailable, notPresent
    case available(percent: Int, power: AIVoiceBatteryPower)

    /// IOPowerSources also lists UPS units. Only present internal batteries
    /// describe this Mac's battery; missing capacity must never become 0%.
    static func decode(_ descriptions: [[String: Any]]?) -> Self {
        guard let descriptions else { return .unavailable }
        let internalSources = descriptions.filter {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        var totalCurrent: Double = 0
        var totalMaximum: Double = 0
        var powers: [AIVoiceBatteryPower] = []
        for source in internalSources {
            guard let present = source[kIOPSIsPresentKey] as? Bool else { return .unavailable }
            guard present else { continue }
            guard let current = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                  let maximum = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue,
                  current.isFinite, maximum.isFinite, maximum > 0,
                  current >= 0, current <= maximum else { return .unavailable }
            totalCurrent += current
            totalMaximum += maximum
            if source[kIOPSIsChargingKey] as? Bool == true {
                powers.append(.charging)
            } else if source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue {
                powers.append(.externalPower)
            } else if source[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue {
                powers.append(.battery)
            } else {
                powers.append(.unknown)
            }
        }
        guard !powers.isEmpty else { return .notPresent }
        guard totalCurrent.isFinite, totalMaximum.isFinite, totalMaximum > 0 else { return .unavailable }
        let power: AIVoiceBatteryPower
        if powers.contains(.charging) { power = .charging }
        else if powers.allSatisfy({ $0 == .externalPower }) { power = .externalPower }
        else if powers.allSatisfy({ $0 == .battery }) { power = .battery }
        else { power = .unknown }
        return .available(percent: Int((totalCurrent / totalMaximum * 100).rounded()), power: power)
    }
}

@MainActor
protocol AIVoiceDesktopEnvironment {
    var canPostMediaEvents: Bool { get }
    func postMediaAction(_ action: AIVoiceMediaAction) -> Bool
    func folderURL(_ folder: AIVoiceFolder) -> URL?
    func isDirectory(_ url: URL) -> Bool
    func openFolder(at url: URL) -> Bool
    func openScreenshotTool() -> Bool
    func currentDate() -> Date
    var timeZone: TimeZone { get }
    func batteryReading() -> AIVoiceBatteryReading
}

@MainActor
final class AIVoiceMacDesktopActions: AIVoiceDesktopActing {
    private let environment: any AIVoiceDesktopEnvironment

    init(environment: (any AIVoiceDesktopEnvironment)? = nil) {
        self.environment = environment ?? AIVoiceMacDesktopEnvironment()
    }

    func execute(_ action: AIVoiceDesktopAction) async -> AIVoiceExecutionResult {
        guard !Task.isCancelled else {
            return .init(status: .cancelled, message: "已取消，未执行操作。")
        }
        switch action {
        case .media(let media):
            guard environment.canPostMediaEvents else {
                return .init(status: .failed, message: "缺少辅助功能权限，未发送媒体按键；请在系统设置中允许 Joy Harness 控制电脑。")
            }
            guard environment.postMediaAction(media) else {
                return .init(status: .failed, message: "无法发送媒体按键，没有重试。")
            }
            return .init(status: .unconfirmed,
                         message: "已发送“\(media.title)”媒体按键；无法确认播放器是否响应或当前播放状态。")
        case .openFolder(let folder):
            guard let url = environment.folderURL(folder), url.isFileURL,
                  environment.isDirectory(url) else {
                return .init(status: .failed, message: "无法访问本机的\(folder.title)文件夹。")
            }
            guard environment.openFolder(at: url) else {
                return .init(status: .failed, message: "系统没有接受打开\(folder.title)文件夹的请求。")
            }
            return .init(status: .unconfirmed, message: "已请求打开\(folder.title)文件夹，尚无法确认 Finder 窗口。")
        case .openScreenshotTool:
            guard environment.openScreenshotTool() else {
                return .init(status: .failed, message: "无法打开 macOS 截屏工具。")
            }
            return .init(status: .unconfirmed, message: "已请求打开 macOS 截屏工具；请在工具中选择范围并完成截屏。")
        case .dateTime:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = environment.timeZone
            formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm:ss"
            return .init(status: .succeeded,
                         message: "本机时间：\(formatter.string(from: environment.currentDate()))（\(environment.timeZone.identifier)）。")
        case .batteryStatus:
            switch environment.batteryReading() {
            case .unavailable:
                return .init(status: .failed, message: "暂时无法读取本机电池状态。")
            case .notPresent:
                return .init(status: .succeeded, message: "未检测到本机内置电池。")
            case .available(let percent, let power):
                let state: String
                switch power {
                case .charging: state = "正在充电"
                case .externalPower: state = "已接通外部电源"
                case .battery: state = "正在使用电池供电"
                case .unknown: state = "供电状态暂不可用"
                }
                return .init(status: .succeeded, message: "本机电池电量 \(percent)%，\(state)。")
            }
        }
    }
}

@MainActor
final class AIVoiceMacDesktopEnvironment: AIVoiceDesktopEnvironment {
    private let workspace: NSWorkspace
    private let fileManager: FileManager

    init(workspace: NSWorkspace = .shared, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    var canPostMediaEvents: Bool { CGPreflightPostEventAccess() }

    func postMediaAction(_ action: AIVoiceMediaAction) -> Bool {
        guard canPostMediaEvents, let events = Self.mediaEvents(for: action) else { return false }
        // Construct both events first, then send without suspension. There is
        // no timer, repeating key, or cancellation point between down and up.
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        return true
    }

    static func mediaEvents(for action: AIVoiceMediaAction) -> (down: CGEvent, up: CGEvent)? {
        let key: Int
        switch action {
        case .playPause: key = Int(NX_KEYTYPE_PLAY)
        case .next: key = Int(NX_KEYTYPE_NEXT)
        case .previous: key = Int(NX_KEYTYPE_PREVIOUS)
        }
        func event(down: Bool) -> CGEvent? {
            let state = down ? 0xA00 : 0xB00
            return NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: .init(rawValue: UInt(state)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 8,
                data1: (key << 16) | state, data2: -1
            )?.cgEvent
        }
        guard let down = event(down: true), let up = event(down: false) else { return nil }
        return (down, up)
    }

    func folderURL(_ folder: AIVoiceFolder) -> URL? {
        let directory: FileManager.SearchPathDirectory
        let domain: FileManager.SearchPathDomainMask
        switch folder {
        case .home: return fileManager.homeDirectoryForCurrentUser
        case .desktop: directory = .desktopDirectory; domain = .userDomainMask
        case .downloads: directory = .downloadsDirectory; domain = .userDomainMask
        case .documents: directory = .documentDirectory; domain = .userDomainMask
        case .applications: directory = .applicationDirectory; domain = .localDomainMask
        case .utilities: directory = .adminApplicationDirectory; domain = .systemDomainMask
        case .pictures: directory = .picturesDirectory; domain = .userDomainMask
        case .movies: directory = .moviesDirectory; domain = .userDomainMask
        case .music: directory = .musicDirectory; domain = .userDomainMask
        }
        return fileManager.urls(for: directory, in: domain).first
    }

    func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    func openFolder(at url: URL) -> Bool { workspace.open(url) }

    func openScreenshotTool() -> Bool {
        guard let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.screenshot.launcher") else { return false }
        return workspace.open(url)
    }

    func currentDate() -> Date { Date() }
    var timeZone: TimeZone { .current }

    func batteryReading() -> AIVoiceBatteryReading {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailable
        }
        var descriptions: [[String: Any]] = []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(information, source)?.takeUnretainedValue()
                as? [String: Any] else { return .unavailable }
            descriptions.append(description)
        }
        return .decode(descriptions)
    }
}
