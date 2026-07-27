import Foundation

@MainActor
private final class CameraGallerySessionCallbacks {
  weak var owner: CameraGallerySession?
}

private final class CameraGalleryThumbnailPipelineBox {
  var value: CameraGalleryThumbnailPipeline?
}

@MainActor
final class CameraGallerySession {
  typealias PreviewPublisher = (CameraGalleryHDPreviewPipeline.Publication) -> Void

  let identity: CameraSessionIdentity
  let sessionEpoch: UUID
  private let filterStore: CameraGalleryFilterStateStore
  private let downloadedHandles: () -> Set<Int>
  private let catalogRuntime: CameraGalleryCatalogRuntime
  private let thumbnailPipeline: CameraGalleryThumbnailPipeline
  private let hdPreviewPipeline: CameraGalleryHDPreviewPipeline
  let previewCache: NativeGalleryHighDefinitionPreviewCache
  private var nextSubmissionRawValue: UInt64 = 0
  private var isInvalidated = false
  private var presentationObservers: [UUID: (CameraGalleryPresentation) -> Void] = [:]
  private var incrementalObservers: [UUID: (CameraGalleryPresentation, Set<Int>) -> Void] = [:]
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
    let thumbnailBox = CameraGalleryThumbnailPipelineBox()
    let catalogRuntime = CameraGalleryCatalogRuntime(
      source: source,
      queryEngine: queryEngine,
      queryOwner: .gallery(sessionEpoch),
      cameraID: identity.historyKey,
      makeThumbnailPipeline: { publisher in
        let pipeline = CameraGalleryThumbnailPipeline(source: source, publish: publisher)
        thumbnailBox.value = pipeline
        return pipeline
      },
      publishPresentation: { presentation in
        callbacks.owner?.install(presentation)
      },
      publishIncrementalUpdate: { presentation, handles in
        callbacks.owner?.installIncremental(presentation, handles: handles)
      },
      reportTransportEvidence: { failure in
        callbacks.owner?.onTransportFailure?(failure)
      }
    )
    guard let thumbnailPipeline = thumbnailBox.value else {
      preconditionFailure("CameraGalleryCatalogRuntime must create its thumbnail pipeline")
    }
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
      }
    )

    self.identity = identity
    self.sessionEpoch = sessionEpoch
    self.filterStore = filterStore
    self.downloadedHandles = downloadedHandles
    self.catalogRuntime = catalogRuntime
    self.thumbnailPipeline = thumbnailPipeline
    self.hdPreviewPipeline = hdPreviewPipeline
    self.previewCache = previewCache
    filterIntent = filterStore.load(for: identity)
    callbacks.owner = self
  }

  func enter() async {
    guard !isInvalidated else { return }
    await catalogRuntime.updateDownloadedHandles(downloadedHandles())
    await catalogRuntime.start(initial: filterIntent)
    await catalogRuntime.waitUntilIdle()
  }

  func submitFilter(_ intent: CameraGalleryFilterIntent) async {
    guard !isInvalidated else { return }
    filterIntent = intent
    filterStore.save(intent, for: identity)
    nextSubmissionRawValue &+= 1
    await catalogRuntime.submit(
      intent,
      submissionID: CameraGalleryIntentSubmissionID(rawValue: nextSubmissionRawValue),
      downloadedHandles: downloadedHandles()
    )
  }

  func updateDownloadedHandles(_ handles: Set<Int>) async {
    await catalogRuntime.updateDownloadedHandles(handles)
  }

  func requestVisibleThumbnails(handles: [Int]) async {
    await catalogRuntime.requestVisibleThumbnails(handles: handles)
  }

  func cancelActiveThumbnailWork() async {
    await catalogRuntime.cancelActiveThumbnailWork()
  }

  func suspendThumbnailWorkForHDPreview() async {
    await catalogRuntime.suspendChildWorkForHighDefinitionPreview()
  }

  func resumeThumbnailWorkAfterHDPreview() async {
    await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()
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

  func pauseHDPreviewForDownload() async {
    await hdPreviewPipeline.pauseForDownload()
  }

  func resumeHDPreviewAfterDownload() {
    hdPreviewPipeline.resumeAfterDownload()
  }

  func cachedPreview(for handle: Int) -> NativeGalleryCachedPreview? {
    hdPreviewPipeline.cachedPreview(for: handle)
  }

  func markTransportLost(_ message: String) async {
    await catalogRuntime.markTransportLost(message)
  }

  func reload() async {
    guard !isInvalidated else { return }
    await catalogRuntime.start(initial: filterIntent)
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
    _ observer: @escaping (CameraGalleryPresentation, Set<Int>) -> Void
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
    await thumbnailPipeline.invalidateSession()
    await hdPreviewPipeline.invalidateSession()
    catalogIdentity = nil
    presentation = .unavailable
  }

  private func install(_ presentation: CameraGalleryPresentation) {
    guard !isInvalidated else { return }
    self.presentation = presentation
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
    handles: Set<Int>
  ) {
    guard !isInvalidated else { return }
    self.presentation = presentation
    incrementalObservers.values.forEach { $0(presentation, handles) }
  }

  private func publishPreview(_ publication: CameraGalleryHDPreviewPipeline.Publication) {
    guard !isInvalidated else { return }
    previewObservers.values.forEach { $0(publication) }
  }
}
