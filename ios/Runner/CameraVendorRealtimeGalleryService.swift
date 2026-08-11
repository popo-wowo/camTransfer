import Darwin
import Foundation
import NetworkExtension

protocol CameraVendorGalleryConnectionTerminating: AnyObject {
  func terminateCameraCommunication(reason: String)
}

protocol CameraVendorGalleryBackgroundKeepAlive: AnyObject {
  func performBackgroundKeepAlive() async throws
}

protocol CameraVendorBleBackgroundKeepAlive: AnyObject {
  func performBackgroundBleKeepAlive(reason: String)
}

struct CameraVendorExclusiveDownloadWindowOwnerID: Hashable, Sendable {
  fileprivate let rawValue: UUID
  fileprivate let generationID: UUID

  fileprivate init(generationID: UUID = UUID()) {
    rawValue = UUID()
    self.generationID = generationID
  }
}

protocol CameraVendorExclusiveDownloadWindowControlling: AnyObject {
  @discardableResult
  func beginExclusiveDownloadWindow() -> CameraVendorExclusiveDownloadWindowOwnerID
  func awaitExclusiveDownloadWindowReady(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID
  ) async throws
  func endExclusiveDownloadWindow(ownerID: CameraVendorExclusiveDownloadWindowOwnerID)
  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async throws -> T
}

private final class CameraVendorExclusiveDownloadWindowRelease: @unchecked Sendable {
  private enum State {
    case waiting
    case admitted
    case released
  }

  private let lock = NSLock()
  private var state = State.waiting
  private var releaseHandler: (() -> Void)?

  init(releaseHandler: @escaping () -> Void) {
    self.releaseHandler = releaseHandler
  }

  func markAdmitted() -> Bool {
    lock.withLock {
      guard case .waiting = state else { return false }
      state = .admitted
      return true
    }
  }

  func cancelWhileWaiting() {
    let handler: (() -> Void)? = lock.withLock {
      guard case .waiting = state else { return nil }
      state = .released
      let handler = releaseHandler
      releaseHandler = nil
      return handler
    }
    handler?()
  }

  func release() {
    let handler: (() -> Void)? = lock.withLock {
      guard case .released = state else {
        state = .released
        let handler = releaseHandler
        releaseHandler = nil
        return handler
      }
      return nil
    }
    handler?()
  }
}

protocol CameraVendorActiveDownloadInterrupting: AnyObject {
  func interruptActiveDownload(reason: String)
}

/// Cancels the current file at the next verified PTP chunk boundary.  Unlike
/// `CameraVendorActiveDownloadInterrupting`, this does not close either PTP
/// socket, so a user can stop a file without turning a healthy camera session
/// into a reconnect.
protocol CameraVendorActiveDownloadCancellationRequesting: AnyObject {
  func requestActiveDownloadCancellation(reason: String)
}

protocol CameraVendorVisibleThumbnailLaneCoordinating: AnyObject {
  func beginVisibleThumbnailBatch(handles: [Int])
  func finishVisibleThumbnailBatch(handles: [Int])
}

enum CameraVendorGalleryFetchConcurrencyPolicy {
  static let shouldRejectConcurrentFetch = true
  static let concurrentFetchErrorCode = 7
}

struct CameraVendorReservedReceiveDiagnosticResult: Equatable {
  let objectInfo: CameraVendorCameraObjectInfo
  let sampleByteCount: Int

  var summary: String {
    let sizeText = ByteCountFormatter.string(
      fromByteCount: Int64(objectInfo.compressedSize),
      countStyle: .file
    )
    let sampleText = NumberFormatter.localizedString(
      from: NSNumber(value: sampleByteCount),
      number: .decimal
    )
    return "\(objectInfo.filename) \(objectInfo.formatLabel) \(sizeText) sample=\(sampleText) bytes"
  }
}

protocol CameraVendorGalleryDiagnosticReporting: AnyObject {
  var diagnosticHandler: ((String) -> Void)? { get set }
}

protocol CameraVendorGalleryConfigurable: AnyObject {
  func configure(connectionSummary: CameraVendorConnectionSummary)
}

protocol CameraVendorGallerySessionPreparedSummaryProviding {
  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary

  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary
}

extension CameraVendorGallerySessionPreparedSummaryProviding {
  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return gallerySessionPreparedConnectionSummary(from: summary)
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }
}

enum FujifilmInitialCatalogStrategyExecutor {
  static func execute(
    definition: InitialCatalogStrategyDefinition,
    fetch: () throws -> CameraVendorCatalogSnapshot,
    recover: () throws -> Void
  ) throws -> CameraVendorCatalogSnapshot {
    switch definition.action {
    case .directSpecifiedCatalog:
      return try fetch()
    case .storeNotAvailableRecovery:
      try recover()
      return try fetch()
    }
  }
}

enum FujifilmInitialCatalogResponseClassifier {
  static func facts(after error: Error) -> CameraCatalogResponseFacts? {
    let evidence: CameraGalleryCatalogResponseEvidence?
    if let failure = error as? CameraGalleryCatalogTransactionFailure {
      guard failure.restorationMessage == nil else { return nil }
      evidence = failure.responseEvidence
    } else {
      evidence = CameraGalleryCatalogResponseEvidence(error: error)
    }
    guard let evidence,
          evidence.domain == "CameraVendorPtpSession",
          evidence.responseCode == 0x2013 else {
      return nil
    }
    return CameraCatalogResponseFacts.classify(
      operationCode: evidence.operationCode,
      responseCode: evidence.responseCode
    )
  }
}

enum FujifilmResponseDrivenInitialCatalogExecutor {
  static func execute(
    directFetch: () throws -> CameraVendorCatalogSnapshot,
    revise: (CameraCatalogResponseFacts) throws -> Void,
    recover: () throws -> Void,
    recoveryFetch: () throws -> CameraVendorCatalogSnapshot
  ) throws -> CameraVendorCatalogSnapshot {
    do {
      return try directFetch()
    } catch {
      guard let facts = FujifilmInitialCatalogResponseClassifier.facts(after: error) else {
        throw error
      }
      try revise(facts)
      try recover()
      return try recoveryFetch()
    }
  }
}

final class CameraVendorPtpSessionRuntime {
  private final class ExclusiveDownloadWindowGeneration {
    var ownerIDs: Set<CameraVendorExclusiveDownloadWindowOwnerID>
    let acquisition: ExclusiveDownloadLeaseAcquisition

    init(
      ownerID: CameraVendorExclusiveDownloadWindowOwnerID,
      acquisition: ExclusiveDownloadLeaseAcquisition
    ) {
      ownerIDs = [ownerID]
      self.acquisition = acquisition
    }
  }

  private final class ExclusiveDownloadLeaseAcquisition {
    private final class State {
      private let lock = NSLock()
      private var isCancelled = false
      private var lease: CameraCommandLease?

      func cancel(afterSerialized finalizer: (() -> Void)? = nil) {
        let leaseToRelease: CameraCommandLease?
        lock.lock()
        isCancelled = true
        leaseToRelease = lease
        lease = nil
        lock.unlock()
        leaseToRelease?.release(afterSerialized: finalizer)
      }

      func install(_ lease: CameraCommandLease) throws {
        let wasCancelled: Bool
        lock.lock()
        wasCancelled = isCancelled
        if !wasCancelled {
          self.lease = lease
        }
        lock.unlock()
        if wasCancelled {
          lease.release()
          throw CancellationError()
        }
      }

      func checkReady() throws {
        let isReady = lock.withLock {
          !isCancelled && lease != nil
        }
        guard isReady else { throw CancellationError() }
      }
    }

    private let state: State
    private let task: Task<Void, Error>

    init(commandLane: CameraCommandLane) {
      let state = State()
      self.state = state
      task = Task {
        let lease = try await commandLane.acquireExclusiveDownloadLease()
        try state.install(lease)
      }
    }

    func waitUntilReady() async throws {
      try await task.value
      try state.checkReady()
      try Task.checkCancellation()
    }

    func cancel(afterSerialized finalizer: (() -> Void)? = nil) {
      task.cancel()
      state.cancel(afterSerialized: finalizer)
    }
  }

  private let session: CameraVendorPtpSession
  private let commandLane: CameraCommandLane
  private let stateLock = NSLock()
  private let exclusiveDownloadLeaseLock = NSLock()
  private let diagnosticHandler: (String) -> Void
  private let communicationGeneration: () -> UInt64
  private var exclusiveDownloadWindowGenerations: [
    UUID: ExclusiveDownloadWindowGeneration
  ] = [:]
  private var isExclusiveDownloadWindowActive = false
  private var activeThumbnailRequestCount = 0
  private var activeBackgroundMetadataRequestCount = 0
  private var visibleThumbnailBatchHandles = Set<Int>()
  private var lastThumbnailActivityAt: Date = .distantPast
  private var hasReportedExclusiveDownloadWindowReady = false

