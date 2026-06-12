# MCP Tool Throughput Remediation: Plan

## Goal
Improve MCP throughput across same-connection bursts, parallel agent threads, long transcripts, multiple windows, Git-heavy workflows, and ranged file reads without weakening watcher freshness, lifecycle ownership, cancellation, or call/result/run-end ordering. The roadmap must first isolate and fix watcher correctness defects, then remove measured duplicate work, introduce selective resource-keyed ordinary-tool concurrency, and establish safe partial reconstruction and cross-window sharing boundaries.

## Background

### Planning decisions

- Selective same-connection concurrency for ordinary tools is in scope now; the plan must define static classes and true resource ownership rather than merely raise the existing ordinary limit.
- Watcher startup is intended to be infallible from the workspace lifecycle's perspective. Any startup or recovery defect must be isolated, made observable, regression-tested, and fixed before partial reconstruction work proceeds.
- Performance acceptance is diagnostics-first: deterministic correctness/work-count invariants and repeatable median/P95 reporting should precede broad wall-clock CI thresholds.

### MCP admission, ownership, and publication

- Admission currently has only `.ordinary` and `.fileSearch`; only canonical `file_search` selects the four-permit search lane, while every other tool enters the per-connection ordinary lane (`Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift:343-372`, `:11623-11636`).
- Different connections can already overlap against the same window, so connection FIFO is not sufficient shared-state protection. Exact connection/lifecycle/window identity is revalidated after queueing, and active permits remain owned until the operation unwinds (`MCPConnectionManager.swift:11639-11759`, `:12614-12762`).
- The permit includes provider execution, result formatting, observer-result encoding, and awaited call/completion observers; final SDK encoding and socket delivery occur after release (`MCPConnectionManager.swift:9915-10009`, `:10659-10791`, `:12845-12859`).
- Completion observers synchronously bridge to Agent Mode transcript mutation on `MainActor`, preserving call-before-result and result-before-run-end ordering (`MCPConnectionManager.swift:3117-3159`; `Sources/RepoPrompt/Infrastructure/AI/Agents/AgentToolTracker.swift:146-250`; `Sources/RepoPrompt/Features/AgentMode/Runtime/AgentRunTerminalCommitBarrier.swift:145-169`). Any future publication decoupling therefore needs an explicit ordered owner and terminal drain barrier.
- Static capability and execution-contract catalogs exist but are not the scheduling policy (`Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolCapabilities.swift:3-128`; `Sources/RepoPrompt/Infrastructure/MCP/Policies/MCPToolExecutionContract.swift:5-133`). There is no exhaustive canonical-tool-to-call-lane test today.

### Watcher correctness and canonical delta boundary

- Native stream creation/start failures are logged and returned from a `Void` function; callers cannot prove activation (`Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift:229-286`). Workspace hydration can advance independently because watcher startup is later post-catalog work (`Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:2518-2539`; `Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceManagerViewModel.swift:5319-5334`, `:5557-5679`).
- The initial crawl is committed before a watcher starts at `kFSEventStreamEventIdSinceNow`, leaving a mutation gap with no replay (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:2489-2585`; `FileSystemService+FSEvents.swift:248-258`).
- If parallel and serial recovery scans both fail, the target can remain unresolved while watermark publication is gated only by the quiet retry set (`FileSystemService+FSEvents.swift:1317-1337`, `:1396-1424`). Freshness can therefore complete without a reliable baseline.
- Ordered, per-root canonical application already exists through `WorkspaceFileSystemIngressCoordinator`, with awaitable applied cuts and root-lifetime fencing (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift:3-9`, `:135-216`).
- `WorkspaceAppliedIndexBatchEvent` already carries per-root generation, exact upserts/removals/modifications, unload, and `requiresFullResync` (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/Models/WorkspaceFileContextModels.swift:374-422`). It becomes suitable for partial reconstruction only after startup/recovery gaps and full-resync signaling are corrected.

### Search invalidation, reconstruction, and window duplication

- Catalog generations are root-kind selective, but every topology invalidation clears all cached scope snapshots and the whole path-match worker (`WorkspaceFileContextStore.swift:4576-4618`, `:4697-4733`). Session-bound scopes also validate against the global `allLoaded` generation (`WorkspaceFileContextStore.swift:4530-4557`).
- Applied-index events already support incremental UI projection with generation-gap/full-resync fallback, but `WorkspaceSearchService` currently treats them as complete rebuild triggers (`Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift:1215-1303`, `:1555-1788`; `Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceSearchService.swift:72-108`, `:240-377`).
- Each window owns a separate `WorkspaceFileContextStore`, search service, file projection, caches, search lane, crawl, ingress pipeline, and watcher graph; only the MCP listener is shared (`Sources/RepoPrompt/App/WindowState.swift:88-143`; `Sources/RepoPrompt/App/WindowStateComposition.swift:27-40`, `:84-116`). The same physical root is therefore crawled, watched, indexed, invalidated, and cached once per window.
- The safe target boundary is immutable, generation-tagged per-root state: private batch application, atomic publication, root-lifetime fencing, conservative rebuild on gaps/drops/dirty recovery, and reference-held old generations for in-flight readers. Multi-window sharing should begin with root snapshots/watchers while preserving per-window projections and leases.

### Long-thread critical path

- Claude, Codex, and ACP completion correlation scan transcript items by invocation ID/signature/name while the MCP permit is held (`Sources/RepoPrompt/Features/AgentMode/Runtime/ToolTracking/ClaudeAgentToolTrackingHandler.swift:505-760`; `Sources/RepoPrompt/Features/AgentMode/Runtime/Codex/CodexAgentModeCoordinator.swift:4500-4628`; `Sources/RepoPrompt/Features/AgentMode/Runtime/Runners/ACPIntegratedAgentModeRunner.swift:1204-1376`).
- Each source-item commit retains the previous array and always rebuilds `Set(updatedItems.map(\.id))`, creating an O(thread length) floor even for one append/replace (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel+TabSession.swift:896-984`, `:1028-1035`, `:1183-1227`).
- Persistence is debounced and derived refresh is usually scheduled, so the immediate optimization target is correlation, array/map mutation, and MainActor scheduling—not synchronous disk persistence (`Sources/RepoPrompt/Features/AgentMode/ViewModels/AgentModeViewModel.swift:2747-2758`, `:7527-7605`, `:9591-9608`).

