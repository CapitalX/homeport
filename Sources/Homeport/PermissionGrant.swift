import AppKit
import Contacts
import EventKit
import Foundation

/// One-shot permission bootstrap, run as `Homeport --grant`.
///
/// Why this exists: the MCP server disclaims TCC responsibility (see
/// `Disclaim.swift`) so grants attach to this binary's identity rather than to
/// whichever client launched it. The cost is that a disclaimed process with no
/// GUI session is one macOS will never prompt for — `requestFullAccessToEvents`
/// returns `notDetermined` instantly without so much as contacting `tccd`.
/// Running it from Terminal does not help; the responsible process is this
/// binary, and this binary has no window server connection.
///
/// The way out is to be a real app exactly once. `open` the bundle and
/// LaunchServices launches it as a foreground-capable app that CAN present the
/// prompts. Because TCC keys the bundle on `CFBundleIdentifier`, the grants that
/// result are matched by every later disclaimed subprocess of the same bundle —
/// including the ones Claude Desktop and Claude Code spawn over stdio.
///
/// Deliberately does NOT disclaim: launched via `open`, the app is already its
/// own responsible process, and re-execing would only obscure that.
enum PermissionGrant {

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/homeport-grant.log")

    static func run() -> Never {
        // Become a real, frontmost application for the duration of this mode.
        //
        // Info.plist sets LSUIElement so the server never litters the Dock, but
        // that makes the process an *accessory* app which can never activate --
        // and TCC will not draw a prompt for an app that cannot come to the
        // front. Overriding the activation policy here (and only here) is what
        // actually gets the dialogs on screen.
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let lock = NSLock()
        var lines = ["=== homeport permission grant — \(Date()) ==="]
        func note(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(s)
        }

        let group = DispatchGroup()

        group.enter()
        EventKitStore.shared.store.requestFullAccessToEvents { granted, error in
            note("Calendar : granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            group.leave()
        }

        group.enter()
        EventKitStore.shared.store.requestFullAccessToReminders { granted, error in
            note("Reminders: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            group.leave()
        }

        group.enter()
        ContactsStore.shared.store.requestAccess(for: .contacts) { granted, error in
            note("Contacts : granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            group.leave()
        }

        // Messages automation is a separate per-target grant that the Notes one
        // does not cover, and it cannot be prompted for from the background
        // daemon -- so raise it here, where we are a real foreground app.
        note("--- Messages automation ---")
        let msgScript = """
        with timeout of 20 seconds
            tell application "Messages" to get name
        end timeout
        """
        if let script = NSAppleScript(source: msgScript) {
            var err: NSDictionary?
            _ = script.executeAndReturnError(&err)
            if let err {
                note("Messages : NOT authorized (\(err[NSAppleScript.errorNumber] ?? "?")) \(err[NSAppleScript.errorMessage] ?? "")")
            } else {
                note("Messages : authorized ✅")
            }
        }

        // Spin the main run loop rather than blocking on a semaphore. The
        // prompts are presented on the main thread, so blocking it is precisely
        // how you get a dialog that never appears.
        var finished = false
        group.notify(queue: .main) { finished = true }
        let deadline = Date().addingTimeInterval(180)
        while !finished && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !finished { note("TIMED OUT after 180s — a prompt was probably left unanswered.") }

        // Authoritative re-read: the callbacks are advisory (see the macOS 14.2
        // false-negative note in EventKitStore), the status is the truth.
        note("--- final status ---")
        note("Calendar : \(describe(EKEventStore.authorizationStatus(for: .event)))")
        note("Reminders: \(describe(EKEventStore.authorizationStatus(for: .reminder)))")
        note("Contacts : \(describeContacts(CNContactStore.authorizationStatus(for: .contacts)))")

        lock.lock()
        let text = lines.joined(separator: "\n") + "\n"
        lock.unlock()

        // Launched via `open`, so stdout goes nowhere a person can see it.
        if let data = text.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
        FileHandle.standardOutput.write(text.data(using: .utf8) ?? Data())
        exit(0)
    }

    private static func describe(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .fullAccess:    return "fullAccess ✅"
        case .writeOnly:     return "writeOnly (need full access to read)"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }

    private static func describeContacts(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted:    return "restricted"
        case .denied:        return "denied"
        case .authorized:    return "authorized ✅"
        @unknown default:    return "unknown(\(s.rawValue))"
        }
    }
}
