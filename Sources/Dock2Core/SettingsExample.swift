import Dock2TOML

extension Settings {
    /// Every setting the file can hold, at its default, with what it does: `config.example.toml`, pinned by a
    /// golden test so it cannot drift from the reader.
    public static var example: String {
        var tables: [(header: String, entries: [String])] = []
        for setting in all {
            for part in setting.parts {
                let header = "[" + TOMLDocument.spell(Array(part.path.dropLast())) + "]"
                if tables.last?.header != header { tables.append((header, [])) }
                let notes = ([part.help] + [part.legend].compactMap { $0 }).flatMap(comment)
                let line = TOMLTable.spell(key: part.path[part.path.count - 1]) + " = " + part.defaultValue.spelled(wrappingAt: TOMLDocument.wrapWidth)
                tables[tables.endIndex - 1].entries.append((notes + [line]).joined(separator: "\n"))
            }
        }
        let generated = tables.map { ([$0.header] + $0.entries).joined(separator: "\n\n") }
        return ([preamble] + generated + [plugins]).joined(separator: "\n\n") + "\n"
    }

    /// What a config file dock2 creates starts with: a sentence rather than an empty buffer, and no settings,
    /// since a file that writes a default down pins it.
    public static let starter = """
    # Dock2's settings. One not written here is at its default; changing one in Dock2 writes it here.
    # Every setting, and what it does: https://github.com/lightningboltemoji/dock2/blob/main/config.example.toml

    """

    private static let preamble = """
    # Every setting Dock2 has, at its default — so a file that says none of this says exactly this.
    # Write down only what you disagree with. Dock2 reads ~/.config/dock2/config.toml as it changes, and
    # changing a setting in Dock2 writes it there, keeping your comments and order.
    #
    # Generated from the schema (`Settings.example`) and pinned by a test. Don't edit it by hand.
    """

    private static let plugins = """
    # Each plugin's choices, in a table named by its id. Every key is optional; an installed plugin starts
    # with what its manifest says.
    #
    # [plugins."zip.tanner.dock2.bitwarden"]
    # enabled = true              # first-party plugins start off, ones you install on
    # revoked = ["query"]         # what it declares that it may not do
    # results = false             # its section in search
    # tiles.player = false        # each of its tiles on the dock, by id
    #
    # [plugins."zip.tanner.dock2.bitwarden".settings]
    # server = "https://vault.bitwarden.eu"   # as its manifest declares; secure ones stay in the Keychain
    """

    /// `text` as `#` comment lines, wrapped at 100 columns.
    private static func comment(_ text: String) -> [String] {
        var lines: [String] = []
        var line = "#"
        for word in text.split(separator: " ") {
            if line.count + word.count + 1 > 100 {
                lines.append(line)
                line = "#"
            }
            line += " " + word
        }
        return lines + [line]
    }
}
