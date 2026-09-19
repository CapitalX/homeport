import Foundation

/// Read protection for named Notes folders.
///
/// A configured folder can keep accepting WRITES (from an automation, say)
/// while its contents are never handed to a client. This is a
/// guardrail, not a security boundary: anything running as this user can open
/// Notes.app or read the CoreData store directly, and anything that can edit
/// policy.json can lift the gate. What it buys is that no AI client — local or
/// remote — pulls that content into a context window by accident.
///
/// Enforced on EVERY transport. `Auth` only runs for HTTP
/// (`StdioTransport` never calls it), so this deliberately lives at the shared
/// chokepoint in `MCPServer.handleToolCall` instead. Because the rule is
/// unconditional it needs no caller identity, which is what makes that
/// placement possible at all.
///
/// **Protection is the union of two rules, and both are load-bearing:**
///
/// - **By id** — survives a note being moved or deleted. A deleted note
///   reappears under "Recently Deleted" with a different folder name, where a
///   name-only rule would stop matching it for the 30 days before it purges.
/// - **By the folder on the result** — catches a note the external service
///   wrote since the last refresh, closing the window a pure id set would leave
///   open.
///
/// Neither alone is sufficient; together they fail safe in both directions.
enum NoteGuard {

    /// Rebuilt lazily. Short enough that an externally-added note is picked up
    /// quickly, long enough that a burst of queries does not re-enumerate Notes
    /// on every call — that enumeration is an AppleScript round trip.
    private static let ttl: TimeInterval = 60

    private static var protectedIds = Set<String>()
    private static var builtAt: Date?
    private static var lastBuildFailed = false
    private static let lock = NSLock()

    static var blockedFolders: [String] { Auth.policy().readBlockedNoteFolders }
    static var isActive: Bool { !blockedFolders.isEmpty }

    // MARK: - The protected set

    /// Note ids currently living in a blocked folder.
    ///
    /// Fails CLOSED: if the set cannot be built, every note is treated as
    /// protected. A guard that silently opens up when Notes is unreachable
    /// would be worse than no guard, because it fails at exactly the moment
    /// nobody is watching.
    private static func ensureFresh() {
        lock.lock(); defer { lock.unlock() }
        if let builtAt, Date().timeIntervalSince(builtAt) < ttl, !lastBuildFailed { return }
        guard isActive else { protectedIds = []; builtAt = Date(); lastBuildFailed = false; return }

        var ids = Set<String>()
        var failed = false
        for folder in blockedFolders {
            do {
                // ids only -- search() would read every note's plaintext to
                // build snippets we immediately discard, which is slow enough
                // to hit the AppleScript timeout on a large folder.
                for id in try NotesStore.noteIds(inFolder: folder) { ids.insert(id) }
            } catch {
                // A folder that simply does not exist is not a failure.
                if "\(error)".contains("No folder named") { continue }
                Log.warn("noteguard: could not enumerate \(folder): \(error); failing closed")
                failed = true
            }
        }
        // Keep anything already registered — a note created a moment ago must
        // not lose protection because a later refresh partially failed.
        protectedIds.formUnion(ids)
        if !failed { protectedIds = protectedIds.union(ids) }
        builtAt = Date()
        lastBuildFailed = failed
    }

    /// Build the protected set ahead of the first request.
    static func warm() {
        guard isActive else { return }
        ensureFresh()
        lock.lock(); let n = protectedIds.count; lock.unlock()
        Log.info("noteguard: protecting \(n) note(s) in \(blockedFolders.joined(separator: ", "))")
    }

    /// Protect a note the instant it is created, without waiting for a refresh.
    /// This is what closes the create-then-read pivot: `notes_create` returns an
    /// id that is immediately a valid `notes_read` key.
    static func register(id: String) {
        lock.lock(); defer { lock.unlock() }
        protectedIds.insert(id)
    }

