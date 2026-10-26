import Foundation
import IOBluetooth
import Combine
import AppKit

/// App state for the connected headset. Lives on the main thread.
final class HeadphoneController: NSObject, ObservableObject {
    enum Status: Equatable {
        case noHeadphones
        /// Paired but not connected to this Mac; the panel offers to connect.
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .noHeadphones
    @Published private(set) var deviceName: String?
    /// Why the last Connect didn't work, shown under the button.
    @Published private(set) var connectError: String?

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

    /// Devices paired with the headset (multipoint), with which one has playback.
    @Published private(set) var devices: [PairedDevice] = []
    private var macAudioDevice: AudioDeviceID?
    private var stopObservingMacAudio: (() -> Void)?
    private var autoSwitchWork: DispatchWorkItem?
    /// Device playback was taken from by an automatic switch, until the switch shows up in the list.
    private var autoSwitchedFrom: PairedDevice?
    private var macAudioAttempts = 0

    private let startedAt = Date()
    /// Set when the headset connects while SonyBar is running; shown once the battery is known.
    private var announceConnection = false

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
        devices = [
            PairedDevice(address: "00", name: "MacBook Pro", connected: true, playing: true, kind: .computer),
            PairedDevice(address: "01", name: "iPhone", connected: true, playing: false, kind: .phone),
        ]
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
            status = .disconnected
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

    /// Connect button: bring up the Bluetooth link, like Connect in Bluetooth settings.
    /// The connect notification then opens the control channel as usual.
    func connectHeadphones() {
        guard let device = Self.findHeadphones(), !device.isConnected() else { return connectIfPossible() }
        Log.debug("Connecting to \(device.name ?? "headphones")")
        connectError = nil
        status = .connecting
        let result = device.openConnection(self)
        if result != kIOReturnSuccess { connectionComplete(device, status: result) }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status result: IOReturn) {
        guard result != kIOReturnSuccess else { return }
        Log.debug(String(format: "Bluetooth connect failed (0x%08X)", result))
        connectError = "Couldn't reach the headphones. Make sure they're on and nearby."
        status = .disconnected
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
        // IOBluetooth reports already-connected devices right after launch; only announce real connections.
        if Date().timeIntervalSince(startedAt) > 5 { announceConnection = true }
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
        tearDown(status: .disconnected)
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
        devices = []
        autoSwitchedFrom = nil
        detachMacAudio()
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
            link?.send(Command2.getDevices, table: .mdrNo2)
            probeNcAsm()
            macAudioAttempts = 0
            attachMacAudio()
            // Normally the battery reply triggers the banner; don't wait forever for it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.announceConnectionIfNeeded() }
            batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.link?.send(Command.getBattery)
            }
        case .closed(let reason):
            Log.debug("Control channel lost: \(reason)")
            let stillConnected = link?.device.isConnected() ?? false
            tearDown(status: stillConnected ? .failed(reason) : .disconnected)
            if stillConnected { scheduleReconnect() }
        case .packet(let packet):
            switch packet.type {
            case MDR.DataType.mdr.rawValue: parse(packet.payload)
            case MDR.DataType.mdrNo2.rawValue: parseTable2(packet.payload)
            default: break
            }
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

    private func parseTable2(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        switch (p[0], p[1]) {
        case (Command2.retPeriParam, Command2.deviceListType), (Command2.ntfyPeriParam, Command2.deviceListType):
            guard let list = PairedDevice.parseList(p) else { return }
            devices = list
            Log.debug("Devices: " + list.map { "\($0.name)\($0.playing ? " (playing)" : $0.connected ? "" : " (off)")" }
                .joined(separator: ", "))
            confirmAutoSwitch()
        case (Command2.ntfyPeriExtParam, Command2.sourceSwitchType), (Command2.ntfyPeriParam, Command2.sourceSwitchType):
            // Switch result; 0 = success, 2 = refused during a call. Refresh the list either way.
            if p.count >= 3, p[0] == Command2.ntfyPeriExtParam { Log.debug("Source switch result \(p[2])") }
            link?.send(Command2.getDevices, table: .mdrNo2)
        default:
            break
        }
    }

    func updateBattery(level: Int, charging: Bool) {
        battery = level
        isCharging = charging
        announceConnectionIfNeeded()
        if let alert = lowBattery.update(level: level, charging: charging) {
            Log.debug("Low battery alert: \(alert) at \(level)%")
            BatteryNotifier.post(alert, battery: level, deviceName: deviceName ?? "Headphones")
        }
    }