### Git and `read_file` amplification

- MCP Git requests eagerly repeat root/repository/default/worktree setup and then expand into multiple fresh `/usr/bin/git` processes; standard/deep artifact publication builds summary inputs and then repeats the full build (`Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPGitToolProvider.swift:161-205`, `:287-330`, `:1000-1206`; `Sources/RepoPrompt/Infrastructure/VCS/GitDiff/GitDiffSnapshotPublisher.swift:59-101`; `Sources/RepoPrompt/Infrastructure/VCS/GitService.swift:2256-2384`).
- Existing reuse includes VCS resolution/backend/layout caches, a coalesced login-shell environment cache, and fingerprint-keyed diff text, but Git process construction, environment merging, command fan-out, and sequential multi-repository loops remain (`Sources/RepoPrompt/Infrastructure/VCS/VCSService.swift:37-165`; `Sources/RepoPrompt/Infrastructure/Process/CLIEnvironmentCache.swift:11-113`; `Sources/RepoPrompt/Infrastructure/VCS/GitDiff/GitDiffEngine.swift:304-432`).
- `read_file` uses in-memory catalog routing, then reopens and decodes the entire file for every successful interactive read; the decoded-content cache used by search is not reused (`Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift:2901-3044`; `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+ContentLoading.swift:557-655`, `:853-1163`).
- The complete string is split, sliced, rejoined, wrapped, and formatted after the read, so small ranges still pay whole-file I/O/decoding plus full-string processing (`Sources/RepoPrompt/Infrastructure/MCP/ViewModels/MCPServerViewModel.swift:3694-3805`; `Sources/RepoPrompt/Infrastructure/MCP/ToolOutputFormatter.swift:850-878`, `:1695-1759`).

### Measurement and prior art

- Existing diagnostics already decompose many local read/search stages and expose limiter snapshots, but there is no single request identity spanning frame acceptance, permit lifecycle, MainActor queue/body time, observer attribution, final encoding/write, proxy delivery, and client completion (`Tests/RepoPromptTests/MCP/MCPReadSearchLatencyDiagnosticsGuardTests.swift:469-517`, `:588-611`, `:1985-2012`).
- The long-transcript benchmark is DEBUG-only, opt-in, warmup-based, and report-oriented; it does not assert wall-clock thresholds (`Tests/RepoPromptTests/AgentMode/Transcript/AgentTranscriptCrawlRefreshBenchmarkTests.swift:1-45`, `:153-187`, `:383-405`).
- PR #155 intentionally established bounded `file_search` admission and freshness-flight sharing; this plan must preserve those guarantees while extending classified ordinary-tool admission ([PR #155](https://github.com/repoprompt/repoprompt-ce/pull/155), merge commit [`83374cfd`](https://github.com/repoprompt/repoprompt-ce/commit/83374cfd5b563456bf000a9aabb93874522a713c), throughput commit [`1aa1ab8b`](https://github.com/repoprompt/repoprompt-ce/commit/1aa1ab8b18ef1e1f551a85237cc7926c71ca9869)).
- The investigation report is the primary synthesis and contains the initial phased roadmap, metrics, invariants, external architecture references, and preventive test inventory (`docs/investigations/mcp-tool-throughput-after-pr155-2026-06-11.md`).

