import CryptoKit
import Dock2Core
import Foundation
import Security

/// Where the clipboard's key lives.
public protocol KeyStore: Sendable {
    /// The key, made on first use. May block on a Keychain prompt: never call it on the main thread.
    func key() throws -> SymmetricKey
}

/// A generic password in the login keychain, trusted by the app that made it.
public struct KeychainKeyStore: KeyStore {
    let service: String
    let account: String

    public init(service: String = Dock2Identity.bundleIdentifier, account: String = "clipboard-key") {
        self.service = service
        self.account = account
    }

    public func key() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let key = SymmetricKey(size: .bits256)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: account, kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                  kSecAttrLabel as String: "Dock2 clipboard history"]
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        return key
    }
}

/// A key in a file only the user can read: for tests, and for builds run outside the bundle, which the
/// Keychain would ask about on every rebuild.
public struct FileKeyStore: KeyStore {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func key() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.withUnsafeBytes { Data($0) }.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }
}

public enum KeyStores {
    /// The Keychain inside the bundle; a file outside it, or when `DOCK2_KEY_STORE=file` says so.
    public static func standard(directory: URL) -> KeyStore {
        let inBundle = Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
        if !inBundle || LaunchEnvironment.variables["DOCK2_KEY_STORE"] == "file" {
            return FileKeyStore(url: directory.appendingPathComponent("clipboard.key"))
        }
        return KeychainKeyStore()
    }
}

/// The history on disk ([clipboard](product/clipboard.md#where-it-lives)): `index.sealed` holds the entries,
/// `<id>.sealed` each one's data, every file an AES-GCM box. Writes are atomic and off the main thread.
public final class ClipboardStore: Sendable {
    public let directory: URL
    private let keys: KeyStore
    private let queue = DispatchQueue(label: "zip.tanner.dock2.clipboard", qos: .utility)
    private let cached = Box<SymmetricKey?>(nil)

    public init(directory: URL = Paths.directory.appendingPathComponent("Clipboard", isDirectory: true), keys: KeyStore? = nil) {
        self.directory = directory
        self.keys = keys ?? KeyStores.standard(directory: directory)
    }

    private func key() throws -> SymmetricKey {
        if let key = cached.value { return key }
        let key = try keys.key()
        cached.value = key
        return key
    }

    private func seal(_ data: Data) throws -> Data {
        try AES.GCM.seal(data, using: key()).combined!
    }

    private func open(_ data: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
    }

    private var index: URL { directory.appendingPathComponent("index.sealed") }
    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).sealed") }

    /// The Keychain did not give the key — locked, or refusing for now — so the history is not opened, and
    /// must not be written over until it is.
    public struct KeyUnavailable: Error {
        public let underlying: Error
    }

    /// The history as last saved, on the main actor: empty when there is none; set aside under another name
    /// when it is sealed with another key or damaged, so a fresh one does not destroy it; `KeyUnavailable`
    /// when the key cannot be had now.
    public func load(_ done: @escaping @MainActor @Sendable (Result<ClipHistory, KeyUnavailable>) -> Void) {
        queue.async {
            let result: Result<ClipHistory, KeyUnavailable>
            if !FileManager.default.fileExists(atPath: self.index.path) {
                result = .success(ClipHistory())
            } else {
                do {
                    let key = try self.key()
                    do {
                        let sealed = try Data(contentsOf: self.index)
                        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
                        result = .success(try JSONDecoder.iso8601.decode(ClipHistory.self, from: plain))
                    } catch {
                        let aside = self.directory.appendingPathComponent("index-unreadable-\(Int(Date().timeIntervalSince1970)).sealed")
                        try? FileManager.default.moveItem(at: self.index, to: aside)
                        warn("the clipboard history could not be opened with its key, so it was set aside as \(aside.lastPathComponent)")
                        result = .success(ClipHistory())
                    }
                } catch {
                    warn("could not open the clipboard history, for now: \(error.localizedDescription)")
                    result = .failure(KeyUnavailable(underlying: error))
                }
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    public func save(_ history: ClipHistory) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try self.seal(JSONEncoder.iso8601.encode(history)).write(to: self.index, options: [.atomic])
            } catch {
                warn("could not save the clipboard history: \(error.localizedDescription)")
            }
        }
    }

    /// An entry's data: every type it was copied with.
    public func save(_ data: [String: Data], for id: String) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let plist = try PropertyListEncoder().encode(data)
                try self.seal(plist).write(to: self.file(id), options: [.atomic])
            } catch {
                warn("could not save a clipboard entry: \(error.localizedDescription)")
            }
        }
    }

    /// An entry's data, read now: for a paste or a preview. Only with the key already held — the caller waits,
    /// and is the main thread, which never waits on the Keychain.
    public func data(for id: String) -> [String: Data]? {
        queue.sync {
            guard let key = cached.value, let sealed = try? Data(contentsOf: file(id)),
                  let plist = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key) else { return nil }
            return try? PropertyListDecoder().decode([String: Data].self, from: plist)
        }
    }

    public func remove(_ ids: [String]) {
        queue.async {
            for id in ids { try? FileManager.default.removeItem(at: self.file(id)) }
        }
    }

    /// Everything, the key's file aside.
    public func clear() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "sealed" { try? FileManager.default.removeItem(at: file) }
        }
    }
}
