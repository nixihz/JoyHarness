import Foundation

enum PadState: String, CaseIterable {
    case idle
    case busy
    case waiting
    case done
    case error

    static func parse(_ raw: String) -> PadState? {
        PadState(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct PadCommand: Decodable {
    var state: String?
    var action: String?
    var note: String?
}
