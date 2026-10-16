import Foundation
import UserNotifications

/// Decides when to warn about low battery: once per threshold per discharge.
/// A threshold re-arms when the headset charges or climbs back above it (with hysteresis).
struct LowBatteryTracker {
    enum Level: Int, CaseIterable {
        case critical = 10
        case low = 20
    }

    static let menuBarThreshold = 20
    private static let hysteresis = 5

    private var fired: Set<Level> = []

    /// Returns the alert to show for this reading, if any.
    mutating func update(level: Int, charging: Bool) -> Level? {
        if charging {
            fired.removeAll()
            return nil
        }
        for threshold in Level.allCases where level > threshold.rawValue + Self.hysteresis {
            fired.remove(threshold)
        }
        // Most severe first; firing it also covers the milder threshold.
        guard let crossed = Level.allCases.first(where: { level <= $0.rawValue }),
              !fired.contains(crossed) else { return nil }
        for threshold in Level.allCases where threshold.rawValue >= crossed.rawValue {
            fired.insert(threshold)
        }
        return crossed
    }
}

/// Posts a system notification when allowed; otherwise (e.g. ad-hoc signed builds,
/// which macOS won't register for notifications) shows SonyBar's own banner.
enum BatteryNotifier {
    static func post(_ level: LowBatteryTracker.Level, battery: Int, deviceName: String) {
        let title: String
        let body: String
        switch level {
        case .low:
            title = "\(deviceName) battery low"
            body = "\(battery)% remaining. Charge soon."
        case .critical:
            title = "\(deviceName) battery critical"
            body = "\(battery)% remaining. Charge now."
        }
        let critical = level == .critical

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.debug("System notifications unavailable (\(error?.localizedDescription ?? "denied")); using banner")
                DispatchQueue.main.async {
                    BannerWindow.show(title: title, body: body, critical: critical)
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if critical { content.sound = .default }
            center.add(UNNotificationRequest(identifier: "battery-low", content: content, trigger: nil))
        }
    }
}
