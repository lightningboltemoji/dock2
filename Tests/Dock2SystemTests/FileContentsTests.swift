import AppKit
@testable import Dock2System
import Foundation
import Testing
import UniformTypeIdentifiers

/// Against files of their own in the temporary directory.
@Suite struct FileContentsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock2-contents-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// A 2×1 PNG, drawn here.
    func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func judgesTextByItsType() throws {
        #expect(FileContents.kind(of: try file("main.swift", Data("let a = 1".utf8))) == .text)
        #expect(FileContents.kind(of: try file("notes.md", Data("# Notes".utf8))) == .text)
        // Its type alone, unread: not on this Mac, reading it would download it.
        #expect(FileContents.kind(of: try file("cloud.json", Data([0, 1, 2])), local: false) == .text)
    }

    @Test func judgesAFileOfNoTextTypeByItsFirstBytes() throws {
        #expect(FileContents.kind(of: try file(".gitignore", Data(".build/\n".utf8))) == .text)
        #expect(FileContents.kind(of: try file(".env", Data("KEY=value\n".utf8))) == .text)
        // macOS takes `.ts` for video.
        #expect(FileContents.kind(of: try file("index.ts", Data("export const a = 1\n".utf8))) == .text)
        #expect(FileContents.kind(of: try file("blob.ts", Data([0x47, 0x40, 0x00, 0x10]))) == nil)
        #expect(FileContents.kind(of: try file("archive.zip", Data("PK\u{3}\u{4}\0\0".utf8))) == nil)
        #expect(FileContents.kind(of: try file("cloud.env", Data("KEY=value".utf8)), local: false) == nil)
    }

    @Test func offersImagesMacOSReadsAndNoRichText() throws {
        #expect(FileContents.kind(of: try file("dot.png", png())) == .image)
        #expect(FileContents.kind(of: try file("letter.rtf", Data("{\\rtf1 hi}".utf8))) == nil)
        // SVG is text macOS can't draw as an image: its source.
        #expect(FileContents.kind(of: try file("icon.svg", Data("<svg/>".utf8))) == .text)
    }

    @Test func sniffsPastACharacterCutOffAtTheEnd() {
        let text = Data(String(repeating: "a", count: FileContents.sniffLength - 1).utf8) + Data("é".utf8)
        let head = text.prefix(FileContents.sniffLength)
        #expect(FileContents.isText(head, whole: false))
        #expect(!FileContents.isText(head, whole: true))
    }

    @Test func readsTextInUTF8AndUTF16WithoutTheMark() throws {
        let plain = try file("plain.txt", Data("héllo\n".utf8))
        #expect(try FileContents.read(plain, as: .text) == .text("héllo\n"))
        let marked = try file("marked.txt", Data([0xEF, 0xBB, 0xBF]) + Data("héllo".utf8))
        #expect(try FileContents.read(marked, as: .text) == .text("héllo"))
        let wide = try file("wide.txt", "héllo".data(using: .utf16)!)
        #expect(try FileContents.read(wide, as: .text) == .text("héllo"))
    }

    @Test func refusesTextItCannotDecode() throws {
        let latin = try file("latin.txt", Data([0x68, 0xE9, 0x6C]))
        #expect(throws: CocoaError.self) { try FileContents.read(latin, as: .text) }
    }

    @Test func readsAnImageAsItsOwnBytesAndAPNG() throws {
        let png = png()
        let url = try file("dot.png", png)
        #expect(try FileContents.read(url, as: .image) == .image([.init(type: UTType.png.identifier, data: png)]))
        let tiff = NSImage(data: png)!.tiffRepresentation!
        guard case .image(let representations) = try FileContents.read(try file("dot.tiff", tiff), as: .image) else {
            Issue.record("not an image")
            return
        }
        #expect(representations.map(\.type) == [UTType.tiff.identifier, UTType.png.identifier])
        #expect(representations[0].data == tiff)
        #expect(NSImage(data: representations[1].data)?.size == NSSize(width: 2, height: 1))
    }

    @MainActor
    @Test func writesTextAndImagesForAnyAppToPaste() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        FileContents.write(.text("hello"), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "hello")
        pasteboard.clearContents()
        let png = png()
        FileContents.write(.image([.init(type: UTType.png.identifier, data: png)]), to: pasteboard)
        #expect(pasteboard.data(forType: .png) == png)
        #expect(NSImage(pasteboard: pasteboard) != nil)
    }

    /// Against the apps on this Mac: TextEdit opens text wherever macOS runs.
    @MainActor
    @Test func listsOpenWithsAppsDefaultFirstThenByNameEachOnce() throws {
        let text = try file("open.txt", Data("hi".utf8))
        let apps = OpenWith.apps(for: [text])
        #expect(apps.preferred == NSWorkspace.shared.urlForApplication(toOpen: text))
        let all = [apps.preferred].compactMap { $0 } + apps.others
        #expect(all.contains { Bundle(url: $0)?.bundleIdentifier == "com.apple.TextEdit" })
        let ids = all.map { Bundle(url: $0)?.bundleIdentifier ?? $0.path }
        #expect(Set(ids).count == ids.count)
        let names = apps.others.map(OpenWith.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(!names.contains { $0.hasSuffix(".app") })
        // Several: only the apps that open them all.
        let image = try file("open.png", png())
        let both = OpenWith.apps(for: [text, image])
        let opening = Set(NSWorkspace.shared.urlsForApplications(toOpen: image).map(\.standardizedFileURL))
        #expect(([both.preferred].compactMap { $0 } + both.others).allSatisfy { opening.contains($0.standardizedFileURL) })
    }
}
