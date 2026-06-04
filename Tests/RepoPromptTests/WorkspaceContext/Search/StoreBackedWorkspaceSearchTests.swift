@testable import RepoPrompt
import XCTest

final class StoreBackedWorkspaceSearchTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        #if DEBUG
            EditFlowPerf.resetDebugCaptureForTesting()
        #endif
        for url in temporaryRoots {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testExactAbsoluteScopeHelperQualifiesTrimmedAndTildePathsButRejectsRelativeAliasAndNULInputs() async throws {
        let root = try makeTemporaryRoot(name: "ExactAbsoluteQualification")
        let fileURL = root.appendingPathComponent("Sources/Visible.swift")
        try write("visible", to: fileURL)

        let homeRoot = try makeHomeTemporaryRoot(name: "TildeQualification")
        let homeFileURL = homeRoot.appendingPathComponent("Sources/HomeVisible.swift")
        try write("home", to: homeFileURL)

        let store = WorkspaceFileContextStore()
        let record = try await store.loadRoot(path: root.path)
        _ = try await store.loadRoot(path: homeRoot.path)

        let trimmed = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("  \(fileURL.path)\n", rootScope: .visibleWorkspace)
        XCTAssertEqual(trimmed?.file?.standardizedFullPath, fileURL.path)

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let tildePath = "~/" + String(homeFileURL.path.dropFirst(homePath.count + 1))
        let tilde = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(tildePath, rootScope: .visibleWorkspace)
        XCTAssertEqual(tilde?.file?.standardizedFullPath, homeFileURL.path)

        let relative = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("Sources/Visible.swift", rootScope: .visibleWorkspace)
        let alias = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("\(record.name)/Sources/Visible.swift", rootScope: .visibleWorkspace)
        let nul = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope("/tmp/blocked\0.swift", rootScope: .visibleWorkspace)
        XCTAssertNil(relative)
        XCTAssertNil(alias)
        XCTAssertNil(nul)
    }

    func testExactAbsoluteScopeHelperReturnsDeepestDiscoverableFileFolderAndRootFolder() async throws {
        let parent = try makeTemporaryRoot(name: "NestedParent")
        let nested = parent.appendingPathComponent("NestedRoot", isDirectory: true)
        let folderURL = nested.appendingPathComponent("Sources/Nested", isDirectory: true)
        let fileURL = folderURL.appendingPathComponent("Visible.swift")
        try write("visible", to: fileURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: parent.path)
        let nestedRecord = try await store.loadRoot(path: nested.path)

        let file = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(fileURL.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(file?.file?.rootID, nestedRecord.id)
        XCTAssertEqual(file?.file?.standardizedFullPath, fileURL.path)

        let folder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(folderURL.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(folder?.folder?.rootID, nestedRecord.id)
        XCTAssertEqual(folder?.folder?.standardizedRelativePath, "Sources/Nested")

        let rootFolder = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(nested.path, rootScope: .visibleWorkspace)
        XCTAssertEqual(rootFolder?.folder?.rootID, nestedRecord.id)
        XCTAssertEqual(rootFolder?.folder?.standardizedRelativePath, "")
    }

    func testExactAbsoluteScopeHelperExcludesManagedOnlyIgnoredFiles() async throws {
        let root = try makeTemporaryRoot(name: "IgnoredDiscoverability")
        try write("*.ignored\n", to: root.appendingPathComponent(".gitignore"))
        let ignoredURL = root.appendingPathComponent("Hidden.ignored")
        try write("hidden", to: ignoredURL)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)
        let readableService = WorkspaceReadableFileService(store: store)
        let readable = await readableService.resolveReadableFile(ignoredURL.path, profile: .mcpRead, rootScope: .visibleWorkspace)
        guard case .workspace = readable else {
            return XCTFail("Expected ignored absolute read fallback to materialize a managed-only record")
        }

        let searchHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(ignoredURL.path, rootScope: .visibleWorkspace)
        XCTAssertNil(searchHit)
        let snapshot = await store.searchCatalogSnapshot(rootScope: .visibleWorkspace)
        XCTAssertFalse(snapshot.files.contains { $0.standardizedFullPath == ignoredURL.path })
    }

    func testExactAbsoluteScopeHelperHonorsVisibleGitDataAndSessionBoundScopes() async throws {
        let logicalRoot = try makeTemporaryRoot(name: "LogicalRoot")
        let gitDataRoot = try makeTemporaryRoot(name: "GitDataRoot")
        let worktreeRoot = try makeTemporaryRoot(name: "WorktreeRoot")
        let logicalFile = logicalRoot.appendingPathComponent("Logical.swift")
        let gitDataFile = gitDataRoot.appendingPathComponent("GitData.swift")
        let worktreeFile = worktreeRoot.appendingPathComponent("Worktree.swift")
        try write("logical", to: logicalFile)
        try write("git data", to: gitDataFile)
        try write("worktree", to: worktreeFile)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: logicalRoot.path)
        let gitDataRecord = try await store.loadRoot(path: gitDataRoot.path, kind: .workspaceGitData)
        let worktreeRecord = try await store.loadRoot(path: worktreeRoot.path, kind: .sessionWorktree)

        let visibleGitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(gitDataFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleGitDataHit)
        let gitDataHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(gitDataFile.path, rootScope: .visibleWorkspacePlusGitData)
        XCTAssertEqual(gitDataHit?.file?.rootID, gitDataRecord.id)

        let visibleWorktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(worktreeFile.path, rootScope: .visibleWorkspace)
        XCTAssertNil(visibleWorktreeHit)
        let sessionScope = WorkspaceLookupRootScope.sessionBoundWorkspace(
            logicalRootPaths: [logicalRoot.path],
            physicalRootPaths: [worktreeRoot.path]
        )
        let worktreeHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(worktreeFile.path, rootScope: sessionScope)
        XCTAssertEqual(worktreeHit?.file?.rootID, worktreeRecord.id)
        let sessionLogicalHit = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(logicalFile.path, rootScope: sessionScope)
        XCTAssertNil(sessionLogicalHit)
    }

    func testStoreBackedSearchAbsoluteFolderAndFileScopesReportScopedCounts() async throws {
        let root = try makeTemporaryRoot(name: "FacadeExactScopes")
        let nestedFolder = root.appendingPathComponent("Sources/Nested", isDirectory: true)
        let nestedA = nestedFolder.appendingPathComponent("A.swift")
        let nestedB = nestedFolder.appendingPathComponent("B.swift")
        let outside = root.appendingPathComponent("Sources/Outside.swift")
        try write("a", to: nestedA)
        try write("b", to: nestedB)
        try write("outside", to: outside)

        let store = WorkspaceFileContextStore()
        _ = try await store.loadRoot(path: root.path)

        let folderResult = try await searchSwiftFiles(paths: [nestedFolder.path], store: store)
        XCTAssertEqual(folderResult.scopedFileCount, 2)
        XCTAssertEqual(Set(folderResult.paths ?? []), Set([nestedA.path, nestedB.path]))

        let fileResult = try await searchSwiftFiles(paths: [nestedA.path], store: store)
        XCTAssertEqual(fileResult.scopedFileCount, 1)
        XCTAssertEqual(fileResult.paths, [nestedA.path])
    }

    func testStoreBackedSearchPreservesRelativeAliasAbsoluteMissAndWildcardFallbacks() async throws {
        let rootA = try makeTemporaryRoot(name: "FallbackAlpha")
        let rootB = try makeTemporaryRoot(name: "FallbackBeta")
        let relativeFile = rootA.appendingPathComponent("Sources/RelativeOnly.swift")
        let absoluteMissingPath = rootA.appendingPathComponent("Sources/Missing").path
        let wildcardFile = rootB.appendingPathComponent("Sources/WildcardOnly.swift")
        try write("relative", to: relativeFile)
        try write("wildcard", to: wildcardFile)

        let store = WorkspaceFileContextStore()
        let recordA = try await store.loadRoot(path: rootA.path)
        _ = try await store.loadRoot(path: rootB.path)

        let relative = try await searchSwiftFiles(paths: ["Sources/RelativeOnly.swift"], store: store)
        XCTAssertEqual(relative.paths, [relativeFile.path])

        let alias = try await searchSwiftFiles(paths: ["\(recordA.name)/Sources/RelativeOnly.swift"], store: store)
        XCTAssertEqual(alias.paths, [relativeFile.path])

        let shortcutMiss = await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(absoluteMissingPath, rootScope: .visibleWorkspace)
        XCTAssertNil(shortcutMiss)
        let absoluteMiss = try await searchSwiftFiles(paths: [absoluteMissingPath], store: store)
        XCTAssertEqual(absoluteMiss.scopedFileCount, 0)
        XCTAssertNil(absoluteMiss.paths)

        let wildcard = try await searchSwiftFiles(paths: ["*/Sources/WildcardOnly.swift"], store: store)
        XCTAssertEqual(wildcard.paths, [wildcardFile.path])
    }

    func testBroadSearchAdmissionClassifierSerializesOnlyUnscopedContentCapableModes() {
        XCTAssertTrue(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .content, paths: nil))
        XCTAssertTrue(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .both, paths: []))
        XCTAssertTrue(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .auto, paths: ["  ", "\n"]))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "*.swift", mode: .path, paths: nil))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "*.swift", mode: .auto, paths: nil))
        XCTAssertFalse(StoreBackedWorkspaceSearch.requiresBroadSearchAdmission(pattern: "needle", mode: .content, paths: ["Sources/A.swift"]))
    }

    #if DEBUG
        func testSameStoreBroadContentSearchesSerializeFIFOAndPreserveResults() async throws {
            let root = try makeTemporaryRoot(name: "BroadAdmissionFIFO")
            let alphaURL = root.appendingPathComponent("A.swift")
            let betaURL = root.appendingPathComponent("B.swift")
            try write("let alphaNeedle = true\n", to: alphaURL)
            try write("let betaNeedle = true\n", to: betaURL)
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let coordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let gate = AsyncGate()
            await coordinator.setPermitAcquiredHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }

            let first = Task {
                try await self.searchContent(pattern: "alphaNeedle", store: store, coordinator: coordinator)
            }
            let firstStarted = await gate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(firstStarted)
            let second = Task {
                try await self.searchContent(pattern: "betaNeedle", store: store, coordinator: coordinator)
            }
            let queuedBehindFirst = await waitForAdmissionWaiterCount(1, store: store, coordinator: coordinator)
            XCTAssertTrue(queuedBehindFirst)
            let heldSnapshot = await coordinator.snapshot(for: store)
            XCTAssertTrue(heldSnapshot.hasActivePermit)
            XCTAssertEqual(heldSnapshot.waiterCount, 1)

            await gate.release()
            let firstResult = try await first.value
            let secondResult = try await second.value
            XCTAssertEqual(firstResult.matches?.map(\.filePath), [alphaURL.path])
            XCTAssertEqual(secondResult.matches?.map(\.filePath), [betaURL.path])
            let finalSnapshot = await coordinator.snapshot(for: store)
            XCTAssertFalse(finalSnapshot.hasActivePermit)
            XCTAssertEqual(finalSnapshot.waiterCount, 0)
        }

        func testQueuedBroadContentSearchCancellationRemovesWaiterAndDoesNotLeakLane() async throws {
            let root = try makeTemporaryRoot(name: "BroadAdmissionCancellation")
            try write("let holdNeedle = true\nlet laterNeedle = true\n", to: root.appendingPathComponent("A.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let coordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let gate = AsyncGate()
            await coordinator.setPermitAcquiredHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }

            let first = Task {
                try await self.searchContent(pattern: "holdNeedle", store: store, coordinator: coordinator)
            }
            let firstStarted = await gate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(firstStarted)
            let cancelled = Task {
                try await self.searchContent(pattern: "cancelledNeedle", store: store, coordinator: coordinator)
            }
            let queuedBeforeCancellation = await waitForAdmissionWaiterCount(1, store: store, coordinator: coordinator)
            XCTAssertTrue(queuedBeforeCancellation)
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                XCTFail("Expected queued broad search cancellation")
            } catch is CancellationError {
                // Expected.
            }
            let removedAfterCancellation = await waitForAdmissionWaiterCount(0, store: store, coordinator: coordinator)
            XCTAssertTrue(removedAfterCancellation)
            let later = Task {
                try await self.searchContent(pattern: "laterNeedle", store: store, coordinator: coordinator)
            }
            let liveFollowerQueued = await waitForAdmissionWaiterCount(1, store: store, coordinator: coordinator)
            XCTAssertTrue(liveFollowerQueued)

            await gate.release()
            _ = try await first.value
            let laterResult = try await later.value
            XCTAssertEqual(laterResult.matches?.count, 1)
            let finalSnapshot = await coordinator.snapshot(for: store)
            XCTAssertFalse(finalSnapshot.hasActivePermit)
            XCTAssertEqual(finalSnapshot.waiterCount, 0)
        }

        func testPathScopedContentAndDifferentStoreSearchesBypassHeldBroadAdmission() async throws {
            let rootA = try makeTemporaryRoot(name: "BroadAdmissionBypassA")
            let rootB = try makeTemporaryRoot(name: "BroadAdmissionBypassB")
            let fileA = rootA.appendingPathComponent("A.swift")
            let fileB = rootB.appendingPathComponent("B.swift")
            try write("let holdNeedle = true\nlet scopedNeedle = true\n", to: fileA)
            try write("let peerNeedle = true\n", to: fileB)
            let storeA = WorkspaceFileContextStore()
            let storeB = WorkspaceFileContextStore()
            _ = try await storeA.loadRoot(path: rootA.path)
            _ = try await storeB.loadRoot(path: rootB.path)
            let coordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let gate = AsyncGate()
            await coordinator.setPermitAcquiredHandlerForTesting { store in
                guard ObjectIdentifier(store) == ObjectIdentifier(storeA) else { return }
                await gate.markStartedAndWaitForRelease()
            }

            let held = Task {
                try await self.searchContent(pattern: "holdNeedle", store: storeA, coordinator: coordinator)
            }
            let heldStarted = await gate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(heldStarted)

            let pathSignal = AsyncSignal()
            let pathTask = Task {
                let result = try await self.searchPaths(pattern: "*.swift", store: storeA, coordinator: coordinator)
                await pathSignal.mark()
                return result
            }
            let scopedSignal = AsyncSignal()
            let scopedTask = Task {
                let result = try await self.searchContent(pattern: "scopedNeedle", paths: [fileA.path], store: storeA, coordinator: coordinator)
                await scopedSignal.mark()
                return result
            }
            let peerSignal = AsyncSignal()
            let peerTask = Task {
                let result = try await self.searchContent(pattern: "peerNeedle", store: storeB, coordinator: coordinator)
                await peerSignal.mark()
                return result
            }

            let pathCompletedBeforeRelease = await pathSignal.waitUntilMarked()
            let scopedCompletedBeforeRelease = await scopedSignal.waitUntilMarked()
            let peerCompletedBeforeRelease = await peerSignal.waitUntilMarked()
            XCTAssertTrue(pathCompletedBeforeRelease)
            XCTAssertTrue(scopedCompletedBeforeRelease)
            XCTAssertTrue(peerCompletedBeforeRelease)
            await gate.release()
            let pathResult = try await pathTask.value
            let scopedResult = try await scopedTask.value
            let peerResult = try await peerTask.value
            XCTAssertEqual(pathResult.paths, [fileA.path])
            XCTAssertEqual(scopedResult.matches?.map(\.filePath), [fileA.path])
            XCTAssertEqual(peerResult.matches?.map(\.filePath), [fileB.path])
            _ = try await held.value
        }

        func testQueuedBroadContentSearchPreservesCappedOrderingAndCountOnlyCompleteness() async throws {
            let root = try makeTemporaryRoot(name: "BroadAdmissionCorrectness")
            try write("needle\nneedle\n", to: root.appendingPathComponent("A.swift"))
            try write("needle\nneedle\n", to: root.appendingPathComponent("B.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: root.path)
            let baselineCoordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let baselineCapped = try await searchContent(pattern: "needle", maxMatches: 2, store: store, coordinator: baselineCoordinator)
            let baselineCountOnly = try await searchContent(pattern: "needle", countOnly: true, store: store, coordinator: baselineCoordinator)

            let coordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let gate = AsyncGate()
            await coordinator.setPermitAcquiredHandlerForTesting { _ in
                await gate.markStartedAndWaitForRelease()
            }
            let held = Task {
                try await self.searchContent(pattern: "holdNeedle", store: store, coordinator: coordinator)
            }
            let heldStarted = await gate.waitUntilStartedWithinTimeout()
            XCTAssertTrue(heldStarted)
            let capped = Task {
                try await self.searchContent(pattern: "needle", maxMatches: 2, store: store, coordinator: coordinator)
            }
            let countOnly = Task {
                try await self.searchContent(pattern: "needle", countOnly: true, store: store, coordinator: coordinator)
            }
            let bothQueuedBehindHeldSearch = await waitForAdmissionWaiterCount(2, store: store, coordinator: coordinator)
            XCTAssertTrue(bothQueuedBehindHeldSearch)
            await gate.release()

            _ = try await held.value
            let queuedCapped = try await capped.value
            let queuedCountOnly = try await countOnly.value
            XCTAssertEqual(queuedCapped.matches, baselineCapped.matches)
            XCTAssertEqual(queuedCountOnly.totalCount, baselineCountOnly.totalCount)
            XCTAssertEqual(queuedCountOnly.contentFileCount, baselineCountOnly.contentFileCount)
            XCTAssertEqual(queuedCountOnly.searchedFileCount, baselineCountOnly.searchedFileCount)
        }

        func testStoreBackedSearchContentWorkerPermitTelemetryInheritsOriginatingCorrelation() async throws {
            let holdingRoot = try makeTemporaryRoot(name: "SearchWorkerCorrelationHolding")
            let searchRoot = try makeTemporaryRoot(name: "SearchWorkerCorrelationTarget")
            try write("let inheritedCorrelationNeedle = true\n", to: searchRoot.appendingPathComponent("Target.swift"))
            let store = WorkspaceFileContextStore()
            _ = try await store.loadRoot(path: searchRoot.path)
            let holdingService = try await FileSystemService(
                path: holdingRoot.path,
                respectGitignore: false,
                respectRepoIgnore: false,
                respectCursorignore: false,
                skipSymlinks: true
            )
            let workerLimit = FileSystemService.contentReadWorkerLimitForTesting
            let enteredCount = AsyncCounter()
            let gate = AsyncGate()
            for index in 0 ..< workerLimit {
                try write("held-\(index)", to: holdingRoot.appendingPathComponent("Held-\(index).txt"))
            }
            await holdingService.setContentReadChunkHandlerForTesting { path in
                guard path.hasPrefix("Held-") else { return }
                _ = await enteredCount.incrementAndValue()
                await gate.markStartedAndWaitForRelease()
            }
            let heldReads = (0 ..< workerLimit).map { index in
                Task {
                    try await holdingService.loadContent(
                        ofRelativePath: "Held-\(index).txt",
                        workloadClass: .contentSearch
                    )
                }
            }
            let saturated = await enteredCount.waitUntilValue(atLeast: workerLimit)
            XCTAssertTrue(saturated)
            _ = startedCapture(label: "store-backed-search-worker-correlation", maxSamples: 100)
            let correlation = try XCTUnwrap(EditFlowPerf.makeLifecycleCorrelationIfActive())
            let coordinator = StoreBackedWorkspaceSearchAdmissionCoordinator()
            let searchTask = Task {
                try await EditFlowPerf.$currentLifecycleCorrelation.withValue(correlation) {
                    try await self.searchContent(
                        pattern: "inheritedCorrelationNeedle",
                        store: store,
                        coordinator: coordinator
                    )
                }
            }
            let waitBegan = await waitForLifecycleEvent(
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                correlationID: correlation.id
            )
            XCTAssertTrue(waitBegan)

            await gate.release()
            for task in heldReads {
                _ = try await task.value
            }
            let results = try await searchTask.value
            XCTAssertEqual(results.matches?.count, 1)
            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let workerEvents = snapshot.lifecycleEvents.filter {
                $0.correlationID == correlation.id.uuidString &&
                    $0.eventName.hasPrefix("FileSystem.ContentReadWorker")
            }
            XCTAssertEqual(workerEvents.map(\.eventName), [
                "FileSystem.ContentReadWorkerPermitWaitBegan",
                "FileSystem.ContentReadWorkerPermitAcquired"
            ])
            XCTAssertTrue(workerEvents.allSatisfy { $0.sanitizedDimensions.contains("workloadClass=contentSearch") })
            await holdingService.setContentReadChunkHandlerForTesting(nil)
        }

        func testStoreBackedSearchAwaitsScopedFreshnessBeforeCatalogSnapshot() async throws {
            let root = try makeTemporaryRoot(name: "ScopedSearchFreshness")
            let addedURL = root.appendingPathComponent("Added.swift")
            let store = WorkspaceFileContextStore()
            let record = try await store.loadRoot(path: root.path)
            try await store.startWatchingRoot(id: record.id)
            let sinkGate = AsyncGate()
            await store.setWatcherSinkWillApplyHandler { observedRootID in
                guard observedRootID == record.id else { return }
                await sinkGate.markStartedAndWaitForRelease()
            }

            try write("added", to: addedURL)
            try await store.publishSyntheticFileSystemDeltasForTesting(rootID: record.id, deltas: [.fileAdded("Added.swift")])
            await sinkGate.waitUntilStarted()
            let searchTask = Task {
                try await self.searchSwiftFiles(paths: [], store: store)
            }
            await sinkGate.release()
            let result = try await searchTask.value

            XCTAssertTrue(result.paths?.contains(addedURL.path) == true)
            await store.setWatcherSinkWillApplyHandler(nil)
            await store.stopWatchingRoot(id: record.id)
        }
    #endif

    func testSearchScopeParserKeepsRequiredResolutionOrder() throws {
        let source = try String(
            contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift"),
            encoding: .utf8
        )
        try assertOrdered([
            "let hasWildcard = normalized.contains(\"*\")",
            "if hasWildcard {",
            "await store.exactPathResolutionIssue(for: normalized, kind: .either, rootScope: rootScope)",
            "await store.lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(normalized, rootScope: rootScope)",
            "await store.lookupPath(WorkspacePathLookupRequest(userPath: normalized, profile: .mcpSearchScope, rootScope: rootScope))",
            "appendClause(.legacyPrefix(candidateLower: normalized.lowercased()))"
        ], in: source)
    }

    private func searchSwiftFiles(paths: [String], store: WorkspaceFileContextStore) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: "*.swift",
            mode: .path,
            isRegex: false,
            caseInsensitive: true,
            maxPaths: 100,
            paths: paths,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil
        )
    }

    private func searchPaths(
        pattern: String,
        store: WorkspaceFileContextStore,
        coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator
    ) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: pattern,
            mode: .path,
            isRegex: false,
            caseInsensitive: true,
            maxPaths: 100,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil,
            admissionCoordinator: coordinator
        )
    }

    private func searchContent(
        pattern: String,
        paths: [String]? = nil,
        maxMatches: Int = 100,
        countOnly: Bool = false,
        store: WorkspaceFileContextStore,
        coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator
    ) async throws -> SearchResults {
        try await StoreBackedWorkspaceSearch.search(
            pattern: pattern,
            mode: .content,
            isRegex: false,
            caseInsensitive: false,
            maxMatches: maxMatches,
            paths: paths,
            countOnly: countOnly,
            rootScope: .visibleWorkspace,
            store: store,
            workspaceManager: nil,
            admissionCoordinator: coordinator
        )
    }

    #if DEBUG
        private func waitForAdmissionWaiterCount(
            _ expectedCount: Int,
            store: WorkspaceFileContextStore,
            coordinator: StoreBackedWorkspaceSearchAdmissionCoordinator,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while await coordinator.snapshot(for: store).waiterCount != expectedCount, waited < timeoutNanoseconds {
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return await coordinator.snapshot(for: store).waiterCount == expectedCount
        }

        private func waitForLifecycleEvent(
            _ eventName: String,
            correlationID: UUID,
            timeoutNanoseconds: UInt64 = 1_000_000_000
        ) async -> Bool {
            let interval: UInt64 = 10_000_000
            var waited: UInt64 = 0
            while waited < timeoutNanoseconds {
                let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: false)
                if snapshot.lifecycleEvents.contains(where: {
                    $0.eventName == eventName && $0.correlationID == correlationID.uuidString
                }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: interval)
                waited += interval
            }
            return false
        }

        private func startedCapture(label: String, maxSamples: Int) -> EditFlowPerf.DebugCaptureSnapshot {
            switch EditFlowPerf.beginDebugCapture(label: label, maxSamples: maxSamples) {
            case let .started(snapshot):
                return snapshot
            case .busy:
                XCTFail("Capture should start.")
                fatalError("Capture should start.")
            }
        }
    #endif

    private func assertOrdered(_ needles: [String], in source: String) throws {
        var lowerBound = source.startIndex
        for needle in needles {
            let range = try XCTUnwrap(source.range(of: needle, range: lowerBound ..< source.endIndex), "Missing ordered source fragment: \(needle)")
            lowerBound = range.upperBound
        }
    }

    #if DEBUG
        private actor AsyncCounter {
            private var count = 0

            func incrementAndValue() -> Int {
                count += 1
                return count
            }

            func waitUntilValue(atLeast target: Int, timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while count < target, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return count >= target
            }
        }

        private actor AsyncSignal {
            private var marked = false

            func mark() {
                marked = true
            }

            func waitUntilMarked(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while !marked, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return marked
            }
        }

        private actor AsyncGate {
            private var started = false
            private var released = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            func markStartedAndWaitForRelease() async {
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
                guard !released else { return }
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }

            func waitUntilStarted() async {
                guard !started else { return }
                await withCheckedContinuation { continuation in
                    startWaiters.append(continuation)
                }
            }

            func waitUntilStartedWithinTimeout(timeoutNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
                let interval: UInt64 = 10_000_000
                var waited: UInt64 = 0
                while !started, waited < timeoutNanoseconds {
                    try? await Task.sleep(nanoseconds: interval)
                    waited += interval
                }
                return started
            }

            func release() {
                released = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    #endif

    private func makeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPromptTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func makeHomeTemporaryRoot(name: String) throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".RepoPromptTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryRoots.append(url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
