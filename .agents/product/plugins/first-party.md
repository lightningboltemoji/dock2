# First-party plugins

The plugins that ship with dock2, off until the user switches them on in Settings → Plugins. They are
written against the same interface as anyone else's, and are the test that it is enough.

## Now Playing

- **Tile**: the artwork, the play state, a progress ring. Hover: the track and the artist. Click: play or
  pause.
- **View**: the artwork, title and artist, a scrubber with the time either side, previous, play/pause,
  next.
- **Commands**: Play/Pause, Next Track, Previous Track — so "next" in the field skips a song.
- **Needs** `now-playing`, which dock2 provides itself. The system's now-playing service answers only
  entitled processes and the system's own binaries, so dock2 reads it through a helper the system's perl
  hosts; commands need nothing. _Next_: Apple Events to each player (Music, Spotify) where that fails, at
  the price of an Automation prompt per player.

## Bitwarden

- **Commands** follow the session. Signed out, only Sign In, which opens the sign-in form. Signed in,
  Search Vault and Sign Out, with Lock while the vault is unlocked.
- **Search Vault**: a list of items with their usernames, each opening to a detail. ↩ copies the
  password and ⌘↩ the username; ⌘K offers the TOTP code, the URL, and opening the site.
- **Results** in search are off by default: a vault in every query is the user's choice to make.
- **Sign-in**: a form for the email and the master password, titled with the server it signs in to. The
  server — bitwarden.com, bitwarden.eu or self-hosted — is a setting in Settings → Plugins, since it is the
  host `network` may reach, which the user grants and a plugin cannot change. The master password is never
  stored. The session lives in the Keychain and locks after a timeout the user
  sets.
- **Copies are concealed**, so clipboard history never keeps them, and the clipboard is cleared after
  30 s.
- **Needs** `network` to the configured server, `secrets`, `clipboard.write`, and `query` only if results
  are switched on.
- **The cryptography** is in the plugin, in Rust, but for the master key, which dock2 derives natively:
  PBKDF2's 600,000 rounds and Argon2's 64 MiB are past what a plugin's call may spend. Items an
  organization shares are opened with its key, as the account's private key opens it.

## Later

Candidates once the interface has proven itself: the dictionary, an emoji picker, system commands. The
calculator is dock2's own ([search](../search/README.md#the-calculator)): its answer comes before every
source's, which a plugin's results never do.
