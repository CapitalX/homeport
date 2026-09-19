import Foundation

/// Apple Notes access.
///
/// Unlike Calendar/Reminders/Contacts there is no EventKit-style framework for
/// Notes, so this drives the app over Apple Events. We use `NSAppleScript`
/// in-process rather than shelling out to `osascript` on purpose: the TCC grant
/// then attaches to THIS binary (which the disclaim shim has already made the
/// responsible process), keeping the server's one-identity permission story.
/// Shelling out would attribute automation to `osascript` instead and fragment
/// the grant across hosts.
enum NotesStore {

    /// Apple Events failures are opaque by default (`-1743` is just "not
    /// authorized"), so translate the ones users actually hit.
    /// Run an Apple Event against Notes.
    ///
    /// `retryOnTimeout` is opt-in and must ONLY be set for reads. A
    /// notes_query immediately followed by a notes_read fails with -1712 about
    /// one time in three -- Notes does not reliably accept a second script right
    /// after the first -- and retrying a read is free because it is idempotent.
    /// Retrying a CREATE on a timeout would risk writing the note twice, since a
    /// timed-out write may well have landed. That is the whole reason
    /// idempotencyKey exists, and it is not something to paper over here.
    /// Serialises Apple Events to Notes against each other — and ONLY against
    /// each other.
    ///
    /// These calls used to be ordered by the one shared dispatch queue, which
    /// also orders every EventKit read. That coupling is what made a slow Notes
    /// call a whole-service outage: the first event after a daemon start times
    /// out at 45s and retries twice, so warming Notes blocked reminder and
    /// calendar queries for up to three minutes even though they touch a
    /// completely different subsystem. Notes needs to be serial with Notes;
    /// it has no business serialising with EventKit.
    private static let appleEventLock = NSLock()

    private static func run(_ source: String, retryOnTimeout: Bool = false) throws -> NSAppleEventDescriptor {
        appleEventLock.lock(); defer { appleEventLock.unlock() }
        do {
            return try runOnce(source)
        } catch let error as ToolError where retryOnTimeout && error.message.contains("Timed out") {
            // Reads are idempotent, so retrying costs nothing but time. Writes
            // deliberately never reach here: retrying a create after a timeout
            // is the duplication risk idempotencyKey exists to prevent.
            Log.warn("notes: timed out, retrying (read is idempotent)")
            for attempt in 1...2 {
                Thread.sleep(forTimeInterval: 0.5 * Double(attempt))
                if let ok = try? runOnce(source) { return ok }
            }
            throw error
        }
    }

    /// Notes does not reliably accept a second Apple Event fired immediately
    /// after the previous one returns -- it fails -1712 about one time in three
    /// under back-to-back calls. Waiting out a 45s timeout and retrying is a
    /// very expensive way to discover that, so keep a minimum gap between
    /// scripts instead. Everything here is serialized on one queue already, so
    /// this costs at most 150ms on consecutive Notes calls and nothing at all
    /// on an isolated one.
    private static var lastCallEnded: Date?
    private static let minimumGap: TimeInterval = 0.15

