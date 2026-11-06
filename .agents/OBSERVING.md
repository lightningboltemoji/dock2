# Observing dock2

How to see the live dock2 do something, record it, and read the recording. Measure rather than recall
(`CLAUDE.md`), and drive dock2 through its control socket rather than synthetic input: a key dock2 does
not take lands in whatever is in front, which is usually the terminal running the session.

## Running the build under observation

```sh
make build
.build/debug/dock2 quit                         # gives the Dock and every takeover back, then returns
DOCK2_DEBUG=1 nohup .build/debug/dock2 > /tmp/dock2.log 2>&1 &
.build/debug/dock2 status                       # "debug": true
```

- Prefer a VM ([below](#in-a-vm)): this Mac's Dock is the person's, and they may be using it.
- It is always fine to quit the running dock2, whoever started it, and run your own. There is no starting
  state to restore afterwards: don't relaunch the one you replaced. A dock2 built before `quit` refuses it;
  `kill -TERM` it instead, which does the same.
- A shell that started dock2 with `&` waits for it too at a bare `wait`: wait for a job by its `$!`.
- dock2 dismisses itself on a click elsewhere or another app coming forward. If the person at the Mac is
  using it, a driven run falls apart, and synthetic pointer moves take their cursor from them. Ask them
  to keep their hands off for the run. While dock2 has the keyboard their typing lands in it, and reads as a
  glitch that comes and goes: before chasing one, log the `keyCode` of what `keyActivity` hears.
- The build and the installed `Dock2.app` share `Clipboard/` but not its key (a file outside the bundle, the
  Keychain inside it), so each sets the other's `index.sealed` aside as `index-unreadable-<epoch>.sealed`.
  Before handing back to the installed app, quit the build and move that file back over `index.sealed`. A run whose own
  config has `history = false` under `[clipboard]` leaves the store alone, so nothing needs moving back.
- Settings apply as they are written. Give the build a config file of its own, so the installed app's is
  untouched: `DOCK2_CONFIG=/tmp/dock2.toml` at launch, then `DOCK2_CONFIG=/tmp/dock2.toml .build/debug/dock2
  config set search.field-form gem`, or edit the file. Setting a default takes its line out. The field's form
  changes at its next showing. A missing file is filled once from the old defaults domain. A file without
  `onboarded = true` under `[general]` opens onboarding and waits there, the dock not up and the control socket
  silent: start from a copy of the real file. `lsof -p <pid> | grep toml` says which file a run reads.
- `DOCK2_REDUCE_MOTION`, `DOCK2_REDUCE_TRANSPARENCY` and `DOCK2_INCREASE_CONTRAST` (`=1`) and
  `DOCK2_APPEARANCE=dark|light` stand in for the system's settings at launch.

dock2 empties its environment at launch (`LaunchEnvironment.setAside`), keeping it in `LaunchEnvironment.variables`:
an override read from `ProcessInfo` in a temporary build never arrives, so read a scratch file instead.

Time main-thread work on a release build (`swift build -c release`, then `.build/release/dock2` with the same
environment): the debug build bakes a form's motion about fifteen times slower, and its latencies are not the app's.

## In a VM

A Tart VM is another macOS with no one's hands to keep off, a Dock no one is using, and a dock2 free to crash. Run in one
unless the work needs this Mac: a VM's display is 1024×768 at 2×, and its GPU is an `Apple Paravirtual device`.

```sh
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base       # or macos-golden-gate-base
tart run tahoe-base &
tar -C .build/debug -cf - dock2 | tart exec -i tahoe-base /bin/sh -c 'mkdir -p /tmp/d2 && tar -xf - -C /tmp/d2'
tart exec tahoe-base /tmp/d2/dock2 debug audit
tart exec tahoe-base /bin/cat /tmp/d2/dock.png > dock.png              # a capture, back on the host
```

- `tart exec` needs no password and runs as `admin` in the logged-in session, so windows, `screencapture` and the control
  socket all work. The image has SIP off, `sudo` without a password, and TCC rows for the guest agent, `osascript` and
  `sshd-keygen-wrapper`: nothing a person would click needs one. Grant anything else through the TCC database.
- A dock2 in the foreground holds `tart exec` open: `nohup … > /tmp/d2/log 2>&1 &` from a script pushed to the VM, and
  poll `status`. Give it a config with `onboarded = true` under `[general]`, or none at all to see onboarding.
- The first capture raises a reminder that the guest agent may record the screen. Captures work behind it, and it
  appears in them, so push its date out once per VM, and it never comes up:

  ```sh
  P="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
  A=$(readlink -f /opt/homebrew/bin/tart-guest-agent); B=/usr/libexec/PlistBuddy
  $B -c "Add :$A dict" "$P" 2>/dev/null
  for k in kScreenCapturePrivacyHintDate kScreenCaptureApprovalLastAlerted; do
    $B -c "Delete :$A:$k" "$P" 2>/dev/null
    $B -c "Add :$A:$k date 'Thu Jan 01 00:00:00 GMT 3000'" "$P"
  done
  killall UserNotificationCenter replayd
  ```

- Bound what might wait on the GUI with `timeout`. An `osascript` walking every process through System Events hung for
  over a minute, and a hung `tart exec` looks like a slow one.

## Driving it

`dock2 <verb>` dials the running dock2 ([control](product/control.md)). The verbs anyone can use do what the
shortcut and the tiles do; the `debug` ones need the `DOCK2_DEBUG=1` launch above.

| Command | Does |
| --- | --- |
| `dock2 summon [query]` | takes the keyboard, the field risen, the query typed |
| `dock2 dismiss` | lets go, as Esc on an empty field does |
| `dock2 files [folder]`, `dock2 clipboard` | Files, Clipboard History |
| `dock2 debug type <text> [--every 0.12]` | typed into dock2's own event queue, a letter at a time with `--every` |
| `dock2 debug key <key>` | a key or a chord, as a menu, a key equivalent or the field takes it: `escape`, `return`, `up`, `cmd+k`, `cmd+1`, `shift+cmd+.` |
| `dock2 debug hold cmd` | modifiers held alone, standing in for the keyboard's, so held before `summon` it is ⌘space kept down; `none` lets go. Each tile's `number` in `debug state` says what shows |
| `dock2 debug reveal on` | holds the dock up, without the keyboard; `off` lets it go |
| `dock2 debug move <target>` | glides the real pointer there: `edge` reveals the dock as a person does, a tile shows its label |
| `dock2 debug click <target> [--right] [--double] [--option]…` | a click there; a row is selected by one and opened by two. An `x,y` is not checked: with the panel gone it lands in whatever is underneath, so read `debug state` first |
| `dock2 debug drag <target> <target>` | pressed, held, dragged and dropped, as AppKit's drag sessions need |
| `dock2 debug audit` | what this macOS lacks of the private API dock2 uses, a name a line; exits 1 if anything. Asks no dock2, so it runs where dock2 won't |
| `dock2 debug state` | JSON: the phase, who has the keyboard, the field's text and form, the rows and the selection, and the frames of the field, the panel, the panel's reach and the platter |

Frames are in screen points from the top left of the main display: what `screencapture -R` and a posted
event take. A part that is not showing has no frame, and its key is absent rather than null.

Keys never leave dock2: they are posted into its own event queue, so a chord meant for it cannot close the
terminal's tab. The pointer is the real one, since dock2 reads where the cursor is and AppKit's drag
sessions follow the hardware's. A target is `tile:<name>` or `tile:<n>` along the dock, `row:<n>` from the
field up, counted from 1 among the rows `debug state` lists, `field`, `platter`, `edge`, `away`, or `x,y`. One that `debug state` says is not showing — the dock
hidden, a row scrolled away — is refused rather than clicked through to whatever is beneath. Results arrive
over time: poll `debug state` until the row is there rather than sleeping a guess. `debug type` and `debug key` answer "summon it first" unless dock2 has the keyboard.

Anything a run opens from search is learned. `picks.json` and `usage.json` sit in Application Support whatever
`DOCK2_CONFIG` says, so a stray ↩ puts that result first for that query from then on. Copy both before a run that opens
results, and put them back once dock2 has quit: it holds them in memory and writes them over the top.

## Looking at views

A debug run built from source has the demo plugin ([plugins](IMPLEMENTATION.md#11-plugins)): every view
kind in every variation, over made-up data that is the same each run. Demo Gallery lists its screens; Demo
List, Detail, Form, Grid and Feedback open each kind's first. A screen starts afresh each time it opens.

```sh
dock2 summon "demo gallery"; dock2 debug key return   # the gallery
dock2 debug type player; dock2 debug key return        # filter it, open one
dock2 debug capture panel
```

`debug state` reads search's rows, not a view's: read a view by capturing it, and find its selection with
↩, since most of the demo's rows say what ran on which one. New views and variations go in `Plugins/demo`,
one `Screen` each, listed in its gallery.

## Capturing it

```sh
dock2 debug capture field                 # a PNG of the field and its shadow; prints the path
dock2 debug record reach 6 run.mov &      # 120 fps, the space the panel can grow into, in the background
dock2 summon; dock2 debug type safari --every 0.12; dock2 debug key escape; dock2 dismiss
```

Regions: `field`, `panel` (the glass as it is now), `reach` (the most the panel grows to at its width, for a
recording that grows), `dock` (the platter, the puck and their labels), `display`. `screencapture` needs Screen
Recording for the terminal, which it has here. A recording into an existing file fails, so
`record` removes it first.

`record`, and any ScreenCaptureKit stream, redraws a frame only where it changed, and the glass inside that
region comes out darker: a band around the caret in every frame after the first, and in no still. A frame
can also tear along straight lines where one redraw met the next. Footage meant to be seen, such as the
README's, is `SCScreenshotManager.captureSampleBuffer` calls on a fixed clock, written to an `AVAssetWriter`
stamped with their slots. Taken back to back, they come about 26 ms apart, give or take, and resampled to a
steady rate they judder. A 1040 × 750 region at 2× holds 25 fps, about one slot in a hundred missed, while 30
fps misses up to one in five. Whether the band also shows on the display is not yet measured.

A query of a letter or two lists files and clips by name. Footage that leaves the Mac comes from a run with
its own config, its `[search]` holding `sources-off = ["Files", "Clipboard", "Bitwarden"]`. Files opened at
`~` shows only the standard folders, while any other folder shows its siblings beside it.

The glass shows whatever window sits behind the reach, including a window's shadow some 45 points below
it, so hide those apps for the take. `NSRunningApplication.hide()` answers false and hides anyway, and
hiding the frontmost app can bring another back: list windows with `CGWindowListCopyWindowInfo` until none
are left. To have only the glass change, put a flat backdrop behind it: a borderless window of your own at
`.floating`, which is under the stage's dock level, ignoring the mouse. A glitch someone reports and a backdrop take does not show
is filmed over the real desktop too: the gem's entrance flash showed on every take over the desktop and on none over
a backdrop.

Settings is an ordinary window, outside these regions: `debug key cmd+,`, its bounds and id from
`CGWindowListCopyWindowInfo` (owner `dock2`), `debug click x,y` on its sidebar, and `screencapture -o -x -l<id>`. Crop
with `ffmpeg`: `sips -c` keeps the middle, whatever `--cropOffset` says.

## Reading a recording

A recording is read as contact sheets. This `ffmpeg` has no `drawtext`, so a sheet carries no timestamps:
lay frames out in order at a known rate instead.

```sh
# The whole take, three frames a second.
ffmpeg -loglevel error -y -i run.mov -vf "fps=3,scale=400:-1,tile=6x5:padding=3:color=red" -frames:v 1 sheet.png
# One moment, close: 0.8 s from 1.0 s at 24 frames a second, cropped in pixels (2× the points).
ffmpeg -loglevel error -y -ss 1.0 -t 0.8 -i run.mov -vf "fps=24,crop=1600:700:0:600,scale=640:-1,tile=4x5" -frames:v 1 moment.png
```

Find the moment on the coarse sheet, then cut close. A crop of a still at full resolution
(`crop=w:h:x:y`) shows the glass's rims and refraction; a sheet at 400 wide shows only shape and timing.

For timing to the frame, read one row of pixels per frame and find an edge in it — a platter's, an icon's.
`screencapture` writes a frame only when something changes, so keep the recording's own timestamps rather
than resampling:

```sh
ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 run.mov > times.txt
ffmpeg -loglevel error -i run.mov -vf "format=rgb24,crop=1932:2:0:276" -fps_mode passthrough -f rawvideo rows.raw
```

An entrance or a dismissal reads as a curve: score the region around the field in each frame by its mean difference
from the take's first frame, before anything showed. A fade climbs or falls steadily, and a frame that jumps ahead
of the climb, or holds still before it, is a state the window server showed on its own.

A mark on the platter is judged over a backdrop with some contrast. Over a flat one the band the glass refracts along
its foot does not show, and a digit straddling its edge looks fine. A column of pixels between two tiles, read at
1 pt steps up from the foot, gives the band's edges.

A flash or a jerk lasting a frame or two hides in a sheet. Score each frame, in grey at the recording's own
timestamps, by its mean difference from the average of its two neighbours: smooth motion scores about alike throughout,
and a glitch stands out as a frame or two well above it. Over a flat backdrop, at rest, a score past three times the
median is worth a look; events that recur on a period point at the motion's loop.

A crop's height must be even. A plain `screencapture -v` started from the shell runs in the background with
`&` and is waited for with `wait`; started inside `( … & )`, it records nothing.

## Trying a look before building it

A visual question the app cannot answer cheaply, such as five frost recipes side by side or three field forms
looping, goes to a harness in the session's scratchpad. It is a small AppKit app compiled with `swiftc` from
copies of `GlassLayer` and `GlassRecipe`, so it draws the same glass at the same size over whatever is on
screen. Use a transparent, borderless panel at `.floating` that ignores the mouse and never takes the
keyboard. Drive it from a display link, and add an environment switch to slow it down and one to hold it
still for recording.

A sweep that rewrites a source file can die between its edit and its restore, and the next run then takes the edit for
the baseline. Have the script restore on a trap and refuse a dirty baseline, and start every sweep at the baseline's own
values: if that first run differs from a capture of the baseline, or every run comes out alike, it is not measuring what
it says. A tree holding uncommitted work has no baseline in git: copy the files aside, and compare `git diff` before and after.

A measurement of pixels pins `DOCK2_APPEARANCE`. A run otherwise follows the Mac, which can turn dark mid-session, and a
threshold written for dark text on light then reads as a confident wrong number.

## Reading the system's own glass

A look the system draws is a recipe that can be read, so read it before fitting one by eye. A SwiftUI or AppKit probe in
the scratchpad hosts the real control, here `NavigationSplitView` with `.searchable(placement: .sidebar)`, then walks
its layers from `contentView.superview`: each `CABackdropLayer`'s `filters`, read by the names in `CAFilter`'s `inputKeys`
(`inputColorMatrix` is an `NSValue` of 20 floats), and each `CASDFLayer`'s `effect`, read through
`class_copyPropertyList`. Force the appearance with `NSApp.appearance`. A probe's field came within a level of System
Settings' at every sampled pixel, so a probe stands for the app.

- Then draw the recipe with `GlassLayer`'s tree and compare it with the probe by pixel columns, not by eye. Start
  from the same ground: a light field's numbers move with what it lies on.
- `make(_:)` a `CASDF…` object and read its defaults before trusting a property's name: the diffuse scales are 0
  unless set, and an unset filter input reads `nil`.
- Find what an input does by removing it and diffing two captures. A screenshot clips at 255, so it cannot show what
  `inputMaxHeadroom` or a clamp over 1 do on this Mac's EDR display.
- Measure glass over a black and a white backdrop before calling it stable: over one desktop, a top edge that follows
  what is behind the panel just looks a little weak.

## Reading Spotlight

dock2 holds ⌘space, but Spotlight opens beside it from its URL, in the `Siri AI` process, a window of owner "Siri" at
layer 23. Find the window with `CGWindowListCopyWindowInfo`.

- `open "spotlight://apps"` raises the Apps view. A bare `spotlight://` opens the Siri app's own window instead: close it.
- Post keys with `CGEvent.postToPid` to that process, so none can land in the terminal. Esc from Apps leaves the plain
  field, and letters then give results. A row reached with ↓ has a stronger selection than the first row has.
- `screencapture -o -x -l<window>` has no shadow or backdrop, so the window's alpha is the outline of the field and the
  panel. A capture with `-R` shows the glass over the desktop.
- It closes in steps, Esc by Esc: the results, then the field. The window's bounds read as the whole screen while the
  field alone shows, so go by whether it is listed at all. It leaves `Siri AI` frontmost: activate what was in front.

Fit a corner by tracing where the edge crosses halfway between inside and outside, then finding the radius whose
continuous outline lies nearest. Take the shape's box from a row and a column of pixels, not from a search out of a seed:
a soft edge or an inset shadow stops the search short and the fit comes back confident and wrong. An edge that tapers
out round its corner, as the pane's does, cannot be traced: read one row of pixels along the corner's diagonal instead.

## When synthetic input is the only way

- dock2's auto-hide zone is Cocoa y < 1: post the reveal at CG y equal to the screen's height (`debug move
  edge` does). Glide there, a move every 8 ms, as well as jumping.
- `CGEvent.postToPid` reaches dock2 alone. Each key event needs its characters set
  (`keyboardSetUnicodeString`), Esc as `0x1b` and delete as `0x7f`; a bare virtual key code never reaches the
  field.
- Posted to the HID tap, a key goes to whatever has the keyboard. Read `debug state` or a screenshot first,
  then send one Esc per dock2 layer that is up, never one to be sure: the spare lands in the terminal and
  interrupts the session. ⌘W, ⌘T and ⌘1–9 close and switch its tabs, so send them only while dock2 has the
  keyboard.
- A global shortcut is a Carbon hot key, which `debug key` never reaches: post the chord to the HID tap, flags set, and
  post ⌘space first as the control, so a chord that does nothing says something about the chord. A function key also
  needs `maskSecondaryFn`, or the hot key doesn't fire. One that isn't registered lands in whatever is in front, so
  give the run a chord nothing uses, in its own config.
- A window of your own may not land where asked: a tiling window manager moves it. Read its bounds from
  `CGWindowListCopyWindowInfo`, and check it is there, before posting a click at it.
- To time a menu's highlight, glide the pointer over two rows an event every 8 ms and read a thin strip beside their text from a
  120 Hz `SCStream`, against a plain app's menu. Run it over a flat backdrop: a window moving behind the panel hides the lag.
- `debug` has no scroll. Put the pointer over the list with `debug move x,y`, then post
  `CGEvent(scrollWheelEvent2Source: nil, units: .line, …)` to `.cghidEventTap` in a small `swiftc` tool: wheel events go
  to the window under the pointer. A long list rests in Files' last slot only with nothing selected in it, since a
  selection there opens another column and shifts the strip, so ↓ never reaches that case.
- The system Dock does not reveal for synthetic moves on macOS 27. Measure it through Accessibility
  (`AXDockItem` frames) and screenshots instead. To photograph it under the user's auto-hide, export
  `com.apple.dock` first, turn auto-hide off for the measurement and back on (the Dock restarts each time),
  and diff the domain against the export: `defaults write -int` over a real leaves an integer behind.

## Badges and minimised windows

- A Dock restart clears every badge and brings every minimised window back, and dock2's launch and quit
  both restart it: badge and minimise after dock2 is up. AppKit never sends a badge equal to the last, so a
  badge a restart cleared needs a new value.
- A test app of your own in the scratchpad gives both on demand: a window or two of flat colour,
  `NSApp.dockTile.badgeLabel` and `miniaturize(_:)`, driven by distributed notifications. Give it a Window menu,
  or the Dock's menu lists none of its windows. This Mac re-tiles its windows about 0.1 s after a `setFrame`;
  set `minSize` and `maxSize` to the shape as well and it holds, skinny or wide.
- Wrap it in an `.app` with an `Info.plist` and run its executable from there. A bare executable becomes a
  regular app only when it calls `setActivationPolicy(.regular)`, which `RunningApps` does not hear, so dock2
  may never watch its windows and every tile comes out `square`.
- A test app restores some of its own windows about a second after Minimize All, dock2 running or not. Test
  Minimize All on Terminal instead (quit it after if it was not running): windows of one title from
  AppleScript's `do script ""`, each told apart by `set background color of selected tab of window i`, and
  Window → Minimize All pressed through Accessibility with Terminal frontmost — pressed while it is not, it
  does nothing at the time and may act later.
- To time a minimise, poll `debug state` for the tile while an `AXObserver` of your own hears the app and the
  Dock, and record `display`: the tile can widen the platter past the `dock` region. Hold the dock up with
  `debug reveal on`, which also starts the badge reads that can see the Dock's item mid-genie.
- Give it native tabs (`tabbingIdentifier`, `addTabbedWindow`) and two windows of one title: a group of tabs
  is one Dock item, and a title is all an item has. A bare executable loses its Dock tile when the Dock
  restarts, and then gets an item for a minimised window even under "Minimize windows into application
  icon" — test that setting with a real app.
- Read the system Dock's items directly to compare: its list's children, `AXMinimizedWindowDockItem` with an
  `AXTitle`, against `debug state`. Pressing one (`AXPress`) restores its window, hidden Dock or not.
- Which window an item is: press the Dock's first item and hear the app's `AXWindowDeminiaturized`, again for
  each. That is exact for a lone window; a group of tabs reports every tab, in no fixed order, so for a group
  the truth is the tab you put on show.
- `debug state` gives each tile's `badge`, and a minimised window's tile as kind `window`, named by the
  Dock's title for it, with how it is drawn: `picture`, `shape` or `square`. Polled in a loop it answers in
  about 10 ms, fine enough to time a badge or a tile leaving. To check a picture is the right window's, give
  each window its own colour and `screencapture -R` a 2-point square inside the tile — left of the app icon,
  below the title bar — reading the colour by hue: the display's profile moves it too far for exact values.
- ScreenCaptureKit lists a minimised window but will not capture it (`SCScreenshotManager`: error −3811; a
  stream sends no frame). SkyLight's `SLSHWCaptureWindowList` does, as `WindowCapture` does. A probe that
  calls into CoreGraphics' window server needs `NSApplication.shared` first, or it asserts (`did_initialize`).
- The Dock's list frame (`AXSize`) moves with its gap only when the Dock started the change, as with
  `AXPress`; for a window the app minimised or restored it jumps at the end. Film the visible Dock for its
  motion. A frozen app (`kill -STOP`) still has its window restored by a press, item and all.
- `lsappinfo -all list` shows a badge as the app's `"StatusLabel"={ "label"="5" }`; `lsappinfo listen +all
  wait` hears launches and activations but nothing when a badge changes.

## Permissions

- Whether dock2 asked, not just checked, is in tccd's log: `/usr/bin/log show --last 1h --style compact
  --predicate 'process == "tccd"'` (zsh's `log` builtin shadows the tool), filtered to `msgID=<pid>.`. Each
  request's `AUTHREQ_CTX` names the service and `preflight=yes` for a check, `no` for an ask, which alone
  can prompt.
- The system TCC database is readable: `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db"` with
  `client = 'zip.tanner.dock2'` gives each row's `auth_value` (0 off, 2 on). Its `csreq` decodes with `csreq
  -r <file> -t`, and a row for an older build's cdhash does not apply to the installed one.
- Run from a terminal, dock2 is the terminal to TCC: its checks and requests, and Settings → Permissions, show
  the terminal's grants. A prompt is seen only from an app opened through LaunchServices.
- macOS shows one prompt at a time. An unanswered one holds the next back, and an Accessibility prompt
  outlives the process that raised it. A prompt held back appears once the one ahead is answered, after its
  process has gone, and answering it writes a row. Screenshot before asking, have whatever is up answered
  first, and clean up only once nothing is left waiting.
- To measure a request without spending dock2's own answers, use a probe: a small `.app` with its own
  bundle id, started with `open -n`. To clean up, `tccutil reset All <id>`. It finds the bundle through
  LaunchServices, which skips `/private/tmp`, so copy the probe to `~/Applications`, `lsregister -f` it,
  reset, then delete it.
