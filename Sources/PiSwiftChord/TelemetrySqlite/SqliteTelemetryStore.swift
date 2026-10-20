// Ports upstream `packages/chord/src/telemetry-sqlite/store.ts` at d9025a5f5: the `TelemetryStore` queries over the
// tables `SqliteTelemetry.swift` writes.

import PiSwiftTelemetry

private func corrupt(_ description: String) -> DecodingError {
    .dataCorrupted(.init(codingPath: [], debugDescription: description))
}

private func number(_ value: SqliteValue?) -> Double? {
    switch value {
    case .integer(let value)?: Double(value)
    case .real(let value)?: value
    default: nil
    }
}

private func text(_ row: SqliteRow, _ column: String) throws -> String {
    guard let value = row[column]?.textValue else { throw corrupt("Expected text in \(column)") }
    return value
}

private func parse(_ row: SqliteRow, _ column: String) throws -> JSONValue {
    try JSONValue(jsonText: text(row, column))
}

/// An attribute value read back from JSON. `null` (a non-finite number upstream wrote) and values outside the
/// attribute types are dropped; an empty array reads as a string array.
private func attributeValue(_ value: JSONValue) -> AttributeValue? {
    switch value {
    case .string(let value): return .string(value)
    case .number(let value): return .number(value)
    case .bool(let value): return .boolean(value)
    case .array(let values):
        let strings = values.compactMap(\.stringValue)
        if strings.count == values.count { return .stringArray(strings) }
        let numbers = values.compactMap(\.numberValue)
        if numbers.count == values.count { return .numberArray(numbers) }
        let booleans = values.compactMap(\.boolValue)
        if booleans.count == values.count { return .booleanArray(booleans) }
        return nil
    case .null, .object: return nil
    }
}

private func attributes(_ value: JSONValue?) throws -> [String: AttributeValue] {
    guard let object = value?.objectValue else { throw corrupt("Expected an attributes object") }
    var attributes: [String: AttributeValue] = [:]
    for (key, value) in object {
        if let value = attributeValue(value) { attributes[key] = value }
    }
    return attributes
}

private func status(_ value: JSONValue) throws -> SpanStatus {
    guard let object = value.objectValue else { throw corrupt("Expected a status object") }
    switch object["status"]?.stringValue {
    case "ok": return .ok
    case "error":
        guard let error = object["error"]?.objectValue else { return .error(nil) }
        return .error(name: error["name"]?.stringValue ?? "", message: error["message"]?.stringValue ?? "")
    default: throw corrupt("Unknown span status")
    }
}

private func storedSpan(_ row: SqliteRow) throws -> StoredSpan {
    guard let startedMs = number(row["started_ms"]), let endedMs = number(row["ended_ms"]),
          let events = try parse(row, "events").arrayValue, let links = try parse(row, "links").arrayValue else {
        throw corrupt("Expected a telemetry span row")
    }
    return StoredSpan(
        id: try text(row, "id"),
        traceId: try text(row, "trace_id"),
        parentId: row["parent_id"]?.textValue,
        name: try text(row, "name"),
        startedMs: startedMs,
        endedMs: endedMs,
        attributes: try attributes(parse(row, "attributes")),
        events: try events.map { event in
            guard let name = event.objectValue?["name"]?.stringValue,
                  let timeMs = event.objectValue?["time_ms"]?.numberValue else { throw corrupt("Expected a span event") }
            return StoredSpan.Event(name: name, timeMs: timeMs, attributes: try attributes(event.objectValue?["attributes"]))
        },
        links: try links.map { link in
            guard let traceId = link.objectValue?["trace_id"]?.stringValue,
                  let spanId = link.objectValue?["span_id"]?.stringValue else { throw corrupt("Expected a span link") }
            let linked = link.objectValue?["attributes"]
            return StoredSpan.Link(traceId: traceId, spanId: spanId, attributes: try linked.map { try attributes($0) })
        },
        status: try status(parse(row, "status")))
}

/// JSON equality must distinguish boolean true from numeric 1. `json_each` also handles arbitrary attribute keys.
private func attributesSql(_ attributes: [String: ScalarAttributeValue]?, _ column: String, _ params: inout [SqliteValue]) -> String {
    let conditions = (attributes ?? [:]).sorted { javaScriptPrecedes($0.key, $1.key) }.map { key, value in
        let type: String
        switch value {
        case .number(let number):
            type = "entry.type IN ('integer', 'real')"
            params += [.text(key), .real(number)]
        case .boolean(let boolean):
            type = "entry.type = '\(boolean ? "true" : "false")'"
            params += [.text(key), .integer(boolean ? 1 : 0)]
        case .string(let string):
            type = "entry.type = 'text'"
            params += [.text(key), .text(string)]
        }
        return "EXISTS (SELECT 1 FROM json_each(\(column)) entry WHERE entry.key = ? AND \(type) AND entry.value = ?)"
    }
    return conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
}

