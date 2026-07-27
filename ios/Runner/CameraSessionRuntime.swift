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

struct CameraSessionQueuedDownload {
  let handle: UInt32
  let mode: CameraVendorTransferDownloadMode
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
  private(set) var presentation = CameraSessionPresentation.idle
  private var identity: CameraSessionIdentity?
  private var queuedDownloads: [CameraSessionQueuedDownload] = []
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
  private(set) var galleryPresentationPayload: CameraSessionRuntimeGalleryPresentationPayload?
  private var galleryItemCount = 0
  private var catalogRuntime: CameraGalleryCatalogRuntime?
  private var catalogLifecycleTask: Task<Void, Never>?
  private var catalogSessionID: UUID?
  private var nextCatalogIntentSubmissionRawValue: UInt64 = 0
  private var pendingGalleryActivation: PendingGalleryActivation?
  private var hasRequestedRecoveredConnection = false
  private var presentationObservers: [UUID: (CameraSessionPresentation) -> Void] = [:]
  private var incrementalCatalogObservers: [UUID: (CameraGalleryPresentation, Set<Int>) -> Void] = [:]
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
    legacyResumeMigrator: CameraSessionRuntimeLegacyResumeMigrating? = nil
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

  func submitGalleryIntent(_ intent: CameraGalleryFilterIntent) {
    guard canSubmitCatalogCommand, let catalogRuntime else { return }
    nextCatalogIntentSubmissionRawValue &+= 1
    let submissionID = CameraGalleryIntentSubmissionID(
      rawValue: nextCatalogIntentSubmissionRawValue
    )
    let downloadedHandles = savedDownloadHandles()
    Task {
      await catalogRuntime.submit(
        intent,
        submissionID: submissionID,
        downloadedHandles: downloadedHandles
      )
    }
  }

  func submitUnsupportedGalleryFilter(_ reason: CameraGalleryUnsupportedReason) {
    guard canSubmitCatalogCommand, let catalogRuntime else { return }
    nextCatalogIntentSubmissionRawValue &+= 1
    let submissionID = CameraGalleryIntentSubmissionID(
      rawValue: nextCatalogIntentSubmissionRawValue
    )
    Task {
      await catalogRuntime.submitUnsupported(reason, submissionID: submissionID)
    }
  }

  func requestVisibleGalleryThumbnails(handles: [Int]) {
    guard canSubmitCatalogCommand, let catalogRuntime else { return }
    Task {
      await catalogRuntime.requestVisibleThumbnails(handles: handles)
    }
  }

  func cancelActiveThumbnailWork() async {
    await catalogRuntime?.cancelActiveThumbnailWork()
  }

  func suspendGalleryChildWorkForHighDefinitionPreview() async {
    await catalogRuntime?.suspendChildWorkForHighDefinitionPreview()
  }

  func resumeGalleryChildWorkAfterHighDefinitionPreview() async {
    await catalogRuntime?.resumeChildWorkAfterHighDefinitionPreview()
  }

  private func configureCatalogRuntime() {
    let sessionID = UUID()
    let previousRuntime = catalogRuntime
    let previousLifecycleTask = catalogLifecycleTask
    catalogSessionID = sessionID
    catalogRuntime = nil
    catalogLifecycleTask = Task { @MainActor [weak self] in
      await previousLifecycleTask?.value
      await previousRuntime?.cancelAllChildren()
      guard let self, self.catalogSessionID == sessionID else { return }

      let source = CameraSessionGalleryCatalogRuntimeSource(transport: self.transport)
      let catalogRuntime = CameraGalleryCatalogRuntime(
        source: source,
        publishPresentation: { [weak self] catalog in
          guard self?.catalogSessionID == sessionID else { return }
          self?.installCatalogPresentation(catalog)
        },
        publishIncrementalUpdate: { [weak self] catalog, handles in
          guard self?.catalogSessionID == sessionID else { return }
          self?.publishIncrementalCatalogUpdate(catalog, handles)
        },
        reportTransportEvidence: { [weak self] failure in
          guard failure.provesTransportLost,
                self?.catalogSessionID == sessionID else { return }
          self?.send(
            .transportFailed(
              NSError(
                domain: "CameraGalleryCatalogRuntime",
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [NSLocalizedDescriptionKey: failure.message]
              )
            )
          )
        }
      )
      self.catalogRuntime = catalogRuntime
      await catalogRuntime.updateDownloadedHandles(self.savedDownloadHandles())
      guard self.catalogSessionID == sessionID else {
        await catalogRuntime.cancelAllChildren()
        return
      }
      await catalogRuntime.start(initial: .all)
    }
  }

