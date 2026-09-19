import EventKit
import Foundation

/// Routes captured reminders within seconds of them landing, instead of nightly.
///
/// EventKit posts `.EKEventStoreChanged` whenever the store changes — including
/// a reminder synced in from a phone. The daemon already parks on
/// `dispatchMain()`, which services main-queue observers, so this needs no
/// polling and no extra process.
///
/// Opt-in via `HOMEPORT_AUTO_ROUTE=1`. Off by default: a background
/// process that silently moves a user's reminders is not something to enable
/// because it happens to be possible.
///
/// **Three separate hazards, three separate mechanisms.** They are not
/// interchangeable and none of them subsumes another:
///
/// 1. **Self-trigger.** Our own writes fire the notification too. For routing
///    this terminates naturally — a routed reminder leaves the capture list and
///    is no longer a candidate, so the echo pass finds nothing. That is not true
///    for anything that writes in place (the scheduler sets `due` and the
///    reminder stays put), so recently-written ids are also remembered for a
///    short window and skipped. Id-based, not time-based: a purely
///    time-based mute either drops real changes or fails to cover a slow write.
///
/// 2. **Sync bursts.** One phone sync fires many notifications in a second.
///    A trailing debounce collapses a burst into one pass: every notification
///    resets the timer, and work happens only after things go quiet.
///
/// 3. **Queue starvation.** A routing pass makes model calls of ~1.3s each.
///    Running those on `BridgeQueue.eventKit` would stall every tailnet client
///    for the duration — five queued captures is six seconds of dead endpoint.
///    The model call touches no Apple framework, so it runs on
///    `BridgeQueue.background` and hops to the EventKit queue only for the
///    fetch and the write, which are milliseconds.
final class ReminderObserver {

    private let captureList: String
    private let margin: Double
    private let debounceSeconds: TimeInterval
    /// How long a written id stays suppressed. Long enough to cover the
    /// notification the write itself provokes, short enough that a genuine user
    /// edit moments later is not swallowed.
    private let suppressionWindow: TimeInterval = 30

    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    private var recentWrites: [String: Date] = [:]
    private var running = false
    /// A notification that arrived while a pass was in flight. Dropping it
    /// loses the change entirely -- observed live: a move and a capture landed
    /// together, the move's pass was already reading candidates when the
    /// capture arrived, and the capture then sat unrouted forever because no
    /// further notification was coming. A change seen during a pass has to be
    /// re-run after it, not discarded.
    private var rerunRequested = false
    private var pollTimer: DispatchSourceTimer?

    init(captureList: String = "Inbox",
         margin: Double = Router.defaultMargin,
         debounceSeconds: TimeInterval = 4) {
        self.captureList = captureList
        self.margin = margin
        self.debounceSeconds = debounceSeconds
    }