    static func isBlocked(folder: String?) -> Bool {
        guard let folder else { return false }
        return blockedFolders.contains(folder)
    }

    static func isProtected(id: String?) -> Bool {
        guard isActive, let id else { return false }
        ensureFresh()
        lock.lock(); defer { lock.unlock() }
        if lastBuildFailed { return true }   // fail closed
        return protectedIds.contains(id)
    }

    /// True when a result should be withheld, by either rule.
    static func isProtected(id: String?, folder: String?) -> Bool {
        isBlocked(folder: folder) || isProtected(id: id)
    }

    // MARK: - Response filtering

    /// Scrub a tool result before it reaches the wire.
    ///
    /// Applied at the single chokepoint in `MCPServer.handleToolCall`, AND on
    /// the idempotency replay path — a replay returns a cached value without
    /// ever entering the handler, so a filter placed only after the handler
    /// would be skipped exactly when a stale blocked-folder body is served.
    static func filter(tool: String, args: JSONObject, value: Any) -> Any {
        guard isActive else { return value }
        guard var out = value as? JSONObject else { return value }

        switch tool {
        case "notes_query":
            guard let notes = out["notes"] as? [JSONObject] else { return out }
            let kept = notes.filter { !isProtected(id: $0.string("id"), folder: $0.string("folder")) }
            let removed = notes.count - kept.count
            out["notes"] = kept
            out["count"] = kept.count
            if removed > 0 {
                // Say so rather than quietly returning fewer results, which
                // would look like the notes do not exist.
                out["suppressed"] = removed
                out["suppressedReason"] = "\(removed) note(s) withheld: "
                    + "\(blockedFolders.joined(separator: ", ")) is read-blocked by policy."
            }

        case "notes_read":
            // The folder is only known after the AppleScript has run, so this
            // can only ever be a post-filter -- the body has already been read
            // into memory; what matters is that it does not leave.
            if isProtected(id: out.string("id"), folder: out.string("folder")) {
                let folder = out.string("folder") ?? "a read-blocked folder"
                return [
                    "denied": true,
                    "id": out.string("id") ?? "",
                    "folder": folder,
                    "message": "Reading notes in \(folder) is blocked by policy. "
                        + "Writing to it is still allowed."
                ] as JSONObject
            }

        case "notes_folders":
            guard let folders = out["folders"] as? [JSONObject] else { return out }
            out["folders"] = folders.map { f -> JSONObject in
                var f = f
                if isBlocked(folder: f.string("folder")) {
                    f["readable"] = false
                    f["note"] = "Read-blocked by policy. Writes are allowed."
                }
                return f
            }

        case "notes_create":
            // Register before the id is ever returned.
            if let created = out["created"] as? JSONObject,
               isBlocked(folder: created.string("folder") ?? args.string("folder")),
               let id = created.string("id") {
                register(id: id)
            }

        case "notes_append":
            // append returns no folder, so classification is by id only. The
            // echoed title is the leak: appending by id to a note you may never
            // have been allowed to see would otherwise reveal its title.
            if let note = out["note"] as? JSONObject, isProtected(id: note.string("id")) {
                var scrubbed = note
                scrubbed["title"] = nil
                scrubbed["titleWithheld"] = true
                out["note"] = scrubbed
            }

        case "voicememos_summarize":
            // `confidential` in SummaryTools is CATEGORY-based, so a category
            // filed into a blocked folder would otherwise return its full
            // summary text inline, ungated.
            let target = args.string("folder")
            if let note = out["note"] as? JSONObject,
               isBlocked(folder: note.string("folder") ?? target),
               let id = note.string("id") {
                register(id: id)
            }
            if isBlocked(folder: target) {
                out["summary"] = nil
                out["title"] = nil
                out["withheld"] = "summary and title suppressed: "
                    + "\(target ?? "target folder") is read-blocked by policy."
            }

        default:
            return out
        }
        return out
    }

}
