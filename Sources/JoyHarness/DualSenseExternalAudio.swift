import Foundation
import Combine
import CDualSenseControlClient

/// Only the root helper's CRC-checked control frames enter this path. The
/// second validation protects the boundary independently from the daemon.
struct DualSenseExternalControlRouter {
    enum Effect: Equatable {
        case interrupted
        case optionsTap
        case cancelTap
        case ps(DualSensePSInputSample)
    }
    private(set) var lastTimestamp: TimeInterval?
    private var optionsDown = false
    private var cancelDown = false
    private var awaitingNeutral = true

    mutating func interrupt() -> [Effect] {
        lastTimestamp = nil
        optionsDown = false
        cancelDown = false
        awaitingNeutral = true
        return [.interrupted]
    }

    mutating func receive(_ bytes: [UInt8], timestamp: TimeInterval, now: TimeInterval) -> [Effect] {
        guard timestamp <= now + 0.02, now - timestamp < PSButtonGesture.maximumReportGap,
              lastTimestamp.map({ timestamp > $0 }) ?? true,
              case let .control(frame) = DualSenseBluetoothAudioProtocol.classifyInput(reportID: 0x31, bytes: bytes) else {
            return []
        }
        var effects: [Effect] = []
        if let lastTimestamp, timestamp - lastTimestamp > PSButtonGesture.maximumReportGap {
            effects = interrupt()
        }
        lastTimestamp = timestamp
        let options = frame.buttons1 & 0x20 != 0 // physical Options; .menu in GameController
        let cancel = frame.buttons0 & 0x40 != 0 // Circle / GameController B
        if awaitingNeutral {
            guard frame.isNeutral else { return effects }
            awaitingNeutral = false
        }
        if options && !optionsDown { effects.append(.optionsTap) }
        optionsDown = options
        // Cancel before processing a simultaneous L2 release, so a cancelled
        // recording cannot be submitted by the same report.
        if cancel && !cancelDown { effects.append(.cancelTap) }
        cancelDown = cancel
        effects.append(.ps(DualSensePSInputSample(isPressed: frame.buttons2 & 1 != 0,
            leftTriggerValue: Float(frame.leftTrigger) / 255, timestamp: timestamp)))
        return effects
    }
}

@MainActor
final class DualSenseExternalAudio: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var connected = false
    @Published private(set) var microphoneActive = false
    var onState: ((Bool, Bool) -> Void)?
    var onControl: ((DualSenseExternalControlRouter.Effect) -> Void)?
    private var client: OpaquePointer?
    private var router = DualSenseExternalControlRouter()
    private var watchdog: Timer?
    private var stopped = false

    func start() {
        guard client == nil else { return }
        stopped = false
        client = JHDSControlClientCreate(Unmanaged.passUnretained(self).toOpaque()) { context, available, connected, microphone, report, length, timestamp in
            guard let context else { return }
            MainActor.assumeIsolated {
                let owner = Unmanaged<DualSenseExternalAudio>.fromOpaque(context).takeUnretainedValue()
                owner.receive(available: available, connected: connected, microphone: microphone,
                              bytes: report.map { Array(UnsafeBufferPointer(start: $0, count: length)) } ?? [],
                              timestamp: Double(timestamp) / 1_000_000_000)
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let last = self.router.lastTimestamp,
                      ProcessInfo.processInfo.systemUptime - last > PSButtonGesture.maximumReportGap else { return }
                self.router.interrupt().forEach { self.onControl?($0) }
            }
        }
    }
    private func receive(available: Bool, connected: Bool, microphone: Bool, bytes: [UInt8], timestamp: TimeInterval) {
        guard !stopped else { return }
        if self.available != available || self.connected != connected || microphoneActive != microphone {
            self.available = available; self.connected = connected; microphoneActive = microphone
            onState?(available && connected, microphone)
        }
        guard available && connected else {
            router.interrupt().forEach { onControl?($0) }
            return
        }
        if !bytes.isEmpty {
            router.receive(bytes, timestamp: timestamp, now: ProcessInfo.processInfo.systemUptime)
                .forEach { onControl?($0) }
        }
    }
    func stop() {
        stopped = true
        watchdog?.invalidate(); watchdog = nil
        if let client { JHDSControlClientStop(client) }
        router.interrupt().forEach { onControl?($0) }
    }
}
