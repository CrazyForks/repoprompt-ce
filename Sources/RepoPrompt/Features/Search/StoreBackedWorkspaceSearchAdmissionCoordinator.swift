import Foundation

actor StoreBackedWorkspaceSearchAdmissionCoordinator {
    static let shared = StoreBackedWorkspaceSearchAdmissionCoordinator()

    #if DEBUG
        struct Snapshot: Equatable {
            let hasActivePermit: Bool
            let waiterCount: Int
        }
    #endif

    private struct PermitAcquisition {
        let storeKey: ObjectIdentifier
        let searchMode: SearchMode
        let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        let waited: Bool
        let queueDepth: Int
        let waiterCount: Int
    }

    private enum WaiterState {
        case waiting(
            continuation: CheckedContinuation<PermitAcquisition, Error>,
            searchMode: SearchMode,
            lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
        )
    }

    private struct Lane {
        var hasActivePermit = false
        var waiterOrder: [UUID] = []
        var waiterStates: [UUID: WaiterState] = [:]
    }

    private var lanes: [ObjectIdentifier: Lane] = [:]
    private var pendingWaiterIDs = Set<UUID>()
    private var cancelledWaiterIDs = Set<UUID>()
    #if DEBUG
        private var permitAcquiredHandlerForTesting: (@Sendable (WorkspaceFileContextStore) async -> Void)?
    #endif

    func withBroadSearchPermit<T>(
        for store: WorkspaceFileContextStore,
        searchMode: SearchMode,
        operation: () async throws -> T
    ) async throws -> T {
        let storeKey = ObjectIdentifier(store)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        let initialMetrics = metrics(for: storeKey)
        let waitState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Search.broadAdmissionWait,
            EditFlowPerf.Dimensions(
                searchMode: searchMode.rawValue,
                queueDepth: initialMetrics.queueDepth,
                waiterCount: initialMetrics.waiterCount
            )
        )

        let acquisition: PermitAcquisition
        do {
            acquisition = try await acquire(
                for: storeKey,
                searchMode: searchMode,
                lifecycleCorrelation: lifecycleCorrelation
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.broadAdmissionWait,
                waitState,
                EditFlowPerf.Dimensions(
                    outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                    searchMode: searchMode.rawValue,
                    queueDepth: acquisition.queueDepth,
                    waiterCount: acquisition.waiterCount
                )
            )
        } catch {
            let currentMetrics = metrics(for: storeKey)
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.broadAdmissionWait,
                waitState,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    searchMode: searchMode.rawValue,
                    queueDepth: currentMetrics.queueDepth,
                    waiterCount: currentMetrics.waiterCount
                )
            )
            throw error
        }

        defer { release(acquisition) }
        try Task.checkCancellation()
        #if DEBUG
            if let permitAcquiredHandlerForTesting {
                await permitAcquiredHandlerForTesting(store)
            }
        #endif
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(
        for storeKey: ObjectIdentifier,
        searchMode: SearchMode,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) async throws -> PermitAcquisition {
        try Task.checkCancellation()
        var lane = lanes[storeKey] ?? Lane()
        if !lane.hasActivePermit {
            lane.hasActivePermit = true
            lanes[storeKey] = lane
            let acquisition = PermitAcquisition(
                storeKey: storeKey,
                searchMode: searchMode,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false,
                queueDepth: lane.waiterOrder.count,
                waiterCount: lane.waiterStates.count
            )
            recordPermitAcquired(acquisition)
            return acquisition
        }

        let waiterID = UUID()
        pendingWaiterIDs.insert(waiterID)
        defer {
            pendingWaiterIDs.remove(waiterID)
            cancelledWaiterIDs.remove(waiterID)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.enqueueWaiter(
                        id: waiterID,
                        for: storeKey,
                        continuation: continuation,
                        searchMode: searchMode,
                        lifecycleCorrelation: lifecycleCorrelation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: storeKey) }
        }
    }

    private func enqueueWaiter(
        id: UUID,
        for storeKey: ObjectIdentifier,
        continuation: CheckedContinuation<PermitAcquisition, Error>,
        searchMode: SearchMode,
        lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation?
    ) {
        if cancelledWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }

        var lane = lanes[storeKey] ?? Lane()
        if !lane.hasActivePermit {
            lane.hasActivePermit = true
            lanes[storeKey] = lane
            let acquisition = PermitAcquisition(
                storeKey: storeKey,
                searchMode: searchMode,
                lifecycleCorrelation: lifecycleCorrelation,
                waited: false,
                queueDepth: lane.waiterOrder.count,
                waiterCount: lane.waiterStates.count
            )
            recordPermitAcquired(acquisition)
            continuation.resume(returning: acquisition)
            return
        }

        lane.waiterStates[id] = .waiting(
            continuation: continuation,
            searchMode: searchMode,
            lifecycleCorrelation: lifecycleCorrelation
        )
        lane.waiterOrder.append(id)
        lanes[storeKey] = lane
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionWaitBegan,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                searchMode: searchMode.rawValue,
                queueDepth: lane.waiterOrder.count,
                waiterCount: lane.waiterStates.count
            )
        )
    }

    private func cancelWaiter(id: UUID, for storeKey: ObjectIdentifier) {
        guard var lane = lanes[storeKey],
              let state = lane.waiterStates.removeValue(forKey: id)
        else {
            if pendingWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
            return
        }
        lane.waiterOrder.removeAll { $0 == id }
        lanes[storeKey] = lane
        switch state {
        case let .waiting(continuation, searchMode, lifecycleCorrelation):
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.broadAdmissionPermitCancelled,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    searchMode: searchMode.rawValue,
                    queueDepth: lane.waiterOrder.count,
                    waiterCount: lane.waiterStates.count
                )
            )
            continuation.resume(throwing: CancellationError())
        }
    }

    private func release(_ acquisition: PermitAcquisition) {
        guard var lane = lanes[acquisition.storeKey], lane.hasActivePermit else { return }
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionPermitReleased,
            correlation: acquisition.lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                searchMode: acquisition.searchMode.rawValue,
                queueDepth: lane.waiterOrder.count,
                waiterCount: lane.waiterStates.count
            )
        )

        while !lane.waiterOrder.isEmpty {
            let waiterID = lane.waiterOrder.removeFirst()
            guard let state = lane.waiterStates.removeValue(forKey: waiterID) else { continue }
            switch state {
            case let .waiting(continuation, searchMode, lifecycleCorrelation):
                lanes[acquisition.storeKey] = lane
                let next = PermitAcquisition(
                    storeKey: acquisition.storeKey,
                    searchMode: searchMode,
                    lifecycleCorrelation: lifecycleCorrelation,
                    waited: true,
                    queueDepth: lane.waiterOrder.count,
                    waiterCount: lane.waiterStates.count
                )
                recordPermitAcquired(next)
                continuation.resume(returning: next)
                return
            }
        }

        lanes.removeValue(forKey: acquisition.storeKey)
    }

    private func recordPermitAcquired(_ acquisition: PermitAcquisition) {
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.broadAdmissionPermitAcquired,
            correlation: acquisition.lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                outcome: acquisition.waited ? "acquiredAfterWait" : "immediate",
                searchMode: acquisition.searchMode.rawValue,
                queueDepth: acquisition.queueDepth,
                waiterCount: acquisition.waiterCount
            )
        )
    }

    private func metrics(for storeKey: ObjectIdentifier) -> (queueDepth: Int, waiterCount: Int) {
        guard let lane = lanes[storeKey] else { return (0, 0) }
        return (lane.waiterOrder.count, lane.waiterStates.count)
    }

    #if DEBUG
        func snapshot(for store: WorkspaceFileContextStore) -> Snapshot {
            let lane = lanes[ObjectIdentifier(store)]
            return Snapshot(
                hasActivePermit: lane?.hasActivePermit == true,
                waiterCount: lane?.waiterStates.count ?? 0
            )
        }

        func setPermitAcquiredHandlerForTesting(
            _ handler: (@Sendable (WorkspaceFileContextStore) async -> Void)?
        ) {
            permitAcquiredHandlerForTesting = handler
        }
    #endif
}
