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
| `dock2 debug type <text> [--every 0.12]` | typed through the stage window, a letter at a time with `--every` |
| `dock2 debug key escape` | also `return`, `tab`, `delete`, the arrows, `home`, `end` |
| `dock2 debug reveal on` | holds the dock up, without the keyboard; `off` lets it go |
| `dock2 debug state` | JSON: the phase, who has the keyboard, the field's text and form, the rows and the selection, and the frames of the field, the panel, the panel's reach and the platter |

Frames are in screen points from the top left of the main display: what `screencapture -R` and a posted
event take. A part that is not showing has no frame, and its key is absent rather than null. `debug type` and `debug key` answer "summon it first" unless dock2 has the keyboard.

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

## Trying a look before building it

A visual question the app cannot answer cheaply, such as five frost recipes side by side or three field forms
looping, goes to a harness in the session's scratchpad. It is a small AppKit app compiled with `swiftc` from
copies of `GlassLayer` and `GlassRecipe`, so it draws the same glass at the same size over whatever is on
screen. Use a transparent, borderless panel at `.floating` that ignores the mouse and never takes the
keyboard. Drive it from a display link, and add an environment switch to slow it down and one to hold it
still for recording.

## When synthetic input is the only way

- dock2's auto-hide zone is Cocoa y < 1: post the reveal at CG y equal to the screen's height. Glide there,
  a move every 8 ms, as well as jumping.
- `CGEvent.postToPid` reaches dock2 alone. Each key event needs its characters set
  (`keyboardSetUnicodeString`), Esc as `0x1b` and delete as `0x7f`; a bare virtual key code never reaches the
  field.
- Posted to the HID tap, a key goes to whatever has the keyboard. Send one Esc per dock2 layer that is up,
  never one to be sure: the spare lands in the terminal and interrupts the session.
- The system Dock does not reveal for synthetic moves on macOS 27. Measure it through Accessibility
  (`AXDockItem` frames) and screenshots instead.
