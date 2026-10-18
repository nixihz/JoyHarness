import Foundation
import Testing
@testable import JoyHarness

private final class MappingReadCountingDefaults: UserDefaults {
    var watchedKey = ""
    var mappingReads = 0

    override func dictionary(forKey key: String) -> [String: Any]? {
        if key == watchedKey { mappingReads += 1 }
        return super.dictionary(forKey: key)
    }
}

@Suite(.serialized)
struct PointerMappingPerformanceTests {
    @Test
    func draggingDoesNotReloadTheWholeProfileForEveryInputReport() throws {
        let suite = "PointerMappingPerformanceTests.\(UUID().uuidString)"
        let preferences = try #require(MappingReadCountingDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = ControllerMappingStore(userDefaults: preferences)
        store.setControllerFamily(.joyConLeft)
        store.setControllerFamily(.xiaomiRemote)
        preferences.watchedKey = "controllerMappings.v1.profiles.joycon-left"
        preferences.mappingReads = 0
        let bridge = ButtonBridge { store.action(for: $0, family: .joyConLeft) }
        var dragEvents: [Bool] = []
        bridge.mouseButtonHandler = { _, down in dragEvents.append(down) }
        for index in 0..<120 {
            bridge.applyJoyConSnapshot(JoyConInputSnapshot(
                buttons: [.leftShoulder: true, .rightShoulder: false, .buttonA: false, .buttonX: false],
                primaryStick: JoyConStick(x: Float(index) / 120, y: 0.3), secondaryStick: .neutral
            ))
        }
        bridge.applyJoyConSnapshot(.neutral)
        #expect(dragEvents == [true, false])
        #expect(preferences.mappingReads <= 1,
                "120 drag samples reloaded the profile \(preferences.mappingReads) times")

        // A warmed runtime profile must still observe edits, reset and Harness changes.
        store.setControllerFamily(.joyConLeft)
        store.setAction(.copy, for: .leftShoulder)
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .leftShoulder, family: .joyConLeft) == .copy)
        store.setHarnessProvider(.claude)
        #expect(store.action(for: .leftShoulder, family: .joyConLeft) == .mouseLeft)
        store.setHarnessProvider(.codex)
        #expect(store.action(for: .leftShoulder, family: .joyConLeft) == .copy)
        store.setControllerFamily(.joyConLeft)
        store.resetDefaults()
        store.setControllerFamily(.xiaomiRemote)
        #expect(store.action(for: .leftShoulder, family: .joyConLeft) == .mouseLeft)
    }
}
