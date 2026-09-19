import Foundation
import SQLite3

/// One iMessage/SMS as we care about it.
struct ChatMessage {
    let rowId: Int
    let guid: String
    let text: String
    let date: Date
    let isFromMe: Bool
    let handle: String?      // the counterparty's phone/email
    let chatName: String?    // display name of the conversation
    let service: String?     // iMessage | SMS
    /// Participants of a group chat. Empty for a one-to-one thread.
    let participants: [String]
    /// True when the row carries an attachment (photo, sticker, file). Such a
    /// message often has no text at all, which would otherwise be
    /// indistinguishable from an empty message.
    let hasAttachments: Bool
    /// A tapback: "liked", "loved", "removed-liked", or a literal emoji.
    /// nil for an ordinary message.
    let reaction: String?
    /// GUID of the message this tapback is attached to.
    let reactionTo: String?
}

/// Tapbacks are not separate objects in `chat.db` — they are message rows whose
/// `associated_message_type` is non-zero and whose `associated_message_guid`
/// points at the message being reacted to. Apple also writes a rendered
/// pseudo-body (`Liked "the original text"`), which is what a naive reader
/// surfaces: it duplicates the original message and gives a model no way to tell
/// "someone reacted to X" apart from "someone said X". Decoding the type instead
/// lets a caller attach the reaction to the message it belongs to.
enum Tapback {
    static func describe(type: Int, emoji: String?) -> String? {
        if type == 0 { return nil }
        if let emoji, !emoji.isEmpty {
            // 3000-range is always a removal, including for custom emoji.
            return type >= 3000 ? "removed-\(emoji)" : emoji
        }
        // Order verified against Apple's own rendered pseudo-body: a row with
        // associated_message_type 2001 renders as `Liked "..."`, so 2000 is
        // loved and 2001 is liked, not the other way round.
        let names = [0: "loved", 1: "liked", 2: "disliked",
                     3: "laughed", 4: "emphasized", 5: "questioned"]
        if (2000...2005).contains(type) { return names[type - 2000] }
        if (3000...3005).contains(type) { return names[type - 3000].map { "removed-\($0)" } }
        return "reaction-\(type)"
    }

    /// `associated_message_guid` is prefixed in some rows ("p:0/<guid>",
    /// "bp:<guid>"), so the bare GUID has to be recovered to match a message.
    static func targetGUID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let slash = raw.lastIndex(of: "/") { return String(raw[raw.index(after: slash)...]) }
        if let colon = raw.lastIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
        return raw
    }
}

/// Read-only access to the Messages library.
///
/// `chat.db` can run to hundreds of MB, actively written by Messages.app and synced by CloudKit.
/// This never opens the live file: it copies the db plus its `-wal`/`-shm`
/// sidecars to a temp directory and reads the copy, exactly as
/// `VoiceMemoStore` does for `CloudRecordings.db`. That avoids both corrupting a
/// synced library and fighting SQLite's WAL locking against an app that has the
/// database open.
///
/// Requires Full Disk Access.
enum MessagesStore {

    /// Core Data / Messages store timestamps as NANOseconds since 2001-01-01 on
    /// modern macOS. Note this differs from Voice Memos, which uses SECONDS
    /// against the same epoch -- mixing them up yields dates in the far future.
    private static let appleEpoch: TimeInterval = 978_307_200
    private static let nanosecondThreshold: Int64 = 1_000_000_000_000

