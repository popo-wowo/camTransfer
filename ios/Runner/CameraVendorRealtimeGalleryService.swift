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
  fileprivate let rawValue = UUID()
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

protocol CameraVendorReservedReceiveDiagnosticService: AnyObject {
  func probeReservedReceive() async throws -> CameraVendorReservedReceiveDiagnosticResult
}

protocol CameraVendorGalleryDiagnosticReporting: AnyObject {
  var diagnosticHandler: ((String) -> Void)? { get set }
}

protocol CameraVendorGalleryConfigurable: AnyObject {
  func configure(connectionSummary: CameraVendorConnectionSummary)
}

protocol CameraVendorGalleryReadySummaryProviding {
  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary
}

extension CameraVendorGalleryReadySummaryProviding {
  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return galleryReadyConnectionSummary(from: summary)
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }
}

final class CameraVendorPtpSessionRuntime {
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
  private var exclusiveDownloadLeaseAcquisition: ExclusiveDownloadLeaseAcquisition?
  private var exclusiveDownloadWindowOwnerIDs = Set<CameraVendorExclusiveDownloadWindowOwnerID>()
  private var isExclusiveDownloadWindowActive = false
  private var activeThumbnailRequestCount = 0
  private var activeBackgroundMetadataRequestCount = 0
  private var visibleThumbnailBatchHandles = Set<Int>()
  private var lastThumbnailActivityAt: Date = .distantPast
  private var hasReportedExclusiveDownloadWindowReady = false

  init(
    session: CameraVendorPtpSession,
    commandLane: CameraCommandLane = CameraCommandLane(),
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
    let shouldActivate: Bool
    exclusiveDownloadLeaseLock.lock()
    exclusiveDownloadWindowOwnerIDs.insert(ownerID)
    shouldActivate = exclusiveDownloadWindowOwnerIDs.count == 1
    if shouldActivate {
      activateExclusiveDownloadWindow()
      let acquisition = ExclusiveDownloadLeaseAcquisition(commandLane: commandLane)
      exclusiveDownloadLeaseAcquisition = acquisition
    }
    exclusiveDownloadLeaseLock.unlock()
  }

