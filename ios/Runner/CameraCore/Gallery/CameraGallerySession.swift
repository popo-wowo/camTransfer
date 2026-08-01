import Foundation

@MainActor
private final class CameraGallerySessionCallbacks {
  weak var owner: CameraGallerySession?
}

@MainActor
final class CameraGallerySession {
  typealias PreviewPublisher = (CameraGalleryHDPreviewPipeline.Publication) -> Void

  let identity: CameraSessionIdentity
  let sessionEpoch: UUID
  private let filterStore: CameraGalleryFilterStateStore
  private let downloadedHandles: () -> Set<Int>
  private let queryEngine: CameraCatalogQueryEngine
  private let catalogRuntime: CameraGalleryCatalogRuntime
  private let hdPreviewPipeline: CameraGalleryHDPreviewPipeline
  let previewCache: NativeGalleryHighDefinitionPreviewCache
  private var nextSubmissionRawValue: UInt64 = 0
  private var isInvalidated = false
  private var isCatalogSubmissionPending = false
  private var pendingCatalogSubmissionID: CameraGalleryIntentSubmissionID?
  private var presentationObservers: [UUID: (CameraGalleryPresentation) -> Void] = [:]
  private var incrementalObservers: [UUID: (CameraGalleryPresentation, CameraGalleryIncrementalDelta) -> Void] = [:]
  private var previewObservers: [UUID: PreviewPublisher] = [:]
  private(set) var filterIntent: CameraGalleryFilterIntent
  private(set) var presentation = CameraGalleryPresentation.unavailable
  private(set) var catalogIdentity: CameraGalleryCatalogIdentity?
  var onTransportFailure: ((CameraGalleryCatalogFailure) -> Void)?

  init(
    identity: CameraSessionIdentity,
    source: CameraGalleryCatalogRuntimeSource,
    sessionEpoch: UUID,
    queryEngine: CameraCatalogQueryEngine,
    filterStore: CameraGalleryFilterStateStore = CameraGalleryFilterStateStore(),
    downloadedHandles: @escaping () -> Set<Int>,
    previewCache: NativeGalleryHighDefinitionPreviewCache = NativeGalleryHighDefinitionPreviewCache(),
    fetchPreview: @escaping CameraGalleryHDPreviewPipeline.FetchPreview
  ) {
    let callbacks = CameraGallerySessionCallbacks()
    let catalogRuntime = CameraGalleryCatalogRuntime(
      source: source,
      queryEngine: queryEngine,
      queryOwner: .gallery(sessionEpoch),
      cameraID: identity.historyKey,
      publishPresentation: { _ in },
      publishSubmissionPresentation: { presentation, submissionID in
        callbacks.owner?.install(presentation, submissionID: submissionID)
      },
      publishIncrementalUpdate: { presentation, delta in
        callbacks.owner?.installIncremental(presentation, delta: delta)
      },
      reportTransportEvidence: { failure in
        callbacks.owner?.onTransportFailure?(failure)
      }
    )
    let hdPreviewPipeline = CameraGalleryHDPreviewPipeline(
      cache: previewCache,
      suspendThumbnailPipeline: {
        await catalogRuntime.suspendChildWorkForHighDefinitionPreview()
      },
      resumeThumbnailPipeline: {
        await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()
      },
      fetchPreview: fetchPreview,
      publish: { publication in
        callbacks.owner?.publishPreview(publication)
      },
      reportTransportFailure: { error in
        let failure = CameraGalleryCatalogFailure(
          message: error.localizedDescription,
          restorationMessage: nil,
          provesTransportLost: true
        )
        callbacks.owner?.onTransportFailure?(failure)
      }
    )

    self.identity = identity
    self.sessionEpoch = sessionEpoch
    self.filterStore = filterStore
    self.downloadedHandles = downloadedHandles
    self.queryEngine = queryEngine
    self.catalogRuntime = catalogRuntime
    self.hdPreviewPipeline = hdPreviewPipeline
    self.previewCache = previewCache
    filterIntent = filterStore.load(for: identity)
    callbacks.owner = self
  }

  func enter() async {
    guard !isInvalidated else { return }
    await catalogRuntime.updateDownloadedHandles(downloadedHandles())
    await catalogRuntime.start(initial: filterIntent)
  }

  func submitFilter(_ intent: CameraGalleryFilterIntent) async {
    guard !isInvalidated else { return }
    isCatalogSubmissionPending = true
    filterIntent = intent
    filterStore.save(intent, for: identity)
    nextSubmissionRawValue &+= 1
    let submissionID = CameraGalleryIntentSubmissionID(rawValue: nextSubmissionRawValue)
    pendingCatalogSubmissionID = submissionID
    await hdPreviewPipeline.prepareForCatalogChange()
    await catalogRuntime.submit(
      intent,
      submissionID: submissionID,
      downloadedHandles: downloadedHandles()
    )
  }

  func updateDownloadedHandles(_ handles: Set<Int>) async {
    await catalogRuntime.updateDownloadedHandles(handles)
  }

  func requestVisibleThumbnails(
    handles: [Int],
    submissionID: UInt64,
    expectedCatalogIdentity: CameraGalleryCatalogIdentity
  ) async {
    await catalogRuntime.requestVisibleThumbnails(
      handles: handles,
      submissionID: submissionID,
      expectedCatalogIdentity: expectedCatalogIdentity
    )
  }

