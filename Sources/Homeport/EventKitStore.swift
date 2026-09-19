import EventKit
import Foundation

/// Owns the single shared EKEventStore and centralizes permission handling.
final class EventKitStore {
    static let shared = EventKitStore()
    let store = EKEventStore()

    private init() {}

    /// Ensure full access to the given entity type, requesting it if needed.
    ///
    /// Defensive against the macOS 14.2.x bug where `requestFullAccess…` calls
    /// back with `granted = false, error = nil` even though access WAS granted:
    /// we never treat a single false/nil callback as authoritative. Instead we
    /// re-read `EKEventStore.authorizationStatus(for:)` and trust that.
    func ensureAccess(_ entity: EKEntityType) throws {
        if EKEventStore.authorizationStatus(for: entity) == .fullAccess { return }

        let semaphore = DispatchSemaphore(value: 0)
        var callbackGranted = false
        var callbackError: Error?
        let completion: EKEventStoreRequestAccessCompletionHandler = { granted, error in
            callbackGranted = granted
            callbackError = error
            semaphore.signal()
        }

        switch entity {
        case .event:
            store.requestFullAccessToEvents(completion: completion)
        case .reminder:
            store.requestFullAccessToReminders(completion: completion)
        @unknown default:
            store.requestFullAccessToEvents(completion: completion)
        }
        _ = semaphore.wait(timeout: .now() + 60)

        // Authoritative re-check — this is the line that neutralizes the 14.2 bug.
        let status = EKEventStore.authorizationStatus(for: entity)
        if status == .fullAccess { return }
        if callbackGranted && callbackError == nil { return }

        throw EventKitStore.accessError(entity: entity, status: status)
    }

    static func accessError(entity: EKEntityType, status: EKAuthorizationStatus) -> ToolError {
        let name = entity == .event ? "Calendar" : "Reminders"
        let reset = entity == .event ? "Calendar" : "Reminders"
        let statusText: String
        switch status {
        case .notDetermined: statusText = "notDetermined"
        case .restricted: statusText = "restricted (blocked by a profile/parental control)"
        case .denied: statusText = "denied"
        case .fullAccess: statusText = "fullAccess"
        case .writeOnly: statusText = "writeOnly (need full access to read)"
        @unknown default: statusText = "unknown(\(status.rawValue))"
        }
        return ToolError("""
        \(name) access is not fully granted (status: \(statusText)). \
        Grant it in System Settings ▸ Privacy & Security ▸ \(name) and enable "Apple MCP Bridge" (or "Homeport"). \
        If it is missing from that list or stuck, reset and retry: `tccutil reset \(reset)` then trigger this tool again.
        """)
    }

    // MARK: - Calendar lookups

    func reminderCalendars() -> [EKCalendar] { store.calendars(for: .reminder) }
    func eventCalendars() -> [EKCalendar] { store.calendars(for: .event) }

    /// Resolve a reminder list from an explicit id or a display name.
    func reminderList(id: String?, name: String?) -> EKCalendar? {
        if let id, let cal = store.calendar(withIdentifier: id), cal.allowedEntityTypes.contains(.reminder) {
            return cal
        }
        if let name {
            return reminderCalendars().first { $0.title == name }
        }
        return nil
    }

    /// Resolve an event calendar from an explicit id or a display name.
    func eventCalendar(id: String?, name: String?) -> EKCalendar? {
        if let id, let cal = store.calendar(withIdentifier: id), cal.allowedEntityTypes.contains(.event) {
            return cal
        }
        if let name {
            return eventCalendars().first { $0.title == name }
        }
        return nil
    }

    func reminder(byId id: String) throws -> EKReminder {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw ToolError("Reminder not found for id: \(id)")
        }
        return item
    }

    func event(byId id: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw ToolError("Event not found for id: \(id)")
        }
        return event
    }

    /// Resolve the specific occurrence of a recurring series that starts on the
    /// given calendar day. Occurrences of one series share an `eventIdentifier`;
    /// `store.event(withIdentifier:)` only returns the next one, so to
    /// edit/delete "this occurrence and all future ones" from a chosen date we
    /// must fetch that occurrence via a date-ranged predicate.
    func occurrence(ofSeries id: String, on date: Date) throws -> EKEvent {
        let base = try event(byId: id)
        var calendar = Calendar.current
        calendar.timeZone = base.timeZone ?? TimeZone.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd,
                                                 calendars: base.calendar.map { [$0] })
        let matches = store.events(matching: predicate).filter { $0.eventIdentifier == id }
        guard let occurrence = matches.first else {
            throw ToolError("No occurrence of this series was found on \(DateParse.isoString(date)). " +
                "Pass an occurrenceDate that lands on an actual occurrence of the series.")
        }
        return occurrence
    }

    /// Synchronous wrapper over the async reminder fetch.
    func fetchReminders(_ predicate: NSPredicate) -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return result
    }
}
