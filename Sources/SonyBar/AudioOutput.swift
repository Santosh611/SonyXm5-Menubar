import CoreAudio
import Foundation

/// Minimal CoreAudio helpers for finding the headset's output device and making it the default.
enum AudioOutput {
    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String
    }

    static let switchOnConnectKey = "switchAudioOnConnect"

    /// User setting, on unless turned off from the menu.
    static var switchOnConnect: Bool {
        UserDefaults.standard.object(forKey: switchOnConnectKey) as? Bool ?? true
    }

    /// Output devices currently known to CoreAudio.
    static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id),
                  let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, name: name, uid: uid)
        }
    }

    /// The headset's output device. Bluetooth device UIDs embed the MAC address
    /// (e.g. `58-18-62-E1-8D-09:output`); fall back to the name.
    static func device(bluetoothAddress: String?, name: String?) -> Device? {
        let devices = outputDevices()
        if let address = bluetoothAddress.map(normalize), !address.isEmpty,
           let match = devices.first(where: { normalize($0.uid).contains(address) }) {
            return match
        }
        guard let name else { return nil }
        return devices.first { $0.name == name }
    }

    static var defaultOutput: AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var newID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &newID)
        return status == noErr
    }

    // MARK: - Helpers

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func normalize(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: ":", with: "-")
    }
}
