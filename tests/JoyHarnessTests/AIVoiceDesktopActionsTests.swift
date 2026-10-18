import AppKit
import Foundation
import IOKit.ps
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceDesktopActionsTests {
    @Test func missingMediaPermissionNeverPostsAnEvent() async {
        let environment = VoiceDesktopEnvironmentStub()
        environment.canPostMediaEvents = false
        let executor = AIVoiceMacDesktopActions(environment: environment)

        let result = await executor.execute(.media(.playPause))

        #expect(result.status == .failed)
        #expect(result.message.contains("辅助功能权限"))
        #expect(environment.mediaActions.isEmpty)
    }

    @Test(arguments: AIVoiceMediaAction.allCases)
    func mediaDispatchNeverClaimsAConfirmedPlaybackState(action: AIVoiceMediaAction) async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)

        let result = await executor.execute(.media(action))

        #expect(environment.mediaActions == [action])
        #expect(result.status == .unconfirmed)
        #expect(result.message.contains("已发送"))
        #expect(!result.message.contains("已暂停"))
        #expect(!result.message.contains("已播放"))
        environment.mediaAccepted = false
        let failed = await executor.execute(.media(action))
        #expect(failed.status == .failed)
        #expect(environment.mediaActions.count == 2)
    }

    @Test func nativeMediaPacketsContainOneDownAndOneUpWithoutKeyRepeat() throws {
        // Inspect native packets without posting them to the user's player.
        // Key values come from the HID media-key wire format, not the enum.
        let expected: [(AIVoiceMediaAction, Int)] = [(.playPause, 16), (.next, 17), (.previous, 18)]
        for (action, key) in expected {
            let events = try #require(AIVoiceMacDesktopEnvironment.mediaEvents(for: action))
            let down = try #require(NSEvent(cgEvent: events.down))
            let up = try #require(NSEvent(cgEvent: events.up))
            #expect(down.type == .systemDefined)
            #expect(up.type == .systemDefined)
            #expect(down.subtype.rawValue == 8)
            #expect(up.subtype.rawValue == 8)
            #expect(down.data1 == (key << 16) | 0xA00)
            #expect(up.data1 == (key << 16) | 0xB00)
            #expect(down.data2 == -1)
            #expect(up.data2 == -1)
        }
    }

    @Test func folderRequestsUseResolvedLocalDirectoriesAndReportOnlyAcceptance() async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)
        let result = await executor.execute(.openFolder(.downloads))

        #expect(environment.resolvedFolders == [.downloads])
        #expect(environment.openedFolders == [environment.resolvedURL!])
        #expect(result.status == .unconfirmed)
        #expect(!result.message.hasPrefix("已打开"))
        environment.folderAccepted = false
        let rejected = await executor.execute(.openFolder(.documents))
        #expect(rejected.status == .failed)
        #expect(environment.openedFolders.count == 2)
    }

    @Test func missingNonDirectoryAndNonFileTargetsNeverReachWorkspace() async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)
        environment.resolvedURL = nil
        #expect(await executor.execute(.openFolder(.home)).status == .failed)
        environment.resolvedURL = URL(string: "https://example.com/Downloads")
        #expect(await executor.execute(.openFolder(.downloads)).status == .failed)
        environment.resolvedURL = URL(fileURLWithPath: "/local/plain-file")
        environment.directoryExists = false
        #expect(await executor.execute(.openFolder(.documents)).status == .failed)
        #expect(environment.openedFolders.isEmpty)
    }

    @Test func nativeDirectoryValidationDoesNotTreatAnExistingFileAsAFolder() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("JoyVoiceFolder-" + UUID().uuidString)
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.txt")
        try Data("fixture".utf8).write(to: file)
        let environment = AIVoiceMacDesktopEnvironment(fileManager: manager)

        #expect(environment.isDirectory(directory))
        #expect(!environment.isDirectory(file))
        #expect(!environment.isDirectory(directory.appendingPathComponent("missing")))
    }

    @Test func screenshotRequestDoesNotClaimThatACaptureWasSaved() async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)

        let accepted = await executor.execute(.openScreenshotTool)

        #expect(environment.screenshotRequests == 1)
        #expect(accepted.status == .unconfirmed)
        #expect(accepted.message.contains("请在工具中"))
        #expect(!accepted.message.contains("已保存"))
        #expect(environment.openedFolders.isEmpty)
        #expect(environment.mediaActions.isEmpty)
        environment.screenshotAccepted = false
        #expect(await executor.execute(.openScreenshotTool).status == .failed)
    }

    @Test func dateTimeUsesTheInjectedLocalClockAndTimeZone() async throws {
        let environment = VoiceDesktopEnvironmentStub()
        environment.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        environment.date = Date(timeIntervalSince1970: 0)

        let result = await AIVoiceMacDesktopActions(environment: environment).execute(.dateTime)

        #expect(result.status == .succeeded)
        #expect(result.message.contains("1970年1月1日"))
        #expect(result.message.contains("08:00:00"))
        #expect(result.message.contains("Asia/Shanghai"))
        #expect(environment.mediaActions.isEmpty)
        #expect(environment.openedFolders.isEmpty)
    }

    @Test func batteryDecodingExcludesUPSAndAbsentInternalBatteries() {
        var ups = battery(current: 100, maximum: 100)
        ups[kIOPSTypeKey] = kIOPSUPSType
        var absent = battery(current: 0, maximum: 0)
        absent[kIOPSIsPresentKey] = false
        #expect(AIVoiceBatteryReading.decode([ups, absent]) == .notPresent)
        #expect(AIVoiceBatteryReading.decode(nil) == .unavailable)
    }

    @Test func batteryCapacityUsesWeightedTotalsAndPreservesPowerState() {
        let first = battery(current: 10, maximum: 40)
        var second = battery(current: 90, maximum: 160)
        second[kIOPSIsChargingKey] = true
        second[kIOPSPowerSourceStateKey] = kIOPSACPowerValue
        #expect(AIVoiceBatteryReading.decode([first, second]) == .available(percent: 50, power: .charging))
        #expect(AIVoiceBatteryReading.decode([first]) == .available(percent: 25, power: .battery))
    }

    @Test func unreadableBatteryCapacityCannotBeReportedAsZeroPercent() {
        var missing = battery(current: 10, maximum: 100)
        missing.removeValue(forKey: kIOPSCurrentCapacityKey)
        let malformed = [missing, battery(current: -1, maximum: 100),
                         battery(current: 20, maximum: 0), battery(current: .nan, maximum: 100),
                         battery(current: 101, maximum: 100)]
        for value in malformed { #expect(AIVoiceBatteryReading.decode([value]) == .unavailable) }
    }

    @Test func desktopWithoutBatteryAndReadFailureHaveDifferentOutcomes() async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)
        environment.battery = .notPresent
        let absent = await executor.execute(.batteryStatus)
        #expect(absent.status == .succeeded)
        #expect(absent.message.contains("未检测到"))
        #expect(!absent.message.contains("0%"))
        environment.battery = .unavailable
        #expect(await executor.execute(.batteryStatus).status == .failed)
        environment.battery = .available(percent: 63, power: .externalPower)
        let connected = await executor.execute(.batteryStatus)
        #expect(connected.message.contains("63%"))
        #expect(connected.message.contains("外部电源"))
        #expect(!connected.message.contains("正在充电"))
    }

    @Test func cancellationBeforeExecutionPreventsEveryDesktopSideEffect() async {
        let environment = VoiceDesktopEnvironmentStub()
        let executor = AIVoiceMacDesktopActions(environment: environment)
        let task = Task { @MainActor in
            [await executor.execute(.media(.playPause)),
             await executor.execute(.openFolder(.downloads)),
             await executor.execute(.openScreenshotTool)]
        }
        task.cancel()
        let results = await task.value

        #expect(results.allSatisfy { $0.status == .cancelled })
        #expect(environment.mediaActions.isEmpty)
        #expect(environment.openedFolders.isEmpty)
        #expect(environment.screenshotRequests == 0)
    }

    private func battery(current: Double, maximum: Double) -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
         kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: maximum,
         kIOPSIsChargingKey: false, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
    }
}

