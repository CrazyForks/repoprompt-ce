import Foundation
@testable import RepoPromptCore

private final class TestFileSystemWatcher: FileSystemWatching, @unchecked Sendable {
    private(set) var isWatching = false

    func start(eventHandler _: @escaping @Sendable (FileSystemWatchEventPayload) -> Void) -> Bool {
        isWatching = true
        return true
    }

    func stop() {
        isWatching = false
    }
}

private struct TestFileSystemWatcherFactory: FileSystemWatcherCreating {
    func makeWatcher(path _: String) -> any FileSystemWatching {
        TestFileSystemWatcher()
    }
}

private struct TestWorkspaceDirectoryListingBackend: WorkspaceDirectoryListingBackend {
    func listDirectoryWithIgnoreDetection(at path: String) throws -> WorkspaceDirectoryScanResult {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var hasGitignore = false
        var hasRepoIgnore = false
        var hasCursorignore = false
        var entries: [WorkspaceDirectoryEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            hasGitignore = hasGitignore || name == ".gitignore"
            hasRepoIgnore = hasRepoIgnore || name == ".repoignore"
            hasCursorignore = hasCursorignore || name == ".cursorignore"
            entries.append(WorkspaceDirectoryEntry(
                name: name,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true
            ))
        }
        entries.sort { $0.name < $1.name }
        return WorkspaceDirectoryScanResult(
            entries: entries,
            hasGitignore: hasGitignore,
            hasRepoIgnore: hasRepoIgnore,
            hasCursorignore: hasCursorignore
        )
    }

    func directoryIdentity(followingSymlinksAt path: String) -> WorkspaceDirectoryIdentity? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: canonical) else { return nil }
        return WorkspaceDirectoryIdentity(device: 0, inode: canonical.testFNV1a64)
    }

    func canonicalPath(for path: String) -> String? {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return FileManager.default.fileExists(atPath: canonical) ? canonical : nil
    }
}

private extension String {
    var testFNV1a64: UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

func makeTestWorkspaceRuntimeDependencies(
    maxPendingWatcherEntries: Int = 50_000,
    maxParallelScans: Int? = nil,
    maxFoldersPerBatch: Int = 256,
    diagnostics: any WorkspaceRuntimeDiagnosticsSink = NoopWorkspaceRuntimeDiagnosticsSink()
) -> WorkspaceRuntimeDependencies {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RepoPromptCoreTests-Runtime", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return WorkspaceRuntimeDependencies(
        watcherFactory: TestFileSystemWatcherFactory(),
        directoryListingBackend: TestWorkspaceDirectoryListingBackend(),
        mutationBackend: nil,
        partitionRoot: root.appendingPathComponent("Partitions", isDirectory: true),
        codeMapCacheRoot: root.appendingPathComponent("CodeMapCaches", isDirectory: true),
        configuration: WorkspaceRuntimeConfiguration(
            maxPendingWatcherEntries: maxPendingWatcherEntries,
            maxParallelScans: maxParallelScans,
            maxFoldersPerBatch: maxFoldersPerBatch,
            agentSupportRoot: root.appendingPathComponent("Agents", isDirectory: true),
            globalIgnoreDefaults: ""
        ),
        diagnostics: diagnostics
    )
}

extension WorkspaceFileContextStore {
    init() {
        self.init(runtimeDependencies: makeTestWorkspaceRuntimeDependencies())
    }
}

extension FileSystemService {
    init(
        path: String,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true
    ) async throws {
        try await self.init(
            path: path,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            dependencies: makeTestWorkspaceRuntimeDependencies()
        )
    }

    #if DEBUG
        init(
            path: String,
            respectGitignore: Bool = true,
            respectRepoIgnore: Bool = true,
            respectCursorignore: Bool = true,
            skipSymlinks: Bool = true,
            enableHierarchicalIgnores: Bool = true,
            testVisitedPaths: Set<String>? = nil,
            testVisitedItems: [String: Bool]? = nil,
            testIgnoreRules: IgnoreRules? = nil,
            isTestMode: Bool = false,
            fileManagerOverride: (any FileSystemProviding)? = nil,
            maxParallelScansOverride: Int? = nil,
            maxFoldersPerBatchOverride: Int? = nil,
            maxPendingWatcherIngressEntriesOverride: Int? = nil
        ) async throws {
            try await self.init(
                path: path,
                respectGitignore: respectGitignore,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                skipSymlinks: skipSymlinks,
                enableHierarchicalIgnores: enableHierarchicalIgnores,
                testVisitedPaths: testVisitedPaths,
                testVisitedItems: testVisitedItems,
                testIgnoreRules: testIgnoreRules,
                isTestMode: isTestMode,
                fileManagerOverride: fileManagerOverride,
                maxParallelScansOverride: maxParallelScansOverride,
                maxFoldersPerBatchOverride: maxFoldersPerBatchOverride,
                maxPendingWatcherIngressEntriesOverride: maxPendingWatcherIngressEntriesOverride,
                dependencies: makeTestWorkspaceRuntimeDependencies(
                    maxPendingWatcherEntries: maxPendingWatcherIngressEntriesOverride ?? 50_000,
                    maxParallelScans: maxParallelScansOverride,
                    maxFoldersPerBatch: maxFoldersPerBatchOverride ?? 256
                )
            )
        }
    #endif
}
