import Dock2TOML
import Foundation

/// Why a value in the config file is not one its setting can hold: the predicate of a sentence whose subject
/// is the key, "must be at least 16".
public struct SettingProblem: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// How one kind of value crosses between the file and Swift: what a legal one is, how to read one, how to
/// write one. Every read refuses with a sentence rather than guessing.
public struct SettingCodec<Value: Sendable>: Sendable {
    /// What a legal value is, as the example document notes it; nil where the default says enough.
    public let legend: String?
    let read: @Sendable (TOMLValue) throws -> Value
    let write: @Sendable (Value) -> TOMLValue

    init(legend: String?, read: @escaping @Sendable (TOMLValue) throws -> Value, write: @escaping @Sendable (Value) -> TOMLValue) {
        self.legend = legend
        self.read = read
        self.write = write
    }
}

extension SettingCodec where Value == Bool {
    static var toggle: SettingCodec {
        SettingCodec(legend: nil, read: { value in
            guard let flag = value.asBool else { throw SettingProblem("must be true or false, not \(value.kindName)") }
            return flag
        }, write: { .bool($0) })
    }
}

extension SettingCodec where Value == Double {
    static func number(_ range: ClosedRange<Double>, unit: String) -> SettingCodec {
        let bounds = "from \(TOMLValue.number(range.lowerBound).spelled) to \(TOMLValue.number(range.upperBound).spelled)"
        return number(legend: "In \(unit), \(bounds).") { range.contains($0) ? nil : "must be \(bounds)" }
    }

    static func number(atLeast minimum: Double, unit: String?) -> SettingCodec {
        let floor = "at least \(TOMLValue.number(minimum).spelled)"
        return number(legend: (unit.map { "In \($0), \(floor)." } ?? "At least \(TOMLValue.number(minimum).spelled).")) { $0 >= minimum ? nil : "must be \(floor)" }
    }

    private static func number(legend: String, refusal: @escaping @Sendable (Double) -> String?) -> SettingCodec {
        SettingCodec(legend: legend, read: { value in
            guard let number = value.asDouble else { throw SettingProblem("must be a number, not \(value.kindName)") }
            guard number.isFinite else { throw SettingProblem("must be a finite number") }
            if let refused = refusal(number) { throw SettingProblem(refused) }
            return number
        }, write: { .number($0) })
    }
}

extension SettingCodec where Value == Int {
    static func integer(atLeast minimum: Int, unit: String) -> SettingCodec {
        SettingCodec(legend: "In \(unit), at least \(minimum).", read: { value in
            guard let number = value.asDouble else { throw SettingProblem("must be a number, not \(value.kindName)") }
            guard number == number.rounded(), let integer = Int(exactly: number) else { throw SettingProblem("must be a whole number") }
            guard integer >= minimum else { throw SettingProblem("must be at least \(minimum)") }
            return integer
        }, write: { .number(Double($0)) })
    }
}

extension SettingCodec where Value: RawRepresentable & CaseIterable, Value.RawValue == String {
    /// One of the cases, each by its raw value in kebab-case: `snowLeopard` is `"snow-leopard"`.
    static var word: SettingCodec {
        let words = Value.allCases.map { (SettingCodec.kebab($0.rawValue), $0) }
        let legal = words.map { "\"\($0.0)\"" }.joined(separator: ", ")
        return SettingCodec(legend: "One of \(legal).", read: { value in
            guard let text = value.asString else { throw SettingProblem("must be a word in quotes, not \(value.kindName)") }
            guard let match = words.first(where: { $0.0 == text }) else { throw SettingProblem("must be one of \(legal), not \"\(text)\"") }
            return match.1
        }, write: { .string(SettingCodec.kebab($0.rawValue)) })
    }
}

extension SettingCodec {
    static func kebab(_ camel: String) -> String {
        camel.reduce(into: "") { text, character in
            if character.isUppercase { text += "-" + character.lowercased() } else { text.append(character) }
        }
    }

    static func strings(_ legend: String?, _ value: TOMLValue) throws -> [String] {
        guard let elements = value.asArray else { throw SettingProblem("must be a list in brackets, not \(value.kindName)") }
        return try elements.map { element in
            guard let text = element.asString else { throw SettingProblem("must list strings, not \(element.kindName)") }
            return text
        }
    }
}

extension SettingCodec where Value == [String] {
    static var strings: SettingCodec {
        SettingCodec(legend: nil, read: { try SettingCodec.strings(nil, $0) }, write: { .array($0.map(TOMLValue.string)) })
    }

