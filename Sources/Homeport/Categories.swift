import Foundation

/// What a recording is. Not an enum, because the set of categories is the
/// operator's to define — see `Categories`.
struct RecordingCategory: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }

    /// The category everything falls back to: no window matched, no vocabulary
    /// scored, or no configuration exists at all.
    static let unknown = RecordingCategory("unknown")
    var isUnknown: Bool { self == .unknown }
}

/// One category's definition: when it applies, what it means, and what to do
/// with a recording that lands in it.
struct CategoryDefinition {
    /// Weekday/clock/duration rule for tier-1 classification.
    struct Window {
        let weekdays: Set<Int>          // 1 = Sunday, per Foundation
        let startMinute: Int            // minutes into the day, inclusive
        let endMinute: Int              // inclusive
        let minimumDurationMinutes: Int
        let confidence: Double
    }
    /// One rendered section of the filed note: a heading and the summary key
    /// whose array it draws from.
    struct Section { let heading: String; let key: String }

    let name: String
    let strong: Set<String>
    let weak: Set<String>
    let window: Window?
    /// When true, a summary of this category is written straight to Notes and
    /// NEVER returned to the caller. This is the privacy rule, expressed as
    /// configuration rather than compiled in.
    let confidential: Bool
    let folder: String?
    let createReminders: Bool
    let extractionPrompt: String
    let sections: [Section]

    var category: RecordingCategory { RecordingCategory(name) }
}

/// Categories are configuration, not code.
///
/// A taxonomy compiled into the binary -- vocabulary lists, time-of-day rules --
/// would be useless to anyone whose life it did not describe, and would ship
/// details about one operator to every adopter. So the operator supplies the
/// taxonomy and the binary supplies only the machinery.
///
/// Config lives at `~/Library/Application Support/homeport/categories.json`.
/// `deploy/categories.example.json` is a neutral starting point — copy it there
/// and edit. With no file present, classification always returns `unknown` and
/// summarization uses a generic prompt; nothing breaks, it just stops guessing.
enum Categories {

    private(set) static var all: [CategoryDefinition] = load()

    static var names: [String] { all.map(\.name) + [RecordingCategory.unknown.rawValue] }

    static func definition(for category: RecordingCategory) -> CategoryDefinition? {
        all.first { $0.name == category.rawValue }
    }

    /// Validate a caller-supplied category name against the configured set.
    static func parse(_ raw: String?) -> RecordingCategory? {
        guard let raw else { return nil }
        if raw == RecordingCategory.unknown.rawValue { return .unknown }
        return all.first { $0.name == raw }.map { RecordingCategory($0.name) }
    }

    /// Used when a category has no definition, or none is configured at all.
    static let fallbackPrompt = """
    Summarize this recording. Return ONLY this JSON shape:
    {"title":"<6 words max>",
     "summary":"<2-3 sentences>",
     "points":["<notable point>"]}
    Be plain and factual. Do not offer advice, diagnosis or judgement.
    """
    static let fallbackSections = [CategoryDefinition.Section(heading: "Points", key: "points")]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/homeport/categories.json")
    }

    /// Re-read the file. Exposed for tests; the daemon loads once at startup.
    @discardableResult
    static func reload() -> [CategoryDefinition] { all = load(); return all }

    private static func load() -> [CategoryDefinition] {
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let raw = root["categories"] as? [JSONObject] else {
            return []
        }
        let parsed = raw.compactMap(parseOne)
        Log.info("categories: loaded \(parsed.count) from \(configURL.lastPathComponent)")
        return parsed
    }

    private static func parseOne(_ o: JSONObject) -> CategoryDefinition? {
        guard let name = o.string("name"), !name.isEmpty,
              name != RecordingCategory.unknown.rawValue else { return nil }

        var window: CategoryDefinition.Window?
        if let w = o.object("window") {
            let days = Set((w["weekdays"] as? [Int]) ?? [])
            if !days.isEmpty {
                window = .init(weekdays: days,
                               startMinute: w.int("startMinute") ?? 0,
                               endMinute: w.int("endMinute") ?? 24 * 60,
                               minimumDurationMinutes: w.int("minimumDurationMinutes") ?? 0,
                               confidence: (w["confidence"] as? Double) ?? 0.7)
            }
        }
        let sections = ((o["sections"] as? [JSONObject]) ?? []).compactMap { s -> CategoryDefinition.Section? in
            guard let h = s.string("heading"), let k = s.string("key") else { return nil }
            return .init(heading: h, key: k)
        }
        return CategoryDefinition(
            name: name,
            strong: Set(((o["strong"] as? [String]) ?? []).map { $0.lowercased() }),
            weak: Set(((o["weak"] as? [String]) ?? []).map { $0.lowercased() }),
            window: window,
            confidential: (o["confidential"] as? Bool) ?? true,
            folder: o.string("folder"),
            createReminders: (o["createReminders"] as? Bool) ?? false,
            extractionPrompt: o.string("extractionPrompt") ?? fallbackPrompt,
            sections: sections.isEmpty ? fallbackSections : sections)
    }
}
