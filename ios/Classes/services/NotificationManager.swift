import Foundation
import os.log
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private static let categoryWithoutActionIdentifier = "ALARM_CATEGORY_NO_ACTION"
    private static let categoryWithActionIdentifierPrefix = "ALARM_CATEGORY_WITH_ACTION_"
    private static let notificationIdentifierPrefix = "ALARM_NOTIFICATION_"
    private static let stopActionIdentifier = "ALARM_STOP_ACTION"
    private static let userInfoAlarmIdKey = "ALARM_ID"

    private static let logger = OSLog(subsystem: ALARM_BUNDLE, category: "NotificationManager")

    override private init() {
        super.init()
        Task {
            await self.setupDefaultNotificationCategory()
        }
    }

    private func setupDefaultNotificationCategory() async {
        let categoryWithoutAction = UNNotificationCategory(identifier: NotificationManager.categoryWithoutActionIdentifier, actions: [], intentIdentifiers: [], options: [])
        let existingCategories = await UNUserNotificationCenter.current().notificationCategories()
        var categories = existingCategories
        categories.insert(categoryWithoutAction)
        UNUserNotificationCenter.current().setNotificationCategories(categories)

        let categoryIdentifiers = categories.map { $0.identifier }.joined(separator: ", ")
        os_log(.debug, log: NotificationManager.logger, "Setup notification categories: %@", categoryIdentifiers)
    }

    private func registerCategoryIfNeeded(forActionTitle actionTitle: String) async {
        let categoryIdentifier = "\(NotificationManager.categoryWithActionIdentifierPrefix)\(actionTitle)"

        let existingCategories = await UNUserNotificationCenter.current().notificationCategories()
        if existingCategories.contains(where: { $0.identifier == categoryIdentifier }) {
            return
        }

        let action = UNNotificationAction(identifier: NotificationManager.stopActionIdentifier, title: actionTitle, options: [.foreground, .destructive])
        let category = UNNotificationCategory(identifier: categoryIdentifier, actions: [action], intentIdentifiers: [], options: [.hiddenPreviewsShowTitle, .hiddenPreviewsShowSubtitle])

        var categories = existingCategories
        categories.insert(category)
        UNUserNotificationCenter.current().setNotificationCategories(categories)

        // Without this delay the action does not register/appear.
        try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))

        let categoryIdentifiers = categories.map { $0.identifier }.joined(separator: ", ")
        os_log(.debug, log: NotificationManager.logger, "Added new category %@. Notification categories are now: %@", categoryIdentifier, categoryIdentifiers)
    }

    func showNotification(id: Int, notificationSettings: NotificationSettings) async {
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        guard notifSettings.authorizationStatus == .authorized else {
            os_log(.error, log: NotificationManager.logger, "Notification permission not granted. Cannot schedule alarm notification. Please request permission first.")
            return
        }

        // Schedule multiple notifications with exact times
        let notificationCount = 10 // Number of notifications to schedule
        let intervalBetweenNotifications: TimeInterval = 3.0 // 3 seconds between each notification
        let now = Date()
        
        for i in 0..<notificationCount {
            let content = UNMutableNotificationContent()
            content.title = notificationSettings.title
            content.body = notificationSettings.body
            content.sound = nil // We'll handle sound playback in the notification handler
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
            }
            content.userInfo = [
                NotificationManager.userInfoAlarmIdKey: id,
                "notificationIndex": i,
                "totalNotifications": notificationCount
            ]

            if let stopButtonTitle = notificationSettings.stopButton {
                let categoryIdentifier = "\(NotificationManager.categoryWithActionIdentifierPrefix)\(stopButtonTitle)"
                await registerCategoryIfNeeded(forActionTitle: stopButtonTitle)
                content.categoryIdentifier = categoryIdentifier
            } else {
                content.categoryIdentifier = NotificationManager.categoryWithoutActionIdentifier
            }

            // Calculate exact time for this notification
            let triggerDate = now.addingTimeInterval(intervalBetweenNotifications * Double(i))
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            
            let request = UNNotificationRequest(
                identifier: "\(NotificationManager.notificationIdentifierPrefix)\(id)_\(i)",
                content: content,
                trigger: trigger
            )
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .medium
                os_log(.debug, log: NotificationManager.logger, "Notification %d/%d scheduled for alarm ID=%d at %@", i + 1, notificationCount, id, dateFormatter.string(from: triggerDate))
            } catch {
                os_log(.error, log: NotificationManager.logger, "Error when scheduling notification %d/%d for alarm ID=%d: %@", i + 1, notificationCount, id, error.localizedDescription)
            }
        }
    }

    func cancelNotification(id: Int) {
        // Cancel all notifications for this alarm ID
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let identifiersToCancel = requests
                .filter { $0.identifier.starts(with: "\(NotificationManager.notificationIdentifierPrefix)\(id)_") }
                .map { $0.identifier }
            center.removePendingNotificationRequests(withIdentifiers: identifiersToCancel)
            os_log(.debug, log: NotificationManager.logger, "Cancelled %d notifications for alarm ID=%d", identifiersToCancel.count, id)
        }
    }

    func dismissNotification(id: Int) {
        // Dismiss all notifications for this alarm ID
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let identifiersToDismiss = notifications
                .filter { $0.request.identifier.starts(with: "\(NotificationManager.notificationIdentifierPrefix)\(id)_") }
                .map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: identifiersToDismiss)
            os_log(.debug, log: NotificationManager.logger, "Dismissed %d notifications for alarm ID=%d", identifiersToDismiss.count, id)
        }
    }

    /// Remove all notifications scheduled by this plugin.
    func removeAllNotifications() async {
        let center = UNUserNotificationCenter.current()

        let pendingNotifs = await center.pendingNotificationRequests()
        let toCancel = pendingNotifs.filter { isAlarmNotificationContent($0.content) }.map { $0.identifier }
        center.removePendingNotificationRequests(withIdentifiers: toCancel)
        os_log(.debug, log: NotificationManager.logger, "Cancelled %d notifications.", toCancel.count)

        let deliveredNotifs = await center.deliveredNotifications()
        let toDismiss = deliveredNotifs.filter { isAlarmNotification($0) }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: toDismiss)
        os_log(.debug, log: NotificationManager.logger, "Dismissed %d notifications.", toDismiss.count)
    }

    private func handleAction(withIdentifier identifier: String, for notification: UNNotification) {
        guard let id = notification.request.content.userInfo[NotificationManager.userInfoAlarmIdKey] as? Int else { return }

        switch identifier {
        case NotificationManager.stopActionIdentifier:
            os_log(.info, log: NotificationManager.logger, "Stop action triggered for notification: %@", notification.request.identifier)
            guard let alarmApi = SwiftAlarmPlugin.getApi() else {
                os_log(.error, log: NotificationManager.logger, "Alarm API not available.")
                return
            }
            alarmApi.stopAlarm(alarmId: Int64(id), completion: { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    os_log(.error, log: NotificationManager.logger, "Failed to stop alarm %d: %@", id, error.localizedDescription)
                }
            })
        default:
            break
        }
    }

    private func isAlarmNotification(_ notification: UNNotification) -> Bool {
        return isAlarmNotificationContent(notification.request.content)
    }

    private func isAlarmNotificationContent(_ content: UNNotificationContent) -> Bool {
        return content.userInfo[NotificationManager.userInfoAlarmIdKey] != nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if !isAlarmNotification(response.notification) {
            return
        }
        handleAction(withIdentifier: response.actionIdentifier, for: response.notification)
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if !isAlarmNotification(notification) {
            return
        }
        
        // Get notification info
        guard let userInfo = notification.request.content.userInfo as? [String: Any],
              let alarmId = userInfo[NotificationManager.userInfoAlarmIdKey] as? Int,
              let notificationIndex = userInfo["notificationIndex"] as? Int,
              let totalNotifications = userInfo["totalNotifications"] as? Int else {
            completionHandler([.badge, .sound, .alert])
            return
        }
        
        // Check if the app is running by checking if the alarm is ringing
        let isAppRunning = (try? SwiftAlarmPlugin.getApi()?.isRinging(alarmId: Int64(alarmId))) ?? false
        
        // Only reschedule notifications if the app is not running
        if !isAppRunning && notificationIndex == totalNotifications - 1 {
            Task {
                // Create NotificationSettings from current notification
                let notifSettings = NotificationSettings(
                    title: notification.request.content.title,
                    body: notification.request.content.body,
                    stopButton: notification.request.content.categoryIdentifier.hasPrefix(NotificationManager.categoryWithActionIdentifierPrefix) ? 
                                notification.request.content.categoryIdentifier.replacingOccurrences(of: NotificationManager.categoryWithActionIdentifierPrefix, with: "") : 
                                nil
                )
                
                // Reschedule notifications for the next batch
                await self.showNotification(id: alarmId, notificationSettings: notifSettings)
            }
        }
        
        // Only show notification UI if app is not running
        if isAppRunning {
            completionHandler([]) // Don't show notification UI when app is running
        } else {
            completionHandler([.badge, .sound, .alert])
        }
    }

    func sendWarningNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.userInfo = [NotificationManager.userInfoAlarmIdKey: 0]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notification on app kill immediate", content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            os_log(.debug, log: NotificationManager.logger, "Warning notification scheduled.")
        } catch {
            os_log(.error, log: NotificationManager.logger, "Error when scheduling warning notification: %@", error.localizedDescription)
        }
    }
}
