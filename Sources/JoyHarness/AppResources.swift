import Foundation

enum AppResources {
    static let bundle: Bundle = {
        if let packaged = packagedBundle(in: .main) { return packaged }
        // SwiftPM's generated accessor differs between build systems. Some versions
        // search only the app root and the build machine's absolute path and trap.
        // A packaged app must use its own resources, never that build-time fallback.
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        return .module
    }()

    static func packagedBundle(in app: Bundle) -> Bundle? {
        for parent in [app.resourceURL, app.bundleURL] {
            if let url = parent?.appendingPathComponent("JoyHarness_JoyHarness.bundle"),
               let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }
}
