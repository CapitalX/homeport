import EventKit
import Foundation

// MARK: - Date parsing / formatting

enum DateParse {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let localDateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "yyyy-MM-dd'T'HH:mm(:ss)" with NO timezone offset.
    ///
    /// ISO8601DateFormatter's .withInternetDateTime requires an offset, so
    /// "2026-09-07T09:00:00" -- the form a model emits most naturally -- was
    /// rejected outright while the space-separated "2026-09-07 09:00" worked.
    /// Interpreted as local time, matching the space-separated variant.
    private static let localDateTimeT: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"].map {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = $0
        return f
    }

    /// Parse an ISO 8601 datetime (with or without offset), "yyyy-MM-dd HH:mm",
    /// or "yyyy-MM-dd" (local).
    static func date(_ string: String) -> Date? {
        let s = string.trimmingCharacters(in: .whitespaces)
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        for f in localDateTimeT { if let d = f.date(from: s) { return d } }
        if let d = localDateTime.date(from: s) { return d }
        if let d = localDateOnly.date(from: s) { return d }
        return nil
    }

    /// True when the string carries no time component (a bare calendar day).
    static func isDateOnly(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespaces)
        return !s.contains("T") && !s.contains(":") && localDateOnly.date(from: s) != nil
    }

    static func isoString(_ date: Date) -> String { iso.string(from: date) }

    private static let isoLocal: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    /// ISO 8601 in the local time zone (keeps the offset, e.g. `+02:00`), so a
    /// value like an inclusive end-of-day `until` reads as the intended date
    /// rather than a UTC-shifted next-day instant.
    static func localISOString(_ date: Date) -> String { isoLocal.string(from: date) }

    /// Build DateComponents for a reminder due date. If the input has no time,
    /// only day-granularity components are set (an all-day due date).
    static func dueComponents(_ string: String) -> DateComponents? {
        guard let date = date(string) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        if isDateOnly(string) {
            return calendar.dateComponents([.year, .month, .day], from: date)
        }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}

// MARK: - Priority

enum Priority {
    /// Map a string ("none"/"high"/"medium"/"low") or numeric string to the
    /// EventKit 0/1/5/9 scale.
    static func fromInput(_ value: Any?) -> Int? {
        if let i = value as? Int { return clamp(i) }
        if let n = value as? NSNumber { return clamp(n.intValue) }
        guard let s = (value as? String)?.lowercased() else { return nil }
        switch s {
        case "none", "0": return 0
        case "high": return 1
        case "medium", "med": return 5
        case "low": return 9
        default: return Int(s).map(clamp)
        }
    }

    private static func clamp(_ i: Int) -> Int { max(0, min(9, i)) }

    static func label(_ priority: Int) -> String {
        switch priority {
        case 0: return "none"
        case 1...4: return "high"
        case 5: return "medium"
        case 6...9: return "low"
        default: return "none"
        }
    }
}

// MARK: - Recurrence

enum Recurrence {
    /// Every field the mapper understands. Anything outside this set is an
    /// error, so unsupported input is never silently accepted and discarded.
    static let allowedKeys: Set<String> = [
        "frequency", "interval",
        "until", "count", "end",            // end specifiers (`end` object is legacy)
        "daysOfWeek", "daysOfMonth", "monthsOfYear", "setPositions"
    ]

