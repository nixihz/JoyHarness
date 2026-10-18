import Foundation
import Testing
@testable import JoyHarness

@MainActor
struct AIVoiceSystemControlsTests {
    @Test func readingVolumeReportsDeviceAndMutedStateWithoutWriting() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0.2, 0.4]
        fixture.audio.muted = [true]
        let result = await controls(fixture).execute(.volumeRead)
        #expect(result.status == .succeeded)
        #expect(result.message.contains("测试扬声器"))
        #expect(result.message.contains("40%"))
        #expect(result.message.contains("已静音"))
        #expect(fixture.audio.writtenVolumes.isEmpty)
        #expect(fixture.audio.writtenMutes.isEmpty)
    }

    @Test func increasingVolumePreservesChannelBalanceAndUnmutes() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0.2, 0.4]
        fixture.audio.muted = [true]
        let result = await controls(fixture).execute(.volumeAdjust(20))
        #expect(result.status == .succeeded)
        #expect(abs(fixture.audio.levels[0] - 0.3) < 0.0001)
        #expect(abs(fixture.audio.levels[1] - 0.6) < 0.0001)
        #expect(fixture.audio.writtenMutes == [false])
        #expect(result.message.contains("60%"))
        #expect(result.message.contains("未静音"))
    }

    @Test func decreasesClampAtZeroAndDoNotChangeMute() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0.12]
        fixture.audio.muted = [true]
        let result = await controls(fixture).execute(.volumeAdjust(-80))
        #expect(result.status == .succeeded)
        #expect(fixture.audio.levels == [0])
        #expect(fixture.audio.muted == [true])
        #expect(fixture.audio.writtenMutes.isEmpty)
    }

    @Test func nonzeroSetUnmutesButExplicitUnmuteDoesNotRaiseZeroVolume() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0]
        fixture.audio.muted = [true]
        let unmute = await controls(fixture).execute(.muteSet(false))
        #expect(unmute.status == .succeeded)
        #expect(fixture.audio.levels == [0])
        #expect(fixture.audio.writtenVolumes.isEmpty)
        fixture.audio.muted = [true]
        let set = await controls(fixture).execute(.volumeSet(35))
        #expect(set.status == .succeeded)
        #expect(fixture.audio.levels == [0.35])
        #expect(fixture.audio.muted == [false])
    }

    @Test func zeroAdjustmentDoesNotFlattenChannelBalanceOrUnmute() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0.2, 0.4]
        fixture.audio.muted = [true]
        let result = await controls(fixture).execute(.volumeAdjust(0))
        #expect(result.status == .succeeded)
        #expect(fixture.audio.writtenVolumes.isEmpty)
        #expect(fixture.audio.writtenMutes.isEmpty)
    }

    @Test func readOnlyUnmutePreventsAPartialVolumeChange() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.muted = [true]
        fixture.audio.muteSettable = false
        let result = await controls(fixture).execute(.volumeSet(80))
        #expect(result.status == .failed)
        #expect(fixture.audio.writtenVolumes.isEmpty)
        #expect(fixture.audio.writtenMutes.isEmpty)
    }

    @Test func invalidIntegersAndInvalidHardwareScalarsCannotReachWrites() async {
        let fixture = SystemControlHardwareStub()
        for action in [AIVoiceSystemControlAction.volumeSet(-1), .brightnessSet(101),
                       .volumeAdjust(Int.max), .brightnessAdjust(Int.min)] {
            #expect(await controls(fixture).execute(action).status == .failed)
        }
        #expect(fixture.audioSelections == 0)
        #expect(fixture.displaySelections == 0)
        for scalar in [Double.nan, .infinity, -0.1, 1.1] {
            fixture.audio.levels = [scalar]
            #expect(await controls(fixture).execute(.volumeSet(20)).status == .failed)
            fixture.display.level = scalar
            #expect(await controls(fixture).execute(.brightnessAdjust(10)).status == .failed)
        }
        #expect(fixture.audio.writtenVolumes.isEmpty)
        #expect(fixture.display.writes.isEmpty)
    }

    @Test func allChannelsMustReadBackAndUnmuteMustActuallySucceed() async {
        let fixture = SystemControlHardwareStub()
        fixture.audio.levels = [0.3, 0.3]
        fixture.audio.onlyWritesFirstChannel = true
        let partial = await controls(fixture).execute(.volumeSet(70))
        #expect(partial.status == .unconfirmed)
        #expect(fixture.audio.levels == [0.7, 0.3])
        fixture.audio.onlyWritesFirstChannel = false
        fixture.audio.muted = [true]
        fixture.audio.ignoresMuteWrites = true
        let muted = await controls(fixture).execute(.volumeSet(50))
        #expect(muted.status == .unconfirmed)
        #expect(fixture.audio.muted == [true])
    }

    @Test func brightnessClampsAndNamesTheSelectedDisplay() async {
        let fixture = SystemControlHardwareStub()
        fixture.display.level = 0.9
        let result = await controls(fixture).execute(.brightnessAdjust(30))
        #expect(result.status == .succeeded)
        #expect(fixture.display.writes == [1])
        #expect(result.message.contains("测试主屏"))
        #expect(result.message.contains("100%"))
        #expect(fixture.audioSelections == 0)
    }

    @Test func readOnlyBrightnessAndUnsupportedHDMIVolumeFailWithoutWrites() async {
        let fixture = SystemControlHardwareStub()
        fixture.display.settable = false
        #expect(await controls(fixture).execute(.brightnessSet(20)).status == .failed)
        fixture.audio.readFailure = AIVoiceSystemControlError("HDMI 不支持系统音量。")
        let result = await controls(fixture).execute(.volumeAdjust(10))
        #expect(result.status == .failed)
        #expect(result.message.contains("HDMI"))
        #expect(fixture.audio.writtenVolumes.isEmpty)
        #expect(fixture.display.writes.isEmpty)
    }

    @Test func brightnessReadbackMismatchAndWriteFailureAreNeverSuccess() async {
        let fixture = SystemControlHardwareStub()
        fixture.display.ignoresWrites = true
        #expect(await controls(fixture).execute(.brightnessSet(90)).status == .unconfirmed)
        fixture.display.writeFailure = AIVoiceSystemControlError("显示器拒绝请求")
        let result = await controls(fixture).execute(.brightnessSet(90))
        #expect(result.status == .unconfirmed)
        #expect(result.message.contains("显示器拒绝请求"))
    }

    @Test func temporarilyStaleReadbackIsRetriedWithoutRepeatingTheWrite() async {
        let fixture = SystemControlHardwareStub()
        fixture.display.staleReadsAfterWrite = 1
        let result = await AIVoiceMacSystemControls(hardware: fixture, verificationAttempts: 2,
                                                   verificationDelayNanoseconds: 0).execute(.brightnessSet(80))
        #expect(result.status == .succeeded)
        #expect(fixture.display.writes == [0.8])
    }

    @Test func cancellationDuringReadbackDoesNotReportSuccessOrRetryTheWrite() async {
        let fixture = SystemControlHardwareStub()
        fixture.display.cancelReadback = true
        let result = await controls(fixture).execute(.brightnessSet(80))
        #expect(result.status == .cancelled)
        #expect(fixture.display.writes == [0.8])
        #expect(result.message.contains("可能仍然生效"))
    }

    private func controls(_ fixture: SystemControlHardwareStub) -> AIVoiceMacSystemControls {
        .init(hardware: fixture, verificationAttempts: 1, verificationDelayNanoseconds: 0)
    }
}

