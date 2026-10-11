import Foundation
import PiSwiftAI

func hasCodemodeIdentifier(_ exposure: ToolExposure) -> Bool {
    exposure != .hidden && exposure != .modelOnly
}

/// A tool name that a path owns, as the `.reject` collision rule sees it.
struct ToolRegistrationOwner {
    var name: String
    var ownerPath: String
    var exposure: ToolExposure
}

/// The `.reject` rule for a new registration. It is shared by session load and live registration.
/// - Parameter allowsOwnerUpdate: True when a path can register its own tool again, for example
///   to change the tool's exposure. Load does not permit this, because a factory that registers
///   one name two times has a defect.
func toolRegistrationCollision(name: String, ownerPath: String, exposure: ToolExposure,
                               existing: [ToolRegistrationOwner], allowsOwnerUpdate: Bool) -> HookAPIError? {
    if let previous = existing.first(where: { $0.name == name }),
       !allowsOwnerUpdate || previous.ownerPath != ownerPath {
        return .toolNameCollision(name: name, ownerPath: previous.ownerPath, path: ownerPath)
    }
    guard hasCodemodeIdentifier(exposure) else {
        return nil
    }
    let identifier = toCodemodeIdentifier(name)
    for previous in existing where previous.name != name && hasCodemodeIdentifier(previous.exposure) {
        if toCodemodeIdentifier(previous.name) == identifier {
            return .toolIdentifierCollision(identifier: identifier, name: name, ownerName: previous.name,
                                            ownerPath: previous.ownerPath, path: ownerPath)
        }
    }
    return nil
}

/// Shared by extension factories during one session load.
public final class ToolRegistrationRegistry: Sendable {
    /// Who owns a name during load.
    enum OwnerKind: Sendable {
        /// A built-in tool or a custom tool.
        case fixed
        case `extension`
        /// A built-in extension that another extension can replace.
        case replaceableExtension
    }

    public let collisionPolicy: ToolNameCollisionPolicy
    private struct Entry: Sendable {
        var ownerPath: String
        var exposure: ToolExposure
        var kind: OwnerKind
    }
    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var order: [String] = []
    }
    private let state = LockedState(State())

    public init(collisionPolicy: ToolNameCollisionPolicy = .overwrite) {
        self.collisionPolicy = collisionPolicy
    }

    /// Returns nil when the registration can continue.
    ///
    /// An extension and a replaceable built-in extension with the same tool name are not a collision.
    /// The extension owns the name and `omitReplacedExtensions` removes the built-in extension.
    func register(name: String, ownerPath: String, exposure: ToolExposure = .direct,
                  kind: OwnerKind) -> HookAPIError? {
        state.withLock { state in
            var yields = false
            if collisionPolicy == .reject {
                var existing = state.order.compactMap { name in
                    state.entries[name].map { ToolRegistrationOwner(name: name, ownerPath: $0.ownerPath, exposure: $0.exposure) }
                }
                switch (state.entries[name]?.kind, kind) {
                case (.extension?, .replaceableExtension):
                    yields = true
                    existing.removeAll { $0.name == name }
                case (.replaceableExtension?, .extension):
                    existing.removeAll { $0.name == name }
                default:
                    break
                }
                if let error = toolRegistrationCollision(name: name, ownerPath: ownerPath, exposure: exposure,
                                                         existing: existing, allowsOwnerUpdate: false) {
                    return error
                }
            }
            guard !yields else {
                return nil
            }
            if state.entries[name] == nil {
                state.order.append(name)
            }
            state.entries[name] = Entry(ownerPath: ownerPath, exposure: exposure, kind: kind)
            return nil
        }
    }

    func unregister(name: String, ownerPath: String) {
        state.withLock { state in
            if state.entries[name]?.ownerPath == ownerPath {
                state.entries.removeValue(forKey: name)
                state.order.removeAll { $0 == name }
            }
        }
    }
}
