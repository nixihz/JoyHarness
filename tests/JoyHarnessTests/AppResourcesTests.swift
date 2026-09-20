import Foundation
import Testing
@testable import JoyHarness

struct AppResourcesTests {
    @Test func relocatedAppLoadsResourcesFromContentsResources() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Moved App.app")
        let resources = app.appendingPathComponent("Contents/Resources/JoyHarness_JoyHarness.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "tech.joyharness.resource-fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try "fixture-version\n".write(to: resources.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: app))
        let packaged = try #require(AppResources.packagedBundle(in: bundle))
        let version = try #require(packaged.url(forResource: "VERSION", withExtension: nil))
        #expect(try String(contentsOf: version, encoding: .utf8) == "fixture-version\n")
        #expect(packaged.bundleURL.path == resources.path)
    }
}
