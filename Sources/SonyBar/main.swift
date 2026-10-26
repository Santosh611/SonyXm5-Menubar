import SwiftUI
import AppKit
import IOBluetooth

let showPanelNotification = Notification.Name("dev.santosh.sonybar.showPanel")

/// MenuBarExtra has no API to open its panel, so click its status item button.
func showPanel() {
    let button = NSApp.windows
        .filter { $0.className.contains("StatusBar") }
        .compactMap { $0.contentView.flatMap(findStatusButton) }
        .first
    if let button { button.performClick(nil) } else { Log.debug("No menu bar icon to open (headphones not connected?)") }
}

private func findStatusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    return view.subviews.lazy.compactMap(findStatusButton).first
}

struct SonyBarApp: App {
    @StateObject private var controller = HeadphoneController()

    var body: some Scene {
        // Shown while headphones are paired, so they can be connected from here. Hidden only when
        // there's no Sony headset at all; "connecting" and "failed" stay visible too.
        MenuBarExtra(isInserted: Binding(
            get: { controller.status != .noHeadphones },
            set: { _ in })) {
            MenuView(controller: controller)
        } label: {
            if let battery = controller.menuBarBattery {
                HStack(spacing: 3) {
                    Image(systemName: "headphones")
                    Text("\(battery)%")
                }
            } else {
                Image(systemName: "headphones")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// `--probe [--play-on <device>] [--volume 0-30] [--mode nc|ambient|off] [--level 1-20] [--voice on|off] [--eq <preset name>] [--bands cb,b1,…,b5]`:
/// connect, optionally change settings, print what the headset reports, and exit.
func runProbe() {
    let controller = HeadphoneController()
    let args = CommandLine.arguments
    func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if let level = value("--level").flatMap(Double.init) {
            controller.ambientLevel = level
        }
        switch value("--mode") {
        case "nc": controller.setNoiseMode(.noiseCancelling)
        case "ambient": controller.setNoiseMode(.ambient)
        case "off": controller.setNoiseMode(.off)
        default: if value("--level") != nil { controller.commitAmbientLevel() }
        }
        if let name = value("--eq"), let preset = EqPreset.all.first(where: { $0.name.lowercased() == name.lowercased() }) {
            controller.setEqPreset(preset.id)
        }
        // --bands clearBass,400,1k,2.5k,6.3k,16k  (each -10…10)
        if let bands = value("--bands")?.split(separator: ",").compactMap({ Double($0) }), bands.count == 6 {
            controller.clearBass = bands[0]
            controller.eqBands = Array(bands[1...])
            controller.commitEqBands()
        }
        // --send "a6 20;t2:36 02": raw payloads for protocol exploration (watch with --debug); t2: = Table 2
        for command in value("--send")?.split(separator: ";") ?? [] {
            let table: MDR.DataType = command.hasPrefix("t2:") ? .mdrNo2 : .mdr
            let bytes = command.split(separator: ":").last ?? ""
            controller.sendRaw(bytes.split(separator: " ").compactMap { UInt8($0, radix: 16) }, table: table)
        }
        if let level = value("--volume").flatMap(Double.init) {
            controller.setVolume(level)
        }
        // --play-on <name>: move playback to the connected device whose name contains this
        if let name = value("--play-on"),
           let device = controller.devices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            controller.switchAudio(to: device)
        }
        if let voice = value("--voice") {
            controller.setVoiceFocus(voice == "on")
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
        print("status:     \(controller.status)")
        print("device:     \(controller.deviceName ?? "-")")
        print("battery:    \(controller.battery.map { "\($0)%" } ?? "-")\(controller.isCharging ? " (charging)" : "")")
        print("noise mode: \(controller.noiseMode?.title ?? "-")  ambient level: \(Int(controller.ambientLevel))  voice focus: \(controller.voiceFocus)")
        let preset = EqPreset.all.first { $0.id == controller.eqPreset }?.name ?? controller.eqPreset.map { String(format: "0x%02X", $0) } ?? "-"
        print("volume:     \(controller.volume.map { "\(Int($0))/\(Command.maxVolume)" } ?? "-")")
        for device in controller.devices {
            print("device:     \(device.name) [\(device.address)]\(controller.isThisMac(device) ? " (this Mac)" : "")"
                  + (device.playing ? " playing" : device.connected ? " connected" : " not connected"))
        }
        print("eq preset:  \(preset)  clear bass: \(Int(controller.clearBass))  bands: \(controller.eqBands.map { Int($0) })")
        exit(0)
    }
    RunLoop.main.run()
}

/// `--test-battery-alerts`: run readings through the low-battery tracker and print what fires.
func testBatteryAlerts() {
    var tracker = LowBatteryTracker()
    let readings: [(Int, Bool)] = [(25, false), (20, false), (19, false), (12, false), (10, false), (9, false),
                                   (40, true), (18, false), (8, false), (14, false), (16, false), (10, false)]
    for (level, charging) in readings {
        let alert = tracker.update(level: level, charging: charging)
        print("\(level)%\(charging ? " charging" : "")\t-> \(alert.map { "\($0)" } ?? "-")")
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--screenshots") {
    let dir = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "docs/screenshots"
    Screenshots.run(outputDir: dir)
} else if CommandLine.arguments.contains("--list-audio") {
    let current = AudioOutput.defaultOutput
    for device in AudioOutput.outputDevices() {
        print("\(device.id == current ? "*" : " ") \(device.name)  [\(device.uid)]")
    }
} else if CommandLine.arguments.contains("--test-audio-switch") {
    // Moves output to another device briefly, then lets the headset matcher switch back.
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    guard let headset = paired.first(where: { ($0.name ?? "").contains("1000XM") }),
          let target = AudioOutput.device(bluetoothAddress: headset.addressString, name: headset.name),
          let other = AudioOutput.outputDevices().first(where: { $0.id != target.id }) else {
        print("Headset audio output not found"); exit(1)
    }
    func current() -> String { AudioOutput.outputDevices().first { $0.id == AudioOutput.defaultOutput }?.name ?? "?" }
    print("matched headset output: \(target.name) [\(target.uid)]")
    AudioOutput.setDefaultOutput(other.id)
    print("moved to:    \(current())")
    Thread.sleep(forTimeInterval: 1)
    print("switch back: \(AudioOutput.setDefaultOutput(target.id) ? "ok" : "failed") -> \(current())")
} else if CommandLine.arguments.contains("--test-battery-alerts") {
    testBatteryAlerts()
} else if CommandLine.arguments.contains("--test-notification") {
    BatteryNotifier.post(CommandLine.arguments.contains("--critical") ? .critical : .low,
                         battery: CommandLine.arguments.contains("--critical") ? 10 : 20, deviceName: "WH-1000XM5")
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--probe") {
    runProbe()
} else if let bundleID = Bundle.main.bundleIdentifier,
          NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
              .contains(where: { $0.processIdentifier != getpid() }) {
    // The headset allows one control channel, so a second copy would sit on "Connecting…" forever.
    // Opening the app again should still do something visible: ask the running copy to show its panel.
    Log.debug("SonyBar is already running, showing its panel")
    DistributedNotificationCenter.default().postNotificationName(
        showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
} else {
    DistributedNotificationCenter.default().addObserver(
        forName: showPanelNotification, object: nil, queue: .main) { _ in showPanel() }
    SonyBarApp.main()
}
