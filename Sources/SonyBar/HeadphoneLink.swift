import Foundation
import IOBluetooth

/// RFCOMM transport to the headset's MDR service. Sends one command at a time and
/// waits for the headset's ACK before the next, retrying on timeout.
/// All IOBluetooth callbacks arrive on the main run loop.
final class HeadphoneLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    enum Event {
        case opened
        case closed(reason: String)
        case packet(MDR.Packet)
    }

    var onEvent: ((Event) -> Void)?
    let device: IOBluetoothDevice

    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = MDR.Parser()
    private var seq: UInt8 = 0
    private var queue: [[UInt8]] = []
    private var inFlight: [UInt8]?
    private var retries = 0
    private var ackTimer: Timer?

    private static let ackTimeout: TimeInterval = 1.0
    private static let maxRetries = 3

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    var isOpen: Bool { channel?.isOpen() ?? false }

    func open() throws {
        let uuid = Self.sdpUUID(MDR.serviceUUID)
        var record = device.getServiceRecord(for: uuid)
        if record == nil {
            // SDP cache may be stale; refresh synchronously once.
            device.performSDPQuery(nil, uuids: [uuid])
            record = device.getServiceRecord(for: uuid)
        }
        guard let record else { throw LinkError("Headphones don't expose the Sony control service") }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            throw LinkError("Couldn't resolve the control channel")
        }

        var newChannel: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&newChannel, withChannelID: channelID, delegate: self)
        guard result == kIOReturnSuccess else {
            throw LinkError(String(format: "Couldn't open control channel (0x%08X)", result))
        }
        channel = newChannel
    }

    func close() {
        ackTimer?.invalidate()
        queue.removeAll()
        inFlight = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
    }

    /// Queue a Table-1 command payload.
    func send(_ payload: [UInt8]) {
        queue.append(payload)
        pump()
    }

    // MARK: - Send queue

    private func pump() {
        guard inFlight == nil, !queue.isEmpty, isOpen else { return }
        inFlight = queue.removeFirst()
        retries = 0
        transmitInFlight()
    }

    private func transmitInFlight() {
        guard let payload = inFlight else { return }
        write(MDR.pack(type: .mdr, seq: seq, payload: payload))
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: Self.ackTimeout, repeats: false) { [weak self] _ in
            self?.ackTimedOut()
        }
    }

    private func ackTimedOut() {
        retries += 1
        if retries < Self.maxRetries {
            Log.debug("ACK timeout, retry \(retries) for \(inFlight?.hex ?? "")")
            transmitInFlight()
        } else {
            Log.debug("Giving up on \(inFlight?.hex ?? "")")
            // Silence usually means the headset saw this seq as a repeat; try the other one next.
            seq = 1 &- seq
            inFlight = nil
            pump()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        Log.debug(">> \(bytes.hex)")
        var data = bytes
        let result = data.withUnsafeMutableBytes { buf in
            channel.writeSync(buf.baseAddress, length: UInt16(buf.count))
        }
        if result != kIOReturnSuccess { Log.debug(String(format: "write failed 0x%08X", result)) }
    }

    private func handle(_ packet: MDR.Packet) {
        if packet.type == MDR.DataType.ack.rawValue {
            // Only the headset's ACK says which seq it expects next. Its own data packets
            // carry its separate counter; copying that made it drop our commands as duplicates.
            seq = packet.seq
            ackTimer?.invalidate()
            inFlight = nil
            pump()
            return
        }
        write(MDR.pack(type: .ack, seq: 1 &- packet.seq, payload: []))
        onEvent?(.packet(packet))
    }

    // MARK: - IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        if error == kIOReturnSuccess {
            onEvent?(.opened)
            pump()
        } else {
            channel = nil
            onEvent?(.closed(reason: String(format: "Connection failed (0x%08X)", error)))
        }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        Log.debug("<< \(bytes.hex)")
        for packet in parser.feed(bytes) { handle(packet) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        ackTimer?.invalidate()
        channel = nil
        inFlight = nil
        queue.removeAll()
        onEvent?(.closed(reason: "Disconnected"))
    }

    // MARK: - Helpers

    private static func sdpUUID(_ string: String) -> IOBluetoothSDPUUID {
        let uuid = UUID(uuidString: string)!
        var bytes = uuid.uuid
        return withUnsafeBytes(of: &bytes) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
    }
}

struct LinkError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Log {
    static let enabled = ProcessInfo.processInfo.environment["SONYBAR_DEBUG"] != nil
        || CommandLine.arguments.contains("--debug")

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(("[SonyBar] " + message() + "\n").data(using: .utf8)!)
    }
}
