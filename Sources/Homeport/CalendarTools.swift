import EventKit
import Foundation

enum CalendarTools {
    private static var ek: EventKitStore { EventKitStore.shared }

    static let all: [Tool] = [
        calendarsTool,
        queryTool,
        createTool,
        updateTool,
        deleteTool
    ]

    // MARK: calendar_calendars

    private static let calendarsTool = Tool(
        name: "calendar_calendars",
        description: "List, create, or delete event calendars. action=list (default) returns all; action=create needs `name` (optional `color`); action=delete needs `calendarId` or `calendar` (name) AND `confirmDelete: true` — deleting a calendar deletes every event in it and syncs everywhere, so without the flag it only previews. Note: some accounts (e.g. certain iCloud/Exchange setups) do not permit programmatic calendar creation/deletion.",
        inputSchema: Schema.object([
            "action": Schema.string("list | create | delete", enumValues: ["list", "create", "delete"]),
            "name": Schema.string("Calendar name (for create)"),
            "calendar": Schema.string("Existing calendar name (for delete)"),
            "calendarId": Schema.string("Existing calendar id (for delete)"),
            "color": Schema.string("Hex color like #34C759 (for create)"),
            "confirmDelete": Schema.boolean("Must be true to actually delete (for delete). Omit to preview.")
        ]),
        handler: { args in
            try ek.ensureAccess(.event)
            switch args.string("action") ?? "list" {
            case "list":
                let def = ek.store.defaultCalendarForNewEvents?.calendarIdentifier
                return ["calendars": ek.eventCalendars().map { cal -> JSONObject in
                    var o = EKMapper.calendar(cal)
                    o["isDefault"] = (cal.calendarIdentifier == def)
                    return o
                }]
            case "create":
                guard let name = args.string("name"), !name.isEmpty else {
                    throw ToolError("create requires `name`")
                }
                let cal = EKCalendar(for: .event, eventStore: ek.store)
                cal.title = name
                cal.source = ek.store.defaultCalendarForNewEvents?.source
                    ?? ek.store.sources.first { $0.sourceType == .calDAV }
                    ?? ek.store.sources.first { $0.sourceType == .local }
                if let hex = args.string("color"), let color = colorFromHex(hex) {
                    cal.cgColor = color
                }
                try ek.store.saveCalendar(cal, commit: true)
                return ["created": EKMapper.calendar(cal)]
            case "delete":
                guard let cal = ek.eventCalendar(id: args.string("calendarId"), name: args.string("calendar")) else {
                    throw ToolError("Calendar not found. Provide a valid `calendarId` or `calendar` name.")
                }
                let title = cal.title
                // A whole calendar takes every event in it, irreversibly and on
                // every synced device -- the largest single deletion this server
                // can make, so it gets the same gate as deleting one event.
                guard args.bool("confirmDelete") == true else {
                    let now = Date()
                    let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
                    let yearAhead = Calendar.current.date(byAdding: .year, value: 1, to: now) ?? now
                    let nearby = ek.store.events(matching: ek.store.predicateForEvents(
                        withStart: yearAgo, end: yearAhead, calendars: [cal])).count
                    return [
                        "deleted": false,
                        "wouldDelete": EKMapper.calendar(cal),
                        "eventsWithinAYear": nearby,
                        "message": "Not deleted. Deleting '\(title)' removes EVERY event in it "
                            + "(\(nearby) within a year either side of today, more beyond) on every "
                            + "synced device. Re-call with confirmDelete: true to proceed."
                    ] as JSONObject
                }
                try ek.store.removeCalendar(cal, commit: true)
                return ["deleted": title]
            default:
                throw ToolError("Unknown action. Use list | create | delete.")
            }
        }
    )

    // MARK: calendar_query

