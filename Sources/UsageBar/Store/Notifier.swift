import Foundation
import UserNotifications

/// Local notifications for threshold crossings and window resets. Only available when
/// running from a real .app bundle (UNUserNotificationCenter requires one).
@MainActor
final class Notifier {
    private var authorized = false
    private let thresholds: [Double] = [75, 90, 100]

    var available: Bool { AppSettings.isBundled }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    func evaluate(old: UsageSnapshot?, new: UsageSnapshot, settings: AppSettings) {
        guard available, settings.notificationsEnabled, let old else { return }
        let name = new.provider.displayName
        for w in new.windows where w.hasLimit {
            guard let prev = old.windows.first(where: { $0.id == w.id }) else { continue }
            if settings.notifyThresholds {
                for t in thresholds where prev.percent < t && w.percent >= t {
                    let title = t >= 100 ? "\(name) \(w.label) limit reached" : "\(name) \(w.label) at \(Int(t))%"
                    var body = "Usage is at \(Format.percent(w.percent))."
                    if let c = Format.countdown(to: w.resetsAt) { body += " Resets in \(c)." }
                    send(id: "\(new.provider.rawValue)-\(w.id)-\(Int(t))", title: title, body: body)
                }
            }
            if settings.notifyResets, prev.percent >= 25, w.percent <= 5 {
                send(id: "\(new.provider.rawValue)-\(w.id)-reset",
                     title: "\(name) \(w.label) window reset",
                     body: "Usage dropped from \(Format.percent(prev.percent)) to \(Format.percent(w.percent)). You're good to go.")
            }
        }
    }

    func send(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: id + "-\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
