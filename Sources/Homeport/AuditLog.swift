import Foundation

/// A durable record of every tool call, on every transport.
///
/// `Log` writes diagnostics to stderr, whose destination depends entirely on how
/// the process was launched — a launchd `StandardErrorPath`, an MCP client's
/// pipe, or nowhere. And it recorded tool calls only for HTTP, so the transport
/// with no scope enforcement was also the transport with no history. After an
/// incident there was no way to answer "was a message sent, to whom, and did it
/// actually go out."
///
/// **What is deliberately NOT written here.** No message bodies, note contents,
/// transcripts, contact values or tool results. This file answers *who did what
/// to which record*, never *what it said*. Content already lives in the app that
/// owns it — Messages, Notes — so duplicating it into a flat file would create a
/// second, less protected copy of the most sensitive data on the machine. Body
/// length is recorded because size is occasionally the tell and it leaks
/// nothing.
///
/// One JSON object per line, so it greps as text and parses as data.
enum AuditLog {

    private static let maxBytes = 5 * 1024 * 1024
    private static let generations = 5
    private static let lock = NSLock()
    private static var warned = false

    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/homeport-audit.log")

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Append one entry. Never throws: an audit failure must not take down a
    /// tool call, but it warns once so a broken log is not silently permanent.
    static func record(tool: String,
                       caller: String?,
                       transport: String,
                       outcome: String,
                       ms: Int,
                       detail: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "ts": stamp.string(from: Date()),
            "transport": transport,
            "caller": caller ?? "local",
            "tool": tool,
            "outcome": outcome,
            "ms": ms
        ]
        for (k, v) in detail { entry[k] = v }

        guard let data = try? JSONSerialization.data(withJSONObject: entry,
                                                     options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)

        lock.lock(); defer { lock.unlock() }
        do {
            try rotateIfNeeded()
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            if !warned {
                warned = true
                Log.warn("audit: cannot write \(url.path) — \(error.localizedDescription)")
            }
        }
    }

    /// Size-based rotation: `.log` -> `.log.1` -> ... -> `.log.5`, oldest dropped.
    ///
    /// Size rather than date because the write rate here is driven by how much
    /// the bridge is used, not by the calendar — a daily file would be empty for
    /// weeks and then truncate a busy afternoon.
    private static func rotateIfNeeded() throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size >= maxBytes else { return }

        let oldest = url.appendingPathExtension("\(generations)")
        if fm.fileExists(atPath: oldest.path) { try? fm.removeItem(at: oldest) }

        var n = generations - 1
        while n >= 1 {
            let from = url.appendingPathExtension("\(n)")
            let to = url.appendingPathExtension("\(n + 1)")
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
            n -= 1
        }
        try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
    }

    /// The non-sensitive fields worth keeping for a given call.
    ///
    /// An allowlist per tool, not a blanket dump of `args`: every tool that
    /// carries content carries it in a differently-named field, so a denylist
    /// would leak the first time someone adds a parameter.
    static func detail(tool: String, args: JSONObject) -> [String: Any] {
        switch tool {
        case "messages_send":
            var d: [String: Any] = ["confirmed": args.bool("confirmSend") == true]
            if let to = args.string("to") { d["to"] = Auth.normalizeHandle(to) }
            if let body = args.string("body") { d["bodyChars"] = body.count }
            return d

        case "contacts_update":
            var d: [String: Any] = [:]
            if let id = args.string("id") { d["contact"] = id }
            let edits = ["addPhones", "removePhones", "setPhones",
                         "addEmails", "removeEmails", "setEmails",
                         "addUrls", "removeUrls", "setUrls"].filter { args.array($0) != nil }
            if !edits.isEmpty { d["edits"] = edits.sorted() }
            if args.bool("confirmReplace") == true { d["confirmed"] = true }
            return d

        case "reminders_bulk_delete", "reminders_bulk_update":
            // The batches that can touch a hundred records in one call. What
            // matters afterwards is how the target was chosen -- an explicit id
            // list is a decision someone made, a filter is one the server
            // resolved -- and whether the gates were actually cleared. Filter
            // KEYS are recorded, never the search string, which is user content.
            var d: [String: Any] = [:]
            if let ids = args.array("ids") { d["idCount"] = ids.count }
            if let filter = args.object("filter") {
                d["targetedBy"] = "filter"
                d["filterKeys"] = filter.keys.sorted()
                if let list = filter.string("list") { d["filterList"] = list }
                if let status = filter.string("status") { d["filterStatus"] = status }
            } else {
                d["targetedBy"] = "ids"
            }
            if let expected = args.int("expectedCount") { d["expectedCount"] = expected }
            if tool == "reminders_bulk_delete" { d["confirmed"] = args.bool("confirmDelete") == true }
            if tool == "reminders_bulk_update" {
                d["fields"] = ReminderTools.bulkUpdateFields.filter { args[$0] != nil }.sorted()
            }
            if args.bool("stopOnError") == true { d["stopOnError"] = true }
            return d

        case "reminders_lists":
            // Only the destructive shapes are worth a line. merge deletes a
            // list, which is the one action here that can take reminders with it.
            let action = args.string("action") ?? "list"
            guard ["create", "rename", "merge", "delete"].contains(action) else { return [:] }
            var d: [String: Any] = ["action": action]
            for key in ["name", "list", "listId", "from", "into"] {
                if let v = args.string(key) { d[key] = v }
            }
            if action == "merge" { d["confirmed"] = args.bool("confirmMerge") == true }
            return d

        case "reminders_bulk_create":
            // Size and target, never the titles. A batch is the one write that
            // can put fifty rows somewhere in a single call, so how many and
            // where is exactly the fact worth keeping; the content itself lives
            // in Reminders, which is the right place for it.
            var d: [String: Any] = ["itemCount": args.array("items")?.count ?? 0]
            if let list = args.string("list") { d["list"] = list }
            if let listId = args.string("listId") { d["listId"] = listId }
            if args.bool("stopOnError") == true { d["stopOnError"] = true }
            return d

        case "contacts_delete", "contacts_merge",
             "reminders_delete", "calendar_delete_event", "notes_append":
            var d: [String: Any] = [:]
            for key in ["id", "keepId", "deleteId", "folder"] {
                if let v = args.string(key) { d[key] = v }
            }
            return d

        default:
            return [:]
        }
    }
}
