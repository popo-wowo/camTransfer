import Foundation

@MainActor
final class CameraGalleryHDPreviewPipeline {
  enum Publication {
    case state(CameraGalleryCatalogIdentity, NativeGalleryHDPreviewState?)
    case preview(CameraGalleryMediaIdentity, NativeGalleryHDPreviewState)
  }

  typealias SuspendThumbnailPipeline = () async -> Void
  typealias ResumeThumbnailPipeline = () async -> Void
  typealias FetchPreview = (CameraGalleryMediaIdentity) async throws -> CameraGalleryPreviewResult
  typealias Publisher = (Publication) -> Void

  private let cache: NativeGalleryHighDefinitionPreviewCache
  private let suspendThumbnailPipeline: SuspendThumbnailPipeline
  private let resumeThumbnailPipeline: ResumeThumbnailPipeline
  private let fetchPreview: FetchPreview
  private let publish: Publisher
  private var catalogIdentity: CameraGalleryCatalogIdentity?
  private var loadTask: Task<Void, Never>?
  private var loadState = NativeGalleryHDPreviewLoadState()
  private var visibleHandles: [Int] = []
  private var suspensionCount = 0
  private var isActive = false
  private(set) var state: NativeGalleryHDPreviewState?

  init(
    cache: NativeGalleryHighDefinitionPreviewCache,
    suspendThumbnailPipeline: @escaping SuspendThumbnailPipeline,
    resumeThumbnailPipeline: @escaping ResumeThumbnailPipeline,
    fetchPreview: @escaping FetchPreview,
    publish: @escaping Publisher
  ) {
    self.cache = cache
    self.suspendThumbnailPipeline = suspendThumbnailPipeline
    self.resumeThumbnailPipeline = resumeThumbnailPipeline
    self.fetchPreview = fetchPreview
    self.publish = publish
  }

  func activate(
    catalogIdentity: CameraGalleryCatalogIdentity,
    snapshot: NativeGalleryHDPreviewSnapshot,
    visibleHandles: [Int]
  ) async {
    await cancelLoading()
    let previousSessionEpoch = self.catalogIdentity?.sessionEpoch
    self.catalogIdentity = catalogIdentity
    if let previousSessionEpoch, previousSessionEpoch != catalogIdentity.sessionEpoch {
      cache.reset()
    }
    loadState = NativeGalleryHDPreviewLoadState()
    self.visibleHandles = visibleHandles
    suspensionCount = 0
    isActive = true
    state = makeState(snapshot: snapshot, catalogIdentity: catalogIdentity)
    publish(.state(catalogIdentity, state))
    await suspendThumbnailPipeline()
    guard isCurrent(catalogIdentity) else { return }
    startLoadingIfNeeded()
  }

  func updateVisibleHandles(_ handles: [Int]) {
    guard handles != visibleHandles else { return }
    visibleHandles = handles
    startLoadingIfNeeded()
  }

  func retry(handle: Int) {
    guard let snapshot = state?.snapshot,
          snapshot.displayHandles.contains(handle) else { return }
    loadState.failedHandles.remove(handle)
    visibleHandles = [handle] + visibleHandles.filter { $0 != handle }
    publishState(snapshot: snapshot)
    startLoadingIfNeeded()
  }

  func suspend() async {
    suspensionCount += 1
    guard suspensionCount == 1 else { return }
    await cancelLoading()
  }

  func resume() {
    guard suspensionCount > 0 else { return }
    suspensionCount -= 1
    guard suspensionCount == 0 else { return }
    startLoadingIfNeeded()
  }

  func pauseForDownload() async {
    await suspend()
  }

  func resumeAfterDownload() {
    resume()
  }

  func deactivate(resumeThumbnailPipeline shouldResumeThumbnailPipeline: Bool) async {
    await cancelLoading()
    let previousCatalogIdentity = catalogIdentity
    catalogIdentity = nil
    loadState = NativeGalleryHDPreviewLoadState()
    visibleHandles = []
    suspensionCount = 0
    isActive = false
    state = nil
    if let previousCatalogIdentity {
      publish(.state(previousCatalogIdentity, nil))
    }
    if shouldResumeThumbnailPipeline {
      await resumeThumbnailPipeline()
    }
  }