  func awaitExclusiveDownloadWindowReady(
    ownerID: CameraVendorExclusiveDownloadWindowOwnerID
  ) async throws {
    let acquisition = exclusiveDownloadLeaseLock.withLock {
      exclusiveDownloadWindowOwnerIDs.contains(ownerID)
        ? exclusiveDownloadLeaseAcquisition
        : nil
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
        self.exclusiveDownloadWindowOwnerIDs.contains(ownerID)
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
    guard exclusiveDownloadWindowOwnerIDs.remove(ownerID) != nil else {
      exclusiveDownloadLeaseLock.unlock()
      return
    }
    shouldDeactivate = exclusiveDownloadWindowOwnerIDs.isEmpty
      && exclusiveDownloadLeaseAcquisition != nil
    if shouldDeactivate {
      acquisition = exclusiveDownloadLeaseAcquisition
      exclusiveDownloadLeaseAcquisition = nil
      deactivateExclusiveDownloadWindow()
    } else {
      acquisition = nil
    }
    exclusiveDownloadLeaseLock.unlock()
    guard shouldDeactivate else { return }
    acquisition?.cancel(afterSerialized: finalizer)
  }

  func forceEndExclusiveDownloadWindow(afterSerialized finalizer: (() -> Void)? = nil) {
    let acquisition: ExclusiveDownloadLeaseAcquisition?
    let shouldDeactivate: Bool
    exclusiveDownloadLeaseLock.lock()
    shouldDeactivate = !exclusiveDownloadWindowOwnerIDs.isEmpty
      || exclusiveDownloadLeaseAcquisition != nil
    exclusiveDownloadWindowOwnerIDs.removeAll(keepingCapacity: false)
    acquisition = exclusiveDownloadLeaseAcquisition
    exclusiveDownloadLeaseAcquisition = nil
    if shouldDeactivate {
      deactivateExclusiveDownloadWindow()
    }
    exclusiveDownloadLeaseLock.unlock()
    guard shouldDeactivate else { return }
    acquisition?.cancel(afterSerialized: finalizer)
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
        CameraVendorGalleryThumbnail(data: result.data, item: item),
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

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await commandLane.runExclusiveSessionMutation {
      do {
        return try self.session.cameraVendorInitialCatalogSnapshot()
      } catch {
        guard CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: error) else {
          throw error
        }
        try self.session.recoverInitialCameraCatalogAfterStoreNotAvailable()
        return try self.session.cameraVendorInitialCatalogSnapshot()
      }
    }
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await commandLane.runExclusiveSessionMutation {
      try self.session.cameraVendorCatalogSnapshot(query: query)
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

final class CameraVendorRealtimeGalleryService: CameraGallerySession, CameraVendorGalleryBackgroundKeepAlive, CameraVendorGalleryObjectInfoSource, CameraVendorExclusiveDownloadWindowControlling, CameraVendorActiveDownloadInterrupting, CameraVendorActiveDownloadCancellationRequesting, CameraVendorVisibleThumbnailLaneCoordinating {
  private let session = CameraVendorPtpSession()
  private lazy var ptpRuntime = CameraVendorPtpSessionRuntime(
    session: session,
    diagnosticHandler: { [weak self] message in
      self?.report(message)
    },
    communicationGeneration: { [weak self] in
      self?.currentCommunicationGeneration() ?? 0
    }
  )
  private var objectInfoCache = CameraVendorObjectInfoCache()
  var diagnosticHandler: ((String) -> Void)?
  private var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] = []
  private var verifiedConnectionSteps: [IOSCameraConnectionStep] = []
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
  private var hasStartedPriorityDownloadBatch = false

  func configure(connectionSummary: CameraVendorConnectionSummary) {
    terminateCameraCommunication(reason: "configure-gallery-connection")
    session.configureTransferProfile(cameraSerialNumber: connectionSummary.serialNumber)
    wifiConfigurations = connectionSummary.wifiConfigurations
    verifiedConnectionSteps = connectionSummary.verifiedConnectionSteps
    ptpClientName = connectionSummary.connectedDeviceName
    prefersManualWifiRecovery = false
    manualWifiPromptBaselineIP = nil
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return summary
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }

  func terminateCameraCommunication(reason: String) {
    report("[OBS] GALLERY_COMMUNICATION_TERMINATE_REQUESTED reason=\(reason)")
    forceEndExclusiveDownloadWindows()
    objectInfoCache.resetForPhysicalSession()
    fetchLock.lock()
    communicationTerminationGeneration += 1
    isFetching = false
    fetchLock.unlock()
    session.disconnect()
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
    let ownerID = CameraVendorExclusiveDownloadWindowOwnerID()
    let shouldReportBegin: Bool
    let generation: UInt64
    exclusiveDownloadWindowLock.lock()
    exclusiveDownloadWindowOwnerIDs.insert(ownerID)
    shouldReportBegin = exclusiveDownloadWindowOwnerIDs.count == 1
    if shouldReportBegin {
      exclusiveDownloadWindowGeneration += 1
      hasStartedPriorityDownloadBatch = false
    }
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
      hasStartedPriorityDownloadBatch = false
    }
    exclusiveDownloadWindowLock.unlock()
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

  func hasExplicitGalleryModeEvidence() -> Bool {
    session.hasExplicitGalleryModeEvidence
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

  func prepareGalleryRouteAttempt(
    _ route: CameraVendorGalleryRoute,
    didCompleteWifiHandoff: Bool,
    recorder: (String) -> Void
  ) {
    recorder("[ROUTE \(route.id.rawValue)] 开始读取相机图库")
    recorder(
      "[ROUTE \(route.id.rawValue)] handoff=\(didCompleteWifiHandoff), " +
      "launchPayload=\(route.launchRequestPayload.map { String(format: "%02x", $0) }.joined())"
    )
    recorder(
      "[OBS] PTP_ROUTE_START id=\(route.id.rawValue) handoff=\(didCompleteWifiHandoff) " +
      "launchPayload=\(route.launchRequestPayload.map { String(format: "%02x", $0) }.joined())"
    )
    let startupDelay = route.ptpStartupDelaySeconds
    if startupDelay > 0 {
      recorder("[ROUTE \(route.id.rawValue)] 等待 \(Int(startupDelay)) 秒让相机 PTP 服务就绪...")
      Thread.sleep(forTimeInterval: startupDelay)
    } else {
      recorder("[ROUTE \(route.id.rawValue)] 跳过额外 PTP 启动等待")
    }
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
    route: CameraVendorGalleryRoute?
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
              route?.allowsUnverifiedWifiHandoffAfterRecoverableError ?? false,
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
    recorder: @escaping (String) -> Void
  ) throws -> IOSCameraPtpSessionEvidence {
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let connectStartedAt = Date()
    try connectWithRetry(recorder: recorder, communicationGeneration: communicationGeneration)
    recorder(
      "[OBS] GALLERY_TIMING_CONNECT seconds=" +
      String(format: "%.3f", Date().timeIntervalSince(connectStartedAt))
    )
    return IOSCameraPtpSessionEvidence(sessionID: "\(ptpClientName)-ptp")
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchCameraCatalog(query: query)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchInitialCameraCatalog()
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await ptpRuntime.executeCountSweepExperiment()
  }

  func prepareCameraVendorLegacyGalleryLoadIfNeeded() throws {
    try session.prepareCameraVendorLegacyGalleryLoadIfNeeded()
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

  func probeReservedReceive() async throws -> CameraVendorReservedReceiveDiagnosticResult {
    report("[OBS] RESERVED_RECEIVE_DIAGNOSTIC_START")
    let shouldDisconnectSession = fetchLock.withLock { () -> Bool in
      let wasFetching = isFetching
      isFetching = true
      return wasFetching
    }
    if shouldDisconnectSession {
      session.disconnect()
    }

    defer {
      fetchLock.withLock {
        isFetching = false
      }
    }

    let clientName = ptpClientName
    let result = try await Task.detached(priority: .userInitiated) {
      let diagnosticSession = CameraVendorPtpSession()
      defer {
        diagnosticSession.disconnect()
      }
      try diagnosticSession.connect(
        clientName: clientName,
        diagnosticHandler: { [weak self] message in
          self?.report(message)
        },
        purpose: .reservedReceiveDiagnostic
      )
      return try diagnosticSession.reservedReceiveDiagnosticObject()
    }.value
    report("[OBS] RESERVED_RECEIVE_DIAGNOSTIC_RESULT \(result.summary)")
    return result
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

  private func connectWithRetry(
    maxAttempts: Int = CameraVendorPtpConnectionStartupPolicy.maxAttempts,
    recorder: ((String) -> Void)? = nil,
    communicationGeneration: UInt64
  ) throws {
    var lastError: Error?
    let startedAt = Date()
    for attempt in 1...maxAttempts {
      try ensureCommunicationGenerationIsCurrent(communicationGeneration)
      do {
        try session.connect(clientName: ptpClientName, diagnosticHandler: recorder)
        try ensureCommunicationGenerationIsCurrent(communicationGeneration)
        return
      } catch {
        session.disconnect()
        try ensureCommunicationGenerationIsCurrent(communicationGeneration)
        if CameraVendorPtpReconnectErrorPolicy.shouldRetry(error) == false {
          throw error
        }

        lastError = error
        let elapsed = Date().timeIntervalSince(startedAt)
        if attempt < maxAttempts {
          let delay = CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
          recorder?(
            "PTP 连接失败 (第 \(attempt) 次，已等待 \(String(format: "%.1f", elapsed))s/" +
            "最多 \(maxAttempts) 次)，\(String(format: "%.1f", delay))s 后重试: \(error.localizedDescription)"
          )
          Thread.sleep(forTimeInterval: delay)
        }
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorRealtimeGalleryService",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "PTP 连接多次失败"]
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
    CameraVendorGalleryDiagnostics.log(message)
    diagnosticHandler?(message)
  }
}
