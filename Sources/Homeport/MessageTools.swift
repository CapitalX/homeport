import Foundation

enum MessageTools {
    static let all: [Tool] = [queryTool, sendTool]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Read

    private static let queryTool = Tool(
        name: "messages_query",
        description: """
        Read recent iMessage/SMS history from this Mac, newest first. Read-only — it copies the \
        Messages database and reads the copy, never touching the live file. Filter by `handle` \
        (phone number or email, substring match), `sinceDays`, and `limit`. Use this to check \
        whether someone replied, or to quote earlier context before sending.

        Group threads set `isGroup` and list `participants`, since the `chat` field is otherwise an \
        opaque id. `hasAttachments` marks a message carrying a photo, sticker or file — those often \
        have empty `text`, which would otherwise look like a blank message.

        Tapbacks come back as `reaction` ("liked", "loved", "laughed", "emphasized", "questioned", \
        "disliked", a literal emoji, or "removed-*" when withdrawn) with `reactionTo` giving the id \
        of the message reacted to when it is present in the same result, and `reactionToGuid` always. \
        A tapback has an empty `text` — treat it as an annotation on another message, not as a \
        message of its own.
        """,
        inputSchema: Schema.object([
            "handle": Schema.string("Phone number or email to filter on, e.g. +15551234567 (substring match)"),
            "sinceDays": Schema.integer("Only messages from the last N days"),
            "limit": Schema.integer("Max messages to return (default 50, max 500)")
        ]),
        handler: { args in
            let handle = args.string("handle")
            let sinceDays = args["sinceDays"] as? Int
            let limit = (args["limit"] as? Int) ?? 50

            let messages = try MessagesStore.query(handle: handle, sinceDays: sinceDays, limit: limit)

            // Let a caller resolve `reactionTo` to a message in this same
            // result without a second round trip.
            let idByGUID = Dictionary(messages.map { ($0.guid, $0.rowId) },
                                      uniquingKeysWith: { a, _ in a })

            let total = (try? MessagesStore.matchCount(handle: handle, sinceDays: sinceDays)) ?? messages.count
            var result: JSONObject = [
                "count": messages.count,
                "total": total,
                "totalMatched": total,
                "messages": messages.map { m in
                    var out: JSONObject = [
                        "id": m.rowId,
                        "date": isoFormatter.string(from: m.date),
                        "direction": m.isFromMe ? "sent" : "received",
                        "handle": m.handle ?? NSNull(),
                        "chat": m.chatName ?? NSNull(),
                        "service": m.service ?? NSNull(),
                        "text": m.text
                    ]
                    if m.hasAttachments { out["hasAttachments"] = true }
                    if m.participants.count > 1 {
                        out["isGroup"] = true
                        out["participants"] = m.participants
                    }
                    if let reaction = m.reaction {
                        out["reaction"] = reaction
                        // Apple stores a rendered pseudo-body on tapback rows
                        // (`Liked "the original"`), which duplicates the message
                        // being reacted to. Drop it: `reaction` + `reactionTo`
                        // carry the same information unambiguously.
                        out["text"] = ""
                        if let target = m.reactionTo {
                            out["reactionToGuid"] = target
                            if let id = idByGUID[target] { out["reactionTo"] = id }
                        }
                    }
                    return out
                }
            ]
            // The SQL caps at 500 regardless of a larger `limit`; saying so
            // stops a caller treating a truncated page as the whole history.
            if messages.count < total {
                result["truncated"] = true
                result["message"] = "Showing \(messages.count) of \(total) matching messages"
                    + (limit > 500 ? " (capped at 500 per call)" : "")
                    + ". Narrow with `handle` or `sinceDays`."
            }
            return result
        }
    )

    // MARK: - Write

    private static let sendTool = Tool(
        name: "messages_send",
        description: """
        Send an iMessage. THIS IS IRREVERSIBLE AND VISIBLE TO ANOTHER PERSON — a sent message \
        cannot be unsent. `confirmSend` must be explicitly true; without it this returns an error \
        describing what would have been sent, so a message is never dispatched on an ambiguous \
        instruction. Prefer a full E.164 phone number (+15551234567) or an Apple ID email that \
        already has a conversation. Requires the Messages Automation grant.
        """,
        inputSchema: Schema.object([
            "to": Schema.string("Recipient: phone number in E.164 form (+15551234567) or Apple ID email"),
            "body": Schema.string("The message text to send"),
            "confirmSend": Schema.boolean("Must be true to actually send. Omit to preview instead.")
        ], required: ["to", "body"]),
        handler: { args in
            guard let to = args.string("to"), !to.isEmpty else {
                throw ToolError("`to` is required (phone number in E.164 form, or Apple ID email).")
            }
            guard let body = args.string("body"), !body.isEmpty else {
                throw ToolError("`body` is required and must not be empty.")
            }

            // The actual boundary on this tool.
            //
            // `confirmSend` below is UX, not security: it is a field in the same
            // JSON object the caller authored, so a model acting on injected
            // instructions can simply set it -- and the preview response even
            // says how. This check cannot be reached the same way, because the
            // allowlist lives in a file no tool can write.
            //
            // Enforced here rather than in `Auth.authorize` because that runs
            // for HTTP only, and stdio -- the transport a local client actually
            // uses -- has no scope layer at all. Same placement reasoning as
            // NoteGuard.
            //
            // Fails closed: an absent or empty list sends nothing.
            let allowed = Auth.policy().allowedRecipients
            guard allowed.contains(Auth.normalizeHandle(to)) else {
                throw ToolError(
                    "Recipient '\(to)' is not enrolled, so nothing was sent. "
                    + (allowed.isEmpty
                        ? "No allowedRecipients are configured."
                        : "\(allowed.count) recipient(s) are enrolled.")
                    + " Add the handle to \"allowedRecipients\" in "
                    + "~/Library/Application Support/homeport/policy.json "
                    + "and restart the bridge. This list is edited by hand on purpose.")
            }

            // Same guard idiom as SummaryTools' confirmMayLeaveMachine: the
            // default must never be the irreversible outward-facing action.
            let confirmed = (args["confirmSend"] as? Bool) ?? false
            guard confirmed else {
                return [
                    "sent": false,
                    "wouldSend": ["to": to, "body": body],
                    "message": "Not sent. Re-call with confirmSend: true to actually deliver this. "
                        + "Sending an iMessage is irreversible and visible to the recipient."
                ]
            }

            try MessagesStore.send(to: to, body: body)

            // A clean Apple Event means Messages ACCEPTED the request, not that
            // anything was delivered: sending to a number not registered with
            // iMessage raises no AppleScript error but lands in chat.db with
            // is_sent=0 and a non-zero error. Read the real outcome back rather
            // than reporting the dispatch as a success.
            let at = isoFormatter.string(from: Date())
            guard let outcome = MessagesStore.confirmDelivery(to: to, within: 6) else {
                return [
                    "dispatched": true, "delivered": "unknown", "to": to,
                    "characters": body.count, "at": at,
                    "message": "Messages accepted the request but no delivery record appeared within 6s. "
                        + "Check the conversation in Messages to confirm."
                ]
            }
            if outcome.isSent {
                return ["dispatched": true, "delivered": true, "to": to,
                        "characters": body.count, "at": at]
            }
            return [
                "dispatched": true, "delivered": false, "to": to, "at": at,
                "errorCode": outcome.error,
                "message": "Messages could not deliver this (error \(outcome.error)). The usual cause is "
                    + "a number or address not registered with iMessage. A failed conversation may now "
                    + "be showing in Messages."
            ]
        }
    )
}
