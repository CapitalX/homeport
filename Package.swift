// swift-tools-version:5.9
import PackageDescription

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
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("Contacts"),
                // Notes has no EventKit equivalent; it is driven over Apple
                // Events via NSAppleScript (Foundation), which needs no extra
                // framework. AVFoundation + libsqlite3 back the Voice Memos
                // reader.
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedLibrary("sqlite3")
            ]
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
