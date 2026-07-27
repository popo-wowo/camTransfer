import Foundation

actor CameraGalleryThumbnailPipeline {
  enum Publication {
    case thumbnail(CameraGalleryMediaIdentity, CameraVendorGalleryThumbnail)
    case details(CameraGalleryCatalogIdentity, CameraGalleryDetailsSourceResult)
  }

  typealias Publisher = @MainActor (Publication) async -> Void

  private struct ActiveVisibleRequest {
    let id: UInt64
    let catalogIdentity: CameraGalleryCatalogIdentity
    let handles: Set<Int>
  }

  private let source: CameraGalleryThumbnailPipelineSource
  private let publish: Publisher
  private var catalogIdentity: CameraGalleryCatalogIdentity?
  private var membership: Set<Int> = []
  private var orderedMembership: [Int] = []
  private var thumbnailTask: Task<Void, Never>?
  private var detailsTask: Task<Void, Never>?
  private var activeVisibleRequest: ActiveVisibleRequest?
  private var nextVisibleRequestID: UInt64 = 0
  private var thumbnailDataCache: [CameraGalleryMediaCacheKey: Data] = [:]
  private var reusableObjectInfos: [CameraGalleryMediaCacheKey: CameraVendorCameraObjectInfo] = [:]
  private var thumbnailRetryCounts: [CameraGalleryMediaCacheKey: Int] = [:]
  private var suspensionCount = 0
  private var isInvalidated = false

  init(
    source: CameraGalleryThumbnailPipelineSource,
    publish: @escaping Publisher
  ) {
    self.source = source
    self.publish = publish
  }

  func install(
    catalogIdentity: CameraGalleryCatalogIdentity,
    membership: [Int],
    reusableObjectInfos: [Int: CameraVendorCameraObjectInfo]
  ) async {
    let previousSessionEpoch = self.catalogIdentity?.sessionEpoch
    self.catalogIdentity = catalogIdentity
    orderedMembership = membership
    self.membership = Set(membership)
    isInvalidated = false
    if let previousSessionEpoch,
       previousSessionEpoch != catalogIdentity.sessionEpoch {
      clearSessionState()
    }
    await cancelTasksAndJoin()
    for (handle, info) in reusableObjectInfos where info.handle == handle {
      let identity = mediaIdentity(
        catalogIdentity: catalogIdentity,
        handle: handle
      )
      self.reusableObjectInfos[CameraGalleryMediaCacheKey(mediaIdentity: identity)] = info
    }
    startDetailsIfPossible()
  }

  func requestVisible(handles: [Int]) async {
    guard suspensionCount == 0,
          !isInvalidated,
          let catalogIdentity else { return }
    let requestedHandles = handles.filter { membership.contains($0) }
    guard !requestedHandles.isEmpty else { return }

    var uncachedHandles: [Int] = []
    for handle in requestedHandles {
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      if let data = thumbnailDataCache[cacheKey] {
        await publish(.thumbnail(
          identity,
          CameraVendorGalleryThumbnail(data: data, item: nil)
        ))
      } else {
        uncachedHandles.append(handle)
      }
    }
    guard !uncachedHandles.isEmpty else { return }

    let requestedHandleSet = Set(uncachedHandles)
    if let activeVisibleRequest,
       activeVisibleRequest.catalogIdentity == catalogIdentity,
       requestedHandleSet.isSubset(of: activeVisibleRequest.handles) {
      return
    }

    await cancelVisibleTaskAndJoin()
    nextVisibleRequestID &+= 1
    let request = ActiveVisibleRequest(
      id: nextVisibleRequestID,
      catalogIdentity: catalogIdentity,
      handles: requestedHandleSet
    )
    activeVisibleRequest = request
    thumbnailTask = Task { [weak self] in
      guard let self else { return }
      await self.loadVisibleThumbnails(
        handles: uncachedHandles,
        catalogIdentity: catalogIdentity
      )
      await self.finishVisibleRequest(id: request.id)
    }
  }

  func suspend() async {
    suspensionCount += 1
    guard suspensionCount == 1 else { return }
    await cancelTasksAndJoin()
  }

  func resume() {
    guard suspensionCount > 0 else { return }
    suspensionCount -= 1
    guard suspensionCount == 0 else { return }
    startDetailsIfPossible()
  }

  func cancelAndJoin() async {
    await cancelTasksAndJoin()
  }

  func waitUntilIdle() async {
    let thumbnailTask = thumbnailTask
    let detailsTask = detailsTask
    await thumbnailTask?.value
    await detailsTask?.value
  }

  func invalidateSession() async {
    isInvalidated = true
    catalogIdentity = nil
    membership = []
    orderedMembership = []
    await cancelTasksAndJoin()
    clearSessionState()
    suspensionCount = 0
  }

  private func startDetailsIfPossible() {
    guard suspensionCount == 0,
          !isInvalidated,
          let catalogIdentity else { return }
    let handles = orderedMembership
    detailsTask?.cancel()
    detailsTask = Task { [weak self] in
      guard let self else { return }
      await self.loadDetails(handles: handles, catalogIdentity: catalogIdentity)
    }
  }

  private func loadVisibleThumbnails(
    handles: [Int],
    catalogIdentity: CameraGalleryCatalogIdentity
  ) async {
    await source.beginVisibleThumbnailBatch(handles: handles)
    for handle in handles {
      guard !Task.isCancelled else { break }
      let identity = mediaIdentity(catalogIdentity: catalogIdentity, handle: handle)
      let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
      do {
        let thumbnail = try await source.loadThumbnail(handle: handle)
        thumbnailRetryCounts.removeValue(forKey: cacheKey)
        await acceptThumbnail(thumbnail, identity: identity)
      } catch is CancellationError {
        break
      } catch {
        thumbnailRetryCounts[cacheKey, default: 0] += 1
      }
    }
    await source.finishVisibleThumbnailBatch(handles: handles)
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
      } catch is CancellationError {
        return
      } catch {
        continue
      }
    }
  }

  private func acceptThumbnail(
    _ thumbnail: CameraVendorGalleryThumbnail,
    identity: CameraGalleryMediaIdentity
  ) async {
    guard catalogIdentity?.sessionEpoch == identity.catalog.sessionEpoch,
          !isInvalidated else { return }
    let cacheKey = CameraGalleryMediaCacheKey(mediaIdentity: identity)
    thumbnailDataCache[cacheKey] = thumbnail.data
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
    suspensionCount == 0 &&
      !isInvalidated &&
      self.catalogIdentity == catalogIdentity &&
      membership.contains(handle)
  }

  private func cancelVisibleTaskAndJoin() async {
    let task = thumbnailTask
    thumbnailTask = nil
    activeVisibleRequest = nil
    task?.cancel()
    await task?.value
  }

  private func cancelTasksAndJoin() async {
    let thumbnailTask = thumbnailTask
    let detailsTask = detailsTask
    self.thumbnailTask = nil
    self.detailsTask = nil
    activeVisibleRequest = nil
    thumbnailTask?.cancel()
    detailsTask?.cancel()
    await thumbnailTask?.value
    await detailsTask?.value
  }

  private func finishVisibleRequest(id: UInt64) {
    guard activeVisibleRequest?.id == id else { return }
    activeVisibleRequest = nil
    thumbnailTask = nil
  }

  private func clearSessionState() {
    thumbnailDataCache = [:]
    reusableObjectInfos = [:]
    thumbnailRetryCounts = [:]
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

  private func isReusableEnrichment(_ info: CameraVendorCameraObjectInfo) -> Bool {
    info.hasResolvedFormat && info.captureDate.count >= 8
  }

  private static func detailsResult(
    from info: CameraVendorCameraObjectInfo
  ) -> CameraGalleryDetailsSourceResult {
    let item = CameraVendorGalleryItem(
      handle: info.handle,
      filename: info.filename,
      formatLabel: info.galleryFormatLabel,
      captureDate: info.captureDate,
      byteSizeText: info.compressedSize > 0
        ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
        : "",
      compressedSize: info.compressedSize == 0 ? nil : info.compressedSize,
      orientation: info.orientation
    )
    let details = CameraGalleryRepositoryAdapter.detailsResult(from: info)
    return CameraGalleryDetailsSourceResult(
      handle: details.handle,
      orientation: details.orientation,
      refinedFormat: details.refinedFormat,
      notes: details.notes,
      resolvedItem: item,
      objectInfo: info
    )
  }
}
