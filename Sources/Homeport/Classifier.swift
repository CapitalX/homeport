import Foundation

/// Why we landed on a category — returned to the caller so a wrong call can be
/// diagnosed (and corrected) without reading the transcript.
struct Classification {
    let category: RecordingCategory
    let confidence: Double
    /// Category from timing/format alone, before any transcript is read.
    let metadataCategory: RecordingCategory
    /// Category from transcript keyword scoring, if a transcript was available.
    let contentCategory: RecordingCategory?
    let contentScores: [String: Double]
    /// True when the two tiers disagree or neither is confident. The caller may
    /// escalate these to a language model; everything else is decided locally.
    let needsAdjudication: Bool
    let reasons: [String]

    var asJSON: JSONObject {
        var out: JSONObject = [
            "category": category.rawValue,
            "confidence": (confidence * 100).rounded() / 100,
            "metadataCategory": metadataCategory.rawValue,
            "needsAdjudication": needsAdjudication,
            "reasons": reasons
        ]
        if let content = contentCategory { out["contentCategory"] = content.rawValue }
        if !contentScores.isEmpty {
            out["contentScores"] = contentScores.mapValues { ($0 * 100).rounded() / 100 }
        }
        return out
    }
}

/// Two-tier local classifier. Tier 1 uses only timing and file format; tier 2
/// scores transcript vocabulary. Both run entirely on this machine — a language
/// model is only ever needed for the residue where the tiers disagree.
enum RecordingClassifier {

    // MARK: - Tier 1: metadata

