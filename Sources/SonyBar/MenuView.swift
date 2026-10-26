import SwiftUI
import ServiceManagement

struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    @State private var showBands: Bool
    @State private var showAmbient: Bool
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AudioOutput.switchOnConnectKey) private var switchAudioOnConnect = true
    @AppStorage(HeadphoneController.switchSoundKey) private var playSwitchSound = true
    @AppStorage(HeadphoneController.autoSwitchKey) private var autoSwitchToMac = true
    @AppStorage(HeadphoneController.connectBannerKey) private var showConnectBanner = true

    init(controller: HeadphoneController, showAmbient: Bool = false, showBands: Bool = false) {
        self.controller = controller
        _showAmbient = State(initialValue: showAmbient)
        _showBands = State(initialValue: showBands)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if controller.status == .connected {
                if let volume = controller.volume { volumeControl(volume) }
                noiseControl
                if controller.noiseMode == .ambient { ambientControls }
                Divider()
                equalizer
                if !controller.devices.isEmpty {
                    Divider()
                    devicesSection
                }
            } else {
                statusMessage
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 22))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.deviceName ?? "Sony Headphones")
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = controller.battery {
                BatteryBadge(level: battery, charging: controller.isCharging)
            }
        }
    }

    private var statusText: String {
        switch controller.status {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .noHeadphones, .disconnected: "Not connected"
        case .failed: "Connection problem"
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.status {
            case .noHeadphones:
                Text("Connect your headphones in Bluetooth settings. Controls appear here automatically.")
            case .disconnected:
                Button("Connect") { controller.connectHeadphones() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                if let error = controller.connectError {
                    Text(error)
                }
            case .connecting:
                ProgressView().controlSize(.small)
            case .failed(let reason):
                Text("\(reason). Retrying automatically. If the Sony app is open on another device, it may be holding the controls.")
            case .connected:
                EmptyView()
            }
            if controller.status != .connecting && controller.status != .disconnected {
                Button("Try Again") { controller.reconnect() }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func volumeControl(_ volume: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { volume }, set: { controller.setVolume($0) }),
                   in: 0...Double(Command.maxVolume), step: 1)
                .controlSize(.small)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var noiseControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Noise Control")
            HStack(spacing: 0) {
                ForEach(NoiseMode.allCases) { mode in
                    ModeButton(mode: mode, selected: controller.noiseMode == mode) {
                        controller.setNoiseMode(mode)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var ambientControls: some View {
        Disclosure(isExpanded: $showAmbient) {
            VStack(alignment: .leading, spacing: 6) {
                Slider(value: $controller.ambientLevel, in: 1...20, step: 1) { editing in
                    if !editing { controller.commitAmbientLevel() }
                }
                .controlSize(.small)
                Toggle("Focus on voice", isOn: Binding(
                    get: { controller.voiceFocus },
                    set: { controller.setVoiceFocus($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("Ambient level")
                Spacer()
                Text("\(Int(controller.ambientLevel.rounded()))\(controller.voiceFocus ? " · Voice" : "")")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var equalizer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Equalizer")
                Spacer()
                Picker("", selection: Binding(
                    get: { controller.eqPreset ?? 0x00 },
                    set: { controller.setEqPreset($0) })) {
                    ForEach(EqPreset.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    if let id = controller.eqPreset, !EqPreset.all.contains(where: { $0.id == id }) {
                        Text("Other").tag(id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Disclosure(isExpanded: $showBands) {
                VStack(spacing: 4) {
                    BandSlider(label: "Clear Bass", value: $controller.clearBass) {
                        controller.commitEqBands()
                    }
                    ForEach(0..<5, id: \.self) { i in
                        BandSlider(label: EqPreset.bandLabels[i], value: $controller.eqBands[i]) {
                            controller.commitEqBands()
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Reset") { controller.resetEqBands() }
                            .controlSize(.small)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Adjust bands")
            }
            .font(.callout)
        }
    }

    /// Multipoint devices, like the AirPods device list: tap a connected one to move playback there.
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Devices")
            ForEach(controller.devices) { device in
                DeviceRow(device: device, isThisMac: controller.isThisMac(device)) {
                    controller.switchAudio(to: device)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if controller.status == .connected {
                Button("Turn Off Headphones") { controller.powerOff() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            Spacer()
            Menu {
                Toggle("Play Sound When Switching Modes", isOn: $playSwitchSound)
                Toggle("Switch Mac Audio on Connect", isOn: $switchAudioOnConnect)
                Toggle("Move Headphones to This Mac When It Plays", isOn: $autoSwitchToMac)
                Toggle("Show Notification When Connected", isOn: $showConnectBanner)
                Toggle("Launch at Login", isOn: $launchAtLogin)
                Divider()
                Button("Quit SonyBar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
}

// MARK: - Components

/// Disclosure row where the whole header toggles, not just the chevron.
private struct Disclosure<Content: View, Label: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    label()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded { content() }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

private struct ModeButton: View {
    let mode: NoiseMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.1)))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(mode.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DeviceRow: View {
    let device: PairedDevice
    let isThisMac: Bool
    let onSelect: () -> Void

    private var detail: String {
        if device.playing { return "Playing" }
        return device.connected ? "Connected" : "Not connected"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 15))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isThisMac ? "This Mac" : device.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if device.playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.connected || device.playing)
        .opacity(device.connected ? 1 : 0.45)
        .help(device.connected && !device.playing ? "Play on \(isThisMac ? "this Mac" : device.name)" : "")
        .accessibilityLabel("\(isThisMac ? "This Mac" : device.name), \(detail)")
    }
}

private struct BandSlider: View {
    let label: String
    @Binding var value: Double
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            Slider(value: $value, in: -10...10, step: 1) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            Text(Int(value.rounded()) == 0 ? "0" : String(format: "%+d", Int(value.rounded())))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

func batterySymbol(level: Int, charging: Bool) -> String {
    if charging { return "battery.100.bolt" }
    switch level {
    case ..<13: return "battery.0"
    case ..<38: return "battery.25"
    case ..<63: return "battery.50"
    case ..<88: return "battery.75"
    default: return "battery.100"
    }
}

private struct BatteryBadge: View {
    let level: Int
    let charging: Bool

    private var symbol: String { batterySymbol(level: level, charging: charging) }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(level)%").font(.callout.monospacedDigit())
            Image(systemName: symbol)
                .foregroundStyle(level <= 15 && !charging ? Color.red : Color.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery \(level) percent\(charging ? ", charging" : "")")
    }
}