## Progress

- [x] Phase 0 / WI-1 — watcher startup and recovery correctness
- [x] Phase 0 / WI-2 — correlated request timeline and permit lifecycle events
- [x] Phase 0 / WI-3 — invalidation, rebuild, Git, and read work-count diagnostics plus baseline capture
- [x] Phase 1 / WI-4 — selective catalog eviction and duplicate-clear removal
- [x] Phase 1 / WI-5 — Git request-scoped context, single artifact build, artifact scope and ingress fixes
- [x] Phase 1 / WI-6 — long-thread transcript critical path
- [x] Phase 1 / WI-7 — `read_file` content reuse and freshness narrowing
- [x] Phase 2 / WI-8 — off-MainActor provider projection
- [x] Phase 2 / WI-9 — bounded Git concurrency and command consolidation
- [x] Phase 2 / WI-10 — classified, resource-keyed ordinary-tool admission
- [x] Phase 3 / WI-11 — immutable per-root catalog shards and scope composition
- [x] Phase 3 / WI-12 — canonical delta application to shards
- [x] Phase 3 / WI-13 — per-root path indexes with global top-k merge
- [ ] Phase 3 / WI-14 — shared physical-root service across windows
- [ ] Phase 3 / WI-15 — (conditional) decoupled completion publication with ordered ownership

## Guardrails and shared invariants

These apply to every work item and are the review checklist for each PR in this plan:

- A request observes one immutable root/scope generation, never a partially applied event batch.
- Cache identity includes root lifetime and all catalog-affecting configuration, not only path. Event-generation gaps, dropped/ambiguous events, or dirty recovery force a conservative rebuild.
- Root unload removes state from new views but cannot invalidate references held by in-flight readers; one cancelled waiter cannot cancel shared coalesced work other waiters still need.
- Result publication preserves call-before-result and result-before-run-end ordering. No work item may wrap `fireToolCompletedObservers` in an untracked `Task` (`Tests/RepoPromptTests/MCP/MCPReadSearchLatencyDiagnosticsGuardTests.swift:724-728` rejects this).
- Admission is bounded by the true shared resource (store, repository, window mutation owner, process pool); connection FIFO is a client-ordering policy, not shared-state protection.
- No TTL-based freshness reuse anywhere: a callback can be accepted immediately after a completed cut, so time-based reuse violates the per-request lower-bound freshness contract.
- Heavy filesystem, Git, parsing, encoding, and index work must not run on MainActor, transport loops, or state-owner actors.
- Every cache invalidation carries a typed reason and affected dependency set; unqualified global clears are prohibited without metrics and a correctness rationale.
- PR #155's bounded `file_search` admission, freshness-flight sharing, and their regression tests (`StoreBackedWorkspaceSearchTests`, `StoreBackedWorkspaceSearchConcurrencyMatrixTests`) must keep passing unchanged in every phase.
- Performance claims are diagnostics-first: each optimization PR must show work-count deltas (commands spawned, scopes evicted, bytes decoded, items scanned) from the WI-2/WI-3 instrumentation, not only wall-clock anecdotes.

## Phase 0 — Correctness and measurement prerequisites

Phase 0 gates everything else. WI-1 is a current correctness defect independent of performance; WI-2/WI-3 produce the evidence that sizes the Phase 1–2 work and selects Phase 2 lane capacities.

### Work Item 1 — Watcher startup and recovery correctness

**Scope**

- Close the crawl-to-`SinceNow` gap: capture an FSEvents cut before the initial crawl or run a post-watcher-start reconciliation scan before declaring the initial index reliable (`WorkspaceFileContextStore.swift:2489-2585`; `FileSystemService+FSEvents.swift:248-258`; `WorkspaceFilesViewModel.swift:2518-2539`).
- Make watcher activation provable to the workspace lifecycle: stream creation/start failures must propagate to callers instead of returning from a `Void` function (`FileSystemService+FSEvents.swift:229-286`).
- Keep failed recovery scans explicitly dirty: when parallel and serial folder scans both fail, the target must block or flag freshness until reconciled, with bounded retry/backoff and an escalation path to `requiresFullResync` (`FileSystemService+FSEvents.swift:1317-1424`). Wire up or remove the orphaned `shouldScheduleSafetyNetScan` helper.

