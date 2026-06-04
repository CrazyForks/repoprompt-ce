@testable import RepoPrompt
import XCTest

@MainActor
final class MCPReadFileAutoSelectionCoordinatorTests: XCTestCase {
    func testEnqueueReturnsWhileCanonicalMutationIsBlocked() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            await gate.markStartedAndWaitForRelease()
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()

        XCTAssertEqual(coordinator.debugSnapshot().canonicalWorkerCount, 1)
        let batchesBeforeRelease = await recorder.canonicalBatches()
        XCTAssertTrue(batchesBeforeRelease.isEmpty)

        await gate.release()
        await coordinator.drain(.canonicalSelection, for: key)
        let batchesAfterDrain = await recorder.canonicalBatches()
        XCTAssertEqual(batchesAfterDrain.count, 1)
    }

    func testCanonicalPendingBatchCoalescesAndFullFileWinsOverSlices() async {
        let firstGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            if await recorder.canonicalBatches().isEmpty {
                await firstGate.markStartedAndWaitForRelease()
            }
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: key))
        await firstGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .slices(entries: [
            WorkspaceSelectionSliceInput(path: "/tmp/A.swift", ranges: [LineRange(start: 1, end: 3)])
        ]), for: key))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        XCTAssertTrue(coordinator.enqueue(intent: .slices(entries: [
            WorkspaceSelectionSliceInput(path: "/tmp/B.swift", ranges: [LineRange(start: 4, end: 6), LineRange(start: 6, end: 8)])
        ]), for: key))
        XCTAssertEqual(coordinator.debugSnapshot().pendingCanonicalBatchCount, 1)

        await firstGate.release()
        await coordinator.drain(.canonicalSelection, for: key)

        let batches = await recorder.canonicalBatches()
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].fullPaths, ["/tmp/A.swift"])
        XCTAssertEqual(batches[1].sliceEntries, [
            WorkspaceSelectionSliceInput(path: "/tmp/B.swift", ranges: [LineRange(start: 4, end: 8)])
        ])
    }

    func testCanonicalIdentityIsConnectionAndRunScopedWhileMirrorsCoalescePerTab() async {
        let mirrorGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let tabID = UUID()
        let workspaceID = UUID()
        let first = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: UUID(), runID: UUID()))
        let second = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: UUID(), runID: UUID()))
        let compatibility = contextKey(tabID: tabID, workspaceID: workspaceID, route: .activeTabCompatibility)
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, batch in
                await recorder.recordKey(key)
                await recorder.recordCanonical(batch)
                return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { key in
                let invocation = await recorder.recordMirror(key)
                if invocation == 1 {
                    await mirrorGate.markStartedAndWaitForRelease()
                }
            }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: first))
        await mirrorGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: second))
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/C.swift"]), for: compatibility))
        await Task.yield()
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 3)
        XCTAssertLessThanOrEqual(coordinator.debugSnapshot().pendingMirrorBatchCount, 1)

        await mirrorGate.release()
        await coordinator.drain(.mirroredSelectionAndMetrics, for: first)
        await coordinator.drain(.mirroredSelectionAndMetrics, for: second)
        await coordinator.drain(.mirroredSelectionAndMetrics, for: compatibility)

        let recordedKeys = await recorder.keys()
        let mirrorCount = await recorder.mirrorCount()
        XCTAssertEqual(Set(recordedKeys), Set([first, second, compatibility]))
        XCTAssertLessThanOrEqual(mirrorCount, 2)
    }

    func testDrainCapturesFiniteHighWaterMark() async {
        let firstGate = CoordinatorAsyncGate()
        let secondGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            let invocation = await recorder.recordCanonicalAndCount(batch)
            if invocation == 1 {
                await firstGate.markStartedAndWaitForRelease()
            } else if invocation == 2 {
                await secondGate.markStartedAndWaitForRelease()
            }
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: key))
        await firstGate.waitUntilStarted()
        let drainFinished = CoordinatorAsyncSignal()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.canonicalSelection, for: key)
            await drainFinished.mark()
        }
        await Task.yield()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Later.swift"]), for: key))

        await firstGate.release()
        await secondGate.waitUntilStarted()
        let finishedAtCapturedHighWaterMark = await drainFinished.isMarked()
        XCTAssertTrue(finishedAtCapturedHighWaterMark)

        await secondGate.release()
        await drainTask.value
        await coordinator.drain(.canonicalSelection, for: key)
    }

    func testInvalidationDropsPendingWorkBeforeStoredCommit() async {
        let recorder = CoordinatorRecorder()
        var currentKey: MCPReadFileAutoSelectionCoordinator.ContextKey?
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == currentKey },
            applyCanonical: { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { _ in }
        )
        let key = contextKey()
        currentKey = key

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        currentKey = nil
        coordinator.invalidate(context: key)
        await coordinator.drain(.canonicalSelection, for: key)
        await Task.yield()

        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertTrue(recordedBatches.isEmpty)
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: key))
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 0)
    }

    func testFinishDrainsAcceptedWorkAndRejectsLaterEnqueues() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            await gate.markStartedAndWaitForRelease()
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()
        let finishTask = Task { @MainActor in
            await coordinator.finish(context: key)
        }
        await Task.yield()
        XCTAssertFalse(coordinator.enqueue(intent: .full(paths: ["/tmp/B.swift"]), for: key))

        await gate.release()
        await finishTask.value
        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertEqual(recordedBatches.count, 1)
        await Task.yield()
        XCTAssertEqual(coordinator.debugSnapshot().canonicalLaneCount, 0)
        XCTAssertEqual(coordinator.debugSnapshot().closingContextCount, 0)
    }

    func testLateLowerCanonicalCommitWaitsForItsOwnTabMirrorTicket() async {
        let firstCanonicalGate = CoordinatorAsyncGate()
        let lateMirrorGate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let tabID = UUID()
        let workspaceID = UUID()
        let first = contextKey(tabID: tabID, workspaceID: workspaceID)
        let second = contextKey(tabID: tabID, workspaceID: workspaceID)
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: { key, _ in
                if key == first {
                    await firstCanonicalGate.markStartedAndWaitForRelease()
                }
                return MCPReadFileAutoSelectionCoordinator.CanonicalApplyResult(mirrorKey: key.mirrorKey)
            },
            applyMirror: { key in
                let invocation = await recorder.recordMirror(key)
                if invocation == 2 {
                    await lateMirrorGate.markStartedAndWaitForRelease()
                }
            }
        )

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/First.swift"]), for: first))
        await firstCanonicalGate.waitUntilStarted()
        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Second.swift"]), for: second))
        await coordinator.drain(.mirroredSelectionAndMetrics, for: second)

        await firstCanonicalGate.release()
        await lateMirrorGate.waitUntilStarted()
        let drainFinished = CoordinatorAsyncSignal()
        let drainTask = Task { @MainActor in
            await coordinator.drain(.mirroredSelectionAndMetrics, for: first)
            await drainFinished.mark()
        }
        await Task.yield()
        let finishedBeforeLateMirror = await drainFinished.isMarked()
        XCTAssertFalse(finishedBeforeLateMirror)

        await lateMirrorGate.release()
        await drainTask.value
    }

    func testReplacementBindingGenerationDropsOldWorkAndAcceptsNewWork() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let connectionID = UUID()
        let runID = UUID()
        let tabID = UUID()
        let workspaceID = UUID()
        let old = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: connectionID, runID: runID), bindingGeneration: 1)
        let replacement = contextKey(tabID: tabID, workspaceID: workspaceID, route: .bound(connectionID: connectionID, runID: runID), bindingGeneration: 2)
        var current = old
        let coordinator = MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { $0 == current },
            applyCanonical: { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { _ in }
        )
        coordinator.setCanonicalApplyGateForTesting {
            await gate.markStartedAndWaitForRelease()
        }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/Old.swift"]), for: old))
        await gate.waitUntilStarted()
        current = replacement
        coordinator.invalidate(context: old)
        await gate.release()
        await coordinator.drain(.canonicalSelection, for: old)
        coordinator.setCanonicalApplyGateForTesting(nil)

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/New.swift"]), for: replacement))
        await coordinator.drain(.canonicalSelection, for: replacement)
        let batches = await recorder.canonicalBatches()
        XCTAssertEqual(batches.map(\.fullPaths), [["/tmp/New.swift"]])
    }

    func testInvalidationDuringSuspensionPreventsStoredCommit() async {
        let gate = CoordinatorAsyncGate()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(recorder: recorder) { _, batch in
            await recorder.recordCanonical(batch)
            return .unchanged
        }
        let key = contextKey()
        coordinator.setCanonicalApplyGateForTesting {
            await gate.markStartedAndWaitForRelease()
        }

        XCTAssertTrue(coordinator.enqueue(intent: .full(paths: ["/tmp/A.swift"]), for: key))
        await gate.waitUntilStarted()
        coordinator.invalidate(context: key)
        await gate.release()
        await coordinator.drain(.canonicalSelection, for: key)

        let recordedBatches = await recorder.canonicalBatches()
        XCTAssertTrue(recordedBatches.isEmpty)
    }

    private func makeCoordinator(
        recorder: CoordinatorRecorder,
        applyCanonical: MCPReadFileAutoSelectionCoordinator.ApplyCanonical? = nil
    ) -> MCPReadFileAutoSelectionCoordinator {
        MCPReadFileAutoSelectionCoordinator(
            isContextCurrent: { _ in true },
            applyCanonical: applyCanonical ?? { _, batch in
                await recorder.recordCanonical(batch)
                return .unchanged
            },
            applyMirror: { key in
                _ = await recorder.recordMirror(key)
            }
        )
    }

    private func contextKey(
        tabID: UUID = UUID(),
        workspaceID: UUID = UUID(),
        route: MCPReadFileAutoSelectionCoordinator.Route = .bound(connectionID: UUID(), runID: UUID()),
        bindingGeneration: UInt64 = 1
    ) -> MCPReadFileAutoSelectionCoordinator.ContextKey {
        MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            route: route,
            bindingGeneration: bindingGeneration
        )
    }
}

