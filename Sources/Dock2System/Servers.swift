import Dock2Core
import Dock2NetFS
import Foundation
import NetFS

/// A file server Files shows as one place ([servers](product/files/README.md#servers)): `smb://<host>`, the
/// shares mounted from it, and who they were mounted as.
public struct Server: Equatable, Sendable {
    public var url: URL
    public var name: String
    /// Who its shares were mounted as; nil for a guest, or with none mounted.
    public var user: String?
    /// The mounted shares' roots, by the share's name.
    public var mounted: [String: URL]

    public var shares: [URL] { mounted.values.sorted { $0.path < $1.path } }

    /// Where `share` is mounted, its name's case aside.
    public func root(of share: String) -> URL? {
        mounted.first { $0.key.caseInsensitiveCompare(share) == .orderedSame }?.value
    }
}

/// What leads to servers and shares ([design](design/files.md#servers)): read from the mount table, cheap
/// enough for every menu and listing.
public enum Servers {
    /// Network's column: the servers the local network announces, and those connected to.
    public static let network = URL(string: "network:")!
    /// The file systems whose servers are places: each has a NetFS plugin that lists its shares.
    static let schemes: Set<String> = ["smb"]

    /// The servers connected to: the mounted volumes grouped by the server each was mounted from.
    public static var connected: [Server] {
        var servers: [Server] = []
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? [] {
            guard let remount = remountURL(of: volume), let server = server(of: remount) else { continue }
            let share = remount.lastPathComponent
            if let index = servers.firstIndex(where: { $0.url == server }) {
                servers[index].mounted[share] = volume.canonical
            } else {
                servers.append(Server(url: server, name: name(of: server), user: remount.user(percentEncoded: false), mounted: [share: volume.canonical]))
            }
        }
        return servers
    }

    public static func isServer(_ url: URL) -> Bool {
        !url.isFileURL && schemes.contains(url.scheme ?? "") && url.host != nil && (url.path.isEmpty || url.path == "/")
    }

    /// A share's address, `smb://<host>/<share>`: a share not mounted.
    public static func isShare(_ url: URL) -> Bool {
        !url.isFileURL && schemes.contains(url.scheme ?? "") && url.host != nil && url.path.count > 1
    }

    /// `smb://<host>` for a server, a share's address, or a mounted share's remount URL. Nil for a file.
    public static func server(of url: URL) -> URL? {
        guard !url.isFileURL, let scheme = url.scheme, schemes.contains(scheme), let host = url.host(percentEncoded: false) else { return nil }
        return Self.url(scheme: scheme, host: host)
    }

    /// The server a mounted share's root was mounted from.
    public static func server(ofRoot volume: URL) -> URL? {
        remountURL(of: volume).flatMap(server(of:))
    }

    /// What leads above `url` in Files' columns: a share's root to its server, a server to Network, anything
    /// else to the folder holding it. Nothing above Network or the root of the disk.
    public static func parent(of url: URL) -> URL? {
        if url == network { return nil }
        if isServer(url) { return network }
        if isShare(url) { return server(of: url) }
        if url.path == "/" { return nil }
        if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true, let server = server(ofRoot: url) { return server }
        return url.parentFolder
    }

    /// "Synology" for `Synology._smb._tcp.local`, as Finder names a server Bonjour announced; another host as
    /// it is.
    public static func name(of server: URL) -> String {
        if server == network { return "Network" }
        let host = server.host(percentEncoded: false) ?? server.absoluteString
        let suffix = "._smb._tcp.local"
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        return trimmed.lowercased().hasSuffix(suffix) ? String(trimmed.dropLast(suffix.count)) : trimmed
    }

    /// `host` percent-encoded, as Finder's remount URLs carry a Bonjour name's spaces and apostrophes.
    public static func url(scheme: String = "smb", host: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.encodedHost = host.addingPercentEncoding(withAllowedCharacters: unreserved) ?? host
        return components.url!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The address that mounts `share` on `server` — the server itself for none — as `user` when there is one.
    public static func address(of share: String?, on server: URL, user: String? = nil) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.user = user
        components.path = share.map { "/" + $0 } ?? ""
        return components.url!
    }

    /// The share an address names, without who it mounts as: what Files' columns hold.
    public static func plain(_ address: URL) -> URL {
        guard let server = server(of: address) else { return address }
        return Self.address(of: address.lastPathComponent, on: server)
    }

