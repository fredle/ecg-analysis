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

    var deviceName: String {
        switch state {
        case .connected(let name), .connecting(let name): return name
        default: return "ER1"
        }
    }

    private(set) var batteryPct: Int = 0
    private(set) var batteryState: Int = 0
    private(set) var leadConnected: Bool = true
    private(set) var lastBPM: Int = 0
    private(set) var lastPacketAt: Date?
    private(set) var totalSamples: Int = 0

    static let displayWindow: Int = 750
    private(set) var displaySamples: [Int16] = []

    // Paper ECG rolling buffer — raw samples without playback smoothing
    static let paperCapacity: Int = 180 * 125
    private(set) var paperSamples: [Int16] = []
    private(set) var paperGaps: [ClosedRange<Int>] = []
    private(set) var paperStartMs: Int64 = 0
    private(set) var paperValueMid: Double = 0
    private(set) var paperValueHalfSpan: Double = 500

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
    @ObservationIgnored private var lastChunkArrival: Date?
    @ObservationIgnored private var paperScaleCounter: Int = 0

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

    // MARK: - Stored-file transfer
    //
    // File download and the 1 Hz real-time keepalive can't share the link, so a
    // pull runs in `transferMode`: the keepalive/playback are paused and notify
    // packets are routed to a single in-flight request/response waiter instead
    // of the live ECG handler. `beginTransfer()`/`endTransfer()` bracket a pull.

    enum TransferError: LocalizedError {
        case notConnected, timeout, deviceError, disconnected

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Device not connected"
            case .timeout:      return "Device stopped responding"
            case .deviceError:  return "Device reported a read error"
            case .disconnected: return "Device disconnected during transfer"
            }
        }
    }

    @ObservationIgnored private(set) var transferMode = false
    @ObservationIgnored private var waiterCmd: UInt8?
    @ObservationIgnored private var waiterCont: CheckedContinuation<ViatomPacket, Error>?
    @ObservationIgnored private var waiterId = 0

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

    // MARK: - File transfer (public API)

    /// Enter download mode: pause the real-time keepalive and playback so the
    /// link is free for file transfer. Always pair with `endTransfer()`.
    func beginTransfer() {
        transferMode = true
        stopKeepalive()
        stopPlayback()
    }

    /// Leave download mode and resume the live stream if still connected.
    func endTransfer() {
        transferMode = false
        guard case .connected = state, peripheral != nil, writeChar != nil else { return }
        send(.getRtData, payload: [0x7D])
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.getRtData, payload: [0x7D]) }
        }
    }

    /// List the recordings stored on the device (names like `R<YYYYMMDDHHMMSS>`).
    func listFiles() async throws -> [String] {
        let pkt = try await sendAndWait(.getFileList, expect: ViatomCmd.getFileList.rawValue)
        return ViatomProtocol.parseFileList(pkt.payload)
    }

    /// Download one stored file by name, reporting `(received, total)` byte
    /// progress. Returns the raw (delta-compressed) file bytes.
    func downloadFile(_ name: String,
                      onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> Data {
        let start = try await sendAndWait(
            .readFileStart,
            payload: ViatomProtocol.readFileStartPayload(name: name),
            expect: ViatomCmd.readFileStart.rawValue
        )
        guard start.status == 1 else { throw TransferError.deviceError }
        let total = Int(ViatomProtocol.readU32le(start.payload))
        guard total > 0 else {
            _ = try? await sendAndWait(.readFileEnd, expect: ViatomCmd.readFileEnd.rawValue)
            return Data()
        }

        var data = Data(capacity: total)
        while data.count < total {
            let chunk = try await sendAndWait(
                .readFileData,
                payload: ViatomProtocol.readFileDataPayload(offset: UInt32(data.count)),
                expect: ViatomCmd.readFileData.rawValue
            )
            guard chunk.status == 1 else { throw TransferError.deviceError }
            if chunk.payload.isEmpty { throw TransferError.deviceError }  // no progress → bail
            data.append(contentsOf: chunk.payload)
            onProgress?(min(data.count, total), total)
        }
        _ = try? await sendAndWait(.readFileEnd, expect: ViatomCmd.readFileEnd.rawValue)
        return data.prefix(total)
    }

    /// Send one command and await the next packet whose cmd matches `expect`.
    private func sendAndWait(_ cmd: ViatomCmd,
                             payload: [UInt8] = [],
                             expect: UInt8,
                             timeout: TimeInterval = 10) async throws -> ViatomPacket {
        guard peripheral != nil, writeChar != nil else { throw TransferError.notConnected }
        waiterId &+= 1
        let id = waiterId
        return try await withCheckedThrowingContinuation { cont in
            waiterCmd = expect
            waiterCont = cont
            send(cmd, payload: payload)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if waiterId == id, let c = waiterCont {
                    waiterCmd = nil
                    waiterCont = nil
                    c.resume(throwing: TransferError.timeout)
                }
            }
        }
    }

    /// Fail any in-flight transfer request (called on disconnect).
    private func failPendingTransfer(_ error: Error) {
        transferMode = false
        guard let cont = waiterCont else { return }
        waiterCmd = nil
        waiterCont = nil
        waiterId &+= 1
        cont.resume(throwing: error)
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
            self.failPendingTransfer(TransferError.disconnected)
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
            self.failPendingTransfer(TransferError.disconnected)
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

    private func appendToPaper(_ newSamples: [Int16]) {
        let now = Date()

        if paperSamples.isEmpty {
            let offsetMs = Int64(Double(newSamples.count) / Self.sampleRate * 1000)
            paperStartMs = Int64(now.timeIntervalSince1970 * 1000) - offsetMs
        } else if let last = lastChunkArrival {
            let elapsed = now.timeIntervalSince(last)
            let expected = 128.0 / Self.sampleRate
            if elapsed > expected * 1.8 {
                let gapSamples = Int((elapsed - expected) * Self.sampleRate)
                if gapSamples > Int(30.0 * Self.sampleRate) {
                    paperSamples.removeAll()
                    paperGaps.removeAll()
                    let offsetMs = Int64(Double(newSamples.count) / Self.sampleRate * 1000)
                    paperStartMs = Int64(now.timeIntervalSince1970 * 1000) - offsetMs
                } else if gapSamples > 0 {
                    let gapStart = paperSamples.count
                    paperSamples.append(contentsOf: Array(repeating: 0, count: gapSamples))
                    paperGaps.append(gapStart...(gapStart + gapSamples - 1))
                }
            }
        }
        lastChunkArrival = now
        paperSamples.append(contentsOf: newSamples)

        if paperSamples.count > Self.paperCapacity {
            let excess = paperSamples.count - Self.paperCapacity
            paperSamples.removeFirst(excess)
            paperStartMs += Int64(Double(excess) / Self.sampleRate * 1000)
            paperGaps = paperGaps.compactMap { g in
                if g.upperBound < excess { return nil }
                return Swift.max(0, g.lowerBound - excess)...(g.upperBound - excess)
            }
        }

        paperScaleCounter += 1
        if paperScaleCounter % 5 == 0 || paperSamples.count < 1000 {
            recomputePaperScale()
        }
    }

    private func recomputePaperScale() {
        guard paperSamples.count > 100 else { return }
        let step = Swift.max(1, paperSamples.count / 2000)
        var vals: [Int16] = []
        vals.reserveCapacity(2000)
        var gIdx = 0
        var i = 0
        while i < paperSamples.count {
            while gIdx < paperGaps.count && paperGaps[gIdx].upperBound < i { gIdx += 1 }
            if gIdx < paperGaps.count && paperGaps[gIdx].contains(i) { i += 1; continue }
            if !paperSamples[i].isECGSaturation { vals.append(paperSamples[i]) }
            i += step
        }
        guard vals.count > 10 else { return }
        vals.sort()
        let p05 = Double(vals[Int(Double(vals.count) * 0.05)])
        let p95 = Double(vals[Int(Double(vals.count) * 0.95)])
        paperValueMid = (p05 + p95) / 2.0
        paperValueHalfSpan = Swift.max(p95 - p05, 400.0) / 2.0 * 1.2
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
            // Resolve an in-flight file-transfer request before anything else.
            if let want = waiterCmd, pkt.cmd == want, let cont = waiterCont {
                waiterCmd = nil
                waiterCont = nil
                waiterId &+= 1   // invalidate the pending timeout for this request
                cont.resume(returning: pkt)
                continue
            }
            if transferMode { continue }  // ignore stray live packets mid-transfer

            if pkt.cmd == ViatomCmd.getRtData.rawValue, let ecg = ECGPacket(payload: pkt.payload) {
                batteryPct = Int(ecg.batteryPct)
                batteryState = Int(ecg.batteryState)
                lastPacketAt = Date()
                totalSamples += ecg.samples.count
                enqueueForPlayback(ecg.samples)
                appendToPaper(ecg.samples)
                onSamples?(ecg.samples)
                // Request next packet immediately — keeps streaming alive
                // in background when the 1s Timer is suspended by iOS.
                send(.getRtData, payload: [0x7D])
            }
        }
    }
}
