import Foundation

/// Turns a transcript into a structured summary using the local model, then
/// renders it as HTML for Apple Notes.
///
/// Long recordings are summarized map-reduce style: the transcript is chunked,
/// each chunk is condensed, and the condensed notes are reduced into the final
/// answer. A long meeting can run to ~10,000 words, more than a small local
/// model's context will take in one pass.
enum Summarizer {

    /// Chunk size in words. Small enough that chunk + prompt + output stays well
    /// inside the model's context, large enough that a topic is not split across
    /// three chunks.
    private static let chunkWords = 2200
    /// Carried between chunks so a sentence spanning a boundary is not lost.
    private static let overlapWords = 120
    /// Below this, one pass is both cheaper and better than map-reduce.
    private static let singlePassLimit = 2800

    // MARK: - Prompts

    private static let systemPrompt = """
    You summarize transcripts of recordings. The transcripts are produced by \
    automatic speech recognition and often garble words, names and technical \
    terms; infer sensibly from context, but NEVER invent facts, names, \
    commitments, dates or citations that are not in the text. \
    When something is unclear, say so rather than guessing. Reply with JSON only.
    """

    /// The extraction prompt is the category's own, from config. Categories are
    /// operator-defined, so the shapes they ask for are too.
    private static func extractionPrompt(for category: RecordingCategory) -> String {
        Categories.definition(for: category)?.extractionPrompt ?? Categories.fallbackPrompt
    }

    // MARK: - Entry point

    static func summarize(transcript: String, category: RecordingCategory) throws -> JSONObject {
        let words = transcript.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let condensed: String
        var chunkCount = 1

        if words.count > singlePassLimit {
            let chunks = chunk(words)
            chunkCount = chunks.count
            var notes: [String] = []
            for (index, piece) in chunks.enumerated() {
                let note = try LocalLLM.complete(
                    system: systemPrompt,
                    user: """
                    This is part \(index + 1) of \(chunks.count) of a longer transcript. \
                    Condense it into dense factual notes: topics discussed, decisions, \
                    commitments, names, numbers, dates, and anything cited. Keep \
                    everything that a final summary would need. Plain prose, no JSON.

                    TRANSCRIPT PART \(index + 1):
                    \(piece)
                    """,
                    maxTokens: 900)
                notes.append("--- part \(index + 1) ---\n" + note.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            condensed = notes.joined(separator: "\n\n")
        } else {
            condensed = transcript
        }

        let raw = try LocalLLM.complete(
            system: systemPrompt,
            user: extractionPrompt(for: category) + "\n\nTRANSCRIPT:\n" + condensed,
            maxTokens: 1800)

        guard var object = LocalLLM.extractJSON(raw) else {
            throw ToolError("The local model did not return usable JSON. First 200 characters: \(raw.prefix(200))")
        }
        object["_chunks"] = chunkCount
        return object
    }

    private static func chunk(_ words: [String]) -> [[String].SubSequence] {
        var out: [[String].SubSequence] = []
        var start = 0
        while start < words.count {
            let end = min(start + chunkWords, words.count)
            out.append(words[start..<end])
            if end == words.count { break }
            start = end - overlapWords
        }
        return out
    }

    // MARK: - Rendering

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func list(_ values: [Any]?) -> String {
        guard let values, !values.isEmpty else { return "" }
        let items = values.compactMap { value -> String? in
            if let s = value as? String { return "<li>\(escape(s))</li>" }
            if let d = value as? JSONObject {
                // point/detail, or task/owner/due
                if let point = d.string("point") {
                    let detail = d.string("detail").map { " — " + escape($0) } ?? ""
                    return "<li><b>\(escape(point))</b>\(detail)</li>"
                }
                if let task = d.string("task") {
                    var trailer: [String] = []
                    if let owner = d.string("owner"), owner.lowercased() != "unspecified" { trailer.append(escape(owner)) }
                    if let due = d.string("due"), due.lowercased() != "unspecified" { trailer.append("due " + escape(due)) }
                    let suffix = trailer.isEmpty ? "" : " <i>(\(trailer.joined(separator: ", ")))</i>"
                    return "<li>\(escape(task))\(suffix)</li>"
                }
            }
            return nil
        }
        return items.isEmpty ? "" : "<ul>" + items.joined() + "</ul>"
    }

    private static func section(_ heading: String, _ body: String) -> String {
        body.isEmpty ? "" : "<h2>\(heading)</h2>" + body
    }

    static func html(_ summary: JSONObject, category: RecordingCategory, subtitle: String) -> String {
        var out = "<p><i>\(escape(subtitle))</i></p>"
        if let text = summary.string("summary") {
            out += section("Summary", "<p>\(escape(text))</p>")
        }
        let sections = Categories.definition(for: category)?.sections ?? Categories.fallbackSections
        for spec in sections {
            out += section(spec.heading, list(summary.array(spec.key)))
        }
        return out
    }
}
