import Dock2Core
import DockWasm
import Foundation

/// The engine ([plugins](design/plugins.md#the-engine)): wasmtime's Pulley interpreter behind dockwasm's C
/// ABI — no executable memory, so nothing the hardened runtime refuses. One per process.
public final class PluginEngine: @unchecked Sendable {
    let raw: OpaquePointer

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static var version: String { String(cString: dw_version()) }

    public init() throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let raw = dw_engine_new(&error) else { throw Failure(description: Self.take(error)) }
        self.raw = raw
    }

    deinit { dw_engine_free(raw) }

    static func take(_ error: UnsafeMutablePointer<CChar>?) -> String {
        guard let error else { return "unknown error" }
        defer { dw_string_free(error) }
        return String(cString: error)
    }

    /// A plugin's module: compiled from its `.wasm`, or read back from what this engine compiled before.
    public final class Module: @unchecked Sendable {
        let raw: OpaquePointer

        init(_ raw: OpaquePointer) {
            self.raw = raw
        }

        deinit { dw_module_free(raw) }

        /// The compiled module, to keep: only this build of the engine may read it back.
        public func serialized() throws -> Data {
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            var error: UnsafeMutablePointer<CChar>?
            guard dw_module_serialize(raw, &bytes, &count, &error) == 0, let bytes else { throw Failure(description: take(error)) }
            defer { dw_bytes_free(bytes, count) }
            return Data(bytes: bytes, count: count)
        }
    }

    public func compile(_ wasm: Data) throws -> Module {
        var error: UnsafeMutablePointer<CChar>?
        let raw = wasm.withUnsafeBytes { dw_module_compile(self.raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &error) }
        guard let raw else { throw Failure(description: Self.take(error)) }
        return Module(raw)
    }

    /// Bytes `Module.serialized` made with this same engine build, never anyone else's.
    public func deserialize(_ bytes: Data) throws -> Module {
        var error: UnsafeMutablePointer<CChar>?
        let raw = bytes.withUnsafeBytes { dw_module_deserialize(self.raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &error) }
        guard let raw else { throw Failure(description: Self.take(error)) }
        return Module(raw)
    }

    /// How a call ended.
    public enum Outcome: Equatable, Sendable {
        case effects(Data)
        /// The budget ran out and the call was stopped.
        case deadline
        case memory(String)
        case trap(String)
        case error(String)
    }

    /// One running plugin. Any outcome but `effects` leaves it unusable: make another.
    public final class Instance: @unchecked Sendable {
        let raw: OpaquePointer
        /// Kept alive for the C callback, which gets it back as its context.
        private let logger: Logger

        final class Logger {
            let log: @Sendable (Int, String) -> Void
            init(_ log: @escaping @Sendable (Int, String) -> Void) { self.log = log }
        }

        init(engine: PluginEngine, module: Module, memoryCap: UInt64, log: @escaping @Sendable (Int, String) -> Void) throws {
            logger = Logger(log)
            var error: UnsafeMutablePointer<CChar>?
            let callback: dw_log_fn = { context, level, bytes, count in
                guard let context, let bytes else { return }
                let logger = Unmanaged<Logger>.fromOpaque(context).takeUnretainedValue()
                logger.log(Int(level), String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
            }
            guard let raw = dw_instance_new(engine.raw, module.raw, memoryCap, callback, Unmanaged.passUnretained(logger).toOpaque(), &error)
            else { throw Failure(description: PluginEngine.take(error)) }
            self.raw = raw
        }

        deinit { dw_instance_free(raw) }

        /// One event in, its effects out, within `budget` milliseconds.
        public func call(_ event: Data, budget: UInt32) -> Outcome {
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            let status = event.withUnsafeBytes {
                dw_instance_call(raw, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, budget, &bytes, &count)
            }
            let out = bytes.map { Data(bytes: $0, count: count) } ?? Data()
            if let bytes { dw_bytes_free(bytes, count) }
            let text = String(decoding: out, as: UTF8.self)
            switch status {
            case DW_OK: return .effects(out)
            case DW_DEADLINE: return .deadline
            case DW_MEMORY: return .memory(text)
            case DW_TRAP: return .trap(text)
            default: return .error(text)
            }
        }
    }

    /// A key from a password, natively; nil when the parameters are refused.
    public static func derive(_ derivation: Derivation) -> Data? {
        var key = Data(count: derivation.length)
        let password = Data(derivation.password.utf8)
        let status = key.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { password in
                derivation.salt.withUnsafeBytes { salt in
                    let (p, s, o) = (password.bindMemory(to: UInt8.self), salt.bindMemory(to: UInt8.self), out.bindMemory(to: UInt8.self))
                    switch derivation.function {
                    case .pbkdf2:
                        return dw_pbkdf2_sha256(p.baseAddress, p.count, s.baseAddress, s.count, UInt32(derivation.iterations), o.baseAddress, o.count)
                    case .argon2id:
                        return dw_argon2id(p.baseAddress, p.count, s.baseAddress, s.count, UInt32(derivation.iterations),
                                           UInt32(derivation.memory ?? 0), UInt32(derivation.parallelism ?? 0), o.baseAddress, o.count)
                    }
                }
            }
        }
        return status == 0 ? key : nil
    }

    public func instantiate(_ module: Module, memoryCap: UInt64, log: @escaping @Sendable (Int, String) -> Void) throws -> Instance {
        try Instance(engine: self, module: module, memoryCap: memoryCap, log: log)
    }
}