    /// A disk that comes out, or a network volume: what ⏏ is for.
    static func ejects(_ volume: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey]
        guard let values = try? volume.resourceValues(forKeys: keys) else { return false }
        return values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false
    }

    /// The URL a network volume was mounted from, for the schemes whose servers are places.
    static func remountURL(of volume: URL) -> URL? {
        guard let values = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey, .volumeIsLocalKey]), values.volumeIsLocal == false,
              let remount = values.volumeURLForRemounting, schemes.contains(remount.scheme ?? "") else { return nil }
        return remount
    }
}

/// Why a server listed nothing, or a share did not mount.
public enum ServerProblem: Error, Equatable, Sendable {
    /// No answer in `ShareListing.timeout`, or no route there.
    case unreachable
    /// It lists nothing for a guest: Connect As… is the way in.
    case needsSignIn
    /// The person closed macOS's window.
    case cancelled
    case failed(Int32)

    init(_ status: Int32) {
        switch status {
        case ECANCELED, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ECONNREFUSED, ENETDOWN: self = .unreachable
        case EAUTH, EACCES, EPERM, Int32(ENETFSNOAUTHMECHSUPP), Int32(ENETFSACCOUNTRESTRICTED), Int32(ENETFSNOSHARESAVAIL): self = .needsSignIn
        case Int32(userCanceledErr): self = .cancelled
        default: self = .failed(status)
        }
    }
}

/// The shares a server offers, mounted or not, through its NetFS plugin (`NetFSPlugin.h`), off the main thread.
public enum ShareListing {
    public struct Listing: Equatable, Sendable {
        public var shares: [String]
        /// Who the session is as: nil for a guest.
        public var user: String?
    }

    /// A host that does not answer holds a session open past a minute.
    public static let timeout: TimeInterval = 15

    /// Lists `server` as `user`, or as a guest with none. `done` runs on the main thread.
    public static func list(_ server: URL, as user: String?, done: @escaping @MainActor @Sendable (Result<Listing, ServerProblem>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(server, as: user)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    private static func run(_ server: URL, as user: String?) -> Result<Listing, ServerProblem> {
        guard let plugin = NetFSPlugin.shared(for: server.scheme ?? "") else { return .failure(.failed(ENOTSUP)) }
        let session = NetFSPlugin.Session()
        guard plugin.table.CreateSessionRef(&session.ref) == 0 else { return .failure(.failed(ENOMEM)) }
        defer { _ = plugin.table.CloseSession(session.ref) }
        let cancel = DispatchWorkItem { _ = plugin.table.Cancel(session.ref) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: cancel)
        defer { cancel.cancel() }
        let address = Servers.address(of: nil, on: server, user: user)
        var options: [String: Any] = [kNAUIOptionKey: kNAUIOptionNoUI]
        if user == nil { options[kNetFSUseGuestKey] = true }
        var info: Unmanaged<CFDictionary>?
        let opened = plugin.table.OpenSession(address as CFURL, session.ref, options as CFDictionary, &info)
        let details = info?.takeRetainedValue() as? [String: Any]
        guard opened == 0 else { return .failure(ServerProblem(opened)) }
        var found: Unmanaged<CFDictionary>?
        let listed = plugin.table.EnumerateShares(session.ref, nil, &found)
        guard listed == 0, let shares = found?.takeRetainedValue() as? [String: [String: Any]] else { return .failure(ServerProblem(listed)) }
        let names = shares.filter { $0.value[kNetFSIsHiddenKey] as? Bool != true && !$0.key.hasSuffix("$") }.map(\.key)
        let guest = details?[kNetFSMountedByGuestKey] as? Bool == true
        return .success(Listing(shares: names, user: guest ? nil : details?[kNetFSMountedByUserKey] as? String))
    }
}

/// Mounting a share through NetFS, which asks in macOS's own window when it needs a name and password.
public enum ShareMount {
    /// `address` mounted where macOS puts it — every share chosen in macOS's window, for a server's
    /// address. `signIn` asks for a name even when one would do. `done` runs on the main thread.
    @MainActor
    public static func mount(_ address: URL, signIn: Bool = false, done: @escaping @MainActor @Sendable (Result<[URL], ServerProblem>) -> Void) {
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = signIn ? kNAUIOptionForceUI : kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(address as CFURL, nil, nil, nil, open, nil, &request, .main) { status, _, points in
            let mounted = (points as? [String])?.map { URL(fileURLWithPath: $0).canonical } ?? []
            MainActor.assumeIsolated { done(status == 0 ? .success(mounted) : .failure(ServerProblem(status))) }
        }
        if status != 0 { done(.failure(ServerProblem(status))) }
    }
}

/// Ejecting what ⏏ is on, off the main thread: a server gone quiet holds an unmount.
public enum Eject {
    /// A network share alone — `unmount(2)`, which the system's ways unmount its server's every share for —
    /// or a disk, the whole device. `done` runs on the main thread with what stopped it.
    @MainActor
    public static func eject(_ volume: URL, done: @escaping @MainActor @Sendable (Error?) -> Void) {
        let network = (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        guard !network else {
            DispatchQueue.global(qos: .userInitiated).async {
                let error: Error? = unmount(volume.path, 0) == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                DispatchQueue.main.async { MainActor.assumeIsolated { done(error) } }
            }
            return
        }
        FileManager.default.unmountVolume(at: volume, options: [.allPartitionsAndEjectDisk]) { error in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(error) } }
        }
    }

    /// Every share mounted from `server`, one at a time; the first that will not go stops the rest.
    @MainActor
    public static func disconnect(_ server: Server, done: @escaping @MainActor @Sendable (_ share: URL?, Error?) -> Void) {
        @MainActor func next(_ shares: ArraySlice<URL>) {
            guard let share = shares.first else { return done(nil, nil) }
            eject(share) { error in
                if let error { done(share, error) } else { next(shares.dropFirst()) }
            }
        }
        next(server.shares[...])
    }

    /// Finder's words for a volume that would not go.
    public static func message(_ error: Error, name: String) -> String {
        if (error as? POSIXError)?.code == .EBUSY || (error as NSError).code == fBsyErr {
            return "“\(name)” can't be ejected because it's in use."
        }
        return "“\(name)” can't be ejected. \(error.localizedDescription)"
    }
}

/// A file system's NetFS plugin, loaded once: the interface `NetFSPlugin.h` describes.
final class NetFSPlugin: @unchecked Sendable {
    let table: NetFSMountInterface_V1

