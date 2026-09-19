import Foundation
import Network

/// MCP over Streamable HTTP, for tailnet clients.
///
/// Binds **127.0.0.1 only**. Binding 0.0.0.0 would put Calendar and Contacts
/// write access on every untrusted network the Mac joins; `tailscale
/// serve` fronts the loopback listener with a real TLS cert instead, so the only
/// way in is over WireGuard from an authenticated tailnet node.
///
/// A deliberate subset of the spec — every response here is immediate and small,
/// so there is no server-initiated stream to offer:
///   POST   /mcp  → dispatch, reply application/json
///   GET    /mcp  → 405 (the spec permits declining to offer SSE)
///   DELETE /mcp  → 204
///
/// Connections are accepted concurrently but every dispatch hops onto one serial
/// queue, preserving the single-request-at-a-time invariant `MCPServer` documents.
final class HTTPTransport {

    private let server: MCPServer
    private let port: NWEndpoint.Port
    private let listener: NWListener
    /// The invariant. Everything that touches EventKit/Contacts runs here.
    /// Shared with the background observer so both honour one invariant. See
    /// `BridgeQueue`.
    private let dispatchQueue = BridgeQueue.eventKit
    private let acceptQueue = DispatchQueue(label: "dev.homeport.bridge.accept")

    init?(port rawPort: UInt16, server: MCPServer) {
        guard let p = NWEndpoint.Port(rawValue: rawPort) else { return nil }
        self.server = server
        self.port = p

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only. This is the security boundary, not a default.
        //
        // The port comes from requiredLocalEndpoint, NOT from NWListener's `on:`
        // argument -- passing both conflicts and the initializer throws.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: p)

        do {
            self.listener = try NWListener(using: params)
        } catch {
            Log.warn("http: could not create listener on 127.0.0.1:\(rawPort): \(error)")
            return nil
        }
    }