    /// Paths, written with `~/` under the home folder so a file shared between Macs names the same folders.
    static var paths: SettingCodec {
        SettingCodec(legend: "Paths; ~ is the home folder.", read: { try SettingCodec.strings(nil, $0).map(HomePath.expand) },
                     write: { .array($0.map { .string(HomePath.abbreviate($0)) }) })
    }
}

extension SettingCodec where Value == [AppRef] {
    /// Each app by its bundle identifier, or its path for an app without one.
    static var apps: SettingCodec {
        SettingCodec(legend: "Bundle identifiers, or the path of an app without one.", read: { value in
            try SettingCodec.strings(nil, value).map { entry in
                guard !entry.isEmpty else { throw SettingProblem("lists an empty app") }
                return entry.hasPrefix("/") || entry.hasPrefix("~")
                    ? AppRef(bundleIdentifier: nil, path: HomePath.expand(entry)) : AppRef(bundleIdentifier: entry, path: "")
            }
        }, write: { apps in .array(apps.map { .string($0.bundleIdentifier ?? HomePath.abbreviate($0.path)) }) })
    }
}

extension SettingCodec where Value == Shortcut {
    /// `"none"`, or a chord. For the summon shortcut, `"cmd-space"` is Spotlight's, taken over.
    static func shortcut(takesSpotlight: Bool) -> SettingCodec {
        let spotlight = KeyChord(keyCode: KeyChord.space, modifiers: KeyChord.command)
        let legend = takesSpotlight
            ? "\"cmd-space\" (taken from Spotlight), a chord like \"ctrl-alt-space\", or \"none\"."
            : "A chord like \"cmd-shift-v\", or \"none\"."
        return SettingCodec(legend: legend, read: { value in
            guard let text = value.asString else { throw SettingProblem("must be a chord in quotes, not \(value.kindName)") }
            if text == "none" { return .none }
            let chord = try KeyChord(spelling: text)
            return takesSpotlight && chord == spotlight ? .commandSpace : .chord(chord)
        }, write: { shortcut in
            switch shortcut {
            case .none: .string("none")
            case .commandSpace: .string(spotlight.spelled ?? "cmd-space")
            case .chord(let chord): .string(chord.spelled ?? "none")
            }
        })
    }
}

extension SettingCodec where Value == CairoPicture? {
    /// `"finder"` for Finder's own icon, else one of Cairo's pictures.
    static var picture: SettingCodec {
        let pictures = CairoPicture.allCases.map { (SettingCodec.kebab($0.rawValue), $0) }
        return SettingCodec(legend: "\"finder\", or one of Cairo's pictures: \(pictures.map { "\"\($0.0)\"" }.joined(separator: ", ")).",
                            read: { value in
            guard let text = value.asString else { throw SettingProblem("must be a word in quotes, not \(value.kindName)") }
            if text == "finder" { return nil }
            guard let match = pictures.first(where: { $0.0 == text }) else { throw SettingProblem("must be \"finder\" or one of Cairo's pictures, not \"\(text)\"") }
            return match.1
        }, write: { picture in .string(picture.map { SettingCodec.kebab($0.rawValue) } ?? "finder") })
    }
}

extension SettingCodec where Value == IconColor {
    /// `"#6A5CD8"`: red, green and blue in Display P3, two hexadecimal digits each.
    static var color: SettingCodec {
        SettingCodec(legend: "A colour in Display P3, as \"#RRGGBB\".", read: { value in
            guard let text = value.asString else { throw SettingProblem("must be a colour in quotes, not \(value.kindName)") }
            let digits = text.hasPrefix("#") ? String(text.dropFirst()) : ""
            guard digits.count == 6, let rgb = UInt32(digits, radix: 16) else { throw SettingProblem("must be a colour like \"#6A5CD8\", not \"\(text)\"") }
            func channel(_ shift: UInt32) -> Double { Double((rgb >> shift) & 0xFF) / 255 }
            return IconColor(red: channel(16), green: channel(8), blue: channel(0))
        }, write: { color in
            func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
            return .string(String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue)))
        })
    }
}

/// Paths as the config file writes them: `~/` for the home folder, so a file shared between Macs names
/// the same folders under another user name.
enum HomePath {
    static func expand(_ path: String) -> String {
        PathInput.expand(path, home: NSHomeDirectory())
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
