import Foundation
import UIKit
import Security
import UserNotifications
import TessereCore

/// Tactile feedback.
@MainActor
enum Haptics {
    static var enabled = true
    static func light() { if enabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    static func soft() { if enabled { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7) } }
    static func medium() { if enabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    static func success() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func warning() { if enabled { UINotificationFeedbackGenerator().notificationOccurred(.warning) } }
    static func selection() { if enabled { UISelectionFeedbackGenerator().selectionChanged() } }
}

/// Max brightness and screen always on while a code is shown; the previous
/// brightness is restored when the code closes (or the app goes away).
@MainActor
enum ScreenBoost {
    private static var saved: CGFloat?
    private static var users = 0
    private static var wantsBrightness = false

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static func begin(maxBrightness: Bool) {
        users += 1
        wantsBrightness = wantsBrightness || maxBrightness
        UIApplication.shared.isIdleTimerDisabled = true
        if maxBrightness { raise() }
    }

    static func end() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        restore()
        wantsBrightness = false
    }

    /// App going to background: give the brightness back.
    static func suspend() { restore() }

    /// Back in foreground with a code still open.
    static func resume() {
        guard users > 0 else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        if wantsBrightness { raise() }
    }

    private static func raise() {
        guard let s = screen else { return }
        if saved == nil { saved = s.brightness }
        s.brightness = 1.0
    }

    private static func restore() {
        guard let v = saved else { return }
        screen?.brightness = v
        saved = nil
    }
}

/// Keeps the app alive a few seconds while saving in the background.
@MainActor
enum BackgroundWork {
    private final class Token {
        var id: UIBackgroundTaskIdentifier = .invalid
    }

    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        Task { @MainActor in
            await work()
            if token.id != .invalid {
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
    }
}

/// Local notifications: expiry reminders and "you are near the shop".
enum Notifier {
    static let nearbyPrefix = "tessere.nearby."

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func isAuthorized() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional || s == .ephemeral
    }

    static func rescheduleExpiry(_ reminders: [ExpiryReminder]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map(\.identifier).filter { $0.hasPrefix(ExpiryPlanner.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard !reminders.isEmpty, await isAuthorized() else { return }
        for r in reminders.prefix(40) {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = ["cardID": r.cardID.uuidString]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }

    /// "Sei vicino a …": at most once every 6 hours per card.
    static func nearby(card: Card) async {
        let key = "nearby.last.\(card.id.uuidString)"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 6 * 3600, await isAuthorized() else { return }
        UserDefaults.standard.set(now, forKey: key)
        let content = UNMutableNotificationContent()
        content.title = "Sei da \(card.storeName)?"
        content.body = "Tocca per mostrare \(card.kind == .loyalty ? "la tessera" : "la carta") alla cassa."
        content.sound = .default
        content.userInfo = ["cardID": card.id.uuidString]
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        let request = UNNotificationRequest(identifier: nearbyPrefix + card.id.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Opens the card when the user taps a notification.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["cardID"] as? String,
              let id = UUID(uuidString: s) else { return }
        await MainActor.run {
            AppModel.shared.open(cardID: id)
        }
    }
}

/// Generic-password Keychain items (device token, family key).
enum Keychain {
    private static let service = "com.garoth93.tessere"

    static func set(_ data: Data?, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ account: String) -> String? { get(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func setString(_ s: String?, for account: String) { set(s.map { Data($0.utf8) }, for: account) }
}