private actor CoordinatorRecorder {
    private var recordedCanonicalBatches: [MCPReadFileAutoSelectionCoordinator.CanonicalBatch] = []
    private var recordedKeys: [MCPReadFileAutoSelectionCoordinator.ContextKey] = []
    private var recordedMirrors: [MCPReadFileAutoSelectionCoordinator.TabMirrorKey] = []

    func recordCanonical(_ batch: MCPReadFileAutoSelectionCoordinator.CanonicalBatch) {
        recordedCanonicalBatches.append(batch)
    }

    func recordCanonicalAndCount(_ batch: MCPReadFileAutoSelectionCoordinator.CanonicalBatch) -> Int {
        recordedCanonicalBatches.append(batch)
        return recordedCanonicalBatches.count
    }

    func canonicalBatches() -> [MCPReadFileAutoSelectionCoordinator.CanonicalBatch] {
        recordedCanonicalBatches
    }

    func recordKey(_ key: MCPReadFileAutoSelectionCoordinator.ContextKey) {
        recordedKeys.append(key)
    }

    func keys() -> [MCPReadFileAutoSelectionCoordinator.ContextKey] {
        recordedKeys
    }

    func recordMirror(_ key: MCPReadFileAutoSelectionCoordinator.TabMirrorKey) -> Int {
        recordedMirrors.append(key)
        return recordedMirrors.count
    }

    func mirrorCount() -> Int {
        recordedMirrors.count
    }
}

private actor CoordinatorAsyncGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
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

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor CoordinatorAsyncSignal {
    private var marked = false

    func mark() {
        marked = true
    }

    func isMarked() -> Bool {
        marked
    }
}
