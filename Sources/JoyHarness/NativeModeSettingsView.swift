import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeModeSettingsPane: View {
    @ObservedObject var settings: NativeGamepadAppSettings
    @State private var isCustomAppSheetPresented = false
    @State private var customBundleID = ""
    @State private var customAppName = ""
    @State private var isResetConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.text("模式切换规则", "Mode Switching Rules")) {
                    Toggle(
                        L10n.text("根据前台应用自动切换", "Auto-switch based on frontmost application"),
                        isOn: $settings.autoSwitchEnabled
                    )

                    Text(L10n.text(
                        "当激活列表中的应用时，自动进入原生手柄模式（关闭虚拟鼠标与按键映射）；离开时自动恢复映射模式。",
                        "When an app in the list becomes active, Joy Harness automatically switches to Native Gamepad Mode (disabling simulated mouse and keys), and restores Mapping Mode when leaving."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.tint)
                        Text(L10n.text(
                            "手动切换：在「按键映射」中把任一按键设为「切换原生/映射模式」（小米遥控器的菜单键默认如此）。手柄的 PS / Home 键用于呼出 Harness 切换浮层。",
                            "Manual switch: In Key Mapping, assign 'Toggle Native/Mapping Mode' to any button (the Xiaomi remote's Menu button does this by default). The gamepad PS / Home button opens the Harness switcher."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text(
                            "提示：若按下 PS / Home 键唤起了 macOS 系统的「游戏」应用或 Launchpad，可在系统设置中将手柄主屏幕按钮动作设为「无」。",
                            "Tip: If pressing PS / Home triggers Apple's Games app or Launchpad, set the Home button action to 'None' in macOS System Settings."
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Button(L10n.text("打开 macOS 游戏控制器设置…", "Open macOS Game Controllers Settings…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Game-Controllers-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                    .padding(.top, 2)
                }

                Section {
                    if settings.apps.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(L10n.text("暂未配置原生手柄应用", "No native gamepad apps configured"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(settings.apps) { app in
                            HStack(spacing: 12) {
                                Toggle("", isOn: Binding(
                                    get: { app.isEnabled },
                                    set: { settings.setAppEnabled(id: app.id, isEnabled: $0) }
                                ))
                                .labelsHidden()

                                ApplicationIconView(bundleIdentifier: app.bundleIdentifier, placeholderSize: 24)
                                    .frame(width: 32, height: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appName.isEmpty ? app.bundleIdentifier : app.appName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(app.isEnabled ? .primary : .secondary)

                                    if !app.bundleIdentifier.isEmpty {
                                        Text(app.bundleIdentifier)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Button {
                                    settings.removeApp(id: app.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(L10n.text("从列表中移除", "Remove from list"))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } header: {
                    HStack {
                        Text(L10n.text("原生手柄模式应用列表", "Native Gamepad Applications"))
                        Spacer()
                        Text("\(settings.apps.count) \(L10n.text("个应用", "apps"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label(L10n.text("恢复默认", "Restore Defaults"), systemImage: "arrow.counterclockwise")
                }

                Spacer()

                Menu {
                    Button(L10n.text("浏览应用程序…", "Browse Applications…")) {
                        browseForApplication()
                    }

                    let runningApplications = ApplicationPresentation.runningApplications()
                    if !runningApplications.isEmpty {
                        Menu(L10n.text("从运行中的应用添加", "Add from Running Applications")) {
                            ForEach(runningApplications) { running in
                                Button(running.name) {
                                    settings.addApp(
                                        bundleIdentifier: running.bundleIdentifier ?? "",
                                        appName: running.name
                                    )
                                }
                            }
                        }
                    }

                    Divider()

                    Button(L10n.text("手动输入 Bundle ID…", "Enter Bundle ID Manually…")) {
                        customBundleID = ""
                        customAppName = ""
                        isCustomAppSheetPresented = true
                    }
                } label: {
                    Label(L10n.text("添加应用…", "Add Application…"), systemImage: "plus")
                }
                .menuStyle(.borderedButton)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(.bar)
        }
        .onAppear {
            // App activation only reveals running defaults; the pane also
            // picks up defaults installed or removed while Joy Harness ran.
            settings.refreshInstalledDefaultApps()
        }
        .sheet(isPresented: $isCustomAppSheetPresented) {
            VStack(spacing: 16) {
                Text(L10n.text("添加原生手柄应用", "Add Native Gamepad Application"))
                    .font(.headline)

                Form {
                    TextField(
                        L10n.text("应用名称", "Application Name"),
                        text: $customAppName,
                        prompt: Text(L10n.text("例如：JoyDSH", "e.g. JoyDSH"))
                    )

                    TextField(
                        L10n.text("Bundle ID / 进程名", "Bundle ID / Process Name"),
                        text: $customBundleID,
                        prompt: Text(L10n.text("例如：com.joydsh.desktop", "e.g. com.joydsh.desktop"))
                    )
                }
                .formStyle(.grouped)

                HStack {
                    Button(L10n.text("取消", "Cancel")) {
                        isCustomAppSheetPresented = false
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button(L10n.text("添加", "Add")) {
                        settings.addApp(
                            bundleIdentifier: customBundleID,
                            appName: customAppName
                        )
                        isCustomAppSheetPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                              customAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(width: 380)
        }
        .alert(L10n.text("恢复默认应用列表？", "Restore Default Applications?"), isPresented: $isResetConfirmationPresented) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("恢复默认", "Restore Defaults"), role: .destructive) {
                settings.resetDefaults()
            }
        } message: {
            Text(L10n.text(
                "将根据本机安装情况恢复默认的原生手柄应用列表（JoyDSH 与 Antigravity）。",
                "This will restore installed default native gamepad apps (JoyDSH and Antigravity)."
            ))
        }
    }

    private func browseForApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("选择", "Choose")
        panel.message = L10n.text(
            "选择要启用原生手柄模式的应用。",
            "Choose an application to enable Native Gamepad Mode."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let bundleIdentifier = bundle?.bundleIdentifier ?? ""
        settings.addApp(
            bundleIdentifier: bundleIdentifier,
            appName: ApplicationPresentation.name(forApplicationAt: url)
        )
    }
}
