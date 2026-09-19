import Foundation
import Testing
@testable import JoyHarness

struct RemoteVolumeSuppressionTests {
    @Test func suppressesNativeVoiceAndRestoresItsOriginalMapping() {
        let voice = RemoteKeyMapping(source: 0x70000003E, destination: 0x70000003A)
        let applied = RemoteVolumeSuppression.suppress([voice])
        #expect(applied.contains(.init(source: voice.source, destination: 0)))
        #expect(RemoteVolumeSuppression.restore(applied, original: [voice]) == [voice])
    }

    @Test func preservesExistingMappingsAndRestoresVolume() {
        let volume = RemoteKeyMapping(source: 0x700000080, destination: 0x700000004)
        let other = RemoteKeyMapping(source: 0x700000039, destination: 0x700000029)
        let original = [volume, other]
        let applied = RemoteVolumeSuppression.suppress(original)
        #expect(applied.contains(other))
        #expect(applied.contains(.init(source: volume.source, destination: 0)))
        #expect(!applied.contains(volume))
        #expect(Set(RemoteVolumeSuppression.restore(applied, original: original)) == Set(original))
    }

    @Test func restorePreservesChangesMadeByAnotherTool() {
        let original = [RemoteKeyMapping(source: 0x700000080, destination: 0x700000004)]
        var current = RemoteVolumeSuppression.suppress(original)
        current.removeAll { $0.source == 0x700000080 }
        let changed = RemoteKeyMapping(source: 0x700000080, destination: 0x700000005)
        let unrelated = RemoteKeyMapping(source: 0x700000039, destination: 0x700000029)
        current += [changed, unrelated]
        #expect(Set(RemoteVolumeSuppression.restore(current, original: original)) == Set([changed, unrelated]))
    }

    @Test func preservesPreviouslyDisabledVolumeAndDoesNotRestoreDeletedMapping() {
        let disabled = RemoteKeyMapping(source: 0x700000080, destination: 0)
        #expect(RemoteVolumeSuppression.restore([disabled], original: [disabled]) == [disabled])
        #expect(RemoteVolumeSuppression.restore([], original: [disabled]).isEmpty)
    }
}