@MainActor
private final class VoiceDesktopEnvironmentStub: AIVoiceDesktopEnvironment {
    var canPostMediaEvents = true
    var mediaAccepted = true
    var mediaActions: [AIVoiceMediaAction] = []
    var resolvedURL: URL? = URL(fileURLWithPath: "/local/user/Downloads", isDirectory: true)
    var resolvedFolders: [AIVoiceFolder] = []
    var directoryExists = true
    var folderAccepted = true
    var openedFolders: [URL] = []
    var screenshotAccepted = true
    var screenshotRequests = 0
    var date = Date(timeIntervalSince1970: 0)
    var timeZone = TimeZone(secondsFromGMT: 0)!
    var battery: AIVoiceBatteryReading = .notPresent

    func postMediaAction(_ action: AIVoiceMediaAction) -> Bool {
        mediaActions.append(action)
        return mediaAccepted
    }
    func folderURL(_ folder: AIVoiceFolder) -> URL? {
        resolvedFolders.append(folder)
        return resolvedURL
    }
    func isDirectory(_ url: URL) -> Bool { directoryExists }
    func openFolder(at url: URL) -> Bool {
        openedFolders.append(url)
        return folderAccepted
    }
    func openScreenshotTool() -> Bool {
        screenshotRequests += 1
        return screenshotAccepted
    }
    func currentDate() -> Date { date }
    func batteryReading() -> AIVoiceBatteryReading { battery }
}
