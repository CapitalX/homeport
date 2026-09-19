import EventKit
import Foundation

enum SummaryTools {
    static let all: [Tool] = [summarizeTool]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func classify(_ memo: VoiceMemo, transcript: String?) -> Classification {
        RecordingClassifier.classify(
            date: memo.date, duration: memo.duration,
            isQuickTimeAudio: memo.isQuickTimeAudio, transcript: transcript)
    }

    private static let summarizeTool = Tool(
        name: "voicememos_summarize",
        description: """
        Summarize a recording with the LOCAL model and file the result. Recordings in a category marked \
        confidential (and uncategorized ones) are summarized on your own hardware and written straight into Apple \
        Notes — the summary text is NOT returned to the caller, so their content never leaves your machines. Categories marked non-confidential are returned inline as well as filed. \
        Action items can additionally become Reminders, for categories configured with createReminders. Long recordings are chunked map-reduce style. \
        Set `deliver` to "return" to get the text back instead of filing it (blocked for confidential categories \
        unless `confirmMayLeaveMachine` is true).
        """,
        inputSchema: Schema.object([
            "id": Schema.string("Recording id or filename from voicememos_list"),
            "deliver": Schema.string("note (default) | return | both", enumValues: ["note", "return", "both"]),
            "folder": Schema.string("Notes folder override (defaults by category)"),
            "category": Schema.string("Override the automatic category", enumValues: Categories.names),
            "createReminders": Schema.boolean("Create Reminders for action items (default: the category's createReminders setting)"),
            "remindersList": Schema.string("Reminders list for action items (default: your default list)"),
            "confirmMayLeaveMachine": Schema.boolean("Allow returning confidential-category text to the caller (default false)")
        ], required: ["id"]),
        handler: { args in
            let memo = try VoiceMemoStore.find(id: try requireString(args, "id", "recording id or filename"))

            // Transcript first: embedded when iOS made one, otherwise on-device.
            var transcript = memo.isQuickTimeAudio ? try EmbeddedTranscript.extract(from: memo.url) : nil
            if transcript == nil { transcript = try LocalTranscriber.transcribe(memo.url) }
            guard let transcript, !transcript.text.isEmpty else {
                throw ToolError("No transcript available for \(memo.filename).")
            }

            let classification = classify(memo, transcript: transcript.text)
            let category = Categories.parse(args.string("category"))
                ?? classification.category
            // Confidentiality is a property of the category, declared in config.
            // Unknown is treated as confidential: if we could not tell what a
            // recording is, it does not leave the machine.
            let isConfidential = Categories.definition(for: category)?.confidential ?? true

            let deliver = args.string("deliver") ?? "note"
            let wantsText = deliver == "return" || deliver == "both"
            let confirmed = args.bool("confirmMayLeaveMachine") ?? false
            if wantsText && isConfidential && !confirmed {
                throw ToolError(
                    "This recording is classified `\(category.rawValue)`, so its summary is not returned to the " +
                    "caller — that would send it off this machine. It has NOT been summarized. Re-run with " +
                    "deliver=\"note\" to file it into Apple Notes, or pass confirmMayLeaveMachine=true to override.")
            }

            let summary = try Summarizer.summarize(transcript: transcript.text, category: category)
            let title = summary.string("title").flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(category.rawValue.capitalized) — \(memo.filename)"
            let minutes = Int((memo.duration / 60).rounded())
            let subtitle = "Recorded \(dateFormatter.string(from: memo.date)) · \(minutes) min · " +
                "transcript \(transcript.source == .embedded ? "from iOS" : "generated on this Mac")"

            var receipt: JSONObject = [
                "id": memo.uniqueId,
                "file": memo.filename,
                "category": category.rawValue,
                "confidence": (classification.confidence * 100).rounded() / 100,
                "title": title,
                "wordCount": transcript.wordCount,
                "chunks": summary["_chunks"] ?? 1,
                "summarizedBy": "local:\(LocalLLM.model)",
                "leftThisMachine": false
            ]

            if deliver == "note" || deliver == "both" {
                let folder = args.string("folder")
                    ?? Categories.definition(for: category)?.folder
                    ?? "Notes"
                let html = Summarizer.html(summary, category: category, subtitle: subtitle)
                receipt["note"] = try NotesStore.create(
                    folder: folder, account: nil, title: title, bodyHTML: html)
            }

            // Reminders are where a work action item actually becomes actionable;
            // Notes has no scriptable checklist type.
            // Whether a category's action items become reminders is its own
            // declaration, not a property of one hardcoded category.
            let shouldRemind = args.bool("createReminders")
                ?? (Categories.definition(for: category)?.createReminders ?? false)
            if shouldRemind, let items = summary.array("actionItems") {
                // The note is the primary deliverable and is already written by
                // now. A Reminders permission problem must not be reported as a
                // total failure -- that would send the caller off to re-run a
                // summarization that already succeeded (and cost minutes of
                // local inference). Degrade to a warning instead.
                do {
                    receipt["remindersCreated"] = try createReminders(
                        items, title: title, memo: memo, list: args.string("remindersList"))
                } catch let error as ToolError {
                    receipt["remindersCreated"] = 0
                    receipt["remindersWarning"] = error.message
                } catch {
                    receipt["remindersCreated"] = 0
                    receipt["remindersWarning"] = error.localizedDescription
                }
            }

            if wantsText {
                receipt["summary"] = summary.filter { $0.key != "_chunks" }
                receipt["leftThisMachine"] = isConfidential && confirmed
            }
            return receipt
        }
    )

    /// Creates one reminder per action item. Notes exposes no scriptable
    /// checklist type, so this is where an item actually becomes actionable.
    private static func createReminders(_ items: [Any], title: String, memo: VoiceMemo, list: String?) throws -> Int {
        var created = 0
        let store = EventKitStore.shared
        try store.ensureAccess(.reminder)
        do {
            for item in items {
                guard let fields = item as? JSONObject,
                      let task = fields.string("task"), !task.isEmpty else { continue }
                let reminder = EKReminder(eventStore: store.store)
                reminder.title = task
                reminder.calendar = store.reminderList(id: nil, name: list)
                    ?? store.store.defaultCalendarForNewReminders()
                guard reminder.calendar != nil else {
                    throw ToolError("No Reminders list available (and no default list is set).")
                }
                var notes = ["From \"\(title)\" (\(memo.filename))"]
                if let owner = fields.string("owner"), owner.lowercased() != "unspecified" {
                    notes.append("Owner: \(owner)")
                }
                if let due = fields.string("due"), due.lowercased() != "unspecified" {
                    notes.append("Stated due: \(due)")
                }
                reminder.notes = notes.joined(separator: "\n")
                try store.store.save(reminder, commit: true)
                created += 1
            }
        }
        return created
    }
}
