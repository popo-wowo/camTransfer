import Foundation

enum NativeGalleryBrowseMode {
  case thumbnail
  case highDefinition
}

enum NativeGalleryHDChromePolicy {
  static let usesGalleryBackground = true
  static let dateFormat = "yyyy-MM-dd"
  static let showsLoadCountBeforeDate = true
}

enum NativeGalleryHDPreviewFailureLogPolicy {
  static func message(handle: Int, errorDescription: String) -> String {
    "[OBS] HD_PREVIEW_IMAGE_FAILED handle=0x\(String(format: "%08X", handle)) error=\(errorDescription)"
  }
}

struct NativeGalleryHDPreviewItem: Equatable {
  let displayItem: CameraVendorGalleryItem
  let rawSidecar: CameraVendorGalleryItem?
}

struct NativeGalleryHDPreviewSnapshot: Equatable {
  let activeDate: Date
  let items: [NativeGalleryHDPreviewItem]

  var displayHandles: [Int] {
    items.map(\.displayItem.handle)
  }

  var allDownloadHandles: Set<Int> {
    Set(items.flatMap { item in
      [item.displayItem.handle] + (item.rawSidecar.map { [$0.handle] } ?? [])
    })
  }
}

struct NativeGalleryHDPreviewLoadState: Equatable {
  var loadingHandles: Set<Int> = []
  var failedHandles: Set<Int> = []
}

enum NativeGalleryHDPreviewLoadEvent: Equatable {
  case started(handle: Int)
  case succeeded(handle: Int)
  case failed(handle: Int)
  case cancelled(handle: Int)
  case reset
}

enum NativeGalleryHDPreviewLoadReducer {
  static func reduce(
    state: NativeGalleryHDPreviewLoadState,
    event: NativeGalleryHDPreviewLoadEvent
  ) -> NativeGalleryHDPreviewLoadState {
    var next = state
    switch event {
    case .started(let handle):
      next.loadingHandles.insert(handle)
      next.failedHandles.remove(handle)
    case .succeeded(let handle):
      next.loadingHandles.remove(handle)
      next.failedHandles.remove(handle)
    case .failed(let handle):
      next.loadingHandles.remove(handle)
      next.failedHandles.insert(handle)
    case .cancelled(let handle):
      next.loadingHandles.remove(handle)
    case .reset:
      next = NativeGalleryHDPreviewLoadState()
    }
    return next
  }
}

struct NativeGalleryHDPreviewState: Equatable {
  let snapshot: NativeGalleryHDPreviewSnapshot
  let loadedHandles: Set<Int>
  let loadState: NativeGalleryHDPreviewLoadState

  init(
    snapshot: NativeGalleryHDPreviewSnapshot,
    loadedHandles: Set<Int>,
    loadState: NativeGalleryHDPreviewLoadState = NativeGalleryHDPreviewLoadState()
  ) {
    self.snapshot = snapshot
    self.loadedHandles = loadedHandles
    self.loadState = loadState
  }

  var loadedCount: Int {
    NativeGalleryHDPreviewSessionPolicy.loadedCount(
      sessionHandles: Set(snapshot.displayHandles),
      loadedHandles: loadedHandles
    )
  }

  var totalCount: Int {
    snapshot.items.count
  }
}

@MainActor
final class NativeGalleryHDPreviewCoordinator {
  typealias SuspendChildWork = () async -> Void
  typealias ResumeChildWork = () async -> Void
  typealias FetchPreview = (Int) async throws -> CameraVendorGalleryPreview
  typealias StatePublisher = (NativeGalleryHDPreviewState?) -> Void

  private let cache: NativeGalleryHighDefinitionPreviewCache
  private let suspendChildWork: SuspendChildWork
  private let resumeChildWork: ResumeChildWork
  private let fetchPreview: FetchPreview
  private let publish: StatePublisher
  private var loadTask: Task<Void, Never>?
  private var loadState = NativeGalleryHDPreviewLoadState()
  private var visibleHandles: [Int] = []
  private(set) var state: NativeGalleryHDPreviewState?

  init(
    cache: NativeGalleryHighDefinitionPreviewCache,
    suspendChildWork: @escaping SuspendChildWork,
    resumeChildWork: @escaping ResumeChildWork,
    fetchPreview: @escaping FetchPreview,
    publish: @escaping StatePublisher
  ) {
    self.cache = cache
    self.suspendChildWork = suspendChildWork
    self.resumeChildWork = resumeChildWork
    self.fetchPreview = fetchPreview
    self.publish = publish
  }

