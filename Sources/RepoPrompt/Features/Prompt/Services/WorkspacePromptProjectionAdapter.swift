import Foundation
import RepoPromptCore

struct WorkspacePromptProjectionAdapter {
    enum Error: Swift.Error, Equatable {
        case missingSelectionProjection
        case missingTokenProjection
        case projectionProvenanceMismatch
        case missingTokenFacts(OccurrenceIdentity)
        case unusedTokenFacts([OccurrenceIdentity])
    }

    struct OccurrenceIdentity: Equatable, Hashable {
        enum Mode: Equatable, Hashable {
            case full
            case slice
            case codemap
        }

        let fileID: UUID
        let standardizedPath: String
        let mode: Mode
        let ranges: [LineRange]
    }

    struct Entry: Equatable {
        let file: WorkspaceFileRecord
        let metadata: WorkspaceSelectionProjection.PathMetadata
        let mode: WorkspaceSelectionProjection.RenderMode
        let ranges: [LineRange]?
        let codemapOrigin: WorkspaceSelectionProjection.CodemapOrigin?
    }

    struct Projection: Equatable {
        let provenance: WorkspaceFileContextCapture.Provenance
        let entries: [Entry]
    }

    struct TokenAwareProjection: Equatable {
        let provenance: WorkspaceFileContextCapture.Provenance
        let selection: WorkspaceSelectionProjection
        let tokens: WorkspaceContextProjection.TokenViews
    }

    typealias CaptureOperation = @Sendable (
        _ selection: StoredSelection,
        _ fileTreeRequest: WorkspaceFileTreeSnapshotRequest,
        _ profile: PathLocateProfile
    ) async throws -> WorkspaceFileContextCapture

    private struct OccurrenceTokenFact {
        let identity: OccurrenceIdentity
        let modificationDate: Date?
        let displayTokens: Int
        let fullTokens: Int
    }

    private let capture: CaptureOperation

    init(store: WorkspaceFileContextStore) {
        capture = { selection, fileTreeRequest, profile in
            try await store.captureWorkspaceFileContext(
                selection: selection,
                fileTreeRequest: fileTreeRequest,
                profile: profile
            )
        }
    }

    init(capture: @escaping CaptureOperation) {
        self.capture = capture
    }

    func project(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay
    ) async throws -> Projection {
        let projection = try await projectContext(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            sections: [.selection],
            materializer: { request in
                try await Self.materializeSelectionProjection(request)
            }
        )
        guard let selectionProjection = projection.selection else {
            throw Error.missingSelectionProjection
        }

        return Projection(
            provenance: selectionProjection.provenance,
            entries: selectionProjection.value.files.compactMap { file in
                guard file.mode != .hidden else { return nil }
                return Entry(
                    file: file.file,
                    metadata: file.metadata,
                    mode: file.mode,
                    ranges: file.ranges,
                    codemapOrigin: file.codemapOrigin
                )
            }
        )
    }

