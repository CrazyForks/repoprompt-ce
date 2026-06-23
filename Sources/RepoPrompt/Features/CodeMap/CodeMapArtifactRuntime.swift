import Foundation
import RepoPromptShared

/// Process-lifetime ownership for content-addressed codemap artifact infrastructure.
///
/// Production access is intentionally lazy and inert until Phase 6 wires a consumer. Tests and
/// benchmarks should construct isolated runtimes with explicit temporary roots instead.
final class CodeMapArtifactRuntime: @unchecked Sendable {
    let artifactStore: CodeMapArtifactStore
    let locatorStore: GitBlobCodeMapLocatorStore
    let manifestStore: CodeMapRootManifestStore
    let coordinator: CodeMapArtifactBuildCoordinator
    private let bindingEngineProvider: WorkspaceCodemapBindingEngineProvider

    init(
        rootURL: URL,
        artifactStorePolicy: CodeMapArtifactStorePolicy = .default,
        artifactStoreClock: CodeMapArtifactStoreClock = .system,
        artifactStoreRemovalHooks: CodeMapSecureFileRemovalHooks? = nil,
        locatorStorePolicy: GitBlobCodeMapLocatorStorePolicy = .default,
        locatorStoreHooks: GitBlobCodeMapLocatorStoreHooks = .none,
        manifestStorePolicy: CodeMapRootManifestStorePolicy = .default,
        manifestStoreHooks: CodeMapRootManifestStoreHooks = .none,
        builder: CodeMapArtifactBuilderClient = CodeMapArtifactBuilderClient(),
        coordinatorPolicy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        coordinatorClock: CodeMapArtifactBuildCoordinatorClock = .continuous,
        coordinatorHooks: CodeMapArtifactBuildCoordinatorHooks = .none,
        bindingEngineFactory: @escaping WorkspaceCodemapBindingEngineProvider.Factory =
            WorkspaceCodemapBindingEngineProvider.unconfiguredFactory
    ) throws {
        let artifactStore = try CodeMapArtifactStore(
            rootURL: rootURL,
            policy: artifactStorePolicy,
            clock: artifactStoreClock,
            removalHooks: artifactStoreRemovalHooks
        )
        let locatorStore = try GitBlobCodeMapLocatorStore(
            rootURL: rootURL,
            policy: locatorStorePolicy,
            hooks: locatorStoreHooks
        )
        let manifestStore = try CodeMapRootManifestStore(
            rootURL: rootURL,
            policy: manifestStorePolicy,
            hooks: manifestStoreHooks
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: locatorStore),
            builder: builder,
            policy: coordinatorPolicy,
            clock: coordinatorClock,
            hooks: coordinatorHooks
        )

        self.artifactStore = artifactStore
        self.locatorStore = locatorStore
        self.manifestStore = manifestStore
        self.coordinator = coordinator
        bindingEngineProvider = WorkspaceCodemapBindingEngineProvider(factory: bindingEngineFactory)
    }

    func bindingEngine() throws -> WorkspaceCodemapBindingEngine {
        try bindingEngineProvider.engine(for: self)
    }

    static func processWide() throws -> CodeMapArtifactRuntime {
        try processWideProvider.runtime()
    }

    static func processWideRootURL(
        applicationSupportRootURL: URL,
        buildFlavor: MCPFilesystemIdentity.BuildFlavor
    ) -> URL {
        applicationSupportRootURL.appendingPathComponent(
            "CodeMapArtifactRuntime-\(buildFlavor.rawValue)",
            isDirectory: true
        )
    }

    private static let processWideProvider = CodeMapArtifactRuntimeProvider {
        let identity = MCPFilesystemConstants.identity
        let rootURL = processWideRootURL(
            applicationSupportRootURL: identity.applicationSupportRootURL(),
            buildFlavor: identity.buildFlavor
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try CodeMapArtifactRuntime(rootURL: rootURL)
    }
}

final class CodeMapArtifactRuntimeProvider: @unchecked Sendable {
    typealias Factory = @Sendable () throws -> CodeMapArtifactRuntime

    private let lock = NSLock()
    private let factory: Factory
    private var cachedResult: Result<CodeMapArtifactRuntime, Error>?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        lock.lock()
        defer { lock.unlock() }

        if let cachedResult {
            return try cachedResult.get()
        }

        let result: Result<CodeMapArtifactRuntime, Error>
        do {
            result = try .success(factory())
        } catch {
            result = .failure(error)
        }
        cachedResult = result
        return try result.get()
    }
}
