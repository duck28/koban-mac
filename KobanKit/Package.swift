// swift-tools-version: 5.10
//
// KobanKit — platform-independent core of Koban for macOS:
// data models, budget calculations and the encrypted SQLite vault.
//
// The Koban.app target (see ../project.yml) compiles these sources directly,
// so they need no `public` modifiers. This package exists to build and unit-test
// the core in isolation:  `cd KobanKit && swift test`

import PackageDescription

let package = Package(
    name: "KobanKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KobanCore", targets: ["KobanCore"]),
    ],
    targets: [
        .target(
            name: "KobanCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "KobanCoreTests",
            dependencies: ["KobanCore"]
        ),
    ]
)
