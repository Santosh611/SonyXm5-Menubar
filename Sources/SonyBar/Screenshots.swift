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

        let bannerHost = NSHostingView(rootView: BannerView(
            title: "WH-1000XM5 battery low", message: "20% remaining. Charge soon.",
            badge: .init(symbol: "battery.25percent", color: .orange),
            onDismiss: {}, onHover: { _ in }))
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
