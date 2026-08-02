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
  private let reportTransportFailure: TransportFailureReporter?
  private var catalogIdentity: CameraGalleryCatalogIdentity?
  private var lifecycleTask: Task<Void, Never>?
  private var loadTask: Task<Void, Never>?
  private var isJoiningLoadTask = false
  private var loadState = NativeGalleryHDPreviewLoadState()
  private var visibleHandles: [Int] = []
  private var focus: NativeGalleryHDPreviewFocus = .list(visibleHandles: [])
  private var lastLoggedPriorityHandles: [Int] = []
  private var suspensionCount = 0
  private var isActive = false
  private var hasTerminalTransportFailure = false
  private(set) var state: NativeGalleryHDPreviewState?

  init(
    cache: NativeGalleryHighDefinitionPreviewCache,
    suspendThumbnailPipeline: @escaping SuspendThumbnailPipeline,
    resumeThumbnailPipeline: @escaping ResumeThumbnailPipeline,
    fetchPreview: @escaping FetchPreview,
    publish: @escaping Publisher,
    reportTransportFailure: TransportFailureReporter? = nil
  ) {
    self.cache = cache
    self.suspendThumbnailPipeline = suspendThumbnailPipeline
    self.resumeThumbnailPipeline = resumeThumbnailPipeline
    self.fetchPreview = fetchPreview
    self.publish = publish
    self.reportTransportFailure = reportTransportFailure
  }

  func activate(
    catalogIdentity: CameraGalleryCatalogIdentity,
    snapshot: NativeGalleryHDPreviewSnapshot,
    visibleHandles: [Int]
  ) async {
    await enqueueLifecycle { [weak self] in
      await self?.performActivate(
        catalogIdentity: catalogIdentity,
        snapshot: snapshot,
        visibleHandles: visibleHandles
      )
    }
  }

  private func performActivate(
    catalogIdentity: CameraGalleryCatalogIdentity,
    snapshot: NativeGalleryHDPreviewSnapshot,
    visibleHandles: [Int]
  ) async {
    guard !hasTerminalTransportFailure else { return }
    await cancelLoading()
    let wasActive = isActive
    let previousSessionEpoch = self.catalogIdentity?.sessionEpoch
    self.catalogIdentity = catalogIdentity
    if let previousSessionEpoch, previousSessionEpoch != catalogIdentity.sessionEpoch {
      cache.reset()
    }
    loadState = NativeGalleryHDPreviewLoadState()
    self.visibleHandles = visibleHandles
    focus = .list(visibleHandles: visibleHandles)
    lastLoggedPriorityHandles = []
    isActive = true
    state = makeState(snapshot: snapshot, catalogIdentity: catalogIdentity)
    publish(.state(catalogIdentity, state))
    if !wasActive {
      await suspendThumbnailPipeline()
    }
    guard isCurrent(catalogIdentity) else { return }
    startLoadingIfNeeded()
  }

  func updateSnapshot(
    catalogIdentity: CameraGalleryCatalogIdentity,
    snapshot: NativeGalleryHDPreviewSnapshot
  ) async {
    await enqueueLifecycle { [weak self] in
      self?.performUpdateSnapshot(
        catalogIdentity: catalogIdentity,
        snapshot: snapshot
      )
    }
  }

  private func performUpdateSnapshot(
    catalogIdentity: CameraGalleryCatalogIdentity,
    snapshot: NativeGalleryHDPreviewSnapshot
  ) {
    guard !hasTerminalTransportFailure,
          isCurrent(catalogIdentity),
          state?.snapshot != snapshot else { return }
    let loadableHandles = Set(snapshot.loadableDisplayHandles)
    loadState.loadingHandles.formIntersection(loadableHandles)
    loadState.failedHandles.formIntersection(loadableHandles)
    if case .fullScreen(let currentHandle) = focus,
       !loadableHandles.contains(currentHandle) {
      focus = .list(visibleHandles: visibleHandles)
      cache.setPinnedHandles([], for: catalogIdentity)
    }
    lastLoggedPriorityHandles = []
    state = makeState(snapshot: snapshot, catalogIdentity: catalogIdentity)
    publish(.state(catalogIdentity, state))
    startLoadingIfNeeded()
  }

  func updateVisibleHandles(_ handles: [Int]) {
    guard !hasTerminalTransportFailure else { return }
    guard handles != visibleHandles else { return }
    visibleHandles = handles
    focus = .list(visibleHandles: handles)
    startLoadingIfNeeded()
  }

  func focusFullScreen(on handle: Int) {
    guard !hasTerminalTransportFailure,
          isActive,
          state?.snapshot.displayHandles.contains(handle) == true else { return }
    focus = .fullScreen(currentHandle: handle)
    if let catalogIdentity, let snapshot = state?.snapshot {
      cache.setPinnedHandles(
        NativeGalleryHDPreviewSessionPolicy.fullScreenPriority(
          orderedHandles: snapshot.loadableDisplayHandles,
          currentHandle: handle
        ),
        for: catalogIdentity
      )
    }
    lastLoggedPriorityHandles = []
    startLoadingIfNeeded()
  }

  func restoreListFocus(visibleHandles handles: [Int]) {
    visibleHandles = handles
    focus = .list(visibleHandles: handles)
    if let catalogIdentity {
      cache.setPinnedHandles([], for: catalogIdentity)
    }
    lastLoggedPriorityHandles = []
    startLoadingIfNeeded()
  }

  func prepareForCatalogChange() async {
    await enqueueLifecycle { [weak self] in
      await self?.performPrepareForCatalogChange()
    }
  }

  private func performPrepareForCatalogChange() async {
    await cancelLoading()
    loadState = NativeGalleryHDPreviewLoadState()
    lastLoggedPriorityHandles = []
    let previousCatalogIdentity = catalogIdentity
    state = nil
    if let previousCatalogIdentity {
      publish(.state(previousCatalogIdentity, nil))
    }
  }

  func retry(handle: Int) {
    guard !hasTerminalTransportFailure else { return }
    guard let snapshot = state?.snapshot,
          snapshot.displayHandles.contains(handle),
          let identity = mediaIdentity(for: handle) else { return }
    cache.remove(identity)
    CameraVendorFileLogger.log(
      "[OBS] HD_PREVIEW_RETRY handle=0x\(String(format: "%08X", handle)) cacheInvalidated=true"
    )
    loadState.failedHandles.remove(handle)
    visibleHandles = [handle] + visibleHandles.filter { $0 != handle }
    publishState(snapshot: snapshot)
    startLoadingIfNeeded()
  }

  func suspend() async {
    await enqueueLifecycle { [weak self] in
      await self?.performSuspend()
    }
  }

  private func performSuspend() async {
    suspensionCount += 1
    guard suspensionCount == 1 else { return }
    await cancelLoading()
  }

  func resume() async {
    await enqueueLifecycle { [weak self] in
      self?.performResume()
    }
  }

  private func performResume() {
    guard suspensionCount > 0 else { return }
    suspensionCount -= 1
    guard suspensionCount == 0 else { return }
    startLoadingIfNeeded()
  }

  func pauseForDownload() async {
    await enqueueLifecycle { [weak self] in
      await self?.performSuspend()
    }
  }

  func resumeAfterDownload() async {
    await enqueueLifecycle { [weak self] in
      self?.performResume()
    }
  }

  func deactivate(resumeThumbnailPipeline shouldResumeThumbnailPipeline: Bool) async {
    await enqueueLifecycle { [weak self] in
      await self?.performDeactivate(
        resumeThumbnailPipeline: shouldResumeThumbnailPipeline
      )
    }
  }

  private func performDeactivate(
    resumeThumbnailPipeline shouldResumeThumbnailPipeline: Bool
  ) async {
    await cancelLoading()
    let previousCatalogIdentity = catalogIdentity
    catalogIdentity = nil
    loadState = NativeGalleryHDPreviewLoadState()
    visibleHandles = []
    focus = .list(visibleHandles: [])
    if let previousCatalogIdentity {
      cache.setPinnedHandles([], for: previousCatalogIdentity)
    }
    lastLoggedPriorityHandles = []
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
    await enqueueLifecycle { [weak self] in
      guard let self else { return }
      await self.performDeactivate(resumeThumbnailPipeline: false)
      self.cache.reset()
      self.hasTerminalTransportFailure = false
    }
  }

  func waitUntilIdle() async {
    await lifecycleTask?.value
    await loadTask?.value
  }

  func cachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    guard let identity = mediaIdentity(for: handle) else { return nil }
    return cache.restoreLoadedPreview(for: identity)
  }

  func peekCachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    guard let identity = mediaIdentity(for: handle) else { return nil }
    return cache.peekLoadedPreview(for: identity)
  }

  private func startLoadingIfNeeded() {
    guard loadTask == nil,
          !isJoiningLoadTask,
          !hasTerminalTransportFailure,
          isActive,
          suspensionCount == 0,
          state != nil else { return }
    loadTask = Task { @MainActor [weak self] in
      await self?.pump()
    }
  }

  private func enqueueLifecycle(
    _ operation: @escaping @MainActor () async -> Void
  ) async {
    let previous = lifecycleTask
    let task = Task { @MainActor in
      await previous?.value
      await operation()
    }
    lifecycleTask = task
    await task.value
  }

  private func pump() async {
    defer { loadTask = nil }
    while !Task.isCancelled,
          suspensionCount == 0,
          let catalogIdentity,
          let snapshot = state?.snapshot {
      let priorityHandles: [Int]
      let focusLabel: String
      switch focus {
      case .list(let focusedVisibleHandles):
        focusLabel = "list"
        priorityHandles = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
          orderedHandles: snapshot.loadableDisplayHandles,
          visibleHandles: focusedVisibleHandles.isEmpty
            ? Array(snapshot.loadableDisplayHandles.prefix(3))
            : focusedVisibleHandles,
          limit: 30
        )
      case .fullScreen(let currentHandle):
        focusLabel = "fullscreen"
        priorityHandles = NativeGalleryHDPreviewSessionPolicy.fullScreenPriority(
          orderedHandles: snapshot.loadableDisplayHandles,
          currentHandle: currentHandle
        )
      }
      cache.touchLoadedHandles(Array(priorityHandles.reversed()), for: catalogIdentity)
      let loadedHandles = cache.loadedHandles(for: catalogIdentity)
      let priorityHandleSet = Set(priorityHandles)
      if priorityHandles != lastLoggedPriorityHandles {
        lastLoggedPriorityHandles = priorityHandles
        CameraVendorFileLogger.log(
          "[OBS] HD_PREVIEW_PRIORITY_PLAN focus=\(focusLabel) generation=\(catalogIdentity.generation.rawValue) " +
          "visible=\(visibleHandles.count) priority=\(priorityHandles.count) " +
          "loaded=\(loadedHandles.intersection(priorityHandleSet).count) " +
          "loading=\(loadState.loadingHandles.count) failed=\(loadState.failedHandles.count)"
        )
      }
      let excluded = loadedHandles
        .union(loadState.loadingHandles)
        .union(loadState.failedHandles)
      let pending = priorityHandles.filter { !excluded.contains($0) }
      guard let handle = pending.first else {
        CameraVendorFileLogger.log(
          "[OBS] HD_PREVIEW_PRIORITY_IDLE generation=\(catalogIdentity.generation.rawValue) " +
          "priority=\(priorityHandles.count) loaded=\(loadedHandles.intersection(priorityHandleSet).count) " +
          "loading=\(loadState.loadingHandles.count) failed=\(loadState.failedHandles.count)"
        )
        return
      }
      let identity = CameraGalleryMediaIdentity(
        catalog: catalogIdentity,
        handle: handle,
        variant: .hdPreview
      )
      apply(.started(handle: handle), catalogIdentity: catalogIdentity)
      let requestStartedAt = Date()
      CameraVendorFileLogger.log(
        "[OBS] HD_PREVIEW_REQUEST_BEGIN handle=0x\(String(format: "%08X", handle)) " +
        "generation=\(catalogIdentity.generation.rawValue)"
      )
      do {
        let preview = try await fetchPreview(identity)
        try Task.checkCancellation()
        guard isCurrent(catalogIdentity) else { return }
        guard state?.snapshot.displayHandles.contains(handle) == true else {
          apply(.cancelled(handle: handle), catalogIdentity: catalogIdentity)
          continue
        }
        cache.store(preview.data, for: identity, objectOrientation: preview.objectOrientation)
        loadState = NativeGalleryHDPreviewLoadReducer.reduce(
          state: loadState,
          event: .succeeded(handle: handle)
        )
        guard let currentSnapshot = state?.snapshot else { return }
        let nextState = makeState(snapshot: currentSnapshot, catalogIdentity: catalogIdentity)
        state = nextState
        publish(.preview(identity, nextState))
        CameraVendorFileLogger.log(
          "[OBS] HD_PREVIEW_REQUEST_END handle=0x\(String(format: "%08X", handle)) " +
          "bytes=\(preview.data.count) orientation=\(preview.objectOrientation.map(String.init) ?? "unknown") " +
          "elapsedMs=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
        )
      } catch is CancellationError {
        apply(.cancelled(handle: handle), catalogIdentity: catalogIdentity)
        CameraVendorFileLogger.log(
          "[OBS] HD_PREVIEW_REQUEST_CANCELLED handle=0x\(String(format: "%08X", handle)) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
        )
        return
      } catch {
        guard !Task.isCancelled, isCurrent(catalogIdentity) else {
          apply(.cancelled(handle: handle), catalogIdentity: catalogIdentity)
          return
        }
        guard state?.snapshot.displayHandles.contains(handle) == true else {
          apply(.cancelled(handle: handle), catalogIdentity: catalogIdentity)
          continue
        }

        let disposition = CameraTransportFailureDispositionPolicy.disposition(for: error)
        switch disposition {
        case .sessionTerminal:
          hasTerminalTransportFailure = true
          apply(.failed(handle: handle), catalogIdentity: catalogIdentity)
          CameraVendorFileLogger.log(
            "[OBS] HD_PREVIEW_TRANSPORT_LOST handle=0x\(String(format: "%08X", handle)) " +
            "error=\(error.localizedDescription) " +
            "elapsedMs=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
          )
          reportTransportFailure?(error)
          return
        case .cancelled:
          apply(.cancelled(handle: handle), catalogIdentity: catalogIdentity)
          return
        case .retryableOperation, .contentFailure:
          apply(.failed(handle: handle), catalogIdentity: catalogIdentity)
          CameraVendorFileLogger.log(
            NativeGalleryHDPreviewFailureLogPolicy.message(
              handle: handle,
              errorDescription: error.localizedDescription
            )
          )
          CameraVendorFileLogger.log(
            "[OBS] HD_PREVIEW_REQUEST_FAILED handle=0x\(String(format: "%08X", handle)) " +
            "elapsedMs=\(Int(Date().timeIntervalSince(requestStartedAt) * 1000))"
          )
        }
      }
    }
  }

  private func cancelLoading() async {
    guard let task = loadTask else { return }
    isJoiningLoadTask = true
    task.cancel()
    await task.value
    loadTask = nil
    isJoiningLoadTask = false
  }

  private func apply(
    _ event: NativeGalleryHDPreviewLoadEvent,
    catalogIdentity: CameraGalleryCatalogIdentity
  ) {
    guard self.catalogIdentity == catalogIdentity,
          let snapshot = state?.snapshot else { return }
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

}
