import Foundation
import OSLog

enum MCPRoutingWaitOutcome: Equatable {
    case routed
    case failed
    case cancelled
    case timedOut(childConnectionObserved: Bool)

    var routed: Bool {
        self == .routed
    }
}

/// Global actor to coordinate "runID became routed" events between:
/// - Producers: `MCPServerViewModel.registerRunIDMapping` (success) and `cleanupRunIDMapping` (failure)
/// - Consumers: `AgentRunCoordinator.releaseGateWhenRouted`
///
/// This replaces the polling loop in `releaseGateWhenRouted` with an event-driven wait.
/// Follows the same continuation-based pattern as `HeadlessAgentConnectionGate`.
actor MCPRoutingWaiter {
    static let shared = MCPRoutingWaiter()

    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "RoutingWaiter")

    /// TTL for terminal state entries (prevents memory leaks from late signals)
    private static let terminalStateTTL: TimeInterval = 120 // 2 minutes

    /// State for each runID being waited on
    private struct WaitingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<MCPRoutingWaitOutcome, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private struct ConnectionObservationContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct WaitState {
        var continuations: [WaitingContinuation] = []
        var connectionObservationContinuations: [ConnectionObservationContinuation] = []
        var expiryTask: Task<Void, Never>? // TTL cleanup for terminal states
        var terminalOutcome: MCPRoutingWaitOutcome?
        var childConnectionObserved = false
    }

    private var waitersByRunID: [UUID: WaitState] = [:]

    // MARK: - Public API

    /// Register a runID before any routing signals are expected.
    /// Idempotent: calling multiple times is a no-op.
    func register(runID: UUID) {
        if waitersByRunID[runID] == nil {
            waitersByRunID[runID] = WaitState()
            log.debug("register: runID=\(runID.uuidString)")
        }
    }

    /// Wait until the runID is routed to a window/connection, or timeout/failure occurs.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time for this waiter to wait. If <= 0, waits indefinitely.
    ///     A timeout affects only this waiter; other waiters remain pending for the run-level signal.
    /// - Returns: `true` if routing succeeded, `false` on failure, cancellation, or this waiter's timeout.
    func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await waitForRoutingOutcome(runID: runID, timeoutSeconds: timeoutSeconds).routed
    }

    /// Waits for the authoritative routing outcome while preserving whether the exact
    /// run-owned child connection had been matched when this waiter's deadline expired.
    func waitForRoutingOutcome(
        runID: UUID,
        timeoutSeconds: TimeInterval
    ) async -> MCPRoutingWaitOutcome {
        // Fast path: already resolved
        if let outcome = waitersByRunID[runID]?.terminalOutcome {
            log.info("waitForRoutingOutcome fast-path: runID=\(runID.uuidString) outcome=\(String(describing: outcome))")
            return outcome
        }

        // Safety check: runID must be registered before waiting.
        guard waitersByRunID[runID] != nil else {
            log.warning("waitForRoutingOutcome: unregistered runID \(runID.uuidString) - returning failure")
            return .failed
        }

        // Wait via continuation with per-waiter identity for targeted timeout/cancellation.
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<MCPRoutingWaitOutcome, Never>) in
                // Check again in case resolved while setting up
                if let outcome = waitersByRunID[runID]?.terminalOutcome {
                    continuation.resume(returning: outcome)
                } else {
                    let timeoutTask: Task<Void, Never>? = if timeoutSeconds > 0 {
                        Task { [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(timeoutSeconds))
                                await self?.handleTimeout(runID: runID, waiterID: waiterID)
                            } catch {
                                // Task cancelled, no-op
                            }
                        }
                    } else {
                        nil
                    }
                    waitersByRunID[runID]?.continuations.append(
                        WaitingContinuation(
                            id: waiterID,
                            continuation: continuation,
                            timeoutTask: timeoutTask
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.handleCancellation(runID: runID, waiterID: waiterID) }
        }
    }

    /// Waits until the exact run-owned pending policy has matched a child connection.
    /// Returns false if routing becomes terminal or this observer is cancelled first.
    func waitUntilChildConnectionObserved(runID: UUID) async -> Bool {
        guard let state = waitersByRunID[runID] else { return false }
        if state.childConnectionObserved { return true }
        if state.terminalOutcome != nil { return false }

        let observerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let current = waitersByRunID[runID] else {
                    continuation.resume(returning: false)
                    return
                }
                if current.childConnectionObserved {
                    continuation.resume(returning: true)
                } else if current.terminalOutcome != nil {
                    continuation.resume(returning: false)
                } else {
                    waitersByRunID[runID]?.connectionObservationContinuations.append(
                        ConnectionObservationContinuation(
                            id: observerID,
                            continuation: continuation
                        )
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelConnectionObservation(runID: runID, observerID: observerID) }
        }
    }

    /// Records the sticky fact that a connection matched the exact run-owned policy.
    /// A later route rollback does not erase this observation; timeout diagnostics must
    /// still classify that run as having observed its child connection.
    func notifyChildConnectionObserved(runID: UUID) async {
        guard var state = waitersByRunID[runID],
              state.terminalOutcome == nil,
              !state.childConnectionObserved
        else { return }

        state.childConnectionObserved = true
        let observers = state.connectionObservationContinuations
        state.connectionObservationContinuations = []
        waitersByRunID[runID] = state
        observers.forEach { $0.continuation.resume(returning: true) }

        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "child_connection_observed"
            )
        #endif
    }

    func childConnectionWasObserved(runID: UUID) -> Bool {
        waitersByRunID[runID]?.childConnectionObserved ?? false
    }

    /// Called when a runID is successfully bound to a connection/window.
    /// Resumes all waiters with `true`.
    func notifyRouted(runID: UUID) async {
        guard resolve(runID: runID, outcome: .routed) else { return }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "routing_waiter_signalled",
                fields: ["outcome": "routed"]
            )
        #endif
    }

    /// Called when routing is known to be impossible (cleanup, cancellation, etc).
    /// Resumes all waiters with `false`.
    func notifyFailed(runID: UUID) async {
        guard resolve(runID: runID, outcome: .failed) else { return }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: runID,
                event: "routing_waiter_signalled",
                fields: ["outcome": "failed"]
            )
        #endif
    }

    // MARK: - Internal

    @discardableResult
    private func resolve(runID: UUID, outcome: MCPRoutingWaitOutcome) -> Bool {
        guard var state = waitersByRunID[runID] else {
            log.warning("resolve: unregistered runID \(runID.uuidString) outcome=\(String(describing: outcome)) - ignoring")
            return false
        }

        // Already resolved - ignore duplicate
        if state.terminalOutcome != nil {
            log.debug("resolve (already terminal): runID=\(runID.uuidString)")
            return false
        }

        // Mark as terminal
        state.terminalOutcome = outcome

        // Schedule TTL cleanup for terminal state
        state.expiryTask = scheduleExpiry(runID: runID)

        // Resume all waiting continuations
        let continuations = state.continuations
        state.continuations = []
        let observationContinuations = state.connectionObservationContinuations
        state.connectionObservationContinuations = []

        // Update state before resuming to avoid races
        waitersByRunID[runID] = state

        log.info("resolve: runID=\(runID.uuidString) outcome=\(String(describing: outcome)) resumingCount=\(continuations.count)")

        for waiter in continuations {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: outcome)
        }
        observationContinuations.forEach { $0.continuation.resume(returning: false) }
        return true
    }

    /// Schedules automatic cleanup of terminal state after TTL expires
    private func scheduleExpiry(runID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.terminalStateTTL * 1_000_000_000))
                await self?.handleExpiry(runID: runID)
            } catch {
                // Task cancelled, no-op
            }
        }
    }

    /// Handles TTL expiry for terminal state entries
    private func handleExpiry(runID: UUID) {
        guard let state = waitersByRunID[runID], state.terminalOutcome != nil else {
            return
        }
        waitersByRunID.removeValue(forKey: runID)
        log.debug("TTL expiry: removed terminal state for runID=\(runID.uuidString)")
    }

    /// Handles timeout of one waiter without terminally resolving the runID.
    private func handleTimeout(runID: UUID, waiterID: UUID) {
        guard var state = waitersByRunID[runID], state.terminalOutcome == nil else { return }
        guard let index = state.continuations.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.continuations.remove(at: index)
        let outcome = MCPRoutingWaitOutcome.timedOut(
            childConnectionObserved: state.childConnectionObserved
        )
        waitersByRunID[runID] = state
        log.info("waiter timeout: runID=\(runID.uuidString) waiterID=\(waiterID.uuidString)")
        waiter.continuation.resume(returning: outcome)
    }

    /// Handles cancellation of a single waiter without resolving the entire runID.
    /// Removes only the specific cancelled waiter and resumes it with `false`.
    /// Other waiters for the same runID are unaffected.
    private func handleCancellation(runID: UUID, waiterID: UUID) {
        guard var state = waitersByRunID[runID], state.terminalOutcome == nil else { return }
        guard let index = state.continuations.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = state.continuations.remove(at: index)
        waitersByRunID[runID] = state
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .cancelled)
    }

    private func cancelConnectionObservation(runID: UUID, observerID: UUID) {
        guard var state = waitersByRunID[runID],
              let index = state.connectionObservationContinuations.firstIndex(where: { $0.id == observerID })
        else { return }
        let observer = state.connectionObservationContinuations.remove(at: index)
        waitersByRunID[runID] = state
        observer.continuation.resume(returning: false)
    }

    /// Clean up state for a runID that is no longer needed.
    /// Call this after the run is fully complete to prevent memory leaks.
    /// Note: With TTL eviction, explicit cleanup is optional but recommended
    /// to free memory sooner when the run is known to be complete.
    func cleanup(runID: UUID) {
        guard let state = waitersByRunID.removeValue(forKey: runID) else { return }
        state.expiryTask?.cancel()
        for waiter in state.continuations {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .failed)
        }
        for connectionObservationContinuation in state.connectionObservationContinuations {
            connectionObservationContinuation.continuation.resume(returning: false)
        }
        log.debug("cleanup: runID=\(runID.uuidString) resumedCount=\(state.continuations.count)")
    }

    #if DEBUG
        func debugContinuationCount(runID: UUID) -> Int {
            waitersByRunID[runID]?.continuations.count ?? 0
        }
    #endif
}

