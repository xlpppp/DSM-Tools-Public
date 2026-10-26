import Foundation

/// DSM returns the same field as a number on one version and a string on another.
/// These wrappers accept either.
public struct FlexInt: Decodable, Hashable, Sendable {
    public let value: Int

    public init(_ value: Int) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = Int(d)
        } else if let s = try? c.decode(String.self), let i = Int(s.trimmingCharacters(in: .whitespaces)) {
            value = i
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            value = Int(d)
        } else {
            throw DecodingError.typeMismatch(Int.self, .init(codingPath: decoder.codingPath, debugDescription: "not an integer"))
        }
    }
}

public struct FlexDouble: Decodable, Hashable, Sendable {
    public let value: Double

    public init(_ value: Double) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self), let d = Double(s.trimmingCharacters(in: .whitespaces)) {
            value = d
        } else {
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "not a number"))
        }
    }
}

public struct FlexString: Decodable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = String(i)
        } else if let d = try? c.decode(Double.self) {
            value = String(d)
        } else if let b = try? c.decode(Bool.self) {
            value = String(b)
        } else {
            throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "not a scalar"))
        }
    }
}

/// Placeholder for calls whose `data` carries nothing we use.
public struct EmptyData: Decodable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {}
}

/// Arbitrary JSON, for payloads that must round-trip untouched (e.g. container profiles).
public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Keep integers integral so DSM doesn't see "1.0".
            if n.rounded() == n, abs(n) < 9.0e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public init?<T: Encodable>(encoding value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = v
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .number(let n): return Int64(n)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }
}
