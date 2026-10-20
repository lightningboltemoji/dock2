// swift-tools-version: 6.2
import PackageDescription

// dock2 — a replacement for the macOS Dock (see .agents/IMPLEMENTATION.md).
//
// Module graph (dependencies point strictly upward):
//
//   Dock2Core    pure — the Dock's measured geometry, the items, the suppression journal. (Foundation, CG geometry)
//       ▲
//   Dock2Shell   imperative — the window, the glass, the tiles, the label, the system Dock's preferences,
//       ▲        the guard process.
//   dock2        executable — the app, `--restore`, and the guard (`--guard <pid>`), all one binary.
let package = Package(
    name: "dock2",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "dock2", targets: ["dock2"]),
    ],
    targets: [
        .target(name: "Dock2Core", path: "Sources/Dock2Core"),
        .target(name: "Dock2Shell", dependencies: ["Dock2Core"], path: "Sources/Dock2Shell"),
        .executableTarget(name: "dock2", dependencies: ["Dock2Core", "Dock2Shell"], path: "Sources/dock2"),
        .testTarget(name: "Dock2CoreTests", dependencies: ["Dock2Core"], path: "Tests/Dock2CoreTests"),
    ]
)
