import Foundation

/// Replay protection for writes.
///
/// A timed-out write is genuinely ambiguous: the Apple Event may well have
/// landed before the client gave up. That is not hypothetical here — the first
/// Notes call after a daemon start takes ~50s cold while Notes.app launches, and
/// Messages can stall behind an Automation prompt. Without replay protection the
/// only safe client behavior is "never retry, query first and reconcile", which
/// pushes the bridge's problem onto every caller and is easy to get wrong.
///
/// With a client-supplied `idempotencyKey`, a retry of the same key returns the
/// ORIGINAL result instead of performing the write again, so retrying is safe.
///
/// Scope and honest limits:
/// - Applies to mutating tools only. Reads are naturally idempotent.
/// - In memory, so it does not survive a daemon restart. A key replayed after a
///   restart executes again. Persisting it would mean a store that must itself
///   be transactional with the Apple write, which cannot be guaranteed — a
///   durable record of "we did it" that is written after a crash-prone step is
///   its own lie. Bounded memory is the honest version.
/// - A result is only cached when the handler SUCCEEDED. Caching a failure would
///   make a legitimate retry-after-fix return the stale error forever.
enum Idempotency {

    /// Long enough to cover a client's retry/backoff window, short enough that a
    /// key reused days later for a genuinely new write is not silently swallowed.
    private static let ttl: TimeInterval = 6 * 3600
    private static let maxEntries = 500

    private struct Entry {
        let result: Any
        let at: Date
        let tool: String
    }

    private static var store: [String: Entry] = [:]
    private static let lock = NSLock()

    /// A cached result for this key, if the same tool produced one recently.
    ///
    /// Reusing one key across two different tools is a client bug; returning the
    /// other tool's result would compound it, so that is treated as a miss and
    /// logged.
    static func replay(key: String, tool: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            store.removeValue(forKey: key); return nil
        }
        guard entry.tool == tool else {
            Log.warn("idempotency: key reused across tools (\(entry.tool) then \(tool)); ignoring cache")
            return nil
        }
        return entry.result
    }

    static func record(key: String, tool: String, result: Any) {
        lock.lock(); defer { lock.unlock() }
        if store.count >= maxEntries {
            // Drop the oldest rather than refusing to record: a full cache must
            // not silently turn replay protection off for new writes.
            let cutoff = store.min { $0.value.at < $1.value.at }
            if let cutoff { store.removeValue(forKey: cutoff.key) }
        }
        store[key] = Entry(result: result, at: Date(), tool: tool)
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }
}
