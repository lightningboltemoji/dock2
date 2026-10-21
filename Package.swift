// swift-tools-version: 6.2
import PackageDescription

// dock2 — a replacement for the macOS Dock (see .agents/IMPLEMENTATION.md).
//
// Module graph (dependencies point strictly upward):
//
//   Dock2Core     pure — geometry, the models, the journal, settings' schema. (Foundation, CG geometry)
//       ▲
//   Dock2System   the Mac without windows — takeovers and the guard, settings' store, apps, the system Dock.
//       ▲
//   Dock2Plugins  the plugin host — the engine (DockWasm, a Rust staticlib `make engine` builds), instances.
//       ▲
//   Dock2Shell    the windows — the stage, the glass, the dock; the controller that wires it all.
//       ▲
//   dock2         executable — the app, `--restore`, and the guard (`--guard <pid>`), all one binary.
let package = Package(
    name: "dock2",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "dock2", targets: ["dock2"]),
    ],
    targets: [
        .target(name: "Dock2Core", path: "Sources/Dock2Core"),
        .target(name: "Dock2System", dependencies: ["Dock2Core"], path: "Sources/Dock2System"),
        .binaryTarget(name: "DockWasm", path: "Frameworks/DockWasm.xcframework"),
        .target(name: "Dock2Plugins", dependencies: ["Dock2Core", "Dock2System", "DockWasm"], path: "Sources/Dock2Plugins",
                linkerSettings: [.linkedLibrary("iconv")]),
        .target(name: "Dock2Shell", dependencies: ["Dock2Core", "Dock2System", "Dock2Plugins"], path: "Sources/Dock2Shell"),
        .executableTarget(name: "dock2", dependencies: ["Dock2Core", "Dock2System", "Dock2Shell"], path: "Sources/dock2"),
        .testTarget(name: "Dock2CoreTests", dependencies: ["Dock2Core"], path: "Tests/Dock2CoreTests"),
        .testTarget(name: "Dock2SystemTests", dependencies: ["Dock2Core", "Dock2System"], path: "Tests/Dock2SystemTests"),
        .testTarget(name: "Dock2PluginsTests", dependencies: ["Dock2Core", "Dock2Plugins"], path: "Tests/Dock2PluginsTests"),
    ]
)
