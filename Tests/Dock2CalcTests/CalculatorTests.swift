@testable import Dock2Calc
import Foundation
import Testing

@Suite struct CalculatorTests {
    private func answer(_ question: String, commaDecimals: Bool = false) -> Calculation? {
        Calculator.calculate(question, budget: 0.05, commaDecimals: commaDecimals)
    }

    @Test func arithmeticAndConversionsAreAnswered() {
        #expect(answer("33+24") == Calculation(answer: "57", isApproximate: false))
        #expect(answer("1 lb to oz")?.answer == "16 oz")
        #expect(answer("20% of 50")?.answer == "10")
        #expect(answer("60 mph to km/h")?.answer == "96.56064 km / h")
        #expect(answer("2^64")?.answer == "18446744073709551616")
    }

    @Test func aRoundedAnswerSaysSo() {
        #expect(answer("1/3") == Calculation(answer: "0.3333333333", isApproximate: true))
        #expect(answer("100 F in C")?.isApproximate == true)
    }

    /// Prefixes of app names fend would answer — "a" an ampere, "G" a billion — and quantities that ask nothing.
    @Test func namesAndBareQuantitiesAreNotQuestions() {
        for typed in ["a", "e", "G", "pi", "TV", "ares", "Safari", "4k", "3pm", "2fa", "5gb", "12 inch", "1.000", "2048", "  24h "] {
            #expect(answer(typed) == nil, "\(typed)")
        }
    }

    @Test func aQuestionFendCannotAnswerHasNoAnswer() {
        #expect(answer("iphone 15") == nil)
        #expect(answer("10:30") == nil)
        #expect(answer("5 +") == nil)
    }

    @Test func commaDecimalsFollowTheChoice() {
        #expect(answer("1,5 + 2", commaDecimals: true)?.answer == "3,5")
        #expect(answer("1,5 + 2")?.answer == "17")
    }

    /// fend computes exactly: left alone, 9^9^9 runs for longer than anyone waits.
    @Test func theBudgetEndsARunawayQuestion() {
        let start = Date()
        #expect(answer("9^9^9") == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    /// Deeper than a dispatch queue's stack holds, and past the longest question asked.
    @Test func deepNestingNeitherCrashesNorIsAsked() {
        let deep = String(repeating: "(", count: 120) + "1" + String(repeating: ")", count: 120)
        #expect(answer(deep + "+1")?.answer == "2")
        #expect(answer(String(repeating: "(", count: 300) + "1+1") == nil)
    }
}