    static var isEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["HOMEPORT_AUTO_ROUTE"] ?? ""
        return raw == "1" || raw.lowercased() == "true"
    }

    func start() {
        // `object: nil`, deliberately.
        //
        // Filtering on the store instance looked correct and silently matched
        // nothing: every pass that appeared to work was actually the startup
        // catch-up, and a reminder captured while the daemon was already running
        // sat in the inbox indefinitely. Accepting the notification from any
        // sender costs nothing -- the pass is idempotent and cheap when there is
        // nothing to do.
        // `queue: nil`, not `.main`.
        //
        // `.main` delivers via OperationQueue.main, which is driven by the main
        // RUN LOOP -- and this daemon ends in `dispatchMain()`, which parks the
        // main thread on libdispatch and never runs a run loop. Blocks queued
        // there are enqueued and never executed, which is why the notification
        // appeared to fire zero times. `nil` invokes the block directly on
        // whichever thread posts it; we hop to our own queue immediately.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Log.info("auto-route: store changed")
            self?.schedulePass()
        }

        // Safety net. A feature whose only trigger is a notification is a
        // feature that silently stops working the day the notification does not
        // arrive -- which is exactly what just happened. The poll is cheap
        // (one EventKit fetch, no model call unless something is waiting) and
        // bounds the worst case regardless of what EventKit decides to post.
        let poll = DispatchSource.makeTimerSource(queue: BridgeQueue.background)
        poll.schedule(deadline: .now() + 15, repeating: 20)
        poll.setEventHandler { [weak self] in self?.runPass() }
        poll.resume()
        pollTimer = poll
        Log.info("auto-route: watching \(captureList) "
            + "(debounce \(Int(debounceSeconds))s, \(Router.votes) votes must agree)")
        // Catch up once at startup. EKEventStoreChanged only fires on CHANGES,
        // so anything captured while the daemon was down -- or before the
        // observer was ever enabled -- would sit in the inbox forever waiting
        // for an event that already happened.
        BridgeQueue.background.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.runPass()
        }
    }

    /// Trailing debounce. Each notification cancels the pending pass and starts
    /// the clock again, so a burst of twenty produces exactly one run.
    private func schedulePass() {
        lock.lock(); defer { lock.unlock() }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runPass() }
        pending = work
        BridgeQueue.background.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }

    private func runPass() {
        lock.lock()
        if running {
            // Never overlap passes -- but never lose the trigger either.
            rerunRequested = true
            lock.unlock()
            return
        }
        running = true
        rerunRequested = false
        prune()
        let suppressed = Set(recentWrites.keys)
        lock.unlock()
        defer {
            lock.lock()
            running = false
            let again = rerunRequested
            rerunRequested = false
            lock.unlock()
            if again { schedulePass() }
        }

        // Read on the EventKit queue, quickly.
        var candidates: [(id: String, title: String)] = []
        var lists: [String] = []
        var examples: [(String, String)] = []
        var state = OrganizerState()

        BridgeQueue.eventKit.sync {
            let ek = EventKitStore.shared
            guard (try? ek.ensureAccess(.reminder)) != nil else { return }
            guard let source = ek.reminderList(id: nil, name: captureList) else { return }
            let all = ek.fetchReminders(ek.store.predicateForReminders(in: nil))
            state = OrganizerState.load()
            let divergences = state.reconcile(against: all)
            // The marker's job ends when the question is answered. Clear it only
            // where we set it -- a priority the user chose is theirs to keep.
            for d in divergences where d.kind == "resolved-hold" {
                guard state.claims[d.id]?.markedLowPriority == true,
                      let r = try? ek.reminder(byId: d.id), r.priority == 9 else { continue }
                r.priority = 0
                try? ek.store.save(r, commit: true)
                state.claims[d.id]?.markedLowPriority = false
                Log.info("auto-route: cleared the unsure marker on \"\((r.title ?? "").prefix(40))\"")
            }
            try? state.save()

            lists = ek.reminderCalendars().map { $0.title }
                .filter { $0 != captureList }.sorted()
            examples = Router.baseExamples(from: all,
                                           excluding: [captureList])
            candidates = all
                .filter { !$0.isCompleted }
                .filter { $0.calendar?.calendarIdentifier == source.calendarIdentifier }
                .filter { !state.isPinned($0.calendarItemIdentifier) }
                .filter { !suppressed.contains($0.calendarItemIdentifier) }
                .compactMap { r -> (id: String, title: String)? in
                    guard let t = r.title, !t.isEmpty else { return nil }
                    // Already held, and unchanged since. Re-asking costs a model
                    // call and yields the same answer.
                    guard !state.alreadyHeld(r.calendarItemIdentifier, title: t) else { return nil }
                    return (r.calendarItemIdentifier, t)
                }
        }

        guard !candidates.isEmpty, !lists.isEmpty else { return }
        Log.info("auto-route: \(candidates.count) new item(s) in \(captureList)")

        for candidate in candidates {
            // Model call: slow, framework-free, off the EventKit queue.
            guard let vote = try? Router.classifyByVote(
                title: candidate.title, lists: lists,
                examples: examples + Router.correctionExamples(state, for: candidate.title))
            else {
                Log.warn("auto-route: could not classify \"\(candidate.title.prefix(40))\"")
                continue
            }
            guard vote.unanimous else {
                let spread = vote.tally.sorted { $0.value > $1.value }
                    .map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
                Log.info("auto-route: held \"\(candidate.title.prefix(40))\" (\(spread))")
                // Remember the question we could not answer. When the user
                // files it themselves, that becomes the answer.
                BridgeQueue.eventKit.sync {
                    let ek = EventKitStore.shared
                    // Mark it so the pile is visible in Reminders.app without
                    // opening anything. Only when no priority is set: clobbering
                    // one the user chose would be worse than no marker at all.
                    var marked = false
                    if let r = try? ek.reminder(byId: candidate.id), r.priority == 0 {
                        r.priority = 9    // low -> a "!" in the list
                        if (try? ek.store.save(r, commit: true)) != nil { marked = true }
                    }
                    var fresh = OrganizerState.load()
                    fresh.claims[candidate.id] = OrganizerState.Claim(
                        routedTo: nil, proposedList: vote.winner,
                        capturedIn: self.captureList, markedLowPriority: marked,
                        dueSetTo: nil,
                        titleHash: OrganizerState.hash(candidate.title),
                        at: OrganizerState.iso(Date()),
                        confidence: Double(vote.agreed) / Double(vote.total),
                        runnerUp: vote.tally.filter { $0.key != vote.winner }
                            .max(by: { $0.value < $1.value })?.key)
                    try? fresh.save()
                }
                continue
            }
            // Write: fast, framework-bound, back on the EventKit queue.
            BridgeQueue.eventKit.sync {
                let ek = EventKitStore.shared
                guard let reminder = try? ek.reminder(byId: candidate.id),
                      let target = ek.reminderList(id: nil, name: vote.winner) else { return }
                reminder.calendar = target
                do {
                    try ek.store.save(reminder, commit: true)
                    var fresh = OrganizerState.load()
                    fresh.claims[candidate.id] = OrganizerState.Claim(
                        routedTo: vote.winner, proposedList: nil, capturedIn: nil,
                        markedLowPriority: false, dueSetTo: nil,
                        titleHash: OrganizerState.hash(candidate.title),
                        at: OrganizerState.iso(Date()),
                        confidence: Double(vote.agreed) / Double(vote.total), runnerUp: nil)
                    try? fresh.save()
                    self.remember(candidate.id)
                    AuditLog.record(tool: "reminders_route", caller: nil, transport: "observer",
                                    outcome: "ok", ms: 0,
                                    detail: ["auto": true, "to": vote.winner,
                                             "votes": "\(vote.agreed)/\(vote.total)"])
                    Log.info("auto-route: \(candidate.title.prefix(40)) → \(vote.winner) "
                        + "(\(vote.agreed)/\(vote.total))")
                } catch {
                    Log.warn("auto-route: save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func remember(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        recentWrites[id] = Date()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-suppressionWindow)
        recentWrites = recentWrites.filter { $0.value > cutoff }
    }
}
