import Foundation

enum AppVersion {
    static let current: String = {
        let urls = [
            Bundle.main.url(forResource: "VERSION", withExtension: nil),
            Bundle.module.url(forResource: "VERSION", withExtension: nil),
        ]
        for url in urls.compactMap({ $0 }) {
            guard let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty else { continue }
            return value
        }
        return "unknown"
    }()

    static var displayName: String {
        "Joy Harness v\(current)"
    }
}
