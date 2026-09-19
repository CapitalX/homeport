import Foundation

/// Authorization for the HTTP transport, keyed on Tailscale node identity.
///
/// There are deliberately **no bearer tokens and no secrets on disk**. The
/// caller is identified by `TailnetIdentity` from headers `tailscale serve`
/// overwrites and a client cannot forge, so authentication is already done by
/// WireGuard before a request reaches us. What remains is authorization: which
/// node may do what.
///
/// `policy.json` is therefore **not a credential file** — it is policy. Reading
/// it grants nobody anything, so it needs no password manager, no rotation, and
/// no special handling if it leaks. Revoking a device means removing it from the
/// tailnet or editing this file; there is no token to invalidate.
///
/// The stdio transport stays unauthenticated: reaching it already means being
/// able to run this binary as you.
enum Auth {

    enum Scope: String, CaseIterable {
        case read     // list/query only
        case write    // create/update/delete
        case message  // send an iMessage (outward-facing, so it stands alone)
    }

    struct Denial: Error {
        let status: Int
        let message: String
    }

    static let policyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/homeport/policy.json")

    /// Which scope each tool requires. A static table rather than a field on
    /// `Tool`: the struct is built by memberwise init across 25 call sites with
    /// `handler` last, so adding a field would churn every tool file — and one
    /// table is one place to audit when asking "what can a read-only node do?"
    static let toolScopes: [String: Scope] = [
        "reminders_lists": .read,      "reminders_query": .read,
        "reminders_create": .write,    "reminders_bulk_create": .write,
        "reminders_update": .write,    "reminders_complete": .write,
        "reminders_delete": .write,    "reminders_bulk_delete": .write,
        "reminders_bulk_update": .write,
        "reminders_route": .write,
        "reminders_schedule": .write,

        "calendar_calendars": .read,   "calendar_query": .read,
        "calendar_create_event": .write, "calendar_update_event": .write,
        "calendar_delete_event": .write,

        "contacts_query": .read,       "contacts_groups": .read,
        "contacts_duplicates": .read,  "contacts_merge": .write,
        "contacts_create": .write,     "contacts_update": .write,
        "contacts_delete": .write,

        "notes_folders": .read,        "notes_query": .read,
        "notes_read": .read,           "notes_create": .write,
        "notes_append": .write,

        "voicememos_list": .read,      "voicememos_transcript": .read,
        "voicememos_transcribe": .write, "voicememos_summarize": .write,

        "messages_query": .read,       "messages_send": .message,

        // shortcuts_fetch is .read despite being able to write files: with
        // save:true it only ever writes into the bridge's own outbox, which is a
        // cache and not the user's data. Building and running are both .write --
        // signing produces a distributable artifact, and running a shortcut is
        // running arbitrary code the owner wrote.
        "shortcuts_list": .read,        "shortcuts_fetch": .read,
        "shortcuts_build": .write,      "shortcuts_run": .write,

        "bridge_ping": .read,
    ]

    /// Unknown tool names require `write`, so a tool added later without a table
    /// entry fails closed rather than being reachable by a read-only node.
    static func requiredScope(forTool name: String) -> Scope {
        toolScopes[name] ?? .write
    }

    // MARK: - Policy

    struct Policy {
        let allowedUsers: Set<String>              // tailnet logins permitted at all
        let byAddress: [String: (node: String, scopes: Set<Scope>)]
        /// Notes folders whose CONTENT must never be returned. Writes still
        /// allowed. Enforced by NoteGuard on every transport, not here, because
        /// this type only runs for HTTP.
        let readBlockedNoteFolders: [String]
        /// Handles `messages_send` may deliver to, normalized. Enforced in the
        /// tool handler rather than in `authorize`, for the same reason as
        /// `readBlockedNoteFolders`: this type only runs for HTTP, and stdio
        /// needs the rule just as much.
        ///
        /// Deliberately stores literal handles, never contact names —
        /// `contacts_update` can rewrite a stored phone number with no
        /// confirmation, so a name-keyed list would be trivially bypassable.
        let allowedRecipients: Set<String>
    }

