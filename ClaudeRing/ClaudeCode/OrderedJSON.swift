import Foundation

/// A JSON value that keeps the key order of objects and the exact text of
/// numbers, so a file can be edited without reformatting everything else.
/// Serializes like `JSON.stringify(value, null, 2)`, which is how Claude Code
/// writes its settings.
indirect enum OrderedJSON: Equatable, Sendable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number exactly as written in the source.
    case number(String)
    case bool(Bool)
    case null

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(a), .array(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    // MARK: Access

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let elements) = self { elements } else { nil }
    }

    var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    /// Replaces the value for `key`, keeping its position, or appends it.
    /// Passing nil removes the key.
    mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value {
                members[index].value = value
            } else {
                members.remove(at: index)
            }
        } else if let value {
            members.append((key, value))
        }
        self = .object(members)
    }

    // MARK: Parsing

    struct ParseError: Error, Equatable {
        let offset: Int
    }

    init(parsing data: Data) throws {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        self = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError(offset: parser.index) }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func parseValue() throws -> OrderedJSON {
            guard index < bytes.count else { throw ParseError(offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject() throws -> OrderedJSON {
            index += 1
            var members: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if try consume("}") { return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError(offset: index) }
                let key = try parseString()
                skipWhitespace()
                guard try consume(":") else { throw ParseError(offset: index) }
                skipWhitespace()
                members.append((key, try parseValue()))
                skipWhitespace()
                if try consume(",") { continue }
                if try consume("}") { return .object(members) }
                throw ParseError(offset: index)
            }
        }

        mutating func parseArray() throws -> OrderedJSON {
            index += 1
            var elements: [OrderedJSON] = []
            skipWhitespace()
            if try consume("]") { return .array(elements) }
            while true {
                skipWhitespace()
                elements.append(try parseValue())
                skipWhitespace()
                if try consume(",") { continue }
                if try consume("]") { return .array(elements) }
                throw ParseError(offset: index)
            }
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []

            func flushRaw() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw ParseError(offset: index) }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll()
            }

            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    try flushRaw()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flushRaw()
                    guard index < bytes.count else { throw ParseError(offset: index) }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code), try consume("\\"), try consume("u") {
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw ParseError(offset: index) }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw ParseError(offset: index) }
                        scalars.append(scalar)
                    default:
                        throw ParseError(offset: index)
                    }
                default:
                    raw.append(byte)
                }
            }
            throw ParseError(offset: index)
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
                  let value = UInt32(text, radix: 16)
            else { throw ParseError(offset: index) }
            index += 4
            return value
        }

        mutating func parseNumber() throws -> OrderedJSON {
            let start = index
            let allowed = Set("+-0123456789.eE".utf8)
            while index < bytes.count, allowed.contains(bytes[index]) {
                index += 1
            }
            guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii),
                  Double(text) != nil
            else { throw ParseError(offset: start) }
            return .number(text)
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw ParseError(offset: index) }
                index += 1
            }
        }

        mutating func consume(_ character: Character) throws -> Bool {
            guard index < bytes.count, let ascii = character.asciiValue, bytes[index] == ascii else { return false }
            index += 1
            return true
        }
    }

    // MARK: Serializing

    func serialized(indent: Int = 2) -> String {
        var output = ""
        write(to: &output, level: 0, indent: indent)
        return output
    }

    private func write(to output: inout String, level: Int, indent: Int) {
        let padding = String(repeating: " ", count: indent * (level + 1))
        let closingPadding = String(repeating: " ", count: indent * level)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += padding + Self.quoted(member.key) + ": "
                member.value.write(to: &output, level: level + 1, indent: indent)
                output += offset < members.count - 1 ? ",\n" : "\n"
            }
            output += closingPadding + "}"
        case .array(let elements):
            guard !elements.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (offset, element) in elements.enumerated() {
                output += padding
                element.write(to: &output, level: level + 1, indent: indent)
                output += offset < elements.count - 1 ? ",\n" : "\n"
            }
            output += closingPadding + "]"
        case .string(let string):
            output += Self.quoted(string)
        case .number(let text):
            output += text
        case .bool(let value):
            output += value ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    /// Escapes like `JSON.stringify`: quotes, backslashes and control
    /// characters; everything else, including non-ASCII, stays as is.
    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let control where control.value < 0x20:
                result += String(format: "\\u%04x", control.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
