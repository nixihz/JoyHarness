import AppKit
import SwiftUI

@MainActor
final class AIVoiceOverlay {
    private let session: AIVoiceSession
    private var panel: NSPanel?
    private var monitors: [Any] = []
    var onOpenSettings: (() -> Void)?

    init(session: AIVoiceSession) { self.session = session }

    func update() {
        guard session.isPresented else { hide(); return }
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - 220, y: frame.minY + 70))
            }
            panel.orderFrontRegardless()
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: session.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if monitors.isEmpty {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { self?.session.dismiss() }
                return nil
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                guard event.keyCode == 53 else { return }
                MainActor.assumeIsolated { self?.session.dismiss() }
            }) { monitors.append(monitor) }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makePanel() -> NSPanel {
        let panel = AIVoicePanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.title = L10n.text("Joy Harness AI 语音", "Joy Harness AI Voice")
        panel.contentView = NSHostingView(rootView: AIVoiceOverlayView(session: session, openSettings: { [weak self] in
            self?.session.dismiss()
            self?.onOpenSettings?()
        }))
        return panel
    }
}

private final class AIVoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AIVoiceOverlayView: View {
    @ObservedObject var session: AIVoiceSession
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("Joy Harness 语音", "Joy Harness Voice"), systemImage: session.phase == .listening ? "mic.fill" : "waveform")
                    .font(.headline)
                Spacer()
                Button { session.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("关闭或取消语音", "Dismiss or cancel voice command"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.message).font(.body).fixedSize(horizontal: false, vertical: true)
                    if session.phase == .listening {
                        ProgressView(value: Double(min(max(session.level, 0), 1)))
                            .accessibilityLabel(L10n.text("麦克风音量", "Microphone level"))
                        Text(session.inputName).font(.caption).foregroundStyle(.secondary)
                    } else if session.phase == .preparing || session.phase == .processing || session.phase == .executing {
                        ProgressView().controlSize(.small)
                    }
                    if !session.transcript.isEmpty {
                        Text(session.transcript).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    if !session.choices.isEmpty {
                        ForEach(session.choices) { choice in
                            Button(choice.title) { session.choose(choice) }.buttonStyle(.link)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            HStack {
                if session.phase == .clarification {
                    Text(L10n.text("按住 L2、点 PS 回答 · B / Esc 取消", "Hold L2, tap PS to answer · B / Esc to cancel"))
                } else if session.interceptsInput {
                    Text(L10n.text("PS 可松开 · B / Esc 取消 · 最长 60 秒", "Release PS · B / Esc to cancel · 60 seconds max"))
                }
                Spacer()
                Button(L10n.text("语音设置…", "Voice Settings…"), action: openSettings)
                    .buttonStyle(.link)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440, height: 250, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.12)))
    }
}

struct AIVoiceSettingsOpener: View {
    @ObservedObject var coordinator: SettingsCoordinator
    let install: (@escaping () -> Void) -> Void

    var body: some View {
        if #available(macOS 14.0, *) {
            ModernVoiceSettingsOpener(coordinator: coordinator, install: install)
        } else {
            Color.clear.onAppear {
                install {
                    coordinator.select(.aiVoice)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }.accessibilityHidden(true)
        }
    }
}

@available(macOS 14.0, *)
private struct ModernVoiceSettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var coordinator: SettingsCoordinator
    let install: (@escaping () -> Void) -> Void

    var body: some View {
        Color.clear.onAppear {
            let openSettings = openSettings
            install {
                coordinator.select(.aiVoice)
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        }.accessibilityHidden(true)
    }
}
