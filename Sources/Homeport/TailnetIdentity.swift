import Foundation

/// Resolves who is calling, from Tailscale rather than from a shared secret.
///
/// `tailscale serve` **overwrites** the `Tailscale-User-*` and `X-Forwarded-For`
/// headers on every proxied request — a client that sends its own forged values
/// has them stripped and replaced (verified: a request carrying
/// `Tailscale-User-Login: attacker@evil.com` and `X-Forwarded-For: 100.99.99.99`
/// arrived with the real identity in both). Combined with the loopback-only bind,
/// which makes `serve` the only route in, that makes these headers trustworthy.
///
/// This is why there are no bearer tokens: identity here is backed by WireGuard
/// keys, which is stronger than a string that must be stored, distributed,
/// rotated and kept out of logs. There is no secret on disk to steal, so there
/// is nothing to keep in a password manager either.
///
/// **Why the caller is identified by address rather than by `tailscale whois`.**
/// The obvious design is to whois the forwarded address per request. It does not
/// work reliably: with Tailscale.app installed, both CLI entry points
/// (`Tailscale.app/Contents/MacOS/{Tailscale,tailscale}`) are GUI-coupled and
/// fail from a launchd agent with "The Tailscale GUI failed to start
/// (Tailscale.CLIError error 3)" — while exiting 0, so the failure is silent and
/// the parse error downstream is the only symptom. Tailnet addresses are stable
/// for the life of a node, so the mapping is resolved once at onboarding by
/// `add-device.sh` (which runs interactively, where the CLI does work) and
/// recorded in `policy.json`. The daemon then spawns no subprocess at all:
/// faster, and with no dependency on a GUI being alive.
///
/// **Known and accepted gap:** any process running locally on this Mac as the
/// same user could reach 127.0.0.1:8765 directly and forge these headers, since
/// only `serve` strips them. That grants nothing — such a process can already
/// read Calendar, Notes and chat.db straight off disk, far more easily. Browsers
/// are handled separately by the Origin check in `HTTPTransport`.
enum TailnetIdentity {

    struct Caller {
        let address: String     // 100.100.100.100, from X-Forwarded-For
        /// you@github for a user-owned device; nil for a TAGGED device.
        /// `tailscale serve` does not populate identity headers for tagged
        /// devices (they have no user), so enrollment by address is the whole
        /// check for them -- see `Auth.authorize`.
        let userLogin: String?

        /// How the caller appears in logs.
        var label: String { userLogin ?? "tagged device" }
    }

    /// Build a caller from the proxy headers, or nil when the request did not
    /// arrive through `tailscale serve`. `serve` sets X-Forwarded-For on every
    /// proxied request, tagged callers included, so its absence is the signal;
    /// `Tailscale-User-Login` is present only for user-owned devices.
    static func resolve(userLogin: String?, forwardedFor: String?) -> Caller? {
        // X-Forwarded-For may be a list; the first entry is the origin client.
        let address = (forwardedFor ?? "")
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !address.isEmpty else { return nil }

        let login = userLogin.flatMap { $0.isEmpty ? nil : $0 }
        return Caller(address: address, userLogin: login)
    }
}
