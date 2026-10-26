import AppKit
import SwiftUI

/// `--screenshots <dir>`: renders README screenshots from the real views with demo data.
/// Each scene is composed over a neutral gradient backdrop and captured with `screencapture`,
/// so nothing else on the user's screen ends up in the images.
enum Screenshots {
    private struct Scene {
        let file: String
        let dark: Bool
        let showAmbient: Bool
        let showBands: Bool
        let showPanel: Bool
        let showBanner: Bool
    }

    private static let scenes: [Scene] = [
        Scene(file: "panel-dark.png", dark: true, showAmbient: true, showBands: false, showPanel: true, showBanner: false),
        Scene(file: "panel-light.png", dark: false, showAmbient: true, showBands: false, showPanel: true, showBanner: false),
        Scene(file: "equalizer.png", dark: true, showAmbient: false, showBands: true, showPanel: true, showBanner: false),
        Scene(file: "battery-alert.png", dark: true, showAmbient: false, showBands: false, showPanel: false, showBanner: true),
        Scene(file: "moved-to-mac.png", dark: true, showAmbient: false, showBands: false, showPanel: false, showBanner: true),
        Scene(file: "connected.png", dark: true, showAmbient: false, showBands: false, showPanel: false, showBanner: true),
        Scene(file: "moved-to-mac-light.png", dark: false, showAmbient: false, showBands: false, showPanel: false, showBanner: true),
    ]

    private static var windows: [NSWindow] = []

    static func run(outputDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        capture(index: 0, outputDir: outputDir)
        app.run()
    }

