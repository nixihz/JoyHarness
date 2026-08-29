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

enum PadAction: String, Codable, CaseIterable {
    case ping
    case status
    case slotsRefresh = "slots-refresh"
    case slotNext = "slot-next"
    case slotPrevious = "slot-previous"
    case slotOpen = "slot-open"
}

struct PadCommand: Decodable {
    var state: String?
    var action: PadAction?
    var note: String?
    var threadID: String?

    init(state: String?, action: PadAction?, note: String?, threadID: String?) {
        self.state = state
        self.action = action
        self.note = note
        self.threadID = threadID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        guard let rawAction = try container.decodeIfPresent(String.self, forKey: .action) else {
            action = nil
            return
        }
        guard let decodedAction = PadAction(rawValue: rawAction.lowercased()) else {
            throw CommandDecodingError.invalidAction
        }
        action = decodedAction
    }

    enum CodingKeys: String, CodingKey {
        case state, action, note
        case threadID = "thread_id"
    }

    enum CommandDecodingError: Error {
        case invalidAction
    }
}
