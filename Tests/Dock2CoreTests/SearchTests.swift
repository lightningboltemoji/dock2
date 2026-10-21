import Dock2Core
import Foundation
import Testing

@Suite struct MatcherTests {
    @Test func namesSplitIntoWordsAsTheProductSays() {
        #expect(Matcher.words(of: "GitHub Desktop").map(\.folded) == ["git", "hub", "desktop"])
        #expect(Matcher.words(of: "VSCode").map(\.folded) == ["vs", "code"])
        #expect(Matcher.words(of: "1Password 7").map(\.folded) == ["1", "password", "7"])
        #expect(Matcher.words(of: "safe_browsing.txt").map(\.folded) == ["safe", "browsing", "txt"])
        #expect(Matcher.words(of: "iPhone Mirroring").map(\.folded) == ["i", "phone", "mirroring"])
    }

    @Test func kindsRankAsTheProductSays() {
        let name = "Visual Studio Code"
        #expect(Matcher.match(Query("Visual Studio Code"), name)?.kind == .exact)
        #expect(Matcher.match(Query("visualstudiocode"), name)?.kind == .exact)
        #expect(Matcher.match(Query("visual st"), name)?.kind == .prefix)
        #expect(Matcher.match(Query("stu code"), name)?.kind == .words)
        #expect(Matcher.match(Query("code vis"), name)?.kind == .words)
        #expect(Matcher.match(Query("vsc"), name)?.kind == .initials)
        #expect(Matcher.match(Query("vsdcd"), name) == nil)
        #expect(Matcher.match(Query("vsdcd"), name, subsequence: true)?.kind == .subsequence)
        #expect(MatchKind.exact < .prefix && .prefix < .words && .words < .initials && .initials < .subsequence)
    }

    @Test func screenSharingByItsInitialsAndCaseAndAccentsIgnored() {
        #expect(Matcher.match(Query("ss"), "Screen Sharing")?.kind == .initials)
        #expect(Matcher.match(Query("CAFE"), "Café Menu")?.kind == .prefix)
        #expect(Matcher.match(Query("hub"), "GitHub")?.kind == .words)
    }

    @Test func aWordMustBeginAWordAndEachWordMatchesOnce() {
        #expect(Matcher.match(Query("ari"), "Safari") == nil)
        #expect(Matcher.match(Query("code code"), "Visual Studio Code") == nil)
    }

    @Test func rangesCoverWhatMatched() {
        #expect(Matcher.match(Query("saf"), "Safari")?.ranges == [0..<3])
        #expect(Matcher.match(Query("stu code"), "Visual Studio Code")?.ranges == [7..<10, 14..<18])
        #expect(Matcher.match(Query("vsc"), "Visual Studio Code")?.ranges == [0..<1, 7..<8, 14..<15])
    }

    @Test func pathsAreNotSearches() {
        #expect(Query("~/Dev").isPath && Query("/tmp").isPath && !Query("dev").isPath)
        #expect(Query("   ").isEmpty)
    }
}

private func result(_ id: String, _ section: SectionID, _ kind: MatchKind, signal: Double = 0, title: String? = nil) -> SearchResult {
    SearchResult(id: id, section: section, title: title ?? id, match: Match(kind: kind, ranges: []), signal: signal,
                 payload: .command(id))
}

@Suite struct SearchSessionTests {
    @Test func theTopHitIsTheBestInTheFirstFrameAndLeavesItsSection() {
        var session = SearchSession(query: Query("saf"))
        session.add([result("Safari", .apps, .prefix), result("Safety", .files, .prefix), result("Lockdown Safe", .apps, .words)])
        session.freeze()
        #expect(session.topHit?.id == "Safari")
        #expect(session.rows.map(\.id) == ["Safari", "Lockdown Safe", "title:apps", "Safety", "title:files"])
    }

