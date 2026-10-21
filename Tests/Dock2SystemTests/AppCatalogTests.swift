import Dock2Core
@testable import Dock2System
import Foundation
import Testing

@Suite struct AppCatalogTests {
    private func makeApp(_ path: URL, id: String, name: String) throws {
        let contents = path.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func scanFindsAppsInVendorFoldersButNotHelpersInsideApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-apps-\(UUID().uuidString)")
        try makeApp(root.appendingPathComponent("Editor.app"), id: "test.editor", name: "Editor")
        try makeApp(root.appendingPathComponent("Editor.app/Contents/Helpers/Editor Helper.app"), id: "test.helper", name: "Helper")
        try makeApp(root.appendingPathComponent("Vendor/Suite/Tool.app"), id: "test.tool", name: "ToolBundleName")
        let apps = AppCatalog.scan([root])
        let ids = Set(apps.compactMap(\.ref.bundleIdentifier))
        #expect(ids.isSuperset(of: ["test.editor", "test.tool", "com.apple.finder"]))
        #expect(!ids.contains("test.helper"))
        #expect(apps.first { $0.ref.bundleIdentifier == "test.tool" }?.names == ["Tool", "ToolBundleName"])
    }
}

@MainActor
@Suite struct AppDirectoryTests {
    @Test func anAppTheCatalogFindsElsewhereIsLookedUpAgain() throws {
        let directory = AppDirectory()
        let calculator = AppRef(bundleIdentifier: "com.apple.calculator", path: "/System/Applications/Calculator.app")
        let found = try #require(directory.entry(calculator))
        let same = AppCatalog.App(ref: calculator, url: found.url, names: ["Calculator"], version: found.version)
        #expect(found.version != nil && !directory.forgetChanged([same]))
        let updated = AppCatalog.App(ref: calculator, url: found.url, names: ["Calculator"], version: "999")
        #expect(directory.forgetChanged([updated]))
        _ = directory.entry(calculator)
        let moved = AppCatalog.App(ref: calculator, url: URL(fileURLWithPath: "/Applications/Calculator.app"), names: ["Calculator"],
                                   version: found.version)
        #expect(directory.forgetChanged([moved]))
    }
}
