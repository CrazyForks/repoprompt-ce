import Foundation
import OSLog

private func acpLeaseLog(_ message: @autoclosure () -> String) {
    guard AgentRuntimeProviderService.enableDebugLogging else { return }
    print(message())
}

enum MCPBootstrapRoutingProgress: String {
    case waitingForChildConnection = "waiting_for_child_connection"
    case childConnectionObserved = "child_connection_observed"
    case waitingForRouting = "waiting_for_routing"
    case routingConfirmed = "routing_confirmed"
    case routingTimeoutBeforeConnection = "routing_timeout_before_connection"
    case routingTimeoutAfterConnection = "routing_timeout_after_connection"
}

typealias MCPBootstrapRoutingProgressReporter = @MainActor @Sendable (
    MCPBootstrapRoutingProgress
) async -> Void

/// Specification describing the MCP bootstrap requirements for a single run.
/// Used by both agent-mode and headless discovery paths.
struct MCPBootstrapLeaseSpec {
    let runID: UUID
    let gateID: UUID
    let windowID: Int
    let tabID: UUID?
    let clientName: String?

    let restrictedTools: Set<String>
    let additionalTools: Set<String>?
    let oneShot: Bool
    let reason: String?
    let ttl: TimeInterval
    let purpose: MCPRunPurpose
    /// The task label kind for role-aware tool advertisement filtering.
    /// `nil` for non-role connections (discover, delegate-edit, direct MCP).
    let taskLabelKind: AgentModelCatalog.TaskLabelKind?
    /// Whether this run may see external agent control tools even when role filtering would hide them.
    let allowsAgentExternalControlTools: Bool
    /// When true, the queued policy is reserved until the MCP peer PID is a descendant
    /// of an explicitly registered expected agent process.
    let requiresExpectedAgentPID: Bool
}

/// Typed readiness failures for the MCP bootstrap path.
///
/// ``routingUnavailable`` reports that a run's routing wait ended without a confirmed MCP
/// connection (timeout or routing failure). ``provisioningUnavailable`` is reserved for
/// provisioning validation (MCP server start / config bootstrap) and carries no behavioral
/// guarantees on its own.
enum MCPBootstrapReadinessError: Error, Equatable {
    /// MCP provisioning validation (server start / config bootstrap) could not be completed for the
    /// run. Used by provisioning validation; no behavioral guarantees are attached here.
    case provisioningUnavailable
    /// The run's routing wait ended without a confirmed MCP connection — a timeout, a routing
    /// failure, or a lease that was already released or consumed (its routing signal already taken).
    case routingUnavailable
}

extension MCPBootstrapReadinessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .provisioningUnavailable:
            "RepoPrompt MCP provisioning could not be completed: the RepoPrompt MCP server entry could not be created or updated in the Codex configuration, so the agent cannot start with RepoPrompt tools."
        case .routingUnavailable:
            "RepoPrompt MCP routing was not confirmed: the run's routing wait ended without an established MCP connection (timeout or routing failure)."
        }
    }
}