  private func installCatalogPresentation(_ catalog: CameraGalleryPresentation) {
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
    activeTransportBinding = binding
    return binding
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

  func cancelConnectionWorker(reason: String) {
    connectionWorker?.cancel(reason: reason)
  }

  /// Activates the transport only after the runtime-owned connection worker has
  /// produced a GalleryReady navigation event. Home receives the returned
  /// presentation payload solely to render the gallery.
  func activateRememberedGallerySession() throws -> CameraSessionRuntimeGalleryPresentationPayload {
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
    send(
      .enterGallery(
        CameraSessionIdentity(
          cameraName: payload.summary.navigationTitle,
          peripheralID: rememberedPeripheralID,
          historyKey: payload.summary.serialNumber.isEmpty
            ? payload.summary.deviceName
            : payload.summary.serialNumber
        )
      )
    )
    galleryPresentationPayload = payload
    return payload
  }

  func send(_ command: CameraSessionCommand) {
    defer { publishPresentation() }
    switch command {
    case .enterGallery(let identity):
      if let recoveredSnapshot,
         (identity.peripheralID == nil || recoveredSnapshot.peripheralID == identity.peripheralID),
         presentation.phase == .recovering {
        self.identity = identity
        configureCatalogRuntime()
        return
      }
      self.identity = identity
      hasRequestedRecoveredConnection = false
      endActivity(reason: "superseded-gallery")
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
        phase: .galleryLoading,
        queuedHandles: [],
        inFlightHandle: nil,
        catalog: .unavailable
      )
      configureCatalogRuntime()
      (backgroundMaintainer as? CameraSessionRuntimeBackgroundExecutionPreparing)?
        .prepareBackgroundExecution()

    case .startDownload(let handles, let mode):
      beginDownload(requests: handles.map { CameraSessionQueuedDownload(handle: $0, mode: mode) })

    case .startDownloadRequests(let requests):
      beginDownload(requests: requests)

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
      releaseBackgroundExecution(reason: "user-cancelled-download")
      backgroundMaintainer?.stop(reason: "user-cancelled-download")
      endActivity(reason: "user-cancelled-download")
      recoveryStore?.clear()
      queuedDownloads = []
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      hasRequestedRecoveredConnection = false
      presentation = presentation.phase == .recovering
        ? .idle
        : CameraSessionPresentation(
          phase: .galleryReady,
          queuedHandles: [],
          inFlightHandle: nil,
          catalog: presentation.catalog
        )

    case .applicationWillResignActive:
      isApplicationTransitioningToBackground = true
      logLifecycleTransition(event: "will-resign-active")
      guard identity != nil, isDownloadingPhase else { return }
      let acquiredBackgroundExecution = hasBackgroundExecutionAuthority ||
        (executionAuthority?.acquire(reason: "download-background-transition") ?? false)
      hasBackgroundExecutionAuthority = acquiredBackgroundExecution
      guard acquiredBackgroundExecution else {
        interruptRecoverably(reason: "background-execution-unavailable")
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
        if presentation.inFlightHandle == nil, !queuedDownloads.isEmpty {
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
        if presentation.inFlightHandle == nil, !queuedDownloads.isEmpty {
          startNextDownload(phase: .downloadingForeground)
        } else {
          present(phase: .downloadingForeground)
        }
      } else if isDownloadingPhase,
                presentation.inFlightHandle == nil,
                !queuedDownloads.isEmpty {
        startNextDownload(phase: .downloadingForeground)
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
        let catalogRuntime = catalogRuntime
        let catalogSessionID = catalogSessionID
        let transportBinding = activeTransportBinding
        Task { @MainActor [weak self] in
          await catalogRuntime?.markTransportLost(error.localizedDescription)
          guard let self,
                self.catalogSessionID == catalogSessionID,
                self.activeTransportBinding == transportBinding else { return }
          self.transport.terminateCameraCommunication(reason: "catalog-transport-lost")
          self.activeTransportBinding = nil
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
      guard !queuedDownloads.isEmpty else {
        recoveredSnapshot = nil
        recoveryStore?.clear()
        presentation = CameraSessionPresentation(
          phase: .galleryReady,
          queuedHandles: [],
          inFlightHandle: nil,
          catalog: presentation.catalog
        )
        endActivity(reason: "recovered-download-reconciled")
        return
      }
      hasInterruptedRecoverably = false
      recoveredSnapshot = nil
      hasRequestedRecoveredConnection = false
      acquireDownloadLease()
      if isApplicationInBackground {
        backgroundMaintainer?.start(allowingPtpKeepAlive: false)
        startNextDownload(phase: .downloadingBackground)
      } else {
        startNextDownload(phase: .downloadingForeground)
      }

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
      // Explicit disconnect releases session/presentation ownership now. The
      // transport still closes only after Catalog children have drained.
      identity = nil
      galleryPresentationPayload = nil
      releaseDownloadLease()
      releaseBackgroundExecution(reason: reason)
      backgroundMaintainer?.stop(reason: reason)
      terminateCatalogSession(reason: reason)
      pendingGalleryActivation = nil
      queuedDownloads = []
      hasRequestedRecoveredConnection = false
      endActivity(reason: reason)
      presentation = .idle

    }
  }

  private func beginDownload(requests: [CameraSessionQueuedDownload]) {
    guard identity != nil,
          presentation.phase == .galleryReady,
          pendingTransportFailureCleanup == nil,
          !requests.isEmpty else {
      return
    }
    queuedDownloads = requests
    itemStates = itemStates.filter { $0.value == .saved }
    for request in requests {
      itemStates[request.handle] = .queued
    }
    itemProgress = [:]
    completedCount = 0
    failedCount = 0
    ensureActivitySessionID()
    acquireDownloadLease()
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
  }

  @discardableResult
  func observeIncrementalCatalogUpdates(_ observer: @escaping (CameraGalleryPresentation, Set<Int>) -> Void) -> UUID {
    let id = UUID()
    incrementalCatalogObservers[id] = observer
    return id
  }

  private func publishIncrementalCatalogUpdate(_ catalog: CameraGalleryPresentation, _ handles: Set<Int>) {
    // Update the session presentation's catalog without triggering full observer publish
    presentation = CameraSessionPresentation(
      phase: presentation.phase,
      queuedHandles: presentation.queuedHandles,
      inFlightHandle: presentation.inFlightHandle,
      catalog: catalog
    )
    // Keep galleryItemsByHandle in sync so recordSavedHandle can find real filenames
    for handle in handles {
      if let item = catalog.items.first(where: { $0.handle == Int(handle) }) {
        galleryItemsByHandle[UInt32(handle)] = item
      }
    }
    for observer in incrementalCatalogObservers.values {
      observer(catalog, handles)
    }
  }

  var isDownloading: Bool { isDownloadingPhase || presentation.phase == .cancelling }

  var canCancelDownload: Bool {
    isDownloading || presentation.phase == .recovering || presentation.phase == .interrupted
  }

  func stopDownloadAndWait() async {
    send(.cancelDownloadByUser)
    guard presentation.phase == .cancelling else { return }
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

  func requestPreviewImage(for handle: Int) async throws -> Data {
    try validateCatalogCommand()
    return try await transport.fetchPreviewImage(for: handle)
  }

  func requestPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    try validateCatalogCommand()
    return try await transport.fetchPreviewImageWithInfo(for: handle)
  }

  private var canSubmitCatalogCommand: Bool {
    identity != nil && presentation.phase == .galleryReady && !hasDownloadLease
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
    let catalogRuntime = catalogRuntime
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
      await catalogRuntime?.markTransportLost(transportMessage)
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
      releaseBackgroundExecution(reason: cleanup.reason)
      backgroundMaintainer?.stop(reason: cleanup.reason)
    }
    releaseDownloadLease(id: cleanup.leaseID)
    guard ownsCurrentSession else { return }
    defer { publishPresentation() }
    guard presentation.phase != .cancelling else {
      endActivity(reason: "user-cancelled-download")
      recoveryStore?.clear()
      queuedDownloads = []
      recoveredSnapshot = nil
      hasInterruptedRecoverably = false
      presentation = CameraSessionPresentation(
        phase: .interrupted,
        queuedHandles: [],
        inFlightHandle: nil,
        catalog: presentation.catalog
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
    logLifecycleTransition(event: "recovery-persisted", details: "reason=\(reason)")
    return true
  }

  private func finishRecoverableInterruption(reason: String) {
    transport.cancelActiveTransfer(reason: reason)
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
    guard let recoveryStore else { return false }
    do {
      try recoveryStore.persistInterruptedRecoverable(
        sessionID: activitySessionID ?? UUID(),
        identity: identity,
        downloads: queuedDownloads,
        inFlightHandle: inFlightHandle,
        completedCount: completedCount,
        failedCount: failedCount,
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
    releaseBackgroundExecution(reason: reason)
    releaseDownloadLease()
    backgroundMaintainer?.stop(reason: reason)
    endActivity(reason: "user-cancelled-download")
    recoveryStore?.clear()
    queuedDownloads = []
    recoveredSnapshot = nil
    hasInterruptedRecoverably = false
    presentation = CameraSessionPresentation(
      phase: identity == nil ? .idle : .galleryReady,
      queuedHandles: [],
      inFlightHandle: nil,
      catalog: identity == nil ? .unavailable : presentation.catalog
    )
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
      presentation = CameraSessionPresentation(
        phase: .galleryReady,
        queuedHandles: [],
        inFlightHandle: nil,
        catalog: presentation.catalog
      )
      recoveryStore?.clear()
      endActivity(reason: "download-completed")
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
      presentation = CameraSessionPresentation(
        phase: .galleryReady,
        queuedHandles: [],
        inFlightHandle: nil,
        catalog: presentation.catalog
      )
      recoveryStore?.clear()
      endActivity(reason: "download-save-failed")
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
    guard let catalogRuntime else { return }
    let handles = savedDownloadHandles().union(additionalHandles)
    Task {
      await catalogRuntime.updateDownloadedHandles(handles)
    }
  }

  private func terminateCatalogSession(reason: String) {
    let previousRuntime = catalogRuntime
    let previousLifecycleTask = catalogLifecycleTask
    catalogSessionID = nil
    catalogRuntime = nil
    catalogLifecycleTask = Task { @MainActor [weak self] in
      await previousLifecycleTask?.value
      await previousRuntime?.cancelAllChildren()
      guard let self else { return }
      self.transport.terminateCameraCommunication(reason: reason)
      self.activeTransportBinding = nil
    }
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

  /// Fetch the ALL baseline catalog (empty SearchMode conditions).
  /// Used by auto-download to compute HEIF handles via set subtraction.
  func fetchBaselineCatalog() async throws -> CameraVendorCatalogSnapshot {
    let query = CameraVendorCatalogQuery(conditions: [], label: "auto-download-baseline")
    return try await transport.fetchCameraCatalog(query: query)
  }

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
        await self.catalogRuntime?.start(initial: .all)
      } catch {
        self.onConnectionLogAppended?("[OBS] COUNT_SWEEP_ERROR \(error.localizedDescription)")
        // Attempt to restore gallery state even after failure
        await self.catalogRuntime?.start(initial: .all)
      }
    }
  }
}