    /// Canonical form for comparing message handles.
    ///
    /// Phone numbers arrive punctuated in a dozen ways and email addresses are
    /// case-insensitive, so both sides of the comparison go through here. A
    /// leading `+` is preserved: it is the only part of a number's punctuation
    /// that carries meaning.
    static func normalizeHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.contains("@") else { return trimmed }
        let kept = trimmed.filter { $0.isNumber || $0 == "+" }
        return kept.isEmpty ? trimmed : kept
    }

    private static var cachedPolicy: Policy?
    private static let policyLock = NSLock()

    static func policy() -> Policy {
        policyLock.lock(); defer { policyLock.unlock() }
        if let cachedPolicy { return cachedPolicy }
        let loaded = loadPolicy()
        cachedPolicy = loaded
        return loaded
    }

    private static func loadPolicy() -> Policy {
        // Fail CLOSED. A missing or malformed policy must not mean "allow
        // everything" -- an empty allowlist rejects every request instead.
        guard let data = try? Data(contentsOf: policyURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            Log.warn("auth: no readable policy at \(policyURL.path); rejecting all HTTP requests")
            return Policy(allowedUsers: [], byAddress: [:], readBlockedNoteFolders: [],
                          allowedRecipients: [])
        }

        let users = Set(root["allowedUsers"] as? [String] ?? [])
        var byAddress: [String: (node: String, scopes: Set<Scope>)] = [:]
        for (node, raw) in (root.object("nodes") ?? [:]) {
            guard let entry = raw as? JSONObject,
                  let address = entry.string("address") else { continue }
            let scopes = Set((entry["scopes"] as? [String] ?? []).compactMap(Scope.init(rawValue:)))
            byAddress[address] = (node, scopes)
        }
        let blocked = root["readBlockedNoteFolders"] as? [String] ?? []
        let recipients = Set((root["allowedRecipients"] as? [String] ?? []).map(normalizeHandle))
        Log.info("auth: policy loaded — \(users.count) user(s), \(byAddress.count) node(s)"
            + (blocked.isEmpty ? "" : ", read-blocked notes folders: \(blocked.joined(separator: ", "))")
            + ", \(recipients.count) allowed message recipient(s)")
        return Policy(allowedUsers: users, byAddress: byAddress, readBlockedNoteFolders: blocked,
                      allowedRecipients: recipients)
    }

    // MARK: - Checking

    /// The enrolled node name for a caller, for logging. nil when unenrolled.
    static func nodeName(for caller: TailnetIdentity.Caller) -> String? {
        policy().byAddress[caller.address]?.node
    }

    /// Authorize one JSON-RPC message for a resolved tailnet caller.
    static func authorize(_ msg: JSONObject, as caller: TailnetIdentity.Caller) throws {
        let p = policy()

        // A user-owned device must belong to an allowed user. A tagged device
        // has no user (serve sends no identity headers for it), so for it the
        // enrollment-by-address check below is the whole gate -- and only a
        // tailnet admin can apply tags.
        if let login = caller.userLogin {
            guard p.allowedUsers.contains(login) else {
                throw Denial(status: 403, message:
                    "Tailnet user '\(login)' is not permitted. Add them to allowedUsers in policy.json.")
            }
        }

        // Unenrolled nodes get nothing. Being on the tailnet is necessary but not
        // sufficient -- a device must be named in policy before it can do
        // anything, so adding a node to the tailnet never silently grants access.
        guard let entry = p.byAddress[caller.address] else {
            throw Denial(status: 403, message:
                "Tailnet node \(caller.address) is not enrolled. Run "
                + "./pipeline/add-device.sh <name> to grant it scopes.")
        }
        let scopes = entry.scopes

        let method = msg.string("method") ?? ""
        // Handshake and discovery must work for any permitted caller, or a
        // read-only client cannot even connect.
        switch method {
        case "initialize", "ping", "tools/list", "prompts/list",
             "resources/list", "resources/templates/list",
             "notifications/initialized", "notifications/cancelled", "initialized":
            return
        default: break
        }
        guard method == "tools/call" else { return }

        let name = (msg.object("params") ?? [:]).string("name") ?? ""
        let needed = requiredScope(forTool: name)
        guard scopes.contains(needed) else {
            let held = scopes.isEmpty ? "none" : scopes.map(\.rawValue).sorted().joined(separator: ", ")
            throw Denial(status: 403, message:
                "Node '\(entry.node)' lacks the '\(needed.rawValue)' scope required by \(name). " +
                "Held scopes: \(held). Edit nodes.\(entry.node) in policy.json to change this.")
        }
    }
}