  init(
    session: CameraVendorPtpSession,
    commandLane: CameraCommandLane,
    diagnosticHandler: @escaping (String) -> Void,
    communicationGeneration: @escaping () -> UInt64
  ) {
    self.session = session
    self.commandLane = commandLane
    self.diagnosticHandler = diagnosticHandler
    self.communicationGeneration = communicationGeneration
  }

  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async throws -> T {
    let ownerID = beginExclusiveDownloadWindow()
    let release = CameraVendorExclusiveDownloadWindowRelease { [weak self] in
      self?.endExclusiveDownloadWindow(ownerID: ownerID)
    }
    return try await withTaskCancellationHandler {
      defer { release.release() }
      try await awaitExclusiveDownloadWindowReady(ownerID: ownerID)
      try Task.checkCancellation()
      guard release.markAdmitted() else { throw CancellationError() }
      return try await operation()
    } onCancel: {
      release.cancelWhileWaiting()
    }
  }

  @discardableResult
  func beginExclusiveDownloadWindow() -> CameraVendorExclusiveDownloadWindowOwnerID {
    let ownerID = CameraVendorExclusiveDownloadWindowOwnerID()
    beginExclusiveDownloadWindow(ownerID: ownerID)
    return ownerID
  }

  func beginExclusiveDownloadWindow(ownerID: CameraVendorExclusiveDownloadWindowOwnerID) {
    exclusiveDownloadLeaseLock.lock()
    if let generation = exclusiveDownloadWindowGenerations[ownerID.generationID] {
      generation.ownerIDs.insert(ownerID)
    } else {
      let shouldActivate = exclusiveDownloadWindowGenerations.isEmpty
      let acquisition = ExclusiveDownloadLeaseAcquisition(commandLane: commandLane)
      exclusiveDownloadWindowGenerations[ownerID.generationID] =
        ExclusiveDownloadWindowGeneration(
          ownerID: ownerID,
          acquisition: acquisition
        )
      if shouldActivate {
        activateExclusiveDownloadWindow()
      }
    }
    exclusiveDownloadLeaseLock.unlock()
  }

  func awaitExclusiveDownloadWindowReady(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID
  ) async throws {
    let acquisition: ExclusiveDownloadLeaseAcquisition? = exclusiveDownloadLeaseLock.withLock {
      guard let generation = exclusiveDownloadWindowGenerations[ownerID.generationID],
        generation.ownerIDs.contains(ownerID) else {
        return nil
      }
      return generation.acquisition
    }
    guard let acquisition else { throw CancellationError() }
    try await acquisition.waitUntilReady()
    try Task.checkCancellation()
  }

  func runPriorityBatchTransition<T>(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID,
    _ operation: () throws -> T
  ) async throws -> T {
    try await commandLane.run(priority: .download) {
      guard self.exclusiveDownloadLeaseLock.withLock({
        self.exclusiveDownloadWindowGenerations[ownerID.generationID]?
          .ownerIDs.contains(ownerID) == true
      }) else {
        throw CancellationError()
      }
      return try operation()
    }
  }

  func endExclusiveDownloadWindow(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID,
    afterSerialized finalizer: (() -> Void)? = nil
  ) {
    let acquisition: ExclusiveDownloadLeaseAcquisition?
    let shouldDeactivate: Bool
    exclusiveDownloadLeaseLock.lock()
    guard let generation = exclusiveDownloadWindowGenerations[ownerID.generationID],
      generation.ownerIDs.remove(ownerID) != nil else {
      exclusiveDownloadLeaseLock.unlock()
      return
    }
    if generation.ownerIDs.isEmpty {
      exclusiveDownloadWindowGenerations.removeValue(forKey: ownerID.generationID)
      acquisition = generation.acquisition
    } else {
      acquisition = nil
    }
    shouldDeactivate = acquisition != nil && exclusiveDownloadWindowGenerations.isEmpty
    if shouldDeactivate {
      deactivateExclusiveDownloadWindow()
    }
    exclusiveDownloadLeaseLock.unlock()
    acquisition?.cancel(afterSerialized: finalizer)
  }

  func forceEndExclusiveDownloadWindow(afterSerialized finalizer: (() -> Void)? = nil) {
    let acquisitions: [ExclusiveDownloadLeaseAcquisition]
    exclusiveDownloadLeaseLock.lock()
    acquisitions = exclusiveDownloadWindowGenerations.values.map(\.acquisition)
    exclusiveDownloadWindowGenerations.removeAll(keepingCapacity: false)
    if !acquisitions.isEmpty {
      deactivateExclusiveDownloadWindow()
    }
    exclusiveDownloadLeaseLock.unlock()
    for (index, acquisition) in acquisitions.enumerated() {
      acquisition.cancel(afterSerialized: index == 0 ? finalizer : nil)
    }
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    stateLock.lock()
    visibleThumbnailBatchHandles.formUnion(handles)
    lastThumbnailActivityAt = Date()
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_VISIBLE_BATCH_BEGIN count=\(handles.count) pending=\(pendingCount)")
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    stateLock.lock()
    visibleThumbnailBatchHandles.subtract(handles)
    lastThumbnailActivityAt = Date()
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_VISIBLE_BATCH_END count=\(handles.count) pending=\(pendingCount)")
  }

  func fetchThumbnailWithInfo(
    for handle: Int,
    expectedSize: UInt32?
  ) async throws -> (thumbnail: CameraVendorGalleryThumbnail, objectInfo: CameraVendorCameraObjectInfo?) {
    try await commandLane.run(priority: .visibleThumbnail) {
      try self.beginThumbnailRequest(handle: handle)
      defer { self.endThumbnailRequest(handle: handle) }
      let result = try self.session.thumbWithInfo(
        handle: UInt32(handle),
        expectedSize: expectedSize
      )
      let item = result.objectInfo.map { info in
        CameraVendorGalleryItem(
          handle: info.handle,
          filename: info.filename,
          formatLabel: info.galleryFormatLabel,
          captureDate: info.captureDate,
          byteSizeText: info.compressedSize > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
            : "",
          compressedSize: info.compressedSize.nonzero,
          orientation: info.orientation
        )
      }
      return (
        CameraVendorGalleryThumbnail(data: result.data, item: item, objectInfo: result.objectInfo),
        result.objectInfo
      )
    }
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await commandLane.run(priority: .hdPreview) {
      try self.session.previewImage(handle: UInt32(handle))
    }
  }

  func fetchPreviewImageWithInfo(
    for handle: Int
  ) async throws -> CameraVendorPreviewImageFetchResult {
    try await commandLane.run(priority: .hdPreview) {
      try self.session.previewImageWithInfo(handle: UInt32(handle))
    }
  }

  func performBackgroundKeepAlive() async throws {
    try await commandLane.run(priority: .keepAlive) {
      let handle = Int(CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle)
      try self.beginBackgroundMetadataRequest(handle: handle)
      defer { self.endBackgroundMetadataRequest(handle: handle) }
      _ = try self.session.cameraVendorLatestObjectInfo(
        preferredHandle: CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle,
        readTimeout: CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoTimeoutSeconds
      )
    }
    diagnosticHandler(
      "[OBS] GALLERY_BACKGROUND_READ_IMAGE_INFO_KEEP_ALIVE_OK " +
      "op=0x9054 handle=0x\(String(format: "%08X", CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle))"
    )
  }

