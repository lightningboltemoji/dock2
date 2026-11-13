# Files

Built (`IMPLEMENTATION.md` §9). What is ahead:

- **Verify without Full Disk Access** itself: search's access row; external and network volumes' prompts.
- **Put Back**: whether Finder's Put Back works for what dock2 trashes (`FileManager.trashItem`).
- _Later_, as the product says: Compress, tags, renaming many at once, operations needing a password.

## Servers

Built (`IMPLEMENTATION.md` §9, [servers](../product/files/README.md#servers)). What is ahead:

- **Local Network from the bundle.** Mounts run in `NetAuthSysAgent`, which reaches the network as the app
  that asked: from an unsigned tool without the grant, `GetServerInfo` failed with `EHOSTUNREACH` after 30 s
  while the same call in-process answered at once, and succeeded the moment Finder's agent was the one
  running. The debug build inherits the terminal's grant. **Open:** whether Dock2.app with Local Network
  denied can still mount, or only list what it is connected to — the permissions row says the latter until
  it is measured.
- **A server not connected**: its guest listing, Not Connected over Connect As…, the first sign-in. This Mac's
  one server was connected throughout; disconnecting it would have taken shares the user had mounted.
- **A server that does not answer**: `Cancel` at 15 s is untried; a host that answered nothing held
  `OpenSession` past a minute without it.
- **NFS**: `nfs.bundle` has the same interface. `Servers.schemes` is SMB alone until an NFS server is seen.
