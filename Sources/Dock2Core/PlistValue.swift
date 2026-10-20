import Foundation

/// A property-list value as a Swift value, so a preference can be compared, tested and written back
/// with the type it was read with — a Dock that read `autohide` as a boolean must get a boolean back.
public indirect enum PlistValue: Sendable, Equatable {
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case string(String)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    /// From what CFPreferences or PropertyListSerialization hands back. `NSNumber` bridges booleans,
    /// integers and reals alike, so its CF type decides.
    public init?(_ object: Any) {
        switch object {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .real(number.doubleValue)
            } else {
                self = .integer(number.intValue)
            }
        case let string as String: self = .string(string)
        case let date as Date: self = .date(date)
        case let data as Data: self = .data(data)
        case let array as [Any]:
            let values = array.compactMap(PlistValue.init)
            guard values.count == array.count else { return nil }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: PlistValue] = [:]
            for (key, value) in dictionary {
                guard let converted = PlistValue(value) else { return nil }
                values[key] = converted
            }
            self = .dictionary(values)
        default:
            return nil
        }
    }

    /// The Foundation object for this value, for CFPreferences or PropertyListSerialization.
    public var object: Any {
        switch self {
        case .bool(let value): return value as NSNumber
        case .integer(let value): return value as NSNumber
        case .real(let value): return value as NSNumber
        case .string(let value): return value
        case .date(let value): return value
        case .data(let value): return value
        case .array(let values): return values.map(\.object)
        case .dictionary(let values): return values.mapValues(\.object)
        }
    }
}
