import EventKit
import Foundation

enum ReminderTools {
    private static var ek: EventKitStore { EventKitStore.shared }

    static let all: [Tool] = [
        listsTool,
        queryTool,
        createTool,
        bulkCreateTool,
        updateTool,
        completeTool,
        deleteTool,
        bulkUpdateTool,
        bulkDeleteTool,
        routeTool,
        scheduleTool
    ]

    // MARK: reminders_lists

    private static let listsTool = Tool(
        name: "reminders_lists",
        description: """
        List, create, rename, merge, or delete Reminders lists. action=list (default) returns all \
        lists; create needs `name`; rename needs `list`/`listId` plus the new `name`; merge needs \
        `from` and `into`; delete needs `listId` or `list` AND `confirmDelete: true` — deleting a list \
        deletes every reminder in it, so without the flag it only previews.

        merge moves every reminder out of `from` into `into` and then deletes the emptied list — the \
        natural end of a restructure, which otherwise cannot be expressed. It requires \
        `confirmMerge: true` and previews what would move otherwise. The source list is deleted ONLY \
        if every reminder moved successfully; a partial move leaves it in place, because deleting a \
        list that still holds reminders would destroy them.
        """,
        inputSchema: Schema.object([
            "action": Schema.string("list | create | rename | merge | delete",
                                    enumValues: ["list", "create", "rename", "merge", "delete"]),
            "name": Schema.string("List name (for create, or the NEW name for rename)"),
            "list": Schema.string("Existing list name (for rename/delete)"),
            "listId": Schema.string("Existing list id (for rename/delete)"),
            "from": Schema.string("Source list name or id (for merge) — emptied, then deleted"),
            "into": Schema.string("Destination list name or id (for merge)"),
            "confirmMerge": Schema.boolean("Must be true to actually merge. Omit to preview."),
            "confirmDelete": Schema.boolean("Must be true to actually delete (for delete). Omit to preview."),
            "color": Schema.string("Hex color like #FF9500 (for create)")
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            switch args.string("action") ?? "list" {
            case "list":
                return ["lists": ek.reminderCalendars().map { EKMapper.calendar($0) }]
            case "create":
                guard let name = args.string("name"), !name.isEmpty else {
                    throw ToolError("create requires `name`")
                }
                let cal = EKCalendar(for: .reminder, eventStore: ek.store)
                cal.title = name
                cal.source = ek.store.defaultCalendarForNewReminders()?.source
                    ?? ek.store.sources.first { $0.sourceType == .calDAV }
                    ?? ek.store.sources.first { $0.sourceType == .local }
                if let hex = args.string("color"), let color = colorFromHex(hex) {
                    cal.cgColor = color
                }
                try ek.store.saveCalendar(cal, commit: true)
                return ["created": EKMapper.calendar(cal)]
            case "rename":
                guard let cal = ek.reminderList(id: args.string("listId"), name: args.string("list")) else {
                    throw ToolError("List not found. Provide a valid `listId` or `list` name.")
                }
                let newName = try requireString(args, "name", "the new list name")
                let previous = cal.title
                guard newName != previous else {
                    return ["renamed": false, "message": "`\(newName)` is already the name."]
                }
                // Reminders keep their calendar reference, so a rename moves
                // nothing and breaks no ids -- unlike merge, which does.
                cal.title = newName
                try ek.store.saveCalendar(cal, commit: true)
                return ["renamed": ["from": previous, "to": newName, "id": cal.calendarIdentifier]]

            case "merge":
                let fromName = try requireString(args, "from", "the source list")
                let intoName = try requireString(args, "into", "the destination list")
                guard let source = ek.reminderList(id: fromName, name: fromName) else {
                    throw ToolError("Source list `\(fromName)` not found.")
                }
                guard let target = ek.reminderList(id: intoName, name: intoName) else {
                    throw ToolError("Destination list `\(intoName)` not found.")
                }
                guard source.calendarIdentifier != target.calendarIdentifier else {
                    throw ToolError("`from` and `into` are the same list.")
                }
                let moving = ek.fetchReminders(ek.store.predicateForReminders(in: [source]))

                guard args.bool("confirmMerge") == true else {
                    return [
                        "merged": false,
                        "from": source.title,
                        "into": target.title,
                        "count": moving.count,
                        "wouldMove": moving.map { BatchTarget.preview($0) },
                        "message": "Nothing was moved. Re-call with confirmMerge: true to move these "
                            + "\(moving.count) reminder(s) into `\(target.title)` and then delete "
                            + "`\(source.title)`. Deleting a list syncs to iCloud and cannot be undone."
                    ]
                }

                var moved = 0
                var failures: [JSONObject] = []
                for reminder in moving {
                    do {
                        reminder.calendar = target
                        try ek.store.save(reminder, commit: true)
                        moved += 1
                    } catch {
                        failures.append(["id": reminder.calendarItemIdentifier,
                                         "title": reminder.title ?? "",
                                         "error": error.localizedDescription])
                    }
                }

                // The source list is removed ONLY if it is genuinely empty now.
                // Deleting a list still holding reminders deletes the reminders
                // with it, so a partial move must not be followed by a delete --
                // that is the one way this operation could lose data.
                var out: JSONObject = ["from": source.title, "into": target.title,
                                       "moved": moved, "failed": failures.count]
                if failures.isEmpty {
                    try ek.store.removeCalendar(source, commit: true)
                    out["merged"] = true
                    out["sourceDeleted"] = true
                } else {
                    out["merged"] = false
                    out["sourceDeleted"] = false
                    out["failures"] = failures
                    out["message"] = "Moved \(moved) of \(moving.count). `\(source.title)` was NOT "
                        + "deleted because \(failures.count) reminder(s) are still in it — deleting "
                        + "it now would take them with it. Resolve the failures and re-run."
                }
                return out

            case "delete":
                guard let cal = ek.reminderList(id: args.string("listId"), name: args.string("list")) else {
                    throw ToolError("List not found. Provide a valid `listId` or `list` name.")
                }
                let title = cal.title
                // Deleting a list deletes every reminder in it. Same gate as
                // deleting a single reminder, and a preview that says how many.
                guard args.bool("confirmDelete") == true else {
                    let inside = ek.fetchReminders(ek.store.predicateForReminders(in: [cal]))
                    let open = inside.filter { !$0.isCompleted }.count
                    return [
                        "deleted": false,
                        "wouldDelete": EKMapper.calendar(cal),
                        "reminders": inside.count,
                        "incomplete": open,
                        "message": "Not deleted. Deleting '\(title)' removes all \(inside.count) "
                            + "reminder(s) in it (\(open) incomplete) on every synced device. Use "
                            + "action merge to keep them, or re-call with confirmDelete: true."
                    ] as JSONObject
                }
                try ek.store.removeCalendar(cal, commit: true)
                return ["deleted": title]
            default:
                throw ToolError("Unknown action. Use list | create | rename | merge | delete.")
            }
        }
    )

    // MARK: reminders_query

    private static let queryTool = Tool(
        name: "reminders_query",
        description: "Search reminders. Optional filters: `list`/`listId` to scope to one list; `status` (incomplete|completed|all, default incomplete); `dueBefore`/`dueAfter` (ISO date or yyyy-MM-dd); `search` (case-insensitive title/notes substring); `limit`.",
        inputSchema: Schema.object([
            "list": Schema.string("Restrict to this list name"),
            "listId": Schema.string("Restrict to this list id"),
            "status": Schema.string("incomplete | completed | all", enumValues: ["incomplete", "completed", "all"]),
            "dueBefore": Schema.string("Only reminders due on/before this date"),
            "dueAfter": Schema.string("Only reminders due on/after this date"),
            "search": Schema.string("Case-insensitive substring match on title/notes"),
            "limit": Schema.integer("Max results (default 100)"),
            "excludeNotes": Schema.boolean("Omit note bodies, returning only notesLength. Use when listing many reminders."),
            "maxNotesLength": Schema.integer("Truncate note bodies to this many characters (sets notesTruncated)"),
            "fields": Schema.array("Only return these keys on each reminder, e.g. [\"id\",\"title\",\"due\"]", items: Schema.string("field name")),
            "flagVague": Schema.boolean(
                "Mark reminders whose titles cannot be acted on without more context (no notes, no due date, and either very short or a bare quantity like \"3 boxes\"). Adds `vague` and `vagueReason`, plus a `vagueCount` summary.")
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let calendars: [EKCalendar]?
            if let cal = ek.reminderList(id: args.string("listId"), name: args.string("list")) {
                calendars = [cal]
            } else if args.string("list") != nil || args.string("listId") != nil {
                throw ToolError("Requested list not found.")
            } else {
                calendars = nil
            }

            let predicate = ek.store.predicateForReminders(in: calendars)
            var reminders = ek.fetchReminders(predicate)

            switch args.string("status") ?? "incomplete" {
            case "incomplete": reminders = reminders.filter { !$0.isCompleted }
            case "completed": reminders = reminders.filter { $0.isCompleted }
            default: break
            }

            if let beforeStr = args.string("dueBefore"), let before = DateParse.date(beforeStr) {
                reminders = reminders.filter { dueDate($0).map { $0 <= before } ?? false }
            }
            if let afterStr = args.string("dueAfter"), let after = DateParse.date(afterStr) {
                reminders = reminders.filter { dueDate($0).map { $0 >= after } ?? false }
            }
            if let search = args.string("search")?.lowercased(), !search.isEmpty {
                reminders = reminders.filter {
                    ($0.title?.lowercased().contains(search) ?? false) ||
                    ($0.notes?.lowercased().contains(search) ?? false)
                }
            }

            reminders.sort { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
            let limit = args.int("limit") ?? 100
            let limited = Array(reminders.prefix(max(0, limit)))

            // Notes are the one unbounded field on a reminder, and some apps
            // park base64 images there, so a single list of image-bearing
            // reminders can make up most of a response nobody wanted.
            let notesMode: EKMapper.NotesMode = {
                if args.bool("excludeNotes") == true { return .excluded }
                if let cap = args.int("maxNotesLength") { return .truncated(cap) }
                return .full
            }()
            // `id` is always kept: a filtered result a caller cannot act on
            // afterwards would be a trap.
            let fieldFilter: Set<String>? = args.array("fields").map {
                Set($0.compactMap { $0 as? String }).union(["id"])
            }
            var out: JSONObject = [
                "count": limited.count,
                "total": reminders.count,
                "totalMatched": reminders.count,
                "reminders": limited.map { r -> JSONObject in
                    var o = EKMapper.reminder(r, notes: notesMode)
                    if let keep = fieldFilter { o = o.filter { keep.contains($0.key) } }
                    return o
                }
            ]
            // Silent truncation is how a caller concludes "that is all of
            // them" from a capped page. messages_query and contacts_query
            // already flagged it; these two only reported a total, which is
            // easy to miss.
            // Surfacing the reminders that a future reader -- human or model --
            // will not be able to act on. A shopping list holding "3 boxes"
            // or "12 large" is the typical case: quantities whose object was
            // never written down, unclassifiable months later without asking.
            // The rule is deliberately conservative, because a false positive
            // teaches you to ignore the flag.
            if args.bool("flagVague") == true {
                var vague = 0
                out["reminders"] = (out["reminders"] as? [JSONObject] ?? []).enumerated().map {
                    index, item -> JSONObject in
                    var item = item
                    if let reason = vagueReason(limited[index]) {
                        item["vague"] = true
                        item["vagueReason"] = reason
                        vague += 1
                    }
                    return item
                }
                out["vagueCount"] = vague
                if vague > 0 {
                    out["vagueMessage"] = "\(vague) reminder(s) carry no notes, no due date, and a "
                        + "title too thin to act on. Add context or delete them — they are the ones "
                        + "that survive every cleanup because nobody can tell what they meant."
                }
            }
            if limited.count < reminders.count {
                out["truncated"] = true
                out["message"] = "Showing \(limited.count) of \(reminders.count) matching reminders. Narrow with `list`/`status`/`dueBefore`, or raise `limit`."
            }
            return out
        }
    )

    // MARK: reminders_create

    private static let createTool = Tool(
        name: "reminders_create",
        description: "Create a reminder. `title` required. Optional: `list`/`listId` (defaults to the default list), `notes`, `due` (ISO or yyyy-MM-dd; add a time for a timed reminder), `priority` (none|high|medium|low), `url`, `recurrence` object, `alarms` array. Recurrence: {frequency:daily|weekly|monthly|yearly, interval, until:\"ISO/yyyy-MM-dd\" (end date) OR count:N (occurrences) — not both, daysOfWeek:[MO,TU...], daysOfMonth:[..]}. Unknown recurrence fields error out rather than being dropped. Alarms: [{relativeOffset seconds, negative = before due}] or [{absoluteDate ISO}].",
        inputSchema: Schema.object([
            "title": Schema.string("Reminder title"),
            "list": Schema.string("Target list name"),
            "listId": Schema.string("Target list id"),
            "notes": Schema.string("Notes / body"),
            "due": Schema.string("Due date (ISO or yyyy-MM-dd)"),
            "priority": Schema.string("none | high | medium | low"),
            "url": Schema.string("Associated URL"),
            "recurrence": Schema.freeObject("Recurrence rule object"),
            "alarms": Schema.array("Alarms", items: Schema.freeObject("Alarm"))
        ], required: ["title"]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let title = try requireString(args, "title", "reminder title")
            let reminder = EKReminder(eventStore: ek.store)
            reminder.title = title
            reminder.calendar = ek.reminderList(id: args.string("listId"), name: args.string("list"))
                ?? ek.store.defaultCalendarForNewReminders()
            guard reminder.calendar != nil else {
                throw ToolError("No target list available (and no default Reminders list is set).")
            }
            try applyReminderFields(reminder, args)
            try ek.store.save(reminder, commit: true)
            return ["created": EKMapper.reminder(reminder)]
        }
    )

    // MARK: reminders_bulk_create

    /// Fields one `items[]` entry may carry.
    ///
    /// `MCPServer.unknownArguments` only inspects TOP-LEVEL argument keys against
    /// the schema, and `items` is an array of free-form objects it cannot see
    /// into. Without this, a caller that writes `name:` where the tool wants
    /// `title:` has the field silently dropped and gets a reminder with an empty
    /// title -- the exact failure the top-level check exists to prevent.
    /// Internal rather than private so tests can exercise it with no TCC grant.
    static let bulkItemFields: Set<String> = [
        "title", "notes", "due", "priority", "url", "recurrence", "alarms", "list", "listId"
    ]

    /// Refuse an item carrying a field the tool does not accept, naming both the
    /// offending keys and the accepted set -- same shape as the top-level check,
    /// so the two read alike to a model trying to self-correct.
    static func validateBulkItem(_ item: JSONObject, at index: Int) throws {
        let unknown = item.keys.filter { !bulkItemFields.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let noun = unknown.count == 1 ? "field" : "fields"
            throw ToolError("items[\(index)]: unknown \(noun) \(unknown.joined(separator: ", ")). "
                + "Accepted: \(bulkItemFields.sorted().joined(separator: ", ")).")
        }
    }

    /// Upper bound on one batch.
    ///
    /// Each item is a separate EventKit commit that syncs to iCloud, so cost is
    /// linear in wall-clock. 100 keeps the worst case inside a typical client
    /// timeout; past that a caller is better served by two calls than by one
    /// that dies halfway and leaves them reconciling.
    static let bulkMaxItems = 100

    private static let bulkCreateTool = Tool(
        name: "reminders_bulk_create",
        description: """
        Create many reminders in ONE call. `items` is an array of objects taking the same fields as \
        reminders_create (`title` required; optional `notes`, `due`, `priority`, `url`, `recurrence`, \
        `alarms`, plus a per-item `list`/`listId`). A top-level `list`/`listId` is the default target \
        for items that name none. Maximum 100 items.

        Partial success is the contract, not a failure mode: EventKit commits each reminder \
        separately, so there is no transaction to roll back. Every item gets an entry in `results` \
        carrying its index and either an id or the reason it failed, and the call reports \
        `created`/`failed` instead of throwing on the first bad row. Pass `stopOnError: true` to halt \
        at the first failure; the untouched remainder comes back marked `skipped`.

        Use `idempotencyKey` here especially: a batch that times out is exactly the case where you \
        cannot tell what landed, and replaying the key returns the original per-item results rather \
        than creating a second copy of everything that already succeeded.
        """,
        inputSchema: Schema.object([
            "items": Schema.array(
                "Reminders to create; each takes the reminders_create fields. `title` is required.",
                items: Schema.freeObject(
                    "{title, notes?, due?, priority?, url?, recurrence?, alarms?, list?, listId?}")),
            "list": Schema.string("Default target list name for items that do not name one"),
            "listId": Schema.string("Default target list id for items that do not name one"),
            "stopOnError": Schema.boolean("Halt at the first failure rather than continuing (default false)")
        ], required: ["items"]),
        handler: { args in
            try ek.ensureAccess(.reminder)

            guard let rawItems = args.array("items") else {
                throw ToolError("`items` is required (an array of reminder objects). "
                    + "Received argument keys: [\(args.keys.sorted().joined(separator: ", "))]")
            }
            guard !rawItems.isEmpty else {
                throw ToolError("`items` is empty; there is nothing to create.")
            }
            guard rawItems.count <= bulkMaxItems else {
                throw ToolError("`items` has \(rawItems.count) entries; the maximum is \(bulkMaxItems). "
                    + "Split the batch -- each entry is a separate EventKit commit that syncs to iCloud.")
            }

            // Resolve each distinct list ONCE. `reminderList(id:name:)` falls
            // back to enumerating `calendars(for:.reminder)` for a name lookup,
            // so a 50-item batch naming one list would otherwise pay for 50
            // identical EventKit round trips.
            var listCache: [String: EKCalendar?] = [:]
            func resolveList(id: String?, name: String?) -> EKCalendar? {
                let key = "\(id ?? "")\u{0}\(name ?? "")"
                if let cached = listCache[key] { return cached }
                let resolved = ek.reminderList(id: id, name: name)
                listCache[key] = resolved
                return resolved
            }

            let defaultList = resolveList(id: args.string("listId"), name: args.string("list"))
                ?? ek.store.defaultCalendarForNewReminders()

            // Caught once, up front. If there is no target at all then every
            // item fails for the same reason, and fifty identical errors are
            // worse than one that says it plainly.
            let anyItemNamesAList = rawItems.contains {
                guard let o = $0 as? JSONObject else { return false }
                return o.string("list") != nil || o.string("listId") != nil
            }
            if defaultList == nil && !anyItemNamesAList {
                throw ToolError("No target list available, and no default Reminders list is set. "
                    + "Pass `list`/`listId` at the top level, or name one per item.")
            }

            let stopOnError = args.bool("stopOnError") == true
            var results: [JSONObject] = []
            var created = 0
            var failed = 0
            var halted = false

            for (index, raw) in rawItems.enumerated() {
                if halted {
                    results.append(["index": index, "ok": false, "skipped": true,
                                    "error": "Not attempted -- stopOnError halted the batch."])
                    continue
                }
                guard let item = raw as? JSONObject else {
                    failed += 1
                    results.append(["index": index, "ok": false,
                                    "error": "Not an object. Every entry of `items` must be a reminder object."])
                    if stopOnError { halted = true }
                    continue
                }
                do {
                    try validateBulkItem(item, at: index)
                    let title = try requireString(item, "title", "reminder title")
                    let reminder = EKReminder(eventStore: ek.store)
                    reminder.title = title
                    reminder.calendar = resolveList(id: item.string("listId"), name: item.string("list"))
                        ?? defaultList
                    guard reminder.calendar != nil else {
                        throw ToolError("No target list for this item and no default is set.")
                    }
                    // The same routine reminders_create uses, so `due`,
                    // `recurrence` and `alarms` parse identically here -- and a
                    // fix to either path lands on both.
                    try applyReminderFields(reminder, item)
                    try ek.store.save(reminder, commit: true)
                    created += 1
                    results.append(["index": index, "ok": true,
                                    "id": reminder.calendarItemIdentifier,
                                    "title": title,
                                    "list": reminder.calendar?.title ?? ""])
                } catch let error as ToolError {
                    failed += 1
                    results.append(["index": index, "ok": false,
                                    "title": item.string("title") ?? "",
                                    "error": error.message])
                    if stopOnError { halted = true }
                } catch {
                    failed += 1
                    results.append(["index": index, "ok": false,
                                    "title": item.string("title") ?? "",
                                    "error": error.localizedDescription])
                    if stopOnError { halted = true }
                }
            }

            var out: JSONObject = [
                "created": created,
                "failed": failed,
                "total": rawItems.count,
                "results": results
            ]
            if let name = defaultList?.title { out["defaultList"] = name }
            if halted { out["haltedOnError"] = true }
            // Said plainly rather than left as two integers to compare: a
            // partially-applied batch is the result most likely to be read as a
            // clean success.
            if failed > 0 {
                out["message"] = "Created \(created) of \(rawItems.count); \(failed) failed. "
                    + "`results` carries the per-item reason. Re-send only the failed items -- "
                    + "re-sending the whole batch would duplicate the ones that succeeded."
            }
            return out
        }
    )

    // MARK: reminders_update

    private static let updateTool = Tool(
        name: "reminders_update",
        description: "Update a reminder by `id`. Provide any of: `title`, `notes`, `due` (or set `clearDue`:true), `priority`, `url`, `list`/`listId` (move it), `recurrence` (or `clearRecurrence`:true), `alarms` (replaces all; or `clearAlarms`:true), `completed`.",
        inputSchema: Schema.object([
            "id": Schema.string("Reminder id (calendarItemIdentifier)"),
            "title": Schema.string("New title"),
            "notes": Schema.string("New notes"),
            "due": Schema.string("New due date"),
            "clearDue": Schema.boolean("Remove the due date"),
            "priority": Schema.string("none | high | medium | low"),
            "url": Schema.string("New URL"),
            "list": Schema.string("Move to this list name"),
            "listId": Schema.string("Move to this list id"),
            "recurrence": Schema.freeObject("New recurrence rule"),
            "clearRecurrence": Schema.boolean("Remove recurrence"),
            "alarms": Schema.array("Replacement alarms", items: Schema.freeObject("Alarm")),
            "addAlarms": Schema.array("Alarms to ADD, e.g. [{relativeOffset:-600}]", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "removeAlarms": Schema.array("Alarms to REMOVE (matched by offset/date)", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "setAlarms": Schema.array("Replace ALL alarms (needs confirmReplace)", items: Schema.freeObject("{relativeOffset}|{absoluteDate}")),
            "confirmReplace": Schema.boolean("Required to be true when using setAlarms"),
            "clearAlarms": Schema.boolean("Remove all alarms"),
            "completed": Schema.boolean("Mark completed/incomplete")
        ], required: ["id"]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let id = try requireString(args, "id", "reminder id")
            let reminder = try ek.reminder(byId: id)

            if let title = args.string("title") { reminder.title = title }
            if let listTarget = ek.reminderList(id: args.string("listId"), name: args.string("list")) {
                reminder.calendar = listTarget
            }
            try applyReminderFields(reminder, args)

            if args.bool("clearDue") == true { reminder.dueDateComponents = nil }
            if args.bool("clearRecurrence") == true { reminder.recurrenceRules = nil }
            if args.bool("clearAlarms") == true { reminder.alarms = nil }
            try AlarmEdits.apply(to: reminder, args)
            if let completed = args.bool("completed") {
                reminder.isCompleted = completed
            }

            try ek.store.save(reminder, commit: true)
            return ["updated": EKMapper.reminder(reminder)]
        }
    )

    // MARK: reminders_complete

    private static let completeTool = Tool(
        name: "reminders_complete",
        description: "Mark a reminder complete (or incomplete). `id` required; `completed` defaults to true.",
        inputSchema: Schema.object([
            "id": Schema.string("Reminder id"),
            "completed": Schema.boolean("true to complete (default), false to reopen")
        ], required: ["id"]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let id = try requireString(args, "id", "reminder id")
            let reminder = try ek.reminder(byId: id)
            reminder.isCompleted = args.bool("completed") ?? true
            try ek.store.save(reminder, commit: true)
            return ["updated": EKMapper.reminder(reminder)]
        }
    )

    // MARK: reminders_delete

    private static let deleteTool = Tool(
        name: "reminders_delete",
        description: """
        Delete a reminder by `id`. IRREVERSIBLE and syncs to iCloud — `confirmDelete` must be \
        explicitly true; without it this returns what WOULD be deleted so you can check it is the \
        right reminder. To finish a task rather than erase it, use reminders_complete instead, \
        which is reversible.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Reminder id"),
            "confirmDelete": Schema.boolean("Must be true to actually delete. Omit to preview.")
        ], required: ["id"]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let id = try requireString(args, "id", "reminder id")
            let reminder = try ek.reminder(byId: id)
            let title = reminder.title ?? ""

            guard args.bool("confirmDelete") == true else {
                return [
                    "deleted": false,
                    "wouldDelete": EKMapper.reminder(reminder),
                    "message": "Not deleted. Re-call with confirmDelete: true. This syncs to "
                        + "iCloud and cannot be undone. If the task is simply done, "
                        + "reminders_complete is reversible."
                ]
            }

            try ek.store.remove(reminder, commit: true)
            return ["deleted": ["id": id, "title": title]]
        }
    )

    // MARK: reminders_bulk_update

    /// What a bulk update may set on every reminder it touches.
    ///
    /// Deliberately excludes `title` and `notes`. Both are per-reminder prose,
    /// and writing one value across a batch does not edit those records, it
    /// overwrites them — the "add a work number, lose the mobile" failure that
    /// contacts_update already had to grow add/remove semantics to fix. Move,
    /// reschedule, reprioritise and complete are the operations that genuinely
    /// mean the same thing applied to fifty rows.
    static let bulkUpdateFields: Set<String> = [
        "list", "listId", "due", "clearDue", "priority", "completed"
    ]

    private static let bulkUpdateTool = Tool(
        name: "reminders_bulk_update",
        description: """
        Apply ONE change to many reminders. Target them with `ids` (explicit) or `filter` (a query: \
        {list, listId, status, dueBefore, dueAfter, search}) — one or the other, never both. Then set \
        any of `list`/`listId` (move them), `due` or `clearDue`, `priority`, `completed`.

        This is the tool for restructuring: moving 50 reminders into a new list is one call, not 50. \
        `title` and `notes` are deliberately NOT settable — one value written across a batch would \
        overwrite fifty different bodies rather than edit them.

        A `filter` never fires blind. Send it without `expectedCount` and you get back the reminders \
        it matched and nothing is changed; re-send with `expectedCount` set to that number to \
        proceed. The value cannot be known without previewing, and a mismatch means the set moved \
        under you — reminders sync from other devices continuously — so it aborts rather than acting \
        on the difference.

        Per-item results, because EventKit saves each reminder separately and a batch can be partly \
        applied. `stopOnError: true` halts at the first failure.
        """,
        inputSchema: Schema.object([
            "ids": Schema.array("Reminder ids to update", items: Schema.string("Reminder id")),
            "filter": Schema.freeObject(
                "Query describing what to update: {list, listId, status, dueBefore, dueAfter, search}"),
            "expectedCount": Schema.integer(
                "Required with `filter`: the number the preview reported. Guards against acting on a set you have not seen."),
            "list": Schema.string("Move them all to this list name"),
            "listId": Schema.string("Move them all to this list id"),
            "due": Schema.string("Set this due date on all of them"),
            "clearDue": Schema.boolean("Remove the due date from all of them"),
            "priority": Schema.string("none | high | medium | low"),
            "completed": Schema.boolean("Mark them all complete / incomplete"),
            "stopOnError": Schema.boolean("Halt at the first failure rather than continuing (default false)")
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)

            // Refuse a no-op before resolving anything. A batch that targets 80
            // reminders and changes nothing looks exactly like success.
            let edits = bulkUpdateFields.filter { args[$0] != nil }
            guard !edits.isEmpty else {
                throw ToolError("Nothing to change. Set at least one of: "
                    + "\(bulkUpdateFields.sorted().joined(separator: ", ")).")
            }
            if args.string("due") != nil && args.bool("clearDue") == true {
                throw ToolError("`due` and `clearDue` contradict each other; send one.")
            }

            let resolved = try BatchTarget.resolve(args, ek, cap: bulkMaxItems)
            if let preview = try BatchTarget.filterGate(args, resolved, verb: "updated") {
                return preview
            }

            // Resolve the destination list once, not per reminder: a name lookup
            // enumerates every reminder calendar.
            var destination: EKCalendar?
            if args.string("list") != nil || args.string("listId") != nil {
                destination = ek.reminderList(id: args.string("listId"), name: args.string("list"))
                guard destination != nil else {
                    throw ToolError("Target list not found. Check `list`/`listId`, or create it with "
                        + "reminders_lists action:create.")
                }
            }

            let stopOnError = args.bool("stopOnError") == true
            var results: [JSONObject] = resolved.notFound.map {
                ["id": $0, "ok": false, "error": "No reminder with this id."]
            }
            var updated = 0
            var failed = resolved.notFound.count
            var halted = false

            for reminder in resolved.reminders {
                let id = reminder.calendarItemIdentifier
                if halted {
                    results.append(["id": id, "ok": false, "skipped": true,
                                    "error": "Not attempted — stopOnError halted the batch."])
                    continue
                }
                do {
                    if let destination { reminder.calendar = destination }
                    // applyReminderFields covers due/priority with exactly the
                    // parsing reminders_update uses; nothing is reimplemented.
                    try applyReminderFields(reminder, args)
                    if args.bool("clearDue") == true { reminder.dueDateComponents = nil }
                    if let completed = args.bool("completed") { reminder.isCompleted = completed }
                    try ek.store.save(reminder, commit: true)
                    updated += 1
                    results.append(["id": id, "ok": true,
                                    "title": reminder.title ?? "",
                                    "list": reminder.calendar?.title ?? ""])
                } catch let error as ToolError {
                    failed += 1
                    results.append(["id": id, "ok": false, "title": reminder.title ?? "",
                                    "error": error.message])
                    if stopOnError { halted = true }
                } catch {
                    failed += 1
                    results.append(["id": id, "ok": false, "title": reminder.title ?? "",
                                    "error": error.localizedDescription])
                    if stopOnError { halted = true }
                }
            }

            var out: JSONObject = [
                "updated": updated,
                "failed": failed,
                "total": resolved.reminders.count + resolved.notFound.count,
                "applied": edits.sorted(),
                "results": results
            ]
            if halted { out["haltedOnError"] = true }
            if failed > 0 {
                out["message"] = "Updated \(updated) of \(out["total"] ?? 0); \(failed) failed. "
                    + "`results` carries the per-id outcome."
            }
            return out
        }
    )

    // MARK: reminders_bulk_delete

    private static let bulkDeleteTool = Tool(
        name: "reminders_bulk_delete",
        description: """
        Delete many reminders in ONE call. IRREVERSIBLE and syncs to iCloud. Target them with `ids` \
        or with `filter` ({list, listId, status, dueBefore, dueAfter, search}) — one or the other.

        Two independent gates, and both must be passed. `confirmDelete` must be explicitly true; \
        without it you get back exactly what WOULD be deleted — id, title, list, completion state — \
        plus any ids that did not resolve. And a `filter` additionally requires `expectedCount` \
        matching what the preview reported, so a described set is never destroyed sight-unseen and a \
        set that changed under you aborts instead.

        To finish tasks rather than erase them, reminders_bulk_update with `completed: true` is \
        reversible and is almost always the better tool. Prefer it unless the records genuinely need \
        to be gone.
        """,
        inputSchema: Schema.object([
            "ids": Schema.array("Reminder ids to delete", items: Schema.string("Reminder id")),
            "filter": Schema.freeObject(
                "Query describing what to delete: {list, listId, status, dueBefore, dueAfter, search}"),
            "expectedCount": Schema.integer(
                "Required with `filter`: the number the preview reported."),
            "confirmDelete": Schema.boolean("Must be true to actually delete. Omit to preview."),
            "stopOnError": Schema.boolean("Halt at the first failure rather than continuing (default false)")
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)

            let resolved = try BatchTarget.resolve(args, ek, cap: bulkMaxItems)
            if let preview = try BatchTarget.filterGate(args, resolved, verb: "deleted") {
                return preview
            }

            guard args.bool("confirmDelete") == true else {
                return [
                    "deleted": false,
                    "wouldDelete": resolved.reminders.map { BatchTarget.preview($0) },
                    "notFound": resolved.notFound,
                    "count": resolved.reminders.count,
                    "message": "Nothing was deleted. Re-call with confirmDelete: true to remove these "
                        + "\(resolved.reminders.count) reminder(s). This syncs to iCloud and cannot be "
                        + "undone. If the tasks are simply done, reminders_bulk_update with "
                        + "completed:true is reversible."
                ]
            }

            let stopOnError = args.bool("stopOnError") == true
            var results: [JSONObject] = resolved.notFound.map {
                ["id": $0, "ok": false, "error": "No reminder with this id."]
            }
            var deleted = 0
            var failed = resolved.notFound.count
            var halted = false

            for reminder in resolved.reminders {
                let id = reminder.calendarItemIdentifier
                let title = reminder.title ?? ""
                if halted {
                    results.append(["id": id, "ok": false, "skipped": true,
                                    "error": "Not attempted — stopOnError halted the batch."])
                    continue
                }
                do {
                    try ek.store.remove(reminder, commit: true)
                    deleted += 1
                    results.append(["id": id, "ok": true, "title": title])
                } catch {
                    failed += 1
                    results.append(["id": id, "ok": false, "title": title,
                                    "error": error.localizedDescription])
                    if stopOnError { halted = true }
                }
            }

            var out: JSONObject = [
                "deleted": deleted,
                "failed": failed,
                "total": resolved.reminders.count + resolved.notFound.count,
                "results": results
            ]
            if halted { out["haltedOnError"] = true }
            if failed > 0 {
                out["message"] = "Deleted \(deleted) of \(out["total"] ?? 0); \(failed) failed or "
                    + "were not found. `results` carries the per-id outcome."
            }
            return out
        }
    )

    // MARK: reminders_route

    private static let routeTool = Tool(
        name: "reminders_route",
        description: """
        File everything sitting in your capture list into the right lists, using a LOCAL model and \
        your own library as the examples. Nothing leaves the machine.

        Two things happen every run, in this order. First it RECONCILES: for every reminder it \
        previously moved, it compares the current list, due date and title against what it recorded \
        at the time. Anything you changed since is a correction — that reminder is pinned and never \
        touched again, and a routing correction is kept as a training example so the same mistake \
        is not repeated. Then it ROUTES what is left.

        A move only happens when the model, asked three times, names the same list every time. \
        Otherwise the reminder stays where it is with the vote reported and is marked low priority \
        (shown as `!` in Reminders.app), because a reminder left in your inbox is one you were already going to see, while a \
        misfiled one is one you have to go hunting for.

        `dryRun` defaults TRUE. It proposes and reconciles but moves nothing.
        """,
        inputSchema: Schema.object([
            "dryRun": Schema.boolean("Propose without moving anything (default true)"),
            "from": Schema.string("Capture list to drain (default Inbox)"),
            "marginThreshold": Schema.number("Deprecated — confidence is now unanimity across 3 samples, not a probability gap."),
            "limit": Schema.integer("Maximum reminders to consider in one run (default 25)"),
            "excludeLists": Schema.array("Lists that are never routing destinations, besides the capture list (default none)",
                                         items: Schema.string("List name"))
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            let source = args.string("from") ?? "Inbox"
            let dryRun = args.bool("dryRun") ?? true
            let margin = args.double("marginThreshold") ?? Router.defaultMargin
            let limit = args.int("limit") ?? 25
            let excluded = Set((args.array("excludeLists")?.compactMap { $0 as? String })
                               ?? [])

            let all = ek.fetchReminders(ek.store.predicateForReminders(in: nil))

            // Reconcile FIRST. Routing before reconciling would re-decide a
            // reminder the user corrected five minutes ago.
            var state = OrganizerState.load()
            let divergences = state.reconcile(against: all)

            guard let sourceCal = ek.reminderList(id: nil, name: source) else {
                throw ToolError("Capture list `\(source)` not found.")
            }
            let destinations = ek.reminderCalendars()
                .map { $0.title }
                .filter { $0 != source && !excluded.contains($0) }
                .sorted()
            guard !destinations.isEmpty else {
                throw ToolError("No destination lists (everything is either the source or excluded).")
            }

            let pending = all
                .filter { !$0.isCompleted }
                .filter { $0.calendar?.calendarIdentifier == sourceCal.calendarIdentifier }
                .filter { !state.isPinned($0.calendarItemIdentifier) }
                // Already held and unchanged: re-asking costs a model call for the
                // same answer. A hold IS an answer until the reminder changes.
                .filter { !state.alreadyHeld($0.calendarItemIdentifier, title: $0.title ?? "") }
                .prefix(limit)

            // Excludes the capture list and every non-destination, so the
            // router cannot learn to file things back where they came from.
            let base = Router.baseExamples(from: all,
                                           excluding: excluded.union([source]))
            var moved: [JSONObject] = []
            var held: [JSONObject] = []
            var failed: [JSONObject] = []

            for reminder in pending {
                let title = reminder.title ?? ""
                guard !title.isEmpty else { continue }
                let examples = base + Router.correctionExamples(state, for: title)
                do {
                    let v = try Router.classifyByVote(title: title, lists: destinations,
                                                      examples: examples)
                    let runnerUp = v.tally.filter { $0.key != v.winner }
                        .max(by: { $0.value < $1.value })?.key
                    let row: JSONObject = [
                        "id": reminder.calendarItemIdentifier, "title": title,
                        "list": v.winner, "votes": "\(v.agreed)/\(v.total)",
                        "runnerUp": runnerUp ?? ""
                    ]
                    guard v.unanimous else {
                        var marked = false
                        if !dryRun {
                            if reminder.priority == 0 {
                                reminder.priority = 9
                                if (try? ek.store.save(reminder, commit: true)) != nil { marked = true }
                            }
                            state.claims[reminder.calendarItemIdentifier] = OrganizerState.Claim(
                                routedTo: nil, proposedList: v.winner, capturedIn: source,
                                markedLowPriority: marked, dueSetTo: nil,
                                titleHash: OrganizerState.hash(title),
                                at: OrganizerState.iso(Date()),
                                confidence: Double(v.agreed) / Double(v.total), runnerUp: runnerUp)
                        }
                        var h = row
                        h["marked"] = marked
                        let spread = v.tally.sorted { $0.value > $1.value }
                            .map { "\($0.key) x\($0.value)" }
                            .joined(separator: ", ")
                        h["reason"] = "the model did not agree with itself across "
                            + "\(v.total) samples (\(spread))"
                        held.append(h)
                        continue
                    }
                    if !dryRun {
                        guard let target = ek.reminderList(id: nil, name: v.winner) else {
                            throw ToolError("Destination `\(v.winner)` vanished mid-run.")
                        }
                        reminder.calendar = target
                        try ek.store.save(reminder, commit: true)
                        state.claims[reminder.calendarItemIdentifier] = OrganizerState.Claim(
                            routedTo: v.winner, proposedList: nil, capturedIn: nil,
                            markedLowPriority: false, dueSetTo: nil,
                            titleHash: OrganizerState.hash(title),
                            at: OrganizerState.iso(Date()),
                            confidence: Double(v.agreed) / Double(v.total), runnerUp: runnerUp)
                    }
                    moved.append(row)
                } catch let e as ToolError {
                    failed.append(["title": title, "error": e.message])
                } catch {
                    failed.append(["title": title, "error": error.localizedDescription])
                }
            }

            // Saved even on a dry run: reconciliation results are real
            // observations about what you changed, and losing them would mean
            // re-detecting the same correction forever.
            try? state.save()

            var out: JSONObject = [
                "dryRun": dryRun,
                "from": source,
                "destinations": destinations,
                "considered": pending.count,
                "routed": moved.count,
                "held": held.count,
                "corrections": divergences.map { d -> JSONObject in
                    ["kind": d.kind, "detail": d.detail]
                },
                "proposals": moved,
                "heldBack": held
            ]
            if !failed.isEmpty { out["failed"] = failed }
            out["learned"] = state.corrections.count
            if dryRun && !moved.isEmpty {
                out["message"] = "Nothing was moved. Re-run with dryRun:false to apply "
                    + "\(moved.count) move(s)."
            }
            return out
        }
    )

    // MARK: reminders_schedule

    private static let scheduleTool = Tool(
        name: "reminders_schedule",
        description: """
        Lay undated and overdue reminders into the days ahead, around what is already on your \
        calendar. Entirely local and entirely deterministic — no model is involved.

        Windows are local wall-clock: a work window on days an event exists on the work-flag \
        calendar (its presence is the flag, its duration is ignored — no event means the day was \
        taken off), plus morning and evening windows for personal lists. Events on protected \
        calendars, or whose title contains a protected word, subtract from those windows. Hours, \
        calendars and lists come from the operator's schedule.json; with none, stock defaults \
        apply (work 09:00-17:00 on a `Work` calendar, `Work` and `Personal` lists).

        It will not overfill. If nine work items do not fit this week they come back as `unplaced` \
        rather than being packed in at twenty-minute intervals, because a plan nobody can follow is \
        worse than an honest shortfall.

        `dryRun` defaults TRUE. Applying writes real due dates, which fire notifications — set \
        `writeDue:false` to plan without them. Anything you have already rescheduled yourself is \
        pinned and left alone.
        """,
        inputSchema: Schema.object([
            "dryRun": Schema.boolean("Plan without writing due dates (default true)"),
            "days": Schema.integer("How many days ahead to plan (default 7)"),
            "slotMinutes": Schema.integer("Minutes reserved per reminder (default 30)"),
            "writeDue": Schema.boolean("Write the planned time as the due date (default true)"),
            "limit": Schema.integer("Maximum reminders to place (default 40)")
        ]),
        handler: { args in
            try ek.ensureAccess(.reminder)
            try ek.ensureAccess(.event)
            let dryRun = args.bool("dryRun") ?? true
            let days = max(1, args.int("days") ?? 7)
            let writeDue = args.bool("writeDue") ?? true
            var policy = Scheduler.Policy.load()
            if let m = args.int("slotMinutes") { policy.slotMinutes = max(5, m) }
            let limit = args.int("limit") ?? 40

            var state = OrganizerState.load()
            let all = ek.fetchReminders(ek.store.predicateForReminders(in: nil))
            let divergences = state.reconcile(against: all)

            func due(_ r: EKReminder) -> Date? {
                r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
            }
            let now = Date()
            // Undated first, then overdue. Something already scheduled for a
            // sensible future time is left alone -- re-slotting it every run is
            // the churn that makes these tools untrustworthy.
            let candidates = all
                .filter { !$0.isCompleted }
                .filter { !state.isPinned($0.calendarItemIdentifier) }
                .filter { r in
                    let list = r.calendar?.title ?? ""
                    return !policy.excludedLists.contains(list)
                        && (policy.workLists.contains(list) || policy.personalLists.contains(list))
                }
                .filter { due($0) == nil || due($0)! < now }
                .prefix(limit)

            var workQueue = candidates
                .filter { policy.workLists.contains($0.calendar?.title ?? "") }
                .map { (id: $0.calendarItemIdentifier, title: $0.title ?? "", list: $0.calendar?.title ?? "") }
            var personalQueue = candidates
                .filter { policy.personalLists.contains($0.calendar?.title ?? "") }
                .map { (id: $0.calendarItemIdentifier, title: $0.title ?? "", list: $0.calendar?.title ?? "") }

            let cal = Calendar.current
            let horizonEnd = cal.date(byAdding: .day, value: days, to: now) ?? now
            // From the START of today, not from `now`. Fetching from the current
            // moment loses this morning's events, and a day whose work block has
            // already ended then looks like a day off. Placement still refuses
            // the past -- that is `fill(after:)`'s job, not the fetch's.
            let horizonStart = cal.startOfDay(for: now)
            let events = ek.store.events(matching:
                ek.store.predicateForEvents(withStart: horizonStart, end: horizonEnd, calendars: nil))

            var plan: [JSONObject] = []
            var placedSlots: [Scheduler.Slot] = []
            var dayReports: [JSONObject] = []
            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
            let human = DateFormatter()
            human.dateFormat = "EEE MM-dd HH:mm"; human.timeZone = .current

            for offset in 0..<days {
                guard let day = cal.date(byAdding: .day, value: offset, to: now) else { continue }
                let w = Scheduler.windows(for: day, events: events, policy: policy)
                let (workPlaced, workLeft) = Scheduler.fill(
                    w.work, with: workQueue, slotMinutes: policy.slotMinutes, after: now)
                workQueue = workLeft
                let (personalPlaced, personalLeft) = Scheduler.fill(
                    w.personal, with: personalQueue, slotMinutes: policy.slotMinutes, after: now)
                personalQueue = personalLeft
                placedSlots += workPlaced + personalPlaced
                // Report only time that is still ahead. A window that closed
                // this morning is not capacity, and counting it makes today look
                // roomier than it is.
                func remaining(_ intervals: [Scheduler.Interval]) -> Int {
                    intervals.reduce(0) { total, i in
                        let start = max(i.start, now)
                        guard start < i.end else { return total }
                        return total + Int(i.end.timeIntervalSince(start) / 60)
                    }
                }
                dayReports.append([
                    "day": human.string(from: day).prefix(9).description,
                    "workDay": w.isWorkDay,
                    "workFreeMinutes": remaining(w.work),
                    "personalFreeMinutes": remaining(w.personal),
                    "placed": workPlaced.count + personalPlaced.count
                ])
            }

            for slot in placedSlots.sorted(by: { $0.start < $1.start }) {
                plan.append(["id": slot.reminderId, "title": slot.title, "list": slot.list,
                             "at": human.string(from: slot.start), "iso": iso.string(from: slot.start)])
                guard !dryRun, writeDue else { continue }
                if let reminder = try? ek.reminder(byId: slot.reminderId) {
                    reminder.dueDateComponents = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: slot.start)
                    if (try? ek.store.save(reminder, commit: true)) != nil {
                        var claim = state.claims[slot.reminderId]
                            ?? OrganizerState.Claim(routedTo: nil, proposedList: nil,
                                                    capturedIn: nil, markedLowPriority: false,
                                                    dueSetTo: nil,
                                                    titleHash: OrganizerState.hash(slot.title),
                                                    at: OrganizerState.iso(Date()),
                                                    confidence: nil, runnerUp: nil)
                        claim.dueSetTo = OrganizerState.iso(slot.start)
                        claim.at = OrganizerState.iso(Date())
                        state.claims[slot.reminderId] = claim
                    }
                }
            }
            try? state.save()

            var out: JSONObject = [
                "dryRun": dryRun,
                "writeDue": writeDue,
                "slotMinutes": policy.slotMinutes,
                "considered": candidates.count,
                "placed": plan.count,
                "days": dayReports,
                "plan": plan,
                "corrections": divergences.map { ["kind": $0.kind, "detail": $0.detail] }
            ]
            let unplaced = workQueue + personalQueue
            if !unplaced.isEmpty {
                out["unplaced"] = unplaced.map { ["title": $0.title, "list": $0.list] }
                out["message"] = "\(plan.count) placed, \(unplaced.count) did not fit in \(days) day(s). "
                    + "They are reported rather than packed in — widen the horizon or drop some."
            }
            return out
        }
    )

    // MARK: - Shared field application

    private static func applyReminderFields(_ reminder: EKReminder, _ args: JSONObject) throws {
        if let notes = args.string("notes") { reminder.notes = notes }
        if let urlStr = args.string("url"), let url = URL(string: urlStr) { reminder.url = url }
        if let priority = Priority.fromInput(args["priority"]) { reminder.priority = priority }
        if let dueStr = args.string("due") {
            guard let comps = DateParse.dueComponents(dueStr) else {
                throw ToolError("Could not parse `due`: \(dueStr)")
            }
            reminder.dueDateComponents = comps
        }
        if let recurrence = args.object("recurrence") {
            reminder.recurrenceRules = [try Recurrence.rule(from: recurrence)]
        }
        if let alarmArray = args.array("alarms") {
            reminder.alarms = nil
            for alarm in Alarms.build(from: alarmArray) { reminder.addAlarm(alarm) }
        }
    }

    /// Why a reminder reads as context-free, or nil when it is fine.
    ///
    /// Conservative on purpose: it fires only when EVERY channel that could
    /// carry meaning is empty — no notes, no due date — and the title itself
    /// does not stand alone. An item like "Milk" with a note saying
    /// what it is for is not vague; the same word with nothing attached is.
    static func vagueReason(_ r: EKReminder) -> String? {
        let title = (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNotes = !(r.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDue = r.dueDateComponents != nil
        guard !hasNotes, !hasDue else { return nil }

        if title.isEmpty { return "empty title" }
        let words = title.split(whereSeparator: { $0 == " " }).count
        // "3 boxes", "12 large" -- a count with no object.
        if let first = title.split(separator: " ").first, Int(first) != nil {
            return "starts with a bare quantity and carries no notes or due date, "
                + "so what is being counted is not recorded anywhere"
        }
        if words <= 2 {
            return "\(words)-word title with no notes and no due date — not enough to act on later"
        }
        return nil
    }

    private static func dueDate(_ r: EKReminder) -> Date? {
        r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }
}

/// Parse "#RRGGBB" into a CGColor.
func colorFromHex(_ hex: String) -> CGColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: 1.0)
}