  func invalidateSession() async {
    await deactivate(resumeThumbnailPipeline: false)
    cache.reset()
  }

  func waitUntilIdle() async {
    await loadTask?.value
  }

  func cachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    guard let identity = mediaIdentity(for: handle) else { return nil }
    return cache.restoreLoadedPreview(for: identity)
  }

  private func startLoadingIfNeeded() {
    guard loadTask == nil,
          isActive,
          suspensionCount == 0,
          state != nil else { return }
    loadTask = Task { @MainActor [weak self] in
      await self?.pump()
    }
  }

  private func pump() async {
    defer { loadTask = nil }
    while !Task.isCancelled,
          suspensionCount == 0,
          let catalogIdentity,
          let snapshot = state?.snapshot {
      let pending = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
        orderedHandles: snapshot.displayHandles,
        visibleHandles: visibleHandles.isEmpty ? Array(snapshot.displayHandles.prefix(3)) : visibleHandles,
        loadedHandles: cache.loadedHandles(for: catalogIdentity),
        loadingHandles: loadState.loadingHandles,
        failedHandles: loadState.failedHandles
      )
      guard let handle = pending.first else { return }
      let identity = CameraGalleryMediaIdentity(
        catalog: catalogIdentity,
        handle: handle,
        variant: .hdPreview
      )
      apply(.started(handle: handle), snapshot: snapshot, catalogIdentity: catalogIdentity)
      do {
        let preview = try await fetchPreview(identity)
        try Task.checkCancellation()
        guard isCurrent(identity) else { return }
        cache.store(preview.data, for: identity, objectOrientation: preview.objectOrientation)
        loadState = NativeGalleryHDPreviewLoadReducer.reduce(
          state: loadState,
          event: .succeeded(handle: handle)
        )
        let nextState = makeState(snapshot: snapshot, catalogIdentity: catalogIdentity)
        state = nextState
        publish(.preview(identity, nextState))
      } catch is CancellationError {
        apply(.cancelled(handle: handle), snapshot: snapshot, catalogIdentity: catalogIdentity)
        return
      } catch {
        guard !Task.isCancelled, isCurrent(identity) else {
          apply(.cancelled(handle: handle), snapshot: snapshot, catalogIdentity: catalogIdentity)
          return
        }
        apply(.failed(handle: handle), snapshot: snapshot, catalogIdentity: catalogIdentity)
      }
    }
  }

  private func cancelLoading() async {
    let task = loadTask
    loadTask = nil
    task?.cancel()
    await task?.value
  }

  private func apply(
    _ event: NativeGalleryHDPreviewLoadEvent,
    snapshot: NativeGalleryHDPreviewSnapshot,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) {
    guard self.catalogIdentity == catalogIdentity else { return }
    loadState = NativeGalleryHDPreviewLoadReducer.reduce(state: loadState, event: event)
    publishState(snapshot: snapshot)
  }

  private func publishState(snapshot: NativeGalleryHDPreviewSnapshot) {
    guard let catalogIdentity else { return }
    let nextState = makeState(snapshot: snapshot, catalogIdentity: catalogIdentity)
    state = nextState
    publish(.state(catalogIdentity, nextState))
  }

  private func makeState(
    snapshot: NativeGalleryHDPreviewSnapshot,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) -> NativeGalleryHDPreviewState {
    NativeGalleryHDPreviewState(
      snapshot: snapshot,
      loadedHandles: cache.loadedHandles(for: catalogIdentity),
      loadState: loadState
    )
  }

  private func mediaIdentity(for handle: Int) -> CameraGalleryMediaIdentity? {
    guard let catalogIdentity else { return nil }
    return CameraGalleryMediaIdentity(
      catalog: catalogIdentity,
      handle: handle,
      variant: .hdPreview
    )
  }

  private func isCurrent(_ catalogIdentity: CameraGalleryCatalogIdentity) -> Bool {
    isActive && self.catalogIdentity == catalogIdentity
  }

  private func isCurrent(_ identity: CameraGalleryMediaIdentity) -> Bool {
    identity.variant == .hdPreview &&
      isCurrent(identity.catalog) &&
      state?.snapshot.displayHandles.contains(identity.handle) == true
  }
}
