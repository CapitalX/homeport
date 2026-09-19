import AVFoundation
import Foundation
import Speech

/// On-device transcription for recordings that carry no embedded transcript —
/// in practice the `.m4a` files Voice Memos writes on a Mac.
///
/// This uses `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26), the same engine
/// that produces the transcripts iOS embeds in `.qta` files. It runs on the
/// Neural Engine and never sends audio anywhere: after a one-time model asset
/// download, transcription needs no network at all. That property is the whole
/// reason this exists rather than a cloud speech API — confidential recordings
/// must not leave the machine.
enum LocalTranscriber {

    /// Results are cached next to the bridge's own support files so a long
    /// recording is only ever transcribed once.
    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("homeport/transcripts", isDirectory: true)
    }

    private static func cacheURL(for audio: URL) -> URL {
        cacheDirectory.appendingPathComponent(audio.lastPathComponent + ".json")
    }

    static func cached(for audio: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: cacheURL(for: audio)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let text = root.string("text") else { return nil }
        let segments = (root["segments"] as? [[String: Any]] ?? []).compactMap { item -> Transcript.Segment? in
            guard let t = item["text"] as? String,
                  let start = item.double("start"), let end = item.double("end") else { return nil }
            return Transcript.Segment(text: t, start: start, end: end)
        }
        return Transcript(text: text, source: .onDevice, segments: segments)
    }

    private static func store(_ transcript: Transcript, for audio: URL) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let payload: JSONObject = [
            "text": transcript.text,
            "source": transcript.source.rawValue,
            "segments": transcript.segments.map { ["text": $0.text, "start": $0.start, "end": $0.end] }
        ]
        try? JSON.line(payload).write(to: cacheURL(for: audio))
    }

    // MARK: - Entry point

    /// Transcribes `audio`, returning a cached result when one exists.
    ///
    /// The MCP server handles one request at a time on the main thread and tool
    /// handlers are synchronous, so this blocks on a semaphore while the async
    /// Speech work runs. Nothing in `SpeechAnalyzer` requires the main actor,
    /// so there is no deadlock risk.
    static func transcribe(_ audio: URL, force: Bool = false) throws -> Transcript {
        if !force, let hit = cached(for: audio) { return hit }
        guard #available(macOS 26.0, *) else {
            throw ToolError("On-device transcription needs macOS 26 or later (this Mac is running an older version).")
        }

        var outcome: Result<Transcript, Error>?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { outcome = .success(try await run(audio)) }
            catch { outcome = .failure(error) }
            done.signal()
        }
        done.wait()

        guard let outcome else { throw ToolError("Transcription finished without producing a result.") }
        let transcript = try outcome.get()
        store(transcript, for: audio)
        return transcript
    }

    @available(macOS 26.0, *)
    private static func run(_ audio: URL) async throws -> Transcript {
        guard SpeechTranscriber.isAvailable else {
            throw ToolError("The on-device speech model is unavailable on this Mac.")
        }

        let preferred = Locale(identifier: "en-US")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) ?? preferred
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)

        // First run downloads the language model; afterwards this is a no-op and
        // the whole path is offline.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audio) }
        catch { throw ToolError("Could not read \(audio.lastPathComponent) as audio: \(error.localizedDescription)") }

        // Start draining results before feeding audio: the stream is live and
        // dropping early results would silently truncate the transcript.
        let collector = Task {
            var text = ""
            var segments: [Transcript.Segment] = []
            for try await result in transcriber.results {
                let attributed = result.text
                text += String(attributed.characters)
                for run in attributed.runs {
                    guard let range = run.audioTimeRange else { continue }
                    segments.append(.init(
                        text: String(attributed[run.range].characters),
                        start: range.start.seconds,
                        end: (range.start + range.duration).seconds))
                }
            }
            return (text, segments)
        }

        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, segments) = try await collector.value

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError("Transcription produced no text — the recording may be silent.")
        }
        return Transcript(text: trimmed, source: .onDevice, segments: segments)
    }
}