**Key files:** `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift`, `Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift`, `Sources/RepoPrompt/Features/WorkspaceFiles/ViewModels/WorkspaceFilesViewModel.swift`, `Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileSystemIngressCoordinator.swift`.

**Done when**

- A regression test mutates the filesystem between crawl completion and watcher start and proves a subsequent freshness-coherent search observes the mutation.
- A regression test forces both recovery scans to fail and proves freshness cannot report completion while the target is unresolved, then proves reconciliation or full-resync recovers it.
- Watcher start failure is observable from workspace lifecycle state, not only logs.

**Validation:** `make dev-test FILTER=WorkspaceFileContextStoreTests`, `make dev-test FILTER=StoreBackedWorkspaceSearchTests`, plus the new regressions; `make dev-lint`.

**Integration risks:** reconciliation scans add startup cost on large roots — measure and bound them; dirty-state blocking must not deadlock freshness for permanently unreadable folders (escalate to full resync instead).

### Work Item 2 — Correlated request timeline and permit lifecycle events

**Scope**

- Propagate one request identity (JSON-RPC request ID + connection generation + app invocation ID) from frame acceptance through SDK decode, limiter queue/acquire/release, MainActor scheduled/entered/exited markers, provider execution, each observer callback, result byte counts, SDK encode, transport write, and proxy stdout commit.
- Add explicit `permit_queued` / `permit_acquired` / `permit_released` events with lane, queue depth, owner resource/window/run, and outcome.
- Add observer-level attribution: token/type, serial position, queue delay, duration, correlation path used (ID/signature/name fallback), and scanned item count.
- Expose publication ownership state separately (provider-active, network-scope-active, permit-active, publication-pending, terminal-barrier), since VM idle currently precedes completion publication for Agent Mode runs.
- DEBUG-only, surfaced through the existing `app_settings` perf-diagnostics group.

**Key files:** `Sources/RepoPrompt/Infrastructure/MCP/MCPConnectionManager.swift`, `Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsReadSearchLatency.swift`, `Sources/RepoPrompt/Infrastructure/MCP/UnixSocketMCPTransport.swift`, `Sources/RepoPromptShared/MCP/JSONRPCBridgeLedger.swift`, `Sources/RepoPromptMCP/main.swift`.

**Done when**

- A guard test joins every stage for a single invocation by the shared identity.
- The five workload matrices produce correlated reports: same-connection ordinary burst, same-connection mixed ordinary/search, distinct connections to one window, distinct windows, and short-versus-long Agent Mode transcript.

**Validation:** `make dev-test FILTER=MCPReadSearchLatencyDiagnosticsGuardTests`, `make dev-test FILTER=PersistentMCPDistinctConnectionConcurrencyTests`; live check via `rpce-cli-debug` with `agent_mode.perf_diagnostics_enabled`.

**Integration risks:** instrumentation overhead in hot paths — keep event construction allocation-light and compiled out of release builds; identity propagation must not change permit ordering.

### Work Item 3 — Invalidation, rebuild, Git, and read work-count diagnostics plus baseline

**Scope**

- Typed invalidation events: reason, affected root IDs/kinds, exact scopes evicted; rebuild counters and timings for catalog filter/sort/materialization, UI index preparation, C-index build, and stale discarded work.
- Freshness counters: noop/join/pending-successor/debounce-cancellation counts, flush calls, watcher batch sizes, per-root wait durations.
- Per-window duplication counters: physical roots, watchers, crawls, and freshness flights per shared root.
- Git per-invocation counters: command count, process queue wait, spawn time, bytes, parse time, repository — with command-count assertions for common status/diff/artifact modes (e.g. warm status = 3–4 processes, standard/deep artifact = 14+U today).
- `read_file` counters: read bytes versus returned bytes/lines, decode time, cache hit rate (zero until WI-7).
- Capture and check in a baseline report for the WI-2 workload matrices so later PRs can show deltas.

**Done when:** counters appear in DEBUG diagnostics; Git command-count assertions exist and pass against current behavior; the baseline report is recorded.

**Validation:** `make dev-test FILTER=WorkspaceFileContextStoreTests`, new Git command-count tests, `make dev-smoke` for live counter sanity.

**Integration risks:** command-count assertions are intentionally brittle — they must be updated deliberately by WI-5/WI-9, which is the point; keep them DEBUG/test-only so they don't block unrelated work.

## Phase 1 — Remove proven waste without changing concurrency semantics

