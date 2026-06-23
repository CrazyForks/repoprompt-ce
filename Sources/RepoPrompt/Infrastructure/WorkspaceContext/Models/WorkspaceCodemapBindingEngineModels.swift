import Foundation

struct WorkspaceCodemapBindingEnginePolicy: Equatable {
    static let `default` = WorkspaceCodemapBindingEnginePolicy()

    let maximumRootCount: Int
    let maximumActiveRequestCountPerRoot: Int
    let maximumActiveRequestCount: Int
    let maximumOwnerCountPerRoot: Int
    let maximumActiveRequestCountPerOwner: Int
    let maximumQueuedRequestCountPerRoot: Int
    let maximumQueuedRequestCountPerOwner: Int
    let maximumQueuedRequestCount: Int
    let maximumActiveTaskCountPerRoot: Int
    let maximumActiveTaskCountPerOwner: Int
    let maximumActiveTaskCount: Int
    let maximumManifestAdoptionRecordCount: Int
    let maximumRetainedManifestRecordCountPerRoot: Int
    let maximumRetainedManifestRecordCount: Int
    let maximumManifestAdoptionLeaseCountPerRoot: Int
    let maximumManifestAdoptionLeaseCount: Int
    let maximumManifestAdoptionLeaseByteCountPerRoot: UInt64
    let maximumManifestAdoptionLeaseByteCount: UInt64
    let maximumCapabilityRetryCount: Int
    let maximumValidatedWorktreeByteCount: Int64
    let maximumRetainedSourceByteCountPerRoot: UInt64
    let maximumRetainedSourceByteCountPerOwner: UInt64
    let maximumRetainedSourceByteCount: UInt64
    let maximumConcurrentMaterializationCountPerRoot: Int
    let maximumConcurrentMaterializationCountPerOwner: Int
    let maximumConcurrentMaterializationCount: Int
    let maximumConsecutiveDemandAdmissions: Int

