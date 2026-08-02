import Foundation
import UIKit


struct CameraSessionIdentity: Equatable {
  let cameraName: String
  let peripheralID: UUID?
  let historyKey: String

  init(cameraName: String, peripheralID: UUID? = nil, historyKey: String? = nil) {
    self.cameraName = cameraName
    self.peripheralID = peripheralID
    self.historyKey = historyKey ?? cameraName
  }
}

struct CameraSessionQueuedDownload: Equatable, Sendable {
  let handle: UInt32
  let mode: CameraVendorTransferDownloadMode
}

enum CameraDownloadOrigin: String, Codable, Equatable, Sendable {
  case gallery
  case quickDownload
  case recovery
}

enum CameraDownloadCompletionPolicy: String, Codable, Equatable, Sendable {
  case returnToGallery
  case disconnectToHome
}

struct CameraDownloadSubmission: Equatable, Sendable {
  let id: UUID
  let requests: [CameraSessionQueuedDownload]
  let origin: CameraDownloadOrigin
  let completionPolicy: CameraDownloadCompletionPolicy
}

enum CameraSessionRuntimeLifecycleLogPolicy {
  static func formattedBackgroundTimeRemaining(_ remaining: TimeInterval) -> String {
    guard remaining.isFinite, remaining < TimeInterval(Int.max) else {
      return "foreground"
    }
    return "\(Int(max(0, remaining)))s"
  }
}

enum CameraSessionCommand {
  case enterGallery(CameraSessionIdentity)
  case startDownload(handles: [UInt32], mode: CameraVendorTransferDownloadMode)
  case startDownloadRequests([CameraSessionQueuedDownload])
  case cancelDownloadByUser
  case galleryPresentationDetached
  case applicationWillResignActive
  case applicationEnteredBackground
  case applicationBecameActive
  case backgroundExecutionExpired
  case transportFailed(Error)
  case transferFinished(handle: UInt32)
  case transferCancelled(handle: UInt32)
  case fileSaveFailed(handle: UInt32, error: Error)
  case restorePersistedDownload
  case resumeRecoveredDownload(availableHandles: Set<UInt32>)
  case clearSavedDownloadHistory(handle: UInt32)
  case clearAllSavedDownloadHistory
  case disconnectCamera(reason: String)
}

@MainActor
protocol CameraSessionRuntimeCommandHandling: AnyObject {
  func send(_ command: CameraSessionCommand)
}


struct CameraSessionRuntimeBinding: Equatable {
  let sessionID: UUID
  let identity: CameraSessionIdentity
}

enum CameraSessionPhase: Equatable {
  case idle
  case galleryLoading
  case galleryReady
  case downloadingForeground
  case downloadingBackground
  case cancelling
  case recovering
  case interrupted
}

struct CameraSessionPresentation: Equatable {
  let phase: CameraSessionPhase
  let queuedHandles: [UInt32]
  let inFlightHandle: UInt32?
  let catalog: CameraGalleryPresentation

  init(
    phase: CameraSessionPhase,
    queuedHandles: [UInt32],
    inFlightHandle: UInt32?,
    catalog: CameraGalleryPresentation = .unavailable
  ) {
    self.phase = phase
    self.queuedHandles = queuedHandles
    self.inFlightHandle = inFlightHandle
    self.catalog = catalog
  }

  static let idle = CameraSessionPresentation(
    phase: .idle,
    queuedHandles: [],
    inFlightHandle: nil,
    catalog: .unavailable
  )
}

struct CameraSessionRuntimeActivitySnapshot: Equatable {
  let sessionID: UUID
  let cameraName: String
  let galleryItemCount: Int
  let downloadCompletedCount: Int
  let downloadTotalCount: Int
  let isBackground: Bool
  let isShowingDownloadProgress: Bool
}

@MainActor
protocol CameraSessionRuntimeActivityReporting: AnyObject {
  func publish(_ snapshot: CameraSessionRuntimeActivitySnapshot, reason: String)
  func end(sessionID: UUID, reason: String)
  func cleanupStale(reason: String)
}

@MainActor
final class CameraSessionRuntime: CameraSessionRuntimeCommandHandling {
  private struct PendingGalleryActivation {
    let resultState: IOSCameraConnectFlowState
    let destination: CameraSessionRuntimePresentationDestination
    let completion: (IOSCameraConnectFlowState) -> Void
  }

  private struct PendingTransportFailureCleanup: Equatable {
    let leaseID: UUID
    let catalogSessionID: UUID?
    let transportBinding: CameraSessionRuntimeBinding?
    let reason: String
  }

  private let transport: CameraSessionRuntimeTransport
  private let recoveryStore: CameraSessionRuntimeRecoveryStoring?
  private let savedHandleStore: CameraSessionRuntimeSavedHandleStoring?
  private let executionAuthority: CameraSessionRuntimeExecutionAuthorizing?
  private let backgroundMaintainer: CameraSessionRuntimeBackgroundMaintaining?
  private let activityReporter: CameraSessionRuntimeActivityReporting?
  private let recoveryConnector: CameraSessionRuntimeRecoveryConnecting?
  private let connectionWorker: CameraSessionRuntimeConnectionWorker?
  private let gallerySessionActivator: CameraSessionRuntimeGallerySessionActivating?
  private let connectionController: CameraSessionRuntimeConnectionControlling?
  private let legacyResumeMigrator: CameraSessionRuntimeLegacyResumeMigrating?
  private let userCancellationHardInterruptDelayNanoseconds: UInt64
  private(set) var presentation = CameraSessionPresentation.idle
  private var identity: CameraSessionIdentity?
  private var queuedDownloads: [CameraSessionQueuedDownload] = []
  private var activeDownloadSubmission: CameraDownloadSubmission?
  private var downloadAdmissionTask: Task<Void, Never>?
  private var suspendedGallerySessionForDownload: CameraGallerySession?
  private var itemStates: [UInt32: CameraVendorDownloadState] = [:]
  private var itemProgress: [UInt32: String] = [:]
  private var galleryItemsByHandle: [UInt32: CameraVendorGalleryItem] = [:]
  private var completedCount = 0
  private var failedCount = 0
  private var recoveredSnapshot: CameraDownloadSessionSnapshot?
  private var hasInterruptedRecoverably = false
  private var hasDownloadLease = false
  private var downloadLeaseID: UUID?
  private var pendingTransportFailureCleanup: PendingTransportFailureCleanup?
  private var isApplicationInBackground = false
  private var isApplicationTransitioningToBackground = false
  private var hasBackgroundExecutionAuthority = false
  private var activitySessionID: UUID?
  private var activeTransportBinding: CameraSessionRuntimeBinding?
  private var isCatalogTransportUsable = false
  private(set) var galleryPresentationPayload: CameraSessionRuntimeGalleryPresentationPayload?
  private var isQuickDownloadQuerySession = false
  private var quickDownloadGalleryReadySession: IOSCameraGallerySession?
  private var galleryItemCount = 0
  private var gallerySession: CameraGallerySession?
  private var catalogQueryEngine: CameraCatalogQueryEngine?
  private var catalogGenerationFence: CameraSessionGenerationFence?
  private var catalogLifecycleTask: Task<Void, Never>?
  private var catalogSessionID: UUID?
  private(set) var galleryCatalogIdentity: CameraGalleryCatalogIdentity?
  private var pendingGalleryActivation: PendingGalleryActivation?
  private var hasRequestedRecoveredConnection = false
  private var presentationObservers: [UUID: (CameraSessionPresentation) -> Void] = [:]
  private var incrementalCatalogObservers: [UUID: (CameraGalleryPresentation, CameraGalleryIncrementalDelta) -> Void] = [:]
  private var galleryThumbnailViewportRevision: UInt64 = 0
  private var downloadStopWaiters: [CheckedContinuation<Void, Never>] = []
  var onConnectionSnapshotChanged: ((IOSCameraHomeSnapshot) -> Void)?
  var onConnectionLogAppended: ((String) -> Void)?
  var onPresentationDestinationReady: ((CameraSessionRuntimePresentationDestination) -> Void)?
  var onDownloadThumbnailGenerated: ((UInt32, UIImage) -> Void)?

  init(
    transport: CameraSessionRuntimeTransport,
    recoveryStore: CameraSessionRuntimeRecoveryStoring? = nil,
    savedHandleStore: CameraSessionRuntimeSavedHandleStoring? = nil,
    executionAuthority: CameraSessionRuntimeExecutionAuthorizing? = nil,
    backgroundMaintainer: CameraSessionRuntimeBackgroundMaintaining? = nil,
    activityReporter: CameraSessionRuntimeActivityReporting? = nil,
    recoveryConnector: CameraSessionRuntimeRecoveryConnecting? = nil,
    connectionWorker: CameraSessionRuntimeConnectionWorker? = nil,
    gallerySessionActivator: CameraSessionRuntimeGallerySessionActivating? = nil,
    connectionController: CameraSessionRuntimeConnectionControlling? = nil,
    legacyResumeMigrator: CameraSessionRuntimeLegacyResumeMigrating? = nil,
    userCancellationHardInterruptDelayNanoseconds: UInt64 = 2_000_000_000
  ) {
    self.transport = transport
    self.recoveryStore = recoveryStore
    self.savedHandleStore = savedHandleStore
    self.executionAuthority = executionAuthority
    self.backgroundMaintainer = backgroundMaintainer
    self.activityReporter = activityReporter
    self.recoveryConnector = recoveryConnector
    self.connectionWorker = connectionWorker
    self.gallerySessionActivator = gallerySessionActivator
    self.connectionController = connectionController
    self.legacyResumeMigrator = legacyResumeMigrator
    self.userCancellationHardInterruptDelayNanoseconds =
      userCancellationHardInterruptDelayNanoseconds
    connectionController?.onSnapshotChanged = { [weak self] snapshot in
      self?.onConnectionSnapshotChanged?(snapshot)
    }
    connectionController?.onLogAppended = { [weak self] message in
      self?.onConnectionLogAppended?(message)
    }
  }

