import Foundation

struct WorkspaceSessionWorktreeOwnershipToken: Hashable {
    let ownerID: UUID
    let generation: UInt64
}

struct WorkspaceSessionWorktreeOwnedRoot: Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let standardizedPhysicalPath: String
}

struct WorkspaceSessionWorktreeOwnershipPreparation {
    let token: WorkspaceSessionWorktreeOwnershipToken
    let bindingFingerprint: String
    let roots: [WorkspaceSessionWorktreeOwnedRoot]
    let reusesInstalledOwnership: Bool
}

enum WorkspaceSessionWorktreeOwnershipError: LocalizedError, Equatable {
    case staleUpdate
    case unavailableRoot(String)
    case invalidRootKind(String)

    var errorDescription: String? {
        switch self {
        case .staleUpdate:
            "The Agent session worktree ownership changed while it was being prepared."
        case let .unavailableRoot(path):
            "The Agent session worktree root is unavailable: \(path)"
        case let .invalidRootKind(path):
            "The requested Agent worktree path is already loaded with incompatible ownership: \(path)"
        }
    }
}