  func activate(
    snapshot: NativeGalleryHDPreviewSnapshot,
    visibleHandles: [Int]
  ) async {
    await cancelLoading()
    loadState = NativeGalleryHDPreviewLoadState()
    self.visibleHandles = visibleHandles
    state = makeState(snapshot: snapshot)
    publish(state)
    await suspendChildWork()
    guard state?.snapshot == snapshot else { return }
    startLoadingIfNeeded()
  }

  func updateVisibleHandles(_ handles: [Int]) {
    guard handles != visibleHandles else { return }
    visibleHandles = handles
    startLoadingIfNeeded()
  }

  func retry(handle: Int) {
    guard let snapshot = state?.snapshot,
          snapshot.displayHandles.contains(handle) else {
      return
    }
    loadState.failedHandles.remove(handle)
    visibleHandles = [handle] + visibleHandles.filter { $0 != handle }
    state = makeState(snapshot: snapshot)
    publish(state)
    startLoadingIfNeeded()
  }

  func pauseForDownload() async {
    await cancelLoading()
  }

  func resumeAfterDownload() {
    startLoadingIfNeeded()
  }

  func stop(resumeCatalogChildWork: Bool) async {
    await cancelLoading()
    loadState = NativeGalleryHDPreviewLoadState()
    visibleHandles = []
    state = nil
    publish(nil)
    if resumeCatalogChildWork {
      await resumeChildWork()
    }
  }

  private func startLoadingIfNeeded() {
    guard loadTask == nil, state != nil else { return }
    loadTask = Task { @MainActor [weak self] in
      await self?.pump()
    }
  }

  private func pump() async {
    defer { loadTask = nil }
    while !Task.isCancelled, let snapshot = state?.snapshot {
      let pending = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
        orderedHandles: snapshot.displayHandles,
        visibleHandles: visibleHandles.isEmpty ? Array(snapshot.displayHandles.prefix(3)) : visibleHandles,
        loadedHandles: cache.loadedHandles,
        loadingHandles: loadState.loadingHandles,
        failedHandles: loadState.failedHandles
      )
      guard let handle = pending.first else { return }
      apply(.started(handle: handle), snapshot: snapshot)
      do {
        let preview = try await fetchPreview(handle)
        try Task.checkCancellation()
        cache.store(preview.data, for: handle, objectOrientation: preview.item?.orientation)
        apply(.succeeded(handle: handle), snapshot: snapshot)
      } catch is CancellationError {
        apply(.cancelled(handle: handle), snapshot: snapshot)
        return
      } catch {
        guard !Task.isCancelled else {
          apply(.cancelled(handle: handle), snapshot: snapshot)
          return
        }
        apply(.failed(handle: handle), snapshot: snapshot)
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
    snapshot: NativeGalleryHDPreviewSnapshot
  ) {
    loadState = NativeGalleryHDPreviewLoadReducer.reduce(state: loadState, event: event)
    state = makeState(snapshot: snapshot)
    publish(state)
  }

  private func makeState(snapshot: NativeGalleryHDPreviewSnapshot) -> NativeGalleryHDPreviewState {
    NativeGalleryHDPreviewState(
      snapshot: snapshot,
      loadedHandles: cache.loadedHandles,
      loadState: loadState
    )
  }
}

enum NativeGalleryHDDownloadRequestPolicy {
  static func requests(
    displayHandles: [Int],
    rawHandles: [Int],
    preferCompressedDisplay: Bool
  ) -> [CameraSessionQueuedDownload] {
    var seen = Set<Int>()
    var result: [CameraSessionQueuedDownload] = []

    for handle in displayHandles where seen.insert(handle).inserted {
      guard let requestHandle = UInt32(exactly: handle) else { continue }
      result.append(CameraSessionQueuedDownload(
        handle: requestHandle,
        mode: preferCompressedDisplay ? .compressed : .original
      ))
    }
    for handle in rawHandles where seen.insert(handle).inserted {
      guard let requestHandle = UInt32(exactly: handle) else { continue }
      result.append(CameraSessionQueuedDownload(handle: requestHandle, mode: .original))
    }
    return result
  }
}

enum NativeGalleryHDPreviewSessionPolicy {
  static func availableDates(
    items: [CameraVendorGalleryItem],
    calendar: Calendar = .current
  ) -> [Date] {
    let dates = items.compactMap { item -> Date? in
      guard !isVideoCandidate(item),
            let captureDate = NativeGalleryFilterPolicy.parsedCaptureDate(item.captureDate) else {
        return nil
      }
      return calendar.startOfDay(for: captureDate)
    }
    return Array(Set(dates)).sorted(by: >)
  }

