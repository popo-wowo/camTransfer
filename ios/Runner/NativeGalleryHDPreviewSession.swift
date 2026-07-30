import Foundation

enum NativeGalleryBrowseMode {
  case thumbnail
  case highDefinition
}

enum NativeGalleryHDChromePolicy {
  static let usesGalleryBackground = true
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

struct NativeGalleryHDPreviewSection: Equatable {
  let day: Date?
  let title: String
  let orderedRepresentedHandles: [Int]
  let items: [NativeGalleryHDPreviewItem]
}

struct NativeGalleryHDPreviewSnapshot: Equatable {
  let sections: [NativeGalleryHDPreviewSection]

  var items: [NativeGalleryHDPreviewItem] {
    sections.flatMap(\.items)
  }

  var sectionDisplayHandles: [[Int]] {
    sections.map { $0.items.map(\.displayItem.handle) }
  }

  var displayHandles: [Int] {
    items.map(\.displayItem.handle)
  }

  var orderedRepresentedHandles: [Int] {
    sections.flatMap(\.orderedRepresentedHandles)
  }

  var loadableDisplayHandles: [Int] {
    items.compactMap { item in
      NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
        item: item.displayItem,
        hasPreviewImage: false
      ) ? item.displayItem.handle : nil
    }
  }

  var allRepresentedHandles: Set<Int> {
    Set(items.flatMap { item in
      [item.displayItem.handle] + (item.rawSidecar.map { [$0.handle] } ?? [])
    })
  }

  var allDownloadHandles: Set<Int> {
    allRepresentedHandles
  }

  func item(at indexPath: IndexPath) -> NativeGalleryHDPreviewItem? {
    guard sections.indices.contains(indexPath.section),
          sections[indexPath.section].items.indices.contains(indexPath.item) else {
      return nil
    }
    return sections[indexPath.section].items[indexPath.item]
  }

  func indexPath(forDisplayHandle handle: Int) -> IndexPath? {
    for (sectionIndex, section) in sections.enumerated() {
      if let itemIndex = section.items.firstIndex(where: { $0.displayItem.handle == handle }) {
        return IndexPath(item: itemIndex, section: sectionIndex)
      }
    }
    return nil
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
      sessionHandles: Set(snapshot.loadableDisplayHandles),
      loadedHandles: loadedHandles
    ) + snapshot.displayHandles.count - snapshot.loadableDisplayHandles.count
  }

  var totalCount: Int {
    snapshot.items.count
  }
}

enum NativeGalleryHDDownloadRequestPolicy {
  static func requests(
    displayItems: [CameraVendorGalleryItem],
    rawHandles: [Int],
    preferCompressedDisplay: Bool
  ) -> [CameraSessionQueuedDownload] {
    var seen = Set<Int>()
    var result: [CameraSessionQueuedDownload] = []

    for item in displayItems where seen.insert(item.handle).inserted {
      guard let requestHandle = UInt32(exactly: item.handle) else { continue }
      result.append(CameraSessionQueuedDownload(
        handle: requestHandle,
        mode: isRaw(item) || !preferCompressedDisplay ? .original : .compressed
      ))
    }
    for handle in rawHandles where seen.insert(handle).inserted {
      guard let requestHandle = UInt32(exactly: handle) else { continue }
      result.append(CameraSessionQueuedDownload(handle: requestHandle, mode: .original))
    }
    return result
  }

  static func isRaw(_ item: CameraVendorGalleryItem) -> Bool {
    let label = item.formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let filename = item.filename.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return label == "RAW" ||
      label == "RAF" ||
      item.formatHints.contains(.raw) ||
      filename.hasSuffix(".RAW") ||
      filename.hasSuffix(".RAF")
  }
}

