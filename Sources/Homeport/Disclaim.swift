import CDisclaim
import Darwin
import Foundation

enum Disclaim {
    /// Sentinel env var that prevents an infinite re-exec loop.
    private static let sentinel = "HOMEPORT_DISCLAIMED"

    /// Re-exec this process disclaiming TCC responsibility, so macOS attributes
    /// Calendar/Reminders/Contacts permission to THIS binary's code-signing
    /// identity rather than to whichever app launched it (Claude Desktop,
    /// Terminal, Cursor, ...). This is what makes the permission grant durable
    /// and portable across every MCP host, and it is what lets the prompt fire
    /// at all when launched from a GUI app whose own Info.plist lacks the
    /// EventKit/Contacts usage strings (the Claude Desktop limitation).
    ///
    /// Must be called before any EventKit or Contacts API is touched.
    static func reexecIfNeeded() {
        // Already disclaimed on a previous exec — nothing to do.
        if ProcessInfo.processInfo.environment[sentinel] != nil { return }

        // Opt-out hatch for debugging.
        if ProcessInfo.processInfo.environment["HOMEPORT_NO_DISCLAIM"] != nil { return }

        guard let execPath = currentExecutablePath() else {
            Log.warn("disclaim: could not resolve executable path; continuing without disclaim")
            return
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // Make the re-exec'd image its own responsible process.
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
        // POSIX_SPAWN_SETEXEC turns posix_spawn into an exec: on success the
        // current image is replaced and this call never returns.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))

        // argv (NULL-terminated).
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)

        // envp with the sentinel added (NULL-terminated).
        var env = ProcessInfo.processInfo.environment
        env[sentinel] = "1"
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        var pid: pid_t = 0
        let rc = execPath.withCString { pathPtr in
            posix_spawn(&pid, pathPtr, nil, &attr, argv, envp)
        }

        // With SETEXEC a return means it failed; carry on undisclaimed rather
        // than aborting (the tool still works when launched from a terminal
        // that already holds the grant).
        Log.warn("disclaim: re-exec failed (rc=\(rc)); continuing without disclaim")

        for p in argv where p != nil { free(p) }
        for p in envp where p != nil { free(p) }
    }

    private static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        // Resolve symlinks / relative components to a stable absolute path.
        let raw = String(cString: buffer)
        return (raw as NSString).resolvingSymlinksInPath
    }
}
