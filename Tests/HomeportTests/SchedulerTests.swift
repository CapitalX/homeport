import XCTest
@testable import Homeport

/// Interval arithmetic is where a scheduler quietly goes wrong, and it is pure,
/// so it gets real coverage. No EventKit, no clock, no grant.
final class SchedulerTests: XCTestCase {

    private func t(_ h: Int, _ m: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 4; c.hour = h; c.minute = m
        return Calendar.current.date(from: c)!
    }
    private func iv(_ a: (Int, Int), _ b: (Int, Int)) -> Scheduler.Interval {
        .init(start: t(a.0, a.1), end: t(b.0, b.1))
    }

    func testBlockInTheMiddleSplitsTheWindow() {
        let free = Scheduler.subtract(iv((9,0),(17,0)), blocking: [iv((12,0),(13,0))])
        XCTAssertEqual(free.count, 2)
        XCTAssertEqual(free[0].minutes, 180)
        XCTAssertEqual(free[1].minutes, 240)
    }

    /// A protected block at the start of a window leaves only the remainder:
    /// 06:00–07:00 against a 06:00–07:30 window is thirty usable minutes, not ninety.
    func testProtectedBlockLeavesTheRemainderOfTheWindow() {
        let free = Scheduler.subtract(iv((6,0),(7,30)), blocking: [iv((6,0),(7,0))])
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(free[0].minutes, 30)
    }

    func testFullyCoveredWindowYieldsNothing() {
        XCTAssertTrue(Scheduler.subtract(iv((20,0),(22,0)),
                                         blocking: [iv((19,0),(22,30))]).isEmpty)
    }

    func testNonOverlappingBlockIsIgnored() {
        let free = Scheduler.subtract(iv((9,0),(17,0)), blocking: [iv((19,0),(20,0))])
        XCTAssertEqual(free.count, 1)
        XCTAssertEqual(free[0].minutes, 480)
    }

    func testOverlappingBlocksDoNotDoubleSubtract() {
        let free = Scheduler.subtract(iv((8,0),(12,0)),
                                      blocking: [iv((9,0),(10,0)), iv((9,30),(11,0))])
        XCTAssertEqual(free.map(\.minutes), [60, 60])
    }

    // MARK: - Filling

    private func items(_ n: Int) -> [(id: String, title: String, list: String)] {
        (1...n).map { (id: "id\($0)", title: "task \($0)", list: "Work") }
    }

    /// The honesty property. A four-hour window at 30-minute slots takes eight
    /// tasks and reports the other four rather than cramming them in.
    func testDoesNotOverfill() {
        let (placed, left) = Scheduler.fill([iv((8,0),(12,0))], with: items(12),
                                            slotMinutes: 30, after: t(0))
        XCTAssertEqual(placed.count, 8)
        XCTAssertEqual(left.count, 4)
    }

    func testSlotsAreSequentialAndInsideTheWindow() {
        let (placed, _) = Scheduler.fill([iv((8,0),(10,0))], with: items(4),
                                         slotMinutes: 30, after: t(0))
        XCTAssertEqual(placed.map { $0.start }, [t(8,0), t(8,30), t(9,0), t(9,30)])
    }

    /// Never schedules into the past — a "plan" containing this morning is noise.
    func testNothingIsPlacedBeforeNow() {
        let (placed, _) = Scheduler.fill([iv((8,0),(12,0))], with: items(2),
                                         slotMinutes: 30, after: t(10, 0))
        XCTAssertEqual(placed.first?.start, t(10, 0))
    }

    func testWindowTooShortForOneSlotPlacesNothing() {
        let (placed, left) = Scheduler.fill([iv((7,50),(8,0))], with: items(3),
                                            slotMinutes: 30, after: t(0))
        XCTAssertTrue(placed.isEmpty)
        XCTAssertEqual(left.count, 3)
    }

    // MARK: - Policy

    /// A stock build must know nothing about its operator: no protected
    /// calendars, no protected words, no holiday calendar assumed.
    func testStockPolicyIsNeutral() {
        let p = Scheduler.Policy()
        XCTAssertTrue(p.protectedCalendars.isEmpty)
        XCTAssertTrue(p.protectedTitles.isEmpty)
        XCTAssertTrue(p.dayOffCalendars.isEmpty)
        XCTAssertEqual(p.workLists, ["Work"])
    }

    func testMissingConfigYieldsStockPolicy() {
        let p = Scheduler.Policy.load(from: URL(fileURLWithPath: "/nonexistent/schedule.json"))
        XCTAssertEqual(p.workStart.hour, 9)
        XCTAssertTrue(p.protectedCalendars.isEmpty)
    }

    func testConfigOverridesOnlyWhatItNames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-\(UUID().uuidString).json")
        try Data("""
        {"workStart":"08:30","protectedCalendars":["Family"],"protectedTitles":["Focus"],
         "eveningEnd":"25:00","slotMinutes":2}
        """.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let p = Scheduler.Policy.load(from: url)
        XCTAssertEqual(p.workStart.hour, 8); XCTAssertEqual(p.workStart.minute, 30)
        XCTAssertEqual(p.protectedCalendars, ["Family"])
        XCTAssertEqual(p.protectedTitles, ["focus"], "titles match lower-cased")
        XCTAssertEqual(p.eveningEnd.hour, 22, "an invalid time keeps its default")
        XCTAssertEqual(p.slotMinutes, 5, "slot length is floored")
        XCTAssertEqual(p.workEnd.hour, 17, "unnamed keys keep their defaults")
    }

    /// The shipped example must parse, or it is documentation that lies.
    func testExampleConfigParses() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("deploy/schedule.example.json")
        let p = Scheduler.Policy.load(from: url)
        XCTAssertEqual(p.protectedCalendars, ["Family"])
        XCTAssertEqual(p.dayOffCalendars, ["Holidays"])
    }
}
