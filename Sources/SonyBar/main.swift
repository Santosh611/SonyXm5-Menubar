import SwiftUI
import AppKit

struct SonyBarApp: App {
    @StateObject private var controller = HeadphoneController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: "headphones")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `--probe [--mode nc|ambient|off] [--level 1-20] [--voice on|off] [--eq <preset name>] [--bands cb,b1,…,b5]`:
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
        print("eq preset:  \(preset)  clear bass: \(Int(controller.clearBass))  bands: \(controller.eqBands.map { Int($0) })")
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--probe") {
    runProbe()
} else {
    SonyBarApp.main()
}
