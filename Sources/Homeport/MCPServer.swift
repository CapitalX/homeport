import Foundation

/// Where a JSON-RPC response goes. Passed down the dispatch chain rather than
/// stored on the server: `MCPServer` is shared across transports, and a stdio
/// reply and an HTTP reply for two different callers must not race for one
/// mutable field.
typealias Responder = (JSONObject) -> Void

/// Minimal, dependency-free MCP server (JSON-RPC 2.0). Transport-agnostic: see
/// `StdioTransport` and `HTTPTransport` for the two ways in.
///
/// One request is handled at a time — EventKit/Contacts calls are cheap and this
/// is a single-user tool, so there is no need for concurrency. HTTP accepts
/// connections in parallel but funnels every dispatch through one serial queue,
/// which preserves this invariant exactly.
final class MCPServer {
    private let protocolVersionDefault = "2025-06-18"
    private let tools: [Tool]
    private let toolIndex: [String: Tool]
    private let prompts: [PromptTemplate]

    /// Exposed for bridge_ping, so the advertised count comes from the real
    /// registry rather than a hand-maintained constant that can drift.
    static private(set) var registeredToolCount = 0

    /// Exposed for the test that asserts `Untrusted.toolTrust` covers the whole
    /// registry. Same reasoning as the count: a hand-maintained list of names
    /// would drift, and the drift is exactly what the test exists to catch.
    static private(set) var registeredToolNames: [String] = []

    init() {
        let raw = ReminderTools.all + CalendarTools.all + ContactTools.all
            + NotesTools.all + VoiceMemoTools.all + SummaryTools.all
            + MessageTools.all + ShortcutsTools.all + DiagnosticTools.all
        // Advertise `idempotencyKey` on every mutating tool.
        //
        // It was accepted from the start (stripped in handleToolCall before the
        // unknown-argument check), but appeared in ZERO schemas -- so a client
        // reading tools/list could not discover it, and `additionalProperties:
        // false` made it look forbidden. An undocumented parameter is an absent
        // one. Injected here rather than hand-added to 15 schemas so it cannot
        // drift as tools are added.
        let all = raw.map { tool -> Tool in
            guard Auth.requiredScope(forTool: tool.name) != .read else { return tool }
            var schema = tool.inputSchema
            var props = schema.object("properties") ?? [:]
            props["idempotencyKey"] = Schema.string(
                "Optional. Replaying the same key returns the ORIGINAL result with replayed:true "
                + "instead of writing again, so a timed-out call can be retried safely. "
                + "Cached in memory for 6 hours; not persisted across a server restart.")
            schema["properties"] = props
            return Tool(name: tool.name, description: tool.description,
                        inputSchema: schema, handler: tool.handler)
        }
        self.tools = all
        self.toolIndex = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        self.prompts = PromptTemplate.all
        MCPServer.registeredToolCount = all.count
        MCPServer.registeredToolNames = all.map { $0.name }
    }

