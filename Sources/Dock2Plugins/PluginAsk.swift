import AppKit
import Dock2Core

/// What installing a plugin, or switching on a first-party one, asks ([asking](product/plugins/permissions.md#asking)):
/// a row for each capability with dock2's lines, the plugin's reason and a switch. An update asks only about
/// what it reaches beyond what was agreed to, and shows the rest as it was.
public struct PluginAsk: Identifiable, Sendable {
    public enum Purpose: Equatable, Sendable {
        case install(URL)
        case switchOn
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let capability: PluginCapability
        /// What dock2 enforces, a line for each thing it names.
        public let lines: [String]
        /// What the plugin claims.
        public let reason: String
        /// A prompt of macOS's it may bring, which names Dock2.
        public let note: String?
        /// It can do anything the user can: worth more than a glance.
        public let isFullTrust: Bool
        public var on: Bool

        public var id: PluginCapability { capability }
    }

    public let manifest: PluginManifest
    public let origin: PluginOrigin
    public let purpose: Purpose
    /// What is new — everything, the first time — each with its switch.
    public var rows: [Row]
    /// What an update reaches as before, as it stands.
    public let unchanged: [Row]

    public var id: String { manifest.id }
    public var isUpdate: Bool { !unchanged.isEmpty }

    /// `agreed` is the reach last agreed to, nil the first time; `choices` what stands for the rest.
    public init(manifest: PluginManifest, origin: PluginOrigin, purpose: Purpose, agreed: PluginManifest.Reach?, choices: PluginChoices?,
                settings: [String: String]) {
        self.manifest = manifest
        self.origin = origin
        self.purpose = purpose
        let new = Set(manifest.reach.beyond(agreed))
        let off = PluginChoices.startsRevoked(manifest)
        func row(_ capability: PluginCapability, on: Bool) -> Row {
            let capabilities = manifest.capabilities
            return Row(capability: capability, lines: manifest.describe(capability, settings: settings), reason: capabilities.reason(capability) ?? "",
                       note: Self.note(capability, manifest), isFullTrust: capability == .run && capabilities.runsWithFullTrust, on: on)
        }
        let declared = manifest.capabilities.declared
        rows = declared.filter(new.contains).map { row($0, on: !off.contains($0)) }
        unchanged = declared.filter { !new.contains($0) }.map { row($0, on: choices?.grants($0, in: manifest) ?? !off.contains($0)) }
    }

    /// What it asks, said: whether there is anything to say yes to.
    public var asksAnything: Bool { !rows.isEmpty }

    /// Each new row's switch, to write as granted or revoked before the plugin first runs.
    public var decisions: [PluginCapability: Bool] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.capability, $0.on) })
    }

    /// macOS asks for Dock2, not the plugin: the sheet says it may.
    static func note(_ capability: PluginCapability, _ manifest: PluginManifest) -> String? {
        switch capability {
        case .files:
            return "macOS asks to let Dock2 into a folder in Desktop, Documents, Downloads or iCloud Drive before it reads one."
        case .localNetwork:
            let hosts = (manifest.capabilities.localNetwork?.hosts ?? []).map { HostPort($0) }
            let beyondThisMac = hosts.contains { host in
                guard let host else { return true }
                return host.host != "localhost" && HostPort.isLoopback(host.host) != true
            }
            return beyondThisMac ? "macOS asks to let Dock2 find devices on your local network before it reaches one." : nil
        default:
            return nil
        }
    }

    /// As `dock2 plugin` prints it: every row, a full-trust one said as such, and what starts off.
    public func text(name: String) -> String {
        var out: [String] = []
        func print(_ row: Row, switchable: Bool) {
            for (index, line) in row.lines.enumerated() { out.append((index == 0 ? "  • " : "    ") + line) }
            if !row.reason.isEmpty { out.append("    \(name) says: “\(row.reason)”") }
            if let note = row.note { out.append("    \(note)") }
            if switchable && !row.on { out.append("    Off until you switch it on in Settings → Plugins.") }
            if !switchable && !row.on { out.append("    Off, as you left it.") }
        }
        for row in rows { print(row, switchable: true) }
        if !unchanged.isEmpty {
            out.append("  As before:")
            for row in unchanged { print(row, switchable: false) }
        }
        return out.joined(separator: "\n")
    }
}

extension HostPort {
    /// The loopback addresses: this Mac alone, which macOS's local network prompt does not ask about.
    static func isLoopback(_ host: String) -> Bool? {
        if host.hasPrefix("127.") || host == "::1" { return true }
        return HostPort.isLocalAddress(host).map { _ in false }
    }
}

extension PluginManifest {
    /// dock2's lines for `capability`, an app named as LaunchServices names it.
    public func describe(_ capability: PluginCapability, settings: [String: String]) -> [String] {
        lines(capability, settings: settings, appName: Self.appName)
    }

    /// "Zed", not "dev.zed.Zed", for an app this Mac has.
    static func appName(_ bundle: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    /// Its settings' defaults: what it would run with, before anyone chose.
    public var defaultSettings: [String: String] {
        Dictionary((settings ?? []).compactMap { setting in setting.defaultValue.map { (setting.id, $0) } }) { first, _ in first }
    }
}
