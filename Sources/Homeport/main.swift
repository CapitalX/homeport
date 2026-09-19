import Foundation

// STEP 0: One-shot permission bootstrap, launched as a real app via `open`.
// Must come before the disclaim re-exec: a disclaimed process has no GUI
// session, and macOS will not raise a TCC prompt for one. See PermissionGrant.
if CommandLine.arguments.contains("--grant") {
    PermissionGrant.run() // never returns
}

// STEP 1: Disclaim TCC responsibility BEFORE touching EventKit/Contacts, so the
// permission grant attaches to this binary rather than the launching app.
Disclaim.reexecIfNeeded()

// STEP 2: Serve MCP until the transport ends.
//
// Transport is chosen by env var, not a flag: Disclaim's POSIX_SPAWN_SETEXEC
// re-exec propagates the environment explicitly, so a var is guaranteed to
// survive it. Note the listener is created AFTER the re-exec above -- binding a
// socket before it would leave it in the discarded first image.
Log.info("starting homeport (pid \(getpid()))")
let server = MCPServer()

if let raw = ProcessInfo.processInfo.environment["HOMEPORT_HTTP_PORT"],
   let port = UInt16(raw) {
    guard let http = HTTPTransport(port: port, server: server) else {
        Log.warn("could not bind 127.0.0.1:\(port); is another instance running?")
        exit(1)
    }
    // Live routing, opt-in. Registered before run() parks on dispatchMain(),
    // which is what delivers the notifications.
    var observer: ReminderObserver?
    if ReminderObserver.isEnabled {
        observer = ReminderObserver()
        observer?.start()
    }
    _ = observer
    http.run() // never returns
} else {
    StdioTransport.run(server: server)
}