  func cancelActiveThumbnailWork() async {
    await catalogRuntime.cancelActiveThumbnailWork()
  }

  func suspendContentWorkForFullScreenPreview() async {
    await hdPreviewPipeline.suspend()
    await catalogRuntime.suspendChildWorkForHighDefinitionPreview()
  }

  func resumeContentWorkAfterFullScreenPreview() async {
    await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()
    await hdPreviewPipeline.resume()
  }

  func suspendChildWorkForDownload() async {
    await hdPreviewPipeline.pauseForDownload()
    await catalogRuntime.suspendChildWorkForDownload()
  }

  func resumeChildWorkAfterDownload() async {
    await catalogRuntime.resumeChildWorkAfterDownload()
    await hdPreviewPipeline.resumeAfterDownload()
  }

  func switchPreviewMode(
    _ mode: NativeGalleryBrowseMode,
    snapshot: NativeGalleryHDPreviewSnapshot? = nil,
    visibleHandles: [Int] = []
  ) async {
    switch mode {
    case .thumbnail:
      await hdPreviewPipeline.deactivate(resumeThumbnailPipeline: true)
    case .highDefinition:
      guard !isCatalogSubmissionPending else { return }
      guard let catalogIdentity, let snapshot else { return }
      await hdPreviewPipeline.activate(
        catalogIdentity: catalogIdentity,
        snapshot: snapshot,
        visibleHandles: visibleHandles
      )
    }
  }

  func updateHDPreviewVisibleHandles(_ handles: [Int]) {
    hdPreviewPipeline.updateVisibleHandles(handles)
  }

  func retryHDPreview(handle: Int) {
    hdPreviewPipeline.retry(handle: handle)
  }

  func cachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    hdPreviewPipeline.cachedPreview(for: handle)
  }

  func peekCachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    hdPreviewPipeline.peekCachedPreview(for: handle)
  }

  func markTransportLost(_ message: String) async {
    isCatalogSubmissionPending = true
    pendingCatalogSubmissionID = nil
    await hdPreviewPipeline.prepareForCatalogChange()
    await catalogRuntime.markTransportLost(message)
  }

  func reload() async {
    guard !isInvalidated else { return }
    isCatalogSubmissionPending = true
    nextSubmissionRawValue &+= 1
    let submissionID = CameraGalleryIntentSubmissionID(rawValue: nextSubmissionRawValue)
    pendingCatalogSubmissionID = submissionID
    await hdPreviewPipeline.prepareForCatalogChange()
    await queryEngine.clearMembershipCache()
    await catalogRuntime.start(initial: filterIntent, submissionID: submissionID)
  }

  @discardableResult
  func observePresentation(_ observer: @escaping (CameraGalleryPresentation) -> Void) -> UUID {
    let id = UUID()
    presentationObservers[id] = observer
    observer(presentation)
    return id
  }

  @discardableResult
  func observeIncrementalUpdates(
    _ observer: @escaping (CameraGalleryPresentation, CameraGalleryIncrementalDelta) -> Void
  ) -> UUID {
    let id = UUID()
    incrementalObservers[id] = observer
    return id
  }

  @discardableResult
  func observePreview(_ observer: @escaping PreviewPublisher) -> UUID {
    let id = UUID()
    previewObservers[id] = observer
    return id
  }

  func removeObserver(_ id: UUID) {
    presentationObservers.removeValue(forKey: id)
    incrementalObservers.removeValue(forKey: id)
    previewObservers.removeValue(forKey: id)
  }

  func invalidate() async {
    guard !isInvalidated else { return }
    isInvalidated = true
    presentationObservers.removeAll()
    incrementalObservers.removeAll()
    previewObservers.removeAll()
    await catalogRuntime.cancelAllChildren()
    await hdPreviewPipeline.invalidateSession()
    pendingCatalogSubmissionID = nil
    catalogIdentity = nil
    presentation = .unavailable
  }

  private func install(
    _ presentation: CameraGalleryPresentation,
    submissionID: CameraGalleryIntentSubmissionID
  ) {
    guard !isInvalidated else { return }
    self.presentation = presentation
    if !presentation.isLoading,
       submissionID == pendingCatalogSubmissionID {
      isCatalogSubmissionPending = false
      pendingCatalogSubmissionID = nil
    }
    if case .ready(let generation, let snapshotID) = presentation.state {
      catalogIdentity = CameraGalleryCatalogIdentity(
        cameraID: identity.historyKey,
        sessionEpoch: sessionEpoch,
        generation: generation,
        snapshotID: snapshotID
      )
    } else {
      catalogIdentity = nil
    }
    presentationObservers.values.forEach { $0(presentation) }
  }

  private func installIncremental(
    _ presentation: CameraGalleryPresentation,
    delta: CameraGalleryIncrementalDelta
  ) {
    guard !isInvalidated else { return }
    self.presentation = presentation
    incrementalObservers.values.forEach { $0(presentation, delta) }
  }

  private func publishPreview(_ publication: CameraGalleryHDPreviewPipeline.Publication) {
    guard !isInvalidated else { return }
    previewObservers.values.forEach { $0(publication) }
  }
}