  static func preferredActiveDate(
    items: [CameraVendorGalleryItem],
    currentDate: Date,
    calendar: Calendar = .current
  ) -> Date {
    let dates = availableDates(items: items, calendar: calendar)
    if let current = dates.first(where: { calendar.isDate($0, inSameDayAs: currentDate) }) {
      return current
    }
    return dates.first ?? calendar.startOfDay(for: currentDate)
  }

  static func snapshot(
    items: [CameraVendorGalleryItem],
    activeDate: Date,
    calendar: Calendar = .current
  ) -> NativeGalleryHDPreviewSnapshot {
    let dayItems = items.filter { item in
      guard let captureDate = NativeGalleryFilterPolicy.parsedCaptureDate(item.captureDate) else {
        return false
      }
      return calendar.isDate(captureDate, inSameDayAs: activeDate)
    }
    let ambiguousItems = ambiguousExtendedStillItems(dayItems)
    var ambiguousHandles = Set<Int>()
    for item in ambiguousItems {
      ambiguousHandles.insert(item.displayItem.handle)
      if let rawSidecar = item.rawSidecar {
        ambiguousHandles.insert(rawSidecar.handle)
      }
    }
    let resolvedDayItems = dayItems.filter { !ambiguousHandles.contains($0.handle) }
    let rawCandidates = resolvedDayItems.filter(isRawCandidate)
    var usedRawHandles = Set<Int>()

    let resolvedPreviewItems = resolvedDayItems.filter(isDisplayCandidate).map { displayItem in
      let sidecar = rawSidecar(
        for: displayItem,
        candidates: rawCandidates,
        excluding: usedRawHandles
      )
      if let sidecar {
        usedRawHandles.insert(sidecar.handle)
      }
      return NativeGalleryHDPreviewItem(displayItem: displayItem, rawSidecar: sidecar)
    }

    return NativeGalleryHDPreviewSnapshot(
      activeDate: calendar.startOfDay(for: activeDate),
      items: (ambiguousItems + resolvedPreviewItems).sorted { lhs, rhs in
        let lDate = NativeGalleryFilterPolicy.parsedCaptureDate(lhs.displayItem.captureDate) ?? .distantPast
        let rDate = NativeGalleryFilterPolicy.parsedCaptureDate(rhs.displayItem.captureDate) ?? .distantPast
        return lDate > rDate
      }
    )
  }

  static func priorityWindow(
    orderedHandles: [Int],
    visibleHandles: [Int],
    loadedHandles: Set<Int>,
    loadingHandles: Set<Int>,
    failedHandles: Set<Int>
  ) -> [Int] {
    let indexByHandle = Dictionary(uniqueKeysWithValues: orderedHandles.enumerated().map { ($0.element, $0.offset) })
    let visible = orderedUnique(visibleHandles.filter { indexByHandle[$0] != nil })
    guard !visible.isEmpty else {
      return orderedHandles.prefix(20).filter {
        !loadedHandles.contains($0) && !loadingHandles.contains($0) && !failedHandles.contains($0)
      }
    }

    let indices = visible.compactMap { indexByHandle[$0] }
    guard let firstVisibleIndex = indices.min(), let lastVisibleIndex = indices.max() else {
      return []
    }
    let afterStart = min(lastVisibleIndex + 1, orderedHandles.count)
    let afterEnd = min(afterStart + 20, orderedHandles.count)
    let beforeStart = max(0, firstVisibleIndex - 5)

    let after = Array(orderedHandles[afterStart..<afterEnd])
    let before = Array(orderedHandles[beforeStart..<firstVisibleIndex])
    let excluded = loadedHandles.union(loadingHandles).union(failedHandles)
    return orderedUnique(visible + after + before).filter { !excluded.contains($0) }
  }

  static func loadedCount(sessionHandles: Set<Int>, loadedHandles: Set<Int>) -> Int {
    sessionHandles.intersection(loadedHandles).count
  }