enum NativeGalleryHDPreviewSessionPolicy {
  static func snapshot(
    sections: [NativeGalleryDaySection]
  ) -> NativeGalleryHDPreviewSnapshot {
    NativeGalleryHDPreviewSnapshot(
      sections: sections.map { section in
        NativeGalleryHDPreviewSection(
          day: section.day,
          title: section.title,
          orderedRepresentedHandles: section.items.map(\.handle),
          items: previewItems(from: section.items)
        )
      }
    )
  }

  private static func previewItems(
    from sectionItems: [CameraVendorGalleryItem]
  ) -> [NativeGalleryHDPreviewItem] {
    let indexByHandle = Dictionary(
      uniqueKeysWithValues: sectionItems.enumerated().map { ($0.element.handle, $0.offset) }
    )
    let ambiguousItems = ambiguousExtendedStillItems(sectionItems)
    var representedHandles = Set<Int>()
    for item in ambiguousItems {
      representedHandles.insert(item.displayItem.handle)
      if let rawSidecar = item.rawSidecar {
        representedHandles.insert(rawSidecar.handle)
      }
    }

    let remaining = sectionItems.filter { !representedHandles.contains($0.handle) }
    let rawCandidates = remaining.filter(isRawCandidate)
    var usedRawHandles = Set<Int>()
    var cards = ambiguousItems

    for displayItem in remaining where isDisplayCandidate(displayItem) {
      let sidecar = rawSidecar(
        for: displayItem,
        candidates: rawCandidates,
        excluding: usedRawHandles
      )
      if let sidecar {
        usedRawHandles.insert(sidecar.handle)
        representedHandles.insert(sidecar.handle)
      }
      representedHandles.insert(displayItem.handle)
      cards.append(NativeGalleryHDPreviewItem(
        displayItem: displayItem,
        rawSidecar: sidecar
      ))
    }

    for item in sectionItems where !representedHandles.contains(item.handle) {
      representedHandles.insert(item.handle)
      cards.append(NativeGalleryHDPreviewItem(displayItem: item, rawSidecar: nil))
    }

    return cards.sorted { left, right in
      let leftIndex = indexByHandle[left.displayItem.handle] ?? Int.max
      let rightIndex = indexByHandle[right.displayItem.handle] ?? Int.max
      return leftIndex < rightIndex
    }
  }

  static func priorityWindow(
    orderedHandles: [Int],
    visibleHandles: [Int],
    limit: Int = 30
  ) -> [Int] {
    let boundedLimit = max(1, limit)
    let ordered = orderedUnique(orderedHandles)
    let visibleSet = Set(visibleHandles)
    let visible = ordered.filter { visibleSet.contains($0) }
    guard !visible.isEmpty else {
      return Array(ordered.prefix(boundedLimit))
    }

    let indexByHandle = Dictionary(
      uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) }
    )
    let visibleIndices = visible.compactMap { indexByHandle[$0] }
    guard let firstVisibleIndex = visibleIndices.min(),
          let lastVisibleIndex = visibleIndices.max() else { return [] }

    var result = Array(visible.prefix(boundedLimit))
    var nextBelow = lastVisibleIndex + 1
    while result.count < boundedLimit, nextBelow < ordered.count {
      result.append(ordered[nextBelow])
      nextBelow += 1
    }

    var nextAbove = firstVisibleIndex - 1
    while result.count < boundedLimit, nextAbove >= 0 {
      result.append(ordered[nextAbove])
      nextAbove -= 1
    }
    return orderedUnique(result)
  }

  static func loadedCount(sessionHandles: Set<Int>, loadedHandles: Set<Int>) -> Int {
    sessionHandles.intersection(loadedHandles).count
  }

  private static func rawSidecar(
    for displayItem: CameraVendorGalleryItem,
    candidates: [CameraVendorGalleryItem],
    excluding usedHandles: Set<Int>
  ) -> CameraVendorGalleryItem? {
    let displayStem = filenameStem(displayItem.filename)
    guard !displayStem.isEmpty else { return nil }
    return candidates.first {
      !usedHandles.contains($0.handle) && filenameStem($0.filename) == displayStem
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