These four items are independent of each other and can land in any order once Phase 0's diagnostics exist. None changes lane counts or ordering semantics.

### Work Item 4 — Selective catalog eviction and duplicate-clear removal

**Scope**

- Replace `clearSearchCatalogSnapshotCache()` in topology invalidation with selective eviction: static scopes evict only when their included root kinds intersect the changed kinds; the path-match worker invalidates per affected scope, not globally (`WorkspaceFileContextStore.swift:4575-4618,4697-4733`).
- Session-bound scopes: drop the global `allLoaded` validation token; derive a token from the scope's selectors plus an ordered `(canonical identity, rootID, lifetime, generation)` dependency vector, recomputed when roots load/unload/replace (`WorkspaceFileContextStore.swift:4530-4557`).
- Remove the per-file clear inside `ensureIndexedFiles` (`:2025-2062`) and consolidate root-unload's triple invalidation (`:2637-2818`) into one publication-finalization cycle.
- Replace the 16-scope cap's clear-all with single-entry (LRU or oldest) eviction (`:4543-4556`).

**Done when:** retention tests warm visible, Git-data, supplemental, and two session-bound scopes, mutate one root kind/root ID, and assert exactly which scopes hit and which rebuild; a `_git_data` artifact publication retains the warm visible-workspace catalog; invalidation diagnostics show reason-scoped evictions only.

**Validation:** `make dev-test FILTER=WorkspaceFileContextStoreTests`, `make dev-test FILTER=WorkspaceSearchServiceTests`, `make dev-test FILTER=StoreBackedWorkspaceSearchTests`.

**Integration risks:** session-scope dependency vectors are the subtle part — a new matching root has a new rootID, so dependencies must be recomputed from selectors, not stale IDs. The existing regression expecting an unchanged session-snapshot generation (`WorkspaceFileContextStoreTests.swift:2442-2472`) will need a deliberate semantic update.

### Work Item 5 — Git request-scoped context, single artifact build, artifact scope and ingress fixes

**Scope**

- Request-scoped Git resolution context: fetch `rootRefs` once per request (currently 3×), skip default-repo resolution when `repo_key` fully determines the target, memoize backend/worktree/branch/HEAD lookups per repository within the request, and build worktree DTOs lazily (`MCPGitToolProvider.swift:161-205,287-330,1376-1421`).
- Standard/deep artifact publication: one `buildSnapshotInputs(generateDiffText: true)` pass with the summary derived from it, removing the duplicated fingerprint/stats/untracked scans (`GitDiffSnapshotPublisher.swift:59-101`).
- Fix artifact auto-selection to resolve with `.visibleWorkspacePlusGitData` instead of the default `.visibleWorkspace`, which excludes the `_git_data` candidate paths (`MCPServerViewModel+SelectionEngine.swift:194-228`; `MCPGitToolProvider.swift:422-432`).
- Narrow the post-publication ingress await from `.visibleWorkspacePlusGitData` to the absolute snapshot path / `_git_data` root (`MCPGitToolProvider.swift:1083-1159`).
- Replace the full retention-manifest scan on every publish with a lightweight count/index while preserving the 25-snapshot limit (`GitDiffDataMaintenance.swift:245-309`).

**Done when:** WI-3 command-count assertions drop accordingly (standard/deep artifact from `14+U` toward `7+U`; status prelude to one `rootRefs` and no redundant default resolution); a regression test proves `MAP.txt`/`all.patch` actually get selected after artifact publication.

**Validation:** `make dev-test FILTER=CodexIntegrationConfigurationTests` (Git-adjacent), new Git provider tests, live `rpce-cli-debug` Git smoke against a repo with a linked worktree and untracked files.

**Integration risks:** request-scoped memoization must not outlive the request (branch/HEAD can change between requests); the artifact-selection scope change alters user-visible selection behavior and needs an explicit test, not just the scope constant change.

### Work Item 6 — Long-thread transcript critical path

**Scope**

- Maintain per-session indexes for invocation ID and pending canonical signature so Claude/Codex/ACP completion correlation stops scanning `session.items` linearly while the MCP permit is held (`ClaudeAgentToolTrackingHandler.swift:505-760`; `CodexAgentModeCoordinator.swift:4500-4628`; `ACPIntegratedAgentModeRunner.swift:1204-1376`).
- Restrict fallback scans to the active turn and record fallback frequency (via WI-2 observer attribution).
- Make append/replace update the ephemeral payload map and live-ID set incrementally instead of retaining the whole previous array and rebuilding `Set(updatedItems.map(\.id))` per mutation (`AgentModeViewModel+TabSession.swift:896-984,1028-1035,1183-1227`).