    static func rule(from obj: JSONObject) throws -> EKRecurrenceRule {
        // Reject unknown fields instead of dropping them silently.
        let unknown = obj.keys.filter { !allowedKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw ToolError("Unsupported recurrence field(s): [\(unknown.joined(separator: ", "))]. " +
                "Supported: frequency, interval, until, count, daysOfWeek, daysOfMonth, monthsOfYear, setPositions.")
        }

        let freqString = (obj.string("frequency") ?? "").lowercased()
        let frequency: EKRecurrenceFrequency
        switch freqString {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default:
            throw ToolError("recurrence.frequency must be one of: daily, weekly, monthly, yearly")
        }

        let interval = max(1, obj.int("interval") ?? 1)
        let end = try recurrenceEnd(from: obj)
        let daysOfWeek = try daysOfWeek(from: obj)

        let daysOfMonth = obj.intArray("daysOfMonth")?.map { NSNumber(value: $0) }
        let monthsOfYear = obj.intArray("monthsOfYear")?.map { NSNumber(value: $0) }
        let setPositions = obj.intArray("setPositions")?.map { NSNumber(value: $0) }

        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfWeek,
            daysOfTheMonth: daysOfMonth,
            monthsOfTheYear: monthsOfYear,
            weeksOfTheYear: nil,
            daysOfTheYear: nil,
            setPositions: setPositions,
            end: end
        )
    }

    /// Build the `EKRecurrenceEnd` from top-level `until`/`count` (preferred) or
    /// a legacy `end: {date|count}` object. Only one end specifier is allowed.
    static func recurrenceEnd(from obj: JSONObject) throws -> EKRecurrenceEnd? {
        var specifiers: [String] = []
        var end: EKRecurrenceEnd?

        if let untilStr = obj.string("until") {
            guard let date = DateParse.date(untilStr) else {
                throw ToolError("Could not parse recurrence.until: \(untilStr). Use ISO 8601 or yyyy-MM-dd.")
            }
            // A date-only `until` (no time) should INCLUDE occurrences on that
            // day. EKRecurrenceEnd(end:) is an exact-instant, inclusive
            // boundary, so a bare date resolves to 00:00 and would drop a
            // same-day occurrence. Extend it to the end of that day.
            let endDate: Date
            if DateParse.isDateOnly(untilStr) {
                var calendar = Calendar.current
                calendar.timeZone = TimeZone.current
                let dayStart = calendar.startOfDay(for: date)
                endDate = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart) ?? date
            } else {
                endDate = date
            }
            end = EKRecurrenceEnd(end: endDate)
            specifiers.append("until")
        }
        if let count = obj.int("count") {
            guard count > 0 else { throw ToolError("recurrence.count must be a positive integer.") }
            end = EKRecurrenceEnd(occurrenceCount: count)
            specifiers.append("count")
        }
        if let endObj = obj.object("end") {
            if let count = endObj.int("count") {
                guard count > 0 else { throw ToolError("recurrence.end.count must be a positive integer.") }
                end = EKRecurrenceEnd(occurrenceCount: count)
                specifiers.append("end.count")
            } else if let dateStr = endObj.string("date"), let date = DateParse.date(dateStr) {
                end = EKRecurrenceEnd(end: date)
                specifiers.append("end.date")
            } else {
                throw ToolError("recurrence.end must be {\"count\": N} or {\"date\": \"ISO\"}.")
            }
        }
        if specifiers.count > 1 {
            throw ToolError("Conflicting recurrence end specifiers: [\(specifiers.joined(separator: ", "))]. " +
                "Provide only one of `until` or `count`.")
        }
        return end
    }

    /// Parse `daysOfWeek` (["MO","WE",...]), erroring on a malformed value
    /// rather than dropping it.
    static func daysOfWeek(from obj: JSONObject) throws -> [EKRecurrenceDayOfWeek]? {
        guard obj["daysOfWeek"] != nil else { return nil }
        guard let names = obj.stringArray("daysOfWeek") else {
            throw ToolError("daysOfWeek must be an array of weekday codes, e.g. [\"MO\",\"WE\",\"FR\"].")
        }
        if names.isEmpty { return nil }
        var parsed: [EKRecurrenceDayOfWeek] = []
        for name in names {
            guard let wd = weekday(name) else {
                throw ToolError("Invalid daysOfWeek value: \(name). Use SU,MO,TU,WE,TH,FR,SA (or full weekday names).")
            }
            parsed.append(EKRecurrenceDayOfWeek(wd))
        }
        return parsed
    }

    static func weekday(_ s: String) -> EKWeekday? {
        switch s.uppercased() {
        case "SU", "SUN", "SUNDAY": return .sunday
        case "MO", "MON", "MONDAY": return .monday
        case "TU", "TUE", "TUESDAY": return .tuesday
        case "WE", "WED", "WEDNESDAY": return .wednesday
        case "TH", "THU", "THURSDAY": return .thursday
        case "FR", "FRI", "FRIDAY": return .friday
        case "SA", "SAT", "SATURDAY": return .saturday
        default: return nil
        }
    }

    static func weekdayName(_ w: EKWeekday) -> String {
        switch w {
        case .sunday: return "SU"
        case .monday: return "MO"
        case .tuesday: return "TU"
        case .wednesday: return "WE"
        case .thursday: return "TH"
        case .friday: return "FR"
        case .saturday: return "SA"
        @unknown default: return "?"
        }
    }

    static func json(_ rule: EKRecurrenceRule) -> JSONObject {
        var out: JSONObject = ["interval": rule.interval]
        switch rule.frequency {
        case .daily: out["frequency"] = "daily"
        case .weekly: out["frequency"] = "weekly"
        case .monthly: out["frequency"] = "monthly"
        case .yearly: out["frequency"] = "yearly"
        @unknown default: out["frequency"] = "unknown"
        }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            out["daysOfWeek"] = days.map { weekdayName($0.dayOfTheWeek) }
        }
        if let dom = rule.daysOfTheMonth, !dom.isEmpty { out["daysOfMonth"] = dom.map { $0.intValue } }
        if let moy = rule.monthsOfTheYear, !moy.isEmpty { out["monthsOfYear"] = moy.map { $0.intValue } }
        if let sp = rule.setPositions, !sp.isEmpty { out["setPositions"] = sp.map { $0.intValue } }
        // Echo the effective end so callers can verify what was actually stored.
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                out["count"] = end.occurrenceCount
            } else if let date = end.endDate {
                out["until"] = DateParse.localISOString(date)
            }
            out["unbounded"] = false
        } else {
            out["unbounded"] = true
        }
        return out
    }
}

