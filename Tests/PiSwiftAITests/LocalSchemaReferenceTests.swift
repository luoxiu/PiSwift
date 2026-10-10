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
