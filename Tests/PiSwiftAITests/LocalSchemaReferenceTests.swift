import Foundation
import Testing
@testable import PiSwiftAI

private func recursiveNodeSchema() -> [String: Any] {
    [
        "$ref": "#/$defs/Node",
        "$defs": [
            "Node": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "children": ["type": "array", "items": ["$ref": "#/$defs/Node"]]
                ],
                "required": ["name"],
                "additionalProperties": false
            ]
        ]
    ]
}

@Test func localSchemaReferencesValidateRecursiveChildren() {
    let valid: [String: Any] = ["name": "root", "children": [["name": "child", "children": [["name": "leaf"]]]]]
    let invalid: [String: Any] = ["name": "root", "children": [["name": "child", "children": [["name": "leaf", "typo": true]]]]]
    #expect(JSONSchemaValidator.shared.validate(valid, against: recursiveNodeSchema(), coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(invalid, against: recursiveNodeSchema(), coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.path == "children[0].children[0].typo")
    #expect(result.errors.first?.message == "additional property not allowed")
}

@Test func localSchemaReferencesKeepRootAcrossCombinatorsAndMaps() {
    let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": ["anyOf": [["$ref": "#/$defs/Count"], ["type": "null"]]],
        "$defs": ["Count": ["type": "integer", "minimum": 2]]
    ]
    #expect(JSONSchemaValidator.shared.validate(["a": 3, "b": NSNull()] as [String: Any], against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate(["a": 1], against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(["a": "3"], against: schema)
    #expect(result.isValid)
    #expect((result.coercedValue as? [String: Any])?["a"] as? Int == 3)
}

@Test func localSchemaReferencesDecodeJSONPointerEscapes() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/item~1name~0value",
        "$defs": ["item/name~value": ["type": "string", "minLength": 2]]
    ]
    #expect(JSONSchemaValidator.shared.validate("ok", against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate("x", against: schema, coerceTypes: false).isValid)
}

@Test(arguments: ["#/$defs/missing", "https://example.com/schema", "#/$defs/invalid~2escape"])
func localSchemaReferencesRejectUnresolvedReferences(reference: String) {
    let result = JSONSchemaValidator.shared.validate("value", against: ["$ref": reference])
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "unresolved local schema reference")
}

@Test func localSchemaReferencesRejectCyclesWithoutValueProgress() {
    let schema: [String: Any] = ["$ref": "#/$defs/A", "$defs": ["A": ["$ref": "#/$defs/B"], "B": ["$ref": "#/$defs/A"]]]
    let result = JSONSchemaValidator.shared.validate("value", against: schema)
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "cyclic schema reference without value progress")
}

@Test func localSchemaReferencesApplySiblingAssertions() {
    let schema: [String: Any] = ["$ref": "#/$defs/Text", "maxLength": 3, "type": "string", "$defs": ["Text": ["type": "string", "minLength": 2]]]
    #expect(JSONSchemaValidator.shared.validate("ok", against: schema, coerceTypes: false).isValid)
    #expect(!JSONSchemaValidator.shared.validate("long", against: schema, coerceTypes: false).isValid)
}

@Test func localSchemaReferencesKeepProgressSeparateFromErrorPaths() {
    let schema: [String: Any] = [
        "$ref": "#/$defs/Node",
        "$defs": ["Node": [
            "type": "object",
            "properties": ["root": ["$ref": "#/$defs/Node"]],
            "additionalProperties": false
        ]]
    ]
    let valid: [String: Any] = ["root": ["root": [:]]]
    #expect(JSONSchemaValidator.shared.validate(valid, against: schema, coerceTypes: false).isValid)
    let invalid: [String: Any] = ["root": ["root": ["typo": true]]]
    let result = JSONSchemaValidator.shared.validate(invalid, against: schema, coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.message == "additional property not allowed")
}

@Test func localSchemaReferencesResolveArrayIndexes() {
    // zod-to-json-schema emits references into combinator arrays.
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "filter": ["anyOf": [["type": "string", "minLength": 2], ["type": "integer"]]],
            "again": ["$ref": "#/properties/filter/anyOf/0"],
            "pair": ["type": "array", "prefixItems": [["type": "boolean"]], "items": ["$ref": "#/properties/pair/prefixItems/0"]]
        ]
    ]
    #expect(JSONSchemaValidator.shared.validate(["again": "ok", "pair": [true, false]] as [String: Any],
                                                against: schema, coerceTypes: false).isValid)
    let result = JSONSchemaValidator.shared.validate(["again": "x"], against: schema, coerceTypes: false)
    #expect(!result.isValid)
    #expect(result.errors.first?.path == "again")
}

@Test(arguments: ["#/anyOf/2", "#/anyOf/01", "#/anyOf/-1", "#/anyOf/x"])
func localSchemaReferencesRejectInvalidArrayIndexes(reference: String) {
    let schema: [String: Any] = ["anyOf": [["type": "string"], ["type": "integer"]], "$ref": reference]
    let result = JSONSchemaValidator.shared.validate("value", against: schema)
    #expect(result.errors.first?.message == "unresolved local schema reference")
}

@Test func optionalNullsAreRemovedInsideReferencedObjects() throws {
    let options: [String: Any] = ["type": "object", "properties": ["limit": ["type": "integer"]]]
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "opts": ["$ref": "#/$defs/Opts"],
            "maybe": ["anyOf": [["$ref": "#/$defs/Opts"], ["type": "null"]]],
            "list": ["type": "array", "items": ["$ref": "#/$defs/Opts"]]
        ],
        "$defs": ["Opts": options]
    ]
    let tool = AITool(name: "pydantic", description: "Pydantic", parameters: schema.mapValues(AnyCodable.init))
    let arguments: [String: AnyCodable] = [
        "opts": AnyCodable(["limit": NSNull()]),
        "maybe": AnyCodable(["limit": NSNull()]),
        "list": AnyCodable([["limit": NSNull()]])
    ]
    let result = try validateToolArguments(tool: tool, toolCall: ToolCall(id: "call", name: "pydantic", arguments: arguments))
    #expect((result["opts"]?.value as? [String: Any])?.isEmpty == true)
    #expect((result["maybe"]?.value as? [String: Any])?.isEmpty == true)
    #expect((result["list"]?.value as? [[String: Any]])?.first?.isEmpty == true)
}

@Test func optionalNullsAreKeptForNullableReferenceTargets() throws {
    let schema: [String: Any] = [
        "type": "object",
        "properties": ["opts": ["$ref": "#/$defs/Opts"]],
        "$defs": ["Opts": ["type": "object", "properties": ["limit": ["anyOf": [["$ref": "#/$defs/Count"], ["type": "null"]]]]],
                  "Count": ["type": "integer"]]
    ]
    let normalized = normalizeOptionalNulls(["opts": ["limit": NSNull()]], schema: schema) as? [String: Any]
    #expect((normalized?["opts"] as? [String: Any])?["limit"] is NSNull)
}
