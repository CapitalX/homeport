import Foundation

/// A transcript plus where it came from, so callers can tell an Apple-generated
/// transcript from one we produced locally.
struct Transcript {
    enum Source: String {
        /// Extracted from the recording's embedded `com.apple.VoiceMemos.tsrp`
        /// metadata (transcribed on-device by iOS when the memo was recorded).
        case embedded
        /// Produced on this Mac by the Speech framework.
        case onDevice
    }

    let text: String
    let source: Source
    /// Word-level timings, when the payload carried them.
    let segments: [Segment]

    struct Segment {
        let text: String
        let start: Double
        let end: Double
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Extracts the transcript iOS embeds in a `.qta` Voice Memo.
///
/// The payload lives in a QuickTime metadata item keyed
/// `com.apple.VoiceMemos.tsrp`, inside a `meta` atom nested in a `trak` (not at
/// the top level, which is why a naive `moov > meta` lookup misses it). The
/// value is JSON: an attributed string whose `runs` array alternates
/// text fragments with indexes into an `attributeTable` of time ranges.
enum EmbeddedTranscript {

    private static let transcriptKey = "com.apple.VoiceMemos.tsrp"

    /// Atoms whose payload is a sequence of child atoms.
    private static let containers: Set<String> =
        ["moov", "trak", "mdia", "minf", "stbl", "udta"]

    static func extract(from url: URL) throws -> Transcript? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ToolError("Could not open \(url.lastPathComponent): \(error.localizedDescription)") }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        guard let end = size else { return nil }

        guard let payload = findTranscriptPayload(handle, start: 0, end: end, depth: 0) else { return nil }
        return decode(payload)
    }

    // MARK: - Atom walking

    private struct Atom {
        let type: String
        let bodyStart: UInt64
        let end: UInt64
    }

    /// Reads the direct children of the region [start, end).
    private static func children(_ handle: FileHandle, start: UInt64, end: UInt64) -> [Atom] {
        var out: [Atom] = []
        var pos = start
        while pos + 8 <= end {
            handle.seek(toFileOffset: pos)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else { break }

            var size = UInt64(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var body = pos + 8

            if size == 1 {
                // 64-bit extended size follows the header.
                let ext = handle.readData(ofLength: 8)
                guard ext.count == 8 else { break }
                size = ext.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                body = pos + 16
            } else if size == 0 {
                size = end - pos          // runs to the end of the container
            }

            guard size >= 8, pos + size <= end else { break }
            out.append(Atom(type: type, bodyStart: body, end: pos + size))
            pos += size
        }
        return out
    }

    private static func findTranscriptPayload(
        _ handle: FileHandle, start: UInt64, end: UInt64, depth: Int
    ) -> Data? {
        guard depth < 8 else { return nil }
        for atom in children(handle, start: start, end: end) {
            if atom.type == "meta" {
                if let hit = readMeta(handle, atom) { return hit }
            } else if containers.contains(atom.type) {
                if let hit = findTranscriptPayload(handle, start: atom.bodyStart, end: atom.end, depth: depth + 1) {
                    return hit
                }
            }
        }
        return nil
    }

    /// QuickTime `meta` atoms hold their children directly; the ISO-BMFF
    /// variant prefixes four version/flags bytes. Try both rather than guessing.
    private static func readMeta(_ handle: FileHandle, _ meta: Atom) -> Data? {
        for offset in [UInt64(0), UInt64(4)] {
            let base = meta.bodyStart + offset
            guard base < meta.end else { continue }
            let kids = children(handle, start: base, end: meta.end)
            guard let keysAtom = kids.first(where: { $0.type == "keys" }),
                  let ilstAtom = kids.first(where: { $0.type == "ilst" }) else { continue }
            let keys = readKeys(handle, keysAtom)
            guard let index = keys.firstIndex(of: transcriptKey) else { continue }
            if let data = readIlstValue(handle, ilstAtom, keyIndex: index + 1) { return data }
        }
        return nil
    }

    private static func readKeys(_ handle: FileHandle, _ keys: Atom) -> [String] {
        handle.seek(toFileOffset: keys.bodyStart)
        let head = handle.readData(ofLength: 8)          // version/flags + count
        guard head.count == 8 else { return [] }
        let count = Int(head.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).bigEndian })

        var out: [String] = []
        var pos = keys.bodyStart + 8
        for _ in 0..<count {
            guard pos + 8 <= keys.end else { break }
            handle.seek(toFileOffset: pos)
            let header = handle.readData(ofLength: 8)
            guard header.count == 8 else { break }
            let size = UInt64(header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard size >= 8, pos + size <= keys.end else { break }
            let value = handle.readData(ofLength: Int(size) - 8)   // skip the 4-char namespace
            out.append(String(decoding: value, as: UTF8.self))
            pos += size
        }
        return out
    }

    /// `ilst` children are keyed by a 1-based index into the `keys` table, with
    /// the actual bytes in a nested `data` atom (4 bytes type + 4 locale).
    private static func readIlstValue(_ handle: FileHandle, _ ilst: Atom, keyIndex: Int) -> Data? {
        for item in children(handle, start: ilst.bodyStart, end: ilst.end) {
            guard let raw = item.type.data(using: .isoLatin1), raw.count == 4 else { continue }
            let index = Int(raw.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard index == keyIndex else { continue }
            for field in children(handle, start: item.bodyStart, end: item.end) where field.type == "data" {
                let length = Int(field.end - field.bodyStart)
                guard length > 8 else { continue }
                handle.seek(toFileOffset: field.bodyStart + 8)
                return handle.readData(ofLength: length - 8)
            }
        }
        return nil
    }

    // MARK: - Payload decoding

    private static func decode(_ data: Data) -> Transcript? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var text = ""
        var segments: [Transcript.Segment] = []
        collect(root, into: &text, segments: &segments)
        guard !text.isEmpty else { return nil }
        return Transcript(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .embedded,
            segments: segments)
    }

    /// The attributed string has been seen both as a dict and wrapped in an
    /// array, so walk the whole tree for any object carrying `runs` rather than
    /// hard-coding one shape.
    private static func collect(_ node: Any, into text: inout String, segments: inout [Transcript.Segment]) {
        if let dict = node as? [String: Any] {
            if let runs = dict["runs"] as? [Any] {
                let table = (dict["attributeTable"] as? [Any]) ?? []
                var pending: String?
                for element in runs {
                    if let fragment = element as? String {
                        if let previous = pending { text += previous }   // no attribute index followed it
                        pending = fragment
                        continue
                    }
                    guard let fragment = pending else { continue }
                    text += fragment
                    pending = nil
                    if let index = element as? Int,
                       index >= 0, index < table.count,
                       let attributes = table[index] as? [String: Any],
                       let range = attributes["timeRange"] as? [Any], range.count == 2,
                       let start = numeric(range[0]), let end = numeric(range[1]) {
                        segments.append(.init(text: fragment, start: start, end: end))
                    }
                }
                if let trailing = pending { text += trailing }
                return
            }
            for value in dict.values { collect(value, into: &text, segments: &segments) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &text, segments: &segments) }
        }
    }

    private static func numeric(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
