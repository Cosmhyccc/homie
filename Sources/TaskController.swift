import AppKit
import EventKit
import UserNotifications

/// Persistent OS-backed tasks; no dependency on a live voice conversation.
final class TaskController: NSObject, UNUserNotificationCenterDelegate {
    private let store = EKEventStore()
    private let notifications = UNUserNotificationCenter.current()
    static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "name": name, "description": description,
         "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false], "strict": true]
    }
    static let string: [String: Any] = ["type": "string"]
    static let tools: [[String: Any]] = [
        tool("create_reminder", "Save an Apple Reminders to-do. due_at is an ISO8601 timestamp with timezone, or empty for no deadline. list_name empty uses default list. Ask if time is ambiguous. Never repeat after success.", ["title": string, "due_at": string, "list_name": string]),
        tool("read_reminders", "Read incomplete Apple Reminders tasks; empty list_name means all lists. Returns IDs needed to complete tasks.", ["list_name": string]),
        tool("complete_reminder", "Mark the exact user-requested reminder complete using an ID from read_reminders. Do not guess IDs.", ["id": string]),
        tool("schedule_alert", "Schedule a Pixie timer or one-time alarm with a macOS notification sound. For timers use seconds 1..604800 and empty at. For clock alarms use ISO8601 timestamp with timezone in at and seconds 0. Not a wake-from-sleep alarm; delivery/sound depend on macOS notifications and Focus. Ask if time is ambiguous.", ["title": string, "seconds": ["type": "integer", "minimum": 0, "maximum": 604800], "at": string]),
        tool("list_alerts", "List pending Pixie timers and alarms with IDs and due times.", [:]),
        tool("cancel_alert", "Cancel only the user-requested Pixie timer/alarm using an ID from list_alerts.", ["id": string])
    ]
    override init() { super.init(); notifications.delegate = self }
    static func owns(_ name: String) -> Bool { tools.contains { $0["name"] as? String == name } }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    static func date(_ value: String) throws -> Date {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: value) else { throw MusicFailure.message("Use a full ISO8601 date with timezone.") }
        return date
    }
    static func alertDate(_ args: [String: Any], now: Date = Date()) throws -> Date {
        let seconds = try DesktopController.integer(args, "seconds", range: 0...604800)
        guard let at = args["at"] as? String, (seconds > 0) == at.isEmpty else { throw MusicFailure.message("Provide either a timer duration or an alarm date, not both.") }
        let due = at.isEmpty ? now.addingTimeInterval(Double(seconds)) : try date(at)
        guard due > now, due.timeIntervalSince(now) <= 366 * 86400 else { throw MusicFailure.message("Choose a future time within the next year.") }
        return due
    }
    private func title(_ args: [String: Any]) throws -> String {
        guard let value = args["title"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 200 else { throw MusicFailure.message("Give this a short title.") }
        return value
    }
    @MainActor private func reminderAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) != .fullAccess {
            guard try await store.requestFullAccessToReminders() else { throw MusicFailure.message("Allow Pixie access to Reminders in System Settings.") }
        }
        store.reset()
    }
    @MainActor func execute(name: String, arguments a: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do { completion(try await perform(name, a)) }
            catch { completion(["status": "error", "message": error.localizedDescription]) }
        }
    }
    @MainActor private func perform(_ name: String, _ a: [String: Any]) async throws -> [String: Any] {
        let iso = ISO8601DateFormatter()
        if ["create_reminder", "read_reminders", "complete_reminder"].contains(name) {
            try await reminderAccess()
            let lists = store.calendars(for: .reminder)
            let listName = a["list_name"] as? String ?? ""
            let matches = lists.filter { $0.title.caseInsensitiveCompare(listName) == .orderedSame }
            if !listName.isEmpty && matches.count != 1 { throw MusicFailure.message("List name is missing or ambiguous. Available lists: " + lists.map(\.title).joined(separator: ", ")) }
            if name == "create_reminder" {
                let text = try title(a)
                guard let raw = a["due_at"] as? String else { throw MusicFailure.message("Missing due date.") }
                let due = raw.isEmpty ? nil : try Self.date(raw)
                guard let calendar = listName.isEmpty ? store.defaultCalendarForNewReminders() : matches.first, calendar.allowsContentModifications else { throw MusicFailure.message("No writable Reminders list is available.") }
                let reminder = EKReminder(eventStore: store)
                reminder.title = text; reminder.calendar = calendar
                if let due {
                    var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: due)
                    components.timeZone = .current
                    reminder.dueDateComponents = components
                    reminder.addAlarm(EKAlarm(absoluteDate: due))
                }
                try store.save(reminder, commit: true)
                return ["status": "created", "id": reminder.calendarItemIdentifier, "title": text, "list": calendar.title, "due_at": due.map { iso.string(from: $0) } ?? ""]
            }
            if name == "complete_reminder" {
                guard let id = a["id"] as? String, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw MusicFailure.message("Read the reminders again to find that task.") }
                reminder.isCompleted = true
                try store.save(reminder, commit: true)
                return ["status": "completed", "title": reminder.title ?? "Task"]
            }
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: listName.isEmpty ? nil : matches)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
            }
            let sorted = reminders.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
            return ["status": "read", "total": sorted.count, "truncated": sorted.count > 100, "tasks": sorted.prefix(100).map { ["id": $0.calendarItemIdentifier, "title": $0.title ?? "Task", "list": $0.calendar.title, "due_at": $0.dueDateComponents?.date.map { iso.string(from: $0) } ?? ""] }]
        }
        if name == "schedule_alert" {
            let text = try title(a), due = try Self.alertDate(a)
            guard try await notifications.requestAuthorization(options: [.alert, .sound]) else { throw MusicFailure.message("Allow Pixie notifications in System Settings before setting an alarm.") }
            let content = UNMutableNotificationContent()
            content.userInfo = ["due_at": iso.string(from: due)]
            content.title = text; content.body = "Time’s up — Pixie"; content.sound = .default
            let id = "pixie.alert." + UUID().uuidString
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, due.timeIntervalSinceNow), repeats: false)
            try await notifications.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            return ["status": "scheduled", "id": id, "title": text, "due_at": iso.string(from: due), "delivery": "macOS notification with sound; does not wake a sleeping Mac; Focus and notification settings apply"]
        }
        let pending = await notifications.pendingNotificationRequests().filter { $0.identifier.hasPrefix("pixie.alert.") }
        if name == "list_alerts" {
            return ["status": "read", "alerts": pending.map { ["id": $0.identifier, "title": $0.content.title, "due_at": $0.content.userInfo["due_at"] as? String ?? ""] }]
        }
        if name == "cancel_alert", let id = a["id"] as? String, pending.contains(where: { $0.identifier == id }) {
            notifications.removePendingNotificationRequests(withIdentifiers: [id])
            return ["status": "cancelled", "id": id]
        }
        throw MusicFailure.message("That pending alert was not found.")
    }
}
