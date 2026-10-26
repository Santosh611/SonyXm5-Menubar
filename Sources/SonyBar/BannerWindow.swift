import AppKit
import SwiftUI

/// Notification-style banner in the top-right corner, sized like a macOS notification.
/// Needs no permissions. Dismisses after a few seconds (paused while hovered),
/// via the hover close button, or when clicked.
enum BannerWindow {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    /// Gap between the banner and the screen edges, matching system notifications.
    private static let screenMargin: CGFloat = 10
    private static let visibleFor: TimeInterval = 8
    private static let resumeAfterHover: TimeInterval = 4

    static func show(title: String, body: String, critical: Bool) {
        show(title: title, body: body,
             badge: .init(symbol: critical ? "battery.0percent" : "battery.25percent", color: critical ? .red : .orange),
             sound: critical ? "Funk" : "Tink", action: nil)
    }

    /// Silent banner with a device badge and an optional button, e.g. after an automatic source switch.
    static func show(title: String, body: String, symbol: String, color: Color = .accentColor, action: Action?) {
        show(title: title, body: body, badge: .init(symbol: symbol, color: color), sound: nil, action: action)
    }

    private static func show(title: String, body: String, badge: BannerView.Badge, sound: String?, action: Action?) {
        dismiss(animated: false)

        let hosting = NSHostingView(rootView: BannerView(
            title: title, message: body, badge: badge,
            action: action.map { action in
                BannerWindow.Action(title: action.title) {
                    dismiss(animated: true)
                    action.perform()
                }
            },
            onDismiss: { dismiss(animated: true) },
            onHover: { hovering in
                if hovering { cancelAutoDismiss() } else { scheduleAutoDismiss(after: resumeAfterHover) }
            }))
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // drawn by SwiftUI so the transparent close-button margin stays shadowless
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.contentView = hosting

        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        // The view carries an outer inset for the close button; align the card itself to the margin.
        let inset = BannerView.outerInset
        let origin = NSPoint(x: frame.maxX - size.width - screenMargin + inset,
                             y: frame.maxY - size.height - screenMargin + inset)
        panel.setFrame(NSRect(origin: NSPoint(x: origin.x + 40, y: origin.y), size: size), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        if let sound { NSSound(named: sound)?.play() }
        scheduleAutoDismiss(after: visibleFor)
    }

    static func dismiss(animated: Bool) {
        cancelAutoDismiss()
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private static func scheduleAutoDismiss(after delay: TimeInterval) {
        cancelAutoDismiss()
        let work = DispatchWorkItem { dismiss(animated: true) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func cancelAutoDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }
}

struct BannerView: View {
    struct Badge {
        let symbol: String
        let color: Color
    }

    let title: String
    let message: String
    let badge: Badge
    var action: BannerWindow.Action?
    /// For screenshots, which can't hover.
    var alwaysShowAction = false
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    /// System notification banner metrics (macOS 26 rounds them more than earlier releases).
    static let width: CGFloat = 344
    static var cornerRadius: CGFloat {
        if #available(macOS 26, *) { 24 } else { 18 }
    }
    /// Transparent room around the card so the close button and shadow aren't clipped.
    static let outerInset: CGFloat = 10

    @State private var hovering = false

    var body: some View {
        card
            .overlay(alignment: .topLeading) {
                if hovering {
                    closeButton
                        .offset(x: -7, y: -7)
                        .transition(.opacity)
                }
            }
            .padding(Self.outerInset)
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) { hovering = inside }
                onHover(inside)
            }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Like system notifications, the action replaces the timestamp while hovered.
                    if let action, hovering || alwaysShowAction {
                        ActionPill(title: action.title, perform: action.perform)
                            .transition(.opacity)
                    } else {
                        Text("now")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.width, alignment: .leading)
        .modifier(NotificationBackground(cornerRadius: Self.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismiss")
    }

    private var icon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "headphones")
                .font(.system(size: 19))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.08)))
            // Pill sized to the glyph, sitting on the tile's corner clear of the ear cups.
            Image(systemName: badge.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badge.color)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .background(Capsule().fill(.background))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .fixedSize()
                .offset(x: 10, y: 7)
        }
        .padding(.trailing, 4)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .modifier(CloseButtonBackground())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// Liquid Glass on macOS 26, like system notifications; frosted material before that.
private struct NotificationBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
    }
}

private struct CloseButtonBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
    }
}

/// Compact grey pill, the way macOS draws a notification's action button.
private struct ActionPill: View {
    let title: String
    let perform: () -> Void
    @State private var pressed = false

    var body: some View {
        Button(action: perform) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(pressed ? 0.2 : 0.1)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onLongPressGesture(minimumDuration: 0, pressing: { pressed = $0 }, perform: {})
    }
}
