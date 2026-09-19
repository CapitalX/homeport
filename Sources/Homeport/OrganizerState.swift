import CryptoKit
import EventKit
import Foundation

/// What the organizer did, so it can tell its own work from yours.
///
/// Everything here exists to answer one question: **did the user change this, or
/// did we?** Without an answer, a nightly job re-decides the same reminder every
/// night and quietly overrides the correction you made this morning. That is the
/// failure that makes people turn these things off.
///
/// The record is a *fingerprint taken at write time* — the list we put it in, the
/// due date we set, and a hash of the title as it was. Any later divergence that
/// we did not cause is, by elimination, you. That is a different mechanism from
/// the live-loop suppression the change observer needs (which drops
/// notifications caused by our own writes, within seconds). This one catches an
/// edit made hours later, on a phone, while the daemon was not watching. Both
/// are needed; neither substitutes for the other.
///
/// **A correction is permanent.** Once you move something we placed, that
/// reminder is pinned and no pass touches it again. A tool that argues with you
/// twice is worse than one that never helped.
///
/// Single JSON document, written tmp-then-rename so a crash mid-write cannot
/// leave a half-parsed state file that fails closed into "I have never seen any
/// of these reminders."
struct OrganizerState: Codable {

    /// What we did to one reminder, as it was when we did it.
    struct Claim: Codable {
        var routedTo: String?        // list we moved it into
        /// Set when the margin gate HELD instead of moving: what we would have
        /// chosen, and where the reminder was sitting when we declined.
        ///
        /// Held items are the most valuable training signal there is — they are
        /// precisely the cases the model could not call. Recording only the
        /// moves threw that away: the user files the reminder by hand, nothing
        /// diverges from a claim that was never made, and the router asks the
        /// same unanswerable question next week.
        var proposedList: String?
        var capturedIn: String?
        /// True when the low-priority "I could not file this" marker was set BY
        /// US. Only then may it be cleared again — a priority the user set
        /// themselves is theirs, and silently clearing it would be a small
        /// betrayal of exactly the kind that makes people switch a tool off.
        var markedLowPriority: Bool = false
        var dueSetTo: String?        // ISO8601 due we wrote
        var titleHash: String        // title at the time
        var at: String               // when we acted
        var confidence: Double?
        var runnerUp: String?
        /// Set once the user diverges from the claim. Never cleared.
        var pinned: Bool = false
        var pinnedReason: String?
    }

    /// One thing we got wrong, kept as training data.
    ///
    /// `embedding` is optional and unset today. The corpus starts empty, so
    /// retrieval has nothing to retrieve; every correction goes in the prompt
    /// until there are enough to be worth ranking. Once the count passes
    /// `retrievalThreshold`, these are embedded once and only the nearest few
    /// are injected — which is what keeps the prompt a constant size no matter
    /// how many corrections accumulate.
    struct Correction: Codable {
        var title: String
        var from: String             // where we put it
        var to: String               // where you moved it
        var at: String
        var embedding: [Double]?
    }

    var claims: [String: Claim] = [:]
    var corrections: [Correction] = []

    /// Below this, inject every correction; above it, embed and retrieve.
    /// Retrieval on a handful of examples costs a round trip to rank items that
    /// would all have fitted anyway.
    static let retrievalThreshold = 25

    // MARK: - Persistence

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/homeport/organizer-state.json")

