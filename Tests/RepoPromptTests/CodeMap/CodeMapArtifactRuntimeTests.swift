import Darwin
import Foundation
@testable import RepoPrompt
import RepoPromptShared
import XCTest

final class CodeMapArtifactRuntimeTests: XCTestCase {
    func testRuntimeProviderLazilyMemoizesOneInstanceAcrossConcurrentCallers() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let callerCount = 32
        let factoryCount = RuntimeProviderTestCounter()
        let results = RuntimeProviderTestResults()
        let overlapGate = RuntimeProviderOverlapGate(expectedCallerCount: callerCount)
        let provider = CodeMapArtifactRuntimeProvider {
            factoryCount.increment()
            overlapGate.factoryEnteredAndWaitForRelease()
            return try CodeMapArtifactRuntime(
                rootURL: root,
                builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
            )
        }
        XCTAssertEqual(factoryCount.value, 0)

        let callers = startProviderCallers(
            count: callerCount,
            provider: provider,
            overlapGate: overlapGate,
            results: results
        )
        let overlapObserved = overlapGate.waitForDeterministicOverlap()
        let overlapSnapshot = overlapGate.snapshot
        overlapGate.releaseFactory()
        XCTAssertTrue(overlapObserved)
        XCTAssertEqual(overlapSnapshot.callerCount, callerCount)
        XCTAssertEqual(overlapSnapshot.factoryEntryCount, 1)
        XCTAssertEqual(callers.wait(timeout: .now() + 10), .success)

