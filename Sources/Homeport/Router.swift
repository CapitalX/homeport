import EventKit
import Foundation

/// Decides which list a freshly captured reminder belongs in.
///
/// Measured on a real library: 93% correct from three examples per list, about
/// a second per reminder. That number is the whole argument for doing this
/// locally — the job is classification against *your* lists, not knowledge about
/// the world, and a mid-size local model is not the weak link. The weak link is confidence.
///
/// **Why agreement and not probability.** Self-reported confidence does not
/// separate right from wrong: a model emits 0.75/0.25 for nearly everything,
/// and even the gap between its top two candidates proved one coarse bucket
/// holding good and bad guesses alike. So routing asks several times at
/// temperature (`classifyByVote`) and acts only on a unanimous answer. A
/// genuinely torn title splits the vote; a clear one does not. A held reminder
/// stays in the inbox it was already in, while a misrouted one is a thing you
/// have to go find.
///
/// `Decision.margin` and `defaultMargin` survive only so the deprecated
/// `marginThreshold` argument still parses; nothing gates on them.
enum Router {

    struct Decision {
        let first: String
        let p1: Double
        let second: String?
        let p2: Double
        var margin: Double { p1 - p2 }
    }

    /// Default gate. Above this margin we act; at or below it we leave the
    /// reminder where it is and say why.
    static let defaultMargin = 0.50

    /// Few-shot examples drawn from the user's OWN library rather than invented.
    ///
    /// This is what makes the router personal without any training: "Buy milk
    /// -> Shopping" teaches more about this user's filing than any description
    /// of what a shopping list is. Sampled per list so a large list cannot
    /// drown out a small one.
    /// `excluding` must contain the capture list and every non-destination.
    ///
    /// Learned the hard way: drawing examples from ALL lists teaches the model
    /// that the capture list is a legitimate destination, and it duly proposes
    /// filing a reminder back into the inbox it came from. The example set has
    /// to describe the lists you can route INTO, not every list that exists.
    static func baseExamples(from reminders: [EKReminder], excluding: Set<String> = [],
                             perList: Int = 3) -> [(String, String)] {
        var byList: [String: [String]] = [:]
        for r in reminders {
            guard let list = r.calendar?.title, let title = r.title, !title.isEmpty else { continue }
            guard !excluding.contains(list) else { continue }
            byList[list, default: []].append(title)
        }
        var out: [(String, String)] = []
        for (list, titles) in byList.sorted(by: { $0.key < $1.key }) {
            for title in titles.sorted().prefix(perList) { out.append((title, list)) }
        }
        return out
    }

    /// Corrections to inject.
    ///
    /// Below `retrievalThreshold` every correction goes in — there are too few
    /// for ranking to beat simply including them. Above it, only the nearest
    /// handful should be embedded and retrieved, which is what keeps this prompt
    /// a fixed size as the corpus grows. The selection point lives here so the
    /// switch is one function, not a refactor.
    static func correctionExamples(_ state: OrganizerState, for title: String,
                                   limit: Int = 8) -> [(String, String)] {
        let all = state.corrections.map { ($0.title, $0.to) }
        guard all.count > OrganizerState.retrievalThreshold else { return all }
        // TODO(retrieval): embed once via a local embedding model
        // and rank by cosine against `title`. Until then, most-recent-first is
        // the honest fallback and still bounded.
        return Array(all.suffix(limit))
    }

    /// How many independent samples a vote takes, and how many must agree.
    ///
    /// Self-reported probability turned out to be a poor confidence signal: the
    /// model emits 0.75/0.25 for almost everything, so "margin 0.50" was one
    /// coarse bucket holding both its good guesses and its bad ones — in use, its
    /// proposals at that margin were right only about half the time. Agreement across
    /// independent samples at temperature is a far better signal, because a
    /// genuinely ambiguous title makes the model waver and a clear one does not.
    ///
    /// Unanimity is required. Two-of-three is exactly the wavering case that
    /// should land in front of a human.
    static let votes = 3
    static let temperature = 0.7

    struct Vote {
        let winner: String
        let agreed: Int
        let total: Int
        let tally: [String: Int]
        var unanimous: Bool { agreed == total }
    }

    /// Classify by asking several times and counting. Costs roughly three
    /// model calls instead of one, which is irrelevant at personal volumes.
    static func classifyByVote(title: String, lists: [String],
                               examples: [(String, String)]) throws -> Vote {
        var tally: [String: Int] = [:]
        var firstError: Error?
        for _ in 0..<votes {
            do {
                let d = try classify(title: title, lists: lists, examples: examples,
                                     temperature: temperature)
                tally[d.first, default: 0] += 1
            } catch {
                // One bad sample must not sink the vote; it just lowers the
                // ceiling, and a vote that cannot reach unanimity will hold.
                if firstError == nil { firstError = error }
            }
        }
        guard let best = tally.max(by: { $0.value < $1.value }) else {
            throw firstError ?? ToolError("Router produced no usable answer for \"\(title)\".")
        }
        return Vote(winner: best.key, agreed: best.value, total: votes, tally: tally)
    }

    static func classify(title: String, lists: [String],
                         examples: [(String, String)],
                         temperature: Double = 0.2) throws -> Decision {
        let exampleBlock = examples
            .map { "\"\($0.0)\" -> \($0.1)" }
            .joined(separator: "\n")

        let system = """
        Route one reminder into exactly one list. Return the TWO best candidates with probabilities.

        Lists: \(lists.joined(separator: ", "))

        Examples from this user's own library:
        \(exampleBlock)

        Reply with JSON only:
        {"first":"<list>","p1":0.0-1.0,"second":"<list>","p2":0.0-1.0}

        p1 and p2 need not sum to 1. Be honest: when two lists are genuinely plausible,
        p1 and p2 should be close together. A confident answer means a wide gap.
        """

        let raw = try LocalLLM.complete(system: system, user: title, maxTokens: 90,
                                        timeout: 120, temperature: temperature)
        guard let obj = LocalLLM.extractJSON(raw), let first = obj.string("first") else {
            throw ToolError("Router returned an unreadable answer for \"\(title)\": \(raw.prefix(120))")
        }
        // A hallucinated list name must not create a list or silently pass. It
        // is treated as no answer, which the margin gate then holds.
        guard lists.contains(first) else {
            throw ToolError("Router proposed \"\(first)\", which is not one of your lists.")
        }
        let second = obj.string("second")
        return Decision(first: first,
                        p1: obj.double("p1") ?? 0,
                        second: lists.contains(second ?? "") ? second : nil,
                        p2: obj.double("p2") ?? 0)
    }
}