    /// Apps come before files at equal match; within a section, the source's signal, then the name.
    @Test func orderIsKindThenSectionThenSignalThenName() {
        var session = SearchSession(query: Query("re"))
        session.add([result("b", .apps, .words, signal: 1), result("a", .apps, .words, signal: 1), result("c", .apps, .words, signal: 5),
                     result("f", .files, .prefix)])
        session.freeze()
        #expect(session.topHit?.id == "f")
        #expect(session.rows.map(\.id) == ["f", "c", "a", "b", "title:apps"])
    }

    @Test func lateResultsGoToTheFarEndOfTheirSectionAndNothingMoves() {
        var session = SearchSession(query: Query("re"))
        session.add([result("b", .files, .words)])
        session.freeze()
        let before = session.rows.map(\.id)
        session.add([result("a", .files, .exact), result("z", .apps, .words)])
        let after = session.rows.map(\.id)
        #expect(before == ["b"])
        #expect(after == ["b", "z", "title:apps", "a", "title:files"])
    }

    @Test func aSectionShowsItsShareThenShowAll() {
        var session = SearchSession(query: Query("x"))
        session.add((0..<5).map { result("app\($0)", .apps, .words, signal: Double(10 - $0)) })
        session.freeze()
        #expect(session.rows.map(\.id) == ["app0", "app1", "app2", "app3", "all:apps", "title:apps"])
        #expect(session.all(in: .apps).count == 5)
        #expect(SectionID.files.share == 5)
    }

    @Test func aLateFirstResultCanStillBeTheTopHit() {
        var session = SearchSession(query: Query("x"))
        session.freeze()
        session.add([result("late", .files, .words)])
        #expect(session.topHit?.id == "late")
    }

    @Test func aLearnedPickOutranksEverything() {
        var session = SearchSession(query: Query("sa"), picks: ["Lockdown Safe"])
        session.add([result("Safari", .apps, .exact), result("Lockdown Safe", .apps, .words)])
        session.freeze()
        #expect(session.topHit?.id == "Lockdown Safe")
    }

    @Test func pluginSectionsComeLastInTheirOrder() {
        #expect(SectionID.apps < .commands && .commands < .clipboard && .clipboard < .files)
        #expect(SectionID.files < .plugin("z", order: 0, title: "Z") && SectionID.plugin("z", order: 0, title: "Z") < .plugin("a", order: 1, title: "A"))
    }

    /// The system's own use decides only between results whose signals are equal.
    @Test func theTiebreakDecidesOnlyBetweenEquals() {
        var session = SearchSession(query: Query("x"))
        func app(_ id: String, signal: Double, tiebreak: Double) -> SearchResult {
            SearchResult(id: id, section: .apps, title: id, match: Match(kind: .prefix, ranges: []), signal: signal, tiebreak: tiebreak,
                         payload: .command(id))
        }
        session.add([app("xa", signal: 1, tiebreak: 0), app("xb", signal: 0, tiebreak: 9e15), app("xc", signal: 0, tiebreak: 5)])
        session.freeze()
        #expect(session.all(in: .apps).map(\.id) == ["xa", "xb", "xc"])
    }

    /// The Files section's note goes with its results, and alone when nothing at all was found.
    @Test func aNoteExplainsAnEmptySearch() {
        var session = SearchSession(query: Query("plan"))
        session.notes = [.files: "Not searched: Desktop"]
        session.freeze()
        #expect(session.isEmpty && session.rows.map(\.id) == ["note:files", "title:files"])
        var found = SearchSession(query: Query("plan"))
        found.notes = [.files: "Not searched: Desktop"]
        found.add([result("a", .apps, .prefix), result("b", .apps, .prefix)])
        found.freeze()
        #expect(!found.rows.contains { $0.id == "note:files" })
    }
}


@Suite struct LearnedPicksTests {
    @Test func aPickAppliesToItsQueryAndLongerOnesLongestFirst() {
        var picks = LearnedPicks()
        let t0 = Date(timeIntervalSince1970: 0)
        picks.record("app:safari", for: Query("sa"), at: t0)
        picks.record("app:sage", for: Query("sag"), at: t0)
        #expect(picks.candidates(for: Query("sa")) == ["app:safari"])
        #expect(picks.candidates(for: Query("sage")) == ["app:sage", "app:safari"])
        #expect(picks.candidates(for: Query("s")) == [])
    }

