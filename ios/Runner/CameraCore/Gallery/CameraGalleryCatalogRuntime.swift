import Foundation

actor CameraGalleryCatalogRuntime {
  typealias PresentationPublisher = @MainActor (CameraGalleryPresentation) -> Void
  typealias IncrementalUpdatePublisher = @MainActor (CameraGalleryPresentation, Set<Int>) -> Void
  typealias TransportEvidenceReporter = @MainActor (CameraGalleryCatalogFailure) -> Void
  typealias ThumbnailPipelineFactory = (
    _ publisher: @escaping CameraGalleryThumbnailPipeline.Publisher
  ) -> CameraGalleryThumbnailPipeline

  private struct PendingTransaction {
    enum SourceOperation {
      case initial
      case filtered
    }

    let generation: CameraGalleryGenerationID
    let intent: CameraGalleryFilterIntent
    let sourceOperation: SourceOperation
  }

  private let queryEngine: CameraCatalogQueryEngine
  private let queryOwner: CameraCatalogAccessOwner
  private let cameraID: String
  private let publishPresentation: PresentationPublisher
  private let publishIncrementalUpdate: IncrementalUpdatePublisher
  private let reportTransportEvidence: TransportEvidenceReporter
  private var repository = CameraGalleryRepository()
  private var nextGenerationRawValue: UInt64 = 0
  private var latestIntentSubmissionID = CameraGalleryIntentSubmissionID(rawValue: 0)
  private var currentIntent = CameraGalleryFilterIntent.all
  private var currentPresentation = CameraGalleryPresentation.unavailable
  private var activeTransactionTask: Task<Void, Never>?
  private var pendingTransaction: PendingTransaction?
  private var thumbnailPipeline: CameraGalleryThumbnailPipeline!
  private var downloadedHandles: Set<Int> = []
  private var installedMembershipIntent: CameraGalleryFilterIntent?
  private var isAcceptingChildWork = false
  private var hdPreviewSuspensionCount = 0
  private var isShuttingDown = false

  init(
    source: CameraGalleryCatalogRuntimeSource,
    queryEngine: CameraCatalogQueryEngine? = nil,
    queryOwner: CameraCatalogAccessOwner = .gallery(UUID()),
    cameraID: String = "gallery",
    makeThumbnailPipeline: ThumbnailPipelineFactory? = nil,
    publishPresentation: @escaping PresentationPublisher,
    publishIncrementalUpdate: @escaping IncrementalUpdatePublisher = { _, _ in },
    reportTransportEvidence: @escaping TransportEvidenceReporter
  ) {
    self.queryEngine = queryEngine ?? CameraCatalogQueryEngine(source: source)
    self.queryOwner = queryOwner
    self.cameraID = cameraID
    self.publishPresentation = publishPresentation
    self.publishIncrementalUpdate = publishIncrementalUpdate
    self.reportTransportEvidence = reportTransportEvidence
    let publisher: CameraGalleryThumbnailPipeline.Publisher = { [weak self] publication in
      guard let self else { return }
      await self.applyPipelinePublication(publication)
    }
    thumbnailPipeline = makeThumbnailPipeline?(publisher) ?? CameraGalleryThumbnailPipeline(
      source: source,
      publish: publisher
    )
  }

  func start(initial intent: CameraGalleryFilterIntent = .all) async {
    await submit(intent, forceCameraTransaction: true, sourceOperation: .initial)
  }

  func submit(
    _ intent: CameraGalleryFilterIntent,
    submissionID: CameraGalleryIntentSubmissionID,
    downloadedHandles: Set<Int>
  ) async {
    guard submissionID > latestIntentSubmissionID else { return }
    latestIntentSubmissionID = submissionID
    self.downloadedHandles = downloadedHandles
    await submit(intent, forceCameraTransaction: false)
  }

  func updateDownloadedHandles(_ handles: Set<Int>) async {
    downloadedHandles = handles
    guard isAcceptingChildWork,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else { return }
    currentPresentation = makeReadyPresentation()
    await publishCurrentPresentation()
  }

  func requestVisibleThumbnails(handles: [Int]) async {
    guard isAcceptingChildWork,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else {
      return
    }
    await thumbnailPipeline.requestVisible(handles: handles)
  }

  func suspendChildWorkForHighDefinitionPreview() async {
    hdPreviewSuspensionCount += 1
    guard hdPreviewSuspensionCount == 1 else { return }
    isAcceptingChildWork = false
    await thumbnailPipeline.suspend()
  }

  func resumeChildWorkAfterHighDefinitionPreview() async {
    guard hdPreviewSuspensionCount > 0 else { return }
    hdPreviewSuspensionCount -= 1
    guard hdPreviewSuspensionCount == 0,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID else {
      return
    }
    isAcceptingChildWork = true
    await thumbnailPipeline.resume()
  }

  func isChildWorkSuspendedForHighDefinitionPreview() -> Bool {
    hdPreviewSuspensionCount > 0
  }

  func cancelAllChildren() async {
    isShuttingDown = true
    isAcceptingChildWork = false
    await thumbnailPipeline.cancelAndJoin()
    pendingTransaction = nil
    await activeTransactionTask?.value
    activeTransactionTask = nil
    await thumbnailPipeline.invalidateSession()
  }

  func cancelActiveThumbnailWork() async {
    await thumbnailPipeline.cancelAndJoin()
  }

  func markTransportLost(_ message: String) async {
    isAcceptingChildWork = false
    await thumbnailPipeline.invalidateSession()
    pendingTransaction = nil
    currentPresentation = CameraGalleryPresentation(
      state: .transportLost(message),
      intent: currentIntent,
      items: sort(repository.items, by: currentIntent.sort),
      entries: repository.entries
    )
    await publishCurrentPresentation()
  }

  func presentation() -> CameraGalleryPresentation {
    currentPresentation
  }

  func waitUntilIdle() async {
    while let task = activeTransactionTask {
      await task.value
    }
    await thumbnailPipeline.waitUntilIdle()
  }

  private func submit(
    _ intent: CameraGalleryFilterIntent,
    forceCameraTransaction: Bool,
    sourceOperation: PendingTransaction.SourceOperation = .filtered
  ) async {
    guard !isTransportLost, !isShuttingDown else { return }

    if !forceCameraTransaction,
       repository.snapshotID != nil,
       currentIntent.hasSameCameraMembership(as: intent) {
      currentIntent = intent
      guard case .ready(let generation, let snapshotID) = currentPresentation.state,
            repository.generation == generation,
            repository.snapshotID == snapshotID,
            let installedMembershipIntent,
            installedMembershipIntent.hasSameCameraMembership(as: intent) else {
        currentPresentation = preservingCurrentState(for: intent)
        await publishCurrentPresentation()
        return
      }
      currentPresentation = makeReadyPresentation()
      await publishCurrentPresentation()
      return
    }

    let generation = allocateGeneration()
    currentIntent = intent
    isAcceptingChildWork = false
    await thumbnailPipeline.cancelAndJoin()

    if let unsupportedReason = unsupportedReason(for: intent) {
      pendingTransaction = nil
      currentPresentation = CameraGalleryPresentation(
        state: .unsupported(generation: generation, reason: unsupportedReason),
        intent: intent,
        items: [],
        entries: []
      )
      await publishCurrentPresentation()
      return
    }

    currentPresentation = CameraGalleryPresentation(
      state: .loading(generation: generation, intent: intent),
      intent: intent,
      items: [],
      entries: []
    )
    await publishCurrentPresentation()

    let transaction = PendingTransaction(
      generation: generation,
      intent: intent,
      sourceOperation: sourceOperation
    )
    guard activeTransactionTask == nil else {
      pendingTransaction = transaction
      activeTransactionTask?.cancel()
      return
    }
    start(transaction)
  }

  private func start(_ transaction: PendingTransaction) {
    activeTransactionTask = Task { [weak self] in
      guard let self else { return }
      await self.execute(transaction)
    }
  }

  private func execute(_ transaction: PendingTransaction) async {
    do {
      let resolution = try await queryEngine.resolve(
        rule: transaction.intent.rule,
        owner: queryOwner,
        downloadedHandles: downloadedHandles
      )
      let snapshot = resolution.snapshot
      guard !isShuttingDown,
            transaction.generation == currentPresentation.generation else {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      repository.install(snapshot, generation: transaction.generation)
      installedMembershipIntent = transaction.intent
      currentIntent = transaction.intent
      currentPresentation = makeReadyPresentation()
      isAcceptingChildWork = hdPreviewSuspensionCount == 0
      await publishCurrentPresentation()
      await thumbnailPipeline.install(
        catalogIdentity: CameraGalleryCatalogIdentity(
          cameraID: cameraID,
          sessionEpoch: queryEngine.sessionEpoch,
          generation: transaction.generation,
          snapshotID: snapshot.snapshotID
        ),
        membership: snapshot.items.map(\.handle),
        reusableObjectInfos: resolution.authoritativeObjectInfos
      )
    } catch is CancellationError {
      // A cancelled transaction may still finish mandatory transport cleanup.
      // It never publishes and the latest pending intent is started below.
    } catch let failure as CameraGalleryCatalogTransactionFailure {
      guard !isShuttingDown,
            transaction.generation == currentPresentation.generation else {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      currentPresentation = CameraGalleryPresentation(
        state: .failed(generation: transaction.generation, failure: failure.catalogFailure),
        intent: transaction.intent,
        items: [],
        entries: []
      )
      await publishCurrentPresentation()
      await reportTransportEvidence(failure.catalogFailure)
    } catch {
      guard !isShuttingDown,
            transaction.generation == currentPresentation.generation else {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      let failure = CameraGalleryCatalogFailure(
        message: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: false
      )
      currentPresentation = CameraGalleryPresentation(
        state: .failed(generation: transaction.generation, failure: failure),
        intent: transaction.intent,
        items: [],
        entries: []
      )
      await publishCurrentPresentation()
      await reportTransportEvidence(failure)
    }
    await finishTransactionAndStartPendingIfNeeded()
  }

  private func finishTransactionAndStartPendingIfNeeded() async {
    activeTransactionTask = nil
    guard !isShuttingDown else {
      pendingTransaction = nil
      return
    }
    guard let pendingTransaction else { return }
    self.pendingTransaction = nil
    start(pendingTransaction)
  }

  private func applyPipelinePublication(
    _ publication: CameraGalleryThumbnailPipeline.Publication
  ) async {
    switch publication {
    case .thumbnail(let mediaIdentity, let thumbnail):
      guard mediaIdentity.variant == .thumbnail,
            isCurrentPublication(
              mediaIdentity.catalog,
              handle: mediaIdentity.handle
            ) else { return }
      let childIdentity = CameraGalleryChildIdentity(
        generation: mediaIdentity.catalog.generation,
        snapshotID: mediaIdentity.catalog.snapshotID,
        handle: mediaIdentity.handle
      )
      guard repository.applyThumbnail(thumbnail, identity: childIdentity) else { return }
      currentPresentation = makeReadyPresentation()
      await publishIncrementalUpdate(currentPresentation, [mediaIdentity.handle])
    case .details(let catalogIdentity, let result):
      guard isCurrentPublication(catalogIdentity, handle: result.handle) else { return }
      let childIdentity = CameraGalleryChildIdentity(
        generation: catalogIdentity.generation,
        snapshotID: catalogIdentity.snapshotID,
        handle: result.handle
      )
      guard repository.applyDetails(result, identity: childIdentity) else { return }
      currentPresentation = makeReadyPresentation()
      await publishIncrementalUpdate(currentPresentation, [result.handle])
    }
  }

  private func isCurrentPublication(
    _ catalogIdentity: CameraGalleryCatalogIdentity,
    handle: Int
  ) -> Bool {
    guard isAcceptingChildWork,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          catalogIdentity.cameraID == cameraID,
          catalogIdentity.sessionEpoch == queryEngine.sessionEpoch,
          generation == catalogIdentity.generation,
          snapshotID == catalogIdentity.snapshotID,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          repository.items.contains(where: { $0.handle == handle }),
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else {
      return false
    }
    return true
  }

  private func allocateGeneration() -> CameraGalleryGenerationID {
    nextGenerationRawValue &+= 1
    return CameraGalleryGenerationID(rawValue: nextGenerationRawValue)
  }

  private func unsupportedReason(
    for intent: CameraGalleryFilterIntent
  ) -> CameraGalleryUnsupportedReason? {
    nil
  }

  private var isTransportLost: Bool {
    if case .transportLost = currentPresentation.state { return true }
    return false
  }

  private func makeReadyPresentation() -> CameraGalleryPresentation {
    guard let generation = repository.generation,
          let snapshotID = repository.snapshotID else {
      return CameraGalleryPresentation.unavailable
    }
    return CameraGalleryPresentation(
      state: .ready(generation: generation, snapshotID: snapshotID),
      intent: currentIntent,
      items: sort(repository.items, by: currentIntent.sort),
      entries: repository.entries
    )
  }

  private func preservingCurrentState(
    for intent: CameraGalleryFilterIntent
  ) -> CameraGalleryPresentation {
    let state: CameraGalleryCatalogState
    switch currentPresentation.state {
    case .loading(let generation, _):
      state = .loading(generation: generation, intent: intent)
    case .unsupported(let generation, let reason):
      state = .unsupported(generation: generation, reason: reason)
    case .failed(let generation, let failure):
      state = .failed(generation: generation, failure: failure)
    case .transportLost(let message):
      state = .transportLost(message)
    case .ready, .unavailable:
      return currentPresentation
    }
    return CameraGalleryPresentation(
      state: state,
      intent: intent,
      items: [],
      entries: []
    )
  }

  private func sort(
    _ items: [CameraVendorGalleryItem],
    by sort: CameraGallerySortIntent
  ) -> [CameraVendorGalleryItem] {
    switch sort {
    case .newest:
      return items
    case .oldest:
      return Array(items.reversed())
    case .notDownloaded:
      return items.filter { !downloadedHandles.contains($0.handle) } +
        items.filter { downloadedHandles.contains($0.handle) }
    }
  }

  private func publishCurrentPresentation() async {
    let presentation = currentPresentation
    await publishPresentation(presentation)
  }
}
