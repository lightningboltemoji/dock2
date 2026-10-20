# The first launch

A short sequence in one window, before dock2 changes anything. Its choices take effect at the end, so
quitting before then leaves the Mac as it was — except file access, which is macOS's, granted when it is
answered.

1. **What dock2 does.** It replaces the Dock while it runs. The Dock's settings are saved first and come
   back when dock2 quits — even if it crashes or is killed. _Continue_ or _Quit_.
2. **Your dock.** The system Dock's apps and tile size, copied ([settings](settings.md)), shown as dock2 will
   draw them.
3. **⌘space.** "Open dock2 with ⌘space? Spotlight's shortcut is switched off while dock2 runs, and back on
   when it quits." _Use ⌘space_, _Choose another…_ or _Not now_.
4. **Your files.** "dock2 shows and finds your files; Full Disk Access lets it see all of them." _Open System
   Settings_, _Just Desktop, Documents and Downloads_ (macOS asks once for each), or _Not now_
   ([access](files/access.md)). Beneath, ticked: "Open 'Show in Finder' from other apps in dock2"
   ([takeovers](system/takeovers.md)).
5. **Clipboard history.** "Keep what you copy — on this Mac, encrypted, for 30 days? Passwords are never
   kept." _Keep history_ or _No thanks_.
6. **Open at login.** _Open at login_ or _Not now_.
7. **How it works.** Reveal the dock or press the shortcut, then type. ⌘1–9 open the first nine tiles. Esc
   steps back.

File access is the only macOS permission asked for here, and only if the user takes it; every other
permission waits for its feature ([permissions](system/permissions.md)). Settings → About runs the
sequence again.
