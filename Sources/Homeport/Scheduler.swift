import EventKit
import Foundation

/// Places tasks into the day, using the calendar as a statement of intent.
///
/// **Free/busy is the wrong signal here, and using it would produce the exact
/// opposite of what is wanted.** On a calendar where every timed event is marked
/// `busy` -- the work blocks included -- a gap-finder refuses to put work tasks
/// inside the work day, the one place they belong, and happily drops them into
/// time the user meant to protect.
///
/// What the calendar actually encodes is *category, by calendar name*:
///
/// - `workFlagCalendar` -- a marker that the work day is happening. Its duration
///   is meaningless; its **presence** is the signal. No event that day means the
///   day was taken off, so the work window simply does not exist.
/// - `protectedCalendars` -- never schedulable.
/// - `protectedTitles` -- a title that says so is a do-not-schedule instruction
///   the user already writes by hand, whatever calendar it is on.
///
/// **Times are local.** EventKit hands back UTC; every window below is local
/// wall-clock. Skipping that conversion puts the work day in the middle of the
/// night for anyone not on UTC.
///
/// The policy is **configuration, not code**, for the same reason categories
/// are (see `Categories`): which calendars someone protects, and when their day
/// starts and ends, is a description of their life. A stock build ships the
/// neutral defaults below; the operator's real policy lives in
/// `~/Library/Application Support/homeport/schedule.json` and is never tracked.
/// `deploy/schedule.example.json` shows every key.
enum Scheduler {

    /// Local wall-clock windows. Work hours are config rather than calendar
    /// geometry because the events are markers, not spans.
    struct Policy {
        var workStart = (hour: 9, minute: 0)
        var workEnd   = (hour: 17, minute: 0)
        /// Personal time before and after the work day. Protected events
        /// subtract from these, so what remains is real.
        var morningStart = (hour: 7, minute: 0)
        var morningEnd   = (hour: 9, minute: 0)
        var eveningStart = (hour: 19, minute: 0)
        var eveningEnd   = (hour: 22, minute: 0)

        var workFlagCalendar = "Work"
        var protectedCalendars: Set<String> = []
        /// Lower-cased substrings that mark an event as protected regardless of
        /// which calendar it is on.
        var protectedTitles: [String] = []
        /// All-day events on these calendars take the whole day off.
        ///
        /// "Presence of a Work event means you are working" is defeated by an
        /// unbounded weekly recurrence, which fires on a public holiday exactly
        /// like any other weekday. The holiday has to win -- so point this at
        /// whichever holiday calendar you subscribe to.
        var dayOffCalendars: Set<String> = []

        var workLists: Set<String> = ["Work"]
        var personalLists: Set<String> = ["Personal"]
        /// Never scheduled at all. Shopping lists are not tasks with a time.
        var excludedLists: Set<String> = ["Shopping"]

        var slotMinutes = 30

        static var configURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/homeport/schedule.json")
        }

