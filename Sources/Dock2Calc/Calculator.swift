import DockCalc
import Foundation

/// An answer to a question typed in search: "33+24" is 57, "1 lb to oz" is 16 oz.
public struct Calculation: Sendable, Equatable {
    /// As fend writes it, without its "approx.": "57", "16 oz", "0.3333333333".
    public var answer: String
    /// fend rounded it to show it.
    public var isApproximate: Bool

    public init(answer: String, isApproximate: Bool) {
        self.answer = answer
        self.isApproximate = isApproximate
    }
}

/// fend, asked only what reads as a question ([search](../../.agents/product/search/README.md#the-calculator)).
public enum Calculator {
    /// fend's answer, or nil: not a question, no answer, or none within `budget`. Blocks while fend works.
    public static func calculate(_ question: String, budget: TimeInterval, commaDecimals: Bool) -> Calculation? {
        guard asks(question), let answer = dc_answer(question, UInt32(budget * 1000), commaDecimals) else { return nil }
        defer { dc_string_free(answer) }
        let text = String(cString: answer)
        let approximate = "approx. "
        return text.hasPrefix(approximate)
            ? Calculation(answer: String(text.dropFirst(approximate.count)), isApproximate: true)
            : Calculation(answer: text, isApproximate: false)
    }

    /// A digit, and more than a number with a word on it: fend reads "a" as an ampere, "4k" as 4000 and "3pm"
    /// as picometres, none of them asked.
    public static func asks(_ question: String) -> Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: isDigit) else { return false }
        let rest = text.drop { isDigit($0) || $0 == "." || $0 == "," }.drop(while: \.isWhitespace)
        return !rest.allSatisfy(\.isLetter)
    }

    private static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }
}