/// Unified lease actor for the MCP bootstrap policy and routing lifecycle.
///
/// Policy installation remains serialized across shared MCP client types. PID-owned policies
/// release the process-global gate as soon as the unique run policy is confirmed armed, allowing
/// independent provider processes to initialize concurrently while their routing waits remain isolated.
/// Legacy policies without expected-PID ownership retain release-on-routed serialization.
///
/// ## Lifecycle
/// 1. `acquire()` — registers routing, acquires the gate, installs and arms the policy
/// 2. PID-owned policies release the gate immediately; routing state stays retained by the lease
/// 3. `releaseWhenRouted()` — waits for routing (or timeout) and cleans retained state
/// 4. `cancelAndCleanup()` — emergency cleanup on cancellation
///
/// ## Additional operations (agent-mode specific)
/// - `releaseWithoutRoutingWait()` — releases gate immediately (when no fresh connection is expected)
/// - `releaseGateForDeferredRouting()` — releases the gate while retaining pending routing/policy state
actor MCPBootstrapLease {
    private let log = Logger(subsystem: "com.repoprompt.mcp", category: "BootstrapLease")

    private var spec: MCPBootstrapLeaseSpec
    private let mcpServerEnabler: (() async -> Void)?
    private let policyInstaller: (MCPBootstrapLeaseSpec) async -> Void
    private let expectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool
    private let policyClearer: (MCPBootstrapLeaseSpec) async -> Void

    private var hasAcquired = false
    private var hasReleased = false
    private var cleanupRequested = false
    private var ownsGate = false
    private var routingRegistered = false
    private var policyInstalled = false
    private var didSignalRoutingFailure = false
    private var didReleaseGate = false
    // Memoized in-flight cleanup operations backing the joinable clear/teardown (see clearPolicyOnce()).
    private var policyClearOperation: Task<Void, Never>?
    private var routingCleanupOperation: Task<Void, Never>?
    #if DEBUG
        // Test-only observability for the join probe (see debugWaitForPolicyClearJoiner()).
        private var debugPolicyClearJoinerCount = 0
        private var debugPolicyClearJoinWaiters: [CheckedContinuation<Void, Never>] = []
    #endif

    /// Creates a unified bootstrap lease.
    ///
    /// - Parameters:
    ///   - spec: The run specification (run ID, gate ID, policy parameters, etc.)
    ///   - mcpServerEnabler: Optional hook to ensure the MCP server is started before acquisition.
    ///     Agent-mode provides this; headless flows typically don't need it.
    ///   - policyInstaller: Installs the per-run connection policy. Defaults to calling
    ///     `ServerNetworkManager.shared.installClientConnectionPolicy(...)`.
    ///   - expectedPIDPolicyArmer: Confirms the intended pending policy is uniquely PID-owned.
    ///   - policyClearer: Clears the per-run connection policy on failure/timeout. Defaults to calling
    ///     `ServerNetworkManager.shared.clearClientConnectionPolicy(...)`.
    init(
        spec: MCPBootstrapLeaseSpec,
        mcpServerEnabler: (() async -> Void)? = nil,
        policyInstaller: ((MCPBootstrapLeaseSpec) async -> Void)? = nil,
        expectedPIDPolicyArmer: ((MCPBootstrapLeaseSpec) async -> Bool)? = nil,
        policyClearer: ((MCPBootstrapLeaseSpec) async -> Void)? = nil
    ) {
        self.spec = spec
        self.mcpServerEnabler = mcpServerEnabler
        self.policyInstaller = policyInstaller ?? Self.defaultPolicyInstaller
        self.expectedPIDPolicyArmer = expectedPIDPolicyArmer ?? Self.defaultExpectedPIDPolicyArmer
        self.policyClearer = policyClearer ?? Self.defaultPolicyClearer
    }

    // MARK: - Core Lifecycle

    /// Atomically acquires the global gate, registers routing, and installs connection policy.
    /// PID-owned policies release the gate after their unique pending policy is confirmed armed.
    /// Returns `false` if cancelled, the gate could not be acquired, or PID ownership could not be armed.
    func acquire() async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() ignored because lease already released")
            return false
        }
        if hasAcquired {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() returning cached success")
            return true
        }

        let runID = spec.runID
        let gateID = spec.gateID
        acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() begin client=\(spec.clientName ?? "<none>") window=\(spec.windowID) purpose=\(spec.purpose.rawValue)")

        // Ensure MCP server is started (agent-mode hook)
        if let enabler = mcpServerEnabler {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) enabling MCP server before gate acquire")
            await enabler()
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) MCP server enabler completed")
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
        }

        // Register routing state before gate acquisition
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) registering routing waiter")
        await MCPRoutingWaiter.register(runID: spec.runID)
        routingRegistered = true
        if shouldAbortAcquire {
            await cancelAndCleanup()
            return false
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "routing_waiter_registered",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "window_id": String(spec.windowID),
                    "tab_id": spec.tabID?.uuidString ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing waiter registered")

        return await withTaskCancellationHandler {
            // Atomically wait + acquire the global gate.
            let gateSnapshot = await HeadlessAgentConnectionGate.snapshot()
            await recordDiagnosticEvent(
                "lease_gate_wait_started",
                fields: [
                    "active_gate_id": gateSnapshot.activeConnectionID?.uuidString ?? "nil",
                    "queue_depth": String(gateSnapshot.queueDepth)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) waiting to acquire global MCP gate")
            let gateAcquisition = await HeadlessAgentConnectionGate.acquireWithDiagnostics(spec.gateID)
            if gateAcquisition.acquired {
                ownsGate = true
            }
            await recordDiagnosticEvent(
                gateAcquisition.acquired ? "lease_gate_acquired" : "lease_gate_acquire_failed",
                fields: [
                    "active_gate_id_at_start": gateAcquisition.activeConnectionIDAtStart?.uuidString ?? "nil",
                    "queue_depth_at_start": String(gateAcquisition.queueDepthAtStart),
                    "queue_depth_at_acquire": String(gateAcquisition.queueDepthAtAcquire),
                    "wait_duration_ms": String(format: "%.3f", gateAcquisition.waitDurationMS)
                ]
            )
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) global MCP gate acquired=\(gateAcquisition.acquired)")
            if !gateAcquisition.acquired || shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() failed, was released, or task cancelled")
                await cancelAndCleanup()
                return false
            }

            // Install per-run connection policy
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) installing connection policy for client=\(spec.clientName ?? "<none>")")
            await policyInstaller(spec)
            policyInstalled = true
            if shouldAbortAcquire {
                await cancelAndCleanup()
                return false
            }
            if spec.requiresExpectedAgentPID {
                let policyArmed = await expectedPIDPolicyArmer(spec)
                await recordDiagnosticEvent(
                    "lease_expected_pid_policy_armed",
                    fields: ["armed": String(policyArmed)]
                )
                guard policyArmed else {
                    acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) expected-PID policy could not be armed")
                    await cancelAndCleanup()
                    return false
                }
                if shouldAbortAcquire {
                    await cancelAndCleanup()
                    return false
                }
            }
            #if DEBUG
                await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                    runID: spec.runID,
                    event: "lease_policy_ready",
                    fields: [
                        "client_name": spec.clientName ?? "nil",
                        "requires_expected_pid": String(spec.requiresExpectedAgentPID),
                        "window_id": String(spec.windowID),
                        "tab_id": spec.tabID?.uuidString ?? "nil"
                    ]
                )
            #endif
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) connection policy installed")
            if shouldAbortAcquire {
                acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) task cancelled or lease released after policy install")
                await cancelAndCleanup()
                return false
            }

            hasAcquired = true
            if spec.requiresExpectedAgentPID {
                // The pending policy is now uniquely run-scoped and PID-owned. Release the
                // process-global gate before spawning so independent sessions may initialize
                // concurrently; the routing waiter and policy remain owned by this lease.
                await releaseOwnedGate(reason: "expected_pid_policy_armed")
            }
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) acquire() completed")
            return true
        } onCancel: {
            acpLeaseLog("[ACP-Runner] lease run=\(runID) gate=\(gateID) acquire() cancellation handler invoked")
            Task { await self.cancelAndCleanup() }
        }
    }

    // MARK: - Release Strategies

    /// Waits for routing and releases legacy gate ownership once established or timed out.
    /// PID-owned policies have already released the gate but retain this routing/policy cleanup.
    /// If routing fails/times out, clears the pending policy entry.
    @discardableResult
    func releaseWhenRouted(
        timeoutMs: Int = 10000,
        progressReporter: MCPBootstrapRoutingProgressReporter? = nil
    ) async -> Bool {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() ignored because lease already released")
            return false
        }
        hasReleased = true

        let ownedGateBeforeWait = ownsGate
        async let pendingReleaseResult = AgentRunCoordinator.shared.releaseGateWhenRouted(
            runID: spec.runID,
            gateID: spec.gateID,
            timeoutMs: timeoutMs
        )
        await progressReporter?(.waitingForChildConnection)
        let connectionObservationTask = progressReporter.map { progressReporter in
            Task {
                guard await MCPRoutingWaiter.waitUntilChildConnectionObserved(
                    runID: spec.runID
                ) else { return false }
                await progressReporter(.childConnectionObserved)
                await progressReporter(.waitingForRouting)
                return true
            }
        }

        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() waiting for routing client=\(spec.clientName ?? "<none>") timeoutMs=\(timeoutMs)")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_started",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "timeout_ms": String(timeoutMs),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        let releaseResult = await pendingReleaseResult
        let childConnectionWasObserved = await MCPRoutingWaiter.childConnectionWasObserved(
            runID: spec.runID
        )
        ownsGate = false
        let routed = releaseResult.routed
        if ownedGateBeforeWait || releaseResult.gateRelease.released {
            let gateReleaseReason = switch releaseResult.routingOutcome {
            case .routed:
                "routing_completed"
            case .cancelled:
                "routing_cancelled"
            case .failed:
                "routing_failed"
            case .timedOut:
                "routing_timeout"
            }
            await recordGateRelease(
                releaseResult.gateRelease,
                reason: gateReleaseReason
            )
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWhenRouted() completed routed=\(routed)")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "routed": String(routed),
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif

        // A concurrent cancelAndCleanup() can run while this waiter is suspended, so route both
        // cleanups through the joinable helpers: they run the policy clear and routing teardown at
        // most once and make every lifecycle path await the same in-flight operation.
        if !routed, policyInstalled {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) routing wait failed or timed out; clearing connection policy")
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }

        let shouldReportConnectionObservation = switch releaseResult.routingOutcome {
        case .routed:
            childConnectionWasObserved
        case let .timedOut(childConnectionObserved):
            childConnectionObserved
        case .failed, .cancelled:
            false
        }
        if shouldReportConnectionObservation {
            let observationWasReported = await connectionObservationTask?.value ?? false
            if !observationWasReported {
                await progressReporter?(.childConnectionObserved)
                await progressReporter?(.waitingForRouting)
            }
        } else {
            connectionObservationTask?.cancel()
            await connectionObservationTask?.value
        }
        switch releaseResult.routingOutcome {
        case .routed:
            await progressReporter?(.routingConfirmed)
        case let .timedOut(childConnectionObserved):
            await progressReporter?(
                childConnectionObserved
                    ? .routingTimeoutAfterConnection
                    : .routingTimeoutBeforeConnection
            )
        case .failed, .cancelled:
            break
        }

        return routed
    }

    /// Fail-closed variant of ``releaseWhenRouted(timeoutMs:)``: waits for the run's routing signal
    /// and throws instead of returning `false`, so a caller cannot silently proceed when the run
    /// never routed.
    ///
    /// For the call that performs the release, this runs the same cleanup as
    /// ``releaseWhenRouted(timeoutMs:)`` — gate release, one-shot policy clear, and routing-waiter
    /// teardown — before throwing, and that cleanup is joinable: a concurrent lifecycle path (e.g. a
    /// racing ``cancelAndCleanup()``) awaits the single in-flight clear/teardown rather than skipping
    /// it, so cleanup has completed before this releasing call throws.
    ///
    /// A routing timeout or failure surfaces as ``MCPBootstrapReadinessError/routingUnavailable``.
    /// A repeated call on a lease that was already released or consumed — its routing signal already
    /// taken, which the Boolean API folds into `false` — fails fast with
    /// ``MCPBootstrapReadinessError/routingUnavailable`` without waiting for the releasing call's
    /// in-flight cleanup.
    ///
    /// Cancellation is attributed from `Task.isCancelled` at the point of failure and surfaces as
    /// `CancellationError`. That attribution is best-effort: the routing wait reports only a Boolean,
    /// so a cancellation that races the timeout may be classified as either outcome.
    func requireRouting(timeoutMs: Int = 10000) async throws {
        let routed = await releaseWhenRouted(timeoutMs: timeoutMs)
        guard routed else {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw MCPBootstrapReadinessError.routingUnavailable
        }
    }

    // MARK: - Joinable Cleanup

    /// Clears the per-run connection policy at most once and lets every caller of this helper join
    /// the same in-flight clear: such a caller never returns before a clear started on another path
    /// (e.g. a racing ``cancelAndCleanup()``) has completed. Fast-path exits that skip this helper —
    /// e.g. a repeated call on an already-released lease — are outside that barrier.
    private func clearPolicyOnce() async {
        if let existing = policyClearOperation {
            #if DEBUG
                debugPolicyClearJoinerCount += 1
                for waiter in debugPolicyClearJoinWaiters {
                    waiter.resume()
                }
                debugPolicyClearJoinWaiters.removeAll()
            #endif
            await existing.value
            return
        }
        let operation = Task { await self.policyClearer(self.spec) }
        policyClearOperation = operation
        await operation.value
    }

    /// Tears down routing state at most once; joinable under the same single-flight rule as
    /// ``clearPolicyOnce()``.
    private func cleanupRoutingOnce() async {
        if let existing = routingCleanupOperation {
            await existing.value
            return
        }
        let operation = Task { await AgentRunCoordinator.shared.cleanupRouting(runID: self.spec.runID) }
        routingCleanupOperation = operation
        await operation.value
    }

    #if DEBUG
        /// Awaits the next caller joining an in-flight ``clearPolicyOnce()`` operation and returns the
        /// observed joiner count, so tests can deterministically prove a second caller entered the
        /// existing-operation branch while the primary clear is still parked.
        func debugWaitForPolicyClearJoiner() async -> Int {
            if debugPolicyClearJoinerCount == 0 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    debugPolicyClearJoinWaiters.append(continuation)
                }
            }
            return debugPolicyClearJoinerCount
        }
    #endif

    /// Releases the global connection gate without waiting for a routing signal.
    /// Use this when no fresh connection is expected but we still need to free the gate.
    func releaseWithoutRoutingWait() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseWithoutRoutingWait() ignored because lease already released")
            return
        }
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releasing gate without waiting for routing")
        await releaseOwnedGate(reason: "without_routing_wait")
        await cleanupRoutingOnce()
    }

    /// Releases only the serialized bootstrap gate while retaining the pending run policy.
    /// Use this for ACP runtimes that do not open their MCP transport until the first prompt.
    func releaseGateForDeferredRouting() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) releaseGateForDeferredRouting() ignored because lease already released")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) deferring route wait until provider prompt")
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "route_wait_deferred",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString
                ]
            )
        #endif
        await releaseOwnedGate(reason: "deferred_routing")
    }

    /// Cleans up deferred routing state after a prompt-deferred provider reaches a terminal state
    /// without needing to report a bootstrap failure.
    func cleanupDeferredRouting() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleanupDeferredRouting() ignored because lease already released")
            return
        }
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cleaning up deferred routing state")
        await performDeferredRoutingCleanup(reason: "deferred_terminal")
    }

    // MARK: - Failure & Cancellation

    /// Hard failure path: signal routing failure and release gate immediately.
    func failAndRelease() async {
        if hasReleased {
            acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() ignored because lease already released")
            return
        }
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndRelease() signaling routing failure")
        await MCPRoutingWaiter.notifyFailed(runID: spec.runID)
        _ = await releaseWhenRouted()
    }

    /// Hard failure path variant used by headless flows.
    func failAndCleanup() async {
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) failAndCleanup() signaling failure and clearing policy")
        await performCancellationCleanup(reason: "failed")
    }

    /// Cancellation path: signal failure, release any gate ownership that materializes,
    /// clear installed policy, and clean up routing. Cleanup remains retryable while a
    /// queued gate acquisition is still suspended.
    func cancelAndCleanup() async {
        cleanupRequested = true
        hasReleased = true
        acpLeaseLog("[ACP-Runner] lease run=\(spec.runID) gate=\(spec.gateID) cancelAndCleanup() signaling failure and releasing gate")
        await performCancellationCleanup(reason: "cancelled")
    }

    private var shouldAbortAcquire: Bool {
        cleanupRequested || hasReleased || Task.isCancelled
    }

    func providerInitializationStarted(provider: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_started",
            fields: ["provider": provider]
        )
    }

    func providerInitializationCompleted(provider: String, outcome: String) async {
        await recordDiagnosticEvent(
            "provider_initialization_completed",
            fields: [
                "provider": provider,
                "outcome": outcome
            ]
        )
    }

    private func releaseOwnedGate(reason: String) async {
        guard ownsGate else { return }
        let result = await HeadlessAgentConnectionGate.completeIfActiveWithDiagnostics(spec.gateID)
        ownsGate = false
        didReleaseGate = didReleaseGate || result.released
        await recordGateRelease(result, reason: reason)
    }

    private func recordGateRelease(
        _ result: HeadlessAgentConnectionGate.ReleaseResult,
        reason: String
    ) async {
        await recordDiagnosticEvent(
            "lease_gate_release",
            fields: [
                "reason": reason,
                "released": String(result.released),
                "active_gate_id_before_release": result.activeConnectionIDBeforeRelease?.uuidString ?? "nil",
                "queue_depth_before_release": String(result.queueDepthBeforeRelease),
                "resumed_waiter": String(result.resumedWaiter)
            ]
        )
    }

    private func recordDiagnosticEvent(
        _ event: String,
        fields: [String: String] = [:]
    ) async {
        #if DEBUG
            var diagnosticFields: [String: String] = [
                "client_name": spec.clientName ?? "nil",
                "connection_id": "nil",
                "gate_id": spec.gateID.uuidString,
                "window_id": String(spec.windowID),
                "tab_id": spec.tabID?.uuidString ?? "nil",
                "requires_expected_pid": String(spec.requiresExpectedAgentPID)
            ]
            for (key, value) in fields {
                diagnosticFields[key] = value
            }
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: event,
                fields: diagnosticFields
            )
            AgentModePerfDiagnostics.event(
                "mcp.routing.\(event)",
                tabID: spec.tabID,
                fields: diagnosticFields
            )
        #endif
    }

    private func performCancellationCleanup(reason: String) async {
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cancelled",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        if routingRegistered, !didSignalRoutingFailure {
            didSignalRoutingFailure = true
            await MCPRoutingWaiter.notifyFailed(runID: spec.runID)
        }
        await releaseOwnedGate(reason: reason)
        if policyInstalled {
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(routingCleanupOperation != nil),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(policyClearOperation != nil)
                ]
            )
        #endif
    }

    private func performDeferredRoutingCleanup(reason: String) async {
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_deferred_cleanup",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "gate_id": spec.gateID.uuidString,
                    "reason": reason
                ]
            )
        #endif
        await releaseOwnedGate(reason: reason)
        if policyInstalled {
            await clearPolicyOnce()
        }
        if routingRegistered {
            await cleanupRoutingOnce()
        }
        #if DEBUG
            await ServerNetworkManager.shared.debugRecordRunRoutingEvent(
                runID: spec.runID,
                event: "lease_cleanup_completed",
                fields: [
                    "client_name": spec.clientName ?? "nil",
                    "reason": reason,
                    "owns_gate": String(ownsGate),
                    "gate_released": String(didReleaseGate),
                    "routing_cleaned": String(routingCleanupOperation != nil),
                    "policy_installed": String(policyInstalled),
                    "policy_cleared": String(policyClearOperation != nil)
                ]
            )
        #endif
    }

    // MARK: - Default Policy Hooks

    private static let defaultExpectedPIDPolicyArmer: (MCPBootstrapLeaseSpec) async -> Bool = { spec in
        guard spec.requiresExpectedAgentPID, let clientName = spec.clientName else {
            return !spec.requiresExpectedAgentPID
        }
        return await ServerNetworkManager.shared.requireExpectedAgentPIDForPendingPolicy(
            for: clientName,
            runID: spec.runID,
            windowID: spec.windowID
        )
    }

    private static let defaultPolicyInstaller: (MCPBootstrapLeaseSpec) async -> Void = { spec in
        guard let clientName = spec.clientName else { return }
        await ServerNetworkManager.shared.installClientConnectionPolicy(
            for: clientName,
            windowID: spec.windowID,
            restrictedTools: spec.restrictedTools,
            oneShot: spec.oneShot,
            reason: spec.reason,
            ttl: spec.ttl,
            tabID: spec.tabID,
            runID: spec.runID,
            additionalTools: spec.additionalTools,
            purpose: spec.purpose,
            taskLabelKind: spec.taskLabelKind,
            allowsAgentExternalControlTools: spec.allowsAgentExternalControlTools,
            requiresExpectedAgentPID: spec.requiresExpectedAgentPID
        )
    }

    private static let defaultPolicyClearer: (MCPBootstrapLeaseSpec) async -> Void = { spec in
        guard let clientName = spec.clientName else { return }
        await ServerNetworkManager.shared.revokeClientConnectionPolicy(
            for: clientName,
            windowID: spec.windowID,
            runID: spec.runID
        )
    }
}
