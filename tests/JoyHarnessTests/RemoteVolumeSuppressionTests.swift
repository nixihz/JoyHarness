import Foundation
import Testing
@testable import JoyHarness

struct RemoteVolumeSuppressionTests {
    @Test(arguments: [Int64(-496_656_494), 0, 3_798_310_802])
    func serviceMatchingPreservesLocationIDReturnedByHidutil(locationID: Int64) throws {
        let service: [String: Int64] = [
            "VendorID": 10007, "ProductID": 12984, "LocationID": locationID,
            "PrimaryUsagePage": 1, "PrimaryUsage": 6,
        ]
        let matching = service.mapValues { NSNumber(value: $0).uint64Value }
        let json = try RemoteVolumeGuardWorker.serviceMatchingJSON(matching)
        let decoded = try JSONDecoder().decode([String: Int64].self, from: Data(json.utf8))
        #expect(decoded == service)
    }

    @Test func restoresSignedLocationIDFromExistingUnsignedJournal() throws {
        let journal = Data(#"{"VendorID":10007,"ProductID":12984,"LocationID":18446744073212895122,"PrimaryUsagePage":1,"PrimaryUsage":6}"#.utf8)
        let matching = try JSONDecoder().decode([String: UInt64].self, from: journal)
        let json = try RemoteVolumeGuardWorker.serviceMatchingJSON(matching)
        let decoded = try JSONDecoder().decode([String: Int64].self, from: Data(json.utf8))
        #expect(decoded["LocationID"] == -496_656_494)
    }

    @Test(arguments: [UInt64(0x700000035), 0x70000003E])
    func suppressesCustomAndVoiceKeysWithoutChangingTheirOriginalMappings(source: UInt64) {
        let original = [RemoteKeyMapping(source: source, destination: 0x7000000E7)]
        let applied = RemoteVolumeSuppression.suppress(original)
        #expect(applied.contains(.init(source: source, destination: 0)))
        #expect(RemoteVolumeSuppression.restore(applied, original: original) == original)
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
