import Foundation
import os.log
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private static let categoryWithoutActionIdentifier = "ALARM_CATEGORY_NO_ACTION"
    private static let categoryWithActionIdentifierPrefix = "ALARM_CATEGORY_WITH_ACTION_"
    private static let notificationIdentifierPrefix = "ALARM_NOTIFICATION_"
    private static let backupNotificationIdentifierPrefix = "ALARM_BACKUP_NOTIFICATION_"
    private static let stopActionIdentifier = "ALARM_STOP_ACTION"
    private static let userInfoAlarmIdKey = "ALARM_ID"
    private static let userInfoIsBackupKey = "IS_BACKUP"
    private static let backupNotificationStartDelay: TimeInterval = 30 // 30 seconds after alarm time
    private static let backupNotificationInterval: TimeInterval = 3 // 3 seconds between backup notifications
    private static let maxBackupNotifications = 10

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

        let content = UNMutableNotificationContent()
        content.title = notificationSettings.title
        content.body = notificationSettings.body
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.userInfo = [NotificationManager.userInfoAlarmIdKey: id]

        if let stopButtonTitle = notificationSettings.stopButton {
            let categoryIdentifier = "\(NotificationManager.categoryWithActionIdentifierPrefix)\(stopButtonTitle)"
            await registerCategoryIfNeeded(forActionTitle: stopButtonTitle)
            content.categoryIdentifier = categoryIdentifier
        } else {
            content.categoryIdentifier = NotificationManager.categoryWithoutActionIdentifier
        }

        let request = UNNotificationRequest(identifier: "\(NotificationManager.notificationIdentifierPrefix)\(id)", content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            os_log(.debug, log: NotificationManager.logger, "Notification shown for alarm ID=%d", id)
        } catch {
            os_log(.error, log: NotificationManager.logger, "Error when showing alarm ID=%d notification: %@", id, error.localizedDescription)
        }
    }

    func scheduleAlarmNotification(id: Int, notificationSettings: NotificationSettings, alarmTime: Date) async {
        // Schedule the main alarm notification
        let content = UNMutableNotificationContent()
        content.title = notificationSettings.title
        content.body = notificationSettings.body
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.userInfo = [NotificationManager.userInfoAlarmIdKey: id]

        if let stopButtonTitle = notificationSettings.stopButton {
            let categoryIdentifier = "\(NotificationManager.categoryWithActionIdentifierPrefix)\(stopButtonTitle)"
            await registerCategoryIfNeeded(forActionTitle: stopButtonTitle)
            content.categoryIdentifier = categoryIdentifier
        } else {
            content.categoryIdentifier = NotificationManager.categoryWithoutActionIdentifier
        }

        // Create date components for the alarm time
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alarmTime)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(identifier: "\(NotificationManager.notificationIdentifierPrefix)\(id)", content: content, trigger: trigger)
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            os_log(.debug, log: NotificationManager.logger, "Alarm notification scheduled for ID=%d at %{public}@", id, alarmTime.description)
            
            // Schedule backup notifications
            await scheduleBackupNotifications(id: id, notificationSettings: notificationSettings, alarmTime: alarmTime)
        } catch {
            os_log(.error, log: NotificationManager.logger, "Error when scheduling alarm ID=%d notification: %@", id, error.localizedDescription)
        }
    }

    private func scheduleBackupNotifications(id: Int, notificationSettings: NotificationSettings, alarmTime: Date) async {
        let content = UNMutableNotificationContent()
        content.title = notificationSettings.title
        content.body = notificationSettings.body
        content.sound = nil
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        content.userInfo = [
            NotificationManager.userInfoAlarmIdKey: id,
            NotificationManager.userInfoIsBackupKey: true
        ]
        content.categoryIdentifier = NotificationManager.categoryWithoutActionIdentifier

        // Calculate the start time for backup notifications (30 seconds after alarm time)
        let backupStartTime = alarmTime.addingTimeInterval(NotificationManager.backupNotificationStartDelay)
        
        for i in 0..<NotificationManager.maxBackupNotifications {
            let backupTime = backupStartTime.addingTimeInterval(NotificationManager.backupNotificationInterval * Double(i))
            
            // Create date components for the backup notification time
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: backupTime)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            
            let request = UNNotificationRequest(
                identifier: "\(NotificationManager.backupNotificationIdentifierPrefix)\(id)_\(i)",
                content: content,
                trigger: trigger
            )
            
            do {
                try await UNUserNotificationCenter.current().add(request)
                os_log(.debug, log: NotificationManager.logger, "Backup notification %d scheduled for alarm ID=%d at %{public}@", i, id, backupTime.description)
            } catch {
                os_log(.error, log: NotificationManager.logger, "Error when scheduling backup notification %d for alarm ID=%d: %@", i, id, error.localizedDescription)
            }
        }
    }

    func cancelNotification(id: Int) {
        let notificationIdentifier = "\(NotificationManager.notificationIdentifierPrefix)\(id)"
        var identifiersToCancel = [notificationIdentifier]
        
        // Add backup notification identifiers
        for i in 0..<NotificationManager.maxBackupNotifications {
            identifiersToCancel.append("\(NotificationManager.backupNotificationIdentifierPrefix)\(id)_\(i)")
        }
        
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiersToCancel)
        os_log(.debug, log: NotificationManager.logger, "Cancelled notifications for alarm ID=%d", id)
    }

    func dismissNotification(id: Int) {
        let notificationIdentifier = "\(NotificationManager.notificationIdentifierPrefix)\(id)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
        os_log(.debug, log: NotificationManager.logger, "Dismissed notification: %@", notificationIdentifier)
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

    private func isBackupNotification(_ content: UNNotificationContent) -> Bool {
        return content.userInfo[NotificationManager.userInfoIsBackupKey] as? Bool == true
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
        completionHandler([.badge, .sound, .alert])
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