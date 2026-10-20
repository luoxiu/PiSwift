// Ports upstream `packages/telemetry/src/render.ts` at d9025a5f5, the `/render` subpath. Swift has no entry graph to
// keep it out of, so it is part of this module.

/// Renders stored spans as a chronological forest, treating absent parents as roots.
///
/// Spans with the same ID are rendered once, with the last one's data at the first one's place. Roots and siblings are
/// ordered by start time, then by input order. Each line holds the name, the attributes, the duration, and an error
/// status; events and links follow on their own lines. Links are printed, never followed. Attributes are printed in
/// key order, where upstream keeps the object's insertion order, which a Swift dictionary does not have.
public func renderTrace(_ spans: [StoredSpan]) -> String {
    var positions: [String: Int] = [:]
    var unique: [StoredSpan] = []
    for span in spans {
        if let position = positions[span.id] {
            unique[position] = span
        } else {
            positions[span.id] = unique.count
            unique.append(span)
        }
    }
    let ordered = unique.enumerated()
        .sorted { left, right in
            left.element.startedMs < right.element.startedMs
                || (left.element.startedMs == right.element.startedMs && left.offset < right.offset)
        }
        .map(\.element)

    var roots: [StoredSpan] = []
    var children: [String: [StoredSpan]] = [:]
    for span in ordered {
        if let parentId = span.parentId, positions[parentId] != nil {
            children[parentId, default: []].append(span)
        } else {
            roots.append(span)
        }
    }

    var lines: [String] = []
    var pending = roots.reversed().map { (span: $0, depth: 0) }
    while let (span, depth) = pending.popLast() {
        let indent = String(repeating: "  ", count: depth)
        var error = ""
        if case let .error(details) = span.status {
            error = " error"
            if let details { error += " \(details.name): \(details.message)" }
        }
        lines.append("\(indent)\(span.name)\(formatAttributes(span.attributes)) (\(javaScriptNumber(span.endedMs - span.startedMs))ms)\(error)")
        for event in span.events {
            lines.append("\(indent)  · \(event.name)\(formatAttributes(event.attributes)) (+\(javaScriptNumber(event.timeMs))ms)")
        }
        for link in span.links {
            lines.append("\(indent)  → link trace \(link.traceId) span \(link.spanId)\(formatAttributes(link.attributes ?? [:]))")
        }
        for child in (children[span.id] ?? []).reversed() {
            pending.append((child, depth + 1))
        }
    }
    return lines.joined(separator: "\n")
}

private func formatAttributes(_ attributes: [String: AttributeValue]) -> String {
    attributes.keys.sorted(by: javaScriptPrecedes).map { key in " \(key)=\(javaScriptJSON(attributes[key]!))" }.joined()
}

/// `JSON.stringify` of an attribute value: JavaScript number text, and `null` for a non-finite number.
package func javaScriptJSON(_ value: AttributeValue) -> String {
    func number(_ value: Double) -> String { value.isFinite ? javaScriptNumber(value) : "null" }
    switch value {
    case .string(let value): return javaScriptQuoted(value)
    case .number(let value): return number(value)
    case .boolean(let value): return value ? "true" : "false"
    case .stringArray(let values): return "[" + values.map(javaScriptQuoted).joined(separator: ",") + "]"
    case .numberArray(let values): return "[" + values.map(number).joined(separator: ",") + "]"
    case .booleanArray(let values): return "[" + values.map { $0 ? "true" : "false" }.joined(separator: ",") + "]"
    }
}

/// JavaScript's `String(number)`: the shortest round-trip digits, in fixed notation from 1e-6 up to 1e21.
package func javaScriptNumber(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == .infinity { return "Infinity" }
    if value == -.infinity { return "-Infinity" }
    if value == 0 { return "0" }
    let sign = value < 0 ? "-" : ""
    let parts = String(abs(value)).lowercased().split(separator: "e")
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let exponent = parts.count == 2 ? Int(parts[1])! : 0
    var digits = Array(mantissa.joined())
    var n = mantissa[0].count + exponent
    while digits.first == "0" { digits.removeFirst(); n -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let k = digits.count
    let text = String(digits)
    if k <= n && n <= 21 { return sign + text + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 { return sign + String(digits.prefix(n)) + "." + String(digits.dropFirst(n)) }
    if -6 < n && n <= 0 { return sign + "0." + String(repeating: "0", count: -n) + text }
    let tail = k > 1 ? "." + String(digits.dropFirst()) : ""
    return sign + String(digits[0]) + tail + "e" + (n - 1 >= 0 ? "+" : "-") + String(abs(n - 1))
}

/// `JSON.stringify` of a string.
package func javaScriptQuoted(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 34: result += "\\\""
        case 92: result += "\\\\"
        case 8: result += "\\b"
        case 9: result += "\\t"
        case 10: result += "\\n"
        case 12: result += "\\f"
        case 13: result += "\\r"
        case 0...31:
            let hex = String(scalar.value, radix: 16)
            result += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

/// JavaScript's `<` on strings: UTF-16 code unit order.
package func javaScriptPrecedes(_ left: String, _ right: String) -> Bool {
    left.utf16.lexicographicallyPrecedes(right.utf16)
}