    init(
        maximumRootCount: Int = 64,
        maximumActiveRequestCountPerRoot: Int = 1024,
        maximumActiveRequestCount: Int = 4096,
        maximumOwnerCountPerRoot: Int = 256,
        maximumActiveRequestCountPerOwner: Int = 64,
        maximumQueuedRequestCountPerRoot: Int = 1024,
        maximumQueuedRequestCountPerOwner: Int = 64,
        maximumQueuedRequestCount: Int = 4096,
        maximumActiveTaskCountPerRoot: Int = 1024,
        maximumActiveTaskCountPerOwner: Int = 64,
        maximumActiveTaskCount: Int = 4096,
        maximumManifestAdoptionRecordCount: Int = 8192,
        maximumRetainedManifestRecordCountPerRoot: Int = 8192,
        maximumRetainedManifestRecordCount: Int = 32768,
        maximumManifestAdoptionLeaseCountPerRoot: Int = 4096,
        maximumManifestAdoptionLeaseCount: Int = 16384,
        maximumManifestAdoptionLeaseByteCountPerRoot: UInt64 = 256 * 1024 * 1024,
        maximumManifestAdoptionLeaseByteCount: UInt64 = 1024 * 1024 * 1024,
        maximumCapabilityRetryCount: Int = 1,
        maximumValidatedWorktreeByteCount: Int64 = 8 * 1024 * 1024,
        maximumRetainedSourceByteCountPerRoot: UInt64 = 128 * 1024 * 1024,
        maximumRetainedSourceByteCountPerOwner: UInt64 = 32 * 1024 * 1024,
        maximumRetainedSourceByteCount: UInt64 = 512 * 1024 * 1024,
        maximumConcurrentMaterializationCountPerRoot: Int = 16,
        maximumConcurrentMaterializationCountPerOwner: Int = 4,
        maximumConcurrentMaterializationCount: Int = 64,
        maximumConsecutiveDemandAdmissions: Int = 8
    ) {
        precondition(maximumRootCount > 0)
        precondition(maximumActiveRequestCountPerRoot > 0)
        precondition(maximumActiveRequestCount > 0)
        precondition(maximumOwnerCountPerRoot > 0)
        precondition(maximumActiveRequestCountPerOwner > 0)
        precondition(maximumQueuedRequestCountPerRoot > 0)
        precondition(maximumQueuedRequestCountPerOwner > 0)
        precondition(maximumQueuedRequestCount > 0)
        precondition(maximumActiveTaskCountPerRoot > 0)
        precondition(maximumActiveTaskCountPerOwner > 0)
        precondition(maximumActiveTaskCount > 0)
        precondition(maximumManifestAdoptionRecordCount > 0)
        precondition(maximumRetainedManifestRecordCountPerRoot > 0)
        precondition(maximumRetainedManifestRecordCount > 0)
        precondition(maximumManifestAdoptionLeaseCountPerRoot > 0)
        precondition(maximumManifestAdoptionLeaseCount > 0)
        precondition(maximumManifestAdoptionLeaseByteCountPerRoot > 0)
        precondition(maximumManifestAdoptionLeaseByteCount > 0)
        precondition(maximumCapabilityRetryCount >= 0 && maximumCapabilityRetryCount <= 1)
        precondition(maximumValidatedWorktreeByteCount > 0)
        precondition(maximumRetainedSourceByteCountPerRoot > 0)
        precondition(maximumRetainedSourceByteCountPerOwner > 0)
        precondition(maximumRetainedSourceByteCount > 0)
        precondition(maximumConcurrentMaterializationCountPerRoot > 0)
        precondition(maximumConcurrentMaterializationCountPerOwner > 0)
        precondition(maximumConcurrentMaterializationCount > 0)
        precondition(maximumConsecutiveDemandAdmissions > 0)
        self.maximumRootCount = maximumRootCount
        self.maximumActiveRequestCountPerRoot = maximumActiveRequestCountPerRoot
        self.maximumActiveRequestCount = maximumActiveRequestCount
        self.maximumOwnerCountPerRoot = maximumOwnerCountPerRoot
        self.maximumActiveRequestCountPerOwner = maximumActiveRequestCountPerOwner
        self.maximumQueuedRequestCountPerRoot = maximumQueuedRequestCountPerRoot
        self.maximumQueuedRequestCountPerOwner = maximumQueuedRequestCountPerOwner
        self.maximumQueuedRequestCount = maximumQueuedRequestCount
        self.maximumActiveTaskCountPerRoot = maximumActiveTaskCountPerRoot
        self.maximumActiveTaskCountPerOwner = maximumActiveTaskCountPerOwner
        self.maximumActiveTaskCount = maximumActiveTaskCount
        self.maximumManifestAdoptionRecordCount = maximumManifestAdoptionRecordCount
        self.maximumRetainedManifestRecordCountPerRoot = maximumRetainedManifestRecordCountPerRoot
        self.maximumRetainedManifestRecordCount = maximumRetainedManifestRecordCount
        self.maximumManifestAdoptionLeaseCountPerRoot = maximumManifestAdoptionLeaseCountPerRoot
        self.maximumManifestAdoptionLeaseCount = maximumManifestAdoptionLeaseCount
        self.maximumManifestAdoptionLeaseByteCountPerRoot = maximumManifestAdoptionLeaseByteCountPerRoot
        self.maximumManifestAdoptionLeaseByteCount = maximumManifestAdoptionLeaseByteCount
        self.maximumCapabilityRetryCount = maximumCapabilityRetryCount
        self.maximumValidatedWorktreeByteCount = maximumValidatedWorktreeByteCount
        self.maximumRetainedSourceByteCountPerRoot = maximumRetainedSourceByteCountPerRoot
        self.maximumRetainedSourceByteCountPerOwner = maximumRetainedSourceByteCountPerOwner
        self.maximumRetainedSourceByteCount = maximumRetainedSourceByteCount
        self.maximumConcurrentMaterializationCountPerRoot = maximumConcurrentMaterializationCountPerRoot
        self.maximumConcurrentMaterializationCountPerOwner = maximumConcurrentMaterializationCountPerOwner
        self.maximumConcurrentMaterializationCount = maximumConcurrentMaterializationCount
        self.maximumConsecutiveDemandAdmissions = maximumConsecutiveDemandAdmissions
    }
}

