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
    private var queue: [(MDR.DataType, [UInt8])] = []
    private var inFlight: (MDR.DataType, [UInt8])?
    private var retries = 0
    private var unansweredCommands = 0
    private var ackTimer: Timer?
    private var openTimer: Timer?

    private static let ackTimeout: TimeInterval = 1.0
    /// The headset sometimes accepts the open request and never answers (e.g. while another
    /// device's Sony app holds the control channel). Give up so the controller can retry.
    private static let openTimeout: TimeInterval = 10
    private static let maxRetries = 3
    /// A dropped command is normal now and then (seq mismatch), but a run of them means the
    /// channel is dead, typically one opened before the Mac slept. Report it so we reconnect.
    private static let maxUnansweredCommands = 2

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
        Log.debug("Opening control channel \(channelID)")
        openTimer = Timer.scheduledTimer(withTimeInterval: Self.openTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.isOpen {
                // IOBluetooth sometimes opens the channel without calling rfcommChannelOpenComplete
                // (seen after the headset reconnects). Waiting for it would leave us "connecting" forever.
                Log.debug("Control channel open without completion callback")
                self.onEvent?(.opened)
                self.pump()
                return
            }
            Log.debug("Control channel didn't open in \(Int(Self.openTimeout))s")
            self.close()
            self.onEvent?(.closed(reason: "Headphones didn't respond"))
        }
    }

    func close() {
        openTimer?.invalidate()
        ackTimer?.invalidate()
        queue.removeAll()
        inFlight = nil
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
    }

    /// Queue a command payload; Table 1 unless `table` says otherwise.
    func send(_ payload: [UInt8], table: MDR.DataType = .mdr) {
        queue.append((table, payload))
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
        guard let (table, payload) = inFlight else { return }
        write(MDR.pack(type: table, seq: seq, payload: payload))
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: Self.ackTimeout, repeats: false) { [weak self] _ in
            self?.ackTimedOut()
        }
    }

    private func ackTimedOut() {
        retries += 1
        if retries < Self.maxRetries {
            Log.packet("ACK timeout, retry \(retries) for \(inFlight?.1.hex ?? "")")
            transmitInFlight()
        } else {
            Log.debug("Giving up on \(inFlight?.1.hex ?? "")")
            unansweredCommands += 1
            if unansweredCommands >= Self.maxUnansweredCommands {
                Log.debug("Headphones stopped answering, closing control channel")
                close()
                onEvent?(.closed(reason: "Headphones stopped responding"))
                return
            }
            // Silence usually means the headset saw this seq as a repeat; try the other one next.
            seq = 1 &- seq
            inFlight = nil
            pump()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let channel else { return }
        Log.packet(">> \(bytes.hex)")
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
            unansweredCommands = 0
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
        openTimer?.invalidate()
        Log.debug(String(format: "Control channel open complete (0x%08X)", error))
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
        Log.packet("<< \(bytes.hex)")
        for packet in parser.feed(bytes) { handle(packet) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        Log.debug("Control channel closed")
        openTimer?.invalidate()
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

/// Connection events always go to ~/Library/Logs/SonyBar.log so a stall can be diagnosed after the fact.
/// Raw packets only appear with --debug (or SONYBAR_DEBUG), on stderr.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["SONYBAR_DEBUG"] != nil
        || CommandLine.arguments.contains("--debug")

    private static let file: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SonyBar.log")
        // Keep one previous log once this one passes 1 MB.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        file?.write("\(timestamp.string(from: Date())) [\(getpid())] \(text)\n".data(using: .utf8)!)
        packet(text)
    }

    static func packet(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(("[SonyBar] " + message() + "\n").data(using: .utf8)!)
    }
}