  var rememberedCameraRecords: [IOSCameraRememberedCameraRecord] {
    connectionController?.rememberedCameraRecords ?? []
  }

  var activeCameraIdentity: CameraSessionIdentity? { identity }

  func submitGalleryFilter(
    rule: CameraMediaFilterRule,
    sort: CameraGallerySortIntent
  ) {
    guard canSubmitCatalogCommand, let gallerySession else { return }
    Task {
      await gallerySession.submitFilter(CameraGalleryFilterIntent(rule: rule, sort: sort))
    }
  }

  func resolveCatalog(
    rule: CameraMediaFilterRule,
    owner: CameraCatalogAccessOwner,
    onProgress: (@MainActor @Sendable (CameraCatalogQueryProgress) -> Void)? = nil
  ) async throws -> CameraCatalogResolution {
    try validateCatalogCommand()
    guard let queryEngine = catalogQueryEngine else { throw CancellationError() }
    let resolution = try await queryEngine.resolve(
      rule: rule,
      owner: owner,
      downloadedHandles: savedDownloadHandles(),
      onProgress: onProgress
    )
    try validateCatalogCommand()
    guard catalogQueryEngine === queryEngine else { throw CancellationError() }
    for item in resolution.snapshot.items {
      galleryItemsByHandle[UInt32(item.handle)] = item
    }
    return resolution
  }

  func requestVisibleGalleryThumbnails(handles: [Int]) {
    guard let expectedCatalogIdentity = galleryCatalogIdentity else { return }
    requestVisibleGalleryThumbnails(
      handles: handles,
      expectedCatalogIdentity: expectedCatalogIdentity
    )
  }

  func requestVisibleGalleryThumbnails(
    handles: [Int],
    expectedCatalogIdentity: CameraGalleryCatalogIdentity
  ) {
    guard canSubmitCatalogCommand,
          let gallerySession,
          expectedCatalogIdentity == galleryCatalogIdentity else { return }
    galleryThumbnailViewportRevision &+= 1
    let submissionID = galleryThumbnailViewportRevision
    Task {
      await gallerySession.requestVisibleThumbnails(
        handles: handles,
        submissionID: submissionID,
        expectedCatalogIdentity: expectedCatalogIdentity
      )
    }
  }

  func cancelActiveThumbnailWork() async {
    await gallerySession?.cancelActiveThumbnailWork()
  }

  func suspendGalleryContentWorkForFullScreenPreview() async {
    await gallerySession?.suspendContentWorkForFullScreenPreview()
  }

  func resumeGalleryContentWorkAfterFullScreenPreview() async {
    await gallerySession?.resumeContentWorkAfterFullScreenPreview()
  }

  var galleryPreviewCache: NativeGalleryHighDefinitionPreviewCache? {
    gallerySession?.previewCache
  }

  func switchGalleryPreviewMode(
    _ mode: NativeGalleryBrowseMode,
    snapshot: NativeGalleryHDPreviewSnapshot? = nil,
    visibleHandles: [Int] = []
  ) async {
    await gallerySession?.switchPreviewMode(
      mode,
      snapshot: snapshot,
      visibleHandles: visibleHandles
    )
  }

  func updateGalleryHDPreviewVisibleHandles(_ handles: [Int]) {
    gallerySession?.updateHDPreviewVisibleHandles(handles)
  }

  func updateGalleryHDPreviewSnapshot(
    _ snapshot: NativeGalleryHDPreviewSnapshot,
    expectedCatalogIdentity: CameraGalleryCatalogIdentity
  ) async {
    await gallerySession?.updateHDPreviewSnapshot(
      snapshot,
      expectedCatalogIdentity: expectedCatalogIdentity
    )
  }

  func focusGalleryHDFullScreen(handle: Int) {
    gallerySession?.focusHDFullScreen(handle: handle)
  }

  func restoreGalleryHDPreviewListFocus(visibleHandles: [Int]) {
    gallerySession?.restoreHDPreviewListFocus(visibleHandles: visibleHandles)
  }

  func retryGalleryHDPreview(handle: Int) {
    gallerySession?.retryHDPreview(handle: handle)
  }