    static var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    static func ensureReadable() throws {
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw ToolError("Messages database not found at \(dbURL.path). Is Messages set up on this Mac?")
        }
        guard FileManager.default.isReadableFile(atPath: dbURL.path) else {
            throw ToolError(
                "Cannot read the Messages database. Grant Full Disk Access to " +
                "Homeport.app in System Settings > Privacy & Security > Full Disk Access.")
        }
    }

    private static func date(fromRaw raw: Int64) -> Date {
        // Older rows are in seconds; current ones in nanoseconds. Decide per row
        // rather than assuming, so an old thread does not land in 1970.
        let seconds = raw > nanosecondThreshold ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + appleEpoch)
    }

    /// Query recent messages, optionally filtered to one counterparty.
    ///
    /// - Parameters:
    ///   - handle: phone number or email to filter on (substring match).
    ///   - sinceDays: only messages newer than this many days.
    ///   - limit: max rows, newest first.
    /// Total rows matching the same filters, ignoring `limit`. Reported so a
    /// caller can tell "these are all of them" from "these are the first N" --
    /// silently returning a capped page is how a model concludes nobody
    /// mentioned something when the evidence was simply cut off.
    static func matchCount(handle: String?, sinceDays: Int?) throws -> Int {
        try query(handle: handle, sinceDays: sinceDays, limit: 0, countOnly: true).count
    }

    static func query(handle: String?, sinceDays: Int?, limit: Int, countOnly: Bool = false) throws -> [ChatMessage] {
        try ensureReadable()

        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("homeport-msg-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // The -wal sidecar holds recent writes; copying it too means we see the
        // same state Messages.app does.
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = temp.appendingPathComponent(dbURL.lastPathComponent + suffix)
            try? FileManager.default.removeItem(at: dst)
            do { try FileManager.default.copyItem(at: src, to: dst) }
            catch {
                throw ToolError(
                    "Could not copy the Messages database (\(error.localizedDescription)). " +
                    "This usually means Full Disk Access is not granted to Homeport.app.")
            }
        }

        let copy = temp.appendingPathComponent(dbURL.lastPathComponent)
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw ToolError("Could not open a copy of chat.db.")
        }
        defer { sqlite3_close(db) }

        var conditions: [String] = ["m.item_type = 0"]  // plain messages, not joins/renames
        if handle != nil { conditions.append("(h.id LIKE ?1)") }
        if let sinceDays {
            let cutoff = Int64((Date().timeIntervalSince1970 - Double(sinceDays) * 86_400 - appleEpoch) * 1_000_000_000)
            conditions.append("m.date >= \(cutoff)")
        }

        let sql = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.date, m.is_from_me,
               h.id, c.display_name, c.chat_identifier, m.service,
               m.associated_message_type, m.associated_message_guid,
               m.associated_message_emoji, m.cache_has_attachments, c.ROWID
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.date DESC
        \(countOnly ? "" : "LIMIT \(max(1, min(limit, 500)))")
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ToolError("Could not query chat.db: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }

        if let handle {
            sqlite3_bind_text(stmt, 1, "%\(handle)%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        // A group chat surfaces only as an opaque identifier like
        // "chat000000000000000000", which tells a caller nothing about who is in
        // it. Resolve the roster once up front rather than per row.
        let participantsByChat = chatParticipants(db)

        var out: [ChatMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = Int(sqlite3_column_int64(stmt, 0))
            let guid = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""

            // `text` is NULL on a meaningful minority of modern rows (a few percent
            // in practice) where the body lives only in the archived attributedBody.
            // Treating NULL as "empty message" would silently drop them.
            var body = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            if body.isEmpty, let blob = sqlite3_column_blob(stmt, 3) {
                let n = Int(sqlite3_column_bytes(stmt, 3))
                let data = Data(bytes: blob, count: n)
                body = decodeAttributedBody(data) ?? ""
            }

            let raw = sqlite3_column_int64(stmt, 4)
            let fromMe = sqlite3_column_int(stmt, 5) == 1
            let hid = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let display = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let chatId = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let service = sqlite3_column_text(stmt, 9).map { String(cString: $0) }

            let amType = Int(sqlite3_column_int(stmt, 10))
            let amGuid = sqlite3_column_text(stmt, 11).map { String(cString: $0) }
            let amEmoji = sqlite3_column_text(stmt, 12).map { String(cString: $0) }

            let hasAttach = sqlite3_column_int(stmt, 13) == 1
            let chatRow = Int(sqlite3_column_int64(stmt, 14))

            let name = (display?.isEmpty == false) ? display : chatId
            out.append(ChatMessage(rowId: rowId, guid: guid, text: body,
                                   date: date(fromRaw: raw), isFromMe: fromMe,
                                   handle: hid, chatName: name, service: service,
                                   participants: participantsByChat[chatRow] ?? [],
                                   hasAttachments: hasAttach,
                                   reaction: Tapback.describe(type: amType, emoji: amEmoji),
                                   reactionTo: Tapback.targetGUID(amGuid)))
        }
        return out
    }

    /// chat ROWID -> the handles taking part in it.
    private static func chatParticipants(_ db: OpaquePointer) -> [Int: [String]] {
        let sql = """
        SELECT chj.chat_id, h.id
        FROM chat_handle_join chj
        JOIN handle h ON h.ROWID = chj.handle_id
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var out: [Int: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chatId = Int(sqlite3_column_int64(stmt, 0))
            guard let h = sqlite3_column_text(stmt, 1) else { continue }
            out[chatId, default: []].append(String(cString: h))
        }
        return out
    }

    /// Pull the plain text out of an archived `NSAttributedString`.
    ///
    /// These blobs are NeXT *typedstream* archives, not keyed archives, so
    /// `NSKeyedUnarchiver` cannot read them and the classic `NSUnarchiver` is not
    /// exposed to Swift. Rather than link a decoder for a format we only need one
    /// field from, locate the `NSString` marker and read the length-prefixed UTF-8
    /// that follows. Returns nil when the shape is not recognised, so the caller
    /// can fall back rather than emit garbage.
    static func decodeAttributedBody(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let markerStart = find(bytes, Array("NSString".utf8)) else { return nil }

        // Typedstream writes: ... "NSString" ... 0x2B ('+') <length> <utf8 bytes>
        var i = markerStart + "NSString".count
        let scanLimit = min(bytes.count, i + 64)
        while i < scanLimit && bytes[i] != 0x2B { i += 1 }
        guard i < scanLimit, bytes[i] == 0x2B else { return nil }
        i += 1
        guard i < bytes.count else { return nil }

        var length = Int(bytes[i]); i += 1
        if length == 0x81 {                       // 0x81 => next 2 bytes are a LE length
            guard i + 1 < bytes.count else { return nil }
            length = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            i += 2
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    /// Confirm what actually happened to the message we just dispatched.
    ///
    /// A successful Apple Event means only "Messages accepted the request" — it
    /// says nothing about delivery. Sending to a number not registered with
    /// iMessage returns no AppleScript error at all, yet lands in chat.db with
    /// `is_sent = 0` and a non-zero `error`. Reporting the Apple Event's success
    /// as "sent" would therefore be a lie, so poll briefly for the real outcome.
    ///
    /// Returns nil if no row appeared in time — genuinely unknown, and the caller
    /// says so rather than guessing.
    static func confirmDelivery(to recipient: String, within seconds: Double) -> (isSent: Bool, error: Int)? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            guard let row = latestOutgoing(to: recipient) else { continue }
            // error stays 0 while in flight; wait for a verdict either way.
            if row.isSent || row.error != 0 { return row }
        }
        return latestOutgoing(to: recipient)
    }

    private static func latestOutgoing(to recipient: String) -> (isSent: Bool, error: Int)? {
        guard let msgs = try? queryRaw(handleExact: recipient) else { return nil }
        return msgs
    }

    /// Minimal single-row read used only by delivery confirmation.
    private static func queryRaw(handleExact: String) throws -> (isSent: Bool, error: Int)? {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("homeport-msgchk-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: dbURL.path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(
                at: src, to: temp.appendingPathComponent(dbURL.lastPathComponent + suffix))
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appendingPathComponent(dbURL.lastPathComponent).path,
                              &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT m.is_sent, m.error FROM message m
        JOIN chat_message_join j ON j.message_id = m.ROWID
        JOIN chat c ON c.ROWID = j.chat_id
        WHERE c.chat_identifier = ?1 AND m.is_from_me = 1
        ORDER BY m.date DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, handleExact, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int(stmt, 0) == 1, Int(sqlite3_column_int(stmt, 1)))
    }

    private static func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    // MARK: - Sending

    /// Send via Apple Events to Messages.app. In-process `NSAppleScript` for the
    /// same reason as Notes: the automation grant then attaches to this binary
    /// rather than to `osascript`.
    ///
    /// Automation grants are per target app, so the existing Notes grant does not
    /// cover Messages -- the first call raises its own prompt.
    static func send(to recipient: String, body: String) throws {
        // `with timeout` is not cosmetic. NSAppleScript blocks the calling
        // thread until the Apple Event returns, and every tool call runs on the
        // HTTP transport's single serial dispatch queue -- so one Apple Event
        // that never comes back (Messages not yet authorized, an unresolvable
        // recipient, the app mid-launch) wedges the ENTIRE daemon, not just this
        // request. AppleScript's default timeout is two minutes; 20s bounds the
        // damage and surfaces a real error instead of a hang.
        let source = """
        with timeout of 20 seconds
            tell application "Messages"
                set targetService to 1st account whose service type = iMessage
                set targetBuddy to participant \(NotesStore.quote(recipient)) of targetService
                send \(NotesStore.quote(body)) to targetBuddy
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            throw ToolError("Could not compile the Messages script.")
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown AppleScript error"
        switch code {
        case -1743:
            throw ToolError(
                "Not authorized to control Messages. Approve it in System Settings > Privacy & " +
                "Security > Automation under Homeport, then retry. The prompt only appears " +
                "from a GUI host, so trigger this once from Claude Desktop if a background run fails.")
        case -600, -609:
            throw ToolError("Messages is not running and could not be launched.")
        case -1712:
            throw ToolError(
                "Timed out talking to Messages after 20s. If this is the first send, the Automation " +
                "prompt cannot appear from the background daemon -- run " +
                "`open -a Homeport.app --args --grant` once, or trigger messages_send from " +
                "Claude Desktop, and approve the Messages prompt.")
        case -1728:
            throw ToolError(
                "Messages could not resolve '\(recipient)'. Use a full phone number in E.164 form " +
                "(+15551234567) or an Apple ID email that already has a conversation.")
        default:
            throw ToolError("Messages scripting failed (\(code)): \(message)")
        }
    }
}