    private static let queryTool = Tool(
        name: "calendar_query",
        description: "List events in a date range. `start` and `end` required (ISO or yyyy-MM-dd). Optional: `calendar`/`calendarId` to scope to one calendar; `search` (case-insensitive title/location/notes substring); `limit`. Recurring events are expanded into individual occurrences within the range.",
        inputSchema: Schema.object([
            "start": Schema.string("Range start (ISO or yyyy-MM-dd)"),
            "end": Schema.string("Range end (ISO or yyyy-MM-dd)"),
            "calendar": Schema.string("Restrict to this calendar name"),
            "calendarId": Schema.string("Restrict to this calendar id"),
            "search": Schema.string("Case-insensitive substring match"),
            "limit": Schema.integer("Max results (default 200)")
        ], required: ["start", "end"]),
        handler: { args in
            try ek.ensureAccess(.event)
            let startStr = try requireString(args, "start", "ISO or yyyy-MM-dd")
            guard let start = DateParse.date(startStr) else {
                throw ToolError("Could not parse `start`: \(startStr). Use ISO 8601 or yyyy-MM-dd.")
            }
            let endStr = try requireString(args, "end", "ISO or yyyy-MM-dd")
            guard let end = DateParse.date(endStr) else {
                throw ToolError("Could not parse `end`: \(endStr). Use ISO 8601 or yyyy-MM-dd.")
            }
            let calendars: [EKCalendar]?
            if let cal = ek.eventCalendar(id: args.string("calendarId"), name: args.string("calendar")) {
                calendars = [cal]
            } else if args.string("calendar") != nil || args.string("calendarId") != nil {
                throw ToolError("Requested calendar not found.")
            } else {
                calendars = nil
            }

            let predicate = ek.store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            var events = ek.store.events(matching: predicate)

            if let search = args.string("search")?.lowercased(), !search.isEmpty {
                events = events.filter {
                    ($0.title?.lowercased().contains(search) ?? false) ||
                    ($0.location?.lowercased().contains(search) ?? false) ||
                    ($0.notes?.lowercased().contains(search) ?? false)
                }
            }
            events.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            let limit = args.int("limit") ?? 200
            let limited = Array(events.prefix(max(0, limit)))
            var out: JSONObject = [
                "count": limited.count,
                "total": events.count,
                "totalMatched": events.count,
                "events": limited.map { EKMapper.event($0) }
            ]
            // Silent truncation is how a caller concludes "that is all of
            // them" from a capped page. messages_query and contacts_query
            // already flagged it; these two only reported a total, which is
            // easy to miss.
            if limited.count < events.count {
                out["truncated"] = true
                out["message"] = "Showing \(limited.count) of \(events.count) matching events. Narrow the date range or raise `limit`."
            }
            return out
        }
    )

    // MARK: calendar_create_event

    private static let createTool = Tool(
        name: "calendar_create_event",
        description: "Create a calendar event. Required: `title`, `start`. Optional: `end` (defaults to +1h, or the day for all-day), `allDay`, `calendar`/`calendarId` (defaults to default calendar), `location`, `notes`, `url`, `timeZone` (IANA id), `availability` (busy|free|tentative|unavailable), `recurrence` object, `alarms` array. Recurrence: {frequency:daily|weekly|monthly|yearly, interval, until:\"ISO/yyyy-MM-dd\" (end date; a date-only until includes that whole day) OR count:N (occurrences) — not both, daysOfWeek:[MO,TU,WE,TH,FR], daysOfMonth:[1,15], monthsOfYear:[3], setPositions:[-1]}. Unknown recurrence fields are rejected with an error (never silently dropped); the response echoes the full stored rule incl. until/count/daysOfWeek and an `unbounded` flag. NOTE: attendees cannot be added programmatically (EventKit limitation) — they are read-only.",
        inputSchema: Schema.object([
            "title": Schema.string("Event title"),
            "start": Schema.string("Start (ISO or yyyy-MM-dd)"),
            "end": Schema.string("End (ISO or yyyy-MM-dd)"),
            "allDay": Schema.boolean("All-day event"),
            "calendar": Schema.string("Target calendar name"),
            "calendarId": Schema.string("Target calendar id"),
            "location": Schema.string("Location"),
            "notes": Schema.string("Notes / body"),
            "url": Schema.string("Associated URL"),
            "timeZone": Schema.string("IANA time zone id, e.g. America/New_York"),
            "availability": Schema.string("busy | free | tentative | unavailable"),
            "recurrence": Schema.freeObject("Recurrence rule object"),
            "alarms": Schema.array("Alarms", items: Schema.freeObject("Alarm"))
        ], required: ["title", "start"]),
        handler: { args in
            try ek.ensureAccess(.event)
            let title = try requireString(args, "title", "event title")
            let startStr = try requireString(args, "start", "ISO or yyyy-MM-dd")
            guard let start = DateParse.date(startStr) else {
                throw ToolError("Could not parse `start`: \(startStr). Use ISO 8601 or yyyy-MM-dd.")
            }
            let event = EKEvent(eventStore: ek.store)
            event.title = title
            event.calendar = ek.eventCalendar(id: args.string("calendarId"), name: args.string("calendar"))
                ?? ek.store.defaultCalendarForNewEvents
            guard event.calendar != nil else {
                throw ToolError("No target calendar available (and no default calendar is set).")
            }

            let allDay = args.bool("allDay") ?? DateParse.isDateOnly(startStr)
            event.isAllDay = allDay
            event.startDate = start
            if let endStr = args.string("end"), let end = DateParse.date(endStr) {
                event.endDate = end
            } else if allDay {
                event.endDate = start
            } else {
                event.endDate = start.addingTimeInterval(3600)
            }

            try applyEventFields(event, args)
            try ek.store.save(event, span: .thisEvent, commit: true)
            return ["created": EKMapper.event(event)]
        }
    )

    // MARK: calendar_update_event

