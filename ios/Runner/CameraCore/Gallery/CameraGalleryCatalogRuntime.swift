import Foundation

actor CameraGalleryCatalogRuntime {
  typealias PresentationPublisher = @MainActor (CameraGalleryPresentation) -> Void
  typealias IncrementalUpdatePublisher = @MainActor (CameraGalleryPresentation, Set<Int>) -> Void
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

  private struct ActiveThumbnailRequest {
    let id: UInt64
    let generation: CameraGalleryGenerationID
    let snapshotID: CameraGallerySnapshotID
    let handles: Set<Int>
  }

  private let source: CameraGalleryCatalogRuntimeSource
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
  private var thumbnailTask: Task<Void, Never>?
  private var activeThumbnailRequest: ActiveThumbnailRequest?
  private var nextThumbnailRequestID: UInt64 = 0
  private var detailsTask: Task<Void, Never>?
  private var enrichedObjectInfos: [Int: CameraVendorCameraObjectInfo] = [:]
  private var downloadedHandles: Set<Int> = []
  private var installedMembershipIntent: CameraGalleryFilterIntent?
  private var isAcceptingChildWork = false
  private var hdPreviewSuspensionCount = 0
  private var isShuttingDown = false

  init(
    source: CameraGalleryCatalogRuntimeSource,
    publishPresentation: @escaping PresentationPublisher,
    publishIncrementalUpdate: @escaping IncrementalUpdatePublisher = { _, _ in },
    reportTransportEvidence: @escaping TransportEvidenceReporter
  ) {
    self.source = source
    self.publishPresentation = publishPresentation
    self.publishIncrementalUpdate = publishIncrementalUpdate
    self.reportTransportEvidence = reportTransportEvidence
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
    let knownHandles = Set(repository.items.map(\.handle))
    let requestedHandles = handles.filter { knownHandles.contains($0) }
    guard !requestedHandles.isEmpty else {
      return
    }
    let requestedHandleSet = Set(requestedHandles)
    if let activeThumbnailRequest,
       activeThumbnailRequest.generation == generation,
       activeThumbnailRequest.snapshotID == snapshotID,
       requestedHandleSet.isSubset(of: activeThumbnailRequest.handles) {
      return
    }

    thumbnailTask?.cancel()
    nextThumbnailRequestID &+= 1
    let request = ActiveThumbnailRequest(
      id: nextThumbnailRequestID,
      generation: generation,
      snapshotID: snapshotID,
      handles: requestedHandleSet
    )
    activeThumbnailRequest = request
    thumbnailTask = Task { [weak self] in
      guard let self else { return }
      await self.loadThumbnails(
        handles: requestedHandles,
        generation: generation,
        snapshotID: snapshotID
      )
      await self.finishThumbnailRequest(id: request.id)
    }
  }

  func suspendChildWorkForHighDefinitionPreview() async {
    hdPreviewSuspensionCount += 1
    guard hdPreviewSuspensionCount == 1 else { return }
    isAcceptingChildWork = false
    await cancelAndJoinChildWork()
  }

  func resumeChildWorkAfterHighDefinitionPreview() {
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
    startDetailsWork(
      handles: repository.items.map(\.handle),
      generation: generation,
      snapshotID: snapshotID
    )
  }

  func isChildWorkSuspendedForHighDefinitionPreview() -> Bool {
    hdPreviewSuspensionCount > 0
  }

  func cancelAllChildren() async {
    isShuttingDown = true
    isAcceptingChildWork = false
    await cancelAndJoinChildWork()
    pendingTransaction = nil
    await activeTransactionTask?.value
    activeTransactionTask = nil
    enrichedObjectInfos = [:]
  }

  func cancelActiveThumbnailWork() async {
    thumbnailTask?.cancel()
    await thumbnailTask?.value
    thumbnailTask = nil
    activeThumbnailRequest = nil
  }

  func markTransportLost(_ message: String) async {
    isAcceptingChildWork = false
    await cancelAndJoinChildWork()
    pendingTransaction = nil
    enrichedObjectInfos = [:]
    currentPresentation = CameraGalleryPresentation(
      state: .transportLost(message),
      intent: currentIntent,
      items: project(repository.items, intent: currentIntent),
      entries: repository.entries
    )
    await publishCurrentPresentation()
  }

  func presentation() -> CameraGalleryPresentation {
    currentPresentation
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
    await cancelAndJoinChildWork()

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
      let snapshot: CameraGalleryCatalogSnapshot
      switch transaction.sourceOperation {
      case .initial:
        snapshot = try await source.loadInitialCatalog()
      case .filtered:
        snapshot = try await source.loadCatalog(for: transaction.intent)
      }
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
      if isAcceptingChildWork {
        startDetailsWork(
          handles: snapshot.items.map(\.handle),
          generation: transaction.generation,
          snapshotID: snapshot.snapshotID
        )
      }
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

  private func startDetailsWork(
    handles: [Int],
    generation: CameraGalleryGenerationID,
    snapshotID: CameraGallerySnapshotID
  ) {
    detailsTask?.cancel()
    detailsTask = Task { [weak self] in
      guard let self else { return }
      for handle in handles {
        guard !Task.isCancelled else { return }
        do {
          let result: CameraGalleryDetailsSourceResult
          if let cachedInfo = await self.verifiedObjectInfo(handle: handle) {
            result = Self.detailsResult(from: cachedInfo)
          } else {
            result = try await self.source.loadDetails(handle: handle)
          }
          await self.applyDetails(
            result,
            identity: CameraGalleryChildIdentity(
              generation: generation,
              snapshotID: snapshotID,
              handle: handle
            )
          )
        } catch is CancellationError {
          return
        } catch {
          // Details are enrichment only. The catalog runtime never disconnects
          // the camera because an enrichment request failed.
          continue
        }
      }
    }
  }

  private func loadThumbnails(
    handles: [Int],
    generation: CameraGalleryGenerationID,
    snapshotID: CameraGallerySnapshotID
  ) async {
    await source.beginVisibleThumbnailBatch(handles: handles)
    for handle in handles {
      guard !Task.isCancelled else { break }
      do {
        let thumbnail = try await source.loadThumbnail(handle: handle)
        await applyThumbnail(
          thumbnail,
          identity: CameraGalleryChildIdentity(
            generation: generation,
            snapshotID: snapshotID,
            handle: handle
          )
        )
      } catch is CancellationError {
        break
      } catch {
        continue
      }
    }
    await source.finishVisibleThumbnailBatch(handles: handles)
  }

  private func applyThumbnail(
    _ thumbnail: CameraVendorGalleryThumbnail,
    identity: CameraGalleryChildIdentity
  ) async {
    guard isCurrentChild(identity) else { return }
    guard repository.applyThumbnail(thumbnail, identity: identity) else { return }
    currentPresentation = makeReadyPresentation()
    await publishIncrementalUpdate(currentPresentation, [identity.handle])
  }

  private func applyDetails(
    _ result: CameraGalleryDetailsSourceResult,
    identity: CameraGalleryChildIdentity
  ) async {
    guard isCurrentChild(identity) else { return }
    guard repository.applyDetails(result, identity: identity) else { return }
    if let objectInfo = result.objectInfo,
       objectInfo.handle == identity.handle,
       result.handle == identity.handle,
       isReusableEnrichment(objectInfo) {
      enrichedObjectInfos[identity.handle] = objectInfo
    }
    currentPresentation = makeReadyPresentation()
    await publishIncrementalUpdate(currentPresentation, [identity.handle])
  }

  private func verifiedObjectInfo(handle: Int) -> CameraVendorCameraObjectInfo? {
    enrichedObjectInfos[handle]
  }

  private func isReusableEnrichment(
    _ info: CameraVendorCameraObjectInfo
  ) -> Bool {
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

  private func cancelAndJoinChildWork() async {
    let thumbnailTask = thumbnailTask
    let detailsTask = detailsTask
    self.thumbnailTask = nil
    activeThumbnailRequest = nil
    self.detailsTask = nil
    thumbnailTask?.cancel()
    detailsTask?.cancel()
    await thumbnailTask?.value
    await detailsTask?.value
  }

  private func finishThumbnailRequest(id: UInt64) {
    guard activeThumbnailRequest?.id == id else { return }
    activeThumbnailRequest = nil
    thumbnailTask = nil
  }

  private func isCurrentChild(_ identity: CameraGalleryChildIdentity) -> Bool {
    guard isAcceptingChildWork,
          !isShuttingDown,
          case .ready(let generation, let snapshotID) = currentPresentation.state,
          generation == identity.generation,
          snapshotID == identity.snapshotID,
          repository.generation == generation,
          repository.snapshotID == snapshotID,
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
      items: project(repository.items, intent: currentIntent),
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

  private func project(
    _ items: [CameraVendorGalleryItem],
    intent: CameraGalleryFilterIntent
  ) -> [CameraVendorGalleryItem] {
    let dateFiltered = clientSideDateFilter(items, date: intent.date)
    switch intent.sort {
    case .newest:
      return dateFiltered
    case .oldest:
      return Array(dateFiltered.reversed())
    case .notDownloaded:
      return dateFiltered.filter { !downloadedHandles.contains($0.handle) } +
        dateFiltered.filter { downloadedHandles.contains($0.handle) }
    }
  }

  private func clientSideDateFilter(
    _ items: [CameraVendorGalleryItem],
    date: CameraGalleryDateIntent
  ) -> [CameraVendorGalleryItem] {
    guard date != .all else { return items }
    let calendar = Calendar(identifier: .gregorian)
    let now = Date()
    return items.filter { item in
      guard let captureDate = parseCaptureDate(item.captureDate) else { return false }
      switch date {
      case .all:
        return true
      case .today:
        return calendar.isDate(captureDate, inSameDayAs: now)
      case .specificDay(let day):
        return calendar.isDate(captureDate, inSameDayAs: day)
      case .range(let from, let to):
        let startOfFrom = calendar.startOfDay(for: from)
        let startOfDayAfterTo = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
        return captureDate >= startOfFrom && captureDate < startOfDayAfterTo
      }
    }
  }

  private func parseCaptureDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    // Format: "20260711T094525" or "2026-07-11"
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if trimmed.count >= 15, trimmed.contains("T") {
      formatter.dateFormat = "yyyyMMdd'T'HHmmss"
      return formatter.date(from: String(trimmed.prefix(15)))
    }
    if trimmed.count >= 10, trimmed.contains("-") {
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.date(from: String(trimmed.prefix(10)))
    }
    if trimmed.count >= 8 {
      formatter.dateFormat = "yyyyMMdd"
      return formatter.date(from: String(trimmed.prefix(8)))
    }
    return nil
  }

  private func publishCurrentPresentation() async {
    let presentation = currentPresentation
    await publishPresentation(presentation)
  }
}
