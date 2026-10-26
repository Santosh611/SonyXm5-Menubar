import Foundation

/// Sony "MDR" protocol, as spoken by WH-1000XM5 and other v2 headsets over RFCOMM.
///
/// Frame: `>` + escape(type, seq, len:Int32BE, payload, checksum) + `<`
/// Reverse-engineered by the SonyHeadphonesClient project (MIT); see libmdr.
enum MDR {
    static let serviceUUID = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

    static let startMarker: UInt8 = 0x3E  // >
    static let endMarker: UInt8 = 0x3C    // <
    static let escapeByte: UInt8 = 0x3D   // =

    enum DataType: UInt8 {
        case data = 0x00
        case ack = 0x01
        case mdr = 0x0C      // "Table 1" commands: NC/ASM, EQ, battery…
        case mdrNo2 = 0x0E   // "Table 2" commands
    }

    struct Packet {
        let type: UInt8
        let seq: UInt8
        let payload: [UInt8]
    }

    static func pack(type: DataType, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = [type.rawValue, seq]
        let n = UInt32(payload.count)
        body += [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        body += payload
        body.append(body.reduce(0, &+))

        var out: [UInt8] = [startMarker]
        for byte in body {
            switch byte {
            case 0x3C, 0x3D, 0x3E: out += [escapeByte, byte - 0x10]  // 0x3C -> 3D 2C, etc.
            default: out.append(byte)
            }
        }
        out.append(endMarker)
        return out
    }

    /// Accumulates raw RFCOMM bytes and yields complete packets.
    struct Parser {
        private var buffer: [UInt8] = []

        mutating func feed(_ bytes: [UInt8]) -> [Packet] {
            buffer += bytes
            var packets: [Packet] = []
            while let start = buffer.firstIndex(of: startMarker),
                  let end = buffer[start...].firstIndex(of: endMarker) {
                let frame = Array(buffer[(start + 1)..<end])
                buffer.removeSubrange(..<(end + 1))
                if let packet = Parser.decode(frame) { packets.append(packet) }
            }
            // Drop leading garbage with no start marker.
            if !buffer.contains(startMarker) { buffer.removeAll() }
            return packets
        }

        private static func decode(_ escaped: [UInt8]) -> Packet? {
            var raw: [UInt8] = []
            var i = 0
            while i < escaped.count {
                if escaped[i] == escapeByte {
                    guard i + 1 < escaped.count else { return nil }
                    raw.append(escaped[i + 1] + 0x10)
                    i += 2
                } else {
                    raw.append(escaped[i])
                    i += 1
                }
            }
            guard raw.count >= 7 else { return nil }
            let checksum = raw.removeLast()
            guard raw.reduce(0, &+) == checksum else { return nil }
            let len = Int(raw[2]) << 24 | Int(raw[3]) << 16 | Int(raw[4]) << 8 | Int(raw[5])
            let payload = Array(raw[6...])
            guard payload.count == len else { return nil }
            return Packet(type: raw[0], seq: raw[1], payload: payload)
        }
    }
}

/// Table-1 command payloads used by the app.
enum Command {
    static let getProtocolInfo: [UInt8] = [0x00, 0x00]
    static let getBattery: [UInt8] = [0x22, 0x00]
    static let powerOff: [UInt8] = [0x24, 0x03, 0x01]
    static let getEq: [UInt8] = [0x56, 0x00]

    static func getNcAsm(type: UInt8) -> [UInt8] { [0x66, type] }

    /// Headset volume, 0…30. Applies to whatever is playing, including a phone over multipoint.
    static let volumeType: UInt8 = 0x20
    static let getVolume: [UInt8] = [0xA6, volumeType]
    static func setVolume(_ level: Int) -> [UInt8] { [0xA8, volumeType, UInt8(clamping: level)] }
    static let maxVolume = 30

    /// Preset change with no band values; the headset answers with the preset's bands.
    static func setEqPreset(_ preset: UInt8) -> [UInt8] { [0x58, 0x00, preset, 0x00] }

    /// `clearBass` and `bands` are in -10…+10.
    static func setEqBands(preset: UInt8, clearBass: Int, bands: [Int]) -> [UInt8] {
        let values = ([clearBass] + bands).map { UInt8(clamping: $0 + 10) }
        return [0x58, 0x00, preset, UInt8(values.count)] + values
    }

    // Reply / notification command IDs
    static let retProtocolInfo: UInt8 = 0x01
    static let retBattery: UInt8 = 0x23
    static let ntfyBattery: UInt8 = 0x25
    static let retEq: UInt8 = 0x57
    static let ntfyEq: UInt8 = 0x59
    static let retNcAsm: UInt8 = 0x67
    static let setNcAsm: UInt8 = 0x68
    static let ntfyNcAsm: UInt8 = 0x69
    static let retPlayParam: UInt8 = 0xA7
    static let ntfyPlayParam: UInt8 = 0xA9

    /// NC/ASM inquiry types to try, in order. XM5 uses 0x17; XM6-era firmware adds noise adaptation (0x19).
    static let ncAsmTypes: [UInt8] = [0x17, 0x19]
}

enum NoiseMode: String, CaseIterable, Identifiable {
    case noiseCancelling, off, ambient
    var id: String { rawValue }

    var title: String {
        switch self {
        case .noiseCancelling: "Noise Cancelling"
        case .off: "Off"
        case .ambient: "Ambient"
        }
    }

    var symbol: String {
        switch self {
        case .noiseCancelling: "person.and.background.dotted"
        case .off: "person.fill"
        case .ambient: "waveform"
        }
    }
}

struct EqPreset: Identifiable, Hashable {
    let id: UInt8
    let name: String

    static let all: [EqPreset] = [
        .init(id: 0x00, name: "Off"),
        .init(id: 0x10, name: "Bright"),
        .init(id: 0x11, name: "Excited"),
        .init(id: 0x12, name: "Mellow"),
        .init(id: 0x13, name: "Relaxed"),
        .init(id: 0x14, name: "Vocal"),
        .init(id: 0x15, name: "Treble Boost"),
        .init(id: 0x16, name: "Bass Boost"),
        .init(id: 0x17, name: "Speech"),
        .init(id: 0xA0, name: "Manual"),
        .init(id: 0xA1, name: "Custom 1"),
        .init(id: 0xA2, name: "Custom 2"),
    ]

    static let manual: UInt8 = 0xA0
    static let editable: Set<UInt8> = [0xA0, 0xA1, 0xA2]
    static let bandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]
}

extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
