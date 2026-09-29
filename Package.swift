// swift-tools-version:5.9
import PackageDescription
import Foundation

// ---------------------------------------------------------------------------
// On-device transcription is an OPTIONAL capability, decided HERE, at build time.
//
// LocalTranscriber drives SpeechAnalyzer/SpeechTranscriber, which arrived in the
// macOS 26 SDK. `#available(macOS 26.0, *)` does not help: on an older SDK those
// symbols do not exist at all, so the file fails to TYPE-CHECK and takes the
// whole binary down with it -- every calendar, reminder, contact and Notes tool
// in it -- on a Mac whose owner may never open Voice Memos. A capability nobody
// asked for must not be able to break the build, so the SDK is probed here and
// the engine is compiled in only when it can be. Without it the binary builds,
// installs and serves as usual; the two transcription paths return a clear
// error saying why, and embedded iPhone transcripts are unaffected.
//
// Force it either way with HOMEPORT_SPEECH_ANALYZER=1 / =0 -- useful to confirm
// the degraded path still builds on a machine that has the newer SDK.
// ---------------------------------------------------------------------------

/// Major version of the macOS SDK `swift build` will actually use, or nil if it
/// cannot be determined -- in which case we assume the feature is unavailable,
/// because guessing wrong in that direction costs a capability while guessing
/// wrong in the other costs the entire build.
func macOSSDKMajor() -> Int? {
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    probe.arguments = ["--sdk", "macosx", "--show-sdk-version"]
    let out = Pipe()
    probe.standardOutput = out
    probe.standardError = FileHandle.nullDevice
    do { try probe.run() } catch { return nil }
    // Read before waiting: the output is a few bytes, so the pipe cannot fill,
    // and reading first avoids the classic wait-then-read deadlock.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    guard probe.terminationStatus == 0 else { return nil }
    let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(version.split(separator: ".").first ?? "")
}

let speechAnalyzerAvailable: Bool = {
    if let override = ProcessInfo.processInfo.environment["HOMEPORT_SPEECH_ANALYZER"] {
        return ["1", "true", "yes"].contains(override.lowercased())
    }
    return (macOSSDKMajor() ?? 0) >= 26
}()

var homeportSwiftSettings: [SwiftSetting] = []
var homeportLinkerSettings: [LinkerSetting] = [
    .linkedFramework("EventKit"),
    .linkedFramework("Contacts"),
    // Notes has no EventKit equivalent; it is driven over Apple
    // Events via NSAppleScript (Foundation), which needs no extra
    // framework. AVFoundation + libsqlite3 back the Voice Memos
    // reader.
    .linkedFramework("AVFoundation"),
    .linkedLibrary("sqlite3")
]
if speechAnalyzerAvailable {
    homeportSwiftSettings.append(.define("SPEECH_ANALYZER"))
    homeportLinkerSettings.append(.linkedFramework("Speech"))
}

let package = Package(
    name: "Homeport",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Tiny C target that declares the private libSystem SPI used to make this
        // process its own TCC-responsible process (the "disclaim shim").
        .target(
            name: "CDisclaim"
        ),
        // The single self-contained binary: MCP stdio server + EventKit/Contacts engine.
        .executableTarget(
            name: "Homeport",
            dependencies: ["CDisclaim"],
            exclude: ["Resources/Info.plist", "Resources/Homeport.entitlements"],
            swiftSettings: homeportSwiftSettings,
            linkerSettings: homeportLinkerSettings
        ),
        // Tests link against the executable target directly rather than forcing
        // a library split. The security-relevant pieces (the untrusted-content
        // table, handle normalization) are pure functions, so they need no
        // EventKit access and no TCC grant to exercise.
        .testTarget(
            name: "HomeportTests",
            dependencies: ["Homeport"],
            path: "Tests/HomeportTests"
        )
    ]
)
