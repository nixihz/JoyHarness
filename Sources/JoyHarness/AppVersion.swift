import Foundation

enum AppVersion {
    static let current: String = {
        load(
            primaryURL: Bundle.main.url(forResource: "VERSION", withExtension: nil),
            fallbackURL: { Bundle.module.url(forResource: "VERSION", withExtension: nil) }
        )
    }()

    static func load(primaryURL: URL?, fallbackURL: () -> URL?) -> String {
        if let value = read(from: primaryURL) {
            return value
        }
        if let value = read(from: fallbackURL()) {
            return value
        }
        return "unknown"
    }

    private static func read(from url: URL?) -> String? {
        guard let url,
              let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static var displayName: String {
        "Joy Harness v\(current)"
    }
}