    private static func capture(index: Int, outputDir: String) {
        guard index < scenes.count else {
            print("Screenshots written to \(outputDir)")
            exit(0)
        }
        let scene = scenes[index]
        let rect = present(scene)
        // Let materials and layout settle before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let path = (outputDir as NSString).appendingPathComponent(scene.file)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", path]
            try? task.run()
            task.waitUntilExit()
            print("  \(scene.file)")
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            capture(index: index + 1, outputDir: outputDir)
        }
    }

    /// Shows the scene's windows and returns the capture rect in screencapture's top-left coordinates.
    private static func present(_ scene: Scene) -> CGRect {
        let appearance = NSAppearance(named: scene.dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let padding: CGFloat = 56

        let controller = HeadphoneController(demo: ())
        let panelView = MenuView(controller: controller, showAmbient: scene.showAmbient, showBands: scene.showBands)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            .padding(1)
        let panelHost = NSHostingView(rootView: panelView)
        let panelSize = scene.showPanel ? panelHost.fittingSize : .zero

        let bannerHost = scene.file.hasPrefix("connected")
            ? NSHostingView(rootView: AnyView(BannerView(
                title: "WH-1000XM5", message: "Connected · 82%",
                badge: .init(symbol: "battery.75", color: .green),
                onDismiss: {}, onHover: { _ in })))
            : scene.file.hasPrefix("moved")
            ? NSHostingView(rootView: AnyView(BannerView(
                title: "WH-1000XM5", message: "Moved to this Mac from Santosh’s iPhone",
                badge: .init(symbol: "laptopcomputer", color: .accentColor),
                action: .init(title: "Move Back") {}, alwaysShowAction: true,
                onDismiss: {}, onHover: { _ in })))
            : NSHostingView(rootView: AnyView(BannerView(
                title: "WH-1000XM5 battery low", message: "20% remaining. Charge soon.",
                badge: .init(symbol: "battery.25percent", color: .orange),
                onDismiss: {}, onHover: { _ in })))
        let bannerSize = scene.showBanner ? bannerHost.fittingSize : .zero

        let content = NSSize(width: max(panelSize.width, bannerSize.width),
                             height: panelSize.height + bannerSize.height)
        let backdropSize = NSSize(width: content.width + padding * 2, height: content.height + padding * 2)

        guard let screen = NSScreen.main else { return .zero }
        let visible = screen.visibleFrame
        let backdropFrame = NSRect(x: visible.minX + 40, y: visible.maxY - backdropSize.height - 40,
                                   width: backdropSize.width, height: backdropSize.height)

        let backdrop = makeWindow(frame: backdropFrame, level: .screenSaver, appearance: appearance)
        backdrop.contentView = NSHostingView(rootView: Backdrop(dark: scene.dark))

        if scene.showPanel {
            let frame = NSRect(x: backdropFrame.midX - panelSize.width / 2,
                               y: backdropFrame.midY - panelSize.height / 2,
                               width: panelSize.width, height: panelSize.height)
            let panel = makeWindow(frame: frame, level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1),
                                   appearance: appearance)
            panel.hasShadow = true
            panel.contentView = panelHost
        }
        if scene.showBanner {
            let frame = NSRect(x: backdropFrame.midX - bannerSize.width / 2,
                               y: backdropFrame.midY - bannerSize.height / 2,
                               width: bannerSize.width, height: bannerSize.height)
            let banner = makeWindow(frame: frame, level: NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1),
                                    appearance: appearance)
            banner.contentView = bannerHost
        }

        windows.forEach { $0.orderFrontRegardless() }
        let top = screen.frame.maxY - backdropFrame.maxY
        return CGRect(x: backdropFrame.minX, y: top, width: backdropFrame.width, height: backdropFrame.height)
    }

    // MARK: - Demo video

    /// `--demo-video <file.mov>`: records the panel being used with demo data, over the same backdrop.
    static func recordVideo(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appearance = NSAppearance(named: .darkAqua)
        NSApp.appearance = appearance

        let controller = HeadphoneController(demo: ())
        let panelView = MenuView(controller: controller, showAmbient: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
            .padding(1)
        // Ambient with its controls open is the tallest state in the video; other states sit top-aligned in it.
        let panelSize = NSHostingView(rootView: panelView).fittingSize
        let bannerHost = NSHostingView(rootView: BannerView(
            title: "WH-1000XM5", message: "Moved to this Mac from iPhone",
            badge: .init(symbol: "laptopcomputer", color: .accentColor),
            action: .init(title: "Move Back") {}, alwaysShowAction: true,
            onDismiss: {}, onHover: { _ in }))
        let bannerSize = bannerHost.fittingSize

        let padding: CGFloat = 48, gap: CGFloat = 16
        let size = NSSize(width: max(panelSize.width, bannerSize.width) + padding * 2,
                          height: bannerSize.height + gap + panelSize.height + padding * 2)
        guard let screen = NSScreen.main else { exit(1) }
        let visible = screen.visibleFrame
        let backdropFrame = NSRect(x: visible.minX + 40, y: visible.maxY - size.height - 40,
                                   width: size.width, height: size.height)
        let backdrop = makeWindow(frame: backdropFrame, level: .screenSaver, appearance: appearance)
        backdrop.contentView = NSHostingView(rootView: Backdrop(dark: true))

        let above = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)
        let panel = makeWindow(
            frame: NSRect(x: backdropFrame.midX - panelSize.width / 2, y: backdropFrame.minY + padding,
                          width: panelSize.width, height: panelSize.height),
            level: above, appearance: appearance)
        let panelHost = NSHostingView(rootView: panelView.frame(maxHeight: .infinity, alignment: .top))
        panelHost.sizingOptions = []
        panel.contentView = panelHost

        let banner = makeWindow(
            frame: NSRect(x: backdropFrame.midX - bannerSize.width / 2,
                          y: backdropFrame.maxY - padding - bannerSize.height,
                          width: bannerSize.width, height: bannerSize.height),
            level: above, appearance: appearance)
        banner.contentView = bannerHost
        banner.alphaValue = 0

        backdrop.orderFrontRegardless()
        panel.orderFrontRegardless()

        func at(_ time: TimeInterval, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: step)
        }
        /// Moves a value one unit at a time, like a slider being dragged.
        func ramp(_ from: Int, _ to: Int, start: TimeInterval, interval: TimeInterval = 0.07, _ apply: @escaping (Double) -> Void) {
            let stride = from < to ? 1 : -1
            for (i, value) in Swift.stride(from: from, through: to, by: stride).enumerated() {
                at(start + Double(i) * interval) { apply(Double(value)) }
            }
        }

        let duration = 18
        // Let materials settle, then record the backdrop's area only.
        at(1) {
            let top = screen.frame.maxY - backdropFrame.maxY
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-v", "-V", "\(duration)", "-R",
                              "\(Int(backdropFrame.minX)),\(Int(top)),\(Int(backdropFrame.width)),\(Int(backdropFrame.height))",
                              path]
            task.terminationHandler = { _ in
                print("Video written to \(path)")
                exit(0)
            }
            do { try task.run() } catch { print("screencapture failed: \(error)"); exit(1) }

            at(2.0) { controller.setNoiseMode(.noiseCancelling) }
            at(3.5) { controller.setNoiseMode(.off) }
            at(5.0) { controller.setNoiseMode(.ambient) }
            ramp(14, 5, start: 6.0) { controller.ambientLevel = $0 }
            ramp(5, 17, start: 6.8) { controller.ambientLevel = $0 }
            at(8.0) { controller.setVoiceFocus(false) }
            ramp(18, 26, start: 8.8, interval: 0.09) { controller.setVolume($0) }
            at(10.5) { controller.setEqPreset(EqPreset.all.first { $0.name == "Bass Boost" }!.id) }
            at(12.0) { controller.demoPlay(on: "01") }
            at(14.0) {
                controller.demoPlay(on: "00")
                banner.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    banner.animator().alphaValue = 1
                }
            }
        }
        app.run()
    }

    private static func makeWindow(frame: NSRect, level: NSWindow.Level, appearance: NSAppearance?) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = level
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }
}

private struct Backdrop: View {
    let dark: Bool

    var body: some View {
        LinearGradient(
            colors: dark
                ? [Color(red: 0.13, green: 0.16, blue: 0.33), Color(red: 0.29, green: 0.17, blue: 0.40),
                   Color(red: 0.10, green: 0.26, blue: 0.33)]
                : [Color(red: 0.72, green: 0.83, blue: 0.97), Color(red: 0.95, green: 0.80, blue: 0.86),
                   Color(red: 0.98, green: 0.90, blue: 0.78)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
