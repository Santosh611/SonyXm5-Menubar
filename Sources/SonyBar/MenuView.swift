import SwiftUI
import ServiceManagement

struct MenuView: View {
    @ObservedObject var controller: HeadphoneController
    @State private var showBands = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if controller.status == .connected {
                noiseControl
                if controller.noiseMode == .ambient { ambientControls }
                Divider()
                equalizer
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
        case .noHeadphones: "Not connected"
        case .failed: "Connection problem"
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.status {
            case .noHeadphones:
                Text("Connect your headphones in Bluetooth settings. Controls appear here automatically.")
            case .connecting:
                ProgressView().controlSize(.small)
            case .failed(let reason):
                Text(reason)
            case .connected:
                EmptyView()
            }
            if controller.status != .connecting {
                Button("Try Again") { controller.reconnect() }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ambient level").font(.callout)
                Spacer()
                Text("\(Int(controller.ambientLevel.rounded()))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $controller.ambientLevel, in: 1...20, step: 1) { editing in
                if !editing { controller.commitAmbientLevel() }
            }
            Toggle("Focus on voice", isOn: Binding(
                get: { controller.voiceFocus },
                set: { controller.setVoiceFocus($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
        }
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

            DisclosureGroup("Adjust bands", isExpanded: $showBands) {
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
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                if controller.status == .connected {
                    Button("Turn Off Headphones") { controller.powerOff() }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

// MARK: - Components

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
            Text(String(format: "%+d", Int(value.rounded())))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

private struct BatteryBadge: View {
    let level: Int
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100.bolt" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

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
