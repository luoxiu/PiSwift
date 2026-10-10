import Foundation
import PiSwiftAI

func hasCodemodeIdentifier(_ exposure: ToolExposure) -> Bool {
    exposure != .hidden && exposure != .modelOnly
}

/// Shared by extension factories during one session load.
public final class ToolRegistrationRegistry: Sendable {
    public let collisionPolicy: ToolNameCollisionPolicy
    private struct Entry: Sendable {
        var ownerPath: String
        var exposure: ToolExposure
    }
    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var order: [String] = []
    }
    private let state = LockedState(State())

    public init(collisionPolicy: ToolNameCollisionPolicy = .overwrite) {
        self.collisionPolicy = collisionPolicy
    }

    func register(name: String, ownerPath: String, exposure: ToolExposure = .direct) -> HookAPIError? {
        state.withLock { state in
            if collisionPolicy == .reject {
                if let previous = state.entries[name] {
                    return .toolNameCollision(name: name, ownerPath: previous.ownerPath, path: ownerPath)
                }
                if hasCodemodeIdentifier(exposure) {
                    let identifier = toCodemodeIdentifier(name)
                    for previousName in state.order {
                        guard let previous = state.entries[previousName], hasCodemodeIdentifier(previous.exposure) else {
                            continue
                        }
                        if toCodemodeIdentifier(previousName) == identifier {
                            return .toolIdentifierCollision(identifier: identifier, name: name,
                                ownerName: previousName, ownerPath: previous.ownerPath, path: ownerPath)
                        }
                    }
                }
            }
            if state.entries[name] == nil {
                state.order.append(name)
            }
            state.entries[name] = Entry(ownerPath: ownerPath, exposure: exposure)
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