    /// A session's handle, for `Cancel` from another thread while `OpenSession` waits.
    final class Session: @unchecked Sendable {
        var ref: UnsafeMutableRawPointer?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: NetFSPlugin] = [:]

    static func shared(for scheme: String) -> NetFSPlugin? {
        lock.lock()
        defer { lock.unlock() }
        if let plugin = loaded[scheme] { return plugin }
        let plugin = load(scheme)
        loaded[scheme] = plugin
        return plugin
    }

    private init(table: NetFSMountInterface_V1) {
        self.table = table
    }

    private static func load(_ scheme: String) -> NetFSPlugin? {
        let bundle = URL(fileURLWithPath: "/System/Library/Filesystems/NetFSPlugins/\(scheme).bundle") as CFURL
        // kNetFSTypeID and kfs_NetFSMountInterfaceID_V1, which Swift does not import from their macros.
        let type = CFUUIDGetConstantUUIDWithBytes(nil, 0x02, 0xfe, 0x7d, 0x14, 0x4e, 0x91, 0x48, 0x1e, 0x94, 0x6c, 0xce, 0x23, 0x3c, 0x79, 0x8c, 0xc0)
        let interface = CFUUIDGetConstantUUIDWithBytes(nil, 0x8f, 0x34, 0xb6, 0xc4, 0xf2, 0xe4, 0x4e, 0xcd, 0x86, 0x25, 0xe5, 0x66, 0x58, 0x11, 0xde, 0x37)
        guard let plugin = CFPlugInCreate(nil, bundle),
              let factories = CFPlugInFindFactoriesForPlugInTypeInPlugIn(type, plugin) as? [CFUUID], let factory = factories.first,
              let instance = CFPlugInInstanceCreate(nil, factory, type) else { return nil }
        let unknown = instance.assumingMemoryBound(to: UnsafeMutablePointer<IUnknownVTbl>.self)
        var found: LPVOID?
        _ = unknown.pointee.pointee.QueryInterface(unknown, CFUUIDGetUUIDBytes(interface), &found)
        _ = unknown.pointee.pointee.Release(unknown)
        guard let found else { return nil }
        // The interface stays for the life of dock2: one per file system, never released.
        return NetFSPlugin(table: found.assumingMemoryBound(to: UnsafeMutablePointer<NetFSMountInterface_V1>.self).pointee.pointee)
    }
}
