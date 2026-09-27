import Foundation

/// A loosely typed JSON value, for the free-form `metrics` dictionaries the pipeline writes.
enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): n
        case .bool(let b): b ? 1 : 0
        case .string(let s): Double(s)
        default: nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let n): n != 0
        default: nil
        }
    }
    var string: String? { if case .string(let s) = self { s } else { nil } }

    var description: String {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): b ? "yes" : "no"
        case .null: "–"
        case .array(let a): a.map(\.description).joined(separator: ", ")
        case .object(let o): o.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func double(_ key: String) -> Double? { self[key]?.double }
    func int(_ key: String) -> Int? { self[key]?.int }
    func bool(_ key: String) -> Bool? { self[key]?.bool }
    func string(_ key: String) -> String? { self[key]?.string }
}
