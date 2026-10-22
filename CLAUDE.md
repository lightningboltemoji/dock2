`.agents/README.md` provides context on the project and how knowledge is managed.

House rules:

- Bias towards clean architecture. Ask yourself if this is the right solution or the easy one.
- Bias towards validating instead of guessing. The real Dock is on this machine: measure it — through
  Accessibility, and with screenshots — rather than recalling what it looks like.
- Observe dock2 through `DOCK2_DEBUG=1` and `dock2 debug …`, not synthetic input: `.agents/OBSERVING.md`.
- Never leave the user's Dock hidden. Anything that touches `com.apple.dock` goes through `Suppressor`
  and the journal; test the crash path (`kill -9`) after changing it.
- Keep this file thin. It carries triggers; `.agents/` carries content.
- What a session learns goes into `.agents/`, never into Claude's auto-memory, which no one else can see.
- Feature work ends with the change file, and writing it starts the pass in `.agents/DOCS.md`. Run the pass
  before reporting the work done.