        /// The operator's policy, or the stock one when no file exists. A
        /// malformed key falls back to its default rather than failing the
        /// tool: a typo in one window should not stop scheduling outright.
        static func load(from url: URL = configURL) -> Policy {
            var p = Policy()
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
                return p
            }
            func hm(_ key: String) -> (hour: Int, minute: Int)? {
                guard let raw = o.string(key) else { return nil }
                let parts = raw.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1])
                else { return nil }
                return (parts[0], parts[1])
            }
            func names(_ key: String) -> Set<String>? { (o[key] as? [String]).map(Set.init) }

            if let v = hm("workStart") { p.workStart = v }
            if let v = hm("workEnd") { p.workEnd = v }
            if let v = hm("morningStart") { p.morningStart = v }
            if let v = hm("morningEnd") { p.morningEnd = v }
            if let v = hm("eveningStart") { p.eveningStart = v }
            if let v = hm("eveningEnd") { p.eveningEnd = v }
            if let v = o.string("workFlagCalendar") { p.workFlagCalendar = v }
            if let v = names("protectedCalendars") { p.protectedCalendars = v }
            if let v = o["protectedTitles"] as? [String] { p.protectedTitles = v.map { $0.lowercased() } }
            if let v = names("dayOffCalendars") { p.dayOffCalendars = v }
            if let v = names("workLists") { p.workLists = v }
            if let v = names("personalLists") { p.personalLists = v }
            if let v = names("excludedLists") { p.excludedLists = v }
            if let v = o.int("slotMinutes") { p.slotMinutes = max(5, v) }
            return p
        }
    }

    struct Interval { var start: Date; var end: Date
        var minutes: Int { Int(end.timeIntervalSince(start) / 60) } }

    struct Slot { let reminderId: String; let title: String; let list: String; let start: Date }

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    private static func at(_ day: Date, _ hm: (hour: Int, minute: Int)) -> Date {
        cal.date(bySettingHour: hm.hour, minute: hm.minute, second: 0, of: day) ?? day
    }

    /// Subtract every blocking event from a window, returning what is left.
    static func subtract(_ window: Interval, blocking: [Interval]) -> [Interval] {
        var free = [window]
        for block in blocking.sorted(by: { $0.start < $1.start }) {
            var next: [Interval] = []
            for slice in free {
                if block.end <= slice.start || block.start >= slice.end { next.append(slice); continue }
                if block.start > slice.start { next.append(Interval(start: slice.start, end: block.start)) }
                if block.end < slice.end { next.append(Interval(start: block.end, end: slice.end)) }
            }
            free = next
        }
        return free.filter { $0.minutes > 0 }
    }

    /// The schedulable windows for one local day, already minus protected time.
    static func windows(for day: Date, events: [EKEvent], policy: Policy)
        -> (work: [Interval], personal: [Interval], isWorkDay: Bool) {

        let dayEvents = events.filter { cal.isDate($0.startDate, inSameDayAs: day) }

        // Presence of a Work event is the "am I working today" flag. Absence
        // means the day was taken off and the work window does not exist.
        let isWorkDay = dayEvents.contains { $0.calendar?.title == policy.workFlagCalendar }

        // An all-day event is usually context (a birthday), but two kinds are
        // not: a holiday, and something the user flagged in the title -- an
        // all-day event with a protected title is the clearest possible
        // statement that the day is spoken for. Those take the day, rather than being skipped for having
        // no useful start and end time.
        let dayIsOff = dayEvents.contains { e in
            guard e.isAllDay else { return false }
            let name = e.calendar?.title ?? ""
            let title = (e.title ?? "").lowercased()
            return policy.dayOffCalendars.contains(name)
                || policy.protectedTitles.contains(where: { title.contains($0) })
        }

        let blocking: [Interval] = dayEvents.compactMap { e in
            let name = e.calendar?.title ?? ""
            let title = (e.title ?? "").lowercased()
            // Remaining all-day events (birthdays) really are just context.
            if e.isAllDay { return nil }
            // The work marker is a flag, never a block.
            if name == policy.workFlagCalendar { return nil }
            let isProtected = policy.protectedCalendars.contains(name)
                || policy.protectedTitles.contains(where: { title.contains($0) })
            guard isProtected else { return nil }
            return Interval(start: e.startDate, end: e.endDate)
        }

        guard !dayIsOff else { return ([], [], false) }

        let work = isWorkDay
            ? subtract(Interval(start: at(day, policy.workStart), end: at(day, policy.workEnd)),
                       blocking: blocking)
            : []
        let personal =
            subtract(Interval(start: at(day, policy.morningStart), end: at(day, policy.morningEnd)),
                     blocking: blocking)
            + subtract(Interval(start: at(day, policy.eveningStart), end: at(day, policy.eveningEnd)),
                       blocking: blocking)
        return (work, personal, isWorkDay)
    }

    /// Lay reminders into intervals, honestly. When they do not fit, they do not
    /// fit — packing twelve tasks into a four-hour block at twenty-minute
    /// intervals produces a plan nobody follows and teaches you to ignore it.
    static func fill(_ intervals: [Interval], with items: [(id: String, title: String, list: String)],
                     slotMinutes: Int, after now: Date) -> (placed: [Slot], unplaced: [(id: String, title: String, list: String)]) {
        var placed: [Slot] = []
        var queue = items
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            var cursor = max(interval.start, now)
            while !queue.isEmpty,
                  cursor.addingTimeInterval(TimeInterval(slotMinutes * 60)) <= interval.end {
                let item = queue.removeFirst()
                placed.append(Slot(reminderId: item.id, title: item.title,
                                   list: item.list, start: cursor))
                cursor = cursor.addingTimeInterval(TimeInterval(slotMinutes * 60))
            }
        }
        return (placed, queue)
    }
}
