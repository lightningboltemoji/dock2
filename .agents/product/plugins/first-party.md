# First-party plugins

The plugins that ship with dock2. They are written against the same interface as anyone else's, and are the
test that it is enough.

## Now Playing

- **Tile**: the artwork, the play state, a progress ring. Hover: the track and the artist. Click: play or
  pause.
- **View**: the artwork, title and artist, a scrubber, previous, play/pause, next.
- **Commands**: Play/Pause, Next Track, Previous Track — so "next" in the field skips a song.
- **Needs** `now-playing`, which dock2 provides itself. **Open:** the system's now-playing service is
  reported to have answered only entitled processes since macOS 15.4; whether, and how, dock2 can read it
  on macOS 27 is unverified. The fallback is Apple Events to each player (Music, Spotify), at the price of
  an Automation prompt per player.

## Bitwarden

- **Command**: Search Vault — a list of items with their usernames, each opening to a detail. ↩ copies the
  password and ⌘↩ the username; ⌘K offers the TOTP code, the URL, and opening the site.
- **Results** in search are off by default: a vault in every query is the user's choice to make.
- **Sign-in**: a form for the server (bitwarden.com or self-hosted), the email and the master password. The
  master password is never stored. The session lives in the Keychain and locks after a timeout the user
  sets.
- **Copies are concealed**, so clipboard history never keeps them, and the clipboard is cleared after
  **Open:** 30 s.
- **Needs** `network` to the configured server, `secrets`, `clipboard.write`, and `query` only if results
  are switched on.
- **Open:** the client-side cryptography. Bitwarden's own client SDK is written in Rust, which makes it the
  obvious way in; whether it builds for dock2's runtime is unverified.

## Later

Candidates once the interface has proven itself: a calculator and unit conversion, the dictionary, an emoji
picker, system commands.