**Done when:** the transcript benchmark (`AgentTranscriptCrawlRefreshBenchmarkTests`) extended with permit-correlated sampling shows per-tool-event transcript cost no longer scaling with thread length; ordering and cancellation tests pass unchanged.

**Validation:** `make dev-test FILTER=AgentTranscriptCrawlRefreshBenchmarkTests`, Agent Mode lifecycle suites (`make dev-test FILTER=AgentModeRunServiceLifecycleTests`), live long-thread session via `agent_run` smoke.

**Integration risks:** index/state desync with the item array is the failure mode — indexes must be rebuilt on any non-incremental commit path (session load, full replace) and verified by an invariant check in DEBUG.

### Work Item 7 — `read_file` content reuse and freshness narrowing

**Scope**

- Introduce a byte-bounded interactive read cache keyed by root/file identity plus content fingerprint/epoch, or safely share the existing decoded search snapshot machinery; invalidate on file epoch, root lifetime, and memory pressure (`WorkspaceFileContextStore.swift:2901-3044`; `FileSystemService+ContentLoading.swift:557-1163`).
- Move full-string line splitting/slicing off MainActor and avoid re-splitting on cache hits (`MCPServerViewModel.swift:3694-3805`) — coordinate with WI-8 rather than duplicating it.
- Narrow freshness: parse explicit paths before the barrier and await only resolved containing roots; add a cut-preserving no-op fast path when the captured watcher watermark and publication sequence are already satisfied (`WorkspaceFileContextStore.swift:1343-1430`; `StoreBackedWorkspaceSearch.swift:45-68`).
- Reuse `metadata.runPurpose` and one request-scoped roots snapshot; collapse the duplicate exact/folder/general lookup fallbacks (`MCPServerViewModel+TabContext.swift:1482-1516`).

**Done when:** WI-3 counters show repeated ranged reads of an unchanged file hitting the cache with read-bytes ≈ returned-bytes on hits; explicit-path operations no longer flush unrelated roots; freshness no-op fast-path count is nonzero in steady-state workloads.

**Validation:** `make dev-test FILTER=WorkspaceFileContextStoreTests`, new read-cache tests, `make dev-smoke`.

**Integration risks:** cache coherence with edits — the fingerprint/epoch key must observe the same invalidation stream as the search decoded cache; the freshness fast path must be proven cut-preserving (no TTL semantics) by a regression that accepts a callback immediately after a completed cut.

## Phase 2 — Move work off MainActor and add classified bounded concurrency

WI-8/WI-9 reduce the cost of work wherever it is scheduled; WI-10 then changes scheduling, sized by Phase 0 measurements. Landing WI-10 before WI-8/WI-9 would mostly relocate queueing into MainActor and the Git process pool, so keep this order.

### Work Item 8 — Off-MainActor provider projection

**Scope**

- Split provider state capture from computation: snapshot required window/session state on MainActor; move Git diff splitting/hunk parsing/truncation, MAP loading and excerpting, file line splitting/slicing, large DTO construction, and `Value` encoding to Sendable worker contexts (`MCPGitToolProvider.swift:6-14,208-449,1292-1363`; `MCPFileToolProvider.swift:344-375`; `MCPServerViewModel.swift:3730-3805`).
- Keep selection/UI mutation and transcript publication on MainActor; ordering is untouched.
- Use WI-2's scheduled/entered/exited markers to prove executor wait and CPU body both fell — i.e. work was removed from MainActor, not wrapped in another task.

**Done when:** MainActor occupancy per Git/read invocation drops in the WI-2 matrices; distinct-window concurrent bursts show reduced cross-window interference; all ordering tests pass.

**Validation:** `make dev-test FILTER=MCPReadSearchLatencyDiagnosticsGuardTests`, Git/file provider suites, `make dev-smoke-launch` with two windows.

**Integration risks:** state snapshots must be value copies, not references to MainActor-isolated objects; watch for accidental retention of large strings in Sendable closures.

### Work Item 9 — Bounded Git concurrency and command consolidation

**Scope**

- Bounded multi-repository concurrency (initially 2–4) with deterministic output order and per-repo error isolation for status/diff/artifact loops (`MCPGitToolProvider.swift:595-649,1000-1081,1218-1288`); add per-repository and process-global Git process budgets so agent fanout cannot spawn unbounded processes.
- Command consolidation: porcelain-v2 `git status --porcelain=v2 -z --branch --untracked-files=all` replacing the 3–4 command status chain where compatible; eliminate the duplicate `rev-parse HEAD` when `baseRef == HEAD`; run numstat/name-status concurrently (an `async let` overload already exists but is unused, `GitService.swift:1634-1718`); batch untracked-file diffs instead of one `--no-index` process per file; `GIT_OPTIONAL_LOCKS=0` for verified read-only operations.
- Reuse a prepared immutable base environment instead of merging the shell snapshot per command (`GitService.swift:2255-2373`).