    /// Tier 1 asks only: does this recording fall inside a window the operator
    /// defined? No window matches -> unknown, and tier 2 decides alone.
    ///
    /// There are deliberately no built-in windows. A rule like "weekday X between
    /// HH:MM and HH:MM means something" describes one person's week, not a general
    /// truth, and belongs in their config rather than in this binary.
    static func fromMetadata(date: Date, duration: TimeInterval, isQuickTimeAudio: Bool) -> (RecordingCategory, Double, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let weekday = parts.weekday ?? 0
        let minutesIntoDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let minutes = Int(duration / 60)

        for def in Categories.all {
            guard let w = def.window,
                  w.weekdays.contains(weekday),
                  minutesIntoDay >= w.startMinute, minutesIntoDay <= w.endMinute else { continue }
            if minutes < w.minimumDurationMinutes {
                return (.unknown, 0.35,
                        "in the \(def.name) window but only \(minutes) min — under its \(w.minimumDurationMinutes) min floor")
            }
            return (def.category, w.confidence,
                    "\(clock(parts.hour ?? 0, parts.minute ?? 0)), \(minutes) min — \(def.name) window")
        }
        return (.unknown, 0.0, Categories.all.isEmpty
                ? "no categories configured — see deploy/categories.example.json"
                : "outside every configured window")
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    // MARK: - Tier 2: transcript vocabulary

    /// Vocabulary is split by how much a hit actually proves. A term that only
    /// ever means one thing counts fully; an everyday word that merely leans
    /// counts a third, and a category needs corroboration from several DISTINCT
    /// terms before it may override tier 1. Both lists come from config.

    /// Below this, per-1,000-word rates are too jumpy to trust: in an 82-word
    /// memo a single incidental match scores 12/1k and buries everything else.
    private static let minimumWordsForContent = 250

    /// A category must match this many DISTINCT terms before its score counts,
    /// so one repeated word cannot carry a verdict on its own.
    private static let minimumDistinctTerms = 3

    /// Hits per 1,000 words, so a 6,000-word recording and a 600-word memo compare.
    static func fromContent(_ text: String) -> (RecordingCategory, Double, [String: Double])? {
        let words = text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard words.count >= minimumWordsForContent else { return nil }

        let lexicons: [(RecordingCategory, strong: Set<String>, weak: Set<String>)] =
            Categories.all.map { ($0.category, $0.strong, $0.weak) }
        guard !lexicons.isEmpty else { return nil }

        var weighted: [RecordingCategory: Double] = [:]
        var distinct: [RecordingCategory: Set<String>] = [:]
        var distinctStrong: [RecordingCategory: Set<String>] = [:]
        for word in words {
            for (category, strong, weak) in lexicons {
                if strong.contains(word) {
                    weighted[category, default: 0] += 1.0
                    distinct[category, default: []].insert(word)
                    distinctStrong[category, default: []].insert(word)
                } else if weak.contains(word) {
                    weighted[category, default: 0] += 0.35
                    distinct[category, default: []].insert(word)
                }
            }
        }

        var scores: [String: Double] = [:]
        for (category, _, _) in lexicons {
            // Ignore a category that only matched a term or two — that is noise,
            // not evidence.
            let terms = distinct[category]?.count ?? 0
            let rate = (weighted[category] ?? 0) * 1000.0 / Double(words.count)
            scores[category.rawValue] = terms >= minimumDistinctTerms ? rate : 0
        }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value > 0,
              case let winner = RecordingCategory(top.key) else { return nil }
        let runnerUp = ranked.dropFirst().first?.value ?? 0

        // Confidence tracks how far ahead the winner is, not its raw rate: 12 vs
        // 11 is genuinely ambiguous, 12 vs 1 is not. Corroboration by several
        // unambiguous terms is what earns the right to override the clock.
        let margin = top.value - runnerUp
        var confidence = min(0.95, 0.45 + margin / (top.value + 1) * 0.5)
        if (distinctStrong[winner]?.count ?? 0) < 2 {
            confidence = min(confidence, 0.6)
        }
        return (winner, confidence, scores)
    }

    // MARK: - Combined

    static func classify(date: Date, duration: TimeInterval, isQuickTimeAudio: Bool, transcript: String?) -> Classification {
        let (metaCategory, metaConfidence, metaReason) = fromMetadata(
            date: date, duration: duration, isQuickTimeAudio: isQuickTimeAudio)
        var reasons = ["metadata: \(metaReason)"]

        guard let text = transcript, let (contentCategory, contentConfidence, scores) = fromContent(text) else {
            reasons.append(transcript == nil
                ? "content: no transcript available yet (tier 1 only)"
                : "content: transcript too short to score")
            return Classification(
                category: metaCategory,
                confidence: metaConfidence,
                metadataCategory: metaCategory,
                contentCategory: nil,
                contentScores: [:],
                // Without a transcript, anything the clock isn't sure about is
                // worth a second look.
                needsAdjudication: metaConfidence < 0.6 || metaCategory == .unknown,
                reasons: reasons)
        }

        let ordered = scores.sorted { $0.value > $1.value }
            .map { "\($0.key) \(($0.value * 10).rounded() / 10)/1k" }
            .joined(separator: ", ")
        reasons.append("content: \(ordered)")

        if contentCategory == metaCategory {
            reasons.append("both tiers agree")
            return Classification(
                category: contentCategory,
                confidence: min(0.99, max(metaConfidence, contentConfidence) + 0.1),
                metadataCategory: metaCategory,
                contentCategory: contentCategory,
                contentScores: scores,
                needsAdjudication: false,
                reasons: reasons)
        }

        // Disagreement: vocabulary beats the clock, because a window says only
        // when a recording was made, never what is in it. But say so, and flag
        // the call for adjudication unless the content signal is strong.
        //
        // A window match is positional evidence only, so it never outranks a
        // confident content verdict.
        let metadataIsResidual = metaConfidence <= 0.5
        let contentWins = contentConfidence >= 0.65 || metadataIsResidual
        reasons.append(contentWins
            ? (metadataIsResidual
                ? "tiers disagree — metadata was only a weak fallback signal, so content wins"
                : "tiers disagree — content signal is strong, overriding metadata")
            : "tiers disagree and neither is confident")
        return Classification(
            category: contentWins ? contentCategory : metaCategory,
            confidence: contentWins ? contentConfidence : min(metaConfidence, 0.55),
            metadataCategory: metaCategory,
            contentCategory: contentCategory,
            contentScores: scores,
            needsAdjudication: !contentWins,
            reasons: reasons)
    }
}
