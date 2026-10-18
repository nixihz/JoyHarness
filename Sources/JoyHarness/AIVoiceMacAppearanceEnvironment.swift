import Darwin

/// Native, system-wide appearance access. Loading this adapter never changes a
/// preference or the application's own NSAppearance override.
@MainActor
final class AIVoiceMacAppearanceEnvironment: AIVoiceSystemAppearanceEnvironment {
    private let functions: Result<SkyLightFunctions, Error>

    init() {
        functions = Result { try SkyLightFunctions() }
    }

    func read() throws -> AIVoiceSystemAppearanceState {
        let api = try functions.get()
        let theme = api.getTheme()
        guard theme == 0 || theme == 1 else {
            throw AIVoiceSystemControlError("macOS 返回了无法识别的系统外观状态。")
        }
        return .init(isAutomatic: api.getAutomatic(), isDark: theme == 1)
    }

    func setAutomatic(_ enabled: Bool) throws {
        try functions.get().setAutomatic(enabled)
    }

    func setDark(_ dark: Bool) throws {
        try functions.get().setTheme(dark ? 1 : 0)
    }
}

/// These are private APIs, so missing symbols fail explicitly. Their setters
/// return no status; the controller must verify the requested mode by reading it.
///
/// Interface facts were cross-checked against:
/// - insidegui/DarkModeBuddy, commit 1ff08ef1e6976bf62327e41f08de0db99c62a9a7
///   (legacy theme represented as Int32: 0 light, 1 dark).
/// - ApolloZhu/Dynamic-Dark-Mode, commit fd152ad8a77ad2a0daa5012ea98a07de71dfeef9
///   Dynamic/Supporting Files/Dynamic-Bridging-Header.h (automatic BOOL API).
/// This adapter is an independent implementation, not copied source.
private final class SkyLightFunctions {
    private typealias GetTheme = @convention(c) () -> Int32
    private typealias SetTheme = @convention(c) (Int32) -> Void
    private typealias GetAutomatic = @convention(c) () -> Bool
    private typealias SetAutomatic = @convention(c) (Bool) -> Void

    private let library: UnsafeMutableRawPointer
    private let readTheme: GetTheme
    private let writeTheme: SetTheme
    private let readAutomatic: GetAutomatic
    private let writeAutomatic: SetAutomatic

    init() throws {
        guard let library = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ) else {
            throw AIVoiceSystemControlError("当前 macOS 无法加载系统外观接口。")
        }
        guard let getTheme = dlsym(library, "SLSGetAppearanceThemeLegacy"),
              let setTheme = dlsym(library, "SLSSetAppearanceThemeLegacy"),
              let getAutomatic = dlsym(library, "SLSGetAppearanceThemeSwitchesAutomatically"),
              let setAutomatic = dlsym(library, "SLSSetAppearanceThemeSwitchesAutomatically") else {
            dlclose(library)
            throw AIVoiceSystemControlError("当前 macOS 缺少所需的系统外观接口。")
        }
        self.library = library
        readTheme = unsafeBitCast(getTheme, to: GetTheme.self)
        writeTheme = unsafeBitCast(setTheme, to: SetTheme.self)
        readAutomatic = unsafeBitCast(getAutomatic, to: GetAutomatic.self)
        writeAutomatic = unsafeBitCast(setAutomatic, to: SetAutomatic.self)
    }

    deinit { dlclose(library) }

    func getTheme() -> Int32 { readTheme() }
    func getAutomatic() -> Bool { readAutomatic() }
    func setTheme(_ theme: Int32) { writeTheme(theme) }
    func setAutomatic(_ enabled: Bool) { writeAutomatic(enabled) }
}
