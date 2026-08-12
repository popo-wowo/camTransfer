import Foundation

actor CameraGalleryCatalogRuntime {
  typealias PresentationPublisher = @MainActor (CameraGalleryPresentation) -> Void
  typealias SubmissionPresentationPublisher = @MainActor (
    CameraGalleryPresentation,
    CameraGalleryIntentSubmissionID
  ) -> Void
  typealias IncrementalUpdatePublisher = @MainActor (CameraGalleryPresentation, CameraGalleryIncrementalDelta) -> Void
  typealias TransportEvidenceReporter = @MainActor (CameraGalleryCatalogFailure) -> Void

  private struct PendingTransaction {
    enum SourceOperation {
      case initial
      case filtered
    }

    let generation: CameraGalleryGenerationID
    let intent: CameraGalleryFilterIntent
    let sourceOperation: SourceOperation
  }

  private final class ThumbnailPublicationRelay: @unchecked Sendable {
    weak var runtime: CameraGalleryCatalogRuntime?
    var transportEvidenceReporter: TransportEvidenceReporter?

    func publish(_ publication: CameraGalleryThumbnailPipeline.Publication) async {
      await runtime?.applyPipelinePublication(publication)
    }
  }

  private let queryEngine: CameraCatalogQueryEngine
  private let queryOwner: CameraCatalogAccessOwner
  private let cameraID: String
  private let publishPresentation: PresentationPublisher
  private let publishSubmissionPresentation: SubmissionPresentationPublisher
  private let publishIncrementalUpdate: IncrementalUpdatePublisher
  private let reportTransportEvidence: TransportEvidenceReporter
  private var repository = CameraGalleryRepository()
  private var nextGenerationRawValue: UInt64 = 0
  private var latestIntentSubmissionID = CameraGalleryIntentSubmissionID(rawValue: 0)
  private var currentIntent = CameraGalleryFilterIntent.all
  private var currentPresentation = CameraGalleryPresentation.unavailable
  private var activeTransactionTask: Task<Void, Never>?
  private var pendingTransaction: PendingTransaction?
  private let thumbnailPipeline: CameraGalleryThumbnailPipeline
  private var downloadedHandles: Set<Int> = []
  private var downloadedProjectionNeedsPublish = false
  private var installedMembershipIntent: CameraGalleryFilterIntent?
  private var isAcceptingChildWork = false
  private var hdPreviewSuspensionCount = 0
  private var downloadSuspensionCount = 0
  private var isShuttingDown = false

  init(
    source: CameraGalleryCatalogRuntimeSource,
    queryEngine: CameraCatalogQueryEngine? = nil,
    queryOwner: CameraCatalogAccessOwner = .gallery(UUID()),
    cameraID: String = "gallery",
    publishPresentation: @escaping PresentationPublisher,
    publishSubmissionPresentation: @escaping SubmissionPresentationPublisher = { _, _ in },
    publishIncrementalUpdate: @escaping IncrementalUpdatePublisher = { _, _ in },
    reportTransportEvidence: @escaping TransportEvidenceReporter
  ) {
    self.queryEngine = queryEngine ?? CameraCatalogQueryEngine(source: source)
    self.queryOwner = queryOwner
    self.cameraID = cameraID
    self.publishPresentation = publishPresentation
    self.publishSubmissionPresentation = publishSubmissionPresentation
    self.publishIncrementalUpdate = publishIncrementalUpdate
    self.reportTransportEvidence = reportTransportEvidence
    let relay = ThumbnailPublicationRelay()
    let publisher: CameraGalleryThumbnailPipeline.Publisher = { publication in
      await relay.publish(publication)
    }
    relay.transportEvidenceReporter = reportTransportEvidence
    thumbnailPipeline = CameraGalleryThumbnailPipeline(
      source: source,
      publish: publisher,
      reportTransportFailure: { error in
        let failure = CameraGalleryCatalogFailure(
          message: error.localizedDescription,
          restorationMessage: nil,
          provesTransportLost: true
        )
        relay.transportEvidenceReporter?(failure)
      }
    )
    relay.runtime = self
  }

  func start(
    initial intent: CameraGalleryFilterIntent = .all,
    submissionID: CameraGalleryIntentSubmissionID? = nil
  ) async {
    if let submissionID {
      guard submissionID > latestIntentSubmissionID else { return }
      latestIntentSubmissionID = submissionID
    }
    await submit(intent, forceCameraTransaction: true, sourceOperation: .initial)
  }

  func reload(
    _ intent: CameraGalleryFilterIntent,
    submissionID: CameraGalleryIntentSubmissionID
  ) async {
    guard submissionID > latestIntentSubmissionID else { return }
    latestIntentSubmissionID = submissionID
    await submit(intent, forceCameraTransaction: true, sourceOperation: .filtered)
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
    guard !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else { return }
    currentPresentation = makeReadyPresentation()
    guard downloadSuspensionCount == 0 else {
      downloadedProjectionNeedsPublish = true
      return
    }
    downloadedProjectionNeedsPublish = false
    await publishCurrentPresentation()
  }

  func requestVisibleThumbnails(
    handles: [Int],
    submissionID: UInt64? = nil,
    expectedCatalogIdentity: CameraGalleryCatalogIdentity? = nil
  ) async {
    guard !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else {
      return
    }
    let currentCatalogIdentity = CameraGalleryCatalogIdentity(
      cameraID: cameraID,
      sessionEpoch: queryEngine.sessionEpoch,
      generation: generation,
      snapshotID: snapshotID
    )
    if let expectedCatalogIdentity,
       expectedCatalogIdentity != currentCatalogIdentity {
      CameraVendorFileLogger.log(
        "[OBS] THUMBNAIL_VIEWPORT_SKIPPED reason=stale-catalog " +
        "expectedGeneration=\(expectedCatalogIdentity.generation.rawValue) " +
        "currentGeneration=\(generation.rawValue) submission=\(submissionID ?? 0)"
      )
      return
    }
    if let submissionID {
      await thumbnailPipeline.requestVisible(
        handles: handles,
        submissionID: submissionID
      )
    } else {
      await thumbnailPipeline.requestVisible(handles: handles)
    }
  }

  func suspendChildWorkForHighDefinitionPreview() async {
    hdPreviewSuspensionCount += 1
    guard hdPreviewSuspensionCount == 1 else { return }
    isAcceptingChildWork = false
    await thumbnailPipeline.suspendForExternalWork()
  }

  func resumeChildWorkAfterHighDefinitionPreview() async {
    guard hdPreviewSuspensionCount > 0 else { return }
    hdPreviewSuspensionCount -= 1
    guard hdPreviewSuspensionCount == 0 else { return }
    await resumeChildWorkIfPossible()
  }

  func isChildWorkSuspendedForHighDefinitionPreview() -> Bool {
    hdPreviewSuspensionCount > 0
  }

  func suspendChildWorkForDownload() async {
    downloadSuspensionCount += 1
    guard downloadSuspensionCount == 1 else { return }
    isAcceptingChildWork = false
    await thumbnailPipeline.suspendForExternalWork()
  }

  func resumeChildWorkAfterDownload() async {
    guard downloadSuspensionCount > 0 else { return }
    downloadSuspensionCount -= 1
    guard downloadSuspensionCount == 0 else { return }
    await publishDeferredDownloadedProjectionIfPossible()
    await resumeChildWorkIfPossible()
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

  private func resumeChildWorkIfPossible() async {
    guard hdPreviewSuspensionCount == 0,
          downloadSuspensionCount == 0,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID else {
      return
    }
    isAcceptingChildWork = true
    await thumbnailPipeline.resumeExternalWork()
  }

  private func publishDeferredDownloadedProjectionIfPossible() async {
    guard downloadedProjectionNeedsPublish,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
          let installedMembershipIntent,
          installedMembershipIntent.hasSameCameraMembership(as: currentIntent) else {
      return
    }
    downloadedProjectionNeedsPublish = false
    currentPresentation = makeReadyPresentation()
    await publishCurrentPresentation()
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
    await thumbnailPipeline.suspendForCatalogChange()

    if let unsupportedReason = unsupportedReason(for: intent) {
      pendingTransaction = nil
      await thumbnailPipeline.cancelAndJoin()
      currentPresentation = CameraGalleryPresentation(
        state: .unsupported(generation: generation, reason: unsupportedReason),
        intent: intent,
        items: [],
        entries: []
      )
      await publishCurrentPresentation()
      return
    }

    let shouldPublishLoading = repository.snapshotID == nil
    currentPresentation = CameraGalleryPresentation(
      state: .loading(generation: generation, intent: intent),
      intent: intent,
      items: sort(repository.items, by: intent.sort),
      entries: repository.entries
    )
    if shouldPublishLoading {
      await publishCurrentPresentation()
    }

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
      let queryStartedAt = Date()
      let resolution = try await queryEngine.resolve(
        rule: transaction.intent.rule,
        owner: queryOwner,
        downloadedHandles: downloadedHandles,
        usesInitialCatalogStrategy: transaction.sourceOperation == .initial
      )
      let snapshot = resolution.membershipSnapshot
      CameraVendorFileLogger.log(
        "[OBS] CATALOG_QUERY_RESOLVED generation=\(transaction.generation.rawValue) " +
        "items=\(snapshot.items.count) authoritativeInfo=\(resolution.authoritativeObjectInfos.count) " +
        "elapsedMs=\(Int(Date().timeIntervalSince(queryStartedAt) * 1000))"
      )
      guard !isShuttingDown,
            transaction.generation == currentPresentation.generation else {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      let repositoryInstallStartedAt = Date()
      repository.install(snapshot, generation: transaction.generation)
      CameraVendorFileLogger.log(
        "[OBS] CATALOG_REPOSITORY_INSTALL_END generation=\(transaction.generation.rawValue) " +
        "items=\(repository.items.count) elapsedMs=\(Int(Date().timeIntervalSince(repositoryInstallStartedAt) * 1000))"
      )
      installedMembershipIntent = transaction.intent
      currentIntent = transaction.intent
      currentPresentation = makeReadyPresentation()
      downloadedProjectionNeedsPublish = false
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
      isAcceptingChildWork = hdPreviewSuspensionCount == 0 && downloadSuspensionCount == 0
      await publishCurrentPresentation()
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
      let disposition = CameraTransportFailureDispositionPolicy.disposition(
        for: error,
        context: .catalog
      )
      if disposition == .cancelled {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      guard !isShuttingDown,
            transaction.generation == currentPresentation.generation else {
        await finishTransactionAndStartPendingIfNeeded()
        return
      }
      let failure = CameraGalleryCatalogFailure(
        message: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: disposition == .sessionTerminal
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
      let previousPresentation = currentPresentation
      guard repository.applyThumbnail(thumbnail, identity: childIdentity) else { return }
      // If thumbnail carries resolvedMetadata with a confirmed format,
      // also update entries details so the format label appears immediately.
      if let metadata = thumbnail.resolvedMetadata,
         !metadata.formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let detailsResult = CameraGalleryRepositoryAdapter.detailsResult(
          fromResolvedMetadata: metadata
        )
        repository.applyDetails(detailsResult, identity: childIdentity)
      }
      currentPresentation = makeReadyPresentation()
      let delta = CameraGalleryIncrementalDelta.between(
        previous: previousPresentation,
        current: currentPresentation,
        changedHandles: [mediaIdentity.handle]
      )
      await publishIncrementalUpdate(currentPresentation, delta)
    case .thumbnailState(let mediaIdentity, let state):
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
      let previousPresentation = currentPresentation
      guard repository.applyThumbnailState(state, identity: childIdentity) else { return }
      currentPresentation = makeReadyPresentation()
      let delta = CameraGalleryIncrementalDelta.between(
        previous: previousPresentation,
        current: currentPresentation,
        changedHandles: [mediaIdentity.handle]
      )
      await publishIncrementalUpdate(currentPresentation, delta)
    case .details(let catalogIdentity, let result):
      guard isCurrentPublication(catalogIdentity, handle: result.handle) else { return }
      let childIdentity = CameraGalleryChildIdentity(
        generation: catalogIdentity.generation,
        snapshotID: catalogIdentity.snapshotID,
        handle: result.handle
      )
      let previousPresentation = currentPresentation
      guard repository.applyDetails(result, identity: childIdentity) else { return }
      currentPresentation = makeReadyPresentation()
      let delta = CameraGalleryIncrementalDelta.between(
        previous: previousPresentation,
        current: currentPresentation,
        changedHandles: [result.handle]
      )
      await publishIncrementalUpdate(currentPresentation, delta)
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
    let candidates = repository.items.map {
      CameraMediaFilterCandidate(
        handle: $0.handle,
        captureDate: CameraFilterEngine.parseCaptureDate($0.captureDate)
      )
    }
    let projectedHandles = Set(CameraFilterEngine.project(
      candidates,
      rule: currentIntent.rule,
      downloadedHandles: downloadedHandles
    ).map(\.handle))
    let items = sort(
      repository.items.filter { projectedHandles.contains($0.handle) },
      by: currentIntent.sort
    )
    let entriesByHandle = Dictionary(
      uniqueKeysWithValues: repository.entries.map { ($0.summary.handle, $0) }
    )
    return CameraGalleryPresentation(
      state: .ready(generation: generation, snapshotID: snapshotID),
      intent: currentIntent,
      items: items,
      entries: items.compactMap { entriesByHandle[$0.handle] }
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
    _ items: [CameraGalleryCatalogItem],
    by sort: CameraGallerySortIntent
  ) -> [CameraGalleryCatalogItem] {
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
    let submissionID = latestIntentSubmissionID
    let startedAt = Date()
    await publishPresentation(presentation)
    await publishSubmissionPresentation(presentation, submissionID)
    CameraVendorFileLogger.log(
      "[OBS] CATALOG_PRESENTATION_PUBLISH_END generation=\(presentation.generation?.rawValue ?? 0) " +
      "submission=\(submissionID.rawValue) items=\(presentation.items.count) " +
      "loading=\(presentation.isLoading) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
  }
}