    static func load() -> OrganizerState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(OrganizerState.self, from: data) else {
            return OrganizerState()
        }
        return state
    }

    /// tmp + rename. A torn write here would read back as "no claims", and the
    /// next pass would re-route everything the user had already corrected.
    func save() throws {
        let dir = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = Self.url.appendingPathExtension("tmp")
        try encoder.encode(self).write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(Self.url, withItemAt: tmp)
    }

    // MARK: - Fingerprints

    static func hash(_ title: String) -> String {
        let digest = SHA256.hash(data: Data(title.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Correction detection

    struct Divergence {
        let id: String
        let kind: String        // routing | schedule | rewritten | vanished
        let detail: String
        let correction: Correction?
    }

    /// Compare live reminders against what we claimed, and pin anything the user
    /// has touched. Returns what changed, so a caller can report it and feed the
    /// routing corrections back into the prompt.
    ///
    /// Reminders we never claimed are ignored entirely: this only ever looks at
    /// our own past decisions, never at the user's untouched library.
    mutating func reconcile(against live: [EKReminder]) -> [Divergence] {
        var byId: [String: EKReminder] = [:]
        for r in live { byId[r.calendarItemIdentifier] = r }

        var found: [Divergence] = []
        for (id, claim) in claims where !claim.pinned {
            guard let reminder = byId[id] else {
                // Deleted or completed out from under us. Drop the claim rather
                // than pinning: there is nothing left to protect.
                claims.removeValue(forKey: id)
                found.append(Divergence(id: id, kind: "vanished",
                                        detail: "no longer present", correction: nil))
                continue
            }
            let title = reminder.title ?? ""
            if Self.hash(title) != claim.titleHash {
                claims[id] = nil
                found.append(Divergence(id: id, kind: "rewritten",
                                        detail: "title changed; our claim no longer applies",
                                        correction: nil))
                continue
            }
            let nowList = reminder.calendar?.title ?? ""

            // A held item the user has since filed themselves. We never moved
            // it, so there is no wrong decision to correct — but there IS an
            // answer to the question we could not answer, which is worth more.
            if claim.routedTo == nil, let proposed = claim.proposedList,
               let capturedIn = claim.capturedIn, nowList != capturedIn, !nowList.isEmpty {
                var resolved = claim
                resolved.pinned = true
                resolved.pinnedReason = "you filed it into \(nowList) after we held it"
                claims[id] = resolved
                let correction = Correction(title: title, from: proposed, to: nowList,
                                            at: Self.iso(Date()), embedding: nil)
                corrections.append(correction)
                found.append(Divergence(id: id, kind: "resolved-hold",
                                        detail: "held (\(proposed)?) → you chose \(nowList)",
                                        correction: correction))
                continue
            }

            if let routedTo = claim.routedTo, nowList != routedTo {
                var pinnedClaim = claim
                pinnedClaim.pinned = true
                pinnedClaim.pinnedReason = "you moved it from \(routedTo) to \(nowList)"
                claims[id] = pinnedClaim
                let correction = Correction(title: title, from: routedTo, to: nowList,
                                            at: Self.iso(Date()), embedding: nil)
                corrections.append(correction)
                found.append(Divergence(id: id, kind: "routing",
                                        detail: "\(routedTo) → \(nowList)", correction: correction))
                continue
            }
            if let dueSetTo = claim.dueSetTo {
                let nowDue = reminder.dueDateComponents
                    .flatMap { Calendar.current.date(from: $0) }
                    .map { Self.iso($0) }
                if nowDue != dueSetTo {
                    var pinnedClaim = claim
                    pinnedClaim.pinned = true
                    pinnedClaim.pinnedReason = "you rescheduled it"
                    claims[id] = pinnedClaim
                    found.append(Divergence(id: id, kind: "schedule",
                                            detail: "\(dueSetTo) → \(nowDue ?? "cleared")",
                                            correction: nil))
                }
            }
        }
        return found
    }

    func isPinned(_ id: String) -> Bool { claims[id]?.pinned == true }

    /// Have we already held this exact reminder, and is the question unchanged?
    ///
    /// Without this the poll re-asks the model the same unanswerable question
    /// every interval — held items were re-classified on every poll,
    /// burning a model call each time and filling the log with identical lines.
    /// A hold is an answer ("I cannot tell"), and it stays the answer until the
    /// reminder itself changes.
    func alreadyHeld(_ id: String, title: String) -> Bool {
        guard let claim = claims[id], claim.routedTo == nil,
              claim.proposedList != nil else { return false }
        return claim.titleHash == Self.hash(title)
    }
}
