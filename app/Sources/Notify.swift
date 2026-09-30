import Foundation
import AppKit
import UserNotifications

/// macOS notifications: session about to expire, VPN dropped, update available. One optional action
/// ("Reconnect now") is wired back to the app. Silently disabled when the app is not run from a bundle
/// (UNUserNotificationCenter needs one) or the user declined notifications.
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()
    static let reconnectAction = "atrain.reconnect"
    static let categoryVPN = "atrain.vpn"
    var onReconnect: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    private var available = false

    func setup() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reconnect = UNNotificationAction(identifier: Notify.reconnectAction, title: "Reconnect now", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Notify.categoryVPN, actions: [reconnect], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in self?.available = granted }
    }

    func post(id: String, title: String, body: String, reconnectAction: Bool = false, update: Bool = false) {
        guard available else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        if reconnectAction { c.categoryIdentifier = Notify.categoryVPN }
        if update { c.userInfo = ["update": true] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])                 // show even while A-Train is frontmost
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Notify.reconnectAction { onReconnect?() }
        else if response.notification.request.content.userInfo["update"] != nil { onOpenUpdate?() }
        completionHandler()
    }
}
