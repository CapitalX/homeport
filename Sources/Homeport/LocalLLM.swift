import Foundation

/// Client for an OpenAI-compatible chat endpoint running on the user's own
/// hardware (LM Studio, Ollama, llama.cpp -- anything that speaks
/// `/v1/chat/completions`), locally or on another machine over Tailscale.
///
/// This exists so recordings can be summarized without their text ever
/// reaching a third party. Defaults to a model on THIS machine, which is the
/// right assumption for a bridge that already runs where the data lives. Point
/// it elsewhere with `HOMEPORT_LLM_URL` / `HOMEPORT_LLM_MODEL` -- set in the
/// LaunchAgent, so the deployment decides rather than the source.
///
/// App Transport Security: a cleartext URL to `localhost`, a `.local` name or a
/// tailnet `100.x` literal is admitted by `NSAllowsLocalNetworking` in
/// Info.plist. Exception domains match names only, so a cleartext host that is
/// neither local nor named in Info.plist needs an exception adding, or TLS.
/// If you use a MagicDNS name, check that it actually resolves on the bridge
/// host first; not every Tailscale install configures the system resolver.
enum LocalLLM {

    static var endpointString: String {
        ProcessInfo.processInfo.environment["HOMEPORT_LLM_URL"]
            ?? "http://localhost:1234/v1/chat/completions"
    }

    static var model: String {
        ProcessInfo.processInfo.environment["HOMEPORT_LLM_MODEL"]
            ?? "qwen/qwen3-14b"
    }

    /// The default is a Qwen3 model, which is a hybrid reasoning model. For extraction work the thinking pass
    /// roughly doubles wall-clock for no measurable gain, so it is disabled by
    /// default via the `/no_think` control token.
    private static let suppressThinking = "\n\n/no_think"

    static func complete(system: String, user: String, maxTokens: Int = 1500,
                         timeout: TimeInterval = 900, temperature: Double = 0.2) throws -> String {
        guard let url = URL(string: endpointString) else {
            throw ToolError("Invalid local model URL: \(endpointString)")
        }
        let payload: JSONObject = [
            "model": model,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user + suppressThinking]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var result: Result<String, Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(ToolError(
                    "Could not reach the local model at \(endpointString): \(error.localizedDescription). " +
                    "Is the model server running, and reachable from this Mac? Set HOMEPORT_LLM_URL to point elsewhere."))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.map { String(decoding: $0, as: UTF8.self).prefix(300) } ?? ""
                result = .failure(ToolError("Local model returned HTTP \(http.statusCode): \(body)"))
                return
            }
            guard let data,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
                  let choices = root["choices"] as? [JSONObject],
                  let message = choices.first?["message"] as? JSONObject,
                  let content = message.string("content") else {
                result = .failure(ToolError("Local model returned an unreadable response."))
                return
            }
            result = .success(content)
        }.resume()
        done.wait()

        guard let result else { throw ToolError("Local model call finished without a result.") }
        return stripThinking(try result.get())
    }

    /// Some builds still emit a `<think>` block even with `/no_think`.
    private static func stripThinking(_ text: String) -> String {
        guard let end = text.range(of: "</think>") else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Models wrap JSON in prose or fences often enough that asking politely is
    /// not sufficient; recover the outermost object.
    static func extractJSON(_ text: String) -> JSONObject? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = candidate.range(of: "```") {
            let afterFence = candidate[fence.upperBound...]
            let body = afterFence.hasPrefix("json") ? afterFence.dropFirst(4) : afterFence
            if let close = body.range(of: "```") {
                candidate = String(body[..<close.lowerBound])
            }
        }
        guard let start = candidate.firstIndex(of: "{"),
              let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(candidate[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? JSONObject
    }
}

extension LocalLLM {
    /// Whether the configured model endpoint is actually answering.
    ///
    /// `voicememos_summarize` and `reminders_route` are the only tools that need
    /// an external service, and when one is absent the failure used to surface
    /// as an opaque timeout deep inside a summarize call. Surfacing it in
    /// `bridge_ping` alongside the framework grants means "why did summarize
    /// hang" is answerable in one call instead of by reading logs.
    static func reachabilitySummary() -> String {
        guard let url = URL(string: endpointString),
              let host = url.host else { return "unconfigured" }
        let base = "\(url.scheme ?? "http")://\(host):\(url.port ?? 80)/v1/models"
        guard let probe = URL(string: base) else { return "unconfigured" }

        var request = URLRequest(url: probe)
        request.timeoutInterval = 2
        var result = "unreachable at \(host):\(url.port ?? 80) — summarize and route will fail"
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode, (200..<500).contains(code) {
                result = "ok (\(host):\(url.port ?? 80))"
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return result
    }
}