    /// Parse one raw JSON-RPC line and dispatch it. Shared by every transport so
    /// the parse-error behavior stays identical across them.
    func handleRawLine(_ raw: String, respondWith send: Responder) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        guard let data = trimmed.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            emitParseError(trimmed, respondWith: send)
            return
        }
        handle(msg, respondWith: send)
    }

    // MARK: - Dispatch

    /// `caller` is the enrolled node name when the request arrived over HTTP.
    /// stdio leaves it nil and audits as "local", which is accurate: reaching
    /// stdio already means being able to run this binary as the user.
    func handle(_ msg: JSONObject, caller: String? = nil, respondWith send: Responder) {
        let method = msg.string("method") ?? ""
        let id = msg["id"]                       // nil for notifications
        let hasId = id != nil && !(id is NSNull)

        switch method {
        case "initialize":
            respond(id, result: initializeResult(msg), send)

        case "notifications/initialized", "notifications/cancelled", "initialized":
            return // notifications: no response

        case "ping":
            respond(id, result: JSONObject(), send)

        case "tools/list":
            respond(id, result: ["tools": tools.map { $0.advertised }], send)

        case "tools/call":
            handleToolCall(id, params: msg.object("params") ?? [:], caller: caller, send)

        case "prompts/list":
            respond(id, result: ["prompts": prompts.map { $0.advertised }], send)

        case "prompts/get":
            handlePromptGet(id, params: msg.object("params") ?? [:], send)

        case "resources/list":
            respond(id, result: ["resources": [Any]()], send)

        case "resources/templates/list":
            respond(id, result: ["resourceTemplates": [Any]()], send)

        default:
            if hasId {
                respondError(id, code: -32601, message: "Method not found: \(method)", send)
            }
        }
    }

    private func initializeResult(_ msg: JSONObject) -> JSONObject {
        let params = msg.object("params") ?? [:]
        let version = params.string("protocolVersion") ?? protocolVersionDefault
        return [
            "protocolVersion": version,
            "capabilities": [
                "tools": JSONObject(),
                "prompts": JSONObject()
            ],
            // One source of truth. This used to be a hardcoded "1.0.0" while
            // `bridge_ping` reported `Version.current` -- so a client that read
            // the handshake and a client that pinged disagreed about which
            // server they were talking to.
            "serverInfo": [
                "name": "homeport",
                "version": Version.current
            ]
        ]
    }

    private func handleToolCall(_ id: Any?, params: JSONObject, caller: String?,
                                _ send: Responder) {
        let started = Date()
        let name = params.string("name") ?? ""
        var args = params.object("arguments") ?? [:]
        // Defensive: some clients double-encode `arguments` as a JSON string
        // instead of an object. Decode it rather than treating every field as
        // missing.
        if args.isEmpty, let raw = params.string("arguments"),
           let data = raw.data(using: .utf8),
           let decoded = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
            args = decoded
        }
        guard let tool = toolIndex[name] else {
            respondError(id, code: -32602, message: "Unknown tool: \(name)", send)
            return
        }

        // `idempotencyKey` is accepted on every mutating tool without appearing
        // in each schema, so it is stripped here -- before the unknown-argument
        // check, which would otherwise reject it, and before the handler, which
        // should never see it.
        let idempotencyKey = args.string("idempotencyKey")
        args.removeValue(forKey: "idempotencyKey")
        let mutating = Auth.requiredScope(forTool: name) != .read

        if let idempotencyKey, mutating,
           let cached = Idempotency.replay(key: idempotencyKey, tool: name) {
            Log.info("idempotency: replaying \(name) for key \(idempotencyKey.prefix(12))…")
            // The replay path never enters the handler, so the guard has to run
            // here too -- otherwise a cached body from a read-blocked folder is
            // served precisely when nothing else is looking at it.
            var payload = JSON.pretty(NoteGuard.filter(tool: name, args: args, value: cached))
            // Mark it so a caller can tell a replay from a fresh write rather
            // than concluding it somehow succeeded twice.
            if let data = payload.data(using: .utf8),
               var obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject {
                obj["replayed"] = true
                obj["note"] = "This is the stored result of an earlier call with the same "
                    + "idempotencyKey. No new write was performed."
                payload = JSON.pretty(obj)
            }
            // Wrapped here, after the `replayed` marker is folded in, so the
            // envelope encloses the final body rather than being re-parsed.
            respondTool(id, tool: name, args: args, caller: caller, started: started,
                        text: payload, isError: false, send)
            return
        }
        // Reject unknown arguments instead of ignoring them.
        //
        // The schemas already say `additionalProperties: false`, but nothing
        // enforced it: a caller that guessed `query:` where the tool wanted
        // `search:` had its argument silently dropped and got an unfiltered
        // result back, which looks like success. A model cannot self-correct
        // from that -- it has no signal anything went wrong.
        if let unknown = unknownArguments(args, for: tool) {
            respondTool(id, tool: name, args: args, caller: caller, started: started,
                        text: "Error: \(unknown)", isError: true, send)
            return
        }

        do {
            let raw = try tool.handler(args)
            let value = NoteGuard.filter(tool: name, args: args, value: raw)
            // Only successes are recorded: caching a failure would make a
            // legitimate retry-after-fix return the stale error forever.
            if let idempotencyKey, mutating {
                Idempotency.record(key: idempotencyKey, tool: name, result: value)
            }
            respondTool(id, tool: name, args: args, caller: caller, started: started,
                        text: JSON.pretty(value), isError: false, send)
        } catch let error as ToolError {
            respondTool(id, tool: name, args: args, caller: caller, started: started,
                        text: "Error: \(error.message)", isError: true, send)
        } catch {
            respondTool(id, tool: name, args: args, caller: caller, started: started,
                        text: "Error: \(error.localizedDescription)", isError: true, send)
        }
    }

    /// Returns a human-readable complaint when `args` contains keys the tool's
    /// schema does not declare, or nil when everything is recognised.
    private func unknownArguments(_ args: JSONObject, for tool: Tool) -> String? {
        guard let properties = tool.inputSchema.object("properties") else { return nil }
        let known = Set(properties.keys)
        let unknown = args.keys.filter { !known.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }

        let accepted = known.sorted().joined(separator: ", ")
        let plural = unknown.count == 1 ? "argument" : "arguments"
        return "Unknown \(plural) for \(tool.name): \(unknown.joined(separator: ", ")). "
            + (accepted.isEmpty ? "This tool takes no arguments."
                                : "Accepted arguments: \(accepted).")
    }

    private func handlePromptGet(_ id: Any?, params: JSONObject, _ send: Responder) {
        let name = params.string("name") ?? ""
        guard let prompt = prompts.first(where: { $0.name == name }) else {
            respondError(id, code: -32602, message: "Unknown prompt: \(name)", send)
            return
        }
        let args = params.object("arguments") ?? [:]
        respond(id, result: [
            "description": prompt.description,
            "messages": [
                [
                    "role": "user",
                    "content": ["type": "text", "text": prompt.render(args)]
                ]
            ]
        ], send)
    }

    // MARK: - Output

    /// The one place a tool's text reaches a caller.
    ///
    /// `handleToolCall` used to build a `content` block at five separate exits,
    /// and three of them -- the error paths -- bypassed `NoteGuard` entirely.
    /// That was a real leak, not a tidiness problem: an untargeted `notes_query`
    /// builds an error listing every folder name, which escaped through the
    /// `ToolError` branch without ever meeting the guard. Routing all five
    /// through here means a new exit added later inherits both the guard and the
    /// envelope by construction, instead of by whoever remembers.
    ///
    /// Wrapping happens on the serialized string, after `JSON.pretty`, which is
    /// also what keeps the idempotency cache clean: `Idempotency.record` stores
    /// the pre-serialization value, so a replay re-serializes and wraps exactly
    /// once. Wrapping the value instead would double-wrap on every replay.
    private func respondTool(_ id: Any?, tool: String, args: JSONObject, caller: String?,
                             started: Date, text: String, isError: Bool, _ send: Responder) {
        // Audited here for the same reason the envelope is applied here: this is
        // the one exit every tool call passes through, on both transports.
        AuditLog.record(tool: tool,
                        caller: caller,
                        transport: caller == nil ? "stdio" : "http",
                        outcome: isError ? "error" : "ok",
                        ms: Int(Date().timeIntervalSince(started) * 1000),
                        detail: AuditLog.detail(tool: tool, args: args))
        respond(id, result: [
            "content": [["type": "text", "text": Untrusted.envelope(tool: tool, text: text)]],
            "isError": isError
        ], send)
    }

    private func respond(_ id: Any?, result: JSONObject, _ send: Responder) {
        var msg: JSONObject = ["jsonrpc": "2.0", "result": result]
        msg["id"] = (id == nil || id is NSNull) ? NSNull() : id!
        send(msg)
    }

    private func respondError(_ id: Any?, code: Int, message: String, _ send: Responder) {
        var msg: JSONObject = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        msg["id"] = (id == nil || id is NSNull) ? NSNull() : id!
        send(msg)
    }

    /// A line that failed to parse as JSON used to be dropped silently, which
    /// made a malformed request (e.g. an unescaped quote in a title/notes value
    /// that broke the client's JSON) look like a hang or a mysteriously missing
    /// field. Instead, surface an explicit JSON-RPC parse error, correlating it
    /// to the request id when we can still recover it from the raw text.
    private func emitParseError(_ raw: String, respondWith send: Responder) {
        Log.warn("JSON parse error; raw line (truncated): \(raw.prefix(200))")
        respondError(recoverId(raw), code: -32700, message:
            "Parse error: message was not valid JSON. A likely cause is an argument value " +
            "containing an unescaped control character or double-quote that truncated the JSON. " +
            "Re-send with proper JSON string escaping.", send)
    }

    /// Best-effort extraction of `"id": <number|string>` from an unparseable
    /// line so the error can still be correlated by the client.
    private func recoverId(_ raw: String) -> Any? {
        guard let keyRange = raw.range(of: #""id"\s*:\s*"#, options: .regularExpression) else { return nil }
        let rest = raw[keyRange.upperBound...]
        if let num = rest.range(of: #"^-?\d+"#, options: .regularExpression) {
            return Int(rest[num])
        }
        if let str = rest.range(of: #"^"([^"\\]*)""#, options: .regularExpression) {
            return String(rest[str].dropFirst().dropLast())
        }
        return nil
    }
}