  private static func rawSidecar(
    for displayItem: CameraVendorGalleryItem,
    candidates: [CameraVendorGalleryItem],
    excluding usedHandles: Set<Int>
  ) -> CameraVendorGalleryItem? {
    let available = candidates.filter { !usedHandles.contains($0.handle) }
    let displayStem = filenameStem(displayItem.filename)
    if !displayStem.isEmpty,
       let exact = available.first(where: { filenameStem($0.filename) == displayStem }) {
      return exact
    }
    return available
      .filter { abs($0.handle - displayItem.handle) <= 3 }
      .min { left, right in
        let leftDistance = abs(left.handle - displayItem.handle)
        let rightDistance = abs(right.handle - displayItem.handle)
        return leftDistance == rightDistance ? left.handle < right.handle : leftDistance < rightDistance
      }
  }

  private static func isDisplayCandidate(_ item: CameraVendorGalleryItem) -> Bool {
    let label = normalized(item.formatLabel)
    if ["JPG", "JPEG", "HEIF", "HEIC", "HIF"].contains(label) {
      return true
    }
    if !item.formatHints.isDisjoint(with: [.jpg, .heif, .extendedStillCandidate]) {
      return true
    }
    let filename = item.filename.uppercased()
    return [".JPG", ".JPEG", ".HEIC", ".HEIF", ".HIF"].contains { filename.hasSuffix($0) }
  }

  private static func isRawCandidate(_ item: CameraVendorGalleryItem) -> Bool {
    let label = normalized(item.formatLabel)
    if label == "RAW" || label == "RAF" || item.formatHints.contains(.raw) {
      return true
    }
    let filename = item.filename.uppercased()
    return filename.hasSuffix(".RAW") || filename.hasSuffix(".RAF")
  }

  private static func isVideoCandidate(_ item: CameraVendorGalleryItem) -> Bool {
    let label = normalized(item.formatLabel)
    if ["VIDEO", "MOV", "MP4"].contains(label) || item.formatHints.contains(.video) {
      return true
    }
    let filename = item.filename.uppercased()
    return filename.hasSuffix(".MOV") || filename.hasSuffix(".MP4")
  }

  private static func ambiguousExtendedStillItems(
    _ items: [CameraVendorGalleryItem]
  ) -> [NativeGalleryHDPreviewItem] {
    let ambiguous = items
      .filter(isAmbiguousExtendedStillPlaceholder)
      .sorted { $0.handle > $1.handle }
    guard !ambiguous.isEmpty else { return [] }
    let byHandle = Dictionary(uniqueKeysWithValues: ambiguous.map { ($0.handle, $0) })
    var usedHandles = Set<Int>()
    var result: [NativeGalleryHDPreviewItem] = []
    for item in ambiguous {
      guard usedHandles.insert(item.handle).inserted else { continue }
      let rawSidecar = byHandle[item.handle - 1].map(asAmbiguousRawCandidate)
      if let rawSidecar {
        usedHandles.insert(rawSidecar.handle)
      }
      result.append(NativeGalleryHDPreviewItem(
        displayItem: asAmbiguousPreviewCandidate(item),
        rawSidecar: rawSidecar
      ))
    }
    return result
  }

  private static func isAmbiguousExtendedStillPlaceholder(
    _ item: CameraVendorGalleryItem
  ) -> Bool {
    normalized(item.formatLabel).isEmpty &&
      item.formatHints.contains(.extendedStillCandidate)
  }

  private static func asAmbiguousPreviewCandidate(
    _ item: CameraVendorGalleryItem
  ) -> CameraVendorGalleryItem {
    replacingFormatHints(of: item, with: [.heif])
  }

  private static func asAmbiguousRawCandidate(
    _ item: CameraVendorGalleryItem
  ) -> CameraVendorGalleryItem {
    replacingFormatHints(of: item, with: [.raw])
  }

  private static func replacingFormatHints(
    of item: CameraVendorGalleryItem,
    with hints: Set<CameraVendorGalleryFormatHint>
  ) -> CameraVendorGalleryItem {
    CameraVendorGalleryItem(
      handle: item.handle,
      filename: item.filename,
      formatLabel: item.formatLabel,
      captureDate: item.captureDate,
      byteSizeText: item.byteSizeText,
      compressedSize: item.compressedSize,
      orientation: item.orientation,
      formatHints: hints,
      thumbnailData: item.thumbnailData
    )
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private static func filenameStem(_ filename: String) -> String {
    let normalizedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalizedFilename.isEmpty, !normalizedFilename.hasPrefix("0X") else { return "" }
    return (normalizedFilename as NSString).deletingPathExtension
  }

  private static func orderedUnique(_ handles: [Int]) -> [Int] {
    var seen = Set<Int>()
    return handles.filter { seen.insert($0).inserted }
  }
}
