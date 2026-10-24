import Dock2Core
import Testing

private func app(_ id: String) -> AppRef { AppRef(bundleIdentifier: id, path: "/Applications/\(id).app") }
private let safari = app("com.apple.Safari"), mail = app("com.apple.mail"), zoom = app("us.zoom.xos")

@Suite struct DockModelTests {
    /// A drag's gap counts the pinned apps on show: one not installed is passed over, and stays pinned.
    @Test func pinningAtAGapPassesOverWhatIsNotShown() {
        let missing = app("com.example.missing")
        let pinned = [missing, safari, mail, safari]
        let drawable: (AppRef) -> Bool = { $0 != missing }
        #expect(DockModel.shown(pinned, drawable: drawable) == [safari, mail])
        // Before the first app on show: past the hidden one, which keeps its place.
        #expect(DockModel.pinning([zoom], atGap: 0, in: pinned, drawable: drawable) == [missing, zoom, safari, mail, safari])
        // Mail dragged to the front of what is shown.
        #expect(DockModel.pinning([mail], atGap: 0, in: pinned, drawable: drawable) == [missing, mail, safari, safari])
        // Past everything on show, or no gap: the end.
        #expect(DockModel.pinning([zoom], atGap: 2, in: pinned, drawable: drawable).last == zoom)
        #expect(DockModel.pinning([zoom, .finder], atGap: nil, in: [], drawable: drawable) == [zoom])
    }

    @Test func finderComesFirstAndOnlyOnce() {
        let slots = DockModel.compose(pinned: [.finder, safari], running: [.finder])
        #expect(slots == [.tile(.finder), .tile(.app(safari))])
    }

    /// As the system Dock shows them: straight after the pinned apps, with no separator.
    @Test func runningAppsThatAreNotPinnedFollowThePinnedInLaunchOrder() {
        let slots = DockModel.compose(pinned: [safari], running: [zoom, safari, mail])
        #expect(slots == [.tile(.finder), .tile(.app(safari)), .tile(.app(zoom)), .tile(.app(mail))])
    }

    @Test func hidingRunningAppsLeavesThePinned() {
        let slots = DockModel.compose(pinned: [safari], running: [zoom], showRunning: false)
        #expect(slots == [.tile(.finder), .tile(.app(safari))])
    }

    @Test func pluginTilesComeLastBehindTheirOwnSeparator() {
        let slots = DockModel.compose(pinned: [safari], running: [zoom], pluginTiles: ["now-playing/main"])
        #expect(slots.suffix(2) == [.separator(.plugins), .tile(.plugin("now-playing/main"))])
    }

    /// As the system Dock ends with them: after everything else, in the order they were minimised.
    @Test func minimisedWindowsComeLastBehindTheirOwnSeparator() {
        let slots = DockModel.compose(pinned: [safari], running: [], pluginTiles: ["now-playing/main"], windows: [7, 3])
        #expect(slots.suffix(3) == [.separator(.windows), .tile(.window(7)), .tile(.window(3))])
        #expect(DockModel.compose(pinned: [safari], running: [], windows: []) == [.tile(.finder), .tile(.app(safari))])
    }

    @Test func pinnedDuplicatesCollapse() {
        let slots = DockModel.compose(pinned: [safari, AppRef(bundleIdentifier: "com.apple.safari", path: "/elsewhere"), mail], running: [])
        #expect(slots == [.tile(.finder), .tile(.app(safari)), .tile(.app(mail))])
    }

    @Test func numbersSkipSeparatorsAndStopAtNine() {
        let pinned = (0..<3).map { app("app.\($0)") }
        let slots = DockModel.compose(pinned: pinned, running: [], pluginTiles: (0..<9).map { "plugin/\($0)" })
        let numbered = DockModel.numbered(slots.map(\.tile))
        #expect(numbered.count == 9)
        #expect(numbered.prefix(5) == [0, 1, 2, 3, 5])
    }
}

@Suite struct AutoHideTests {
    @Test func touchingTheEdgeRevealsAfterTheDelay() {
        var hide = AutoHide(enabled: true, revealDelay: 0.2)
        #expect(!hide.isShown)
        #expect(hide.pointer(.edge) == [.start(.reveal, after: 0.2)])
        #expect(hide.pointer(.band) == [])
        #expect(hide.fired(.reveal) == [.show])
        #expect(hide.isShown)
    }

    @Test func leavingBeforeTheDelayCancelsTheReveal() {
        var hide = AutoHide(enabled: true)
        _ = hide.pointer(.edge)
        #expect(hide.pointer(.away) == [.cancel(.reveal)])
        #expect(hide.fired(.reveal) == [])
        #expect(!hide.isShown)
    }

    @Test func risingAboveThePlatterHidesAfterTheDelayUnlessItComesBack() {
        var hide = AutoHide(enabled: true, hideDelay: 0.04)
        _ = hide.pointer(.edge); _ = hide.fired(.reveal)
        #expect(hide.pointer(.away) == [.start(.hide, after: 0.04)])
        #expect(hide.pointer(.band) == [.cancel(.hide)])
        _ = hide.pointer(.away)
        #expect(hide.fired(.hide) == [.hide])
        #expect(!hide.isShown)
    }

    @Test func aHoldKeepsTheDockAndShowsItIfHidden() {
        var hide = AutoHide(enabled: true)
        #expect(hide.hold(.engaged, true) == [.show])
        #expect(hide.pointer(.edge) == [])
        #expect(hide.pointer(.away) == [])
        #expect(hide.fired(.hide) == [])
        #expect(hide.hold(.menu, true) == [])
        #expect(hide.hold(.engaged, false) == [])
        #expect(hide.hold(.menu, false) == [.start(.hide, after: hide.hideDelay)])
    }

    @Test func aTimerThatWasCancelledDoesNothingWhenItFires() {
        var hide = AutoHide(enabled: true)
        _ = hide.pointer(.edge)
        _ = hide.pointer(.away)
        _ = hide.pointer(.band)
        #expect(hide.fired(.reveal) == [])
        #expect(!hide.isShown)
    }

    @Test func withoutAutoHideTheDockStays() {
        var hide = AutoHide(enabled: false)
        #expect(hide.isShown)
        #expect(hide.pointer(.edge) == [])
        #expect(hide.pointer(.away) == [])
        #expect(hide.fired(.hide) == [])
        #expect(hide.setEnabled(true) == [.start(.hide, after: hide.hideDelay)])
        #expect(hide.fired(.hide) == [.hide])
        _ = hide.pointer(.edge)
        #expect(hide.setEnabled(false) == [.cancel(.reveal), .show])
        #expect(hide.isShown)
    }
}