        let snapshot = results.snapshot()
        XCTAssertEqual(factoryCount.value, 1)
        XCTAssertEqual(snapshot.runtimes.count, callerCount)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let first = try XCTUnwrap(snapshot.runtimes.first)
        XCTAssertTrue(snapshot.runtimes.allSatisfy { $0 === first })
        XCTAssertTrue(try provider.runtime() === first)
    }

    func testRuntimeProviderMemoizesInitializationFailureWithoutFallback() {
        let callerCount = 32
        let sentinel = NSError(
            domain: "CodeMapArtifactRuntimeTests.Sentinel",
            code: 93,
            userInfo: [NSLocalizedDescriptionKey: "reference-identical sentinel"]
        )
        let factoryCount = RuntimeProviderTestCounter()
        let results = RuntimeProviderTestResults()
        let overlapGate = RuntimeProviderOverlapGate(expectedCallerCount: callerCount)
        let provider = CodeMapArtifactRuntimeProvider {
            factoryCount.increment()
            overlapGate.factoryEnteredAndWaitForRelease()
            throw sentinel
        }

        let callers = startProviderCallers(
            count: callerCount,
            provider: provider,
            overlapGate: overlapGate,
            results: results
        )
        let overlapObserved = overlapGate.waitForDeterministicOverlap()
        let overlapSnapshot = overlapGate.snapshot
        overlapGate.releaseFactory()
        XCTAssertTrue(overlapObserved)
        XCTAssertEqual(overlapSnapshot.callerCount, callerCount)
        XCTAssertEqual(overlapSnapshot.factoryEntryCount, 1)
        XCTAssertEqual(callers.wait(timeout: .now() + 10), .success)

        let snapshot = results.snapshot()
        XCTAssertEqual(factoryCount.value, 1)
        XCTAssertTrue(snapshot.runtimes.isEmpty)
        XCTAssertEqual(snapshot.errors.count, callerCount)
        XCTAssertTrue(snapshot.errors.allSatisfy {
            ($0 as NSError) === sentinel
        })
        do {
            _ = try provider.runtime()
            XCTFail("expected memoized initialization failure")
        } catch {
            XCTAssertTrue((error as NSError) === sentinel)
        }
        XCTAssertEqual(factoryCount.value, 1)
    }

    func testBindingEngineProviderIsInertAndMemoizesOneEngineAcrossConcurrentCallers() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let callerCount = 32
        let factoryCount = RuntimeProviderTestCounter()
        let results = BindingEngineProviderTestResults()
        let overlapGate = RuntimeProviderOverlapGate(expectedCallerCount: callerCount)
        let runtime = try CodeMapArtifactRuntime(
            rootURL: root,
            bindingEngineFactory: { runtime in
                factoryCount.increment()
                overlapGate.factoryEnteredAndWaitForRelease()
                return Self.makeBindingEngine(runtime: runtime)
            }
        )
        XCTAssertEqual(factoryCount.value, 0)

        let callers = startBindingEngineCallers(
            count: callerCount,
            runtime: runtime,
            overlapGate: overlapGate,
            results: results
        )
        let overlapObserved = overlapGate.waitForDeterministicOverlap()
        let overlapSnapshot = overlapGate.snapshot
        overlapGate.releaseFactory()
        XCTAssertTrue(overlapObserved)
        XCTAssertEqual(overlapSnapshot.callerCount, callerCount)
        XCTAssertEqual(overlapSnapshot.factoryEntryCount, 1)
        XCTAssertEqual(callers.wait(timeout: .now() + 10), .success)

        let snapshot = results.snapshot()
        XCTAssertEqual(factoryCount.value, 1)
        XCTAssertEqual(snapshot.engines.count, callerCount)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let first = try XCTUnwrap(snapshot.engines.first)
        XCTAssertTrue(snapshot.engines.allSatisfy { $0 === first })
        XCTAssertTrue(try runtime.bindingEngine() === first)
    }

    func testBindingEngineProviderMemoizesUnconfiguredFailureWithoutFallback() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let factoryCount = RuntimeProviderTestCounter()
        let runtime = try CodeMapArtifactRuntime(
            rootURL: root,
            bindingEngineFactory: { _ in
                factoryCount.increment()
                throw WorkspaceCodemapBindingEngineProviderError.unconfigured
            }
        )
        XCTAssertEqual(factoryCount.value, 0)

        for _ in 0 ..< 2 {
            XCTAssertThrowsError(try runtime.bindingEngine()) {
                XCTAssertEqual(
                    $0 as? WorkspaceCodemapBindingEngineProviderError,
                    .unconfigured
                )
            }
        }
        XCTAssertEqual(factoryCount.value, 1)
    }

    func testEachRuntimeOwnsItsOwnMemoizedBindingEngine() throws {
        let firstRoot = try makeSecureRoot()
        let secondRoot = try makeSecureRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let factoryCount = RuntimeProviderTestCounter()
        let factory: WorkspaceCodemapBindingEngineProvider.Factory = { runtime in
            factoryCount.increment()
            return Self.makeBindingEngine(runtime: runtime)
        }
        let firstRuntime = try CodeMapArtifactRuntime(
            rootURL: firstRoot,
            bindingEngineFactory: factory
        )
        let secondRuntime = try CodeMapArtifactRuntime(
            rootURL: secondRoot,
            bindingEngineFactory: factory
        )

        let firstEngine = try firstRuntime.bindingEngine()
        let secondEngine = try secondRuntime.bindingEngine()

        XCTAssertTrue(try firstRuntime.bindingEngine() === firstEngine)
        XCTAssertTrue(try secondRuntime.bindingEngine() === secondEngine)
        XCTAssertFalse(firstEngine === secondEngine)
        XCTAssertEqual(factoryCount.value, 2)
    }

    func testInsecureRuntimeRootFailsWithoutConstructingAlternateStores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapRuntimeInsecure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let resolvedRoot = try resolvedDirectoryURL(root)
        defer { try? FileManager.default.removeItem(at: resolvedRoot) }
        XCTAssertEqual(chmod(resolvedRoot.path, 0o755), 0)

        XCTAssertThrowsError(try CodeMapArtifactRuntime(rootURL: resolvedRoot)) {
            XCTAssertEqual($0 as? CodeMapArtifactFileStoreError, .insecureDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: resolvedRoot.path), [])
    }

    func testProcessWideRootDerivationSeparatesFlavorsAndReservedNamespaces() {
        let applicationSupportRoot = URL(
            fileURLWithPath: "/synthetic/Library/Application Support/RepoPrompt CE",
            isDirectory: true
        )
        let debugRoot = CodeMapArtifactRuntime.processWideRootURL(
            applicationSupportRootURL: applicationSupportRoot,
            buildFlavor: .debug
        )
        let releaseRoot = CodeMapArtifactRuntime.processWideRootURL(
            applicationSupportRootURL: applicationSupportRoot,
            buildFlavor: .release
        )

        XCTAssertEqual(
            debugRoot,
            applicationSupportRoot.appendingPathComponent("CodeMapArtifactRuntime-debug", isDirectory: true)
        )
        XCTAssertEqual(
            releaseRoot,
            applicationSupportRoot.appendingPathComponent("CodeMapArtifactRuntime-release", isDirectory: true)
        )
        assertNamespacesDoNotCollide(debugRoot, releaseRoot)

        let reservedPaths = [
            applicationSupportRoot.appendingPathComponent("CodeMapCaches", isDirectory: true),
            applicationSupportRoot.appendingPathComponent("MCP", isDirectory: true),
            applicationSupportRoot.appendingPathComponent("DebugApps/RepoPrompt.app", isDirectory: true)
        ]
        for runtimeRoot in [debugRoot, releaseRoot] {
            for reservedPath in reservedPaths {
                assertNamespacesDoNotCollide(runtimeRoot, reservedPath)
            }
        }
    }

    func testRuntimeOwnsCoordinatorBackedByItsExactArtifactAndLocatorStores() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: root,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let artifactStore = runtime.artifactStore
        let locatorStore = runtime.locatorStore
        let coordinator = runtime.coordinator

        XCTAssertTrue(runtime.artifactStore === artifactStore)
        XCTAssertTrue(runtime.locatorStore === locatorStore)
        XCTAssertTrue(runtime.coordinator === coordinator)

        let input = try makeLocatorInput(root: root)
        let result = try await coordinator.resolve(
            CodeMapArtifactBuildRequest(
                ownerID: UUID(),
                priority: .demand,
                target: .source(input)
            )
        )
        guard case let .ready(resolution) = result else {
            XCTFail("expected runtime coordinator resolution")
            return
        }
        XCTAssertEqual(resolution.locatorPublication, .inserted)

        switch try await artifactStore.lookup(key: input.artifactKey) {
        case let .hit(source, handle):
            XCTAssertEqual(source, .memory)
            XCTAssertTrue(handle === resolution.handle)
        case .miss:
            XCTFail("runtime artifact store did not observe coordinator publication")
        }
        switch try await locatorStore.read(identity: XCTUnwrap(input.locatorIdentity)) {
        case let .hit(key): XCTAssertEqual(key, input.artifactKey)
        case .miss, .corrupt: XCTFail("runtime locator store did not observe coordinator publication")
        }
    }

    func testRuntimeOwnsExactInertRootManifestStore() async throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try CodeMapArtifactRuntime(
            rootURL: root,
            builder: CodeMapArtifactBuilderClient(build: { _, _, _ in .readyNoSymbols })
        )
        let manifestStore = runtime.manifestStore

        XCTAssertTrue(runtime.manifestStore === manifestStore)
        let accounting = try await manifestStore.accounting()
        XCTAssertEqual(accounting.manifestCount, 0)
        XCTAssertEqual(accounting.recordCount, 0)
        XCTAssertEqual(accounting.manifestByteCount, 0)
    }

    private func makeSecureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapRuntime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedRoot = try resolvedDirectoryURL(root)
        XCTAssertEqual(chmod(resolvedRoot.path, 0o700), 0)
        return resolvedRoot
    }

    private func startProviderCallers(
        count: Int,
        provider: CodeMapArtifactRuntimeProvider,
        overlapGate: RuntimeProviderOverlapGate,
        results: RuntimeProviderTestResults
    ) -> DispatchGroup {
        let callers = DispatchGroup()
        for _ in 0 ..< count {
            callers.enter()
            Thread.detachNewThread {
                defer { callers.leave() }
                overlapGate.callerWillRequestRuntime()
                do {
                    try results.record(runtime: provider.runtime())
                } catch {
                    results.record(error: error)
                }
            }
        }
        return callers
    }

    private func startBindingEngineCallers(
        count: Int,
        runtime: CodeMapArtifactRuntime,
        overlapGate: RuntimeProviderOverlapGate,
        results: BindingEngineProviderTestResults
    ) -> DispatchGroup {
        let callers = DispatchGroup()
        for _ in 0 ..< count {
            callers.enter()
            Thread.detachNewThread {
                defer { callers.leave() }
                overlapGate.callerWillRequestRuntime()
                do {
                    try results.record(engine: runtime.bindingEngine())
                } catch {
                    results.record(error: error)
                }
            }
        }
        return callers
    }

    private static func makeBindingEngine(
        runtime: CodeMapArtifactRuntime
    ) -> WorkspaceCodemapBindingEngine {
        WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: WorkspaceCodemapGitCapabilityService(
                namespaceSalt: Data(
                    repeating: 0x5A,
                    count: GitBlobRepositoryNamespace.saltByteCount
                )
            ),
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                throw CancellationError()
            }
        )
    }

    private func assertNamespacesDoNotCollide(
        _ first: URL,
        _ second: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let firstPath = first.standardizedFileURL.path
        let secondPath = second.standardizedFileURL.path
        XCTAssertNotEqual(firstPath, secondPath, file: file, line: line)
        XCTAssertFalse(firstPath.hasPrefix(secondPath + "/"), file: file, line: line)
        XCTAssertFalse(secondPath.hasPrefix(firstPath + "/"), file: file, line: line)
    }

    private func resolvedDirectoryURL(_ url: URL) throws -> URL {
        let resolvedPath = try XCTUnwrap(url.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private func makeLocatorInput(root: URL) throws -> CodeMapArtifactBuildInput {
        let bytes = Data("runtime ownership".utf8)
        let source = try WorkspaceCodemapValidatedSnapshotTestSupport.cleanSource(
            bytes: bytes,
            objectFormat: .sha1,
            namespaceScope: root.path
        )
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: source.decoderPolicy
        )
        guard case let .cleanGitBlob(namespace, blobOID) = source.provenance else {
            throw GitBlobIdentityError.invalidOID
        }
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: namespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        return try CodeMapArtifactBuildInput(
            source: source,
            language: .swift,
            locatorIdentity: locator
        )
    }
}

