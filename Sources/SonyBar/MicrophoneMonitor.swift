import CoreAudio
import Foundation

/// The Mac's microphones and which one is the default input, kept current as devices come and go.
final class MicrophoneMonitor: ObservableObject {
    @Published private(set) var inputs: [AudioOutput.Device] = []
    @Published private(set) var current: AudioDeviceID = 0

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
        // A Bluetooth headset's mic appears and disappears with its hands-free connection.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    deinit {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    func select(_ id: AudioDeviceID) {
        let ok = AudioOutput.setDefaultInput(id)
        Log.debug("Switch microphone to \(inputs.first { $0.id == id }?.name ?? "\(id)"): \(ok ? "ok" : "failed")")
        refresh()
    }

    /// The headset's mic, matched by name (its UID embeds the MAC address, but the name is enough here).
    func headsetInput(named name: String?) -> AudioOutput.Device? {
        guard let name else { return nil }
        return inputs.first { $0.name == name }
    }

    private func refresh() {
        inputs = AudioOutput.inputDevices()
        current = AudioOutput.defaultInput
    }
}