// MARK: - Static Async Methods (for async callers)

extension MCPRoutingWaiter {
    /// Register a runID before any routing signals are expected.
    static func register(runID: UUID) async {
        await shared.register(runID: runID)
    }

    /// Wait until the runID is routed or timeout/failure.
    /// - Parameters:
    ///   - runID: The run identifier to watch for routing.
    ///   - timeoutSeconds: Maximum time to wait. If <= 0, waits indefinitely.
    static func waitUntilRouted(runID: UUID, timeoutSeconds: TimeInterval) async -> Bool {
        await shared.waitUntilRouted(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    static func waitForRoutingOutcome(
        runID: UUID,
        timeoutSeconds: TimeInterval
    ) async -> MCPRoutingWaitOutcome {
        await shared.waitForRoutingOutcome(runID: runID, timeoutSeconds: timeoutSeconds)
    }

    static func waitUntilChildConnectionObserved(runID: UUID) async -> Bool {
        await shared.waitUntilChildConnectionObserved(runID: runID)
    }

    static func notifyChildConnectionObserved(runID: UUID) async {
        await shared.notifyChildConnectionObserved(runID: runID)
    }

    static func childConnectionWasObserved(runID: UUID) async -> Bool {
        await shared.childConnectionWasObserved(runID: runID)
    }

    /// Notify that a runID was successfully routed (async version).
    static func notifyRouted(runID: UUID) async {
        await shared.notifyRouted(runID: runID)
    }

    /// Notify that a runID failed to route (async version).
    static func notifyFailed(runID: UUID) async {
        await shared.notifyFailed(runID: runID)
    }

    /// Clean up state for a completed runID.
    static func cleanup(runID: UUID) async {
        await shared.cleanup(runID: runID)
    }

    #if DEBUG
        static func debugContinuationCount(runID: UUID) async -> Int {
            await shared.debugContinuationCount(runID: runID)
        }
    #endif
}

// MARK: - Fire-and-Forget Signal Methods (for sync callers)

extension MCPRoutingWaiter {
    /// Fire-and-forget notification that runID was successfully routed.
    /// Safe to call from @MainActor or any synchronous context.
    /// Uses Task.detached so the notification survives parent task cancellation.
    nonisolated static func signalRouted(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyRouted(runID: runID)
        }
    }

    /// Fire-and-forget notification that routing failed or will never happen.
    /// Safe to call from @MainActor or any synchronous context.
    /// Uses Task.detached so the notification survives parent task cancellation.
    nonisolated static func signalFailed(_ runID: UUID) {
        Task.detached(priority: .utility) {
            await shared.notifyFailed(runID: runID)
        }
    }
}
