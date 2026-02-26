import Foundation

// MARK: - JSON-RPC Request

struct RPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: RPCValue]
}

// MARK: - JSON-RPC Response

struct RPCResponse: Decodable {
    let jsonrpc: String
    let id: Int?
    let result: RPCValue?
    let error: RPCError?
    let method: String?
    let params: [String: RPCValue]?

    var isNotification: Bool { id == nil && method != nil }

    /// Get result as a dictionary (most common case)
    var resultDict: [String: RPCValue] {
        result?.objectValue ?? [:]
    }

    /// Get result as an array (for list methods)
    var resultArray: [RPCValue] {
        result?.arrayValue ?? []
    }
}

struct RPCError: Decodable {
    let code: Int
    let message: String
}

// MARK: - RPCValue — type-safe JSON value

enum RPCValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([RPCValue])
    case object([String: RPCValue])

    // Convenience accessors
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let v) = self { return v }
        if case .int(let v) = self { return Double(v) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var arrayValue: [RPCValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: RPCValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([RPCValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: RPCValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