  func cachedGalleryHDPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    gallerySession?.cachedPreview(for: handle)
  }

  func peekCachedGalleryHDPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    gallerySession?.peekCachedPreview(for: handle)
  }

  func galleryHDPreviewLoadedHandles(
    for catalogIdentity: CameraGalleryCatalogIdentity
  ) -> Set<Int> {
    gallerySession?.previewCache.loadedHandles(for: catalogIdentity) ?? []
  }

  @discardableResult
  func observeGalleryPreview(
    _ observer: @escaping (CameraGalleryHDPreviewPipeline.Publication) -> Void
  ) -> UUID? {
    gallerySession?.observePreview(observer)
  }

  private func beginFreshConnectedSession(
    identity: CameraSessionIdentity,
    phase: CameraSessionPhase,
    startsGalleryCatalog: Bool
  ) {
    if recoveredSnapshot != nil || hasInterruptedRecoverably {
      (recoveryConnector as? CameraSessionRuntimeRecoveryCancelling)?
        .cancelRecoveryConnection(reason: "fresh-session-superseded-download-recovery")
      recoveryStore?.clear()
    }
    self.identity = identity
    isCatalogTransportUsable = true
    activeDownloadSubmission = nil
    recoveredSnapshot = nil
    hasRequestedRecoveredConnection = false
    endActivity(reason: startsGalleryCatalog ? "superseded-gallery" : "quick-download-connected")
    hasInterruptedRecoverably = false
    queuedDownloads = []
    itemStates = [:]
    itemProgress = [:]
    galleryItemsByHandle = [:]
    synchronizeSavedHistoryFromStore()
    completedCount = 0
    failedCount = 0
    galleryItemCount = 0
    presentation = CameraSessionPresentation(
      phase: phase,
      queuedHandles: [],
      inFlightHandle: nil,
      catalog: .unavailable
    )
    isQuickDownloadQuerySession = !startsGalleryCatalog
    if startsGalleryCatalog {
      configureCatalogRuntime()
    } else {
      configureCatalogQueryRuntime()
    }
    (backgroundMaintainer as? CameraSessionRuntimeBackgroundExecutionPreparing)?
      .prepareBackgroundExecution()
  }

  private func configureCatalogQueryRuntime() {
    let previousSession = gallerySession
    let previousQueryEngine = catalogQueryEngine
    let previousGenerationFence = catalogGenerationFence
    let previousLifecycleTask = catalogLifecycleTask
    previousGenerationFence?.invalidate()
    guard identity != nil else { return }
    let sessionEpoch = UUID()
    let generationFence = CameraSessionGenerationFence()
    let source = CameraSessionGalleryCatalogRuntimeSource(
      transport: transport,
      generationFence: generationFence
    )
    let queryEngine = CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch)
    catalogSessionID = sessionEpoch
    catalogQueryEngine = queryEngine
    catalogGenerationFence = generationFence
    galleryCatalogIdentity = nil
    gallerySession = nil
    catalogLifecycleTask = Task { @MainActor [weak self] in
      await previousLifecycleTask?.value
      await previousQueryEngine?.invalidate()
      await previousSession?.invalidate()
      guard self?.catalogSessionID == sessionEpoch else {
        await queryEngine.invalidate()
        return
      }
    }
  }

  private func configureCatalogRuntime() {
    let previousSession = gallerySession
    let previousQueryEngine = catalogQueryEngine
    let previousGenerationFence = catalogGenerationFence
    let previousLifecycleTask = catalogLifecycleTask
    previousGenerationFence?.invalidate()
    let generationFence = CameraSessionGenerationFence()
    let source = CameraSessionGalleryCatalogRuntimeSource(
      transport: transport,
      generationFence: generationFence
    )
    guard let identity else { return }
    let sessionEpoch = UUID()
    let queryEngine = CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch)
    let session = CameraGallerySession(
      identity: identity,
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: queryEngine,
      downloadedHandles: { [weak self] in self?.savedDownloadHandles() ?? [] },
      fetchPreview: { [weak self] mediaIdentity in
        guard let self else { throw CancellationError() }
        try generationFence.checkActive()
        let preview = try await self.transport.fetchPreviewImageWithInfo(for: mediaIdentity.handle)
        try generationFence.checkActive()
        return CameraGalleryRepositoryAdapter.previewResult(from: preview)
      }
    )
    let sessionID = sessionEpoch
    catalogSessionID = sessionID
    catalogQueryEngine = queryEngine
    catalogGenerationFence = generationFence
    galleryCatalogIdentity = nil
    gallerySession = nil
    catalogLifecycleTask = Task { @MainActor [weak self] in
      await previousLifecycleTask?.value
      await previousQueryEngine?.invalidate()
      await previousSession?.invalidate()
      guard let self,
            self.catalogSessionID == sessionID else {
        await session.invalidate()
        await queryEngine.invalidate()
        return
      }
      self.gallerySession = session
      session.onTransportFailure = { [weak self] failure in
        guard failure.provesTransportLost,
              self?.catalogSessionID == sessionID else { return }
        self?.send(.transportFailed(NSError(
          domain: "CameraGalleryCatalogRuntime",
          code: NSURLErrorNetworkConnectionLost,
          userInfo: [NSLocalizedDescriptionKey: failure.message]
        )))
      }
      session.observePresentation { [weak self] catalog in
        guard self?.catalogSessionID == sessionID else { return }
        self?.installCatalogPresentation(catalog)
      }
      session.observeIncrementalUpdates { [weak self] catalog, delta in
        guard self?.catalogSessionID == sessionID else { return }
        self?.publishIncrementalCatalogUpdate(catalog, delta)
      }
      await session.enter()
    }
  }

  private func installCatalogPresentation(_ catalog: CameraGalleryPresentation) {
    if case .ready(let generation, let snapshotID) = catalog.state,
       let sessionEpoch = catalogSessionID {
      galleryCatalogIdentity = CameraGalleryCatalogIdentity(
        cameraID: identity?.historyKey ?? sessionEpoch.uuidString,
        sessionEpoch: sessionEpoch,
        generation: generation,
        snapshotID: snapshotID
      )
    } else {
      galleryCatalogIdentity = nil
    }
    let wasRecovering = presentation.phase == .recovering
    let phase: CameraSessionPhase
    if presentation.phase == .galleryLoading, case .ready = catalog.state {
      phase = .galleryReady
    } else {
      phase = presentation.phase
    }
    presentation = CameraSessionPresentation(
      phase: phase,
      queuedHandles: presentation.queuedHandles,
      inFlightHandle: presentation.inFlightHandle,
      catalog: catalog
    )
    galleryItemsByHandle = Dictionary(
      uniqueKeysWithValues: catalog.items.map { (UInt32($0.handle), $0) }
    )
    galleryItemCount = catalog.items.count
    publishPresentation()
    if case .ready = catalog.state, wasRecovering {
      send(.resumeRecoveredDownload(availableHandles: Set(catalog.items.map { UInt32($0.handle) })))
    }
    switch catalog.state {
    case .ready:
      completePendingGalleryActivationIfNeeded()
    case .failed(_, let failure):
      failPendingGalleryActivationIfNeeded(message: failure.message)
    case .transportLost(let message):
      failPendingGalleryActivationIfNeeded(message: message)
    case .unsupported(_, let reason):
      failPendingGalleryActivationIfNeeded(message: reason.message)
    case .unavailable, .loading:
      break
    }
  }

  func beginTransportBinding(identity: CameraSessionIdentity) -> CameraSessionRuntimeBinding {
    let binding = CameraSessionRuntimeBinding(sessionID: UUID(), identity: identity)
    catalogGenerationFence?.invalidate()
    activeTransportBinding = binding
    return binding
  }

  var currentTransportBinding: CameraSessionRuntimeBinding? {
    activeTransportBinding
  }

  func acceptsTransportCallback(_ binding: CameraSessionRuntimeBinding?) -> Bool {
    binding != nil && binding == activeTransportBinding
  }

  var connectionSnapshot: IOSCameraHomeSnapshot? {
    connectionController?.snapshot()
  }

  var requiresSystemBluetoothPairingCleanup: Bool {
    connectionController?.snapshot().requiresSystemBluetoothPairingCleanup ?? false
  }

  var connectionLogText: String {
    connectionController?.currentLogText ?? ""
  }

  var connectionLogFileURL: URL? {
    connectionController?.logFileURL
  }

  func restoreRememberedCameraRecords() -> Bool {
    connectionController?.restoreLastPairedCameraIfAvailable() ?? false
  }

  func publishSystemBluetoothCleanupBlockIfNeeded() -> Bool {
    connectionController?.publishSystemBluetoothCleanupBlockIfNeeded() ?? false
  }

  func requestCameraDiscovery() {
    connectionController?.startScan()
  }

  func clearConnectionLogs() {
    connectionController?.clearLogs()
  }

  func acknowledgeSystemBluetoothPairingCleanupForFreshPairing() {
    connectionController?.acknowledgeSystemBluetoothPairingCleanupForFreshPairing()
  }

  func forgetLastRememberedCamera() {
    connectionController?.forgetLastPairedCamera()
  }

  func forgetRememberedCamera(peripheralID: UUID) {
    connectionController?.forgetRememberedCamera(peripheralID: peripheralID)
  }

  @discardableResult
  func cancelRecoveredDownloadFromConnectionOverlay() -> Bool {
    guard presentation.phase == .recovering else {
      return false
    }
    send(.cancelDownloadByUser)
    return true
  }

  func repairSystemBluetoothCleanupAndStartFreshDiscovery() {
    connectionController?.acknowledgeSystemBluetoothPairingCleanupForFreshPairing()
    connectionController?.forgetLastPairedCamera()
    connectionController?.clearLogs()
    connectionController?.startScan()
  }

  func isRememberedCamera(_ camera: IOSCameraDiscoveredCamera) -> Bool {
    rememberedCameraRecords.contains { $0.peripheralID == camera.id }
  }

  // MARK: - Pairing Probe

  func probePairing(peripheralID: UUID) async -> CameraVendorPairingProbeResult {
    await connectionController?.probePairing(peripheralID: peripheralID) ?? .bluetoothOff
  }

  var hasPreconnectedProbe: Bool {
    connectionController?.hasPreconnectedProbe ?? false
  }

  var preconnectedProbePeripheralID: UUID? {
    connectionController?.preconnectedProbePeripheralID
  }

  func cancelPairingProbe(reason: String) {
    connectionController?.cancelPairingProbe(reason: reason)
  }

  var isConnectionWorkerActive: Bool { connectionWorker?.isActive ?? false }
  var connectionFlowState: IOSCameraConnectFlowState? { connectionWorker?.state }
  var connectionNavigationEvent: IOSCameraConnectFlowNavigationEvent? { connectionWorker?.navigationEvent }

  func startPairingConnection(
    camera: IOSCameraDiscoveredCamera,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    connectionWorker?.startPairing(camera: camera, completion: completion)
  }

  func confirmPairingConnection(completion: @escaping (Result<Void, Error>) -> Void) {
    connectionWorker?.confirmPairing(completion: completion)
  }

  func startRememberedGalleryConnection(
    record: IOSCameraRememberedCameraRecord,
    completion: @escaping (IOSCameraConnectFlowState) -> Void
  ) {
    quickDownloadGalleryReadySession = nil
    connectionWorker?.enterRememberedGallery(record: record) { [weak self] state in
      guard let self else { return }
      guard case .galleryReady = state else {
        completion(state)
        return
      }
      do {
        let shouldRouteToRecoveryDownloadCenter = self.presentation.phase == .recovering
        self.galleryPresentationPayload = try self.activateRememberedGallerySession()
        guard let payload = self.galleryPresentationPayload else {
          throw CameraSessionRuntimeGalleryActivationError.missingGallerySessionActivator
        }
        self.pendingGalleryActivation = PendingGalleryActivation(
          resultState: state,
          destination: shouldRouteToRecoveryDownloadCenter
            ? .recoveryDownloadCenter(payload)
            : .gallery(payload),
          completion: completion
        )
      } catch {
        completion(.failed(IOSCameraConnectionIssue(
          step: .loadGallery,
          reason: error.localizedDescription
        )))
      }
    }
  }

  func startRememberedQuickDownloadConnection(
    record: IOSCameraRememberedCameraRecord,
    completion: @escaping (IOSCameraConnectFlowState) -> Void
  ) {
    quickDownloadGalleryReadySession = nil
    connectionWorker?.enterRememberedGallery(record: record) { [weak self] state in
      guard let self else { return }
      guard case let .galleryReady(session) = state else {
        completion(state)
        return
      }
      do {
        self.galleryPresentationPayload = try self.activateRememberedQuickDownloadSession()
        self.quickDownloadGalleryReadySession = session
        completion(state)
      } catch {
        completion(.failed(IOSCameraConnectionIssue(
          step: .loadGallery,
          reason: error.localizedDescription
        )))
      }
    }
  }

  func cancelConnectionWorker(reason: String) {
    connectionWorker?.cancel(reason: reason)
  }

  /// Activates the transport only after the runtime-owned connection worker has
  /// produced a GalleryReady navigation event. Home receives the returned
  /// presentation payload solely to render the gallery.
  func activateRememberedGallerySession() throws -> CameraSessionRuntimeGalleryPresentationPayload {
    let (payload, identity) = try activateRememberedTransportSession()
    send(.enterGallery(identity))
    galleryPresentationPayload = payload
    return payload
  }

  private func activateRememberedQuickDownloadSession() throws -> CameraSessionRuntimeGalleryPresentationPayload {
    let (payload, identity) = try activateRememberedTransportSession()
    beginFreshConnectedSession(
      identity: identity,
      phase: .galleryReady,
      startsGalleryCatalog: false
    )
    galleryPresentationPayload = payload
    publishPresentation()
    return payload
  }

  private func activateRememberedTransportSession() throws -> (
    CameraSessionRuntimeGalleryPresentationPayload,
    CameraSessionIdentity
  ) {
    guard case let .enterGallery(session)? = connectionWorker?.navigationEvent else {
      throw CameraSessionRuntimeGalleryActivationError.missingGalleryNavigation
    }
    guard let rememberedPeripheralID = session.rememberedPeripheralID else {
      throw CameraSessionRuntimeGalleryActivationError.missingGalleryNavigation
    }
    guard let gallerySessionActivator else {
      throw CameraSessionRuntimeGalleryActivationError.missingGallerySessionActivator
    }
    let payload = try gallerySessionActivator.activateGallerySession(session, runtime: self)
    guard payload.rememberedPeripheralID == rememberedPeripheralID else {
      throw CameraSessionRuntimeGalleryActivationError.mismatchedRememberedCamera
    }
    let identity = CameraSessionIdentity(
      cameraName: payload.summary.navigationTitle,
      peripheralID: rememberedPeripheralID,
      historyKey: payload.summary.serialNumber.isEmpty
        ? payload.summary.deviceName
        : payload.summary.serialNumber
    )
    return (payload, identity)
  }

  func send(_ command: CameraSessionCommand) {
    defer { publishPresentation() }
    switch command {
    case .enterGallery(let identity):
      if presentation.phase == .recovering {
        let hasSameProcessRecovery = hasInterruptedRecoverably &&
          activeDownloadSubmission != nil &&
          !queuedDownloads.isEmpty
        let recoveryPeripheralID = recoveredSnapshot?.peripheralID ?? self.identity?.peripheralID
        if (recoveredSnapshot != nil || hasSameProcessRecovery),
           recoveryPeripheralID == identity.peripheralID {
          self.identity = identity
          isCatalogTransportUsable = true
          configureCatalogRuntime()
          return
        }
      }
      beginFreshConnectedSession(
        identity: identity,
        phase: .galleryLoading,
        startsGalleryCatalog: true
      )

    case .startDownload(let handles, let mode):
      submitDownload(CameraDownloadSubmission(
        id: UUID(),
        requests: handles.map { CameraSessionQueuedDownload(handle: $0, mode: mode) },
        origin: .gallery,
        completionPolicy: .returnToGallery
      ))

    case .startDownloadRequests(let requests):
      submitDownload(CameraDownloadSubmission(
        id: UUID(),
        requests: requests,
        origin: .gallery,
        completionPolicy: .returnToGallery
      ))

    case .galleryPresentationDetached:
      return

    case .cancelDownloadByUser:
      guard isDownloading || presentation.phase == .recovering || presentation.phase == .interrupted else { return }
      if isDownloading {
        if pendingTransportFailureCleanup != nil {
          transport.cancelActiveTransfer(reason: "user-cancelled-download")
          presentation = CameraSessionPresentation(
            phase: .cancelling,
            queuedHandles: queuedDownloads.map(\.handle),
            inFlightHandle: presentation.inFlightHandle,
            catalog: presentation.catalog
          )
          return
        }
        guard presentation.inFlightHandle != nil else {
          finishUserCancelledDownload(reason: "user-cancelled-queued-download")
          return
        }
        transport.cancelActiveTransfer(reason: "user-cancelled-download")
        presentation = CameraSessionPresentation(
          phase: .cancelling,
          queuedHandles: queuedDownloads.map(\.handle),
          inFlightHandle: presentation.inFlightHandle,
          catalog: presentation.catalog
        )
        return
      }
      if presentation.phase == .recovering {
        (recoveryConnector as? CameraSessionRuntimeRecoveryCancelling)?
          .cancelRecoveryConnection(reason: "user-cancelled-download-recovery")
      }
      // User explicitly cancelled — always return to gallery regardless of the
      // original submission's completionPolicy. The user wants to stay and operate,
      // not disconnect.
      let completionPolicy: CameraDownloadCompletionPolicy = .returnToGallery
      finishDownloadAdmission()
      releaseBackgroundExecution(reason: "user-cancelled-download")
      backgroundMaintainer?.stop(reason: "user-cancelled-download")
      endActivity(reason: "user-cancelled-download")
      recoveryStore?.clear()
      activeDownloadSubmission = nil
      queuedDownloads = []
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      hasRequestedRecoveredConnection = false
      applyDownloadCompletionRouting(
        completionPolicy,
        reason: "user-cancelled-interrupted-download"
      )

    case .applicationWillResignActive:
      isApplicationTransitioningToBackground = true
      logLifecycleTransition(event: "will-resign-active")
      guard identity != nil else { return }
      let needsFiniteBackgroundTask = isDownloadingPhase
        || presentation.phase == .galleryLoading
        || presentation.phase == .galleryReady
      guard needsFiniteBackgroundTask else { return }
      let acquiredBackgroundExecution = hasBackgroundExecutionAuthority ||
        (executionAuthority?.acquire(reason: "camera-background-transition") ?? false)
      hasBackgroundExecutionAuthority = acquiredBackgroundExecution
      guard acquiredBackgroundExecution else {
        if isDownloadingPhase {
          interruptRecoverably(reason: "background-execution-unavailable")
        }
        return
      }

    case .applicationEnteredBackground:
      isApplicationInBackground = true
      isApplicationTransitioningToBackground = false
      logLifecycleTransition(event: "entered-background")
      guard identity != nil,
            presentation.phase == .galleryLoading || presentation.phase == .galleryReady || isDownloadingPhase else {
        return
      }
      backgroundMaintainer?.start(
        allowingPtpKeepAlive: !isDownloading
      )
      let hasSustainingBackgroundExecution = (backgroundMaintainer as? CameraSessionRuntimeBackgroundExecutionSustaining)?
        .isSustainingBackgroundExecution == true
      let acquiredBackgroundExecution = hasBackgroundExecutionAuthority ||
        (executionAuthority?.acquire(reason: "download-background") ?? false)
      hasBackgroundExecutionAuthority = acquiredBackgroundExecution
      logLifecycleTransition(
        event: "background-authority-evaluated",
        details: "finite=\(acquiredBackgroundExecution) sustained=\(hasSustainingBackgroundExecution)"
      )
      guard acquiredBackgroundExecution || hasSustainingBackgroundExecution else {
        if isDownloadingPhase {
          interruptRecoverably(reason: "background-execution-unavailable")
        } else {
          backgroundMaintainer?.stop(reason: "background-execution-unavailable")
        }
        return
      }
      if isDownloadingPhase {
        if downloadAdmissionTask != nil {
          presentDownloadAwaitingAdmission(phase: .downloadingBackground)
        } else if presentation.inFlightHandle == nil, !queuedDownloads.isEmpty {
          startNextDownload(phase: .downloadingBackground)
        } else {
          present(phase: .downloadingBackground)
        }
      }
      publishActivity(reason: "application-entered-background")

    case .applicationBecameActive:
      isApplicationInBackground = false
      isApplicationTransitioningToBackground = false
      hasBackgroundExecutionAuthority = false
      logLifecycleTransition(event: "became-active")
      backgroundMaintainer?.stop(reason: "application-became-active")
      releaseBackgroundExecution(reason: "download-foreground")
      if identity != nil,
         presentation.phase == .galleryLoading || presentation.phase == .galleryReady || isDownloadingPhase {
        (backgroundMaintainer as? CameraSessionRuntimeBackgroundExecutionPreparing)?
          .prepareBackgroundExecution()
      }
      if presentation.phase == .downloadingBackground {
        if downloadAdmissionTask != nil {
          presentDownloadAwaitingAdmission(phase: .downloadingForeground)
        } else if presentation.inFlightHandle == nil, !queuedDownloads.isEmpty {
          startNextDownload(phase: .downloadingForeground)
        } else {
          present(phase: .downloadingForeground)
        }
      } else if isDownloadingPhase,
                presentation.inFlightHandle == nil,
                !queuedDownloads.isEmpty {
        if downloadAdmissionTask != nil {
          presentDownloadAwaitingAdmission(phase: .downloadingForeground)
        } else {
          startNextDownload(phase: .downloadingForeground)
        }
      }
      publishActivity(reason: "application-became-active")
      requestRecoveredConnectionIfNeeded()

    case .backgroundExecutionExpired:
      guard isApplicationInBackground else {
        logLifecycleTransition(event: "background-expired-ignored-after-foreground")
        return
      }
      isApplicationTransitioningToBackground = false
      hasBackgroundExecutionAuthority = false
      logLifecycleTransition(event: "background-execution-expired")
      if (backgroundMaintainer as? CameraSessionRuntimeBackgroundExecutionSustaining)?
        .isSustainingBackgroundExecution == true {
        let inFlight = presentation.inFlightHandle.map { String($0) } ?? "none"
        CameraVendorFileLogger.log(
          "[RUNTIME_BACKGROUND_EXECUTION] finite-task-expired ble-activity-active queue=\(queuedDownloads.count) inFlight=\(inFlight)"
        )
        return
      }
      backgroundMaintainer?.stop(reason: "background-execution-expired")
      if isDownloading {
        interruptRecoverably(reason: "background-execution-expired")
      }

    case .transportFailed(let error):
      let transportError = error as NSError
      logLifecycleTransition(
        event: "transport-failed",
        details: "errorDomain=\(transportError.domain) errorCode=\(transportError.code) " +
          "message=\(error.localizedDescription)"
      )
      if isDownloadingPhase {
        interruptRecoverablyAfterCatalogShutdown(
          reason: "transport-failed",
          transportMessage: error.localizedDescription
        )
      } else if presentation.phase == .galleryLoading || presentation.phase == .galleryReady {
        let gallerySession = gallerySession
        let catalogSessionID = catalogSessionID
        let transportBinding = activeTransportBinding
        Task { @MainActor [weak self] in
          await gallerySession?.markTransportLost(error.localizedDescription)
          guard let self,
                self.catalogSessionID == catalogSessionID,
                self.activeTransportBinding == transportBinding else { return }
          self.transport.terminateCameraCommunication(reason: "catalog-transport-lost")
          self.activeTransportBinding = nil
          self.isCatalogTransportUsable = false
        }
      }

    case .transferFinished(let handle):
      completeTransfer(handle: handle)

    case .transferCancelled(let handle):
      completeCancelledTransfer(handle: handle)

    case .fileSaveFailed(let handle, let error):
      completeSaveFailure(handle: handle, error: error)

    case .restorePersistedDownload:
      legacyResumeMigrator?.discardLegacyRememberedGalleryResume()
      guard let snapshot = recoveryStore?.loadInterruptedRecoverable() else {
        activityReporter?.cleanupStale(reason: "no-persisted-recovery")
        return
      }
      recoveredSnapshot = snapshot
      identity = CameraSessionIdentity(
        cameraName: snapshot.cameraName,
        peripheralID: snapshot.peripheralID,
        historyKey: snapshot.historyKey
      )
      queuedDownloads = snapshot.queue.map {
        CameraSessionQueuedDownload(handle: UInt32($0.handle), mode: $0.downloadMode)
      }
      activeDownloadSubmission = CameraDownloadSubmission(
        id: UUID(),
        requests: queuedDownloads,
        origin: snapshot.origin,
        completionPolicy: snapshot.completionPolicy
      )
      itemStates = Dictionary(uniqueKeysWithValues: queuedDownloads.map { ($0.handle, .queued) })
      itemProgress = [:]
      completedCount = snapshot.completedCount
      failedCount = snapshot.failedCount
      activitySessionID = snapshot.sessionID
      galleryItemCount = queuedDownloads.count
      hasInterruptedRecoverably = true
      // A durable queue is recovery intent, not evidence that iOS is still
      // executing a transfer.  Clear any ActivityKit entry left by the old
      // process; a new activity starts only after the physical PTP lane does.
      activityReporter?.cleanupStale(reason: "restore-persisted-download-awaiting-execution")
      presentation = CameraSessionPresentation(
        phase: .recovering,
        queuedHandles: queuedDownloads.map(\.handle),
        inFlightHandle: nil,
        catalog: .unavailable
      )
      requestRecoveredConnectionIfNeeded()

    case .resumeRecoveredDownload(let availableHandles):
      guard presentation.phase == .recovering, let identity else { return }
      guard !isApplicationInBackground || hasBackgroundExecutionAuthority else { return }
      let savedHandles = Set(savedHandleStore?.savedHandles(identity: identity).map(UInt32.init) ?? [])
      let savedRecoveredHandles = queuedDownloads
        .map(\.handle)
        .filter { savedHandles.contains($0) }
      for handle in savedRecoveredHandles {
        itemStates[handle] = .saved
      }
      // The recovery snapshot is written before an in-flight Photos save can
      // finish. A receipt discovered here represents a completion that happened
      // after that snapshot, so account for it exactly once while removing it
      // from the queue.
      completedCount += savedRecoveredHandles.count
      let unavailableHandles = queuedDownloads
        .map(\.handle)
        .filter { !availableHandles.contains($0) && !savedHandles.contains($0) }
      for handle in unavailableHandles {
        itemStates[handle] = .failed("相机中未找到该恢复文件")
        itemProgress[handle] = "相机中未找到该恢复文件"
      }
      failedCount += unavailableHandles.count
      queuedDownloads.removeAll { savedHandles.contains($0.handle) || !availableHandles.contains($0.handle) }
      let completionPolicy = activeDownloadSubmission?.completionPolicy
        ?? recoveredSnapshot?.completionPolicy
        ?? .returnToGallery
      guard !queuedDownloads.isEmpty else {
        recoveredSnapshot = nil
        recoveryStore?.clear()
        activeDownloadSubmission = nil
        hasInterruptedRecoverably = false
        hasRequestedRecoveredConnection = false
        endActivity(reason: "recovered-download-reconciled")
        applyDownloadCompletionRouting(
          completionPolicy,
          reason: "recovered-download-reconciled"
        )
        return
      }
      let recoveredRequests = queuedDownloads
      queuedDownloads = []
      hasInterruptedRecoverably = false
      recoveredSnapshot = nil
      hasRequestedRecoveredConnection = false
      activeDownloadSubmission = nil
      submitDownload(CameraDownloadSubmission(
        id: UUID(),
        requests: recoveredRequests,
        origin: .recovery,
        completionPolicy: completionPolicy
      ))

    case .clearSavedDownloadHistory(let handle):
      guard let identity else { return }
      savedHandleStore?.removeSaved(handle: Int(handle), identity: identity)
      if itemStates[handle] == .saved {
        itemStates[handle] = .idle
      }
      syncCatalogDownloadedHandles()

    case .clearAllSavedDownloadHistory:
      guard let identity else { return }
      savedHandleStore?.clear(identity: identity)
      for (handle, state) in itemStates where state == .saved {
        itemStates[handle] = .idle
      }
      syncCatalogDownloadedHandles()

    case .disconnectCamera(let reason):
      if presentation.phase == .recovering {
        (recoveryConnector as? CameraSessionRuntimeRecoveryCancelling)?
          .cancelRecoveryConnection(reason: reason)
      }
      // Explicit disconnect fences the current generation and closes the
      // physical transport immediately; retired Catalog children drain later.
      identity = nil
      galleryPresentationPayload = nil
      isQuickDownloadQuerySession = false
      quickDownloadGalleryReadySession = nil
      activeDownloadSubmission = nil
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      releaseDownloadLease()
      releaseBackgroundExecution(reason: reason)
      backgroundMaintainer?.stop(reason: reason)
      _ = beginCatalogSessionTermination(reason: reason)
      pendingGalleryActivation = nil
      queuedDownloads = []
      hasRequestedRecoveredConnection = false
      recoveryStore?.clear()
      endActivity(reason: reason)
      presentation = .idle

    }
  }

  @discardableResult
  func submitDownload(_ submission: CameraDownloadSubmission) -> Bool {
    let isRecoverySubmission = submission.origin == .recovery && presentation.phase == .recovering
    guard identity != nil,
          presentation.phase == .galleryReady || isRecoverySubmission,
          pendingTransportFailureCleanup == nil,
          activeDownloadSubmission == nil else {
      return false
    }
    var seenHandles = Set<UInt32>()
    let requests = submission.requests.filter { seenHandles.insert($0.handle).inserted }
    guard !requests.isEmpty else { return false }
    if !isRecoverySubmission {
      let hasActiveDuplicate = requests.contains {
        switch itemStates[$0.handle] ?? .idle {
        case .queued, .downloading: return true
        case .idle, .failed, .saved: return false
        }
      }
      guard !hasActiveDuplicate else { return false }
    }
    activeDownloadSubmission = CameraDownloadSubmission(
      id: submission.id,
      requests: requests,
      origin: submission.origin,
      completionPolicy: submission.completionPolicy
    )
    queuedDownloads = requests
    if !isRecoverySubmission {
      itemStates = itemStates.filter { $0.value == .saved }
      itemProgress = [:]
      completedCount = 0
      failedCount = 0
    }
    for request in requests {
      itemStates[request.handle] = .queued
    }
    ensureActivitySessionID()
    presentDownloadAwaitingAdmission()
    beginDownloadAdmission(submissionID: submission.id)
    return true
  }

  private func beginDownloadAdmission(submissionID: UUID) {
    downloadAdmissionTask?.cancel()
    let gallerySession = gallerySession
    downloadAdmissionTask = Task { @MainActor [weak self] in
      await gallerySession?.suspendChildWorkForDownload()
      guard let self,
            !Task.isCancelled,
            self.activeDownloadSubmission?.id == submissionID,
            self.identity != nil else {
        await gallerySession?.resumeChildWorkAfterDownload()
        return
      }
      self.downloadAdmissionTask = nil
      self.suspendedGallerySessionForDownload = gallerySession
      self.acquireDownloadLease()
      self.startAdmittedDownload()
    }
  }

  private func startAdmittedDownload() {
    if isApplicationInBackground {
      guard hasBackgroundExecutionAuthority else {
        interruptQueuedDownloadBeforeStarting(reason: "background-execution-unavailable")
        return
      }
      backgroundMaintainer?.start(allowingPtpKeepAlive: false)
      startNextDownload(phase: .downloadingBackground)
    } else if isApplicationTransitioningToBackground {
      let acquiredBackgroundExecution = hasBackgroundExecutionAuthority ||
        (executionAuthority?.acquire(reason: "download-background-transition") ?? false)
      hasBackgroundExecutionAuthority = acquiredBackgroundExecution
      guard acquiredBackgroundExecution else {
        interruptQueuedDownloadBeforeStarting(reason: "background-execution-unavailable")
        return
      }
      presentQueuedDownloadAwaitingLifecycleTransition()
    } else {
      startNextDownload(phase: .downloadingForeground)
    }
  }

  private func presentDownloadAwaitingAdmission(
    phase: CameraSessionPhase? = nil
  ) {
    presentation = CameraSessionPresentation(
      phase: phase ?? (isApplicationInBackground ? .downloadingBackground : .downloadingForeground),
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    publishActivity(reason: "download-awaiting-gallery-children")
  }

  private func finishDownloadAdmission() {
    downloadAdmissionTask?.cancel()
    downloadAdmissionTask = nil
    guard let gallerySession = suspendedGallerySessionForDownload else { return }
    suspendedGallerySessionForDownload = nil
    Task {
      await gallerySession.resumeChildWorkAfterDownload()
    }
  }

  @discardableResult
  func routeQuickDownloadNoMatch(
    completionPolicy: CameraDownloadCompletionPolicy
  ) async -> Bool {
    await routeQuickDownloadTerminal(
      completionPolicy: completionPolicy,
      reason: "quick-download-no-match"
    )
  }

  func routeQuickDownloadFailure(
    completionPolicy: CameraDownloadCompletionPolicy,
    reason: String
  ) async -> Bool {
    await routeQuickDownloadTerminal(
      completionPolicy: completionPolicy,
      reason: reason
    )
  }

  private func routeQuickDownloadTerminal(
    completionPolicy: CameraDownloadCompletionPolicy,
    reason: String
  ) async -> Bool {
    guard identity != nil,
          presentation.phase == .galleryReady,
          activeDownloadSubmission == nil else {
      return false
    }
    applyDownloadCompletionRouting(completionPolicy, reason: reason)
    publishPresentation()
    return true
  }

  @discardableResult
  func observe(_ observer: @escaping (CameraSessionPresentation) -> Void) -> UUID {
    let id = UUID()
    presentationObservers[id] = observer
    observer(presentation)
    return id
  }

  func removeObserver(_ id: UUID) {
    presentationObservers.removeValue(forKey: id)
    incrementalCatalogObservers.removeValue(forKey: id)
    gallerySession?.removeObserver(id)
  }

  @discardableResult
  func observeIncrementalCatalogUpdates(
    _ observer: @escaping (CameraGalleryPresentation, CameraGalleryIncrementalDelta) -> Void
  ) -> UUID {
    let id = UUID()
    incrementalCatalogObservers[id] = observer
    return id
  }

  private func publishIncrementalCatalogUpdate(
    _ catalog: CameraGalleryPresentation,
    _ delta: CameraGalleryIncrementalDelta
  ) {
    // Update the session presentation's catalog without triggering full observer publish
    presentation = CameraSessionPresentation(
      phase: presentation.phase,
      queuedHandles: presentation.queuedHandles,
      inFlightHandle: presentation.inFlightHandle,
      catalog: catalog
    )
    // Keep galleryItemsByHandle in sync so recordSavedHandle can find real filenames
    for handle in delta.changedHandles {
      if let item = catalog.items.first(where: { $0.handle == Int(handle) }) {
        galleryItemsByHandle[UInt32(handle)] = item
      }
    }
    for observer in incrementalCatalogObservers.values {
      observer(catalog, delta)
    }
  }

  var isDownloading: Bool { isDownloadingPhase || presentation.phase == .cancelling }

  var canCancelDownload: Bool {
    isDownloading || presentation.phase == .recovering || presentation.phase == .interrupted
  }

  func stopDownloadAndWait() async {
    // Override completion policy before cancelling — once the user requests stop,
    // we must return to gallery regardless of whether the transfer finishes
    // normally (race) or gets cancelled.
    activeDownloadSubmission = activeDownloadSubmission.map {
      CameraDownloadSubmission(
        id: $0.id,
        requests: $0.requests,
        origin: $0.origin,
        completionPolicy: .returnToGallery
      )
    }
    send(.cancelDownloadByUser)
    guard presentation.phase == .cancelling else { return }
    let hardInterruptTask = Task { @MainActor [weak self] in
      guard let self else { return }
      try? await Task.sleep(
        nanoseconds: self.userCancellationHardInterruptDelayNanoseconds
      )
      guard !Task.isCancelled, self.presentation.phase == .cancelling else { return }
      self.forceFinishUserCancelledDownloadAfterSoftCancellationTimeout()
    }
    defer { hardInterruptTask.cancel() }
    await withCheckedContinuation { continuation in
      guard presentation.phase == .cancelling else {
        continuation.resume()
        return
      }
      downloadStopWaiters.append(continuation)
    }
  }

  var recoveryIdentity: CameraSessionIdentity? {
    presentation.phase == .recovering ? identity : nil
  }

  var hasPendingRecovery: Bool {
    presentation.phase == .recovering
  }

  /// A persisted queue is recovery intent only. This read-only signal lets
  /// presentation code ask the user before recovery changes runtime state.
  var hasPersistedDownloadRecovery: Bool {
    recoveryStore?.loadInterruptedRecoverable() != nil
  }

  /// Catalog work is valid only while the runtime owns a healthy, idle gallery
  /// lane. Presentation code must not infer readiness from "not downloading":
  /// recovery is also not a download state.
  var canAcceptCatalogCommands: Bool {
    canSubmitCatalogCommand
  }

  func downloadState(for handle: Int) -> CameraVendorDownloadState {
    itemStates[UInt32(handle)] ?? .idle
  }

  func downloadProgressText(for handle: Int) -> String? {
    itemProgress[UInt32(handle)]
  }

  func downloadableHandles(from handles: [Int]) -> [Int] {
    handles.filter {
      switch downloadState(for: $0) {
      case .idle, .failed:
        return true
      case .queued, .downloading, .saved:
        return false
      }
    }
  }

  func savedDownloadHandles() -> Set<Int> {
    Set(itemStates.compactMap { handle, state in state == .saved ? Int(handle) : nil })
  }

  func downloadHistoryItems() -> [CameraVendorGalleryItem] {
    guard let identity else { return [] }
    return savedHandleStore?.historyItems(identity: identity) ?? []
  }

  func recordSavedHandle(_ handle: UInt32) {
    guard let identity else { return }
    savedHandleStore?.recordSaved(
      handle: Int(handle),
      item: galleryItemsByHandle[handle],
      identity: identity
    )
    syncCatalogDownloadedHandles(including: [Int(handle)])
  }

  func requestPreviewImageWithInfo(
    for identity: CameraGalleryMediaIdentity
  ) async throws -> CameraVendorGalleryPreview {
    try validateCatalogCommand()
    guard identity.variant == .hdPreview,
          galleryCatalogIdentity == identity.catalog,
          gallerySession?.catalogIdentity == identity.catalog,
          gallerySession?.presentation.items.contains(where: {
            $0.handle == identity.handle
          }) == true else {
      throw CancellationError()
    }
    let preview = try await transport.fetchPreviewImageWithInfo(for: identity.handle)
    try validateCatalogCommand()
    guard galleryCatalogIdentity == identity.catalog,
          gallerySession?.catalogIdentity == identity.catalog,
          gallerySession?.presentation.items.contains(where: {
            $0.handle == identity.handle
          }) == true else {
      throw CancellationError()
    }
    return preview
  }

  private var canSubmitCatalogCommand: Bool {
    identity != nil &&
      isCatalogTransportUsable &&
      catalogSessionID != nil &&
      presentation.phase == .galleryReady &&
      !hasDownloadLease
  }

  private func validateCatalogCommand() throws {
    guard canSubmitCatalogCommand else { throw CancellationError() }
  }

  private func interruptRecoverably(reason: String) {
    guard beginRecoverableInterruption(reason: reason) else { return }
    finishRecoverableInterruption(reason: reason)
  }

  private func interruptRecoverablyAfterCatalogShutdown(
    reason: String,
    transportMessage: String
  ) {
    guard beginRecoverableInterruption(reason: reason) else { return }
    let gallerySession = gallerySession
    let catalogSessionID = catalogSessionID
    let transportBinding = activeTransportBinding
    guard let leaseID = downloadLeaseID else {
      finishRecoverableInterruption(reason: reason)
      return
    }
    let cleanup = PendingTransportFailureCleanup(
      leaseID: leaseID,
      catalogSessionID: catalogSessionID,
      transportBinding: transportBinding,
      reason: reason
    )
    pendingTransportFailureCleanup = cleanup
    Task { @MainActor [weak self] in
      await gallerySession?.markTransportLost(transportMessage)
      self?.finishTransportFailureCleanup(cleanup)
    }
  }

  private func finishTransportFailureCleanup(_ cleanup: PendingTransportFailureCleanup) {
    guard pendingTransportFailureCleanup == cleanup else { return }
    pendingTransportFailureCleanup = nil
    let ownsCurrentSession = catalogSessionID == cleanup.catalogSessionID &&
      activeTransportBinding == cleanup.transportBinding
    if ownsCurrentSession {
      transport.cancelActiveTransfer(reason: cleanup.reason)
      activeTransportBinding = nil
      isCatalogTransportUsable = false
      releaseBackgroundExecution(reason: cleanup.reason)
      backgroundMaintainer?.stop(reason: cleanup.reason)
    }
    releaseDownloadLease(id: cleanup.leaseID)
    guard ownsCurrentSession else { return }
    defer { publishPresentation() }
    guard presentation.phase != .cancelling else {
      // User explicitly cancelled during transport failure cleanup —
      // always return to gallery, not home.
      let completionPolicy: CameraDownloadCompletionPolicy = .returnToGallery
      endActivity(reason: "user-cancelled-download")
      recoveryStore?.clear()
      queuedDownloads = []
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      hasRequestedRecoveredConnection = false
      activeDownloadSubmission = nil
      applyDownloadCompletionRouting(
        completionPolicy,
        reason: "user-cancelled-download"
      )
      return
    }
    guard hasInterruptedRecoverably, isDownloadingPhase else { return }
    presentation = CameraSessionPresentation(
      phase: .recovering,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    endLiveActivityRetainingSessionID(reason: cleanup.reason)
    requestRecoveredConnectionIfNeeded()
  }

  private func beginRecoverableInterruption(reason: String) -> Bool {
    guard isDownloadingPhase,
          !hasInterruptedRecoverably,
          let identity else { return false }
    ensureActivitySessionID()
    guard persistInterruptedRecovery(
      identity: identity,
      inFlightHandle: presentation.inFlightHandle,
      reason: reason
    ) else {
      failInterruptedRecoveryPersistence(reason: reason)
      return false
    }
    hasInterruptedRecoverably = true
    cancelPendingDownloadAdmission()
    logLifecycleTransition(event: "recovery-persisted", details: "reason=\(reason)")
    return true
  }

  private func finishRecoverableInterruption(reason: String) {
    transport.cancelActiveTransfer(reason: reason)
    activeTransportBinding = nil
    isCatalogTransportUsable = false
    releaseDownloadLease()
    releaseBackgroundExecution(reason: reason)
    backgroundMaintainer?.stop(reason: reason)
    presentation = CameraSessionPresentation(
      phase: .recovering,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    endLiveActivityRetainingSessionID(reason: reason)
    requestRecoveredConnectionIfNeeded()
  }

  private func interruptQueuedDownloadBeforeStarting(reason: String) {
    guard !hasInterruptedRecoverably,
          let identity else {
      return
    }
    ensureActivitySessionID()
    guard persistInterruptedRecovery(identity: identity, inFlightHandle: nil, reason: reason) else {
      failInterruptedRecoveryPersistence(reason: reason)
      return
    }
    hasInterruptedRecoverably = true
    finishDownloadAdmission()
    releaseBackgroundExecution(reason: reason)
    releaseDownloadLease()
    backgroundMaintainer?.stop(reason: reason)
    presentation = CameraSessionPresentation(
      phase: .recovering,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    endLiveActivityRetainingSessionID(reason: reason)
    requestRecoveredConnectionIfNeeded()
  }

  private var isDownloadingPhase: Bool {
    presentation.phase == .downloadingForeground || presentation.phase == .downloadingBackground
  }

  private func persistInterruptedRecovery(
    identity: CameraSessionIdentity,
    inFlightHandle: UInt32?,
    reason: String
  ) -> Bool {
    guard let recoveryStore,
          let activeDownloadSubmission else { return false }
    do {
      try recoveryStore.persistInterruptedRecoverable(
        sessionID: activitySessionID ?? UUID(),
        identity: identity,
        downloads: queuedDownloads,
        inFlightHandle: inFlightHandle,
        completedCount: completedCount,
        failedCount: failedCount,
        origin: activeDownloadSubmission.origin,
        completionPolicy: activeDownloadSubmission.completionPolicy,
        reason: reason
      )
      return true
    } catch {
      CameraVendorFileLogger.log("[RUNTIME_RECOVERY_PERSIST_FAILED] reason=\(reason) error=\(error.localizedDescription)")
      return false
    }
  }

  private func failInterruptedRecoveryPersistence(reason: String) {
    transport.cancelActiveTransfer(reason: reason)
    activeTransportBinding = nil
    isCatalogTransportUsable = false
    releaseDownloadLease()
    releaseBackgroundExecution(reason: reason)
    backgroundMaintainer?.stop(reason: reason)
    if let inFlightHandle = presentation.inFlightHandle {
      itemStates[inFlightHandle] = .failed("无法保存下载恢复状态")
      itemProgress[inFlightHandle] = "无法保存下载恢复状态"
      failedCount += 1
    }
    presentation = CameraSessionPresentation(
      phase: .interrupted,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    endLiveActivityRetainingSessionID(reason: "recovery-persistence-failed")
  }

  private func requestRecoveredConnectionIfNeeded() {
    guard presentation.phase == .recovering,
          !isApplicationInBackground,
          !hasRequestedRecoveredConnection,
          let identity else {
      return
    }
    guard let recoveryConnector else { return }
    hasRequestedRecoveredConnection = true
    recoveryConnector.requestRecoveredConnection(identity: identity) { [weak self] accepted in
      guard let self,
            !accepted,
            self.presentation.phase == .recovering,
            self.identity == identity else {
        return
      }
      self.hasRequestedRecoveredConnection = false
    }
  }

  private func completeCancelledTransfer(handle: UInt32) {
    guard presentation.phase == .cancelling,
          presentation.inFlightHandle == handle else {
      return
    }
    finishUserCancelledDownload(reason: "user-cancelled-download-drained")
  }

  private func finishUserCancelledDownload(reason: String) {
    finishDownloadAdmission()
    releaseBackgroundExecution(reason: reason)
    releaseDownloadLease()
    backgroundMaintainer?.stop(reason: reason)
    endActivity(reason: "user-cancelled-download")
    recoveryStore?.clear()
    queuedDownloads = []
    recoveredSnapshot = nil
    hasInterruptedRecoverably = false
    // User explicitly cancelled — always return to gallery.
    let completionPolicy: CameraDownloadCompletionPolicy = .returnToGallery
    activeDownloadSubmission = nil
    applyDownloadCompletionRouting(completionPolicy, reason: reason)
  }

  private func forceFinishUserCancelledDownloadAfterSoftCancellationTimeout() {
    guard presentation.phase == .cancelling else { return }
    let reason = "user-cancelled-download-timeout"
    transport.cancelActiveTransfer(reason: reason)
    _ = beginCatalogSessionTermination(reason: reason)
    finishUserCancelledDownload(reason: reason)
    publishPresentation()
  }

  private func startNextDownload(phase: CameraSessionPhase) {
    guard !isApplicationTransitioningToBackground else {
      presentQueuedDownloadAwaitingLifecycleTransition()
      return
    }
    guard let next = queuedDownloads.first else { return }
    presentation = CameraSessionPresentation(
      phase: phase,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: next.handle,
      catalog: presentation.catalog
    )
    itemStates[next.handle] = .downloading
    itemProgress[next.handle] = "\(completedCount + failedCount + 1)/\(completedCount + failedCount + queuedDownloads.count)"
    logLifecycleTransition(event: "transfer-started", details: "handle=\(next.handle)")
    publishActivity(reason: "download-started")
    transport.startTransfer(handle: next.handle, mode: next.mode)
  }

  private func logLifecycleTransition(event: String, details: String = "") {
    let session = activitySessionID?.uuidString ?? "none"
    let inFlight = presentation.inFlightHandle.map(String.init) ?? "none"
    let suffix = details.isEmpty ? "" : " \(details)"
    CameraVendorFileLogger.log(
      "[RUNTIME_LIFECYCLE] event=\(event) session=\(session) phase=\(presentation.phase) background=\(isApplicationInBackground) queue=\(queuedDownloads.count) inFlight=\(inFlight)\(suffix)"
    )
  }

  private func presentQueuedDownloadAwaitingLifecycleTransition() {
    presentation = CameraSessionPresentation(
      phase: .downloadingForeground,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    publishActivity(reason: "download-awaiting-background-transition")
  }

  private func completeTransfer(handle: UInt32) {
    guard isDownloadingPhase,
          presentation.inFlightHandle == handle,
          queuedDownloads.first?.handle == handle else {
      return
    }
    queuedDownloads.removeFirst()
    itemStates[handle] = .saved
    itemProgress[handle] = nil
    syncCatalogDownloadedHandles()
    completedCount += 1
    guard !queuedDownloads.isEmpty else {
      releaseBackgroundExecution(reason: "download-completed")
      releaseDownloadLease()
      backgroundMaintainer?.stop(reason: "download-completed")
      recoveryStore?.clear()
      endActivity(reason: "download-completed")
      finishDownloadSubmission(reason: "download-completed")
      return
    }
    startNextDownload(phase: presentation.phase)
  }

  private func completeSaveFailure(handle: UInt32, error: Error) {
    guard isDownloadingPhase,
          presentation.inFlightHandle == handle,
          queuedDownloads.first?.handle == handle else {
      return
    }
    queuedDownloads.removeFirst()
    itemStates[handle] = .failed(error.localizedDescription)
    itemProgress[handle] = error.localizedDescription
    failedCount += 1
    guard !queuedDownloads.isEmpty else {
      releaseBackgroundExecution(reason: "download-save-failed")
      releaseDownloadLease()
      backgroundMaintainer?.stop(reason: "download-save-failed")
      recoveryStore?.clear()
      endActivity(reason: "download-save-failed")
      finishDownloadSubmission(reason: "download-save-failed")
      return
    }
    startNextDownload(phase: presentation.phase)
  }

  private func present(phase: CameraSessionPhase) {
    presentation = CameraSessionPresentation(
      phase: phase,
      queuedHandles: queuedDownloads.map(\.handle),
      inFlightHandle: queuedDownloads.first?.handle,
      catalog: presentation.catalog
    )
  }

  private func releaseBackgroundExecution(reason: String) {
    hasBackgroundExecutionAuthority = false
    executionAuthority?.release(reason: reason)
  }

  private func acquireDownloadLease() {
    guard !hasDownloadLease else { return }
    hasDownloadLease = true
    downloadLeaseID = UUID()
    transport.beginDownloadLease()
  }

  private func synchronizeSavedHistoryFromStore() {
    guard let identity else { return }
    for handle in savedHandleStore?.savedHandles(identity: identity) ?? [] {
      itemStates[UInt32(handle)] = .saved
    }
  }

  private func syncCatalogDownloadedHandles(including additionalHandles: Set<Int> = []) {
    guard let gallerySession else { return }
    let handles = savedDownloadHandles().union(additionalHandles)
    Task {
      await gallerySession.updateDownloadedHandles(handles)
    }
  }

  private func beginCatalogSessionTermination(reason: String) -> Task<Void, Never> {
    discardDownloadAdmissionForTermination()
    if gallerySession == nil,
       catalogQueryEngine == nil,
       catalogGenerationFence == nil,
       activeTransportBinding == nil,
       let catalogLifecycleTask {
      return catalogLifecycleTask
    }
    let previousSession = gallerySession
    let previousQueryEngine = catalogQueryEngine
    let previousGenerationFence = catalogGenerationFence
    let previousLifecycleTask = catalogLifecycleTask
    catalogSessionID = nil
    galleryCatalogIdentity = nil
    gallerySession = nil
    catalogQueryEngine = nil
    catalogGenerationFence = nil
    previousGenerationFence?.invalidate()
    transport.terminateCameraCommunication(reason: reason)
    activeTransportBinding = nil
    isCatalogTransportUsable = false
    let terminationTask = Task { @MainActor in
      await previousQueryEngine?.invalidate()
      await previousSession?.invalidate()
      await previousLifecycleTask?.value
    }
    catalogLifecycleTask = terminationTask
    return terminationTask
  }

  private func discardDownloadAdmissionForTermination() {
    downloadAdmissionTask?.cancel()
    downloadAdmissionTask = nil
    suspendedGallerySessionForDownload = nil
  }

  private func cancelPendingDownloadAdmission() {
    downloadAdmissionTask?.cancel()
    downloadAdmissionTask = nil
  }

  private func terminateCatalogSession(reason: String) {
    _ = beginCatalogSessionTermination(reason: reason)
  }

  private func finishDownloadSubmission(reason: String) {
    let completionPolicy = activeDownloadSubmission?.completionPolicy ?? .returnToGallery
    finishDownloadAdmission()
    activeDownloadSubmission = nil
    queuedDownloads = []
    switch completionPolicy {
    case .returnToGallery:
      applyReturnToGalleryRouting()
    case .disconnectToHome:
      applyDownloadCompletionRouting(completionPolicy, reason: reason)
      publishPresentation()
    }
  }

  private func applyDownloadCompletionRouting(
    _ completionPolicy: CameraDownloadCompletionPolicy,
    reason: String
  ) {
    switch completionPolicy {
    case .returnToGallery:
      applyReturnToGalleryRouting()
    case .disconnectToHome:
      identity = nil
      galleryPresentationPayload = nil
      isQuickDownloadQuerySession = false
      quickDownloadGalleryReadySession = nil
      pendingGalleryActivation = nil
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      hasRequestedRecoveredConnection = false
      presentation = .idle
      terminateCatalogSession(reason: reason)
      onPresentationDestinationReady?(.home)
    }
  }

  private func applyReturnToGalleryRouting() {
    if isQuickDownloadQuerySession,
       beginGalleryActivationAfterQuickDownload() {
      return
    }
    let hasUsableCatalogTransport = identity != nil &&
      isCatalogTransportUsable &&
      catalogSessionID != nil
    presentation = CameraSessionPresentation(
      phase: hasUsableCatalogTransport ? .galleryReady :
        (identity == nil ? .interrupted : .recovering),
      queuedHandles: [],
      inFlightHandle: nil,
      catalog: presentation.catalog
    )
    routeDownloadCompletionToGalleryIfPossible()
    requestRecoveredConnectionIfNeeded()
  }

  private func beginGalleryActivationAfterQuickDownload() -> Bool {
    guard let payload = galleryPresentationPayload,
          identity != nil,
          let session = quickDownloadGalleryReadySession else {
      return false
    }
    isQuickDownloadQuerySession = false
    quickDownloadGalleryReadySession = nil
    pendingGalleryActivation = PendingGalleryActivation(
      resultState: .galleryReady(session),
      destination: .gallery(payload),
      completion: { _ in }
    )
    presentation = CameraSessionPresentation(
      phase: .galleryLoading,
      queuedHandles: [],
      inFlightHandle: nil,
      catalog: .unavailable
    )
    configureCatalogRuntime()
    return true
  }

  private func routeDownloadCompletionToGalleryIfPossible() {
    guard let galleryPresentationPayload else { return }
    onPresentationDestinationReady?(.gallery(galleryPresentationPayload))
  }

  func exitGalleryAndDisconnect(reason: String) {
    terminateCatalogSession(reason: reason)
    clearGallerySessionStateAfterDisconnect()
  }

  @discardableResult
  func exitGalleryAndDisconnect(
    reason: String,
    expectedBinding: CameraSessionRuntimeBinding
  ) -> Bool {
    guard activeTransportBinding == expectedBinding else { return false }
    exitGalleryAndDisconnect(reason: reason)
    return true
  }

  private func clearGallerySessionStateAfterDisconnect() {
    recoveryStore?.clear()
    identity = nil
    galleryPresentationPayload = nil
    isQuickDownloadQuerySession = false
    quickDownloadGalleryReadySession = nil
    activeDownloadSubmission = nil
    recoveredSnapshot = nil
    hasInterruptedRecoverably = false
    hasRequestedRecoveredConnection = false
    queuedDownloads = []
    itemStates = [:]
    itemProgress = [:]
    galleryItemsByHandle = [:]
    presentation = .idle
    publishPresentation()
  }

  private func completePendingGalleryActivationIfNeeded() {
    guard let pendingGalleryActivation else { return }
    self.pendingGalleryActivation = nil
    onPresentationDestinationReady?(pendingGalleryActivation.destination)
    pendingGalleryActivation.completion(pendingGalleryActivation.resultState)
  }

  private func failPendingGalleryActivationIfNeeded(message: String) {
    guard let pendingGalleryActivation else { return }
    self.pendingGalleryActivation = nil
    pendingGalleryActivation.completion(.failed(IOSCameraConnectionIssue(
      step: .loadGallery,
      reason: message
    )))
  }

  private func releaseDownloadLease() {
    releaseDownloadLease(id: nil)
  }

  private func releaseDownloadLease(id: UUID?) {
    guard hasDownloadLease else { return }
    if let id, id != downloadLeaseID { return }
    hasDownloadLease = false
    downloadLeaseID = nil
    transport.endDownloadLease()
  }

  private func ensureActivitySessionID() {
    if activitySessionID == nil {
      activitySessionID = UUID()
    }
  }

  private func publishActivity(reason: String) {
    guard let sessionID = activitySessionID, let identity else { return }
    guard isLiveActivityExecutionActive else {
      endLiveActivityRetainingSessionID(reason: reason)
      return
    }
    let totalCount = completedCount + failedCount + queuedDownloads.count
    activityReporter?.publish(
      CameraSessionRuntimeActivitySnapshot(
        sessionID: sessionID,
        cameraName: identity.cameraName,
        galleryItemCount: galleryItemCount,
        downloadCompletedCount: completedCount + failedCount,
        downloadTotalCount: totalCount,
        isBackground: isApplicationInBackground,
        isShowingDownloadProgress: totalCount > 0 && !queuedDownloads.isEmpty
      ),
      reason: reason
    )
  }

  private var isLiveActivityExecutionActive: Bool {
    isDownloadingPhase || presentation.phase == .cancelling
  }

  private func endLiveActivityRetainingSessionID(reason: String) {
    guard let sessionID = activitySessionID else { return }
    activityReporter?.end(sessionID: sessionID, reason: reason)
  }

  private func endActivity(reason: String) {
    guard let sessionID = activitySessionID else { return }
    activityReporter?.end(sessionID: sessionID, reason: reason)
    activitySessionID = nil
  }

  private func publishPresentation() {
    for observer in presentationObservers.values {
      observer(presentation)
    }
    guard presentation.phase != .cancelling, !downloadStopWaiters.isEmpty else { return }
    let waiters = downloadStopWaiters
    downloadStopWaiters.removeAll(keepingCapacity: false)
    waiters.forEach { $0.resume() }
  }

  // MARK: - HEIF Count Sweep Experiment (Diagnostic Only)

  func runCountSweepExperiment() {
    guard presentation.phase == .galleryReady else {
      onConnectionLogAppended?("[OBS] COUNT_SWEEP_REJECTED phase=\(presentation.phase)")
      return
    }
    onConnectionLogAppended?("[OBS] COUNT_SWEEP_EXPERIMENT_REQUESTED")
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await self.transport.executeCountSweepExperiment()
        self.onConnectionLogAppended?(result.diagnosticSummary)
        if result.heifExact616 {
          self.onConnectionLogAppended?("[OBS] COUNT_SWEEP_SUCCESS exact_616=true — HEIF catalog verified")
        } else {
          self.onConnectionLogAppended?(
            "[OBS] COUNT_SWEEP_FAILED exact_616=false — HEIF remains unverified " +
            "(declared=\(result.heifDeclaredCount.map(String.init) ?? "nil") handles=\(result.heifHandleCount))"
          )
        }
        // Reload the initial catalog to restore normal gallery state
        await self.gallerySession?.reload()
      } catch {
        self.onConnectionLogAppended?("[OBS] COUNT_SWEEP_ERROR \(error.localizedDescription)")
        // Attempt to restore gallery state even after failure
        await self.gallerySession?.reload()
      }
    }
  }
}