**Done when:** WI-3 Git command-count assertions are updated downward and pass; multi-repo status latency scales sub-linearly with repository count in the baseline matrix; mutation operations remain serialized per repository.

**Validation:** new/updated Git command-count tests, `make dev-provider-test`, live smoke against a multi-repo workspace.

**Integration risks:** porcelain-v2 parsing differences (renames, submodules, detached HEAD) need fixture coverage before swapping; concurrency must respect the budgets under agent fanout or it recreates the amplification it fixes.

### Work Item 10 — Classified, resource-keyed ordinary-tool admission

**Scope**

- Replace the single ordinary limit-1 lane (`MCPConnectionManager.swift:11623-11636`) with a static classification: mutating selection/prompt/workspace/settings, lifecycle, approval, and interactive tools stay serial/exclusive; small read/snapshot tools get a bounded lane (initial 2–4 per connection); Git reads get a bounded lane (1–2 per repository plus the WI-9 global process budget); canonical `file_search` keeps its existing four-permit lane and per-store broad gate.
- Add resource-keyed correctness limits where the connection lane no longer provides them: per-window mutation ownership, per-store read/search admission, per-repository Git admission. Connection FIFO remains a client-ordering policy only.
- Classification is a static, reviewed table covering every canonical tool, enforced by an exhaustive test (no tool may default into a concurrent lane); capacities are chosen from Phase 0 baseline data, resolving the open question below.

**Gate B capacity evidence (2026-06-11):** the WI-3 baseline recorded ordinary capacity 1, `file_search` capacity 4 per connection, and search capacity 4 per store, while live latency remained deferred because no app was launched. WI-10 therefore uses the conservative lower bounds: exclusive tools remain 1, small reads use 2 per connection and 2 per window/store, Git reads use 2 per connection plus 1 active request per repository, and canonical `file_search` remains unchanged at 4 per connection and 4 per store. These values are fixed by the WI-10 classification tests so later tuning requires an explicit evidence-backed change.

**Done when:** the exhaustive tool-to-lane test exists; same-connection mixed bursts show reads/Git overlapping while mutations stay exclusive; PR #155's admission/freshness tests pass unchanged; WI-2 matrices show end-to-end latency improving rather than queue relocation to MainActor/Git/store lanes.

**Validation:** `make dev-test FILTER=PersistentMCPDistinctConnectionConcurrencyTests`, `make dev-test FILTER=StoreBackedWorkspaceSearchTests`, new lane-classification and overlap tests, full `make dev-test`, live smoke with parallel agent threads.

**Integration risks:** this is the highest-blast-radius scheduling change in the plan. Hard gate: do not land until WI-8/WI-9 metrics show MainActor and Git process contention reduced, otherwise the new permits just queue elsewhere. Duplicate/mis-tracked tool-card protection currently provided by limit-1 (see the comment at `MCPConnectionManager.swift:11623`) must be re-established by explicit per-window/run ownership before the lane opens.

## Phase 3 — Partial reconstruction and multi-window architecture

Phase 3 items are sequential (WI-11 → WI-12 → WI-13; WI-14 after WI-11) and all gate on WI-1. WI-15 is conditional on Phase 0/2 evidence.

### Work Item 11 — Immutable per-root catalog shards and scope composition

Immutable `RootCatalogShard` keyed by `(canonical/config identity, rootID, lifetimeID, topologyGeneration)`: private batch build, atomic publication, in-flight readers retain old generations via ARC. Scopes compose shard references and k-way merge already-sorted root arrays (`O(F log R)`) or expose lazy composite views. Ship with a DEBUG shadow comparison against the current full rebuild until outputs and ordering are byte-identical, plus generation-retention diagnostics and a backstop cap. **Done when** shadow parity holds across the retention test matrix and topology churn rebuilds only affected shards.

### Work Item 12 — Canonical delta application to shards

Consume `WorkspaceAppliedIndexBatchEvent` (exact upserts/removals/modifications, generation, unload, `requiresFullResync` — `WorkspaceFileContextModels.swift:374-422`) against a private shard builder: require contiguous generations per root lifetime, fall back to root-snapshot rebuild on any gap, unload, overflow, dirty recovery, or full-resync signal. Choose patch-versus-rebuild by delta-size thresholds measured in WI-3. Raw FSEvents never patch search state directly. **Hard dependency on WI-1** — deltas are not authoritative until the startup and failed-scan gaps are fixed.

