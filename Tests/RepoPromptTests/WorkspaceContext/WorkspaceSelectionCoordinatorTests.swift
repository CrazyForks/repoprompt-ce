import Combine
@testable import RepoPrompt
import XCTest

@MainActor
final class WorkspaceSelectionCoordinatorTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testActiveSelectionSnapshotReturnsActiveTabSelectionAndFlushesPendingUIWhenRequested() {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"], codemapAutoEnabled: true)
        let pending = StoredSelection(
            selectedPaths: ["/tmp/pending.swift"],
            autoCodemapPaths: ["/tmp/dependency.swift"],
            slices: ["/tmp/pending.swift": [LineRange(start: 1, end: 3)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = pending
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        let unflushed = coordinator.activeSelectionSnapshot(flushPendingUI: false)
        XCTAssertEqual(unflushed.tabID, harness.tabID)
        XCTAssertEqual(unflushed.selection, initial)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 0)

        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let flushed = coordinator.activeSelectionSnapshot(flushPendingUI: true)
        XCTAssertEqual(flushed.tabID, harness.tabID)
        XCTAssertEqual(flushed.selection, pending)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: pending, source: .uiFlush))
    }

    func testPersistActiveSelectionWritesActiveTabAndEmitsChange() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let next = StoredSelection(
            selectedPaths: ["/tmp/next.swift"],
            autoCodemapPaths: ["/tmp/next_dependency.swift"],
            slices: ["/tmp/next.swift": [LineRange(start: 4, end: 8)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
        let persisted = await coordinator.persistActiveSelection(next, source: .runtimeMutation, mirrorToUI: true)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, next)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .runtimeMutation))
        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
    }

    func testPersistVirtualSelectionStoresImmediatelyAndEmitsVirtualChange() {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let next = StoredSelection(
            selectedPaths: ["/tmp/virtual.swift"],
            slices: ["/tmp/virtual.swift": [LineRange(start: 2, end: 5)]],
            codemapAutoEnabled: false
        )
        let harness = CoordinatorHarness(initialSelection: initial)
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)
        var changes: [WorkspaceSelectionCoordinator.Change] = []
        coordinator.changes
            .sink { changes.append($0) }
            .store(in: &cancellables)

        let persisted = coordinator.persistVirtualSelection(next, for: harness.tabID)

        XCTAssertEqual(persisted, next)
        XCTAssertEqual(harness.manager.composeTab(with: harness.tabID)?.selection, next)
        XCTAssertEqual(harness.manager.updateStoredOnlyCallCount, 1)
        XCTAssertEqual(changes.last, .init(tabID: harness.tabID, selection: next, source: .virtual))
    }

    func testApplyingSelectionMirrorGuardSuppressesFlushPublication() async {
        let initial = StoredSelection(selectedPaths: ["/tmp/initial.swift"])
        let pending = StoredSelection(selectedPaths: ["/tmp/pending.swift"])
        let harness = CoordinatorHarness(initialSelection: initial)
        harness.manager.pendingUISelection = pending
        let coordinator = WorkspaceSelectionCoordinator(workspaceManager: harness.manager, store: harness.store)

        await coordinator.withApplyingSelectionMirror {
            XCTAssertTrue(coordinator.isApplyingSelectionMirror)
            let snapshot = coordinator.activeSelectionSnapshot(flushPendingUI: true)
            XCTAssertEqual(snapshot.selection, initial)
            XCTAssertEqual(harness.manager.publishSnapshotCallCount, 0)
        }

        XCTAssertFalse(coordinator.isApplyingSelectionMirror)
        let flushed = coordinator.activeSelectionSnapshot(flushPendingUI: true)
        XCTAssertEqual(flushed.selection, pending)
        XCTAssertEqual(harness.manager.publishSnapshotCallCount, 1)
    }

    func testSaveSnapshotPrefersMatchingCanonicalSelectionOverStaleUISnapshot() {
        let activeTabID = UUID()
        let liveUI = StoredSelection(
            selectedPaths: ["/tmp/stale.swift"],
            slices: ["/tmp/stale.swift": [LineRange(start: 1, end: 2)]],
            codemapAutoEnabled: true
        )
        let canonical = StoredSelection(selectedPaths: ["/tmp/fixture.swift"], codemapAutoEnabled: false)

        let stored = StoredSelection(selectedPaths: ["/tmp/stored.swift"])

        let decision = WorkspaceManagerViewModel.selectionForSaveSnapshot(
            liveUISelection: liveUI,
            storedSelection: stored,
            canonicalSelection: canonical,
            canonicalTabID: activeTabID,
            activeTabID: activeTabID
        )

        XCTAssertEqual(decision.selection, canonical)
        XCTAssertEqual(decision.owner, .canonicalCoordinator)
    }

    func testSaveSnapshotFallsBackToStoredSelectionWhenCanonicalIsUnusable() {
        let liveUI = StoredSelection(selectedPaths: ["/tmp/live.swift"])
        let stored = StoredSelection(selectedPaths: ["/tmp/stored.swift"], codemapAutoEnabled: false)
        let canonical = StoredSelection(selectedPaths: ["/tmp/other.swift"], codemapAutoEnabled: false)
        let activeTabID = UUID()
        let scenarios: [(name: String, canonicalSelection: StoredSelection?, canonicalTabID: UUID?)] = [
            ("canonical tab does not match", canonical, UUID()),
            ("canonical selection is missing", nil, nil)
        ]

        for scenario in scenarios {
            let decision = WorkspaceManagerViewModel.selectionForSaveSnapshot(
                liveUISelection: liveUI,
                storedSelection: stored,
                canonicalSelection: scenario.canonicalSelection,
                canonicalTabID: scenario.canonicalTabID,
                activeTabID: activeTabID
            )

            XCTAssertEqual(decision.selection, stored, scenario.name)
            XCTAssertEqual(decision.owner, .storedComposeTab, scenario.name)
        }
    }
}

