import Foundation

enum NativeGalleryBrowseMode {
  case thumbnail
  case highDefinition
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

enum NativeGalleryHDPreviewSessionPolicy {
  static func availableDates(
    items: [CameraVendorGalleryItem],
    calendar: Calendar = .current
  ) -> [Date] {
    let dates = items.compactMap { item -> Date? in
      guard isDisplayCandidate(item),
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
    let rawCandidates = dayItems.filter(isRawCandidate)
    var usedRawHandles = Set<Int>()

    let previewItems = dayItems.filter(isDisplayCandidate).map { displayItem in
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
      items: previewItems
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
    if !item.formatHints.isDisjoint(with: [.jpg, .heif]) {
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