    func projectTokens(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy?,
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot],
        tokenProjectionInput: WorkspaceTokenProjectionInput
    ) async throws -> TokenAwareProjection {
        let tokenFacts = try await Self.makeOccurrenceTokenFacts(
            resolvedEntries: resolvedEntries,
            promptFileEntrySnapshots: promptFileEntrySnapshots
        )
        let projection = try await projectContext(
            selection: selection,
            codeMapUsage: codeMapUsage,
            filePathDisplay: filePathDisplay,
            sections: [.selection, .tokens],
            alternatePolicy: alternatePolicy,
            tokenProjectionInput: tokenProjectionInput,
            materializer: { request in
                try Self.materializeTokenProjection(request, tokenFacts: tokenFacts)
            }
        )
        guard let selectionProjection = projection.selection else {
            throw Error.missingSelectionProjection
        }
        guard let tokenProjection = projection.tokens else {
            throw Error.missingTokenProjection
        }
        guard selectionProjection.provenance == tokenProjection.provenance else {
            throw Error.projectionProvenanceMismatch
        }

        return TokenAwareProjection(
            provenance: selectionProjection.provenance,
            selection: selectionProjection.value,
            tokens: tokenProjection.value
        )
    }

    @MainActor
    func mapToLivePromptEntries(
        _ projection: Projection,
        resolveFile: (WorkspaceFileRecord) -> FileViewModel?
    ) -> [PromptFileEntry] {
        projection.entries.compactMap { entry in
            guard let file = resolveFile(entry.file),
                  file.id == entry.file.id,
                  file.standardizedFullPath == entry.file.standardizedFullPath
            else { return nil }

            return PromptFileEntry(
                file: file,
                isCodemap: entry.mode == .codemap,
                ranges: entry.mode == .slice ? entry.ranges : nil
            )
        }
    }

    private func projectContext(
        selection: StoredSelection,
        codeMapUsage: CodeMapUsage,
        filePathDisplay: FilePathDisplay,
        sections: WorkspaceContextProjectionRequest.Sections,
        alternatePolicy: WorkspaceSelectionProjectionRequest.AlternatePolicy? = nil,
        tokenProjectionInput: WorkspaceTokenProjectionInput = .emptyVirtual,
        materializer: @escaping WorkspaceContextProjectionService.Materializer
    ) async throws -> WorkspaceContextProjection {
        let capture = capture
        let service = WorkspaceContextProjectionService(
            capture: {
                try await capture(
                    selection,
                    WorkspaceFileTreeSnapshotRequest(
                        mode: .none,
                        filePathDisplay: filePathDisplay,
                        onlyIncludeRootsWithSelectedFiles: false,
                        includeLegend: false,
                        showCodeMapMarkers: false,
                        rootScope: .allLoaded
                    ),
                    .uiAssisted
                )
            },
            materializer: materializer
        )
        return try await service.project(.init(
            sections: sections,
            filePathDisplay: filePathDisplay,
            codeMapUsage: codeMapUsage,
            alternatePolicy: alternatePolicy,
            tokenProjectionInput: tokenProjectionInput
        ))
    }

    private static func makeOccurrenceTokenFacts(
        resolvedEntries: [ResolvedPromptFileEntry],
        promptFileEntrySnapshots: [PromptFileEntrySnapshot]
    ) async throws -> [OccurrenceTokenFact] {
        let service = TokenCalculationService()
        var remainingSnapshots = Array(promptFileEntrySnapshots.enumerated())
        var facts: [OccurrenceTokenFact] = []
        facts.reserveCapacity(resolvedEntries.count)

        for entry in resolvedEntries {
            let identity = occurrenceIdentity(for: entry)
            guard let remainingIndex = remainingSnapshots.firstIndex(where: { _, snapshot in
                snapshot.fileID == entry.file.id
                    && snapshot.isCodemapRequested == entry.isCodemap
                    && (snapshot.ranges ?? []) == identity.ranges
            }) else {
                throw Error.missingTokenFacts(identity)
            }
            let snapshot = remainingSnapshots.remove(at: remainingIndex).element
            let evaluation = await service.evaluatePromptEntries([snapshot])
            guard let result = evaluation.entryResultsByFileID[entry.file.id],
                  result.renderMode == evaluationMode(for: identity.mode)
            else {
                throw Error.missingTokenFacts(identity)
            }
            facts.append(OccurrenceTokenFact(
                identity: identity,
                modificationDate: entry.file.modificationDate,
                displayTokens: result.displayTokens,
                fullTokens: result.fullTokens
            ))
        }
        return facts
    }

    private static func materializeTokenProjection(
        _ request: WorkspaceContextProjectionMaterializationRequest,
        tokenFacts: [OccurrenceTokenFact]
    ) throws -> WorkspaceContextProjectionMaterialization {
        var remainingFacts = tokenFacts
        var occurrences: [WorkspaceContextProjectionMaterialization.Occurrence] = []
        occurrences.reserveCapacity(request.occurrences.count)

        for occurrence in request.occurrences {
            let identity = occurrenceIdentity(for: occurrence)
            guard let factIndex = remainingFacts.firstIndex(where: {
                $0.identity == identity
                    && $0.modificationDate == occurrence.file.modificationDate
            }) else {
                throw Error.missingTokenFacts(identity)
            }
            let fact = remainingFacts.remove(at: factIndex)
            occurrences.append(.init(
                id: occurrence.id,
                content: nil,
                tokenFacts: .init(
                    displayTokens: fact.displayTokens,
                    fullTokens: fact.fullTokens
                )
            ))
        }

        guard remainingFacts.isEmpty else {
            throw Error.unusedTokenFacts(remainingFacts.map(\.identity))
        }
        return WorkspaceContextProjectionMaterialization(
            provenance: request.provenance,
            occurrences: occurrences
        )
    }

    private static func occurrenceIdentity(
        for entry: ResolvedPromptFileEntry
    ) -> OccurrenceIdentity {
        let mode: OccurrenceIdentity.Mode = switch entry.mode {
        case .fullFile:
            .full
        case .sliced:
            .slice
        case .codemap:
            .codemap
        }
        return OccurrenceIdentity(
            fileID: entry.file.id,
            standardizedPath: entry.file.standardizedFullPath,
            mode: mode,
            ranges: entry.lineRanges ?? []
        )
    }

    private static func occurrenceIdentity(
        for occurrence: WorkspaceContextProjectionMaterializationRequest.Occurrence
    ) -> OccurrenceIdentity {
        let mode: OccurrenceIdentity.Mode = switch occurrence.mode {
        case .full:
            .full
        case .slice:
            .slice
        case .codemap:
            .codemap
        }
        return OccurrenceIdentity(
            fileID: occurrence.file.id,
            standardizedPath: occurrence.file.standardizedFullPath,
            mode: mode,
            ranges: occurrence.ranges
        )
    }

    private static func evaluationMode(
        for mode: OccurrenceIdentity.Mode
    ) -> PromptEntriesEvaluation.RenderMode {
        switch mode {
        case .full: .full
        case .slice: .slice
        case .codemap: .codemap
        }
    }

    private static func materializeSelectionProjection(
        _ request: WorkspaceContextProjectionMaterializationRequest
    ) async throws -> WorkspaceContextProjectionMaterialization {
        WorkspaceContextProjectionMaterialization(
            provenance: request.provenance,
            occurrences: request.occurrences.map { occurrence in
                let displayTokens = occurrence.mode == .codemap
                    ? occurrence.codemap?.tokens ?? 0
                    : 0
                return .init(
                    id: occurrence.id,
                    content: nil,
                    tokenFacts: .init(
                        displayTokens: displayTokens,
                        fullTokens: 0
                    )
                )
            }
        )
    }
}
