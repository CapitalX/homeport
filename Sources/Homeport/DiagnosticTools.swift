import Contacts
import EventKit
import Foundation

enum DiagnosticTools {
    static let all: [Tool] = [pingTool]

    /// Cheap, side-effect-free health probe.
    ///
    /// Exists so a caller can tell three failure modes apart without spending a
    /// real call to find out: the Mac is asleep or the daemon is down (no
    /// response at all), a TCC grant is missing (reported per capability here),
    /// or the arguments were wrong (a normal tool error). Previously all three
    /// looked alike from the client side.
    ///
    /// It also reports the tool count and a payload-shape version, so a client
    /// can detect that the server changed underneath it rather than diffing
    /// response shapes by hand.
    private static let pingTool = Tool(
        name: "bridge_ping",
        description: """
        Health check. No side effects, no writes. Returns server version, tool count, and the \\
        live authorization status of each capability (calendar, reminders, contacts, notes, \\
        messages, voicememos) so a failure can be attributed to a missing grant rather than to \\
        bad arguments or an unreachable Mac. Set `warm` true to also pre-launch the Notes \\
        AppleScript path — the first Notes call after a daemon restart takes ~50s while Notes.app \\
        launches, and warming it here keeps that cost off a real request.
        """,
        inputSchema: Schema.object([
            "warm": Schema.boolean("Also warm the Notes/AppleScript path (slower, but only once)")
        ]),
        handler: { args in
            var capabilities: JSONObject = [
                "calendar": describe(EKEventStore.authorizationStatus(for: .event)),
                "reminders": describe(EKEventStore.authorizationStatus(for: .reminder)),
                "contacts": describeContacts(CNContactStore.authorizationStatus(for: .contacts)),
            ]

            // Notes and Messages have no status API -- automation is only
            // observable by trying it, so report what a probe actually found
            // rather than guessing.
            if args.bool("warm") == true {
                let started = Date()
                do {
                    _ = try NotesStore.folders()
                    capabilities["notes"] = "ok (warmed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s)"
                } catch let e as ToolError {
                    capabilities["notes"] = "unavailable: \(e.message.prefix(120))"
                } catch {
                    capabilities["notes"] = "unavailable: \(error.localizedDescription)"
                }
            } else {
                capabilities["notes"] = "not probed (pass warm:true)"
            }

            // Full Disk Access, which gates Voice Memos and Messages history.
            let fdaOK = (try? MessagesStore.ensureReadable()) != nil
            capabilities["messages"] = fdaOK ? "ok (chat.db readable)" : "unavailable: Full Disk Access not granted"
            capabilities["voicememos"] = FileManager.default.isReadableFile(
                atPath: VoiceMemoStore.recordingsURL.path) ? "ok" : "unavailable: Full Disk Access not granted"

            // The only capability that depends on something outside this Mac.
            // Reported here so "why did summarize hang" is one call to answer.
            capabilities["localModel"] = LocalLLM.reachabilitySummary()

            return [
                "ok": true,
                "server": "homeport",
                "version": Version.current,
                "payloadVersion": Version.payload,
                "toolCount": Version.toolCount,
                "transport": ProcessInfo.processInfo.environment["HOMEPORT_HTTP_PORT"] != nil ? "http" : "stdio",
                "time": ISO8601DateFormatter().string(from: Date()),
                "capabilities": capabilities,
                "idempotencyKeysCached": Idempotency.count
            ]
        }
    )

    private static func describe(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess:    return "ok"
        case .writeOnly:     return "writeOnly (cannot read)"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined (never granted)"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private static func describeContacts(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .authorized:    return "ok"
        case .denied:        return "denied"
        case .restricted:    return "restricted"
        case .notDetermined: return "notDetermined (never granted)"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }
}

/// Version surface, so a client can detect a server change rather than
/// discovering it by diffing response shapes.
enum Version {
    static let current = "1.8.0"
    /// Bump whenever a response SHAPE changes in a way a client could notice:
    /// a new field, a renamed key, a different truncation contract.
    static let payload = 4
    static var toolCount: Int { MCPServer.registeredToolCount }
}