    func run() -> Never {
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:  Log.info("http: listening on 127.0.0.1:\(self.port)")
            case .failed(let e): Log.warn("http: listener failed: \(e)"); exit(1)
            default: break
            }
        }
        // Warm Notes.app before anyone asks for it.
        //
        // The first Apple Event after a daemon start has to LAUNCH Notes.app,
        // which can take about a minute, versus about a second once it is running. Because
        // every tool call shares one serial dispatch queue, that first caller
        // blocks every other device for a minute. AppleScript's `with timeout`
        // does not help: it bounds individual events, not the app launch.
        //
        // Queueing the warm-up as the FIRST item on the dispatch queue means it
        // runs before any request rather than in the middle of one, and it
        // respects the same serialization as everything else. Failure is
        // deliberately ignored -- this is an optimization, and Notes may simply
        // not be set up on a given machine.
        // Off the shared queue. Notes now serialises against Notes via its own
        // lock, so a slow warm-up delays only other Notes work -- not reminder
        // routing, not calendar queries, not the tailnet endpoint.
        BridgeQueue.background.async {
            let started = Date()
            // Launch only. Enumerating folders here cost minutes and bought
            // nothing the first real query would not do anyway.
            try? NotesStore.ping()
            // Build the read-guard's protected-id set here too. Otherwise the
            // first notes call pays for it, and it lands as a SECOND AppleScript
            // immediately after the query's own -- the back-to-back pattern that
            // fails with -1712 about one time in three.
            NoteGuard.warm()
            Log.info("http: warmed Notes in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }

        listener.start(queue: acceptQueue)
        dispatchMain()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: acceptQueue)
        receive(conn, buffer: Data())
    }

    /// Accumulate until headers plus the full Content-Length body have arrived.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }

            if let error {
                Log.warn("http: receive error: \(error)")
                conn.cancel(); return
            }

            if let request = HTTPRequest(buf) {
                self.handle(request, on: conn)
                return
            }
            if done {
                conn.cancel(); return
            }
            self.receive(conn, buffer: buf) // incomplete; keep reading
        }
    }

    private func handle(_ req: HTTPRequest, on conn: NWConnection) {
        // Guard against DNS rebinding, which the MCP spec calls out explicitly:
        // a browser on some page must not be able to drive this.
        if let origin = req.header("origin"), !Self.originAllowed(origin) {
            return respond(conn, status: 403, json: ["error": "Origin not allowed: \(origin)"])
        }

        guard req.path.hasPrefix("/mcp") else {
            return respond(conn, status: 404, json: ["error": "Not found. The MCP endpoint is /mcp."])
        }

        switch req.method {
        case "GET":
            // No SSE stream on offer; the spec allows saying so.
            return respond(conn, status: 405, json: ["error": "This server does not offer an SSE stream. POST JSON-RPC to /mcp."])
        case "DELETE":
            return respond(conn, status: 204, json: nil)
        case "POST":
            break
        default:
            return respond(conn, status: 405, json: ["error": "Method not allowed: \(req.method)"])
        }

        // Identity comes from headers `tailscale serve` overwrites, not from a
        // shared secret. Their absence means the request did not arrive through
        // serve, which is the only supported route in.
        guard let caller = TailnetIdentity.resolve(
                userLogin: req.header("tailscale-user-login"),
                forwardedFor: req.header("x-forwarded-for")) else {
            return respond(conn, status: 401, json: ["error":
                "No Tailscale identity on this request. Reach this service through its "
                + "`tailscale serve` HTTPS endpoint from a tailnet device, not by "
                + "connecting to this port directly."])
        }

        guard let body = String(data: req.body, encoding: .utf8),
              let data = body.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            return respond(conn, status: 400, json: [
                "jsonrpc": "2.0", "id": NSNull(),
                "error": ["code": -32700, "message": "Parse error: body was not valid JSON."]
            ])
        }

        do {
            try Auth.authorize(msg, as: caller)
        } catch let denial as Auth.Denial {
            Log.warn("http: \(Auth.nodeName(for: caller) ?? caller.address) denied — \(denial.message)")
            return respond(conn, status: denial.status, json: ["error": denial.message])
        } catch {
            return respond(conn, status: 403, json: ["error": "\(error)"])
        }

        let method = msg.string("method") ?? ""
        let toolName = (msg.object("params") ?? [:]).string("name")
        Log.info("http: \(Auth.nodeName(for: caller) ?? caller.address) (\(caller.label)) → \(method)\(toolName.map { " \($0)" } ?? "")")

        // Serialize: this is where the single-threaded invariant is enforced.
        dispatchQueue.async { [weak self] in
            guard let self else { return }
            var reply: JSONObject?
            let who = Auth.nodeName(for: caller) ?? caller.address
            self.server.handle(msg, caller: who) { reply = $0 }
            // Notifications produce no reply; 202 is the spec's answer for those.
            if let reply {
                self.respond(conn, status: 200, json: reply)
            } else {
                self.respond(conn, status: 202, json: nil)
            }
        }
    }

    /// Tailscale Serve proxies from loopback, so requests legitimately arrive
    /// with no Origin at all. Only reject an Origin that is present and foreign.
    private static func originAllowed(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host.hasSuffix(".ts.net")
    }

    private func respond(_ conn: NWConnection, status: Int, json: JSONObject?) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var bodyData = Data()
        if let json {
            bodyData = JSON.line(json)
            head += "Content-Type: application/json\r\n"
        }
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default:  return "Error"
        }
    }
}

/// Just enough HTTP/1.1 to serve one JSON-RPC endpoint. Returns nil until the
/// buffer holds a complete request, so the caller knows to keep reading.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased names
    let body: Data

    init?(_ buffer: Data) {
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<sep.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        self.method = String(requestLine[0]).uppercased()
        self.path = String(requestLine[1])

        var h: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            h[name] = value
        }
        self.headers = h

        let expected = Int(h["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        let available = buffer.count - bodyStart
        guard available >= expected else { return nil } // keep reading
        self.body = buffer.subdata(in: bodyStart..<(bodyStart + expected))
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}
