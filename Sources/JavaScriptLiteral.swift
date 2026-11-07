import Foundation

/// Encodes Swift values as JavaScript source literals for generated user
/// scripts. JSON is a strict subset of JavaScript expression syntax, so the
/// encoded output is always safe to interpolate into script source.
enum JavaScriptLiteral {
    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]) else { return "\"\"" }
        // Encode inside an array so top-level fragments work on every SDK,
        // then strip the surrounding brackets.
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    static func array(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
