import Foundation

/// Loosely-typed JSON object. MCP messages are dynamic, so we work with
/// dictionaries rather than fighting Codable over every optional field.
typealias JSONObject = [String: Any]

/// Error carrying a human-readable message that is surfaced back to the model
/// as an `isError` tool result (not a transport-level JSON-RPC error).
struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Fetch a required string argument, or throw an error that NAMES the keys we
/// actually received. If an upstream client produced malformed JSON (e.g. an
/// unescaped double-quote inside a notes/title value that truncated the
/// arguments object), the dropped field shows up immediately as "missing from
/// [the keys that survived]" instead of looking like a mysterious server bug.
func requireString(_ args: JSONObject, _ key: String, _ hint: String) throws -> String {
    if let v = args.string(key), !v.isEmpty { return v }
    let received = args.keys.sorted().joined(separator: ", ")
    throw ToolError("`\(key)` is required (\(hint)). Received argument keys: [\(received)]")
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let i = self[key] as? Int { return i }
        if let n = self[key] as? NSNumber { return n.intValue }
        if let d = self[key] as? Double { return Int(d) }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let d = self[key] as? Double { return d }
        if let n = self[key] as? NSNumber { return n.doubleValue }
        if let i = self[key] as? Int { return Double(i) }
        if let s = self[key] as? String { return Double(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        if let i = self[key] as? Int { return i != 0 }
        if let s = self[key] as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func object(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
    }

    func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    func stringArray(_ key: String) -> [String]? {
        (self[key] as? [Any])?.compactMap { $0 as? String }
    }

    func intArray(_ key: String) -> [Int]? {
        (self[key] as? [Any])?.compactMap {
            if let i = $0 as? Int { return i }
            if let n = $0 as? NSNumber { return n.intValue }
            return nil
        }
    }
}

enum JSON {
    /// Serialize a JSON value to a single line (no embedded newlines) for the
    /// MCP stdio transport.
    static func line(_ value: Any) -> Data {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return data
        }
        return Data("{}".utf8)
    }

    /// Pretty-printed JSON used inside tool text results so the model gets
    /// readable output.
    static func pretty(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }
}
