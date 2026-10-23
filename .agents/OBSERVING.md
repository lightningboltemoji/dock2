# Observing dock2

How to see the live dock2 do something, record it, and read the recording. Measure rather than recall
(`CLAUDE.md`), and drive dock2 through its control socket rather than synthetic input: a key dock2 does
not take lands in whatever is in front, which is usually the terminal running the session.

## Running the build under observation

```sh
make build
kill -TERM $(pgrep -f 'build/debug/dock2$')     # gives the Dock and every takeover back
DOCK2_DEBUG=1 nohup .build/debug/dock2 > /tmp/dock2.log 2>&1 &
.build/debug/dock2 status                       # "debug": true
```

- Another session may be building and relaunching the same checkout. Check `pgrep -lf build/debug/dock2`
  and `git status` first, and say so before replacing a dock2 someone else started.
- dock2 dismisses itself on a click elsewhere or another app coming forward. If the person at the Mac is
  using it, a driven run falls apart, and synthetic pointer moves take their cursor from them. Ask them
  to keep their hands off for the run.
- The build and the installed `Dock2.app` share `Clipboard/` but not its key (a file outside the bundle, the
  Keychain inside it), so each sets the other's `index.sealed` aside as `index-unreadable-<epoch>.sealed`.
  Before handing back to the installed app, quit the build and move that file back over `index.sealed`.
- Settings apply as they are written: `defaults write zip.tanner.dock2 fieldForm -string gem`, and
  `defaults delete` to go back to the default. The field's form changes at its next showing.
- `DOCK2_REDUCE_MOTION`, `DOCK2_REDUCE_TRANSPARENCY` and `DOCK2_INCREASE_CONTRAST` (`=1`) and
  `DOCK2_APPEARANCE=dark|light` stand in for the system's settings at launch.

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
| `dock2 debug hold cmd` | modifiers held alone, as for the number badges; `none` lets go |
| `dock2 debug reveal on` | holds the dock up, without the keyboard; `off` lets it go |
| `dock2 debug move <target>` | glides the real pointer there: `edge` reveals the dock as a person does, a tile shows its label |
| `dock2 debug click <target> [--right] [--double] [--option]…` | a click there; a row is selected by one and opened by two |
| `dock2 debug drag <target> <target>` | pressed, held, dragged and dropped, as AppKit's drag sessions need |
| `dock2 debug state` | JSON: the phase, who has the keyboard, the field's text and form, the rows and the selection, and the frames of the field, the panel, the panel's reach and the platter |

Frames are in screen points from the top left of the main display: what `screencapture -R` and a posted
event take. A part that is not showing has no frame, and its key is absent rather than null.

Keys never leave dock2: they are posted into its own event queue, so a chord meant for it cannot close the
terminal's tab. The pointer is the real one, since dock2 reads where the cursor is and AppKit's drag
sessions follow the hardware's. A target is `tile:<name>` or `tile:<n>` along the dock, `row:<n>` from the
field up, `field`, `platter`, `edge`, `away`, or `x,y`. One that `debug state` says is not showing — the dock
hidden, a row scrolled away — is refused rather than clicked through to whatever is beneath. Results arrive
over time: poll `debug state` until the row is there rather than sleeping a guess. `debug type` and `debug key` answer "summon it first" unless dock2 has the keyboard.

## Capturing it

```sh
dock2 debug capture field                 # a PNG of the field and its shadow; prints the path
dock2 debug record reach 6 run.mov &      # 120 fps, the space the panel can grow into, in the background
dock2 summon; dock2 debug type safari --every 0.12; dock2 debug key escape; dock2 dismiss
```

Regions: `field`, `panel` (the glass as it is now), `reach` (the most the panel grows to at its width, for a
recording that grows), `dock` (the platter and its labels), `display`. `screencapture` needs Screen
Recording for the terminal, which it has here. A recording into an existing file fails, so
`record` removes it first.

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

A crop's height must be even. A plain `screencapture -v` started from the shell runs in the background with
`&` and is waited for with `wait`; started inside `( … & )`, it records nothing.

## Trying a look before building it

A visual question the app cannot answer cheaply, such as five frost recipes side by side or three field forms
looping, goes to a harness in the session's scratchpad. It is a small AppKit app compiled with `swiftc` from
copies of `GlassLayer` and `GlassRecipe`, so it draws the same glass at the same size over whatever is on
screen. Use a transparent, borderless panel at `.floating` that ignores the mouse and never takes the
keyboard. Drive it from a display link, and add an environment switch to slow it down and one to hold it
still for recording.

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
  or the Dock's menu lists none of its windows.
- Give it native tabs (`tabbingIdentifier`, `addTabbedWindow`) and two windows of one title: a group of tabs
  is one Dock item, and a title is all an item has. A bare executable loses its Dock tile when the Dock
  restarts, and then gets an item for a minimised window even under "Minimize windows into application
  icon" — test that setting with a real app.
- Read the system Dock's items directly to compare: its list's children, `AXMinimizedWindowDockItem` with an
  `AXTitle`, against `debug state`. Pressing one (`AXPress`) restores its window, hidden Dock or not.
- `debug state` gives each tile's `badge`, and a minimised window's tile as kind `window`, named by the
  Dock's title for it. Polled in a loop it answers in about 10 ms, fine enough to time a badge or a tile
  leaving.
- The Dock's list frame (`AXSize`) moves with its gap only when the Dock started the change, as with
  `AXPress`; for a window the app minimised or restored it jumps at the end. Film the visible Dock for its
  motion. A frozen app (`kill -STOP`) still has its window restored by a press, item and all.
- `lsappinfo -all list` shows a badge as the app's `"StatusLabel"={ "label"="5" }`; `lsappinfo listen +all
  wait` hears launches and activations but nothing when a badge changes.
