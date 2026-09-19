import Foundation

enum VoiceMemoTools {
    static let all: [Tool] = [listTool, transcriptTool, transcribeTool]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func summary(_ memo: VoiceMemo, classification: Classification?) -> JSONObject {
        var out: JSONObject = [
            "id": memo.uniqueId,
            "file": memo.filename,
            "date": dateFormatter.string(from: memo.date),
            "durationMinutes": (memo.duration / 60 * 10).rounded() / 10,
            "hasEmbeddedTranscript": memo.isQuickTimeAudio,
            "untitled": memo.hasDefaultLabel
        ]
        if !memo.hasDefaultLabel, let label = memo.customLabel { out["title"] = label }
        if let folder = memo.folder { out["folder"] = folder }
        if let classification { out["classification"] = classification.asJSON }
        return out
    }

    // MARK: voicememos_list

    private static let listTool = Tool(
        name: "voicememos_list",
        description: """
        List Voice Memos recordings with metadata and an automatic category (from your categories.json; `unknown` when nothing matches). \
        Classification runs entirely on this Mac: tier 1 uses recording time, weekday and duration; tier 2 scores \
        transcript vocabulary when a transcript is available. `needsAdjudication` marks the few where the tiers \
        disagree — only those need a language model to settle. Set `classify` to false for a faster metadata-only listing.
        """,
        inputSchema: Schema.object([
            "limit": Schema.integer("Max recordings to return, newest first (default 25)"),
            "category": Schema.string("Only return this category", enumValues: Categories.names),
            "classify": Schema.boolean("Run classification (default true). False skips reading transcripts."),
            "since": Schema.string("Only recordings on or after this date (yyyy-MM-dd)")
        ]),
        handler: { args in
            let memos = try VoiceMemoStore.all()
            let shouldClassify = args.bool("classify") ?? true
            let limit = args.int("limit") ?? 25

            var since: Date?
            if let raw = args.string("since") {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                f.locale = Locale(identifier: "en_US_POSIX")
                guard let parsed = f.date(from: raw) else {
                    throw ToolError("`since` must be yyyy-MM-dd; got \"\(raw)\".")
                }
                since = parsed
            }

            var rows: [JSONObject] = []
            var counts: [String: Int] = [:]
            for memo in memos {
                if let since, memo.date < since { continue }

                var classification: Classification?
                if shouldClassify {
                    // Use a transcript if one is already available, but never
                    // transcribe during a listing — that would turn a cheap call
                    // into minutes of work. Uncached .m4a files get tier 1 only.
                    let text = memo.isQuickTimeAudio
                        ? (try? EmbeddedTranscript.extract(from: memo.url))??.text
                        : LocalTranscriber.cached(for: memo.url)?.text
                    classification = RecordingClassifier.classify(
                        date: memo.date,
                        duration: memo.duration,
                        isQuickTimeAudio: memo.isQuickTimeAudio,
                        transcript: text)
                }

                if let wanted = args.string("category") {
                    guard classification?.category.rawValue == wanted else { continue }
                }
                if let category = classification?.category.rawValue {
                    counts[category, default: 0] += 1
                }
                rows.append(summary(memo, classification: classification))
                if rows.count >= limit { break }
            }

            var out: JSONObject = ["count": rows.count, "recordings": rows]
            if !counts.isEmpty { out["byCategory"] = counts }
            return out
        }
    )

    // MARK: voicememos_transcript

    private static let transcriptTool = Tool(
        name: "voicememos_transcript",
        description: """
        Return the transcript of one recording. iPhone-recorded .qta files carry a transcript Apple generated \
        on-device; Mac-recorded .m4a files are transcribed locally on first request and cached thereafter. \
        Nothing is ever sent off this machine. Set `segments` to true for word-level timings.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Recording id or filename from voicememos_list"),
            "segments": Schema.boolean("Include word-level timings (default false)"),
            "maxWords": Schema.integer("Truncate to this many words (default: no limit)"),
            "allowOnDevice": Schema.boolean("Transcribe on this Mac when no embedded transcript exists (default true)")
        ], required: ["id"]),
        handler: { args in
            let memo = try VoiceMemoStore.find(id: try requireString(args, "id", "recording id or filename"))
            // Prefer the transcript iOS already embedded; otherwise fall back to
            // transcribing on this Mac (cached, so only the first call is slow).
            var transcript = memo.isQuickTimeAudio
                ? try EmbeddedTranscript.extract(from: memo.url)
                : nil
            if transcript == nil {
                guard args.bool("allowOnDevice") ?? true else {
                    throw ToolError("\(memo.filename) has no embedded transcript and `allowOnDevice` is false.")
                }
                transcript = try LocalTranscriber.transcribe(memo.url)
            }
            guard let transcript else {
                throw ToolError("No transcript available for \(memo.filename).")
            }

            var text = transcript.text
            var truncated = false
            if let maxWords = args.int("maxWords"), maxWords > 0 {
                let words = text.split(separator: " ")
                if words.count > maxWords {
                    text = words.prefix(maxWords).joined(separator: " ")
                    truncated = true
                }
            }

            var out: JSONObject = [
                "id": memo.uniqueId,
                "file": memo.filename,
                "date": dateFormatter.string(from: memo.date),
                "source": transcript.source.rawValue,
                "wordCount": transcript.wordCount,
                "truncated": truncated,
                "text": text
            ]
            if args.bool("segments") == true {
                out["segments"] = transcript.segments.map {
                    ["text": $0.text, "start": ($0.start * 100).rounded() / 100, "end": ($0.end * 100).rounded() / 100]
                }
            }
            return out
        }
    )

    // MARK: voicememos_transcribe

    private static let transcribeTool = Tool(
        name: "voicememos_transcribe",
        description: """
        Transcribe a recording on this Mac using Apple's on-device speech model, and cache the result.         Audio never leaves the machine. Use this to pre-warm Mac-recorded .m4a files (roughly 60x realtime,         so an hour-long recording takes about a minute); voicememos_transcript calls it automatically when needed.
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Recording id or filename from voicememos_list"),
            "force": Schema.boolean("Re-transcribe even if a cached transcript exists (default false)")
        ], required: ["id"]),
        handler: { args in
            let memo = try VoiceMemoStore.find(id: try requireString(args, "id", "recording id or filename"))
            let wasCached = LocalTranscriber.cached(for: memo.url) != nil
            let transcript = try LocalTranscriber.transcribe(memo.url, force: args.bool("force") ?? false)
            return [
                "id": memo.uniqueId,
                "file": memo.filename,
                "source": transcript.source.rawValue,
                "wordCount": transcript.wordCount,
                "fromCache": wasCached && (args.bool("force") ?? false) == false,
                "preview": String(transcript.text.prefix(280))
            ]
        }
    )
}