  func downloadOriginal(for handle: Int, expectedSize: UInt32?) async throws -> Data {
    try await commandLane.run(priority: .download) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      return try self.session.object(handle: UInt32(handle), expectedSize: expectedSize)
    }
  }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode,
    cachedInfo: CameraVendorCameraObjectInfo?
  ) async throws -> (Data, CameraVendorCameraObjectInfo?) {
    try await commandLane.run(priority: .download) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      let info = try (cachedInfo ?? self.session.objectInfo(handle: UInt32(handle)).reliableDownloadMetadata)
      let formatLabel = info?.galleryFormatLabel ?? ""
      let expectedSize = info?.compressedSize.nonzero
      let objectData = try self.session.objectData(
        handle: UInt32(handle),
        expectedSize: expectedSize,
        formatLabel: formatLabel,
        downloadMode: mode
      )
      return (objectData.data, objectData.info ?? info)
    }
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode,
    cachedInfo: CameraVendorCameraObjectInfo?
  ) async throws -> (URL, CameraVendorCameraObjectInfo?, CameraVendorOriginalFileTransferTiming) {
    try await commandLane.run(priority: .download) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      let fileResult = try self.session.objectFile(
        handle: UInt32(handle),
        cachedInfo: cachedInfo,
        downloadMode: mode
      )
      let info = fileResult.info.reliableDownloadMetadata ?? cachedInfo
      return (fileResult.fileURL, info, fileResult.timing)
    }
  }

  func fetchInitialCameraCatalog(
    definition: InitialCatalogStrategyDefinition,
    query: CameraVendorCatalogQuery? = nil,
    revise: (CameraCatalogResponseFacts) throws -> Void
  ) async throws -> CameraVendorCatalogSnapshot {
    try await commandLane.runExclusiveSessionMutation {
      let fetch = {
        if let query {
          return try self.session.cameraVendorCatalogSnapshot(query: query)
        }
        return try self.session.cameraVendorInitialCatalogSnapshot()
      }
      switch definition.action {
      case .directSpecifiedCatalog:
        return try FujifilmResponseDrivenInitialCatalogExecutor.execute(
          directFetch: fetch,
          revise: revise,
          recover: {
            try self.session.recoverInitialCameraCatalogAfterStoreNotAvailable()
          },
          recoveryFetch: fetch
        )
      case .storeNotAvailableRecovery:
        return try FujifilmInitialCatalogStrategyExecutor.execute(
          definition: definition,
          fetch: fetch,
          recover: {
            try self.session.recoverInitialCameraCatalogAfterStoreNotAvailable()
          }
        )
      }
    }
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await commandLane.runExclusiveSessionMutation {
      try self.session.cameraVendorCatalogSnapshot(query: query)
    }
  }

  func fetchExpandedCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await commandLane.runExclusiveSessionMutation {
      try self.session.cameraVendorInitialCatalogSnapshot()
    }
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await commandLane.runExclusiveSessionMutation {
      try self.session.cameraVendorCountSweepExperiment()
    }
  }

  func objectInfo(
    handle: UInt32,
    readTimeout: TimeInterval
  ) async throws -> CameraVendorCameraObjectInfo {
    try await commandLane.run(priority: .details) {
      try self.beginBackgroundMetadataRequest(handle: Int(handle))
      defer { self.endBackgroundMetadataRequest(handle: Int(handle)) }
      return try self.session.objectInfo(handle: handle, readTimeout: readTimeout)
    }
  }

  private func beginThumbnailRequest(handle: Int) throws {
    stateLock.lock()
    if isExclusiveDownloadWindowActive {
      stateLock.unlock()
      diagnosticHandler("[OBS] THUMBNAIL_REQUEST_REJECTED_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: CameraVendorPriorityDownloadThumbnailGatePolicy.suspendedThumbnailErrorCode,
        userInfo: [NSLocalizedDescriptionKey: "下载期间暂停缩略图加载"]
      )
    }
    activeThumbnailRequestCount += 1
    lastThumbnailActivityAt = Date()
    let activeCount = activeThumbnailRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_REQUEST_BEGIN handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }

  private func endThumbnailRequest(handle: Int) {
    stateLock.lock()
    activeThumbnailRequestCount = max(0, activeThumbnailRequestCount - 1)
    visibleThumbnailBatchHandles.remove(handle)
    lastThumbnailActivityAt = Date()
    let activeCount = activeThumbnailRequestCount
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler(
      "[OBS] THUMBNAIL_REQUEST_END handle=0x\(String(format: "%08X", handle)) " +
      "active=\(activeCount) pending=\(pendingCount)"
    )
  }

  private func currentThumbnailLaneState() -> (activeCount: Int, pendingCount: Int, lastActivityAt: Date) {
    stateLock.lock()
    let state = (activeThumbnailRequestCount, visibleThumbnailBatchHandles.count, lastThumbnailActivityAt)
    stateLock.unlock()
    return state
  }

  func galleryRequestCounts() -> (
    activeThumbnailCount: Int,
    activeBackgroundMetadataCount: Int,
    pendingThumbnailCount: Int
  ) {
    stateLock.lock()
    let counts = (
      activeThumbnailRequestCount,
      activeBackgroundMetadataRequestCount,
      visibleThumbnailBatchHandles.count
    )
    stateLock.unlock()
    return counts
  }

  private func activateExclusiveDownloadWindow() {
    stateLock.lock()
    isExclusiveDownloadWindowActive = true
    hasReportedExclusiveDownloadWindowReady = false
    stateLock.unlock()
  }

  private func deactivateExclusiveDownloadWindow() {
    stateLock.lock()
    isExclusiveDownloadWindowActive = false
    stateLock.unlock()
  }

  private func reportExclusiveDownloadWindowReadyIfNeeded() {
    stateLock.lock()
    let shouldReport = isExclusiveDownloadWindowActive && !hasReportedExclusiveDownloadWindowReady
    if shouldReport {
      hasReportedExclusiveDownloadWindowReady = true
    }
    stateLock.unlock()
    if shouldReport {
      diagnosticHandler("[OBS] PTP_EXCLUSIVE_DOWNLOAD_WINDOW_READY")
    }
  }

  private func beginBackgroundMetadataRequest(handle: Int) throws {
    stateLock.lock()
    if isExclusiveDownloadWindowActive {
      stateLock.unlock()
      diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REJECTED_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: NSURLErrorCancelled,
        userInfo: [NSLocalizedDescriptionKey: "下载期间暂停后台元数据加载"]
      )
    }
    activeBackgroundMetadataRequestCount += 1
    let activeCount = activeBackgroundMetadataRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REQUEST_BEGIN handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }

  private func endBackgroundMetadataRequest(handle: Int) {
    stateLock.lock()
    activeBackgroundMetadataRequestCount = max(0, activeBackgroundMetadataRequestCount - 1)
    let activeCount = activeBackgroundMetadataRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REQUEST_END handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }
}

final class CameraVendorPhysicalSessionTerminationWaitGate {
  typealias TimeoutCancellation = () -> Void
  typealias TimeoutScheduler = (
    TimeInterval,
    @escaping () -> Void
  ) -> TimeoutCancellation

  private final class PendingWait {
    let id = UUID()
    let continuation: CheckedContinuation<CameraCompatibilityLabResetResult, Never>
    var cancelTimeout: TimeoutCancellation?

    init(
      continuation: CheckedContinuation<CameraCompatibilityLabResetResult, Never>
    ) {
      self.continuation = continuation
    }
  }

  private let lock = NSLock()
  private let timeoutScheduler: TimeoutScheduler
  private var isTerminationInFlight = false
  private var pendingWaits: [UUID: PendingWait] = [:]

  init(
    timeoutScheduler: @escaping TimeoutScheduler = { timeoutSeconds, handler in
      let workItem = DispatchWorkItem(block: handler)
      DispatchQueue.main.asyncAfter(
        deadline: .now() + timeoutSeconds,
        execute: workItem
      )
      return { workItem.cancel() }
    }
  ) {
    self.timeoutScheduler = timeoutScheduler
  }

  func beginTermination() {
    lock.lock()
    isTerminationInFlight = true
    lock.unlock()
  }

  func completeTermination() {
    let waits: [PendingWait]
    lock.lock()
    isTerminationInFlight = false
    waits = Array(pendingWaits.values)
    pendingWaits.removeAll(keepingCapacity: false)
    lock.unlock()
    waits.forEach { wait in
      wait.cancelTimeout?()
      wait.continuation.resume(returning: .succeeded)
    }
  }

  func wait(
    timeoutSeconds: TimeInterval
  ) async -> CameraCompatibilityLabResetResult {
    await withCheckedContinuation { continuation in
      let pending = PendingWait(continuation: continuation)
      let shouldWait: Bool
      lock.lock()
      if isTerminationInFlight {
        pendingWaits[pending.id] = pending
        shouldWait = true
      } else {
        shouldWait = false
      }
      lock.unlock()
      guard shouldWait else {
        continuation.resume(returning: .succeeded)
        return
      }

      let cancelTimeout = timeoutScheduler(timeoutSeconds) { [weak self] in
        self?.timeout(waitID: pending.id)
      }
      var shouldCancelTimeout = false
      lock.lock()
      if pendingWaits[pending.id] === pending {
        pending.cancelTimeout = cancelTimeout
      } else {
        shouldCancelTimeout = true
      }
      lock.unlock()
      if shouldCancelTimeout {
        cancelTimeout()
      }
    }
  }

