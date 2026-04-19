import Foundation
import CoreBluetooth
import Observation

@MainActor
@Observable
final class ER1Client: NSObject {
    enum State: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case scanning
        case connecting(name: String)
        case connected(name: String)
    }

    private(set) var state: State = .idle
    private(set) var batteryPct: Int = 0
    private(set) var batteryState: Int = 0
    private(set) var leadConnected: Bool = true
    private(set) var lastBPM: Int = 0
    private(set) var lastPacketAt: Date?
    private(set) var totalSamples: Int = 0

    static let displayWindow: Int = 750
    private(set) var displaySamples: [Int16] = []

    // Playback buffering — BLE packets land ~1/s in 128-sample bursts;
    // we drip-feed them into `displaySamples` at a steady rate so the
    // trace scrolls silkily instead of stepping. If the buffer drains
    // (late packet) we keep scrolling and emit `fillerSample` sentinel
    // values; `WaveformView` renders those runs as a flat "no data" line.
    static let sampleRate: Double = 125
    static let playbackRate: Double = 30
    static let preBufferSamples: Int = 125   // ~1 s of head-start
    static let maxPendingSamples: Int = 375  // ~3 s; clamp if we fall behind
    static let fillerSample: Int16 = .min

    @ObservationIgnored private var pending: [Int16] = []
    @ObservationIgnored private var samplesOwed: Double = 0
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    var onSamples: (([Int16]) -> Void)?
    var onBPM: ((Int) -> Void)?

    private static let viatomService    = CBUUID(string: "14839ac4-7d7e-415c-9a42-167340cf2339")
    private static let viatomWrite      = CBUUID(string: "8b00ace7-eb0b-49b0-bbe9-9aee0a26e1a3")
    private static let viatomNotify     = CBUUID(string: "0734594a-a8e7-4b1a-a6b1-cd5243059a57")
    private static let hrService        = CBUUID(string: "180D")
    private static let hrMeasurement    = CBUUID(string: "2A37")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var hrChar: CBCharacteristic?

    private var reassembler = PacketReassembler()
    private var seq: UInt8 = 0
    private var keepaliveTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func nextSeq() -> UInt8 {
        let s = seq
        seq = seq &+ 1
        if seq > 254 { seq = 0 }
        return s
    }

    private func beginScan() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func send(_ cmd: ViatomCmd, payload: [UInt8] = []) {
        guard let p = peripheral, let w = writeChar else { return }
        let data = ViatomProtocol.build(cmd: cmd, seq: nextSeq(), payload: payload)
        p.writeValue(data, for: w, type: .withoutResponse)
    }

    private func startupSequence() {
        send(.getVibrateConfig)
        send(.getInfo)
        send(.syncTime, payload: ViatomProtocol.syncTimePayload())
        send(.getRtData, payload: [0x7D])

        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.send(.getRtData, payload: [0x7D])
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    func disconnect() {
        stopKeepalive()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }
}

extension ER1Client: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.beginScan()
            case .unauthorized:
                self.state = .unauthorized
            case .poweredOff, .resetting, .unsupported, .unknown:
                self.state = .poweredOff
            @unknown default:
                self.state = .poweredOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard name.uppercased().hasPrefix("ER1") else { return }
        Task { @MainActor in
            guard case .scanning = self.state else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting(name: name)
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.reassembler.reset()
            peripheral.discoverServices([Self.viatomService, Self.hrService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.stopKeepalive()
            self.writeChar = nil
            self.notifyChar = nil
            self.hrChar = nil
            self.peripheral = nil
            self.state = .idle
            self.beginScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.state = .idle
            self.beginScan()
        }
    }
}

extension ER1Client: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] {
            if svc.uuid == Self.viatomService {
                peripheral.discoverCharacteristics([Self.viatomWrite, Self.viatomNotify], for: svc)
            } else if svc.uuid == Self.hrService {
                peripheral.discoverCharacteristics([Self.hrMeasurement], for: svc)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case Self.viatomWrite:
                    self.writeChar = ch
                case Self.viatomNotify:
                    self.notifyChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                case Self.hrMeasurement:
                    self.hrChar = ch
                    peripheral.setNotifyValue(true, for: ch)
                default:
                    break
                }
            }
            if self.writeChar != nil && self.notifyChar != nil {
                self.state = .connected(name: peripheral.name ?? "ER1")
                self.startupSequence()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.hrMeasurement {
                self.handleHR(data)
            } else if uuid == Self.viatomNotify {
                self.handleViatom(data)
            }
        }
    }

    private func handleHR(_ data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)
        let flags = bytes[0]
        let bpm: Int
        if flags & 0x01 == 0 {
            bpm = Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return }
            bpm = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        }
        lastBPM = bpm
        onBPM?(bpm)
    }

    private func enqueueForPlayback(_ samples: [Int16]) {
        pending.append(contentsOf: samples)
        if pending.count > Self.maxPendingSamples {
            pending.removeFirst(pending.count - Self.maxPendingSamples)
        }
        startPlaybackIfNeeded()
    }

    private func startPlaybackIfNeeded() {
        guard playbackTask == nil, pending.count >= Self.preBufferSamples else { return }
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let interval = Duration.seconds(1.0 / Self.playbackRate)
            var nextTick = ContinuousClock.now + interval
            while !Task.isCancelled {
                try? await Task.sleep(until: nextTick, clock: .continuous)
                self.playbackTick()
                nextTick += interval
            }
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        pending.removeAll()
        samplesOwed = 0
    }

    private func playbackTick() {
        samplesOwed += Self.sampleRate / Self.playbackRate

        // Elastic speed: if we're building up a backlog, consume a bit
        // faster so latency doesn't drift up after a slow BLE packet.
        let nominal = Int(samplesOwed)
        let boosted = pending.count > Int(Self.sampleRate * 1.5) ? nominal + 1 : nominal
        guard boosted > 0 else { return }

        let realCount = min(boosted, pending.count)
        let fillerCount = boosted - realCount

        if realCount > 0 {
            displaySamples.append(contentsOf: pending.prefix(realCount))
            pending.removeFirst(realCount)
        }
        if fillerCount > 0 {
            displaySamples.append(contentsOf: repeatElement(Self.fillerSample, count: fillerCount))
        }
        samplesOwed -= Double(boosted)

        let overflow = displaySamples.count - Self.displayWindow
        if overflow > 0 {
            displaySamples.removeFirst(overflow)
        }
    }

    private func handleViatom(_ data: Data) {
        let packets = reassembler.append(data)
        for pkt in packets {
            if pkt.cmd == ViatomCmd.getRtData.rawValue, let ecg = ECGPacket(payload: pkt.payload) {
                batteryPct = Int(ecg.batteryPct)
                batteryState = Int(ecg.batteryState)
                lastPacketAt = Date()
                totalSamples += ecg.samples.count
                enqueueForPlayback(ecg.samples)
                onSamples?(ecg.samples)
            }
        }
    }
}
