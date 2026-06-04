import CoreServices
import Foundation
#if DEBUG || EDIT_FLOW_PERF
    import os
#endif

enum FileSystemPublishPerf {
    #if DEBUG || EDIT_FLOW_PERF
        typealias State = OSSignpostIntervalState
        static let signposter = OSSignposter(subsystem: "com.repoprompt.workspace", category: "fs-publish")
        static var isEnabled: Bool {
            UserDefaults.standard.bool(forKey: "enableRepoFileReplaySignposts")
        }

        static func begin(_ name: StaticString) -> State? {
            guard isEnabled else { return nil }
            return signposter.beginInterval(name)
        }

        static func end(_ name: StaticString, _ state: State?) {
            guard isEnabled, let state else { return }
            signposter.endInterval(name, state)
        }
    #else
        struct State {}
        static var isEnabled: Bool {
            false
        }

        static func begin(_ name: StaticString) -> State? {
            nil
        }

        static func end(_ name: StaticString, _ state: State?) {}
    #endif
}

public enum FileSystemDelta: Sendable, Equatable {
    case fileAdded(String)
    case fileRemoved(String)
    case folderAdded(String)
    case folderRemoved(String)
    case fileModified(String, Date?) // observed disk mtime when available
    case folderModified(String, Date? = nil) // observed disk mtime when available
}

enum FileSystemDeltaPublicationSource: String {
    case watcher
    case syntheticMutation
    case watcherBarrierNoop
    case overflowRootRescan
}

struct FileSystemDeltaPublication {
    let servicePublicationSequence: UInt64
    let source: FileSystemDeltaPublicationSource
    let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?
    let deltas: [FileSystemDelta]
}

typealias PendingFSEvent = (path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)

struct PendingFSEventBatch {
    var events: [PendingFSEvent] = []
    var watcherAcceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?
    var publicationSource: FileSystemDeltaPublicationSource = .watcher
    var watcherIngressGeneration: UInt64?

    var isEmpty: Bool {
        events.isEmpty
    }
}

public enum CatalogRegularFileIneligibilityReason: Sendable, Equatable, CustomStringConvertible {
    case invalidRelativePath
    case outsideRoot
    case missingOrDirectory
    case symbolicLink
    case nonRegularFile
    case symlinkComponent
    case outsideCanonicalRoot
    case ignored

    public var description: String {
        switch self {
        case .invalidRelativePath:
            "invalid relative path"
        case .outsideRoot:
            "path is outside the workspace root"
        case .missingOrDirectory:
            "path is missing or is a directory"
        case .symbolicLink:
            "path is a symbolic link"
        case .nonRegularFile:
            "path is not a regular file"
        case .symlinkComponent:
            "path contains a symbolic-link component"
        case .outsideCanonicalRoot:
            "canonical path is outside the workspace root"
        case .ignored:
            "path is ignored by workspace policy"
        }
    }
}

public enum CatalogRegularFileEligibility: Sendable, Equatable {
    case eligible
    case ineligible(CatalogRegularFileIneligibilityReason)

    public var isEligible: Bool {
        if case .eligible = self { return true }
        return false
    }
}

struct FSItemDTO {
    let relativePath: String
    let isDirectory: Bool
    let hierarchy: Int
}

struct FSPreparedChunk {
    let folders: [FSItemDTO]
    let files: [FSItemDTO]
}

#if DEBUG
    struct PublishedDeltaCoalescingDiagnostics: Equatable {
        let rawDeltaCount: Int
        let publishedDeltaCount: Int
    }
#endif

enum LoadContentsEvent {
    case totalFileCount(Int) // emitted at least once, first emission precedes item payloads
    case items([(any FileSystemItem, [String])]) // legacy compatibility
    case preparedItems(FSPreparedChunk) // preferred streaming payload
}

enum ContentReadWorkloadClass: String {
    case interactiveRead
    case contentSearch
    case codemap
    case encodingDetection
    case unspecified
}

// MARK: - Encoding support -----------------------------------------------------

/// Bundles the decoded text with the encoding that produced it.
struct DetectedText {
    let string: String
    let encoding: String.Encoding
}

enum FileSystemError: Error {
    case fileAlreadyExists
    case fileNotFound
    case failedToCreateFile(Error)
    case failedToEditFile(Error)
    case failedToDeleteFile(Error)
    case failedToReadFile
    case failedToEnumerateDirectory
    case fileTooLarge
    case isDirectory
    case failedToCreateDirectory(Error)
    case invalidRelativePath
}

extension FileSystemError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRelativePath:
            "Unsafe workspace mutation path: target escapes the loaded root, contains traversal, or uses a symbolic-link component."
        default:
            nil
        }
    }
}