@MainActor
private final class SystemControlHardwareStub: AIVoiceSystemControlHardware {
    let audio = AudioOutputControlStub()
    let display = BrightnessControlStub()
    var audioSelections = 0
    var displaySelections = 0
    func defaultAudioOutput() throws -> any AIVoiceAudioOutputHardware { audioSelections += 1; return audio }
    func brightnessDisplay() async throws -> any AIVoiceBrightnessHardware { displaySelections += 1; return display }
}

@MainActor
private final class AudioOutputControlStub: AIVoiceAudioOutputHardware {
    let name = "测试扬声器"
    var levels = [0.5]
    var muted: [Bool]? = [false]
    var volumeSettable = true
    var muteSettable = true
    var onlyWritesFirstChannel = false
    var ignoresMuteWrites = false
    var readFailure: Error?
    var writtenVolumes: [[Double]] = []
    var writtenMutes: [Bool] = []
    func volume() throws -> AIVoiceScalarControlState {
        if let readFailure { throw readFailure }
        return .init(values: levels, isSettable: volumeSettable)
    }
    func setVolume(_ values: [Double]) throws {
        writtenVolumes.append(values)
        if onlyWritesFirstChannel { levels[0] = values[0] } else { levels = values }
    }
    func mute() throws -> AIVoiceMuteControlState? { muted.map { .init(values: $0, isSettable: muteSettable) } }
    func setMute(_ value: Bool) throws {
        writtenMutes.append(value)
        if !ignoresMuteWrites { muted = muted?.map { _ in value } }
    }
}

@MainActor
private final class BrightnessControlStub: AIVoiceBrightnessHardware {
    let name = "测试主屏"
    var level = 0.5
    var settable = true
    var ignoresWrites = false
    var writeFailure: Error?
    var staleReadsAfterWrite = 0
    var cancelReadback = false
    var writes: [Double] = []
    func brightness() async throws -> AIVoiceScalarControlState {
        if !writes.isEmpty, cancelReadback { throw CancellationError() }
        if !writes.isEmpty, staleReadsAfterWrite > 0 {
            staleReadsAfterWrite -= 1
            return .init(values: [0.5], isSettable: settable)
        }
        return .init(values: [level], isSettable: settable)
    }
    func setBrightness(_ value: Double) async throws {
        writes.append(value)
        if let writeFailure { throw writeFailure }
        if !ignoresWrites { level = value }
    }
}
