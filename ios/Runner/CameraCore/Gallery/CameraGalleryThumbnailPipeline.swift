import Foundation

actor CameraGalleryThumbnailPipeline {
  enum Publication {
    case thumbnail(CameraGalleryMediaIdentity, CameraGalleryThumbnailResult)
    case thumbnailState(CameraGalleryMediaIdentity, CameraGalleryThumbnailState)
    case details(CameraGalleryCatalogIdentity, CameraGalleryDetailsSourceResult)
  }

  typealias Publisher = @MainActor (Publication) async -> Void

  private let source: CameraGalleryThumbnailPipelineSource
  private let retryDelaysNanoseconds: [UInt64]
  private let publish: Publisher
  private let reportTransportFailure: TransportFailureReporter?
  private var catalogIdentity: CameraGalleryCatalogIdentity?
  private var membership: Set<Int> = []
  private var orderedMembership: [Int] = []
  private var thumbnailTask: Task<Void, Never>?
  private var detailsTask: Task<Void, Never>?
  private var latestVisibleHandles: [Int] = []
  private var latestViewportSubmissionID: UInt64 = 0
  private var latestViewportRevision: UInt64 = 0
  private var thumbnailDataCache: [CameraGalleryMediaCacheKey: Data] = [:]
  private var reusableObjectInfos: [CameraGalleryMediaCacheKey: CameraGalleryObjectInfoResult] = [:]
  private var thumbnailRetryCounts: [CameraGalleryMediaCacheKey: Int] = [:]
  private var failedThumbnailKeys: Set<CameraGalleryMediaCacheKey> = []
  private var completedDetailsHandles: Set<Int> = []
  private var detailsCursor = 0
  private var isCatalogSuspended = false
  private var isExternalWorkSuspended = false
  private var isInvalidated = false

  init(
    source: CameraGalleryThumbnailPipelineSource,
    retryDelaysNanoseconds: [UInt64] = [500_000_000, 2_000_000_000],
    publish: @escaping Publisher,
    reportTransportFailure: TransportFailureReporter? = nil
  ) {
    self.source = source
    self.retryDelaysNanoseconds = retryDelaysNanoseconds
    self.publish = publish
    self.reportTransportFailure = reportTransportFailure
  }

  func install(
    catalogIdentity: CameraGalleryCatalogIdentity,
    membership: [Int],
    reusableObjectInfos: [Int: CameraGalleryObjectInfoResult]
  ) async {
    let startedAt = Date()
    let previousSessionEpoch = self.catalogIdentity?.sessionEpoch
    isCatalogSuspended = true
    await cancelTasksAndJoin()
    self.catalogIdentity = catalogIdentity
    orderedMembership = membership
    self.membership = Set(membership)
    latestVisibleHandles = []
    completedDetailsHandles = []
    detailsCursor = 0
    isCatalogSuspended = false
    isInvalidated = false
    if let previousSessionEpoch,
       previousSessionEpoch != catalogIdentity.sessionEpoch {
      clearSessionState()
    }
    for (handle, info) in reusableObjectInfos where info.handle == handle {
      let identity = mediaIdentity(
        catalogIdentity: catalogIdentity,
        handle: handle
      )
      self.reusableObjectInfos[CameraGalleryMediaCacheKey(mediaIdentity: identity)] = info
    }
    CameraVendorFileLogger.log(
      "[OBS] THUMBNAIL_PIPELINE_INSTALL_END generation=\(catalogIdentity.generation.rawValue) " +
      "membership=\(membership.count) thumbnailCache=\(thumbnailDataCache.count) " +
      "objectInfoCache=\(self.reusableObjectInfos.count) externalSuspended=\(isExternalWorkSuspended) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
  }

  func requestVisible(handles: [Int]) async {
    let submissionID = latestViewportSubmissionID &+ 1
    await requestVisible(handles: handles, submissionID: submissionID)
  }

  func requestVisible(handles: [Int], submissionID: UInt64) async {
    let startedAt = Date()
    guard !isInvalidated,
          let catalogIdentity else { return }
    guard submissionID > latestViewportSubmissionID else { return }
    latestViewportSubmissionID = submissionID
    let requestedHandles = handles.filter { membership.contains($0) }
    if requestedHandles != latestVisibleHandles {
      latestVisibleHandles = requestedHandles
      latestViewportRevision &+= 1
    }
    guard !requestedHandles.isEmpty else { return }
    guard !isSuspended else { return }

    let rearmedFailureCount = rearmFailedThumbnails(
      handles: requestedHandles,
      catalogIdentity: catalogIdentity
    )

    var uncachedHandles: [Int] = []
    var cachedPublications: [Publication] = []
    var cacheHitCount = 0
    var failedCount = 0
    for handle in requestedHandles {
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      if let data = thumbnailDataCache[cacheKey] {
        cacheHitCount += 1
        cachedPublications.append(.thumbnail(
          identity,
          CameraGalleryThumbnailResult(data: data, resolvedMetadata: nil)
        ))
      } else if failedThumbnailKeys.contains(cacheKey) {
        failedCount += 1
        cachedPublications.append(.thumbnailState(identity, .failed))
      } else {
        uncachedHandles.append(handle)
      }
    }
    for publication in cachedPublications {
      guard isCurrentViewport(
        submissionID: submissionID,
        catalogIdentity: catalogIdentity
      ) else { return }
      await publish(publication)
      guard isCurrentViewport(
        submissionID: submissionID,
        catalogIdentity: catalogIdentity
      ) else { return }
    }
    CameraVendorFileLogger.log(
      "[OBS] THUMBNAIL_VIEWPORT_CLASSIFIED generation=\(catalogIdentity.generation.rawValue) " +
      "submission=\(submissionID) requested=\(requestedHandles.count) cacheHits=\(cacheHitCount) " +
      "camera=\(uncachedHandles.count) failed=\(failedCount) rearmed=\(rearmedFailureCount) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
    guard !uncachedHandles.isEmpty else {
      startDetailsIfPossible()
      return
    }

    await cancelDetailsWorkAndJoin()
    guard submissionID == latestViewportSubmissionID,
          !isSuspended,
          !isInvalidated else { return }
    startThumbnailWorkerIfNeeded()
  }

  private func isCurrentViewport(
    submissionID: UInt64,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) -> Bool {
    submissionID == latestViewportSubmissionID &&
      self.catalogIdentity == catalogIdentity &&
      !isSuspended &&
      !isInvalidated
  }

  private func startThumbnailWorkerIfNeeded() {
    guard thumbnailTask == nil,
          !pendingVisibleThumbnailHandles().isEmpty else { return }
    thumbnailTask = Task { [weak self] in
      guard let self else { return }
      await self.runThumbnailWorker()
    }
  }

  func suspendForCatalogChange() async {
    guard !isCatalogSuspended else { return }
    isCatalogSuspended = true
    await cancelTasksAndJoin()
  }

  func resumeAfterCatalogFailure() {
    guard isCatalogSuspended else { return }
    isCatalogSuspended = false
    guard !isSuspended, !isInvalidated else { return }
    if latestVisibleHandles.isEmpty {
      startDetailsIfPossible()
    } else {
      startThumbnailWorkerIfNeeded()
    }
  }

  func suspendForExternalWork() async {
    guard !isExternalWorkSuspended else { return }
    isExternalWorkSuspended = true
    await cancelTasksAndJoin()
  }

  func resumeExternalWork() async {
    guard isExternalWorkSuspended else { return }
    isExternalWorkSuspended = false
    guard !isSuspended else { return }
    if !latestVisibleHandles.isEmpty {
      await cancelDetailsWorkAndJoin()
      guard !isSuspended, !isInvalidated else { return }
      startThumbnailWorkerIfNeeded()
    }
  }

  func cancelAndJoin() async {
    await cancelTasksAndJoin()
  }

  func waitUntilIdle() async {
    let thumbnailTask = thumbnailTask
    await thumbnailTask?.value
    let detailsTask = detailsTask
    await detailsTask?.value
  }

  func invalidateSession() async {
    isInvalidated = true
    catalogIdentity = nil
    membership = []
    orderedMembership = []
    latestVisibleHandles = []
    completedDetailsHandles = []
    detailsCursor = 0
    await cancelTasksAndJoin()
    clearSessionState()
    isCatalogSuspended = false
    isExternalWorkSuspended = false
  }

  private func startDetailsIfPossible() {
    guard !isSuspended,
          !isInvalidated,
          thumbnailTask == nil,
          let catalogIdentity else { return }
    let handles = pendingDetailsHandles()
    guard !handles.isEmpty else { return }
    detailsTask?.cancel()
    detailsTask = Task { [weak self] in
      guard let self else { return }
      await self.loadDetails(handles: handles, catalogIdentity: catalogIdentity)
    }
  }

  private func runThumbnailWorker() async {
    var activeBatchRevision: UInt64?
    var activeBatchHandles: [Int] = []

    while !Task.isCancelled,
          !isSuspended,
          !isInvalidated,
          let catalogIdentity {
      let viewportRevision = latestViewportRevision
      let pendingHandles = pendingVisibleThumbnailHandles()
      guard let handle = pendingHandles.first else { break }

      if activeBatchRevision != viewportRevision {
        if !activeBatchHandles.isEmpty {
          await source.finishVisibleThumbnailBatch(handles: activeBatchHandles)
          activeBatchHandles = []
        }
        guard !Task.isCancelled, !isSuspended, !isInvalidated else { break }
        activeBatchRevision = viewportRevision
        activeBatchHandles = pendingHandles
        await source.beginVisibleThumbnailBatch(handles: pendingHandles)
      }

      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      let didFinish = await loadThumbnailWithRetry(
        handle: handle,
        identity: identity,
        cacheKey: cacheKey
      )
      if !didFinish { break }
    }

    if !activeBatchHandles.isEmpty {
      await source.finishVisibleThumbnailBatch(handles: activeBatchHandles)
    }
    thumbnailTask = nil
    startDetailsIfPossible()
  }

  private func loadDetails(
    handles: [Int],
    catalogIdentity: CameraGalleryCatalogIdentity
  ) async {
    for handle in handles {
      guard !Task.isCancelled else { return }
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      do {
        let result: CameraGalleryDetailsSourceResult
        if let info = reusableObjectInfos[cacheKey] {
          result = Self.detailsResult(from: info)
        } else {
          result = try await source.loadDetails(handle: handle)
        }
        await acceptDetails(result, catalogIdentity: catalogIdentity)
        markDetailsCompleted(handle, catalogIdentity: catalogIdentity)
      } catch is CancellationError {
        return
      } catch {
        continue
      }
    }
  }

  private func acceptThumbnail(
    _ thumbnail: CameraGalleryThumbnailResult,
    identity: CameraGalleryMediaIdentity
  ) async {
    guard catalogIdentity?.sessionEpoch == identity.catalog.sessionEpoch,
          !isInvalidated else { return }
    let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
    thumbnailDataCache[cacheKey] = thumbnail.data
    if let info = thumbnail.objectInfo,
       info.handle == identity.handle,
       isReusableEnrichment(info) {
      reusableObjectInfos[cacheKey] = info
    }
    guard isCurrent(identity.catalog, handle: identity.handle) else { return }
    await publish(.thumbnail(identity, thumbnail))
  }

  private func acceptDetails(
    _ result: CameraGalleryDetailsSourceResult,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) async {
    guard self.catalogIdentity?.sessionEpoch == catalogIdentity.sessionEpoch,
          !isInvalidated else { return }
    if let info = result.objectInfo,
       info.handle == result.handle,
       isReusableEnrichment(info) {
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: result.handle)
      reusableObjectInfos[CameraGalleryMediaCacheKey(mediaIdentity: identity)] = info
    }
    guard isCurrent(catalogIdentity, handle: result.handle) else { return }
    await publish(.details(catalogIdentity, result))
  }

  private func isCurrent(
    _ catalogIdentity: CameraGalleryCatalogIdentity,
    handle: Int
  ) -> Bool {
    !isSuspended &&
      !isInvalidated &&
      self.catalogIdentity == catalogIdentity &&
      membership.contains(handle)
  }

  private func cancelTasksAndJoin() async {
    let thumbnailTask = thumbnailTask
    let detailsTask = detailsTask
    self.thumbnailTask = nil
    self.detailsTask = nil
    thumbnailTask?.cancel()
    detailsTask?.cancel()
    await thumbnailTask?.value
    await detailsTask?.value
  }

  private func cancelDetailsWorkAndJoin() async {
    let detailsTask = detailsTask
    self.detailsTask = nil
    detailsTask?.cancel()
    await detailsTask?.value
  }

  private func clearSessionState() {
    thumbnailDataCache = [:]
    reusableObjectInfos = [:]
    thumbnailRetryCounts = [:]
    failedThumbnailKeys = []
  }

  private func loadThumbnailWithRetry(
    handle: Int,
    identity: CameraGalleryMediaIdentity,
    cacheKey: CameraGalleryMediaCacheKey
  ) async -> Bool {
    while !Task.isCancelled {
      do {
        let thumbnail = try await source.loadThumbnail(handle: handle)
        try Task.checkCancellation()
        thumbnailRetryCounts.removeValue(forKey: cacheKey)
        failedThumbnailKeys.remove(cacheKey)
        await acceptThumbnail(thumbnail, identity: identity)
        return true
      } catch is CancellationError {
        return false
      } catch {
        let disposition = CameraTransportFailureDispositionPolicy.disposition(for: error)
        switch disposition {
        case .sessionTerminal:
          failedThumbnailKeys.insert(cacheKey)
          await publish(.thumbnailState(identity, .failed))
          isInvalidated = true
          await reportTransportFailure?(error)
          return false
        case .cancelled:
          return false
        case .retryableOperation:
          let failureCount = thumbnailRetryCounts[cacheKey, default: 0] + 1
          thumbnailRetryCounts[cacheKey] = failureCount
          guard failureCount <= retryDelaysNanoseconds.count else {
            failedThumbnailKeys.insert(cacheKey)
            await publish(.thumbnailState(identity, .failed))
            return true
          }
          do {
            try await Task.sleep(nanoseconds: retryDelaysNanoseconds[failureCount - 1])
          } catch {
            return false
          }
        case .contentFailure:
          failedThumbnailKeys.insert(cacheKey)
          await publish(.thumbnailState(identity, .failed))
          return true
        }
      }
    }
    return false
  }

  private func rearmFailedThumbnails(
    handles: [Int],
    catalogIdentity: CameraGalleryCatalogIdentity
  ) -> Int {
    var count = 0
    for handle in handles {
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      guard failedThumbnailKeys.remove(cacheKey) != nil else { continue }
      thumbnailRetryCounts.removeValue(forKey: cacheKey)
      count += 1
    }
    return count
  }

  private func pendingDetailsHandles() -> [Int] {
    advanceDetailsCursor()
    return orderedMembership.dropFirst(detailsCursor).filter {
      !completedDetailsHandles.contains($0)
    }
  }

  private func pendingVisibleThumbnailHandles() -> [Int] {
    guard let catalogIdentity else { return [] }
    return latestVisibleHandles.filter { handle in
      guard membership.contains(handle) else { return false }
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      return thumbnailDataCache[cacheKey] == nil && !failedThumbnailKeys.contains(cacheKey)
    }
  }

  private func markDetailsCompleted(
    _ handle: Int,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) {
    guard self.catalogIdentity == catalogIdentity,
          membership.contains(handle) else { return }
    completedDetailsHandles.insert(handle)
    advanceDetailsCursor()
  }

  private func advanceDetailsCursor() {
    while detailsCursor < orderedMembership.count,
          completedDetailsHandles.contains(orderedMembership[detailsCursor]) {
      detailsCursor += 1
    }
  }

  private var isSuspended: Bool {
    isCatalogSuspended || isExternalWorkSuspended
  }

  private func mediaIdentity(
    catalogIdentity: CameraGalleryCatalogIdentity,
    handle: Int
  ) -> CameraGalleryMediaIdentity {
    CameraGalleryMediaIdentity(
      catalog: catalogIdentity,
      handle: handle,
      variant: .thumbnail
    )
  }

  private func isReusableEnrichment(_ info: CameraGalleryObjectInfoResult) -> Bool {
    info.hasResolvedFormat && info.captureDate.count >= 8
  }

  private static func detailsResult(
    from info: CameraGalleryObjectInfoResult
  ) -> CameraGalleryDetailsSourceResult {
    return CameraGalleryDetailsSourceResult(
      handle: info.handle,
      orientation: info.metadata.orientation.map(CameraGalleryConfirmedValue.confirmed) ?? .unknown,
      refinedFormat: CameraGalleryRepositoryAdapter.refinedFormat(
        from: info.metadata,
        hasResolvedFormat: info.hasResolvedFormat
      ),
      notes: [],
      resolvedMetadata: info.metadata,
      objectInfo: info
    )
  }
}