**Landed threshold:** patch only one logical catalog record. WI-3 establishes rebuild work counts but no measured multi-record crossover, so larger batches rebuild authoritatively rather than relying on an invented threshold.

### Work Item 13 — Per-root path indexes with global top-k merge

One C `PathSearchIndex` per immutable root shard; rebuild only changed roots; extend the C boundary to expose comparable scores and deterministic tie-breaks so per-root candidates merge into the current global ordering. Root unload becomes dropping an index reference instead of the current filter/remap/discard/full-rebuild (`WorkspaceSearchService.swift:269-383`; `PathSearchIndex.swift:79-110`). Never mutate a shared C index in place under readers.

**PR boundary (80/20):** this pull request lands through WI-13. WI-14 and WI-15 remain intentionally deferred follow-up work; WI-15 still requires post-WI-6/WI-8 measurement evidence before implementation.

### Work Item 14 — Shared physical-root service across windows

Process-level ref-counted root catalog service keyed by physical identity (canonical path + volume/file identity) plus all catalog-affecting configuration and a process-owned access lease. First milestone shares crawl, watcher, ingress, and immutable shard history only; windows keep projections, selections, leases, search admission, and session-worktree bindings. Decoded-content cache sharing is explicitly deferred (see Open Questions). **Done when** a real two-window test on one root shows one crawl/watcher/freshness-flight set and independent window teardown leaves the other window's access intact.

### Work Item 15 — (Conditional) decoupled completion publication

Only if Phase 0/2 timelines still show permit-held publication as a top cost after WI-6/WI-8: introduce a sequence-numbered per-run event queue with retained publication ownership, release the execution permit only after synchronous enqueue, and require run-end/fallback/cancellation to drain or explicitly cancel the queue. WI-2's publication-ownership states are the prerequisite evidence.

## Integration sequence and validation gates

1. **Gate A (after Phase 0):** WI-1 regressions green; correlated timeline joins all stages; baseline report checked in. No Phase 1 performance claims before this.
2. **Phase 1 items (WI-4–7)** land independently, each showing a work-count delta against the baseline. After each: focused `make dev-test FILTER=…`, `make dev-lint`, and the live CE MCP smoke flow when MCP/Agent-Mode surfaces changed.
3. **Gate B (before WI-10):** WI-8 and WI-9 metrics show MainActor occupancy and Git process counts reduced; per-window/run mutation ownership design reviewed. Lane capacities fixed from baseline data.
4. **Gate C (before WI-12+):** WI-1 stable in the field (no dirty-recovery escapes in diagnostics), WI-11 shadow parity proven.
5. **Final validation per phase:** full `make dev-test`, `make dev-provider-test`, `make dev-lint`, `make dev-smoke-launch`, and the long-thread + multi-window live matrices from WI-2.
6. Every PR follows the contribution preflight (`.agents/skills/rpce-contribution-check/scripts/preflight.sh`); local `docs/investigations/*` artifacts stay unstaged.

## Open Questions

- Exact lane capacities (WI-10), Git process budgets (WI-9), delta-size rebuild thresholds (WI-12), and retained-generation caps (WI-11) should be selected from the WI-2/WI-3 correlated diagnostics and baseline matrices rather than guessed in advance; the initial numbers in the work items are starting points to be confirmed at Gate B/C.
- The first cross-window shared-root milestone (WI-14) stops at crawl/watcher/immutable catalog ownership; decoded-content cache sharing remains a later decision after identity, configuration, security-lease, and teardown semantics are proven.
- Whether WI-15 (decoupled completion publication) is needed at all is decided by post-WI-6/WI-8 measurements, not in advance.

## References

- `docs/investigations/mcp-tool-throughput-after-pr155-2026-06-11.md`
- `docs/plans/codex-steering-composer-implementation-2026-06-10.md`
- [Apple FSEvents Programming Guide](https://leopard-adc.pepas.com/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FSEvents_ProgGuide.pdf)
- [Watchman file queries](https://facebook.github.io/watchman/docs/file-query) and [recrawl behavior](https://facebook.github.io/watchman/docs/troubleshooting)
- [Lucene `ReferenceManager`](https://lucene.apache.org/core/4_0_0/core/org/apache/lucene/search/ReferenceManager.html)
- [Git status](https://git-scm.com/docs/git-status) and [`git cat-file`](https://git-scm.com/docs/git-cat-file)
