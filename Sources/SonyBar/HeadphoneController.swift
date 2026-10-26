import Foundation
import IOBluetooth
import Combine
import AppKit

/// App state for the connected headset. Lives on the main thread.
final class HeadphoneController: NSObject, ObservableObject {
    enum Status: Equatable {
        case noHeadphones
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .noHeadphones
    @Published private(set) var deviceName: String?

    @Published private(set) var battery: Int?
    @Published private(set) var isCharging = false

    @Published private(set) var noiseMode: NoiseMode?
    @Published var ambientLevel: Double = 10     // 1…20, bound directly to the slider
    @Published private(set) var voiceFocus = false

    @Published private(set) var eqPreset: UInt8?
    @Published var clearBass: Double = 0         // -10…10
    @Published var eqBands: [Double] = Array(repeating: 0, count: 5)

    /// Headset volume, 0…30. Nil until the headset reports it.
    @Published private(set) var volume: Double?
    private var sentVolume: Int?

    private var link: HeadphoneLink?
    private var lowBattery = LowBatteryTracker()
    private var ncAsmTemplate: [UInt8]?          // last NC/ASM reply, reused as the SET template
    private var ncAsmProbeIndex = 0
    private var ncAsmProbeTimer: Timer?
    private var batteryTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts = 0
    private var audioRouteTimer: Timer?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?

    override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        connectIfPossible()
    }

    /// Offline controller with fixed sample state, for README screenshots. Never touches Bluetooth.
    init(demo: Void) {
        super.init()
        status = .connected
        deviceName = "WH-1000XM5"
        battery = 82
        noiseMode = .ambient
        ambientLevel = 14
        voiceFocus = true
        eqPreset = EqPreset.manual
        clearBass = 3
        eqBands = [2, 0, -1, 1, 3]
        volume = 18
    }

    // MARK: - Connection

    func connectIfPossible() {
        // A link that exists is either open or still opening. Replacing an open in progress
        // aborts it mid-handshake, which can leave the headset ignoring every later attempt.
        guard link == nil else { return }
        guard let device = Self.findHeadphones() else {
            status = .noHeadphones
            deviceName = nil
            return
        }
        connect(to: device)
    }

    private func connect(to device: IOBluetoothDevice) {
        link?.close()
        deviceName = device.name
        guard device.isConnected() else {
            Log.debug("\(device.name ?? "Headphones") not connected, skipping control channel")
            status = .noHeadphones
            return
        }
        // Background retries keep showing the last problem instead of flipping back to a spinner.
        if case .failed = status {} else { status = .connecting }
        let link = HeadphoneLink(device: device)
        link.onEvent = { [weak self] in self?.handle($0) }
        self.link = link
        do {
            try link.open()
        } catch {
            self.link = nil
            status = .failed(error.localizedDescription)
            scheduleReconnect()
        }
    }