    private static func runOnce(_ source: String) throws -> NSAppleEventDescriptor {
        if let last = lastCallEnded {
            let since = Date().timeIntervalSince(last)
            if since < minimumGap { Thread.sleep(forTimeInterval: minimumGap - since) }
        }
        defer { lastCallEnded = Date() }
        // Bound every Apple Event to Notes.
        //
        // NSAppleScript blocks the calling thread until the event returns, and
        // the HTTP transport runs every tool call on ONE serial queue -- so a
        // Notes call that never comes back wedges the whole daemon for every
        // device, not just its own request. This is not hypothetical: the first
        // notes_folders after a reboot has to launch Notes.app and exceeded a
        // 120s client timeout, while the same call takes ~1.2s once Notes is
        // running. AppleScript's own default is two minutes; 45s is generous
        // enough for a cold launch and bounded enough to fail loudly instead.
        let bounded = """
        with timeout of 45 seconds
        \(source)
        end timeout
        """
        guard let script = NSAppleScript(source: bounded) else {
            throw ToolError("Could not compile the Notes script.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard let error else { return result }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
        switch code {
        case -1743:
            throw ToolError(
                "Not authorized to control Notes. Approve it in System Settings > Privacy & Security > " +
                "Automation, under this binary, then retry.")
        case -600, -609:
            throw ToolError("Notes is not running and could not be launched.")
        case -1712:
            throw ToolError(
                "Timed out talking to Notes after 45s. If this is the first call since a reboot, "
                + "Notes.app was still launching -- retry once. If it keeps timing out, open "
                + "Notes.app manually and check it is not stuck on a sync or upgrade prompt.")
        default:
            throw ToolError("Notes scripting failed (\(code)): \(message)")
        }
    }

    /// Escapes a Swift string for embedding in an AppleScript string literal.
    /// Notes bodies are user text and routinely contain quotes and apostrophes;
    /// without this a single `"` silently truncates the script.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// Records are returned as newline-separated fields with a sentinel
    /// separator, which survives titles containing commas far better than
    /// AppleScript's own list coercion.
    private static let separator = "\u{001F}"
    private static let recordSeparator = "\u{001E}"

    private static func split(_ descriptor: NSAppleEventDescriptor) -> [[String]] {
        guard let raw = descriptor.stringValue, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: recordSeparator)
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: separator) }
    }

    // MARK: - Reads

    /// Search notes and return METADATA ONLY — never bodies.
    ///
    /// Bodies are the whole problem: one account can hold megabytes of HTML, and
    /// returning it would swamp a response for no benefit. Callers get ids plus
    /// a short snippet, then fetch the one note they want with `body(id:)`.
    ///
    /// Two things keep this from timing out on a large library:
    ///
    /// - Title search uses AppleScript's `whose` clause, which Notes evaluates
    ///   internally. Reading `plaintext of n` for every note to match in Swift
    ///   meant the cost scaled with the whole library and blew the 45s timeout.
    ///   Body search still requires that full scan, so it is opt-in via
    ///   `searchBody` rather than the silent default it used to be.
    /// - Both loops `exit repeat` once `limit` is reached. Previously the guard
    ///   only stopped *collecting*, so iteration continued over every remaining
    ///   note and a small `limit` was no cheaper than a large one.
    static func search(query: String?, folder: String?, limit: Int, searchBody: Bool) throws -> [JSONObject] {
        // PARENTHESES ARE LOad-BEARING. Written as
        // `folders whose name is "X" of acct`, AppleScript parses the `of acct`
        // as belonging to the STRING -- `name is ("X" of acct)` -- and fails
        // with -1723 "Can't get \"X\" of acct. Access not allowed.", which reads
        // like a permissions problem and is not one. The collection has to be
        // bound first: `(folders of acct) whose name is "X"`.
        let folderFilter = folder.map { "(folders of acct) whose name is \(quote($0))" }
            ?? "(folders of acct)"
        // Let Notes do the filtering when we can.
        let noteSelector: String
        if let query, !query.isEmpty, !searchBody {
            noteSelector = "notes of f whose name contains \(quote(query))"
        } else {
            noteSelector = "notes of f"
        }
        let bodyGuard: String
        if let query, !query.isEmpty, searchBody {
            bodyGuard = "if (t & \" \" & b) contains \(quote(query)) then"
        } else {
            bodyGuard = "if true then"
        }

        let source = """
        tell application "Notes"
            set out to ""
            set matched to 0
            repeat with acct in accounts
                repeat with f in (\(folderFilter))
                    repeat with n in (\(noteSelector))
                        if matched >= \(limit) then exit repeat
                        set t to name of n
                        set b to plaintext of n
                        \(bodyGuard)
                            set snip to b
                            if (count of snip) > 160 then set snip to (text 1 thru 160 of snip)
                            set out to out & (id of n) & \(quote(separator)) & t & \(quote(separator)) & (name of f) & \(quote(separator)) & (name of acct) & \(quote(separator)) & ((modification date of n) as string) & \(quote(separator)) & (count of b) & \(quote(separator)) & snip & \(quote(recordSeparator))
                            set matched to matched + 1
                        end if
                    end repeat
                    if matched >= \(limit) then exit repeat
                end repeat
                if matched >= \(limit) then exit repeat
            end repeat
            return out
        end tell
        """
        return try split(run(source, retryOnTimeout: true)).compactMap { fields in
            guard fields.count >= 7 else { return nil }
            return [
                "id": fields[0],
                "title": fields[1],
                "folder": fields[2],
                "account": fields[3],
                "modified": fields[4],
                "characters": Int(fields[5]) ?? 0,
                "snippet": fields[6].replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
    }

    /// Just the note ids in a folder — no titles, no bodies.
    ///
    /// `search()` reads `plaintext of n` for every note to build its snippet,
    /// which is wasted work (and slow enough to hit the 45s timeout) when the
    /// caller only needs identity. NoteGuard refreshes on a 60s TTL, so this
    /// runs often and must stay cheap.
    static func noteIds(inFolder folder: String) throws -> [String] {
        let source = """
        tell application "Notes"
            set out to ""
            repeat with acct in accounts
                repeat with f in ((folders of acct) whose name is \(quote(folder)))
                    repeat with n in notes of f
                        set out to out & (id of n) & \(quote(recordSeparator))
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        return try run(source, retryOnTimeout: true).stringValue?
            .components(separatedBy: recordSeparator)
            .filter { !$0.isEmpty } ?? []
    }

    /// Full body of one note, as plain text or HTML.
    ///
    /// Every value is bound to a variable before use. AppleScript returns a
    /// REFERENCE rather than a value for a chained property access, so
    /// `name of container of n` fails to coerce (-1700) and
    /// `count of (plaintext of n)` returns 1 instead of the character count.
    /// Binding first is what makes both correct.
    static func body(id: String, html: Bool) throws -> JSONObject {
        let field = html ? "body" : "plaintext"
        let source = """
        tell application "Notes"
            set n to note id \(quote(id))
            set t to name of n
            set f to container of n
            set fname to name of f
            set m to (modification date of n) as string
            set b to \(field) of n
            return t & \(quote(separator)) & fname & \(quote(separator)) & m & \(quote(separator)) & b
        end tell
        """
        let raw = try run(source, retryOnTimeout: true).stringValue ?? ""
        let parts = raw.components(separatedBy: separator)
        guard parts.count >= 4 else {
            throw ToolError("Note not found for id: \(id). Use notes_query to get a valid id.")
        }
        return [
            "id": id,
            "title": parts[0],
            "folder": parts[1],
            "modified": parts[2],
            "format": html ? "html" : "plaintext",
            // The body itself may contain the separator; rejoin the remainder.
            "body": parts[3...].joined(separator: separator)
        ]
    }

    /// Cheapest possible Apple Event: launches Notes.app and returns.
    ///
    /// The warm-up used to call `folders()`, which asks for `count of notes` in
    /// every folder of every account — an O(folders x notes) round trip,
    /// which can take minutes even with Notes.app ALREADY RUNNING. The point of
    /// warming was only ever to pay the app-launch cost off the critical path,
    /// and launching does not require reading anything.
    static func ping() throws {
        // Deliberately no retry. A warm-up that spends 135s across three
        // timeouts has stopped being an optimisation; if the first attempt does
        // not land, the first real caller can pay for one instead.
        _ = try run("tell application \"Notes\" to get name", retryOnTimeout: false)
    }

    static func folders() throws -> [JSONObject] {
        let source = """
        tell application "Notes"
            set out to ""
            repeat with acct in accounts
                repeat with f in folders of acct
                    set out to out & (name of acct) & \(quote(separator)) & (name of f) & \(quote(separator)) & (count of notes of f) & \(quote(recordSeparator))
                end repeat
            end repeat
            return out
        end tell
        """
        return try split(run(source, retryOnTimeout: true)).compactMap { fields in
            guard fields.count >= 3 else { return nil }
            return ["account": fields[0], "folder": fields[1], "noteCount": Int(fields[2]) ?? 0]
        }
    }

    // MARK: - Writes

    /// Creates a note. `body` is HTML — Notes renders the first line as the
    /// note's title, so we prepend the title as an `<h1>` rather than relying on
    /// the `name` property alone (which Notes overwrites from the body).
    static func create(folder: String, account: String?, title: String, bodyHTML: String) throws -> JSONObject {
        let html = "<h1>\(title)</h1>" + bodyHTML
        let target = account.map { "folder \(quote(folder)) of account \(quote($0))" }
            ?? "folder \(quote(folder))"

        // Report the account the note actually landed in. With both an iCloud
        // and a local "On My Mac" account, a folder-name collision could silently file notes somewhere that never
        // syncs to iPhone -- and a note that quietly stops syncing is a failure
        // you would otherwise only notice weeks later.
        let source = """
        tell application "Notes"
            set theFolder to \(target)
            set newNote to make new note at theFolder with properties {body:\(quote(html))}
            set acct to container of theFolder
            set acctName to name of acct
            set noteId to id of newNote
            set noteName to name of newNote
            return noteId & \(quote(separator)) & noteName & \(quote(separator)) & acctName
        end tell
        """
        let fields = try split(run(source)).first ?? []
        guard fields.count >= 2 else {
            throw ToolError("Notes did not return the created note. Check that folder \"\(folder)\" exists.")
        }
        var created: JSONObject = ["id": fields[0], "title": fields[1], "folder": folder]
        if fields.count >= 3 {
            created["account"] = fields[2]
            created["syncsToOtherDevices"] = fields[2] == "iCloud"
        }
        return created
    }

    /// Appends HTML to an existing note, found by id or by exact title.
    static func append(noteId: String?, title: String?, folder: String?, account: String?, html: String) throws -> JSONObject {
        let locator: String
        if let noteId, !noteId.isEmpty {
            locator = "set theNote to note id \(quote(noteId))"
        } else if let title, !title.isEmpty {
            if let folder, !folder.isEmpty {
                // Naming a read-blocked folder AND a title would let a caller
                // probe which titles exist in it -- a read capability wearing a
                // write tool's clothes. Appending into such a folder is still
                // possible by note id, which the writer already holds.
                if NoteGuard.isBlocked(folder: folder) {
                    throw ToolError(
                        "Appending by title is not available for \(folder) because it is "
                        + "read-blocked by policy: matching a title would reveal whether that "
                        + "title exists. Use `noteId` instead, or notes_create.")
                }
                let target = account.map { "folder \(quote(folder)) of account \(quote($0))" }
                    ?? "folder \(quote(folder))"
                locator = """
                set matches to (every note of \(target) whose name is \(quote(title)))
                    if (count of matches) is 0 then error "no note titled \(title)"
                    set theNote to item 1 of matches
                """
            } else {
                // Untargeted search. `whose ... and name of container is not "X"`
                // is NOT a usable filter -- Notes silently matches nothing rather
                // than erroring, which quietly broke every title-based append.
                // Iterate folders explicitly and skip the blocked ones instead.
                let skip = NoteGuard.blockedFolders
                    .map { "if fname is not \(quote($0)) then" }
                let close = String(repeating: "end if\n", count: skip.count)
                locator = """
                set theNote to missing value
                repeat with acct in accounts
                    repeat with f in folders of acct
                        set fname to name of f
                        \(skip.joined(separator: "\n"))
                        set matches to (every note of f whose name is \(quote(title)))
                        if (count of matches) > 0 then
                            set theNote to item 1 of matches
                        end if
                        \(close)
                        if theNote is not missing value then exit repeat
                    end repeat
                    if theNote is not missing value then exit repeat
                end repeat
                if theNote is missing value then error "no note titled \(title)"
                """
            }
        } else {
            throw ToolError("append requires either `noteId` or `title`.")
        }

        let source = """
        tell application "Notes"
            \(locator)
            set body of theNote to (body of theNote) & \(quote(html))
            return (id of theNote) & \(quote(separator)) & (name of theNote)
        end tell
        """
        let fields = try split(run(source)).first ?? []
        guard fields.count >= 2 else {
            throw ToolError("Could not find the note to append to.")
        }
        return ["id": fields[0], "title": fields[1], "appended": true]
    }
}