func sqliteTelemetryTrace(_ db: any SqliteExecutor, _ traceId: String) throws -> StoredTrace? {
    let rows = try db.all("SELECT * FROM telemetry_spans WHERE trace_id = ? ORDER BY started_ms, id", [.text(traceId)])
    return rows.isEmpty ? nil : StoredTrace(traceId: traceId, spans: try rows.map(storedSpan))
}

func sqliteTelemetryTraces(_ db: any SqliteExecutor, _ query: TraceQuery) throws -> StoredTracePage {
    let limit = query.limit ?? 20
    var conditions: [String] = []
    var params: [SqliteValue] = []
    if let name = query.name {
        conditions.append(
            "(SELECT name FROM telemetry_spans WHERE trace_id = heads.trace_id ORDER BY started_ms, id LIMIT 1) = ?")
        params.append(.text(name))
    }
    if let startMin = query.startMin {
        conditions.append("started_ms >= ?")
        params.append(.real(startMin))
    }
    if let startMax = query.startMax {
        conditions.append("started_ms <= ?")
        params.append(.real(startMax))
    }
    if query.errors {
        conditions.append(
            "EXISTS (SELECT 1 FROM telemetry_spans WHERE trace_id = heads.trace_id AND json_extract(status, '$.status') = 'error')")
    }
    if let attributes = query.attributes {
        conditions.append(
            "EXISTS (SELECT 1 FROM telemetry_spans candidate WHERE candidate.trace_id = heads.trace_id AND \(attributesSql(attributes, "candidate.attributes", &params)))")
    }
    if let cursor = query.cursor {
        guard let parts = try JSONValue(jsonText: cursor).arrayValue, parts.count == 2,
              let startedMs = parts[0].numberValue, let traceId = parts[1].stringValue else {
            throw corrupt("Invalid trace cursor \(cursor)")
        }
        conditions.append("(started_ms < ? OR (started_ms = ? AND trace_id > ?))")
        params += [.real(startedMs), .real(startedMs), .text(traceId)]
    }
    return try db.transaction { tx in
        var heads = try tx.all(
            "WITH heads AS (\n\t\t\tSELECT trace_id, min(started_ms) started_ms FROM telemetry_spans GROUP BY trace_id\n\t\t) SELECT * FROM heads WHERE \(conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")) ORDER BY started_ms DESC, trace_id LIMIT ?",
            params + [.integer(Int64(limit) + 1)])
        let more = heads.count > limit
        if more { heads.removeLast() }
        if heads.isEmpty { return StoredTracePage(traces: []) }
        let ids = try heads.map { try text($0, "trace_id") }
        let rows = try tx.all(
            "SELECT * FROM telemetry_spans WHERE trace_id IN (SELECT value FROM json_each(?)) ORDER BY started_ms, id",
            [.text(jsonText(.array(ids.map(JSONValue.string))))])
        var grouped: [String: [StoredSpan]] = [:]
        for row in rows {
            let span = try storedSpan(row)
            grouped[span.traceId, default: []].append(span)
        }
        let traces = ids.map { StoredTrace(traceId: $0, spans: grouped[$0] ?? []) }
        guard more, let last = heads.last, let startedMs = number(last["started_ms"]) else {
            return StoredTracePage(traces: traces)
        }
        return StoredTracePage(traces: traces, cursor: jsonText(.array([.number(startedMs), .string(try text(last, "trace_id"))])))
    }
}

func sqliteTelemetryMetrics(_ db: any SqliteExecutor, _ query: MetricQuery) throws -> [StoredMetric] {
    var params: [SqliteValue] = [.text(query.name)]
    var conditions = ["name = ?"]
    if let startMin = query.startMin {
        conditions.append("interval_ms >= ?")
        params.append(.real(startMin))
    }
    if let startMax = query.startMax {
        conditions.append("interval_ms <= ?")
        params.append(.real(startMax))
    }
    conditions.append(attributesSql(query.attributes, "attributes", &params))
    let rows = try db.all(
        "SELECT * FROM telemetry_metrics WHERE \(conditions.joined(separator: " AND ")) ORDER BY interval_ms, series_key", params)
    return try rows.map { row in
        guard let intervalMs = number(row["interval_ms"]), let kind = TelemetryMetricKind(rawValue: try text(row, "kind")),
              let count = number(row["count"]), let sum = number(row["sum"]), let min = number(row["min"]),
              let max = number(row["max"]) else { throw corrupt("Expected a telemetry metric row") }
        return StoredMetric(
            intervalMs: intervalMs, name: try text(row, "name"), kind: kind, unit: row["unit"]?.textValue,
            attributes: try attributes(parse(row, "attributes")), count: Int(count), sum: sum, min: min, max: max)
    }
}
