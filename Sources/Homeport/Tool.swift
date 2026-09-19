import Foundation

/// One MCP tool: its advertised schema plus the handler that runs it.
struct Tool {
    let name: String
    let description: String
    let inputSchema: JSONObject
    let handler: (JSONObject) throws -> Any

    var advertised: JSONObject {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}

/// Small helpers for building JSON-Schema fragments without a wall of literals.
enum Schema {
    static func object(_ properties: [String: JSONObject], required: [String] = []) -> JSONObject {
        var schema: JSONObject = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    static func string(_ description: String, enumValues: [String]? = nil) -> JSONObject {
        var s: JSONObject = ["type": "string", "description": description]
        if let e = enumValues { s["enum"] = e }
        return s
    }

    static func integer(_ description: String) -> JSONObject {
        ["type": "integer", "description": description]
    }

    static func number(_ description: String) -> JSONObject {
        ["type": "number", "description": description]
    }

    static func boolean(_ description: String) -> JSONObject {
        ["type": "boolean", "description": description]
    }

    static func array(_ description: String, items: JSONObject) -> JSONObject {
        ["type": "array", "description": description, "items": items]
    }

    /// A free-form object (used for recurrence / alarm sub-objects that we
    /// document in the description rather than exhaustively in schema).
    static func freeObject(_ description: String) -> JSONObject {
        ["type": "object", "description": description]
    }
}
