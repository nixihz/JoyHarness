import Foundation

/// Fixed identifiers inspected in macOS ExtensionKit Info.plists. Opening a
/// pane never grants permissions or changes the setting it describes.
enum AIVoiceSystemSettingsPage: String, CaseIterable, Sendable {
    case bluetooth, sound, keyboard, wifi, displays, battery, network, privacy
    case accessibility, notifications, focus, appearance, desktopDock = "desktop_dock"
    case mouse, trackpad, dateTime = "date_time", languageRegion = "language_region"
    case storage, softwareUpdate = "software_update", loginItems = "login_items"
    case general, wallpaper, screenTime = "screen_time", sharing, printers, users
    case lockScreen = "lock_screen"

    private var metadata: (title: String, english: String, identifier: String) {
        switch self {
        case .bluetooth: return ("蓝牙", "Bluetooth", "com.apple.BluetoothSettings")
        case .sound: return ("声音", "Sound", "com.apple.Sound-Settings.extension")
        case .keyboard: return ("键盘", "Keyboard", "com.apple.Keyboard-Settings.extension")
        case .wifi: return ("Wi-Fi", "Wi-Fi", "com.apple.wifi-settings-extension")
        case .displays: return ("显示器", "Displays", "com.apple.Displays-Settings.extension")
        case .battery: return ("电池", "Battery", "com.apple.Battery-Settings.extension")
        case .network: return ("网络", "Network", "com.apple.Network-Settings.extension")
        case .privacy: return ("隐私与安全性", "Privacy & Security", "com.apple.settings.PrivacySecurity.extension")
        case .accessibility: return ("辅助功能", "Accessibility", "com.apple.Accessibility-Settings.extension")
        case .notifications: return ("通知", "Notifications", "com.apple.Notifications-Settings.extension")
        case .focus: return ("专注模式", "Focus", "com.apple.Focus-Settings.extension")
        case .appearance: return ("外观", "Appearance", "com.apple.Appearance-Settings.extension")
        case .desktopDock: return ("桌面与程序坞", "Desktop & Dock", "com.apple.Desktop-Settings.extension")
        case .mouse: return ("鼠标", "Mouse", "com.apple.Mouse-Settings.extension")
        case .trackpad: return ("触控板", "Trackpad", "com.apple.Trackpad-Settings.extension")
        case .dateTime: return ("日期与时间", "Date & Time", "com.apple.Date-Time-Settings.extension")
        case .languageRegion: return ("语言与地区", "Language & Region", "com.apple.systempreferences.InternationalSettingsExtension")
        case .storage: return ("储存空间", "Storage", "com.apple.settings.Storage")
        case .softwareUpdate: return ("软件更新", "Software Update", "com.apple.Software-Update-Settings.extension")
        case .loginItems: return ("登录项与扩展", "Login Items & Extensions", "com.apple.LoginItems-Settings.extension")
        case .general: return ("通用", "General", "com.apple.systempreferences.GeneralSettings")
        case .wallpaper: return ("墙纸", "Wallpaper", "com.apple.Wallpaper-Settings.extension")
        case .screenTime: return ("屏幕使用时间", "Screen Time", "com.apple.Screen-Time-Settings.extension")
        case .sharing: return ("共享", "Sharing", "com.apple.Sharing-Settings.extension")
        case .printers: return ("打印机与扫描仪", "Printers & Scanners", "com.apple.Print-Scan-Settings.extension")
        case .users: return ("用户与群组", "Users & Groups", "com.apple.Users-Groups-Settings.extension")
        case .lockScreen: return ("锁定屏幕", "Lock Screen", "com.apple.Lock-Screen-Settings.extension")
        }
    }

    var title: String { metadata.title }
    var extensionIdentifier: String { metadata.identifier }
    var verificationTitles: Set<String> {
        var titles: Set<String> = [title, metadata.english]
        if self == .loginItems { titles.formUnion(["登录项", "Login Items"]) }
        return titles
    }
    var aliases: [String] {
        var names = [title, title + "设置", rawValue, metadata.english, metadata.english + " settings"]
        switch self {
        case .wifi: names += ["无线网络", "无线网络设置", "WiFi设置"]
        case .displays: names += ["屏幕设置", "显示设置", "亮度设置"]
        case .privacy: names += ["隐私设置", "隐私与安全设置", "安全设置"]
        case .storage: names += ["存储空间", "存储设置"]
        case .wallpaper: names += ["壁纸", "壁纸设置"]
        case .loginItems: names += ["登录项", "登录项设置", "开机启动设置"]
        case .desktopDock: names += ["程序坞设置", "Dock设置"]
        case .dateTime: names += ["时间设置", "日期设置"]
        default: break
        }
        return names
    }
}
