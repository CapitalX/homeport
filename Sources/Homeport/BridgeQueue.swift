import Foundation

/// The one serial queue every EventKit/Contacts/AppleScript touch runs on.
///
/// `MCPServer` documents a single-request-at-a-time invariant and `HTTPTransport`
/// upholds it by funnelling every dispatch through one queue. The background
/// observer has to honour the same rule, so the queue stops being a private
/// detail of the transport and becomes a named, shared thing.
///
/// **What this queue does NOT protect.** It guards access to Apple's frameworks,
/// not "any work the bridge does". A local-model call takes seconds and touches
/// no framework; running it here would stall every tailnet client for its
/// duration. Slow, framework-free work belongs on `background`, hopping back
/// here only for the actual read or write.
enum BridgeQueue {
    /// Serialises all EventKit / Contacts / Apple Events access.
    static let eventKit = DispatchQueue(label: "dev.homeport.bridge.dispatch")

    /// Model calls and other slow work that touches no Apple framework.
    ///
    /// **Concurrent, and it has to be.** As a serial queue this merely relocated
    /// the problem it was created to solve: the Notes warm-up (up to 45s on a
    /// timeout) ran here, and the routing observer's passes queued behind it,
    /// so a captured reminder still waited ~100s to be filed. Work on this queue
    /// is independent by construction -- it touches no Apple framework and hops
    /// to `eventKit` for anything that does -- so there is nothing to serialise.
    static let background = DispatchQueue(
        label: "dev.homeport.bridge.background",
        qos: .utility, attributes: .concurrent)
}