// MARK: - Alarms

enum Alarms {
    static func build(from array: [Any]) -> [EKAlarm] {
        var alarms: [EKAlarm] = []
        for case let entry as JSONObject in array {
            if let offset = entry.double("relativeOffset") {
                alarms.append(EKAlarm(relativeOffset: offset))
            } else if let dateStr = entry.string("absoluteDate"), let date = DateParse.date(dateStr) {
                alarms.append(EKAlarm(absoluteDate: date))
            }
        }
        return alarms
    }

    static func json(_ alarms: [EKAlarm]) -> [JSONObject] {
        alarms.map { alarm in
            if let date = alarm.absoluteDate {
                return ["absoluteDate": DateParse.isoString(date)]
            }
            return ["relativeOffset": alarm.relativeOffset]
        }
    }
}

// MARK: - EventKit objects -> JSON

enum EKMapper {
    /// How to treat a reminder's `notes` field in a listing.
    ///
    /// Notes are unbounded free text and some apps park base64 images there --
    /// a single list with image-heavy notes can make up most of a response
    /// that no caller wanted. Listings should be able to opt out or ask for
    /// a preview without giving up the field entirely.
    enum NotesMode {
        case full
        case excluded
        case truncated(Int)
    }

    static func reminder(_ r: EKReminder, notes: NotesMode = .full) -> JSONObject {
        var o: JSONObject = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "list": r.calendar?.title ?? "",
            "listId": r.calendar?.calendarIdentifier ?? "",
            "completed": r.isCompleted,
            "priority": Priority.label(r.priority)
        ]
        if let raw = r.notes, !raw.isEmpty {
            switch notes {
            case .excluded:
                // Report the size so a caller knows something was there and can
                // re-query for it, rather than silently seeing no notes at all.
                o["notesLength"] = raw.count
            case .full:
                o["notes"] = raw
            case .truncated(let max):
                if raw.count > max {
                    o["notes"] = String(raw.prefix(max))
                    o["notesLength"] = raw.count
                    o["notesTruncated"] = true
                } else {
                    o["notes"] = raw
                }
            }
        }
        if let url = r.url { o["url"] = url.absoluteString }
        if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
            o["due"] = DateParse.isoString(date)
        }
        if let done = r.completionDate { o["completionDate"] = DateParse.isoString(done) }
        if let rules = r.recurrenceRules, let first = rules.first { o["recurrence"] = Recurrence.json(first) }
        if let alarms = r.alarms, !alarms.isEmpty { o["alarms"] = Alarms.json(alarms) }
        return o
    }

    static func event(_ e: EKEvent) -> JSONObject {
        var o: JSONObject = [
            "id": e.eventIdentifier ?? "",
            "title": e.title ?? "",
            "calendar": e.calendar?.title ?? "",
            "calendarId": e.calendar?.calendarIdentifier ?? "",
            "allDay": e.isAllDay
        ]
        if let start = e.startDate { o["start"] = DateParse.isoString(start) }
        if let end = e.endDate { o["end"] = DateParse.isoString(end) }
        if let location = e.location, !location.isEmpty { o["location"] = location }
        if let notes = e.notes, !notes.isEmpty { o["notes"] = notes }
        if let url = e.url { o["url"] = url.absoluteString }
        if let tz = e.timeZone { o["timeZone"] = tz.identifier }
        o["availability"] = availabilityLabel(e.availability)
        o["status"] = statusLabel(e.status)
        o["isRecurring"] = e.hasRecurrenceRules
        if let rules = e.recurrenceRules, let first = rules.first { o["recurrence"] = Recurrence.json(first) }
        if let alarms = e.alarms, !alarms.isEmpty { o["alarms"] = Alarms.json(alarms) }
        if let organizer = e.organizer { o["organizer"] = participant(organizer) }
        if let attendees = e.attendees, !attendees.isEmpty {
            o["attendees"] = attendees.map { participant($0) }
        }
        return o
    }

    static func calendar(_ c: EKCalendar) -> JSONObject {
        var o: JSONObject = [
            "id": c.calendarIdentifier,
            "title": c.title,
            "type": sourceTypeLabel(c.source?.sourceType),
            "source": c.source?.title ?? "",
            "allowsModify": c.allowsContentModifications,
            "isImmutable": c.isImmutable
        ]
        if let cg = c.cgColor { o["color"] = hexColor(cg) }
        return o
    }

    static func participant(_ p: EKParticipant) -> JSONObject {
        var o: JSONObject = [
            "name": p.name ?? "",
            "role": roleLabel(p.participantRole),
            "status": participantStatusLabel(p.participantStatus),
            "type": participantTypeLabel(p.participantType),
            "isCurrentUser": p.isCurrentUser
        ]
        // Email is exposed via a mailto: URL on EKParticipant.
        let url = p.url
        if url.scheme == "mailto" {
            o["email"] = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return o
    }

    // MARK: labels

    private static func availabilityLabel(_ a: EKEventAvailability) -> String {
        switch a {
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        case .notSupported: return "notSupported"
        @unknown default: return "unknown"
        }
    }

    private static func statusLabel(_ s: EKEventStatus) -> String {
        switch s {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    private static func sourceTypeLabel(_ t: EKSourceType?) -> String {
        switch t {
        case .some(.local): return "local"
        case .some(.exchange): return "exchange"
        case .some(.calDAV): return "calDAV/iCloud"
        case .some(.mobileMe): return "mobileMe"
        case .some(.subscribed): return "subscribed"
        case .some(.birthdays): return "birthdays"
        default: return "unknown"
        }
    }

    private static func roleLabel(_ r: EKParticipantRole) -> String {
        switch r {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        @unknown default: return "unknown"
        }
    }

    private static func participantStatusLabel(_ s: EKParticipantStatus) -> String {
        switch s {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "inProcess"
        @unknown default: return "unknown"
        }
    }

    private static func participantTypeLabel(_ t: EKParticipantType) -> String {
        switch t {
        case .unknown: return "unknown"
        case .person: return "person"
        case .room: return "room"
        case .resource: return "resource"
        case .group: return "group"
        @unknown default: return "unknown"
        }
    }

    private static func hexColor(_ cg: CGColor?) -> String {
        guard let comps = cg?.components, comps.count >= 3 else { return "" }
        let r = Int((comps[0] * 255).rounded())
        let g = Int((comps[1] * 255).rounded())
        let b = Int((comps[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// Add/remove alarms without destroying the ones already set.
///
/// The previous behavior for `alarms` was `x.alarms = nil` followed by a
/// rebuild, so "add a 10-minute reminder" silently deleted the existing 1-day
/// one -- the same failure class as contacts_update assigning whole arrays.
/// `setAlarms` still replaces, but only behind confirmReplace.
///
/// Alarms are matched by relative offset (or absolute date): EKAlarm has no
/// stable identity to compare on.
enum AlarmEdits {
    static func signature(_ alarm: EKAlarm) -> String {
        if let absolute = alarm.absoluteDate { return "abs:\(absolute.timeIntervalSince1970)" }
        return "rel:\(alarm.relativeOffset)"
    }

    /// Works for any EKCalendarItem, so events and reminders share one path.
    static func apply(to item: EKCalendarItem, _ args: JSONObject) throws {
        if let set = args.array("setAlarms") {
            guard args.bool("confirmReplace") == true else {
                throw ToolError(
                    "`setAlarms` discards every existing alarm. Pass confirmReplace: true if that "
                    + "is intended, or use `addAlarms` / `removeAlarms` to change individual "
                    + "alarms without touching the others.")
            }
            item.alarms = nil
            for alarm in Alarms.build(from: set) { item.addAlarm(alarm) }
            return
        }

        guard args.array("removeAlarms") != nil || args.array("addAlarms") != nil else { return }
        var current = item.alarms ?? []

        if let remove = args.array("removeAlarms") {
            let targets = Set(Alarms.build(from: remove).map(signature))
            current.removeAll { targets.contains(signature($0)) }
        }
        if let add = args.array("addAlarms") {
            let existing = Set(current.map(signature))
            for alarm in Alarms.build(from: add) where !existing.contains(signature(alarm)) {
                current.append(alarm)
            }
        }
        item.alarms = current.isEmpty ? nil : current
    }
}
