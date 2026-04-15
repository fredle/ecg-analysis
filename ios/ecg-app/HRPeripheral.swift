import Foundation
import CoreBluetooth
import Observation

@MainActor
@Observable
final class HRPeripheral: NSObject {
    enum State: Equatable {
        case poweredOff
        case unauthorized
        case idle
        case advertising
    }

    private(set) var state: State = .idle
    private(set) var subscriberCount: Int = 0
    private(set) var currentBPM: Int = 0

    private static let hrService     = CBUUID(string: "180D")
    private static let hrMeasurement = CBUUID(string: "2A37")

    private var manager: CBPeripheralManager!
    private var measurementChar: CBMutableCharacteristic?
    private var subscribers: Set<UUID> = []

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func update(bpm: Int) {
        currentBPM = bpm
        guard let ch = measurementChar, manager.state == .poweredOn else { return }
        manager.updateValue(Self.encode(bpm: bpm), for: ch, onSubscribedCentrals: nil)
    }

    private static func encode(bpm: Int) -> Data {
        let clamped = max(0, min(bpm, 65535))
        if clamped < 256 {
            return Data([0x00, UInt8(clamped)])
        } else {
            return Data([0x01, UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)])
        }
    }

    private func setUpServiceAndAdvertise() {
        guard manager.state == .poweredOn else { return }
        manager.removeAllServices()

        let ch = CBMutableCharacteristic(
            type: Self.hrMeasurement,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        let svc = CBMutableService(type: Self.hrService, primary: true)
        svc.characteristics = [ch]
        measurementChar = ch
        manager.add(svc)
    }
}

extension HRPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.setUpServiceAndAdvertise()
            case .unauthorized:
                self.state = .unauthorized
            default:
                self.state = .poweredOff
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didAdd service: CBService,
                                       error: Error?) {
        Task { @MainActor in
            guard error == nil else { return }
            peripheral.startAdvertising([
                CBAdvertisementDataLocalNameKey: "ECG Relay",
                CBAdvertisementDataServiceUUIDsKey: [Self.hrService]
            ])
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                                         error: Error?) {
        Task { @MainActor in
            if error == nil { self.state = .advertising }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscribers.insert(central.identifier)
            self.subscriberCount = self.subscribers.count
            if self.currentBPM > 0, let ch = self.measurementChar {
                peripheral.updateValue(Self.encode(bpm: self.currentBPM),
                                       for: ch,
                                       onSubscribedCentrals: [central])
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       central: CBCentral,
                                       didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscribers.remove(central.identifier)
            self.subscriberCount = self.subscribers.count
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager,
                                       didReceiveRead request: CBATTRequest) {
        Task { @MainActor in
            let value = Self.encode(bpm: self.currentBPM)
            if request.offset > value.count {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = value.subdata(in: request.offset..<value.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }
}