struct WorkspaceCodemapBindingRootRegistration: Equatable {
    let capabilityRequest: WorkspaceCodemapGitCapabilityRequest
    let catalogGeneration: UInt64
    let ingressGeneration: UInt64
    let language: LanguageType

    init(
        rootID: UUID,
        rootLifetimeID: UUID,
        loadedRootURL: URL,
        catalogGeneration: UInt64,
        ingressGeneration: UInt64,
        language: LanguageType
    ) {
        capabilityRequest = WorkspaceCodemapGitCapabilityRequest(
            rootID: rootID,
            rootLifetimeID: rootLifetimeID,
            loadedRootURL: loadedRootURL
        )
        self.catalogGeneration = catalogGeneration
        self.ingressGeneration = ingressGeneration
        self.language = language
    }
}

struct WorkspaceCodemapManifestBindingCandidate {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
}

struct WorkspaceCodemapBindingCatalogClient: @unchecked Sendable {
    let resolveManifestBinding: @Sendable (
        WorkspaceCodemapRootEpoch,
        String
    ) async -> WorkspaceCodemapManifestBindingCandidate?

    static let unavailable = WorkspaceCodemapBindingCatalogClient { _, _ in nil }
}

struct WorkspaceCodemapValidatedSourceReaderClient: @unchecked Sendable {
    let read: @Sendable (
        WorkspaceCodemapArtifactBindingIdentity,
        GitBlobLStatFingerprint,
        Int64,
        UUID
    ) async throws -> ValidatedRawFileContentSnapshot
}

struct WorkspaceCodemapBindingDemand: Equatable {
    let owner: WorkspaceCodemapLiveDemandOwner
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let catalogGeneration: UInt64
    let pathGeneration: UInt64
    let ingressGeneration: UInt64
    let priority: CodeMapArtifactBuildPriority
    let language: LanguageType
}

enum WorkspaceCodemapBindingRegistrationResult {
    case registered(adoptedReadyCount: Int)
    case exactDuplicate
    case unavailable(WorkspaceCodemapGitCapabilityState)
    case busy
    case failed
}

enum WorkspaceCodemapBindingDemandRejection: Equatable {
    case rootNotRegistered
    case capabilityUnavailable
    case rootEpochMismatch
    case rootPathMismatch
    case invalidIdentity
    case catalogGenerationMismatch
    case requestGenerationInvalid
    case stalePathGeneration
    case staleIngressGeneration
    case languageMismatch
    case classificationMismatch
    case sourceAuthorityUnavailable
    case overlayRejected
    case staleCompletion
}

enum WorkspaceCodemapBindingDemandUnavailableReason: Equatable {
    case unsupportedFileType
    case missing
    case securityExcluded
    case nonRegular
    case oversized
    case transient
    case terminalArtifact(WorkspaceCodemapLiveArtifactOutcome)
}

enum WorkspaceCodemapBindingDemandResult {
    case ready(WorkspaceCodemapLiveReadySnapshot)
    case alreadyReady(WorkspaceCodemapLiveReadySnapshot)
    case unavailable(WorkspaceCodemapBindingDemandUnavailableReason)
    case busy(retryAfterMilliseconds: Int?)
    case rejected(WorkspaceCodemapBindingDemandRejection)
    case cancelled
}

enum WorkspaceCodemapBindingManifestState: Equatable {
    case unavailable
    case miss
    case clean(generation: UInt64)
    case dirtyRetryRequired
}

struct WorkspaceCodemapBindingInvalidationResult: Equatable {
    let revokedOverlayCount: Int
    let cancelledRequestCount: Int
    let manifestWriteFailed: Bool
}