private final class RuntimeProviderOverlapGate: @unchecked Sendable {
    struct Snapshot {
        let callerCount: Int
        let factoryEntryCount: Int
    }

    private let condition = NSCondition()
    private let expectedCallerCount: Int
    private var callerCount = 0
    private var factoryEntryCount = 0
    private var factoryReleased = false

    init(expectedCallerCount: Int) {
        self.expectedCallerCount = expectedCallerCount
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(callerCount: callerCount, factoryEntryCount: factoryEntryCount)
    }

    func callerWillRequestRuntime() {
        condition.lock()
        callerCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func factoryEnteredAndWaitForRelease() {
        condition.lock()
        factoryEntryCount += 1
        condition.broadcast()
        while !factoryReleased {
            condition.wait()
        }
        condition.unlock()
    }

    func waitForDeterministicOverlap(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while callerCount < expectedCallerCount || factoryEntryCount != 1 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFactory() {
        condition.lock()
        factoryReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class RuntimeProviderTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private final class RuntimeProviderTestResults: @unchecked Sendable {
    struct Snapshot {
        let runtimes: [CodeMapArtifactRuntime]
        let errors: [Error]
    }

    private let lock = NSLock()
    private var runtimes: [CodeMapArtifactRuntime] = []
    private var errors: [Error] = []

    func record(runtime: CodeMapArtifactRuntime) {
        lock.lock()
        runtimes.append(runtime)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(runtimes: runtimes, errors: errors)
    }
}

private final class BindingEngineProviderTestResults: @unchecked Sendable {
    struct Snapshot {
        let engines: [WorkspaceCodemapBindingEngine]
        let errors: [Error]
    }

    private let lock = NSLock()
    private var engines: [WorkspaceCodemapBindingEngine] = []
    private var errors: [Error] = []

    func record(engine: WorkspaceCodemapBindingEngine) {
        lock.lock()
        engines.append(engine)
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(engines: engines, errors: errors)
    }
}