  private func timeout(waitID: UUID) {
    let wait: PendingWait?
    lock.lock()
    wait = pendingWaits.removeValue(forKey: waitID)
    lock.unlock()
    wait?.continuation.resume(returning: .failed)
  }
}

final class CameraVendorRealtimeGalleryService: CameraGalleryTransportSession, CameraVendorGalleryBackgroundKeepAlive, CameraVendorGalleryObjectInfoSource, CameraVendorExclusiveDownloadWindowControlling, CameraVendorActiveDownloadInterrupting, CameraVendorActiveDownloadCancellationRequesting, CameraVendorVisibleThumbnailLaneCoordinating {
  private let session = CameraVendorPtpSession()
  private var commandLane = CameraCommandLane()
  private var ptpRuntime: CameraVendorPtpSessionRuntime! = nil
  private var objectInfoCache = CameraVendorObjectInfoCache()
  var diagnosticHandler: ((String) -> Void)?
  private var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] = []
  private var verifiedConnectionSteps: [IOSCameraConnectionStep] = []
  private var activeConnectionPlan: CameraConnectionPlan?
  private var activeStrategySnapshot: FujifilmProtocolStrategySnapshot?
  private var activePhysicalSession: FujifilmCameraSession?
  private let physicalSessionTerminationCondition = NSCondition()
  private let physicalSessionTerminationWaitGate =
    CameraVendorPhysicalSessionTerminationWaitGate()
  private var didCommitPhysicalSessionTermination = false
  private var isPhysicalSessionTerminationInFlight = false
  private var ptpClientName = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
  private var prefersManualWifiRecovery = false
  private var manualWifiPromptBaselineIP: String?
  /// Re-entrancy guard: prevents parallel PTP connections that conflict with each other.
  private let fetchLock = NSLock()
  private var isFetching = false
  private var communicationTerminationGeneration: UInt64 = 0
  private let exclusiveDownloadWindowLock = NSLock()
  private var exclusiveDownloadWindowOwnerIDs = Set<CameraVendorExclusiveDownloadWindowOwnerID>()
  private var exclusiveDownloadWindowGeneration: UInt64 = 0
  private var exclusiveDownloadWindowGenerationID: UUID?
  private var hasStartedPriorityDownloadBatch = false
#if DEBUG
  var exclusiveDownloadWindowEndStateDidCommitForTesting: (() -> Void)?
  var physicalSessionTerminationDidCommitForTesting: (() -> Void)?
  var physicalSessionTransportDidCloseForTesting: (() -> Void)?
  var connectionPlanBindDidStartForTesting: (() -> Void)?