    /// Paired Sony headset with the MDR service; prefers one that's currently connected.
    private static func findHeadphones() -> IOBluetoothDevice? {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let sony = paired.filter { device in
            let name = device.name ?? ""
            return name.contains("1000XM") || name.hasPrefix("WH-") || name.hasPrefix("WF-") || name.contains("LinkBuds")
        }
        return sony.first(where: { $0.isConnected() }) ?? sony.first
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.findHeadphones()?.addressString == device.addressString else { return }
        Log.debug("\(device.name ?? "device") connected")
        reconnectAttempts = 0
        routeAudioToHeadphones(device)
        // Give the audio profiles a moment to settle before opening the control channel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.connectIfPossible()
        }
    }

    /// A channel opened before sleep is often dead after wake; start over once Bluetooth is back.
    @objc private func didWake(_ note: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            if self.status == .connected {
                // It may only look connected. If this goes unanswered the link reports it closed.
                Log.debug("Woke from sleep, checking control channel")
                self.link?.send(Command.getBattery)
                self.link?.send(Command.getNcAsm(type: self.ncAsmTemplate?[1] ?? Command.ncAsmTypes[0]))
                return
            }
            Log.debug("Woke from sleep, reconnecting")
            self.reconnectAttempts = 0
            self.reconnect()
        }
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Log.debug("\(device.name ?? "device") disconnected")
        tearDown(status: .noHeadphones)
    }

    /// macOS doesn't always pick the headset as output when it reconnects (common with multipoint).
    /// Wait for its audio device to appear, then make it the default output.
    private func routeAudioToHeadphones(_ device: IOBluetoothDevice) {
        guard AudioOutput.switchOnConnect else { return }
        audioRouteTimer?.invalidate()
        let address = device.addressString
        let name = device.name
        let deadline = Date().addingTimeInterval(15)
        audioRouteTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if let output = AudioOutput.device(bluetoothAddress: address, name: name) {
                timer.invalidate()
                if AudioOutput.defaultOutput != output.id {
                    let ok = AudioOutput.setDefaultOutput(output.id)
                    Log.debug("Switch audio output to \(output.name): \(ok ? "ok" : "failed")")
                }
            } else if Date() > deadline {
                timer.invalidate()
                Log.debug("\(name ?? "Headphones") audio output never appeared")
            }
        }
    }

    /// Keeps retrying while the headset stays connected: 5s, 10s, 20s, then every 30s.
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let delay = min(5 * pow(2, Double(reconnectAttempts)), 30)
        reconnectAttempts += 1
        Log.debug("Reconnecting in \(Int(delay))s")
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connectIfPossible()
        }
    }

    private func tearDown(status newStatus: Status) {
        link?.close()
        link = nil
        batteryTimer?.invalidate()
        ncAsmProbeTimer?.invalidate()
        disconnectNotification?.unregister()
        disconnectNotification = nil
        status = newStatus
        ncAsmTemplate = nil
        noiseMode = nil
        battery = nil
        eqPreset = nil
        volume = nil
        sentVolume = nil
    }

    // MARK: - Link events

    private func handle(_ event: HeadphoneLink.Event) {
        switch event {
        case .opened:
            Log.debug("Connected to \(deviceName ?? "headphones")")
            status = .connected
            reconnectAttempts = 0
            if let device = link?.device {
                disconnectNotification = device.register(
                    forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
            }
            link?.send(Command.getProtocolInfo)
            link?.send(Command.getBattery)
            link?.send(Command.getEq)
            ncAsmProbeIndex = 0
            link?.send(Command.getVolume)
            probeNcAsm()
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.link?.send(Command.getBattery)
            }
        case .closed(let reason):
            Log.debug("Control channel lost: \(reason)")
            let stillConnected = link?.device.isConnected() ?? false
            tearDown(status: stillConnected ? .failed(reason) : .noHeadphones)
            if stillConnected { scheduleReconnect() }
        case .packet(let packet):
            guard packet.type == MDR.DataType.mdr.rawValue else { return }
            parse(packet.payload)
        }
    }

    /// Ask for NC/ASM state with each known inquiry type until one answers.
    private func probeNcAsm() {
        guard ncAsmTemplate == nil, ncAsmProbeIndex < Command.ncAsmTypes.count else { return }
        link?.send(Command.getNcAsm(type: Command.ncAsmTypes[ncAsmProbeIndex]))
        ncAsmProbeIndex += 1
        ncAsmProbeTimer?.invalidate()
        ncAsmProbeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.probeNcAsm()
        }
    }

    private func parse(_ p: [UInt8]) {
        guard let command = p.first else { return }
        switch command {
        case Command.retBattery, Command.ntfyBattery:
            // [cmd, type=0x00, level, chargingStatus]
            guard p.count >= 4, p[1] == 0x00 else { return }
            updateBattery(level: Int(p[2]), charging: p[3] == 1)
        case Command.retNcAsm, Command.ntfyNcAsm:
            // [cmd, type, changeStatus, totalEffect, ncAsmMode, ambientMode, level, …]
            guard p.count >= 7, Command.ncAsmTypes.contains(p[1]) else { return }
            ncAsmTemplate = p
            ncAsmProbeTimer?.invalidate()
            noiseMode = p[3] == 0 ? .off : (p[4] == 0 ? .noiseCancelling : .ambient)
            voiceFocus = p[5] == 1
            ambientLevel = Double(p[6])
        case Command.retEq, Command.ntfyEq:
            // [cmd, type=0x00, preset, count, clearBass, b1…b5]
            guard p.count >= 4, p[1] == 0x00 else { return }
            eqPreset = p[2]
            let count = Int(p[3])
            if count == 6, p.count >= 10 {
                clearBass = Double(Int(p[4]) - 10)
                eqBands = (5..<10).map { Double(Int(p[$0]) - 10) }
            }
        case Command.retPlayParam, Command.ntfyPlayParam:
            // [cmd, type=0x20, level]; type 0x01 is now-playing info, which we ignore
            guard p.count >= 3, p[1] == Command.volumeType else { return }
            volume = Double(p[2])
            sentVolume = Int(p[2])
        default:
            break
        }
    }

    func updateBattery(level: Int, charging: Bool) {
        battery = level
        isCharging = charging
        if let alert = lowBattery.update(level: level, charging: charging) {
            Log.debug("Low battery alert: \(alert) at \(level)%")
            BatteryNotifier.post(alert, battery: level, deviceName: deviceName ?? "Headphones")
        }
    }

    /// Battery to show beside the menu bar icon, only when it needs attention.
    var menuBarBattery: Int? {
        guard status == .connected, let battery, !isCharging,
              battery <= LowBatteryTracker.menuBarThreshold else { return nil }
        return battery
    }

    // MARK: - User actions

    static let switchSoundKey = "playSwitchSound"

    func setNoiseMode(_ mode: NoiseMode) {
        // The headset only plays its own tone for the physical button, so confirm app switches here.
        if mode != noiseMode, UserDefaults.standard.object(forKey: Self.switchSoundKey) as? Bool ?? true {
            NSSound(named: "Pop")?.play()
        }
        noiseMode = mode
        sendNcAsm()
    }

    func setVoiceFocus(_ on: Bool) {
        voiceFocus = on
        sendNcAsm()
    }

    /// Call when the ambient slider is released.
    func commitAmbientLevel() {
        sendNcAsm()
    }

    private func sendNcAsm() {
        guard let mode = noiseMode else { return }
        var p = ncAsmTemplate ?? [Command.setNcAsm, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14]
        p[0] = Command.setNcAsm
        p[2] = 0x01                                   // value changed (not mid-drag)
        p[3] = mode == .off ? 0 : 1                   // NC/ASM effect on/off
        p[4] = mode == .ambient ? 1 : (mode == .noiseCancelling ? 0 : p[4])
        p[5] = voiceFocus ? 1 : 0
        p[6] = UInt8(clamping: Int(ambientLevel.rounded()))
        link?.send(p)
    }

    func setEqPreset(_ preset: UInt8) {
        eqPreset = preset
        link?.send(Command.setEqPreset(preset))
        link?.send(Command.getEq)
    }

    /// Call when an EQ slider is released. Switches to Manual if a fixed preset is active.
    func commitEqBands() {
        let preset = eqPreset.flatMap { EqPreset.editable.contains($0) ? $0 : nil } ?? EqPreset.manual
        eqPreset = preset
        link?.send(Command.setEqBands(
            preset: preset,
            clearBass: Int(clearBass.rounded()),
            bands: eqBands.map { Int($0.rounded()) }))
    }

    func resetEqBands() {
        clearBass = 0
        eqBands = Array(repeating: 0, count: 5)
        commitEqBands()
    }

    /// Called while the slider moves; only sends when the level actually changes.
    func setVolume(_ value: Double) {
        volume = value
        let level = Int(value.rounded())
        guard level != sentVolume else { return }
        sentVolume = level
        link?.send(Command.setVolume(level))
    }

    /// For `--probe --send`: queue a raw Table-1 payload.
    func sendRaw(_ payload: [UInt8]) {
        link?.send(payload)
    }

    func powerOff() {
        link?.send(Command.powerOff)
    }

    func reconnect() {
        reconnectTimer?.invalidate()
        tearDown(status: .connecting)
        connectIfPossible()
    }
}
