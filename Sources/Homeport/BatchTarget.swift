import EventKit
import Foundation

/// How a bulk tool decides *which* reminders to act on.
///
/// Two ways in, and exactly one per call:
///
/// - **`ids`** — an explicit list. Unambiguous, and what a caller uses after it
///   has already looked at a query result.
/// - **`filter`** — a description ("everything completed in Inbox"). This is the
///   one that makes restructuring tractable: collecting dozens of ids by hand, only to
///   send them straight back, is a round trip that exists purely because the
///   server could not be told what was meant.
///
/// **A filter is never applied sight-unseen.** `expectedCount` is required, and
/// there is no way to know the right value without previewing first — so the
/// preview is structural rather than a convention someone can skip. It doubles
/// as a race check: reminders sync from other devices continuously, so a set that changed between
/// the preview and the call is a set the caller has not actually seen. That
/// aborts instead of acting on the difference.
enum BatchTarget {

    /// A filter reuses the `reminders_query` vocabulary exactly. One mental
    /// model for reading and for acting, and no second dialect to learn.
    static let filterFields: Set<String> = [
        "list", "listId", "status", "dueBefore", "dueAfter", "search"
    ]

    /// What a resolution produced, before anything has been changed.
    struct Resolved {
        let reminders: [EKReminder]
        /// Ids that matched nothing. Only possible in `ids` mode.
        let notFound: [String]
        let viaFilter: Bool
    }

    /// Nested objects are invisible to `MCPServer.unknownArguments`, so a
    /// filter validates its own keys for the same reason `items[]` does: a
    /// dropped `status` would silently widen the set a destructive call acts on.
    static func validateFilter(_ filter: JSONObject) throws {
        let unknown = filter.keys.filter { !filterFields.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let noun = unknown.count == 1 ? "field" : "fields"
            throw ToolError("filter: unknown \(noun) \(unknown.joined(separator: ", ")). "
                + "Accepted: \(filterFields.sorted().joined(separator: ", ")).")
        }
        guard !filter.isEmpty else {
            throw ToolError("`filter` is empty, which would match every reminder you have. "
                + "Name at least one of: \(filterFields.sorted().joined(separator: ", ")).")
        }
    }

    /// Reminders matching a filter, using the same semantics as
    /// `reminders_query` so a preview there and an action here agree.
    static func matching(_ filter: JSONObject, _ ek: EventKitStore) throws -> [EKReminder] {
        let calendars: [EKCalendar]?
        if let cal = ek.reminderList(id: filter.string("listId"), name: filter.string("list")) {
            calendars = [cal]
        } else if filter.string("list") != nil || filter.string("listId") != nil {
            throw ToolError("filter: requested list not found.")
        } else {
            calendars = nil
        }

        var reminders = ek.fetchReminders(ek.store.predicateForReminders(in: calendars))

        // `status` defaults to "incomplete" in reminders_query. Here it has no
        // default: a bulk action is not the place to guess which half of the
        // library was meant, so an absent status means "both" and the caller has
        // to have said so via expectedCount anyway.
        switch filter.string("status") ?? "all" {
        case "incomplete": reminders = reminders.filter { !$0.isCompleted }
        case "completed":  reminders = reminders.filter { $0.isCompleted }
        case "all":        break
        default:
            throw ToolError("filter: `status` must be incomplete | completed | all.")
        }

        if let raw = filter.string("dueBefore") {
            guard let before = DateParse.date(raw) else {
                throw ToolError("filter: could not parse `dueBefore`: \(raw)")
            }
            reminders = reminders.filter { due($0).map { $0 <= before } ?? false }
        }
        if let raw = filter.string("dueAfter") {
            guard let after = DateParse.date(raw) else {
                throw ToolError("filter: could not parse `dueAfter`: \(raw)")
            }
            reminders = reminders.filter { due($0).map { $0 >= after } ?? false }
        }
        if let search = filter.string("search")?.lowercased(), !search.isEmpty {
            reminders = reminders.filter {
                ($0.title?.lowercased().contains(search) ?? false)
                    || ($0.notes?.lowercased().contains(search) ?? false)
            }
        }
        return reminders
    }

    /// Resolve `ids` or `filter` into concrete reminders, before any mutation.
    ///
    /// Resolution happens up front on purpose: a preview assembled from
    /// half-changed state would be a lie, and a bad id should surface while the
    /// batch is still entirely reversible.
    static func resolve(_ args: JSONObject, _ ek: EventKitStore, cap: Int) throws -> Resolved {
        let rawIds = args.array("ids")
        let filter = args.object("filter")

        if rawIds != nil && filter != nil {
            throw ToolError("Pass either `ids` or `filter`, not both — they would disagree about "
                + "what to act on, and silently picking one is how the wrong records get touched.")
        }

        if let filter {
            try validateFilter(filter)
            let matches = try matching(filter, ek)
            guard matches.count <= cap else {
                throw ToolError("`filter` matches \(matches.count) reminders; the maximum for one "
                    + "batch is \(cap). Narrow it (add `list`, `status`, or a due range), or act on "
                    + "explicit `ids` instead.")
            }
            return Resolved(reminders: matches, notFound: [], viaFilter: true)
        }

        guard let rawIds else {
            throw ToolError("Pass `ids` (an array of reminder ids) or `filter` (a query describing "
                + "what to act on). Received argument keys: "
                + "[\(args.keys.sorted().joined(separator: ", "))]")
        }
        var seen = Set<String>()
        // Duplicates collapse: a second pass over the same id reports a spurious
        // "not found" that reads as a failure when nothing is wrong.
        let ids = rawIds.compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw ToolError("`ids` is empty; there is nothing to act on.") }
        guard ids.count <= cap else {
            throw ToolError("`ids` has \(ids.count) entries; the maximum is \(cap). Split the batch "
                + "— each record is a separate EventKit commit that syncs to iCloud.")
        }

        var found: [EKReminder] = []
        var missing: [String] = []
        for id in ids {
            if let reminder = try? ek.reminder(byId: id) { found.append(reminder) }
            else { missing.append(id) }
        }
        return Resolved(reminders: found, notFound: missing, viaFilter: false)
    }

    /// The gate that makes a filtered batch impossible to fire blind.
    ///
    /// Returns a preview payload when the caller has not yet supplied a matching
    /// `expectedCount`, and nil when it is cleared to proceed.
    static func filterGate(_ args: JSONObject, _ resolved: Resolved,
                           verb: String) throws -> JSONObject? {
        guard resolved.viaFilter else { return nil }
        let actual = resolved.reminders.count
        guard let expected = args.int("expectedCount") else {
            return [
                "previewOnly": true,
                "matched": actual,
                "wouldAffect": resolved.reminders.map { preview($0) },
                "message": "Nothing was \(verb). `filter` matched \(actual) reminder(s), listed "
                    + "above. To proceed, re-send the same filter with expectedCount: \(actual). "
                    + "That value cannot be guessed without seeing this preview, which is the point."
            ]
        }
        guard expected == actual else {
            throw ToolError("`expectedCount` is \(expected) but the filter now matches \(actual). "
                + "The set changed since you previewed it — reminders sync from other devices "
                + "continuously. Re-run without expectedCount to see the current set.")
        }
        return nil
    }

    /// One reminder, as it appears in a preview.
    static func preview(_ r: EKReminder) -> JSONObject {
        var o: JSONObject = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "list": r.calendar?.title ?? "",
            "completed": r.isCompleted
        ]
        if let d = due(r) { o["due"] = ISO8601DateFormatter().string(from: d) }
        return o
    }

    private static func due(_ r: EKReminder) -> Date? {
        r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
    }
}
