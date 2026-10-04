import AppKit
import SwiftUI

enum ApplicationPresentation {
    /// Finder shows or hides the `.app` extension per user preference. Only the
    /// trailing extension is dropped so names containing ".app" elsewhere survive.
    static func name(forDisplayName displayName: String) -> String {
        guard displayName.count > 4,
              displayName.lowercased().hasSuffix(".app") else { return displayName }
        return String(displayName.dropLast(4))
    }

    static func name(forApplicationAt url: URL) -> String {
        name(forDisplayName: FileManager.default.displayName(atPath: url.path))
    }

    /// An application's own icon at a fixed point size. `NSMenu` draws images at
    /// their intrinsic size, so menu rows need a pre-sized copy. Apps that are
    /// not installed get a neutral template glyph instead of a brand stand-in.
    static func icon(forApplicationAt url: URL?, size: CGFloat) -> NSImage {
        let pointSize = NSSize(width: size, height: size)
        if let url {
            let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage)
                ?? NSWorkspace.shared.icon(forFile: url.path)
            icon.size = pointSize
            return icon
        }
        let placeholder = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage(size: pointSize)
        placeholder.size = pointSize
        placeholder.isTemplate = true
        return placeholder
    }

    struct RunningApplication: Hashable, Identifiable {
        let bundleIdentifier: String?
        let name: String
        var url: URL? = nil

        var id: String {
            bundleIdentifier ?? url.map { "path:\($0.standardizedFileURL.path)" } ?? "name:\(name)"
        }
    }

    /// Regular apps other than Joy Harness, sorted by name for "Add" menus.
    static func runningApplications() -> [RunningApplication] {
        let applications = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                    $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { application -> RunningApplication? in
                guard let name = application.localizedName, !name.isEmpty else { return nil }
                return RunningApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    name: name,
                    url: application.bundleURL
                )
            }
        return Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Looks the icon up once per bundle identifier instead of on every render.
struct ApplicationIconView: View {
    let bundleIdentifier: String?
    let placeholderSize: CGFloat
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: placeholderSize))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: bundleIdentifier) {
            icon = Self.icon(for: bundleIdentifier)
        }
    }

    private static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
