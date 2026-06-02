#if DEBUG
    @testable import RepoPrompt
    import XCTest

    final class MCPReadSearchLatencyDiagnosticsGuardTests: XCTestCase {
        override func tearDown() {
            EditFlowPerf.resetDebugCaptureForTesting()
            super.tearDown()
        }

        func testHiddenDispatcherRecognizesReadSearchCaptureOperations() throws {
            let diagnostics = try diagnosticsSource()
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_begin"))
            XCTAssertTrue(diagnostics.contains("mcp_read_search_capture_snapshot"))

            let sibling = try source("Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift")
            XCTAssertTrue(sibling.contains("#if DEBUG"))
            XCTAssertTrue(sibling.contains("100 ... 100_000"))
        }

        func testExpectedAttributionStagesRemainPresent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            for stage in [
                "EditFlow.MCPToolCall.PreToolFilesystemFlush",
                "EditFlow.MCPToolCall.ProviderExecution",
                "EditFlow.MCPToolCall.FormatResult",
                "EditFlow.ReadFile.ResolveReadableFile",
                "EditFlow.ReadFile.ExactPathIssueDetection",
                "EditFlow.ReadFile.RootRefsLookup",
                "EditFlow.ReadFile.FolderResolution",
                "EditFlow.ReadFile.ExternalFolderGuard",
                "EditFlow.ReadFile.ReadableServiceResolution",
                "EditFlow.ReadFile.ExactCatalogLookupAwait",
                "EditFlow.ReadFile.ExactCatalogLookupActorBody",
                "EditFlow.ReadFile.ExplicitMaterialization",
                "EditFlow.ReadFile.GeneralLookupFallback",
                "EditFlow.ReadFile.ExternalFileFallback",
                "EditFlow.ReadFile.WorkspaceContentLoad",
                "EditFlow.ReadFile.SplitPreservingLineEndings",
                "EditFlow.ReadFile.BuildSlice",
                "EditFlow.Search.CatalogSnapshot",
                "EditFlow.Search.DTOBuild",
                "EditFlow.FileSystem.ContentLoadActorBody"
            ] {
                XCTAssertTrue(perf.contains(stage), "Missing attribution stage: \(stage)")
            }
        }

        func testReadResolutionDecompositionHooksRemainOnExpectedLayers() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            for hook in [
                "resolveReadableFile",
                "exactPathIssueDetection",
                "rootRefsLookup",
                "folderResolution",
                "externalFolderGuard",
                "readableServiceResolution"
            ] {
                XCTAssertTrue(viewModel.contains(hook), "Missing view-model read-resolution hook: \(hook)")
            }

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            for hook in [
                "exactCatalogLookupAwait",
                "explicitMaterialization",
                "generalLookupFallback",
                "externalFileFallback"
            ] {
                XCTAssertTrue(readableService.contains(hook), "Missing readable-service resolution hook: \(hook)")
            }

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("exactCatalogLookupActorBody"))
            XCTAssertTrue(store.contains("Dimensions(outcome:"))
        }

        func testReadResolutionDecompositionAvoidsOrdinaryReleaseOutcomeBookkeeping() throws {
            let viewModel = try source("Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift")
            XCTAssertFalse(viewModel.contains("let readableServiceOutcome ="))
            XCTAssertTrue(viewModel.contains("Dimensions(outcome: {\n                    switch readableFile"))

            let readableService = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceReadableFileService.swift")
            XCTAssertFalse(readableService.contains("let exactCatalogLookupOutcome ="))
            XCTAssertFalse(readableService.contains("let explicitMaterializationOutcome ="))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch exactCatalogLookup"))
            XCTAssertTrue(readableService.contains("Dimensions(outcome: {\n                switch materialization"))

            let store = try source("Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift")
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n            var exactCatalogLookupOutcome"))
            XCTAssertTrue(store.contains("#if DEBUG || EDIT_FLOW_PERF\n                exactCatalogLookupOutcome ="))
        }

        func testInactiveCaptureFastPathRemainsAtomicAndUnusedOutputBytesIsAbsent() throws {
            let perf = try source("Sources/RepoPrompt/Infrastructure/Diffing/EditFlowPerf.swift")
            XCTAssertTrue(perf.contains("Lightweight, gated instrumentation for hot-path diagnostics."))
            XCTAssertTrue(perf.contains("private let activeHint = DebugCaptureActiveHint()"))
            XCTAssertTrue(perf.contains("if let active = activeHint.loadIfAvailable(), !active { return nil }"))
            XCTAssertTrue(perf.contains("@available(macOS 15.0, *)"))
            XCTAssertFalse(perf.contains("outputBytes"))
        }

        func testCaptureRejectsConcurrentStartAndFinishDisablesCapture() {
            switch EditFlowPerf.beginDebugCapture(label: "first", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("First capture should start.")
            }
            switch EditFlowPerf.beginDebugCapture(label: "second", maxSamples: 100) {
            case .started:
                XCTFail("Concurrent capture should be rejected.")
            case let .busy(snapshot):
                XCTAssertEqual(snapshot.label, "first")
                XCTAssertTrue(snapshot.active)
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertFalse(snapshot.active)
            XCTAssertFalse(EditFlowPerf.isDebugCaptureActive)
        }

        func testStaleIntervalFromFinishedCaptureDoesNotContaminateNextCapture() throws {
            _ = startedCapture(label: "capture-a", maxSamples: 100)
            let staleState = try XCTUnwrap(EditFlowPerf.begin(EditFlowPerf.Stage.MCPToolCall.providerExecution))
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            _ = startedCapture(label: "capture-b", maxSamples: 100)
            EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.providerExecution, staleState)

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.label, "capture-b")
            XCTAssertEqual(snapshot.retainedSampleCount, 0)
            XCTAssertEqual(snapshot.droppedSampleCount, 0)
            XCTAssertTrue(snapshot.stages.isEmpty)
        }

        func testDirectCaptureSampleLimitIsClampedToDiagnosticBounds() {
            let lowerBound = startedCapture(label: "lower", maxSamples: 1)
            XCTAssertEqual(lowerBound.maxSamples, 100)
            _ = EditFlowPerf.debugCaptureSnapshot(finish: true)

            let upperBound = startedCapture(label: "upper", maxSamples: 100_001)
            XCTAssertEqual(upperBound.maxSamples, 100_000)
        }

        func testUnsafeSyntheticLabelAndDimensionsAreSanitizedAndBounded() throws {
            let unsafe = "synthetic /:|\\n" + String(repeating: "x", count: 100)
            let started = startedCapture(label: unsafe, maxSamples: 100)
            assertPermittedLabel(started.label)

            EditFlowPerf.measure(
                EditFlowPerf.Stage.MCPToolCall.providerExecution,
                EditFlowPerf.Dimensions(toolName: unsafe, status: unsafe)
            ) {}

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            let components = aggregate.sanitizedDimensions.split(separator: " ")
            XCTAssertEqual(components.count, 2)
            for component in components {
                let parts = component.split(separator: "=", maxSplits: 1)
                XCTAssertEqual(parts.count, 2)
                assertPermittedLabel(String(parts[1]))
            }
        }

        func testBoundedCaptureReportsDroppedSamplesAndSanitizedDimensions() throws {
            switch EditFlowPerf.beginDebugCapture(label: "bounded", maxSamples: 100) {
            case .started:
                break
            case .busy:
                XCTFail("Capture should start.")
            }

            for _ in 0 ..< 101 {
                EditFlowPerf.measure(
                    EditFlowPerf.Stage.MCPToolCall.providerExecution,
                    EditFlowPerf.Dimensions(toolName: "read_file", status: "ok")
                ) {}
            }

            let snapshot = EditFlowPerf.debugCaptureSnapshot(finish: true)
            XCTAssertEqual(snapshot.retainedSampleCount, 100)
            XCTAssertEqual(snapshot.droppedSampleCount, 1)
            let aggregate = try XCTUnwrap(snapshot.stages.first)
            XCTAssertEqual(aggregate.sampleCount, 100)
            XCTAssertTrue(aggregate.sanitizedDimensions.contains("tool=read_file"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("/"))
            XCTAssertFalse(aggregate.sanitizedDimensions.contains("namespace"))
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

        private func assertPermittedLabel(_ value: String, file: StaticString = #filePath, line: UInt = #line) {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
            XCTAssertLessThanOrEqual(value.unicodeScalars.count, 64, file: file, line: line)
            XCTAssertTrue(value.unicodeScalars.allSatisfy(allowed.contains), "Unexpected unsafe label: \(value)", file: file, line: line)
        }

        private func diagnosticsSource() throws -> String {
            let root = try RepoRoot.url()
            let directory = root.appendingPathComponent("Sources/RepoPrompt/Features/Diagnostics/MCP")
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("MCPConnectionManager+DebugDiagnostics") && $0.pathExtension == "swift" }
                .map { try String(contentsOf: $0, encoding: .utf8) }
                .joined(separator: "\n")
        }

        private func source(_ relativePath: String) throws -> String {
            try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
        }
    }
#endif
