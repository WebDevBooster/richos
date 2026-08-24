import Foundation

/// A tiny insertion-ordered JSON value model.
///
/// The frozen contract (P1 `tools/richos-service/README.md`) is consumed by `JSON.parse`, so field
/// *order* is not functionally load-bearing — but explicit `null` vs *omitted* IS (the extension's
/// `session.json` carries `endedAt: null`, `pipeline.model: null`, etc., and the pipeline's
/// `upgradeRecord` only fills a block when it is ABSENT, so we must emit the full v2 shape with
/// real nulls, not omit them). `Codable`'s default optional handling omits nils, which would be
/// wrong here — so this model gives byte-for-shape control and preserves a human-readable order.
public indirect enum JSON {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSON])
    /// Ordered object: array of (key, value) pairs, serialized in insertion order.
    case object([(String, JSON)])

    /// Serialize with the same 2-space indentation the pipeline uses when it rewrites session.json.
    public func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let pad1 = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let s): return JSON.encodeString(s)
        case .int(let n): return String(n)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { pad1 + $0.serialized(indent: indent + 1) }.joined(separator: ",\n")
            return "[\n\(body)\n\(pad)]"
        case .object(let pairs):
            if pairs.isEmpty { return "{}" }
            let body = pairs.map { (k, v) in
                pad1 + JSON.encodeString(k) + ": " + v.serialized(indent: indent + 1)
            }.joined(separator: ",\n")
            return "{\n\(body)\n\(pad)}"
        }
    }

    public func data() -> Data {
        Data((serialized() + "\n").utf8)
    }

    /// Compact single-line serialization (for ndjson rows).
    public func compact() -> String {
        switch self {
        case .string(let s): return JSON.encodeString(s)
        case .int(let n): return String(n)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return "[" + items.map { $0.compact() }.joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { JSON.encodeString($0.0) + ":" + $0.1.compact() }.joined(separator: ",") + "}"
        }
    }

    static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