    private static let updateTool = Tool(
        name: "calendar_update_event",
        description: "Update an event by `id`. For recurring events, `span` = thisEvent (default) or futureEvents. To bound a runaway/unbounded series after the fact, pass a `recurrence` object with `until` or `count` (it replaces the stored rule); `clearRecurrence`:true removes recurrence entirely. To truncate/split a series AT a specific date, pass `occurrenceDate` (the date of an actual occurrence) together with `span`:\"futureEvents\" — the edit then applies to that occurrence and all later ones instead of the whole series. Provide any of: `title`, `start`, `end`, `allDay`, `location`, `notes`, `url`, `timeZone`, `availability`, `calendar`/`calendarId` (move it), `recurrence` (or `clearRecurrence`:true), `alarms` (replaces all; or `clearAlarms`:true). Same recurrence fields as calendar_create_event.",
        inputSchema: Schema.object([
            "id": Schema.string("Event id (eventIdentifier)"),
            "span": Schema.string("thisEvent | futureEvents", enumValues: ["thisEvent", "futureEvents"]),
            "occurrenceDate": Schema.string("Date of a specific occurrence (ISO or yyyy-MM-dd) to anchor a futureEvents edit at, e.g. to split/trim a recurring series from that date forward"),
            "title": Schema.string("New title"),
            "start": Schema.string("New start"),
            "end": Schema.string("New end"),
            "allDay": Schema.boolean("All-day"),
            "location": Schema.string("New location"),
            "notes": Schema.string("New notes"),
            "url": Schema.string("New URL"),
            "timeZone": Schema.string("IANA time zone id"),
            "availability": Schema.string("busy | free | tentative | unavailable"),
            "calendar": Schema.string("Move to this calendar name"),
            "calendarId": Schema.string("Move to this calendar id"),
            "recurrence": Schema.freeObject("New recurrence rule"),
            "clearRecurrence": Schema.boolean("Remove recurrence"),
            "alarms": Schema.array("Replacement alarms", items: Schema.freeObject("Alarm")),
            "addAlarms": Schema.array("Alarms to ADD, e.g. [{relativeOffset:-600}]", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "removeAlarms": Schema.array("Alarms to REMOVE (matched by offset/date)", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "setAlarms": Schema.array("Replace ALL alarms (needs confirmReplace)", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "confirmReplace": Schema.boolean("Required to be true when using setAlarms"),
            "clearAlarms": Schema.boolean("Remove all alarms")
        ], required: ["id"]),
        handler: { args in
            try ek.ensureAccess(.event)
            let id = try requireString(args, "id", "event id")
            let event = try resolveTarget(id: id, args: args)

            if let title = args.string("title") { event.title = title }
            if let calTarget = ek.eventCalendar(id: args.string("calendarId"), name: args.string("calendar")) {
                event.calendar = calTarget
            }
            if let allDay = args.bool("allDay") { event.isAllDay = allDay }
            if let startStr = args.string("start"), let start = DateParse.date(startStr) { event.startDate = start }
            if let endStr = args.string("end"), let end = DateParse.date(endStr) { event.endDate = end }

            try applyEventFields(event, args)

            if args.bool("clearRecurrence") == true { event.recurrenceRules = nil }
            if args.bool("clearAlarms") == true { event.alarms = nil }
            try AlarmEdits.apply(to: event, args)

            var span: EKSpan = (args.string("span") == "futureEvents") ? .futureEvents : .thisEvent
            // Changing the recurrence rule of a series must not be saved as a
            // single-occurrence (.thisEvent) edit — that detaches one instance
            // instead of re-bounding the series. Force .futureEvents for a
            // series-level recurrence change (unless the caller is deliberately
            // anchoring at a specific occurrence to split the series).
            let changesRecurrence = args.object("recurrence") != nil || args.bool("clearRecurrence") == true
            // Alarm edits need the same treatment, and for a subtler reason: a
            // .thisEvent save DETACHES that occurrence from the series. The next
            // alarm edit then resolves the id back to the series master, which
            // still has the old alarms, so "add one alarm" reads an empty list
            // and silently replaces the set instead of extending it. Verified:
            // add/remove behave correctly on a non-recurring event and only lose
            // alarms on a series saved with .thisEvent.
            let changesAlarms = args.array("addAlarms") != nil
                || args.array("removeAlarms") != nil
                || args.array("setAlarms") != nil
                || args.array("alarms") != nil
                || args.bool("clearAlarms") == true
            if (changesRecurrence || changesAlarms) && args.string("occurrenceDate") == nil {
                span = .futureEvents
            }
            try ek.store.save(event, span: span, commit: true)
            return ["updated": EKMapper.event(event)]
        }
    )

    // MARK: calendar_delete_event

    private static let deleteTool = Tool(
        name: "calendar_delete_event",
        description: "Delete an event by `id`. For recurring events, `span` = thisEvent (default) or futureEvents. To trim a series at a date (delete this-and-future from a chosen point), pass `occurrenceDate` (the date of an actual occurrence) with `span`:\"futureEvents\"; without `occurrenceDate`, futureEvents affects the whole series from its next occurrence.",
        inputSchema: Schema.object([
            "id": Schema.string("Event id"),
            "span": Schema.string("thisEvent | futureEvents", enumValues: ["thisEvent", "futureEvents"]),
            "occurrenceDate": Schema.string("Date of a specific occurrence (ISO or yyyy-MM-dd) to anchor a futureEvents delete at"),
            "confirmDelete": Schema.boolean("Must be true to actually delete. Omit to preview. span:futureEvents removes the whole rest of the series.")
        ], required: ["id"]),
        handler: { args in
            try ek.ensureAccess(.event)
            let id = try requireString(args, "id", "event id")
            let event = try resolveTarget(id: id, args: args)
            let title = event.title ?? ""
            let span: EKSpan = (args.string("span") == "futureEvents") ? .futureEvents : .thisEvent

            // A futureEvents delete removes the whole rest of the series. That is
            // a very different action from removing one occurrence, and nothing
            // in the call itself distinguishes them, so say how many are at stake.
            let affected = (span == .futureEvents) ? countRemainingOccurrences(of: event) : 1

            guard args.bool("confirmDelete") == true else {
                var preview: JSONObject = [
                    "deleted": false,
                    "wouldDelete": EKMapper.event(event),
                    "span": span == .futureEvents ? "futureEvents" : "thisEvent"
                ]
                if span == .futureEvents {
                    preview["occurrencesAffected"] = affected
                    preview["message"] = "Not deleted. This would remove \(affected) occurrence(s) - "
                        + "the whole remainder of the series, not just this one. Re-call with "
                        + "confirmDelete: true, or use span thisEvent for a single occurrence."
                } else {
                    preview["message"] = "Not deleted. Re-call with confirmDelete: true. "
                        + "This syncs to iCloud and cannot be undone."
                }
                return preview
            }

            try ek.store.remove(event, span: span, commit: true)
            var out: JSONObject = ["deleted": ["id": id, "title": title]]
            if span == .futureEvents { out["occurrencesDeleted"] = affected }
            return out
        }
    )

    // MARK: - Shared helpers

    /// Resolve the event to act on: a specific occurrence when `occurrenceDate`
    /// is supplied (so a `futureEvents` edit/delete can be anchored at a date to
    /// split or trim a series), otherwise the series itself.
    /// How many occurrences a `.futureEvents` delete would take with it.
    ///
    /// EventKit gives no count for a span delete, so enumerate the series
    /// forward and count. Bounded at two years: enough to convey the scale of
    /// the action without walking an unbounded recurrence forever.
    private static func countRemainingOccurrences(of event: EKEvent) -> Int {
        guard event.hasRecurrenceRules, let start = event.startDate else { return 1 }
        let horizon = Calendar.current.date(byAdding: .year, value: 2, to: start) ?? start
        let predicate = ek.store.predicateForEvents(withStart: start, end: horizon,
                                                    calendars: event.calendar.map { [$0] })
        let identifier = event.eventIdentifier
        return max(ek.store.events(matching: predicate).filter { $0.eventIdentifier == identifier }.count, 1)
    }

    private static func resolveTarget(id: String, args: JSONObject) throws -> EKEvent {
        guard let occStr = args.string("occurrenceDate") else {
            return try ek.event(byId: id)
        }
        guard let occDate = DateParse.date(occStr) else {
            throw ToolError("Could not parse `occurrenceDate`: \(occStr). Use ISO 8601 or yyyy-MM-dd.")
        }
        return try ek.occurrence(ofSeries: id, on: occDate)
    }

    private static func applyEventFields(_ event: EKEvent, _ args: JSONObject) throws {
        if let location = args.string("location") { event.location = location }
        if let notes = args.string("notes") { event.notes = notes }
        if let urlStr = args.string("url"), let url = URL(string: urlStr) { event.url = url }
        if let tzId = args.string("timeZone"), let tz = TimeZone(identifier: tzId) { event.timeZone = tz }
        if let availability = args.string("availability") {
            switch availability.lowercased() {
            case "busy": event.availability = .busy
            case "free": event.availability = .free
            case "tentative": event.availability = .tentative
            case "unavailable": event.availability = .unavailable
            default: break
            }
        }
        if let recurrence = args.object("recurrence") {
            event.recurrenceRules = [try Recurrence.rule(from: recurrence)]
        }
        if let alarmArray = args.array("alarms") {
            event.alarms = nil
            for alarm in Alarms.build(from: alarmArray) { event.addAlarm(alarm) }
        }
    }
}
