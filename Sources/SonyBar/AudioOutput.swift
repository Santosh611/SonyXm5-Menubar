import CoreAudio
import Foundation

/// Minimal CoreAudio helpers for finding the headset's output device and making it the default,
/// plus picking the Mac's default microphone.
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
    static func outputDevices() -> [Device] { devices(scope: kAudioDevicePropertyScopeOutput) }

    /// Input devices (microphones) currently known to CoreAudio.
    static func inputDevices() -> [Device] { devices(scope: kAudioDevicePropertyScopeInput) }

    private static func devices(scope: AudioObjectPropertyScope) -> [Device] {
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
            guard hasStreams(id, scope: scope),
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

    static var defaultOutput: AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInput: AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, id)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var newID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &newID)
        return status == noErr
    }

    // MARK: - Playback activity

    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// True while any app on this Mac is playing through the device.
    static func isRunning(_ id: AudioDeviceID) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &size, &value) == noErr && value != 0
    }


    /// Apps currently playing to the device, by pid, with their bundle IDs (CoreAudio process objects, macOS 14+).
    static func playingProcesses(on device: AudioDeviceID) -> [pid_t: String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [:] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [:] }

        var result: [pid_t: String] = [:]
        for process in processes where uint32(process, kAudioProcessPropertyIsRunningOutput) != 0 {
            // Only count apps playing to the headset, not e.g. to the built-in speakers.
            guard devices(of: process).contains(device) else { continue }
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
            result[pid] = string(process, kAudioProcessPropertyBundleID) ?? "pid \(pid)"
        }
        return result
    }

    private static func devices(of process: AudioObjectID) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    // MARK: - Helpers

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
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
