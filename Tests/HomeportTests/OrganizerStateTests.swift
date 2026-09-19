import EventKit
import XCTest
@testable import Homeport

/// The organizer's whole value depends on telling its own work from the user's.
/// These cover that boundary. Pure — EKReminder instances need no TCC grant.
final class OrganizerStateTests: XCTestCase {

    private let store = EKEventStore()

    private func reminder(_ title: String, list: String, id: String? = nil) -> EKReminder {
        let r = EKReminder(eventStore: store)
        r.title = title
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = list
        r.calendar = cal
        return r
    }

    func testTitleHashIsStableAcrossCalls() {
        // Swift's Hasher is seeded per process; a fingerprint that changed on
        // restart would report every reminder as rewritten.
        XCTAssertEqual(OrganizerState.hash("Call mom"), OrganizerState.hash("Call mom"))
        XCTAssertNotEqual(OrganizerState.hash("Call mom"), OrganizerState.hash("Call dad"))
    }

    func testMovingOurDecisionIsDetectedPinnedAndLearned() {
        var state = OrganizerState()
        let r = reminder("Update the quarterly report", list: "Projects")   // user moved it here
        state.claims[r.calendarItemIdentifier] = .init(
            routedTo: "Work", dueSetTo: nil,
            titleHash: OrganizerState.hash("Update the quarterly report"),
            at: "now", confidence: 0.85, runnerUp: "Projects")

        let found = state.reconcile(against: [r])

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.kind, "routing")
        XCTAssertTrue(state.isPinned(r.calendarItemIdentifier), "a corrected reminder must be pinned")
        XCTAssertEqual(state.corrections.count, 1)
        XCTAssertEqual(state.corrections.first?.to, "Projects")
    }

    /// Pinning is permanent. A second pass must not re-report or re-learn the
    /// same correction, or the corpus fills with duplicates of one mistake.
    func testPinnedClaimsAreNotReconsidered() {
        var state = OrganizerState()
        let r = reminder("Update the quarterly report", list: "Projects")
        state.claims[r.calendarItemIdentifier] = .init(
            routedTo: "Work", dueSetTo: nil,
            titleHash: OrganizerState.hash("Update the quarterly report"),
            at: "now", confidence: 0.85, runnerUp: nil)
        _ = state.reconcile(against: [r])
        let second = state.reconcile(against: [r])
        XCTAssertTrue(second.isEmpty, "a pinned claim must not be revisited")
        XCTAssertEqual(state.corrections.count, 1, "the same correction must not be learned twice")
    }

    func testRewrittenTitleDropsOurClaimRatherThanPinning() {
        var state = OrganizerState()
        let r = reminder("Completely different now", list: "Work")
        state.claims[r.calendarItemIdentifier] = .init(
            routedTo: "Work", dueSetTo: nil,
            titleHash: OrganizerState.hash("The original title"),
            at: "now", confidence: 0.9, runnerUp: nil)
        let found = state.reconcile(against: [r])
        XCTAssertEqual(found.first?.kind, "rewritten")
        XCTAssertNil(state.claims[r.calendarItemIdentifier],
                     "a rewritten reminder is a new item, not a correction")
    }

    func testVanishedReminderDropsTheClaim() {
        var state = OrganizerState()
        state.claims["gone-id"] = .init(routedTo: "Work", dueSetTo: nil,
                                        titleHash: "abc", at: "now",
                                        confidence: 0.9, runnerUp: nil)
        let found = state.reconcile(against: [])
        XCTAssertEqual(found.first?.kind, "vanished")
        XCTAssertTrue(state.claims.isEmpty)
    }

    /// Reminders we never touched are none of our business.
    func testUnclaimedRemindersAreIgnored() {
        var state = OrganizerState()
        let untouched = reminder("Something the user filed themselves", list: "Shopping")
        XCTAssertTrue(state.reconcile(against: [untouched]).isEmpty)
        XCTAssertTrue(state.corrections.isEmpty)
    }
}

final class RouterTests: XCTestCase {

    private let store = EKEventStore()
    private func reminder(_ title: String, list: String) -> EKReminder {
        let r = EKReminder(eventStore: store); r.title = title
        let c = EKCalendar(for: .reminder, eventStore: store); c.title = list
        r.calendar = c; return r
    }

    /// The bug a live run caught: drawing examples from every list taught the
    /// router that the capture list was a valid destination, and it proposed
    /// filing a reminder back into the inbox it came from.
    func testExamplesExcludeTheCaptureList() {
        let rs = [reminder("a", list: "Inbox"), reminder("b", list: "Work"),
                  reminder("c", list: "Archive")]
        let ex = Router.baseExamples(from: rs, excluding: ["Inbox", "Archive"])
        XCTAssertEqual(ex.map(\.1), ["Work"])
    }

    func testExamplesAreBalancedPerList() {
        // 35 groceries must not drown out a 1-item list.
        var rs = (1...30).map { reminder("g\($0)", list: "Shopping") }
        rs.append(reminder("only", list: "Personal"))
        let ex = Router.baseExamples(from: rs, perList: 3)
        XCTAssertEqual(ex.filter { $0.1 == "Shopping" }.count, 3)
        XCTAssertEqual(ex.filter { $0.1 == "Personal" }.count, 1)
    }

    /// Below the threshold every correction is injected; the retrieval switch
    /// exists so prompt size stops growing once there are many.
    func testAllCorrectionsInjectedWhileCorpusIsSmall() {
        var state = OrganizerState()
        state.corrections = (1...5).map {
            .init(title: "t\($0)", from: "Work", to: "Projects", at: "now", embedding: nil)
        }
        XCTAssertEqual(Router.correctionExamples(state, for: "anything").count, 5)
    }

    func testLargeCorpusIsBounded() {
        var state = OrganizerState()
        state.corrections = (1...200).map {
            .init(title: "t\($0)", from: "Work", to: "Projects", at: "now", embedding: nil)
        }
        let picked = Router.correctionExamples(state, for: "anything", limit: 8)
        XCTAssertEqual(picked.count, 8, "prompt size must not grow with the corpus")
    }
}
