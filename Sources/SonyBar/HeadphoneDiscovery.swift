import Foundation
import IOBluetooth

enum HeadphoneDiscovery {
    static let selectionKey = "selectedHeadphoneAddress"
    static let serviceUUID = HeadphoneLink.sdpUUID(MDR.serviceUUID)

    struct Candidate: Identifiable {
        let id: String
        let name: String
        let connected: Bool
        let hasControlService: Bool
    }

    static func normalize(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: ":", with: "-")
    }

    static func candidates() -> [Candidate] {
        pairedDevices().compactMap { device in
            guard let address = device.addressString else { return nil }
            return Candidate(id: normalize(address), name: device.name ?? "Unnamed device",
                             connected: device.isConnected(),
                             hasControlService: device.getServiceRecord(for: serviceUUID) != nil)
        }
    }

    /// Display names are labels, never evidence of control-protocol compatibility.
    static func select(from candidates: [Candidate], preferredAddress: String?) -> Candidate? {
        if let preferredAddress {
            // Keep an explicitly selected device even while offline or its SDP cache is empty.
            // The transport still validates its control service before sending commands.
            return candidates.first { $0.id == normalize(preferredAddress) }
        }
        let supported = candidates.filter(\.hasControlService)
        return supported.first(where: \.connected) ?? supported.first
    }

    static func pairedDevices() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    }

    static func findHeadphones() -> IOBluetoothDevice? {
        guard let selected = select(from: candidates(), preferredAddress:
            UserDefaults.standard.string(forKey: selectionKey)) else { return nil }
        return pairedDevices().first { $0.addressString.map(normalize) == selected.id }
    }
}

/// Retained by its caller until completion. SDP queries are asynchronous, including with a nil target.
final class HeadphoneServiceQuery: NSObject {
    private let device: IOBluetoothDevice
    private var completion: ((IOReturn) -> Void)?
    private var timer: Timer?

    init(device: IOBluetoothDevice, completion: @escaping (IOReturn) -> Void) {
        self.device = device
        self.completion = completion
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.finish(kIOReturnTimeout)
        }
        let result = device.performSDPQuery(self, uuids: [HeadphoneDiscovery.serviceUUID])
        if result != kIOReturnSuccess { finish(result) }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        finish(status)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        completion = nil
    }

    private func finish(_ status: IOReturn) {
        timer?.invalidate()
        timer = nil
        let callback = completion
        completion = nil
        callback?(status)
    }
}
