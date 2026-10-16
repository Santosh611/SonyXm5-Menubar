import AppKit
import SwiftUI

/// Notification-style banner in the top-right corner, sized like a macOS notification.
/// Needs no permissions. Dismisses after a few seconds (paused while hovered),
/// via the hover close button, or when clicked.
enum BannerWindow {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    /// Gap between the banner and the screen edges, matching system notifications.
    private static let screenMargin: CGFloat = 10
    private static let visibleFor: TimeInterval = 8
    private static let resumeAfterHover: TimeInterval = 4

    static func show(title: String, body: String, critical: Bool) {
        dismiss(animated: false)

        let hosting = NSHostingView(rootView: BannerView(
            title: title, message: body, critical: critical,
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

        NSSound(named: critical ? "Funk" : "Tink")?.play()
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
    let title: String
    let message: String
    let critical: Bool
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    /// System notification banner metrics.
    static let width: CGFloat = 344
    static let cornerRadius: CGFloat = 18
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
                    Text("now")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
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
            Image(systemName: critical ? "battery.0percent" : "battery.25percent")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(critical ? Color.red : Color.orange)
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
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
