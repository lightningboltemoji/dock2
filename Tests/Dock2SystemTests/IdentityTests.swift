@testable import Dock2System
import Foundation
import Testing

@Suite struct IdentityTests {
    private func makeBundle(_ app: URL, id: String) throws -> URL {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "dock2", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("dock2")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        return executable
    }

    @Test func aLinkIntoDock2sBundleIsFollowedAndNothingElseIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeBundle(root.appendingPathComponent("Dock2.app"), id: Dock2Identity.bundleIdentifier)
        let other = try makeBundle(root.appendingPathComponent("Other.app"), id: "test.other")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("dock2"), otherLink = bin.appendingPathComponent("other")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        try FileManager.default.createSymbolicLink(at: otherLink, withDestinationURL: other)

        let real = try #require(Dock2Identity.bundledExecutable(linkedAt: link.path))
        #expect(real.hasSuffix("/Dock2.app/Contents/MacOS/dock2"))
        #expect(Dock2Identity.bundledExecutable(linkedAt: real) == nil)
        #expect(Dock2Identity.bundledExecutable(linkedAt: otherLink.path) == nil)
        #expect(Dock2Identity.bundledExecutable(linkedAt: bin.appendingPathComponent("missing").path) == nil)
    }
}
