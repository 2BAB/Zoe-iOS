import Foundation

/// Business data stays in Swift. Only explicit inputs reach a model or a script.
indirect enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var text: String { if case .string(let v) = self { v } else { json } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
    var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? "null"
    }
    var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let v): v
        case .number(let v): v
        case .string(let v): v
        case .array(let v): v.map(\.foundation)
        case .object(let v): v.mapValues(\.foundation)
        }
    }

    func field(_ path: ArraySlice<String>) throws -> JSONValue {
        guard let head = path.first else { return self }
        let next: JSONValue?
        if case .object(let obj) = self { next = obj[head] }
        else if case .array(let list) = self, let index = Int(head), list.indices.contains(index) { next = list[index] }
        else { next = nil }
        guard let next else { throw ZoeError("Missing variable field: \(head)") }
        return try next.field(path.dropFirst())
    }
}

struct ValueRef: Codable, Hashable, Sendable {
    var path: String?
    var literal: JSONValue?
    static func variable(_ path: String) -> Self { .init(path: path) }
    static func value(_ value: JSONValue) -> Self { .init(literal: value) }

    func validate() throws {
        guard (path == nil) != (literal == nil), path?.isEmpty != true else {
            throw ZoeError("A reference needs exactly one nonempty path or literal.")
        }
    }
    func resolve(in variables: [String: JSONValue]) throws -> JSONValue {
        try validate()
        if let literal { return literal }
        return try JSONValue.object(variables).field(path!.split(separator: ".").map(String.init)[...])
    }
}