@MainActor
private final class CoordinatorHarness {
    let store = WorkspaceFileContextStore()
    let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: WorkspaceFileContextStore())
    let tabID = UUID()
    let manager: FakeWorkspaceSelectionManager

    init(initialSelection: StoredSelection) {
        let tab = ComposeTabState(id: tabID, name: "Test", selection: initialSelection)
        let workspace = WorkspaceModel(
            name: "Test Workspace",
            repoPaths: [],
            composeTabs: [tab],
            activeComposeTabID: tabID
        )
        manager = FakeWorkspaceSelectionManager(workspace: workspace, fileManager: fileManager)
    }
}

@MainActor
private final class FakeWorkspaceSelectionManager: WorkspaceSelectionHost {
    var activeWorkspace: WorkspaceModel?
    let fileManager: WorkspaceFilesViewModel
    var pendingUISelection: StoredSelection?
    private(set) var publishSnapshotCallCount = 0
    private(set) var updateStoredOnlyCallCount = 0

    init(workspace: WorkspaceModel, fileManager: WorkspaceFilesViewModel) {
        activeWorkspace = workspace
        self.fileManager = fileManager
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        activeWorkspace?.composeTabs.first(where: { $0.id == id })
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {
        publishSnapshotCallCount += 1
        guard commitToMemory,
              let pendingUISelection,
              var workspace = activeWorkspace,
              let activeID = workspace.activeComposeTabID,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == activeID })
        else { return }
        workspace.composeTabs[index].selection = pendingUISelection
        if touchModified {
            workspace.composeTabs[index].lastModified = Date()
        }
        activeWorkspace = workspace
    }

    func updateComposeTabStoredOnly(_ tab: ComposeTabState) {
        updateStoredOnlyCallCount += 1
        guard var workspace = activeWorkspace,
              let index = workspace.composeTabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        workspace.composeTabs[index] = tab
        activeWorkspace = workspace
    }
}
