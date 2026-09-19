import Foundation

/// Newline-delimited JSON-RPC over stdin/stdout — the transport every local MCP
/// client (Claude Desktop, Claude Code) uses when it spawns this binary.
///
/// Lifted verbatim out of `MCPServer.run()` when the output sink became
/// pluggable. Behavior here must stay byte-identical to the pre-refactor server:
/// no framing headers, one JSON object per line, stderr reserved for logs.
enum StdioTransport {

    static func run(server: MCPServer) {
        let out = FileHandle.standardOutput
        let send: Responder = { msg in
            var data = JSON.line(msg)
            data.append(0x0A) // newline delimiter
            out.write(data)
        }

        while let line = readLine(strippingNewline: true) {
            server.handleRawLine(line, respondWith: send)
        }
        Log.info("stdin closed; exiting")
    }
}
