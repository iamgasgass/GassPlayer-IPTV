import Foundation
import UserNotifications

final class ReminderService {
    static let shared = ReminderService()

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func scheduleReminder(for program: EPGProgram, minutesBefore: Int = 5) {
        let content = UNMutableNotificationContent()
        content.title = "Sta per iniziare"
        content.body = program.title
        content.sound = .default

        let triggerDate = program.start.addingTimeInterval(-Double(minutesBefore * 60))
        guard triggerDate > Date() else { return }
        let interval = triggerDate.timeIntervalSinceNow
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: program.id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelReminder(programId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [programId])
    }
}
