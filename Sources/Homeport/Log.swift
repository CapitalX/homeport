import Foundation

/// All diagnostics go to stderr; stdout is reserved for the MCP JSON-RPC
/// stream and must never contain anything else.
enum Log {
    static func write(_ level: String, _ message: String) {
        let line = "[homeport] \(level): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    static func info(_ message: String) { write("info", message) }
    static func warn(_ message: String) { write("warn", message) }
    static func error(_ message: String) { write("error", message) }
}