enum WorkspaceCodemapBindingEngineHookKind: String {
    case capabilityEligible
    case capabilityTerminalUnavailable
    case capabilityTransientRetry
    case classificationClean
    case classificationWorktree
    case classificationUnavailable
    case locatorFastPath
    case casFastPath
    case build
    case manifestLoadHit
    case manifestLoadMiss
    case manifestAdopted
    case manifestRevisionQueued
    case manifestWrite
    case manifestFailure
    case overlayReady
    case overlayUnavailable
    case overlayExactDuplicate
    case materialization
    case staleDrop
    case cancellation
    case busy
    case failure
    case invalidation
    case rootUnload
}

/// Hook payloads deliberately contain no physical or logical path.
struct WorkspaceCodemapBindingEngineHookEvent {
    let kind: WorkspaceCodemapBindingEngineHookKind
    let rootEpoch: WorkspaceCodemapRootEpoch?
    let artifactStorageDigest: String?
    let numericValue: UInt64
}

struct WorkspaceCodemapBindingEngineHooks {
    let event: @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void

    init(event: @escaping @Sendable (WorkspaceCodemapBindingEngineHookEvent) -> Void = { _ in }) {
        self.event = event
    }

    static let none = WorkspaceCodemapBindingEngineHooks()
}

struct WorkspaceCodemapBindingEngineCounters: Equatable {
    var capabilityResolutions: UInt64 = 0
    var capabilityRetries: UInt64 = 0
    var classifications: UInt64 = 0
    var cleanClassifications: UInt64 = 0
    var worktreeClassifications: UInt64 = 0
    var locatorFastPaths: UInt64 = 0
    var casFastPaths: UInt64 = 0
    var builds: UInt64 = 0
    var manifestLoads: UInt64 = 0
    var manifestAdoptions: UInt64 = 0
    var manifestWrites: UInt64 = 0
    var manifestFailures: UInt64 = 0
    var materializations: UInt64 = 0
    var materializedBytes: UInt64 = 0
    var validatedWorktreeReads: UInt64 = 0
    var validatedWorktreeBytes: UInt64 = 0
    var overlayReadyPublications: UInt64 = 0
    var overlayUnavailablePublications: UInt64 = 0
    var overlayExactDuplicateCompletions: UInt64 = 0
    var staleCompletionDrops: UInt64 = 0
    var cancellations: UInt64 = 0
    var busyRejections: UInt64 = 0
    var failures: UInt64 = 0

    init(initialValue: UInt64 = 0) {
        capabilityResolutions = initialValue
        capabilityRetries = initialValue
        classifications = initialValue
        cleanClassifications = initialValue
        worktreeClassifications = initialValue
        locatorFastPaths = initialValue
        casFastPaths = initialValue
        builds = initialValue
        manifestLoads = initialValue
        manifestAdoptions = initialValue
        manifestWrites = initialValue
        manifestFailures = initialValue
        materializations = initialValue
        materializedBytes = initialValue
        validatedWorktreeReads = initialValue
        validatedWorktreeBytes = initialValue
        overlayReadyPublications = initialValue
        overlayUnavailablePublications = initialValue
        overlayExactDuplicateCompletions = initialValue
        staleCompletionDrops = initialValue
        cancellations = initialValue
        busyRejections = initialValue
        failures = initialValue
    }
}

struct WorkspaceCodemapBindingEngineAccounting: Equatable {
    let rootCount: Int
    let eligibleRootCount: Int
    let unavailableRootCount: Int
    let activeRequestCount: Int
    let queuedRequestCount: Int
    let ownerCount: Int
    let reservedSourceByteCount: UInt64
    let manifestAdoptionLeaseCount: Int
    let manifestAdoptionLeaseByteCount: UInt64
    let rootAdmissionHistoryCount: Int
    let ownerAdmissionHistoryCount: Int
    let dirtyManifestCount: Int
    let counters: WorkspaceCodemapBindingEngineCounters
}