    static let connectBannerKey = "showConnectBanner"

    /// AirPods-style "Connected" banner with the battery level.
    private func announceConnectionIfNeeded() {
        guard announceConnection, status == .connected else { return }
        announceConnection = false
        guard UserDefaults.standard.object(forKey: Self.connectBannerKey) as? Bool ?? true else { return }
        let body = battery.map { "Connected · \($0)%\(isCharging ? ", charging" : "")" } ?? "Connected"
        BannerWindow.show(
            title: deviceName ?? "Headphones", body: body,
            symbol: battery.map { batterySymbol(level: $0, charging: isCharging) } ?? "checkmark",
            color: (battery ?? 100) <= LowBatteryTracker.menuBarThreshold && !isCharging ? .orange : .green,
            action: nil)
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

    // MARK: - Multipoint

    static let autoSwitchKey = "autoSwitchToMac"
    private static var autoSwitchEnabled: Bool {
        UserDefaults.standard.object(forKey: autoSwitchKey) as? Bool ?? true
    }

    /// This Mac's Bluetooth address in the headset's format ("AA:BB:CC:DD:EE:FF").
    static let macAddress: String? = IOBluetoothHostController.default()?.addressAsString()?
        .uppercased().replacingOccurrences(of: "-", with: ":")

    func isThisMac(_ device: PairedDevice) -> Bool {
        device.address.uppercased() == Self.macAddress
    }

    /// Moves headset playback to another connected device.
    func switchAudio(to device: PairedDevice) {
        guard device.connected, !device.playing else { return }
        Log.debug("Switching playback to \(device.name)")
        link?.send(Command2.switchSource(to: device.address), table: .mdrNo2)
        // Not every firmware notifies the new state, so ask again shortly after.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.link?.send(Command2.getDevices, table: .mdrNo2)
        }
    }

    /// Watch this Mac's headset output so playback can follow the Mac, like AirPods.
    /// The audio device can appear a few seconds after the control channel, so retry briefly.
    private func attachMacAudio() {
        guard status == .connected, let device = link?.device else { return }
        guard let output = AudioOutput.device(bluetoothAddress: device.addressString, name: device.name) else {
            macAudioAttempts += 1
            if macAudioAttempts < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attachMacAudio() }
            }
            return
        }
        guard output.id != macAudioDevice else { return }
        detachMacAudio()
        macAudioDevice = output.id
        stopObservingMacAudio = AudioOutput.observeRunning(output.id) { [weak self] running in
            self?.macAudioChanged(running: running)
        }
    }

    private func detachMacAudio() {
        stopObservingMacAudio?()
        stopObservingMacAudio = nil
        macAudioDevice = nil
        autoSwitchWork?.cancel()
    }

    /// Only a start of playback counts, and only if it lasts: a notification sound shouldn't
    /// take the headset from the phone, and switching back by hand isn't undone while audio keeps going.
    private func macAudioChanged(running: Bool) {
        autoSwitchWork?.cancel()
        guard running else { return }
        let work = DispatchWorkItem { [weak self] in self?.autoSwitchToMac() }
        autoSwitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func autoSwitchToMac() {
        guard Self.autoSwitchEnabled, status == .connected,
              let id = macAudioDevice, AudioOutput.isRunning(id),
              let current = devices.first(where: \.playing), !isThisMac(current),
              let mac = devices.first(where: isThisMac), mac.connected else { return }
        Log.debug("Mac started playing; taking playback from \(current.name)")
        autoSwitchedFrom = current
        switchAudio(to: mac)
    }

    /// Once the list shows the Mac playing after an automatic switch, offer the way back.
    private func confirmAutoSwitch() {
        guard let previous = autoSwitchedFrom,
              devices.first(where: \.playing).map(isThisMac) == true else { return }
        autoSwitchedFrom = nil
        BannerWindow.show(
            title: deviceName ?? "Headphones",
            body: "Moved to this Mac from \(previous.name)",
            symbol: "laptopcomputer",
            action: .init(title: "Move Back") { [weak self] in
                guard let self, let device = self.devices.first(where: { $0.address == previous.address }) else { return }
                self.switchAudio(to: device)
            })
    }


    /// For `--probe --send`: queue a raw Table-1 payload.
    func sendRaw(_ payload: [UInt8], table: MDR.DataType = .mdr) {
        link?.send(payload, table: table)
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
