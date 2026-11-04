import Dock2Core
import Foundation
import XPC

/// XPC for plugins ([services](product/plugins/permissions.md#services)): a connection per plugin and service,
/// opened at its first message, by Mach name and held to the team the manifest names — the name alone proves
/// nothing, since any LaunchAgent can claim one in the user's domain.
@MainActor
final class PluginXPC {
    /// A connection not yet activated: production's by Mach name, a test's to a listener of its own.
    var connect: (XPCService) -> xpc_connection_t = PluginXPC.machService
    /// What a connection says unasked — a message, or that it closed — on the main actor.
    var onEvent: (_ plugin: String, _ event: PluginEvent) -> Void = { _, _ in }
    private var open: [String: [String: xpc_connection_t]] = [:]
    private let queue = DispatchQueue(label: "zip.tanner.dock2.plugin-xpc")

    nonisolated static func machService(_ service: XPCService) -> xpc_connection_t {
        let flags = service.daemon == true ? UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED) : 0
        let connection = xpc_connection_create_mach_service(service.name, nil, flags)
        require(team: service.team, of: connection)
        return connection
    }

    /// Signed by the team, by a certificate Apple issued: Developer ID, the App Store's, or development's.
    nonisolated static func require(team: String, of connection: xpc_connection_t) {
        _ = xpc_connection_set_peer_code_signing_requirement(connection, "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
    }

    /// Sends `message`, opening the connection first if it has to; `reply` hears the answer, or why there is
    /// none, on the main actor.
    func send(_ message: XPCValue, to service: XPCService, from plugin: String, reply: (@MainActor (Result<XPCValue, XPCValue.Refusal>) -> Void)?) {
        let connection = open[plugin]?[service.name] ?? start(service, for: plugin)
        let object = Self.object(message)
        guard let reply else {
            xpc_connection_send_message(connection, object)
            return
        }
        xpc_connection_send_message_with_reply(connection, object, queue) { answer in
            let result: Result<XPCValue, XPCValue.Refusal>
            if xpc_get_type(answer) == XPC_TYPE_ERROR {
                result = .failure(.init(message: "\(service.name): \(Self.describe(answer))"))
            } else {
                do { result = .success(try Self.value(answer)) } catch let refusal as XPCValue.Refusal { result = .failure(refusal) } catch {
                    result = .failure(.init(message: "\(error)"))
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { reply(result) } }
        }
    }

    private func start(_ service: XPCService, for plugin: String) -> xpc_connection_t {
        let connection = connect(service)
        let name = service.name, identity = ObjectIdentifier(connection)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            let type = xpc_get_type(event)
            let said: PluginEvent?
            var gone = false
            if type == XPC_TYPE_DICTIONARY {
                said = (try? Self.value(event)).map { .xpcMessage(service: name, message: $0.json) }
            } else if type == XPC_TYPE_ERROR {
                gone = event !== XPC_ERROR_CONNECTION_INTERRUPTED
                said = .xpcClosed(service: name, reason: gone ? "invalid" : "interrupted")
            } else {
                said = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.open[plugin]?[name].map(ObjectIdentifier.init) == identity else { return }
                    if gone { self.open[plugin]?[name] = nil }
                    if let said { self.onEvent(plugin, said) }
                }
            }
        }
        xpc_connection_activate(connection)
        open[plugin, default: [:]][name] = connection
        return connection
    }

    /// Its capability revoked, or the plugin stopped: the connection goes, and with it any reply still due.
    func close(_ service: String, of plugin: String) {
        guard let connection = open[plugin]?.removeValue(forKey: service) else { return }
        xpc_connection_cancel(connection)
    }

    // MARK: - Values

    nonisolated static func object(_ value: XPCValue) -> xpc_object_t {
        switch value {
        case .null: return xpc_null_create()
        case .bool(let bool): return xpc_bool_create(bool)
        case .int64(let int): return xpc_int64_create(int)
        case .uint64(let uint): return xpc_uint64_create(uint)
        case .double(let double): return xpc_double_create(double)
        case .string(let string): return xpc_string_create(string)
        case .data(let data): return data.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        case .date(let ns): return xpc_date_create(ns)
        case .uuid(let uuid): return withUnsafeBytes(of: uuid.uuid) { xpc_uuid_create($0.bindMemory(to: UInt8.self).baseAddress!) }
        case .array(let items):
            let array = xpc_array_create(nil, 0)
            for item in items { xpc_array_append_value(array, object(item)) }
            return array
        case .dictionary(let entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for (key, item) in entries { xpc_dictionary_set_value(dictionary, key, object(item)) }
            return dictionary
        }
    }

    /// What a service sent, as a plugin may hold it: file descriptors, shared memory and endpoints are refused.
    nonisolated static func value(_ object: xpc_object_t) throws -> XPCValue {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_NULL: return .null
        case XPC_TYPE_BOOL: return .bool(xpc_bool_get_value(object))
        case XPC_TYPE_INT64: return .int64(xpc_int64_get_value(object))
        case XPC_TYPE_UINT64: return .uint64(xpc_uint64_get_value(object))
        case XPC_TYPE_DOUBLE: return .double(xpc_double_get_value(object))
        case XPC_TYPE_STRING: return .string(xpc_string_get_string_ptr(object).map { String(cString: $0) } ?? "")
        case XPC_TYPE_DATA:
            guard let bytes = xpc_data_get_bytes_ptr(object) else { return .data(Data()) }
            return .data(Data(bytes: bytes, count: xpc_data_get_length(object)))
        case XPC_TYPE_DATE: return .date(xpc_date_get_value(object))
        case XPC_TYPE_UUID:
            guard let bytes = xpc_uuid_get_bytes(object) else { return .null }
            return .uuid(UUID(uuid: UnsafeRawPointer(bytes).load(as: uuid_t.self)))
        case XPC_TYPE_ARRAY:
            var items: [XPCValue] = []
            var failure: Error?
            xpc_array_apply(object) { _, item in
                do { items.append(try value(item)); return true } catch { failure = error; return false }
            }
            if let failure { throw failure }
            return .array(items)
        case XPC_TYPE_DICTIONARY:
            var entries: [String: XPCValue] = [:]
            var failure: Error?
            xpc_dictionary_apply(object) { key, item in
                do { entries[String(cString: key)] = try value(item); return true } catch { failure = error; return false }
            }
            if let failure { throw failure }
            return .dictionary(entries)
        default:
            let name = String(cString: xpc_type_get_name(type))
            throw XPCValue.Refusal(message: "a reply holding \(name), which a plugin cannot hold")
        }
    }

    nonisolated static func describe(_ error: xpc_object_t) -> String {
        if error === XPC_ERROR_CONNECTION_INTERRUPTED { return "interrupted" }
        guard let description = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) else { return "invalid" }
        return String(cString: description).lowercased()
    }
}