    @Test func choosingAgainReplacesThatQuerysPick() {
        var picks = LearnedPicks()
        picks.record("a", for: Query("Sa"))
        picks.record("b", for: Query("sa"))
        #expect(picks.candidates(for: Query("sa")) == ["b"])
        #expect(picks.picks.count == 1)
    }
}

@Suite struct FileRankingTests {
    private let home = "/Users/me"
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func signal(_ path: String, days: Double? = nil) -> Double {
        FileRanking.signal(path: path, lastUsed: nil, modified: days.map { now.addingTimeInterval(-$0 * 86_400) },
                           home: home, near: [home + "/Desktop", home + "/Documents", home + "/Downloads"], now: now)
    }

    @Test func nearPlacesThenHomeThenTheRestThenSystem() {
        #expect(signal("/Users/me/Documents/a.txt") > signal("/Users/me/Developer/a.txt"))
        #expect(signal("/Users/me/Developer/a.txt") > signal("/Volumes/X/a.txt"))
        #expect(signal("/Volumes/X/a.txt") > signal("/Users/me/Library/a.txt"))
        #expect(signal("/Volumes/X/a.txt") > signal("/System/a.txt"))
    }

    @Test func noiseAndHiddenFoldersSinkBelowEverything() {
        #expect(signal("/System/Library/x.txt") > signal("/Users/me/Documents/app/node_modules/x/index.js", days: 0))
        #expect(signal("/System/Library/x.txt") > signal("/Users/me/.config/x.txt", days: 0))
        // A hidden file itself is not noise; a hidden folder above it is.
        #expect(signal("/Users/me/Documents/.env") > signal("/Users/me/Developer/x.txt"))
    }

    @Test func recentBeatsOldAndShallowBeatsDeep() {
        #expect(signal("/Users/me/Developer/a.txt", days: 1) > signal("/Users/me/Developer/a.txt", days: 200))
        #expect(signal("/Users/me/Developer/a.txt") > signal("/Users/me/Developer/x/y/z/a.txt"))
    }

    @Test func theQueryStringMatchesWordsAndLeavesAppsOut() {
        #expect(FileRanking.queryString(Query("re port")) ==
                "kMDItemDisplayName == \"re*\"cdw && kMDItemDisplayName == \"port*\"cdw && kMDItemContentTypeTree != \"com.apple.application\"")
        #expect(FileRanking.queryString(Query("a\"b*")).hasPrefix("kMDItemDisplayName == \"a\\\"b\\**\"cdw"))
        #expect(FileRanking.queryString(Query("re"), usedWithin: 90).hasSuffix("&& kMDItemLastUsedDate >= $time.today(-90)"))
        #expect(FileRanking.abbreviate("/Users/me/Documents", home: home) == "~/Documents")
    }
}

@Suite struct BuildTreesTests {
    @Test func aBuildOutputTreeIsNoise() {
        let home = "/Users/me", now = Date()
        let built = FileRanking.signal(path: "/Users/me/src/chromium/out/Release/obj/x.ninja", lastUsed: nil, modified: now, home: home, near: [], now: now)
        let source = FileRanking.signal(path: "/Users/me/src/chromium/components/x.cc", lastUsed: nil, modified: nil, home: home, near: [], now: now)
        #expect(source > built)
    }
}

@Suite struct LearnedPicksSettingsTests {
    @Test func aPickKeepsItsTitleAndCanBeForgotten() {
        var picks = LearnedPicks()
        picks.record("app:safari", title: "Safari", for: Query("saf"))
        picks.record("file:/a", for: Query("a"))
        #expect(picks.picks.map(\.title) == ["Safari", nil])
        picks.forget("saf")
        #expect(picks.candidates(for: Query("safari")).isEmpty && picks.picks.count == 1)
    }
}