#endif

  init() {
    installCommandRuntime(commandLane: commandLane)
  }

  var currentCommandLane: CameraCommandLane {
    commandLane
  }

  func beginConnectionPlanAttempt() throws {
    waitForPhysicalSessionTerminationToFinish()
    guard activePhysicalSession == nil else {
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 31,
        userInfo: [
          NSLocalizedDescriptionKey: "An active physical camera session must terminate before a new connection plan attempt"
        ]
      )
    }
    if let activeConnectionPlan {
      report(
        "[OBS] CAMERA_PLAN_ATTEMPT_RESET previousPlanID=\(activeConnectionPlan.id.rawValue) " +
        "previousRevision=\(activeConnectionPlan.revision)"
      )
    }
    activeConnectionPlan = nil
    activeStrategySnapshot = nil
  }

  func configure(connectionSummary: CameraVendorConnectionSummary) {
    terminateCameraCommunication(reason: "configure-gallery-connection")
    waitForPhysicalSessionTerminationToFinish()
    resetPhysicalSessionTerminationLatch()
    commandLane = CameraCommandLane()
    installCommandRuntime(commandLane: commandLane)
    session.configureTransferProfile(cameraSerialNumber: connectionSummary.serialNumber)
    wifiConfigurations = connectionSummary.wifiConfigurations
    verifiedConnectionSteps = connectionSummary.verifiedConnectionSteps
    ptpClientName = connectionSummary.connectedDeviceName
    prefersManualWifiRecovery = false
    manualWifiPromptBaselineIP = nil
  }

  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func gallerySessionPreparedConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return summary
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }

  func terminateCameraCommunication(reason: String) {
    if let activePhysicalSession {
      _ = activePhysicalSession.terminate(reason: reason)
      return
    }
    performPhysicalSessionTermination(reason: reason)
  }

  func terminateCameraCommunicationAndWait(
    reason: String,
    timeoutSeconds: TimeInterval = 3
  ) async -> CameraCompatibilityLabResetResult {
    terminateCameraCommunication(reason: reason)
    return await waitForPhysicalSessionTerminationToFinishAsync(
      timeoutSeconds: timeoutSeconds
    )
  }

  func installPhysicalSession(_ physicalSession: FujifilmCameraSession) {
    precondition(
      physicalSession.commandLane === commandLane,
      "The physical Fujifilm session must own the service command lane"
    )
    if let activePhysicalSession, activePhysicalSession !== physicalSession {
      _ = activePhysicalSession.terminate(reason: "physical-session-superseded")
    }
    resetPhysicalSessionTerminationLatch()
    activePhysicalSession = physicalSession
  }

  func performPhysicalSessionTermination(reason: String) {
    guard claimPhysicalSessionTermination() else { return }
#if DEBUG
    physicalSessionTerminationDidCommitForTesting?()
#endif
    report("[OBS] GALLERY_COMMUNICATION_TERMINATE_REQUESTED reason=\(reason)")
    forceEndExclusiveDownloadWindows()
    objectInfoCache.resetForPhysicalSession()
    fetchLock.lock()
    communicationTerminationGeneration += 1
    isFetching = false
    fetchLock.unlock()
    commandLane.terminateAfterDrainingActiveOperation { [weak self] in
      self?.completePhysicalSessionTransportClose()
    }
  }

  private func claimPhysicalSessionTermination() -> Bool {
    physicalSessionTerminationCondition.lock()
    guard !didCommitPhysicalSessionTermination else {
      physicalSessionTerminationCondition.unlock()
      return false
    }
    didCommitPhysicalSessionTermination = true
    isPhysicalSessionTerminationInFlight = true
    physicalSessionTerminationWaitGate.beginTermination()
    physicalSessionTerminationCondition.unlock()
    return true
  }

  private func completePhysicalSessionTransportClose() {
    session.disconnect()
#if DEBUG
    physicalSessionTransportDidCloseForTesting?()
#endif
    activeConnectionPlan = nil
    activeStrategySnapshot = nil
    activePhysicalSession = nil
    physicalSessionTerminationCondition.lock()
    isPhysicalSessionTerminationInFlight = false
    physicalSessionTerminationCondition.broadcast()
    physicalSessionTerminationCondition.unlock()
    physicalSessionTerminationWaitGate.completeTermination()
  }

  private func waitForPhysicalSessionTerminationToFinish() {
    physicalSessionTerminationCondition.lock()
    while isPhysicalSessionTerminationInFlight {
      physicalSessionTerminationCondition.wait()
    }
    physicalSessionTerminationCondition.unlock()
  }

  private func waitForPhysicalSessionTerminationToFinishAsync(
    timeoutSeconds: TimeInterval
  ) async -> CameraCompatibilityLabResetResult {
    await physicalSessionTerminationWaitGate.wait(
      timeoutSeconds: timeoutSeconds
    )
  }

  private func resetPhysicalSessionTerminationLatch() {
    physicalSessionTerminationCondition.lock()
    didCommitPhysicalSessionTermination = false
    physicalSessionTerminationCondition.unlock()
  }

  private func installCommandRuntime(commandLane: CameraCommandLane) {
    ptpRuntime = CameraVendorPtpSessionRuntime(
      session: session,
      commandLane: commandLane,
      diagnosticHandler: { [weak self] message in
        self?.report(message)
      },
      communicationGeneration: { [weak self] in
        self?.currentCommunicationGeneration() ?? 0
      }
    )
  }

  func bindConnectionPlan(
    _ plan: CameraConnectionPlan,
    strategySnapshot: FujifilmProtocolStrategySnapshot
  ) throws {
#if DEBUG
    connectionPlanBindDidStartForTesting?()
#endif
    guard plan.supportStatus != .unsupported else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported camera plan cannot bind to a Fujifilm session"]
      )
    }
    if let activeConnectionPlan {
      if activeConnectionPlan == plan {
        guard activeStrategySnapshot == strategySnapshot else {
          throw NSError(
            domain: "FujifilmProtocolEngine",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Bound plan cannot change its Strategy definitions"]
          )
        }
        return
      }
      guard activeConnectionPlan.id == plan.id,
            plan.revision == activeConnectionPlan.revision + 1 else {
        throw NSError(
          domain: "FujifilmProtocolEngine",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Only an adjacent revision of the bound session plan is allowed"]
        )
      }
    }
    activeConnectionPlan = plan
    activeStrategySnapshot = strategySnapshot
    reportStrategySnapshotBindings(plan: plan, snapshot: strategySnapshot)
  }

  private func reportStrategySnapshotBindings(
    plan: CameraConnectionPlan,
    snapshot: FujifilmProtocolStrategySnapshot
  ) {
    var bindings: [(stage: String, strategyID: String, fingerprint: String)] = [
      (
        stage: "activation",
        strategyID: plan.activationStrategy.rawValue,
        fingerprint: FujifilmStrategyDefinitionFingerprint.hex(snapshot.activation)
      )
    ]
    if let definition = snapshot.ptpInit {
      bindings.append((
        stage: "ptpInit",
        strategyID: plan.ptpInitStrategy.rawValue,
        fingerprint: FujifilmStrategyDefinitionFingerprint.hex(definition)
      ))
    }
    if let definition = snapshot.negotiation {
      bindings.append((
        stage: "negotiation",
        strategyID: plan.negotiationStrategy.rawValue,
        fingerprint: FujifilmStrategyDefinitionFingerprint.hex(definition)
      ))
    }
    if let definition = snapshot.galleryBootstrap {
      bindings.append((
        stage: "galleryBootstrap",
        strategyID: plan.galleryBootstrapStrategy.rawValue,
        fingerprint: FujifilmStrategyDefinitionFingerprint.hex(definition)
      ))
    }
    if let definition = snapshot.initialCatalog {
      bindings.append((
        stage: "initialCatalog",
        strategyID: plan.initialCatalogStrategy.rawValue,
        fingerprint: FujifilmStrategyDefinitionFingerprint.hex(definition)
      ))
    }

    for binding in bindings {
      report(
        "[OBS] CAMERA_STRATEGY_BIND planID=\(plan.id.rawValue) " +
          "revision=\(plan.revision) stage=\(binding.stage) " +
          "strategyID=\(binding.strategyID) fingerprint=\(binding.fingerprint)"
      )
    }
  }

  private func currentCommunicationGeneration() -> UInt64 {
    fetchLock.lock()
    let generation = communicationTerminationGeneration
    fetchLock.unlock()
    return generation
  }

  private func ensureCommunicationGenerationIsCurrent(_ generation: UInt64) throws {
    guard currentCommunicationGeneration() == generation else {
      throw NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled,
        userInfo: [NSLocalizedDescriptionKey: "图库加载已取消"]
      )
    }
  }

  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async throws -> T {
    let ownerID = beginExclusiveDownloadWindow()
    let release = CameraVendorExclusiveDownloadWindowRelease { [weak self] in
      self?.endExclusiveDownloadWindow(ownerID: ownerID)
    }
    return try await withTaskCancellationHandler {
      defer { release.release() }
      try await awaitExclusiveDownloadWindowReady(ownerID: ownerID)
      try Task.checkCancellation()
      guard release.markAdmitted() else { throw CancellationError() }
      return try await operation()
    } onCancel: {
      release.cancelWhileWaiting()
    }
  }

  @discardableResult
  func beginExclusiveDownloadWindow() -> CameraVendorExclusiveDownloadWindowOwnerID {
    let ownerID: CameraVendorExclusiveDownloadWindowOwnerID
    let shouldReportBegin: Bool
    let generation: UInt64
    exclusiveDownloadWindowLock.lock()
    shouldReportBegin = exclusiveDownloadWindowOwnerIDs.isEmpty
    if shouldReportBegin {
      exclusiveDownloadWindowGeneration += 1
      exclusiveDownloadWindowGenerationID = UUID()
      hasStartedPriorityDownloadBatch = false
    }
    ownerID = CameraVendorExclusiveDownloadWindowOwnerID(
      generationID: exclusiveDownloadWindowGenerationID!
    )
    exclusiveDownloadWindowOwnerIDs.insert(ownerID)
    generation = exclusiveDownloadWindowGeneration
    exclusiveDownloadWindowLock.unlock()
    ptpRuntime.beginExclusiveDownloadWindow(ownerID: ownerID)
    let isCurrent = exclusiveDownloadWindowLock.withLock {
      exclusiveDownloadWindowGeneration == generation
        && exclusiveDownloadWindowOwnerIDs.contains(ownerID)
    }
    if !isCurrent {
      ptpRuntime.endExclusiveDownloadWindow(ownerID: ownerID)
    } else if shouldReportBegin {
      report("[OBS] PTP_EXCLUSIVE_DOWNLOAD_WINDOW_BEGIN")
    }
    return ownerID
  }

  func awaitExclusiveDownloadWindowReady(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID
  ) async throws {
    try await ptpRuntime.awaitExclusiveDownloadWindowReady(ownerID: ownerID)
    try Task.checkCancellation()
    let transition: UInt64? = try exclusiveDownloadWindowLock.withLock {
      guard exclusiveDownloadWindowOwnerIDs.contains(ownerID) else {
        throw CancellationError()
      }
      guard !hasStartedPriorityDownloadBatch else { return nil }
      hasStartedPriorityDownloadBatch = true
      return exclusiveDownloadWindowGeneration
    }
    guard let generation = transition else { return }
    try await ptpRuntime.runPriorityBatchTransition(ownerID: ownerID) {
      let shouldBegin = self.exclusiveDownloadWindowLock.withLock {
        self.exclusiveDownloadWindowGeneration == generation
          && self.exclusiveDownloadWindowOwnerIDs.contains(ownerID)
          && self.hasStartedPriorityDownloadBatch
      }
      guard shouldBegin else { throw CancellationError() }
      self.report("[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_BEGIN_COMMAND_LANE")
      self.session.beginPriorityDownloadBatch(
        generation: self.currentCommunicationGeneration()
      )
    }
    let isStillCurrent = exclusiveDownloadWindowLock.withLock {
      exclusiveDownloadWindowGeneration == generation
        && exclusiveDownloadWindowOwnerIDs.contains(ownerID)
        && hasStartedPriorityDownloadBatch
    }
    guard isStillCurrent else { throw CancellationError() }
    let counts = ptpRuntime.galleryRequestCounts()
    report(
      "[OBS] PTP_EXCLUSIVE_DOWNLOAD_ADMISSION_READY " +
        "active=\(counts.activeThumbnailCount + counts.activeBackgroundMetadataCount) " +
        "pendingNonDownload=0 schedulerIdle=true"
    )
    guard exclusiveDownloadWindowLock.withLock({
      exclusiveDownloadWindowGeneration == generation
        && exclusiveDownloadWindowOwnerIDs.contains(ownerID)
    }) else {
      throw CancellationError()
    }
  }

  func endExclusiveDownloadWindow(ownerID: CameraVendorExclusiveDownloadWindowOwnerID) {
    let shouldFinishBatch: Bool
    exclusiveDownloadWindowLock.lock()
    guard exclusiveDownloadWindowOwnerIDs.remove(ownerID) != nil else {
      exclusiveDownloadWindowLock.unlock()
      return
    }
    let isLastOwner = exclusiveDownloadWindowOwnerIDs.isEmpty
    shouldFinishBatch = isLastOwner && hasStartedPriorityDownloadBatch
    if isLastOwner {
      exclusiveDownloadWindowGenerationID = nil
      hasStartedPriorityDownloadBatch = false
    }
    exclusiveDownloadWindowLock.unlock()
#if DEBUG
    if isLastOwner {
      exclusiveDownloadWindowEndStateDidCommitForTesting?()
    }
#endif
    let finalizer: (() -> Void)? = shouldFinishBatch ? { [weak self] in
      guard let self else { return }
      self.session.finishPriorityDownloadBatchOnCommandLane()
      self.report("[OBS] PRIORITY_DOWNLOAD_FINISH")
    } : nil
    ptpRuntime.endExclusiveDownloadWindow(
      ownerID: ownerID,
      afterSerialized: finalizer
    )
    if isLastOwner && !shouldFinishBatch {
      report("[OBS] PRIORITY_DOWNLOAD_FINISH")
    }
  }

  private func forceEndExclusiveDownloadWindows() {
    let hadOwners: Bool
    let shouldFinishBatch: Bool
    exclusiveDownloadWindowLock.lock()
    hadOwners = !exclusiveDownloadWindowOwnerIDs.isEmpty
    shouldFinishBatch = hasStartedPriorityDownloadBatch
    exclusiveDownloadWindowOwnerIDs.removeAll(keepingCapacity: false)
    exclusiveDownloadWindowGeneration += 1
    exclusiveDownloadWindowGenerationID = nil
    hasStartedPriorityDownloadBatch = false
    exclusiveDownloadWindowLock.unlock()
    guard hadOwners else { return }
    let finalizer: (() -> Void)? = shouldFinishBatch ? { [weak self] in
      guard let self else { return }
      self.session.finishPriorityDownloadBatchOnCommandLane()
      self.report("[OBS] PRIORITY_DOWNLOAD_FINISH")
    } : nil
    ptpRuntime.forceEndExclusiveDownloadWindow(afterSerialized: finalizer)
    if !shouldFinishBatch {
      report("[OBS] PRIORITY_DOWNLOAD_FINISH")
    }
  }

  func interruptActiveDownload(reason: String) {
    report("[OBS] PTP_ACTIVE_DOWNLOAD_INTERRUPT reason=\(reason)")
    session.invalidateInFlightOperationForPriorityDownload(reason: reason)
  }

  func requestActiveDownloadCancellation(reason: String) {
    report("[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCEL_REQUESTED reason=\(reason)")
    session.requestActiveDownloadCancellation(reason: reason)
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    ptpRuntime.beginVisibleThumbnailBatch(handles: handles)
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    ptpRuntime.finishVisibleThumbnailBatch(handles: handles)
  }

  func beginMainlineGalleryFetch() throws -> UInt64 {
    CameraVendorFileLogger.log(
      "beginMainlineGalleryFetch: wifiConfigs=\(wifiConfigurations.count) prefersManual=\(prefersManualWifiRecovery)"
    )
    report(
      "[OBS] GALLERY_FETCH_START wifiConfigs=\(wifiConfigurations.map(\.ssid).joined(separator: ",")) " +
      "clientName=\(ptpClientName)"
    )
    fetchLock.lock()
    if isFetching {
      fetchLock.unlock()
      report("[OBS] GALLERY_FETCH_REJECTED_CONCURRENT")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: CameraVendorGalleryFetchConcurrencyPolicy.concurrentFetchErrorCode,
        userInfo: [NSLocalizedDescriptionKey: "已有图库加载任务在进行，请等待当前连接完成"]
      )
    }
    isFetching = true
    let fetchGeneration = communicationTerminationGeneration
    fetchLock.unlock()
    return fetchGeneration
  }

  func finishMainlineGalleryFetch(generation: UInt64) {
    fetchLock.lock()
    if communicationTerminationGeneration == generation {
      isFetching = false
    }
    fetchLock.unlock()
  }

  func appendGalleryRuntimeMessage(_ message: String) {
    report(message)
  }

  func hasVerifiedConnectionStep(_ step: IOSCameraConnectionStep) -> Bool {
    CameraVendorIOSOfficialConnectionEvidencePolicy.hasVerifiedStep(
      step,
      in: verifiedConnectionSteps
    )
  }

  func currentOfficialWifiCredential() -> IOSCameraWifiCredential? {
    guard let preferredWifi = wifiConfigurations.first else {
      return nil
    }
    return IOSCameraWifiCredential.official(
      ssid: preferredWifi.ssid,
      passphrase: preferredWifi.passphrase,
      bssid: preferredWifi.bssid,
      source: .bleHandshake
    )
  }

  func completeSuccessfulGalleryRouteSearch() {
    prefersManualWifiRecovery = false
  }

  func buildGalleryRouteFailure(
    didCompleteWifiHandoff: Bool,
    diagnostics: [String],
    error: Error
  ) -> NSError {
    session.disconnect()
    let message = CameraVendorGalleryDiagnostics.composeFailureMessage(
      baseMessage: CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
        errorDescription: error.localizedDescription,
        didCompleteWifiHandoff: didCompleteWifiHandoff
      ),
      diagnostics: diagnostics
    )
    return NSError(
      domain: "CameraVendorRealtimeGalleryService",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  func joinCameraWifi(
    context: IOSCameraConnectionContext,
    communicationGeneration: UInt64,
    allowUnverifiedAssociationAfterRecoverableError: Bool
  ) async throws -> CameraVendorGalleryWifiHandoffResult {
    var lastWifiJoinError: Error?
    var didJoinWifiAutomatically = false
    var skippedAutoJoinBecauseManual = false

    let currentSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
    let currentWifiIP = getWifiIPv4Address()
    let ssidMatchesCamera = wifiConfigurations.contains { $0.ssid == currentSSID }
    let currentPtpReachable = CameraVendorPtpConstants.isCameraWifiIPv4Address(currentWifiIP)
    let hasConfirmedCameraNetwork = CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
      currentSSID: currentSSID,
      wifiConfigurations: wifiConfigurations,
      isCameraPtpReachable: currentPtpReachable
    )
    report("Wi-Fi 预检查: ssid=\(currentSSID ?? "<nil>"), ip=\(currentWifiIP ?? "<nil>"), matchesCamera=\(ssidMatchesCamera)")
    report(
      "[OBS] WIFI_PRECHECK currentSSID=\(currentSSID ?? "nil") " +
      "ip=\(currentWifiIP ?? "nil") matchesCamera=\(ssidMatchesCamera) " +
      "ptpReachable=\(currentPtpReachable) confirmedCameraNetwork=\(hasConfirmedCameraNetwork)"
    )

    if hasConfirmedCameraNetwork {
      report("检测到 iPhone 已连接相机网络，跳过自动切换 Wi‑Fi，继续等待相机 IP 确认")
      prefersManualWifiRecovery = false
    } else if CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
      hasWifiConfigurations: !wifiConfigurations.isEmpty,
      prefersManualWifiRecovery: prefersManualWifiRecovery
    ) {
      for (configurationIndex, configuration) in wifiConfigurations.enumerated() {
        do {
          try await CameraVendorCameraWifiConnector.join(
            configuration: configuration,
            allowUnverifiedAssociationAfterRecoverableError:
              allowUnverifiedAssociationAfterRecoverableError,
            diagnosticHandler: diagnosticHandler
          )
          didJoinWifiAutomatically = true
          prefersManualWifiRecovery = false
          break
        } catch {
          lastWifiJoinError = error
          report("Wi-Fi 连接失败 \(configuration.ssid): \(error.localizedDescription)")
          if CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
            attemptedConfigurationIndex: configurationIndex
          ) {
            report("首选相机 Wi‑Fi 自动连接失败，立即转入手动连接以避免相机传图状态超时")
            break
          }
        }
      }

      if !didJoinWifiAutomatically, let preferredConfiguration = wifiConfigurations.first {
        prefersManualWifiRecovery = true
        manualWifiPromptBaselineIP = currentWifiIP
        if let nsError = lastWifiJoinError as NSError?,
           nsError.domain == NEHotspotConfigurationErrorDomain,
           nsError.code == NEHotspotConfigurationError.internal.rawValue {
          report("当前构建可能无法自动切换到相机 Wi-Fi，请先手动加入。")
        }
        for instruction in CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(for: preferredConfiguration) {
          report(instruction)
        }
      }
    } else if prefersManualWifiRecovery {
      skippedAutoJoinBecauseManual = true
      report("检测到你可能已手动加入相机 Wi-Fi，本次跳过自动切换，直接尝试连接相机。")
    } else if !wifiConfigurations.isEmpty {
      prefersManualWifiRecovery = true
      manualWifiPromptBaselineIP = currentWifiIP
      report("自动 Wi-Fi 连接已停用，避免干扰已手动连接的相机 Wi-Fi。")
      if let preferredConfiguration = wifiConfigurations.first {
        for instruction in CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(for: preferredConfiguration) {
          report(instruction)
        }
      }
    } else {
      report("没有可用的相机 Wi-Fi 名称候选，停止进入 PTP")
    }

    let postJoinSnapshot = await waitForManualCameraWifiIfNeeded(
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      wifiConfigurations: wifiConfigurations,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      report: report
    )
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let postJoinManualRecoveryEvidence = CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: postJoinSnapshot.ssid,
      currentIP: postJoinSnapshot.ip,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    )
    let readySnapshot = await waitForCameraIPv4AfterAssociationEvidenceIfNeeded(
      hasAssociationEvidence: didJoinWifiAutomatically
        || hasConfirmedCameraNetwork
        || postJoinManualRecoveryEvidence,
      initialSSID: postJoinSnapshot.ssid,
      initialIP: postJoinSnapshot.ip,
      report: report
    )
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let postJoinSSID = readySnapshot.ssid
    let postJoinWifiIP = readySnapshot.ip
    let postJoinSSIDMatchesCamera = postJoinSSID.map { ssid in
      wifiConfigurations.contains { $0.ssid == ssid }
    } ?? false
    let manualPtpReachable = CameraVendorPtpConstants.isCameraWifiIPv4Address(postJoinWifiIP)
    let postJoinConfirmedCameraNetwork = CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
      currentSSID: postJoinSSID,
      wifiConfigurations: wifiConfigurations,
      isCameraPtpReachable: manualPtpReachable
    )
    let manualRecoveryNetworkEvidence = CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: postJoinSSID,
      currentIP: postJoinWifiIP,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    )

    if CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
      didJoinWifiAutomatically: didJoinWifiAutomatically,
      prefersManualWifiRecovery: prefersManualWifiRecovery,
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      currentSSIDMatchesCamera: postJoinSSIDMatchesCamera,
      isCameraPtpReachable: manualPtpReachable,
      hasCurrentWifiConfigurations: !wifiConfigurations.isEmpty
    ) {
      CameraVendorFileLogger.log("shouldPause=true, 抛出手动WiFi提示")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "请先手动加入相机 Wi-Fi，然后回到 CamTransfer 点“重新加载”。"
        ]
      )
    }

    let didCompleteWifiHandoff = CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
      hasConfirmedCameraNetwork: hasConfirmedCameraNetwork,
      postJoinConfirmedCameraNetwork: postJoinConfirmedCameraNetwork,
      didJoinWifiAutomatically: didJoinWifiAutomatically,
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      manualRecoveryNetworkEvidence: manualRecoveryNetworkEvidence,
      postJoinCameraPtpReachable: manualPtpReachable
    )
    report(
      "[OBS] WIFI_HANDOFF_RESULT didJoinAutomatically=\(didJoinWifiAutomatically) " +
      "skippedManual=\(skippedAutoJoinBecauseManual) didComplete=\(didCompleteWifiHandoff) " +
      "currentSSID=\(postJoinSSID ?? "nil") ip=\(postJoinWifiIP ?? "nil") " +
      "ptpReachable=\(manualPtpReachable) manualEvidence=\(manualRecoveryNetworkEvidence)"
    )
    guard CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
      didCompleteWifiHandoff: didCompleteWifiHandoff
    ) else {
      let message = CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
        errorDescription: "Wi-Fi handoff 未完成，未启动 PTP 相册路线",
        didCompleteWifiHandoff: false
      )
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
    let joinedSSID = postJoinSSID ?? wifiConfigurations.first?.ssid ?? context.wifiCredential?.ssid
    guard let joinedSSID,
          !joinedSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IOSCameraConnectionIssue(
        step: .joinCameraWifi,
        reason: "未获得可确认的相机 Wi-Fi SSID，已停止进入 PTP"
      )
    }
    return CameraVendorGalleryWifiHandoffResult(
      joinedSSID: joinedSSID,
      didCompleteWifiHandoff: didCompleteWifiHandoff
    )
  }

  func connectGalleryPtp(
    communicationGeneration: UInt64,
    recorder: @escaping (String) -> Void,
    plan: CameraConnectionPlan,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws -> IOSCameraPtpSessionEvidence {
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    guard activeConnectionPlan == plan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "PTP connect plan does not match the bound session plan"]
      )
    }
    let strategySnapshot = try requireActiveStrategySnapshot(for: plan)
    guard let ptpInitDefinition = strategySnapshot.ptpInit else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 12,
        userInfo: [NSLocalizedDescriptionKey: "PTP INIT Strategy is not available in the active plan"]
      )
    }
    let connectStartedAt = Date()
    try session.connectTransportAndOpenSession(
      clientName: ptpClientName,
      diagnosticHandler: recorder,
      ptpInitDefinition: ptpInitDefinition,
      progressHandler: progressHandler
    )
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    recorder(
      "[OBS] GALLERY_TIMING_CONNECT seconds=" +
      String(format: "%.3f", Date().timeIntervalSince(connectStartedAt))
    )
    return IOSCameraPtpSessionEvidence(sessionID: "\(ptpClientName)-ptp")
  }

  func negotiateGalleryFunction(
    plan: CameraConnectionPlan,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws {
    guard activeConnectionPlan == plan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Function negotiation plan does not match the active session plan"]
      )
    }
    guard let definition = try requireActiveStrategySnapshot(for: plan).negotiation else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Function negotiation Strategy is not available"]
      )
    }
    try session.negotiateGalleryFunction(
      definition: definition,
      connectionPlanID: plan.id,
      progressHandler: progressHandler
    )
  }

  func inspectGalleryFunction(
    plan: CameraConnectionPlan
  ) throws -> CameraGalleryFunctionFacts {
    guard activeConnectionPlan == plan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Function inspection plan does not match the active session plan"]
      )
    }
    guard let definition = try requireActiveStrategySnapshot(for: plan).negotiation else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 13,
        userInfo: [NSLocalizedDescriptionKey: "Function inspection Strategy is not available"]
      )
    }
    switch definition.inspectionAction {
    case .noFacts:
      report("[OBS] PTP_FUNCTION_INSPECTION strategy=\(definition.id.rawValue) facts=none")
      return .currentBaseline
    }
  }

  func prepareGallerySession(
    plan: CameraConnectionPlan,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws {
    guard activeConnectionPlan == plan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Gallery bootstrap plan does not match the active session plan"]
      )
    }
    guard let definition = try requireActiveStrategySnapshot(for: plan).galleryBootstrap else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Gallery bootstrap Strategy is not available"]
      )
    }
    try session.prepareGallerySession(
      definition: definition,
      connectionPlanID: plan.id,
      progressHandler: progressHandler
    )
  }

  func resetFailedGalleryPtpAttempt() {
    session.disconnect()
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchCameraCatalog(query: query)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await fetchInitialCameraCatalog(query: nil)
  }

  func fetchExpandedCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchExpandedCameraCatalog()
  }

  func fetchInitialCameraCatalog(
    query: CameraVendorCatalogQuery?
  ) async throws -> CameraVendorCatalogSnapshot {
    guard let currentPlan = activeConnectionPlan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Initial Catalog requires a bound connection plan"]
      )
    }
    guard let strategySnapshot = activeStrategySnapshot else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Initial Catalog requires bound Strategy definitions"]
      )
    }
    guard let initialCatalogDefinition = strategySnapshot.initialCatalog else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Initial Catalog Strategy is not available"]
      )
    }
    guard initialCatalogDefinition.id == currentPlan.initialCatalogStrategy else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Initial Catalog Strategy does not match the bound plan"]
      )
    }
    guard let physicalSession = activePhysicalSession else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Initial Catalog requires an active physical session"]
      )
    }
    let queryLabel = query?.label ?? "expanded-all"
    report(
      "[OBS] INITIAL_CATALOG_STRATEGY_BEGIN planID=\(currentPlan.id.rawValue) " +
        "revision=\(currentPlan.revision) strategyID=\(initialCatalogDefinition.id.rawValue) " +
        "queryLabel=\(queryLabel)"
    )
    let snapshot = try await ptpRuntime.fetchInitialCameraCatalog(
      definition: initialCatalogDefinition,
      query: query,
      revise: { responseFacts in
        let revisedFacts = physicalSession.facts.updating(
          catalogResponseFacts: responseFacts
        )
        guard let revision = try physicalSession.applyInitialCatalogResponseRevision(
          facts: revisedFacts
        ) else {
          throw NSError(
            domain: "FujifilmProtocolEngine",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Catalog response did not produce a plan revision"]
          )
        }
        activeConnectionPlan = revision.plan
        activeStrategySnapshot = revision.strategySnapshot
        report(
          "[OBS] CAMERA_PLAN_REVISION planID=\(revision.plan.id.rawValue) " +
            "revision=\(revision.plan.revision) reason=\(revision.summary.reason.rawValue) " +
            "changedStages=\(revision.summary.changedStages.map(\.rawValue).joined(separator: ",")) " +
            "preservedLockedStages=" +
            revision.summary.preservedLockedStages.map(\.rawValue).joined(separator: ",")
        )
      }
    )
    report(
      "[OBS] INITIAL_CATALOG_STRATEGY_END planID=\(activeConnectionPlan?.id.rawValue ?? currentPlan.id.rawValue) " +
        "revision=\(activeConnectionPlan?.revision ?? currentPlan.revision) " +
        "strategyID=\(activeConnectionPlan?.initialCatalogStrategy.rawValue ?? initialCatalogDefinition.id.rawValue) " +
        "queryLabel=\(queryLabel) handles=\(snapshot.orderedHandles.count)"
    )
    return snapshot
  }

  private func requireActiveStrategySnapshot(
    for plan: CameraConnectionPlan
  ) throws -> FujifilmProtocolStrategySnapshot {
    guard activeConnectionPlan == plan, let activeStrategySnapshot else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Protocol Strategy definitions are not bound to this plan"]
      )
    }
    return activeStrategySnapshot
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await ptpRuntime.executeCountSweepExperiment()
  }

  private func waitForManualCameraWifiIfNeeded(
    skippedAutoJoinBecauseManual: Bool,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration],
    manualPromptBaselineIP: String?,
    report: @escaping (String) -> Void
  ) async -> (ssid: String?, ip: String?) {
    let initialSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
    let initialIP = getWifiIPv4Address()
    guard skippedAutoJoinBecauseManual else {
      return (initialSSID, initialIP)
    }

    if CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: initialSSID,
      currentIP: initialIP,
      manualPromptBaselineIP: manualPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    ) {
      return (initialSSID, initialIP)
    }

    report(
      "[OBS] WIFI_MANUAL_WAIT_START ssid=\(initialSSID ?? "nil") " +
      "ip=\(initialIP ?? "nil") maxSeconds=\(Int(CameraVendorManualWifiReadinessPolicy.maxWaitSeconds))"
    )

    let deadline = Date().addingTimeInterval(CameraVendorManualWifiReadinessPolicy.maxWaitSeconds)
    var latestSSID = initialSSID
    var latestIP = initialIP
    while Date() < deadline {
      let sleepNanoseconds = UInt64(CameraVendorManualWifiReadinessPolicy.pollIntervalSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: sleepNanoseconds)
      latestSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
      latestIP = getWifiIPv4Address()
      report("[OBS] WIFI_MANUAL_WAIT_SAMPLE ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
      if CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: latestSSID,
        currentIP: latestIP,
        manualPromptBaselineIP: manualPromptBaselineIP,
        wifiConfigurations: wifiConfigurations
      ) {
        report("[OBS] WIFI_MANUAL_WAIT_READY ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
        return (latestSSID, latestIP)
      }
    }

    report("[OBS] WIFI_MANUAL_WAIT_TIMEOUT ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
    return (latestSSID, latestIP)
  }

  private func waitForCameraIPv4AfterAssociationEvidenceIfNeeded(
    hasAssociationEvidence: Bool,
    initialSSID: String?,
    initialIP: String?,
    report: @escaping (String) -> Void
  ) async -> (ssid: String?, ip: String?) {
    guard CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
      didJoinWifiAutomatically: hasAssociationEvidence,
      currentWifiIP: initialIP
    ) else {
      return (initialSSID, initialIP)
    }

    report(
      "[OBS] WIFI_IPV4_WAIT_START ssid=\(initialSSID ?? "nil") " +
      "ip=\(initialIP ?? "nil") maxSeconds=\(Int(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds))"
    )
    let deadline = Date().addingTimeInterval(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds)
    var latestSSID = initialSSID
    var latestIP = initialIP
    while Date() < deadline {
      let sleepNanoseconds = UInt64(CameraVendorWifiAssociationReadinessPolicy.pollIntervalSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: sleepNanoseconds)
      latestSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
      latestIP = getWifiIPv4Address()
      report("[OBS] WIFI_IPV4_WAIT_SAMPLE ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
      if !CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: latestIP
      ) {
        report("[OBS] WIFI_IPV4_WAIT_READY ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
        return (latestSSID, latestIP)
      }
    }

    report("[OBS] WIFI_IPV4_WAIT_TIMEOUT ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
    return (latestSSID, latestIP)
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    try await fetchThumbnailWithInfo(for: handle).data
  }

  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo {
    let info = try await ptpRuntime.objectInfo(
      handle: UInt32(handle),
      readTimeout: CameraVendorBackgroundMetadataRefreshPolicy.objectInfoReadTimeoutSeconds
    )
    cacheObjectInfos([info])
    return info
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    let result = try await ptpRuntime.fetchThumbnailWithInfo(for: handle, expectedSize: expectedSize)
    if let info = result.objectInfo {
      cacheObjectInfos([info])
    }
    return result.thumbnail
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await ptpRuntime.fetchPreviewImage(for: handle)
  }

  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    let result = try await ptpRuntime.fetchPreviewImageWithInfo(for: handle)
    let info = result.objectInfo
    cacheObjectInfos([info])
    return CameraVendorGalleryPreview(
      data: result.data,
      item: CameraVendorGalleryItem(
        handle: info.handle,
        filename: info.filename,
        formatLabel: info.galleryFormatLabel,
        captureDate: info.captureDate,
        byteSizeText: info.compressedSize > 0
          ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
          : "",
        compressedSize: info.compressedSize.nonzero,
        orientation: info.orientation
      )
    )
  }

  func performBackgroundKeepAlive() async throws {
    try await ptpRuntime.performBackgroundKeepAlive()
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    return try await ptpRuntime.downloadOriginal(for: handle, expectedSize: expectedSize)
  }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData {
    let cachedInfo = objectInfoCache[handle]?.reliableDownloadMetadata
    let result = try await ptpRuntime.downloadOriginalData(
      for: handle,
      mode: mode,
      cachedInfo: cachedInfo
    )
    if let info = result.1 {
      cacheObjectInfos([info])
    }
    return CameraVendorDownloadedPhotoData(
      data: result.0,
      filename: result.1?.filename ?? "CamTransfer-\(handle).jpg"
    )
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    try await downloadOriginalFile(for: handle, mode: .original)
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile {
    let cachedInfo = objectInfoCache[handle]?.reliableDownloadMetadata
    let result = try await ptpRuntime.downloadOriginalFile(
      for: handle,
      mode: mode,
      cachedInfo: cachedInfo
    )
    if let info = result.1 {
      cacheObjectInfos([info])
    }
    let filename = result.1?.filename ?? "CamTransfer-\(handle).bin"
    let item = CameraVendorGalleryItem(
      handle: handle,
      filename: filename,
      formatLabel: result.1?.galleryFormatLabel ?? "",
      captureDate: result.1?.captureDate ?? "",
      byteSizeText: ""
    )
    let mediaType = CameraVendorGalleryDownloadPolicy.mediaType(for: item)
    let fileURL = result.0
    return CameraVendorDownloadedFile(
      fileURL: fileURL,
      filename: filename,
      mediaType: mediaType,
      transferTiming: result.2
    )
  }

  private func cacheObjectInfos(_ infos: [CameraVendorCameraObjectInfo]) {
    for info in infos {
      objectInfoCache.store(info)
    }
  }

  private func galleryItem(
    from info: CameraVendorCameraObjectInfo,
    formatHints: Set<CameraVendorGalleryFormatHint> = []
  ) -> CameraVendorGalleryItem {
    CameraVendorGalleryItem(
      handle: info.handle,
      filename: info.filename,
      formatLabel: info.galleryFormatLabel,
      captureDate: info.captureDate,
      byteSizeText: info.compressedSize > 0
        ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
        : "",
      compressedSize: info.compressedSize.nonzero,
      orientation: info.orientation,
      formatHints: formatHints
    )
  }

  private func galleryItems(
    from infos: [CameraVendorCameraObjectInfo],
    formatHintsByHandle: [Int: Set<CameraVendorGalleryFormatHint>] = [:],
    preserveInputOrder: Bool = false
  ) -> [CameraVendorGalleryItem] {
    CameraVendorGalleryItemOrderingPolicy.galleryItems(
      from: infos,
      formatHintsByHandle: formatHintsByHandle,
      preserveInputOrder: preserveInputOrder
    )
  }

  private func waitForPtpReachability(
    timeout: TimeInterval = 10,
    interval: TimeInterval = 0.5,
    recorder: ((String) -> Void)? = nil
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if CameraVendorCameraPtpReachabilityProbe.isReachable() {
        recorder?("相机 PTP 端口已就绪")
        return true
      }
      recorder?("相机 PTP 端口未就绪，\(String(format: "%.1f", deadline.timeIntervalSince(Date())))s 后重试")
      Thread.sleep(forTimeInterval: interval)
    }
    return false
  }

  private func report(_ message: String) {
    guard CameraVendorPtpDiagnosticLogPolicy.shouldEmit(message) else { return }
    if let diagnosticHandler {
      diagnosticHandler(message)
    } else {
      CameraVendorGalleryDiagnostics.log(message)
    }
  }
}
