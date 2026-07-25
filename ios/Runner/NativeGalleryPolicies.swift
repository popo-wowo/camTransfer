import Foundation
import UIKit

enum NativeGalleryAndroidParityChromePolicy {
  static let toolRowHeight: CGFloat = 42
  static let toolSurfaceCount = 3
  static let usesSeparateModeRow = false

  static func showsFilterSurface(mode _: NativeGalleryBrowseMode) -> Bool {
    true
  }

  static func canExpandFilters(mode: NativeGalleryBrowseMode) -> Bool {
    mode == .thumbnail
  }
}

enum NativePhotoPreviewRotationPolicy {
  static func nextManualRotationDegrees(_ currentDegrees: Int) -> Int {
    normalizedDegrees(currentDegrees + 90)
  }

  static func previousManualRotationDegrees(_ currentDegrees: Int) -> Int {
    normalizedDegrees(currentDegrees - 90)
  }

  static func normalizedDegrees(_ degrees: Int) -> Int {
    ((degrees % 360) + 360) % 360
  }

  static func autoRotationDegrees(
    objectOrientation: Int?,
    decodedWidth: Int,
    decodedHeight: Int,
    imageData: Data?
  ) -> Int {
    if let imageData,
       let exifDegrees = exifRotationDegrees(imageData) {
      if rotationAlreadyApplied(exifDegrees, decodedWidth: decodedWidth, decodedHeight: decodedHeight) {
        return 0
      }
      return exifDegrees
    }
    if let objectOrientation {
      if let metadataDegrees = cameraVendorOrientationRotationDegrees(objectOrientation) {
        if rotationAlreadyApplied(metadataDegrees, decodedWidth: decodedWidth, decodedHeight: decodedHeight) {
          return 0
        }
        return metadataDegrees
      }
    }
    return 0
  }

  private static func rotationAlreadyApplied(_ degrees: Int, decodedWidth: Int, decodedHeight: Int) -> Bool {
    guard decodedWidth > 0, decodedHeight > 0 else { return false }
    return (degrees == 90 || degrees == 270) && decodedHeight > decodedWidth
  }

  private static func cameraVendorOrientationRotationDegrees(_ orientation: Int) -> Int? {
    switch orientation {
    case 2:
      return 90
    case 3:
      return 180
    case 4:
      return 270
    default:
      return nil
    }
  }

  private static func exifRotationDegrees(_ imageData: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32 else {
      return nil
    }
    switch rawOrientation {
    case 6, 7:
      return 90
    case 3, 4:
      return 180
    case 5, 8:
      return 270
    default:
      return nil
    }
  }

  static func displaySize(for size: CGSize, manualRotationDegrees: Int) -> CGSize {
    let degrees = normalizedDegrees(manualRotationDegrees)
    if degrees == 90 || degrees == 270 {
      return CGSize(width: size.height, height: size.width)
    }
    return size
  }
}

enum NativeGalleryOrientationRefreshPolicy {
  static func handlesNeedingThumbnailReDecode(
    existingItems: [CameraVendorGalleryItem],
    resolvedItems: [CameraVendorGalleryItem]
  ) -> Set<Int> {
    let existingByHandle = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.handle, $0) })
    return Set(resolvedItems.compactMap { resolvedItem in
      guard let existingItem = existingByHandle[resolvedItem.handle],
            existingItem.orientation != (resolvedItem.orientation ?? existingItem.orientation) else {
        return nil
      }
      return resolvedItem.handle
    })
  }
}

enum NativePhotoPreviewOrientationRefreshPolicy {
  static func shouldRerender(
    previousObjectOrientation: Int?,
    updatedObjectOrientation: Int?,
    hasLoadedImageData: Bool
  ) -> Bool {
    hasLoadedImageData && updatedObjectOrientation != nil && previousObjectOrientation != updatedObjectOrientation
  }
}

enum NativeGalleryPreviewImageLoadPolicy {
  static func shouldRequestPreviewImage(item: CameraVendorGalleryItem, hasPreviewImage: Bool) -> Bool {
    if hasPreviewImage { return false }
    let label = item.formatLabel.uppercased()
    let filename = item.filename.uppercased()
    return label == "JPG" ||
      label == "JPEG" ||
      label == "HEIF" ||
      filename.hasSuffix(".JPG") ||
      filename.hasSuffix(".JPEG") ||
      filename.hasSuffix(".HEIC") ||
      filename.hasSuffix(".HEIF") ||
      filename.hasSuffix(".HIF")
  }
}

enum NativePhotoPreviewImageSourcePolicy {
  static func shouldFetchPreviewImage(
    item: CameraVendorGalleryItem,
    hasPreviewImage: Bool,
    hasLoadedPreviewData: Bool
  ) -> Bool {
    NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: item,
      hasPreviewImage: hasPreviewImage || hasLoadedPreviewData
    )
  }
}

enum NativePhotoPreviewInitialImagePolicy {
  static func initialImage(item: CameraVendorGalleryItem, cachedThumbnailImage: UIImage?) -> UIImage? {
    if let data = item.thumbnailData,
       let image = CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: item.orientation) {
      return image
    }
    return cachedThumbnailImage
  }
}

enum NativePhotoPreviewImageRenderer {
  static func rendered(image: UIImage, manualRotationDegrees: Int) -> UIImage {
    let normalized = normalized(image)
    let degrees = NativePhotoPreviewRotationPolicy.normalizedDegrees(manualRotationDegrees)
    guard degrees != 0 else { return normalized }

    let targetSize = NativePhotoPreviewRotationPolicy.displaySize(
      for: normalized.size,
      manualRotationDegrees: degrees
    )
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = normalized.scale
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
    return renderer.image { context in
      let cgContext = context.cgContext
      cgContext.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
      cgContext.rotate(by: CGFloat(degrees) * .pi / 180)
      normalized.draw(
        in: CGRect(
          x: -normalized.size.width / 2,
          y: -normalized.size.height / 2,
          width: normalized.size.width,
          height: normalized.size.height
        )
      )
    }
  }

  private static func normalized(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else { return image }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = image.scale
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }
}

enum NativeLogTextViewPolicy {
  static let maxDisplayedCharacters = 20_000

  static func appending(_ message: String, to existingText: String) -> String {
    let combined = existingText.isEmpty ? message : "\(existingText)\n\(message)"
    guard combined.count > maxDisplayedCharacters else {
      return combined
    }
    return "...\n" + String(combined.suffix(maxDisplayedCharacters))
  }

  static func shouldRenderLiveText(applicationState: UIApplication.State, hasWindow: Bool) -> Bool {
    applicationState == .active && hasWindow
  }

  static func shouldRenderLiveText(
    applicationState: UIApplication.State,
    hasWindow: Bool,
    visibleHeight: CGFloat
  ) -> Bool {
    shouldRenderLiveText(applicationState: applicationState, hasWindow: hasWindow)
      && visibleHeight > 1
  }
}

enum NativeCameraAdapterRegistry {
  static let defaultAdapter = FujifilmCameraAdapter(profile: .xt5Current)

  static var defaultAdapterDescriptor: CameraAdapterDescriptor {
    defaultAdapter.descriptor
  }
}

enum NativeGalleryGridLayoutPolicy {
  static let minColumnCount = 2
  static let maxColumnCount = 6
  static let androidGridSpacing: CGFloat = 2

  static func columnCount(forCollectionWidth width: CGFloat) -> Int {
    width >= 700 ? 4 : 3
  }

  static func clampedColumnCount(_ count: Int) -> Int {
    max(minColumnCount, min(maxColumnCount, count))
  }

  static func itemSide(
    forCollectionWidth width: CGFloat,
    horizontalInset: CGFloat,
    interItemSpacing: CGFloat,
    columns: Int? = nil
  ) -> CGFloat {
    let columnCount = CGFloat(columns ?? self.columnCount(forCollectionWidth: width))
    let availableWidth = width - (horizontalInset * 2) - (interItemSpacing * (columnCount - 1))
    return floor(availableWidth / columnCount)
  }
}

enum NativeGalleryChromeCopy {
  static let title = "CAMERA GALLERY"
  static let filterTitle = "筛选"
  static let defaultFilterSummary = "全部日期 · 全部格式 · 最新优先"
  static let sortOptionTitles = ["最新", "最早", "未下载"]

  static func loadingText(activeDownloadCount: Int, isLoading: Bool, isTransferring: Bool) -> String? {
    if activeDownloadCount > 0 { return "下载中 \(activeDownloadCount)" }
    if isTransferring { return "正在下载" }
    if isLoading { return "正在读取相机照片" }
    return nil
  }
}

enum NativeGalleryExitCopy {
  static let title = "确认断开相机连接？"
  static let message = "当前会保持在照片筛选页面，并且不会断开相机通讯。只有确认断开后，才会返回首页并断开相机连接。"
  static let confirmTitle = "确认断开"
  static let cancelTitle = "继续停留"
}

enum NativeGalleryExitPolicy {
  static func shouldConfirmBeforeLeaving(hasActiveCameraCommunication: Bool) -> Bool {
    hasActiveCameraCommunication
  }

  static func shouldTerminateCameraCommunication(
    hasActiveCameraCommunication: Bool,
    userConfirmedExit: Bool
  ) -> Bool {
    hasActiveCameraCommunication && userConfirmedExit
  }
}

enum NativeGalleryPresentationLifecyclePolicy {

  static func shouldDisableIdleTimer(
    isLoading: Bool,
    isDownloading: Bool,
    hasActiveCameraCommunication: Bool
  ) -> Bool {
    isLoading || isDownloading || hasActiveCameraCommunication
  }

  static func shouldPauseThumbnailRequests(
    applicationState: UIApplication.State,
    hasActiveCameraCommunication: Bool
  ) -> Bool {
    applicationState == .background && hasActiveCameraCommunication
  }
}

enum NativeGalleryRuntimeOwnershipPolicy {
  static func shouldReleaseRuntimeForGalleryTeardown(
    hasDurableActiveDownloadSession: Bool
  ) -> Bool {
    !hasDurableActiveDownloadSession
  }
}

enum NativeGalleryMainLoadLifecyclePolicy {
  static func shouldTerminateCameraCommunication(
    isLeavingGallery: Bool,
    hasActiveGalleryLoadTask: Bool
  ) -> Bool {
    isLeavingGallery && hasActiveGalleryLoadTask
  }
}

enum NativeDownloadCenterChrome {
  static let title = "DOWNLOADS"
  static let clearRecordsTitle = "清理记录"
  static let emptyTitle = "下载中心为空"
  static let terminateAlertTitle = "终止当前下载？"
  static let terminateAlertMessage = "返回后会终止当前下载，未完成的照片不会继续下载。"
  static let terminateAlertConfirmTitle = "终止下载"
  static let terminateAlertCancelTitle = "继续下载"
  static let gridColumnCount = 3
  static let gridInsets = UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12)
  static let gridHorizontalSpacing: CGFloat = 8
  static let gridVerticalSpacing: CGFloat = 12

  static func summary(totalCount: Int, doneCount: Int, activeCount: Int) -> String {
    "\(totalCount) 张 · 已保存 \(doneCount) · 进行中 \(activeCount)"
  }
}

enum NativeGalleryTopChromePolicy {
  static let shouldHideSystemNavigationBar = true
  static let horizontalInset: CGFloat = 18
  static let topInset: CGFloat = 0
  static let bottomInset: CGFloat = 0
  static let actionRowHeight: CGFloat = 42
  static let actionSpacing: CGFloat = 8
  static let statusSpacing: CGFloat = 0
  static let cornerRadius: CGFloat = 24
}

enum NativeGalleryAndroidParityLayoutPolicy {
  static let filterToGridSpacing: CGFloat = 2
  static let filterHeaderHeight: CGFloat = 42
  static let filterTopSpacing: CGFloat = 6
  static let shouldShowPinchHintBubble = false
  static let bottomBarHeight: CGFloat = 52
  static let bottomBarBottomInset: CGFloat = 10
}

enum NativeGalleryDateFilter: Equatable {
  case all
  case today
  case specificDay(Date)
  case range(from: Date, to: Date)
}

enum NativeGalleryFormatFilter: Hashable {
  case all
  case jpg
  case heif
  case raw
  case video
}

enum NativeGallerySortMode: Equatable {
  case newest
  case oldest
  case notDownloaded
}

struct NativeGalleryFilterState: Equatable {
  var date: NativeGalleryDateFilter
  var format: NativeGalleryFormatFilter
  var sort: NativeGallerySortMode

  var isAllFormats: Bool {
    format == .all
  }

  init(
    date: NativeGalleryDateFilter = .all,
    format: NativeGalleryFormatFilter = .all,
    sort: NativeGallerySortMode = .newest
  ) {
    self.date = date
    self.format = format
    self.sort = sort
  }
}

extension NativeGalleryFilterState {
  var catalogIntent: CameraGalleryFilterIntent {
    let dateIntent: CameraGalleryDateIntent
    switch date {
    case .all:
      dateIntent = .all
    case .today:
      dateIntent = .today
    case .specificDay(let day):
      dateIntent = .specificDay(day)
    case .range(let from, let to):
      dateIntent = .range(from: from, to: to)
    }

    let formatIntent: CameraGalleryFormatIntent
    switch format {
    case .all: formatIntent = .all
    case .jpg: formatIntent = .jpg
    case .heif: formatIntent = .heif
    case .raw: formatIntent = .raw
    case .video: formatIntent = .video
    }

    let sortIntent: CameraGallerySortIntent
    let downloadStatus: CameraGalleryDownloadStatusIntent
    switch sort {
    case .newest:
      sortIntent = .newest
      downloadStatus = .all
    case .oldest:
      sortIntent = .oldest
      downloadStatus = .all
    case .notDownloaded:
      sortIntent = .notDownloaded
      downloadStatus = .notDownloaded
    }

    return CameraGalleryFilterIntent(
      date: dateIntent,
      format: formatIntent,
      sort: sortIntent,
      downloadStatus: downloadStatus
    )
  }

}

enum NativeTopChromeIconButtonStylePolicy {
  static let sideLength: CGFloat = 42
  static let usesFilledBackground = false
  static let usesBorder = false
  static let usesShadow = false
}

enum NativeGalleryBackgroundMetadataUIRefreshPolicy {
  static let shouldApplyPublishedAndroidBatchImmediately = true

  static func canRefreshVisibleItemsOnly(filterState: NativeGalleryFilterState) -> Bool {
    filterState.date == .all &&
      filterState.isAllFormats &&
      filterState.sort == .newest
  }

  static func requiresCollectionReload(
    existingItems: [CameraVendorGalleryItem],
    resolvedItems: [CameraVendorGalleryItem],
    filterState: NativeGalleryFilterState
  ) -> Bool {
    guard canRefreshVisibleItemsOnly(filterState: filterState) else {
      return true
    }
    let existingHandles = Set(existingItems.map(\.handle))
    return resolvedItems.contains { !existingHandles.contains($0.handle) }
  }
}

enum NativeGalleryUIInvalidationPolicy {
  static func changedHandles(before: Set<Int>, after: Set<Int>) -> Set<Int> {
    before.symmetricDifference(after)
  }
}

enum NativeGallerySelectionRefreshPolicy {
  static let shouldReconfigureImageDuringSelectionChange = false
  static let shouldPauseThumbnailLoadingDuringSelectionGesture = true
}

enum NativeGalleryInteractionPriorityPolicy {
  static let shouldCancelThumbnailQueueBeforeExitTap = true
  static let shouldSuppressThumbnailRetryAfterInteractionCancel = true
  static let thumbnailResumeDelayAfterSelectionSeconds: TimeInterval = 0.2
}

enum NativeGalleryThumbnailFailurePolicy {
  static func shouldRememberFailure(_ error: Error) -> Bool {
    _ = error
    // A thumbnail is a best-effort catalog asset.  A later foreground/viewport
    // generation must be allowed to retry transient PTP and decode failures.
    // Permanent suppression made one short transport hiccup leave an item blank.
    return false
  }

  static func shouldPublishResult(afterCancellation isCancelled: Bool) -> Bool {
    guard !isCancelled else {
      return false
    }
    return true
  }
}

enum NativeGalleryThumbnailLoadingPolicy {
  static func shouldStartCatalogWork(
    runtimeCanAcceptCatalogCommands: Bool,
    isDownloading: Bool
  ) -> Bool {
    runtimeCanAcceptCatalogCommands &&
      (!isDownloading || !CameraVendorThumbnailLoadPolicy.shouldPauseWhileDownloading)
  }
}

enum NativeGalleryFilterPerformancePolicy {
  static let shouldBuildCaptureDateIndex = true
  static let shouldDisableReloadAnimation = true
}

struct NativeGalleryCaptureDateIndex {
  private let datesByHandle: [Int: Date]

  init(items: [CameraVendorGalleryItem]) {
    var dates: [Int: Date] = [:]
    for item in items {
      if let date = NativeGalleryFilterPolicy.parsedCaptureDate(item.captureDate) {
        dates[item.handle] = date
      }
    }
    self.datesByHandle = dates
  }

  func date(for item: CameraVendorGalleryItem) -> Date? {
    datesByHandle[item.handle]
  }
}

enum NativeGalleryFilterPolicy {
  static func filteredItems(
    _ items: [CameraVendorGalleryItem],
    state: NativeGalleryFilterState,
    downloadedHandles: Set<Int> = [],
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [CameraVendorGalleryItem] {
    let captureDateIndex = NativeGalleryFilterPerformancePolicy.shouldBuildCaptureDateIndex
      ? NativeGalleryCaptureDateIndex(items: items)
      : nil
    func captureDate(for item: CameraVendorGalleryItem) -> Date? {
      if let captureDateIndex {
        return captureDateIndex.date(for: item)
      }
      return parsedCaptureDate(item.captureDate)
    }

    let filtered = items.filter { item in
      matchesFormat(item, format: state.format) &&
        matchesDate(captureDate(for: item), date: state.date, now: now, calendar: calendar)
    }

    return filtered.sorted { left, right in
      let leftDate = captureDate(for: left)
      let rightDate = captureDate(for: right)
      switch state.sort {
      case .newest:
        return sortNewest(left, right, leftDate: leftDate, rightDate: rightDate)
      case .oldest:
        return sortOldest(left, right, leftDate: leftDate, rightDate: rightDate)
      case .notDownloaded:
        let leftDownloaded = downloadedHandles.contains(left.handle)
        let rightDownloaded = downloadedHandles.contains(right.handle)
        if leftDownloaded != rightDownloaded {
          return !leftDownloaded && rightDownloaded
        }
        return sortNewest(left, right, leftDate: leftDate, rightDate: rightDate)
      }
    }
  }

  private static func matchesFormat(_ item: CameraVendorGalleryItem, format: NativeGalleryFormatFilter) -> Bool {
    if format == .all {
      return true
    }
    return resolvedFormat(from: item.formatLabel) == format
  }

  private static func resolvedFormat(from formatLabel: String) -> NativeGalleryFormatFilter? {
    let normalized = formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty, !normalized.hasPrefix("0X") else { return nil }
    switch normalized {
    case "JPG", "JPEG":
      return .jpg
    case "HEIF", "HEIC", "HIF":
      return .heif
    case "RAW", "RAF":
      return .raw
    case "VIDEO", "MOV", "MP4":
      return .video
    default:
      return nil
    }
  }

  private static func matchesDate(
    _ captureDate: Date?,
    date: NativeGalleryDateFilter,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard date != .all else { return true }
    guard let captureDate else { return false }
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

  static func parsedCaptureDate(_ text: String) -> Date? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    for formatter in captureDateFormatters {
      if let date = formatter.date(from: text) {
        return date
      }
    }
    return nil
  }

  private static let captureDateFormatters: [DateFormatter] = [
    "yyyy:MM:dd HH:mm:ss",
    "yyyyMMdd",
    "yyyyMMdd'T'HHmmss",
    "yyyyMMdd'T'HHmmss.SSS",
  ].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    formatter.isLenient = false
    return formatter
  }

  private static func sortNewest(
    _ left: CameraVendorGalleryItem,
    _ right: CameraVendorGalleryItem,
    leftDate: Date?,
    rightDate: Date?
  ) -> Bool {
    if leftDate != rightDate {
      return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
    }
    return left.handle > right.handle
  }

  private static func sortOldest(
    _ left: CameraVendorGalleryItem,
    _ right: CameraVendorGalleryItem,
    leftDate: Date?,
    rightDate: Date?
  ) -> Bool {
    if leftDate != rightDate {
      return (leftDate ?? .distantFuture) < (rightDate ?? .distantFuture)
    }
    return left.handle < right.handle
  }

}

enum NativeGalleryCameraCatalogProjection {
  static func items(
    _ catalogItems: [CameraVendorGalleryItem],
    sort: NativeGallerySortMode,
    downloadedHandles: Set<Int>
  ) -> [CameraVendorGalleryItem] {
    switch sort {
    case .newest:
      return catalogItems
    case .oldest:
      return Array(catalogItems.reversed())
    case .notDownloaded:
      return catalogItems.filter { !downloadedHandles.contains($0.handle) } +
        catalogItems.filter { downloadedHandles.contains($0.handle) }
    }
  }
}

struct NativeGalleryDaySection: Equatable {
  let day: Date?
  let title: String
  let items: [CameraVendorGalleryItem]
}

enum NativeGallerySectionPolicy {
  static func shouldShowDateSections(_ items: [CameraVendorGalleryItem]) -> Bool {
    items.contains { NativeGalleryFilterPolicy.parsedCaptureDate($0.captureDate) != nil }
  }

  static func sections(
    from items: [CameraVendorGalleryItem],
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [NativeGalleryDaySection] {
    guard !items.isEmpty else { return [] }
    guard shouldShowDateSections(items) else {
      return [NativeGalleryDaySection(day: nil, title: "未知日期 \(items.count) 张", items: items)]
    }

    var orderedDays: [Date] = []
    var filesByDay: [Date: [CameraVendorGalleryItem]] = [:]
    var unknownItems: [CameraVendorGalleryItem] = []
    for item in items {
      guard let captureDate = NativeGalleryFilterPolicy.parsedCaptureDate(item.captureDate) else {
        unknownItems.append(item)
        continue
      }
      let day = calendar.startOfDay(for: captureDate)
      if filesByDay[day] == nil {
        orderedDays.append(day)
        filesByDay[day] = []
      }
      filesByDay[day]?.append(item)
    }

    var sections = orderedDays.compactMap { day -> NativeGalleryDaySection? in
      guard let dayItems = filesByDay[day], !dayItems.isEmpty else { return nil }
      return NativeGalleryDaySection(
        day: day,
        title: "\(dayLabel(day, now: now, calendar: calendar)) \(dayItems.count) 张",
        items: dayItems
      )
    }
    if !unknownItems.isEmpty {
      sections.append(NativeGalleryDaySection(day: nil, title: "未知日期 \(unknownItems.count) 张", items: unknownItems))
    }
    return sections
  }

  private static func dayLabel(_ day: Date, now: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.month, .day], from: day)
    let month = components.month ?? 0
    let dayValue = components.day ?? 0
    if calendar.isDate(day, inSameDayAs: now) {
      return "今天 \(month)月\(dayValue)日"
    }
    return "\(month)月\(dayValue)日"
  }
}

enum NativeGalleryThumbnailRequestWindowPolicy {
  private static let prefetchRowsBefore = 1
  private static let prefetchRowsAfter = 2

  static func handlesToRequest(
    orderedHandles: [Int],
    visibleHandles: [Int],
    columnCount: Int
  ) -> [Int] {
    guard !orderedHandles.isEmpty, !visibleHandles.isEmpty else { return [] }
    let indexByHandle = Dictionary(uniqueKeysWithValues: orderedHandles.enumerated().map { ($0.element, $0.offset) })
    let visibleIndexes = visibleHandles.compactMap { indexByHandle[$0] }
    guard let minIndex = visibleIndexes.min(), let maxIndex = visibleIndexes.max() else { return [] }
    let safeColumnCount = max(columnCount, 1)
    let visibleOrdered = visibleHandles.filter { indexByHandle[$0] != nil }.reduce(into: [Int]()) { result, handle in
      if !result.contains(handle) { result.append(handle) }
    }.sorted {
      (indexByHandle[$0] ?? Int.max) < (indexByHandle[$1] ?? Int.max)
    }
    let visibleSet = Set(visibleOrdered)
    let contiguousWindowLimit = visibleOrdered.count + safeColumnCount * (prefetchRowsBefore + prefetchRowsAfter)
    let start = max(0, minIndex - safeColumnCount * prefetchRowsBefore)
    let end = min(orderedHandles.count - 1, maxIndex + safeColumnCount * prefetchRowsAfter)
    guard end - start + 1 <= contiguousWindowLimit else {
      var nearbyIndexes = Set<Int>()
      for index in visibleIndexes {
        let localStart = max(0, index - safeColumnCount * prefetchRowsBefore)
        let localEnd = min(orderedHandles.count - 1, index + safeColumnCount * prefetchRowsAfter)
        nearbyIndexes.formUnion(localStart...localEnd)
      }
      let nearby = nearbyIndexes
        .sorted()
        .map { orderedHandles[$0] }
        .filter { !visibleSet.contains($0) }
      return visibleOrdered + Array(nearby.prefix(contiguousWindowLimit - visibleOrdered.count))
    }
    let nearby = orderedHandles[start...end].filter { !visibleSet.contains($0) }
    return visibleOrdered + nearby
  }
}

enum NativeGalleryThumbnailRetryPolicy {
  static func shouldContinueLoadingAfterBatch(requestedCount: Int, loadedCount: Int) -> Bool {
    requestedCount > 0 && loadedCount > 0
  }
}

enum NativeGalleryThumbnailDecodeCachePolicy {
  static func shouldUseCachedImage(
    thumbnailData: Data?,
    cachedImage: UIImage?
  ) -> Bool {
    thumbnailData != nil && cachedImage != nil
  }
}

enum NativeGalleryCellThumbnailDecodePolicy {
  static let shouldDecodeDataDuringCellConfigure = false
}

enum NativeDownloadCenterThumbnailPolicy {
  static let shouldRehydratePersistedThumbnailData = true

  static func action(
    thumbnailData: Data?,
    cachedImage: UIImage?
  ) -> NativeGalleryVisibleThumbnailAction {
    if thumbnailData != nil && cachedImage != nil {
      return .none
    }
    if shouldRehydratePersistedThumbnailData && thumbnailData != nil {
      return .decodeCachedData
    }
    return .none
  }
}

enum NativeGalleryVisibleThumbnailAction: Equatable {
  case none
  case decodeCachedData
  case fetchFromCamera
}

enum NativeGalleryVisibleThumbnailPolicy {
  static func action(
    thumbnailData: Data?,
    cachedImage: UIImage?,
    hasFailedThumbnailRequest: Bool
  ) -> NativeGalleryVisibleThumbnailAction {
    if NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
      thumbnailData: thumbnailData,
      cachedImage: cachedImage
    ) {
      return .none
    }
    if thumbnailData != nil {
      return .decodeCachedData
    }
    return hasFailedThumbnailRequest ? .none : .fetchFromCamera
  }
}

enum NativeGalleryThumbnailUILogPolicy {
  static func shouldEmitSuccess(totalElapsedMs: Int) -> Bool {
    false
  }

  static func shouldEmitFailure(for error: Error) -> Bool {
    !(error is CancellationError)
  }
}

enum NativeGalleryDownloadDiagnosticLogPolicy {
  static func shouldWriteToFile(_ message: String) -> Bool {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("下载传输完成") &&
      trimmed.contains("transferMs=") &&
      trimmed.contains("speedMBps=") {
      return true
    }
    if trimmed.hasPrefix("[保存] 完成") &&
      trimmed.contains("transferMs=") &&
      trimmed.contains("saveMs=") &&
      trimmed.contains("totalMs=") &&
      trimmed.contains("speedMBps=") {
      return true
    }
    if trimmed.hasPrefix("[下载]") || trimmed.hasPrefix("[保存]") {
      return false
    }
    if trimmed.contains("下载进行中") ||
      trimmed.contains("下载优先模式") ||
      trimmed.contains("优先下载原图") ||
      trimmed.contains("保存队列") ||
      trimmed.contains("下载传输完成") {
      return false
    }
    return true
  }
}

enum NativeGalleryThumbnailSectionRefreshPolicy {
  static let shouldRebuildSectionsAfterThumbnailLoad = false
}

enum NativeGalleryThumbnailResultMergePolicy {
  static func item(
    existingItem: CameraVendorGalleryItem,
    thumbnailData: Data,
    resolvedItem: CameraVendorGalleryItem?
  ) -> CameraVendorGalleryItem {
    var item = resolvedItem.map {
      NativeGalleryMetadataMergePolicy.mergedItem(
        existingItem: existingItem,
        resolvedItem: $0
      )
    } ?? existingItem
    item.thumbnailData = thumbnailData
    return item
  }
}

enum NativeGalleryThumbnailDecodePipeline {
  static func decodedImage(from data: Data, objectOrientation: Int? = nil) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: objectOrientation)
    }.value
  }
}

enum NativeGalleryMetadataMergePolicy {
  static func mergedItemsRestrictingMembership(
    existingItems: [CameraVendorGalleryItem],
    resolvedItems: [CameraVendorGalleryItem]
  ) -> [CameraVendorGalleryItem] {
    let resolvedByHandle = Dictionary(uniqueKeysWithValues: resolvedItems.map { ($0.handle, $0) })
    return existingItems.map { existingItem in
      guard let resolvedItem = resolvedByHandle[existingItem.handle] else { return existingItem }
      return mergedItem(existingItem: existingItem, resolvedItem: resolvedItem)
    }
  }

  static func mergedItemsPreservingExistingOrder(
    existingItems: [CameraVendorGalleryItem],
    resolvedItems: [CameraVendorGalleryItem]
  ) -> [CameraVendorGalleryItem] {
    guard !resolvedItems.isEmpty else { return existingItems }
    let existingItemsByHandle = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.handle, $0) })
    var resolvedItemsByHandle = Dictionary(uniqueKeysWithValues: resolvedItems.map { ($0.handle, $0) })
    var mergedItems = existingItems.map { existingItem -> CameraVendorGalleryItem in
      guard let resolvedItem = resolvedItemsByHandle.removeValue(forKey: existingItem.handle) else {
        return existingItem
      }
      return mergedItem(existingItem: existingItem, resolvedItem: resolvedItem)
    }
    let newResolvedItems = resolvedItems.filter { item in
      existingItemsByHandle[item.handle] == nil
    }
    mergedItems.append(contentsOf: newResolvedItems)
    return mergedItems
  }

  static func mergedItem(
    existingItem: CameraVendorGalleryItem?,
    resolvedItem: CameraVendorGalleryItem
  ) -> CameraVendorGalleryItem {
    guard let existingItem else { return resolvedItem }
    var item = resolvedItem
    item.thumbnailData = existingItem.thumbnailData
    let mergedFormatLabel = resolvedFormatLabel(
      existingFormatLabel: existingItem.formatLabel,
      resolvedFormatLabel: item.formatLabel
    )
    item = CameraVendorGalleryItem(
      handle: item.handle,
      filename: resolvedFilename(
        existingFilename: existingItem.filename,
        resolvedFilename: item.filename
      ),
      formatLabel: mergedFormatLabel,
      captureDate: resolvedCaptureDate(
        existingCaptureDate: existingItem.captureDate,
        resolvedCaptureDate: resolvedItem.captureDate
      ),
      byteSizeText: resolvedByteSizeText(
        existingByteSizeText: existingItem.byteSizeText,
        resolvedByteSizeText: item.byteSizeText
      ),
      orientation: item.orientation ?? existingItem.orientation,
      formatHints: resolvedFormatHints(
        existingItem: existingItem,
        resolvedItem: item,
        mergedFormatLabel: mergedFormatLabel
      ),
      thumbnailData: item.thumbnailData
    )
    return item
  }

  private static func resolvedFilename(
    existingFilename: String,
    resolvedFilename: String
  ) -> String {
    if !isPlaceholderFilename(existingFilename) {
      return existingFilename
    }
    let trimmedResolved = resolvedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedResolved.isEmpty else { return existingFilename }
    return resolvedFilename
  }

  private static func resolvedFormatLabel(
    existingFormatLabel: String,
    resolvedFormatLabel: String
  ) -> String {
    if CameraVendorGalleryFormatResolutionPolicy.isResolvedStillOrVideoFormat(existingFormatLabel) {
      return existingFormatLabel
    }
    if CameraVendorGalleryFormatResolutionPolicy.isResolvedStillOrVideoFormat(resolvedFormatLabel) {
      return resolvedFormatLabel
    }
    return existingFormatLabel
  }

  private static func isPlaceholderFilename(_ filename: String) -> Bool {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    guard trimmed.hasPrefix("0x"), trimmed.count == 10 else { return false }
    return trimmed.dropFirst(2).allSatisfy(\.isHexDigit)
  }

  private static func resolvedByteSizeText(
    existingByteSizeText: String,
    resolvedByteSizeText: String
  ) -> String {
    existingByteSizeText.isEmpty ? resolvedByteSizeText : existingByteSizeText
  }

  private static func resolvedFormatHints(
    existingItem: CameraVendorGalleryItem,
    resolvedItem: CameraVendorGalleryItem,
    mergedFormatLabel: String
  ) -> Set<CameraVendorGalleryFormatHint> {
    if CameraVendorGalleryFormatResolutionPolicy.isResolvedStillOrVideoFormat(mergedFormatLabel) {
      return []
    }
    if resolvedItem.formatHints.isEmpty &&
      !existingItem.formatHints.isEmpty &&
      !CameraVendorGalleryFormatResolutionPolicy.isResolvedStillOrVideoFormat(resolvedItem.formatLabel) {
      return existingItem.formatHints
    }
    return resolvedItem.formatHints
  }

  static func resolvedCaptureDate(existingCaptureDate: String, resolvedCaptureDate: String) -> String {
    let existingDay = captureDayKey(existingCaptureDate)
    let resolvedDay = captureDayKey(resolvedCaptureDate)
    switch (existingDay, resolvedDay) {
    case (nil, _):
      return resolvedCaptureDate
    case (_, nil):
      return existingCaptureDate
    case let (existing?, resolved?) where existing == resolved:
      return resolvedCaptureDate
    default:
      return existingCaptureDate
    }
  }

  private static func captureDayKey(_ captureDate: String) -> String? {
    guard let date = NativeGalleryFilterPolicy.parsedCaptureDate(captureDate) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }
}

enum NativeGalleryFormatDisplayPolicy {
  static func displayLabel(for formatLabel: String) -> String? {
    let trimmed = formatLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let uppercased = trimmed.uppercased()
    guard !uppercased.hasPrefix("0X") else { return nil }
    return trimmed == "Video" ? "MOV" : uppercased
  }

  static func displayLabel(for item: CameraVendorGalleryItem) -> String? {
    if let label = displayLabel(for: item.formatLabel) {
      return label
    }
    return displayLabelForStableFilename(item.filename)
  }

  static func badgeText(for item: CameraVendorGalleryItem) -> String? {
    if let label = displayLabel(for: item) {
      return " \(label) "
    }
    return nil
  }

  static func badgeText(
    for item: CameraVendorGalleryItem,
    viewState: CameraGalleryEntryViewState?
  ) -> String? {
    guard let viewState else {
      return badgeText(for: item)
    }
    return badgeText(for: viewState)
  }

  static func badgeText(for viewState: CameraGalleryEntryViewState) -> String? {
    if let label = displayLabel(for: viewState.summary.format) {
      return " \(label) "
    }
    if let label = displayLabel(for: viewState.details.refinedFormat) {
      return " \(label) "
    }
    return nil
  }

  static func previewSubtitle(
    index: Int,
    total: Int,
    item: CameraVendorGalleryItem,
    viewState: CameraGalleryEntryViewState? = nil
  ) -> String {
    var components = ["\(index + 1) / \(total)"]
    if let viewState {
      if let badge = badgeText(for: viewState)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !badge.isEmpty {
        components.append(badge)
      }
    } else if let label = displayLabel(for: item) {
      components.append(label)
    } else if let badge = badgeText(for: item)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !badge.isEmpty {
      components.append(badge)
    }
    if !item.byteSizeText.isEmpty {
      components.append(item.byteSizeText)
    }
    return components.joined(separator: " · ")
  }

  private static func displayLabelForStableFilename(_ filename: String) -> String? {
    let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("0x") else { return nil }
    switch (trimmed as NSString).pathExtension.uppercased() {
    case "JPG", "JPEG":
      return "JPG"
    case "HEIF", "HEIC", "HIF":
      return "HEIF"
    case "RAW", "RAF":
      return "RAW"
    case "MOV":
      return "MOV"
    case "MP4":
      return "MP4"
    default:
      return nil
    }
  }

  private static func displayLabel(
    for value: CameraGalleryConfirmedValue<CameraGalleryFormat>
  ) -> String? {
    guard case let .confirmed(format) = value else { return nil }
    switch format {
    case .jpg:
      return "JPG"
    case .heif:
      return "HEIF"
    case .raw:
      return "RAW"
    case .video:
      return "MOV"
    }
  }

  private static func displayLabel(
    for value: CameraGalleryConfirmedValue<String>
  ) -> String? {
    guard case let .confirmed(filename) = value else { return nil }
    return displayLabelForStableFilename(filename)
  }
}

enum CameraVendorDownloadHistoryStore {
  private static let storageKey = "camtransfer.downloadHistory.v1"
  private static let recordStorageKey = "camtransfer.downloadHistory.records.v1"

  private struct Record: Codable {
    let handle: Int
    let filename: String
    let formatLabel: String
    let captureDate: String
    let byteSizeText: String
    let orientation: Int?
    let thumbnailData: Data?

    var item: CameraVendorGalleryItem {
      CameraVendorGalleryItem(
        handle: handle,
        filename: filename,
        formatLabel: formatLabel,
        captureDate: captureDate,
        byteSizeText: byteSizeText,
        orientation: orientation,
        thumbnailData: thumbnailData
      )
    }
  }

  static func savedHandles(for cameraID: String) -> Set<Int> {
    let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    return Set(dict[cameraID] ?? []).union(historyItems(for: cameraID).map(\.handle))
  }

  static func markSaved(handle: Int, for cameraID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    var existing = Set(dict[cameraID] ?? [])
    existing.insert(handle)
    dict[cameraID] = Array(existing).sorted()
    UserDefaults.standard.set(dict, forKey: storageKey)
  }

  static func markSaved(item: CameraVendorGalleryItem, for cameraID: String) {
    markSaved(handle: item.handle, for: cameraID)
    var dict = UserDefaults.standard.dictionary(forKey: recordStorageKey) as? [String: [String]] ?? [:]
    var records = dict[cameraID] ?? []
    records.removeAll { encoded in
      decodedRecord(from: encoded)?.handle == item.handle
    }
    let record = Record(
      handle: item.handle,
      filename: item.filename,
      formatLabel: item.formatLabel,
      captureDate: item.captureDate,
      byteSizeText: item.byteSizeText,
      orientation: item.orientation,
      thumbnailData: item.thumbnailData
    )
    if let encoded = encodedRecord(record) {
      records.append(encoded)
    }
    dict[cameraID] = records
    UserDefaults.standard.set(dict, forKey: recordStorageKey)
  }

  static func historyItems(for cameraID: String) -> [CameraVendorGalleryItem] {
    let dict = UserDefaults.standard.dictionary(forKey: recordStorageKey) as? [String: [String]] ?? [:]
    return (dict[cameraID] ?? [])
      .compactMap(decodedRecord(from:))
      .map(\.item)
      .sorted {
        if $0.captureDate != $1.captureDate {
          return $0.captureDate > $1.captureDate
        }
        return $0.handle > $1.handle
      }
  }

  static func removeSaved(handle: Int, for cameraID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    var existing = Set(dict[cameraID] ?? [])
    existing.remove(handle)
    if existing.isEmpty {
      dict.removeValue(forKey: cameraID)
    } else {
      dict[cameraID] = Array(existing).sorted()
    }
    UserDefaults.standard.set(dict, forKey: storageKey)

    var recordDict = UserDefaults.standard.dictionary(forKey: recordStorageKey) as? [String: [String]] ?? [:]
    var records = recordDict[cameraID] ?? []
    records.removeAll { encoded in
      decodedRecord(from: encoded)?.handle == handle
    }
    if records.isEmpty {
      recordDict.removeValue(forKey: cameraID)
    } else {
      recordDict[cameraID] = records
    }
    UserDefaults.standard.set(recordDict, forKey: recordStorageKey)
  }

  static func clear(for cameraID: String) {
    var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [Int]] ?? [:]
    dict.removeValue(forKey: cameraID)
    UserDefaults.standard.set(dict, forKey: storageKey)

    var recordDict = UserDefaults.standard.dictionary(forKey: recordStorageKey) as? [String: [String]] ?? [:]
    recordDict.removeValue(forKey: cameraID)
    UserDefaults.standard.set(recordDict, forKey: recordStorageKey)
  }

  private static func encodedRecord(_ record: Record) -> String? {
    try? JSONEncoder().encode(record).base64EncodedString()
  }

  private static func decodedRecord(from encoded: String) -> Record? {
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return try? JSONDecoder().decode(Record.self, from: data)
  }
}

enum CameraVendorDownloadTimingFormatter {
  static func megabytesPerSecond(byteCount: Int, elapsedMs: Int) -> String {
    guard byteCount > 0, elapsedMs > 0 else { return "0.00" }
    let megabytes = Double(byteCount) / 1_048_576.0
    let seconds = Double(elapsedMs) / 1000.0
    return String(format: "%.2f", megabytes / seconds)
  }
}

enum NativeGalleryLoadingPhrase {
  /// Map raw diagnostic strings into a short human-readable sentence
  /// shown under the spinner. Returns empty string if the message is
  /// not worth surfacing (e.g. very low-level packet logs).
  static func humanize(_ message: String) -> String {
    let lower = message.lowercased()
    if lower.contains("openSession".lowercased()) || lower.contains("session") && lower.contains("open") {
      return "正在打开 PTP 会话"
    }
    if lower.contains("getstorageids") || lower.contains("storage") {
      return "正在读取相机存储信息"
    }
    if lower.contains("getobjecthandles") || lower.contains("d621") || lower.contains("listing") || lower.contains("getobjectinfo") {
      return "正在获取照片列表"
    }
    if lower.contains("hidden handle") || lower.contains("heif") || lower.contains("raw") {
      return "正在补全 HEIF / RAW 照片"
    }
    if lower.contains("缩略图") || lower.contains("thumbnail") {
      return "正在加载缩略图"
    }
    if lower.contains("ble") || lower.contains("蓝牙") {
      return "正在通过蓝牙激活相机传输"
    }
    if lower.contains("wi-fi") || lower.contains("wifi") {
      return "正在等待相机 Wi-Fi"
    }
    if lower.contains("握手") || lower.contains("handshake") {
      return "正在与相机建立连接"
    }
    if lower.contains("加载失败") || lower.contains("failed") {
      return ""
    }
    return ""
  }
}

enum NativeGalleryDownloadSelectionPolicy {
  static func canSelect(downloadState: CameraVendorDownloadState) -> Bool {
    switch downloadState {
    case .idle, .failed:
      return true
    case .queued, .downloading, .saved:
      return false
    }
  }
}

enum NativeGalleryNavigationPolicy {
  static func canLeaveGallery(isDownloading: Bool) -> Bool {
    !isDownloading
  }

  static func canOpenPreview(isDownloading: Bool) -> Bool {
    !isDownloading
  }

  static func canDismissPreview(isDownloading: Bool) -> Bool {
    !isDownloading
  }
}

enum NativeGalleryDownloadBarPolicy {
  static func canToggleSelectAll(totalSelectableCount: Int, isDownloading: Bool) -> Bool {
    !isDownloading && totalSelectableCount > 0
  }

  static func canStartDownload(selectedCount: Int, isDownloading: Bool) -> Bool {
    !isDownloading && selectedCount > 0
  }
}

enum NativeGallerySessionPresentationSurface: String, Equatable {
  case gallery
  case downloadCenter
  case other
}

enum NativeGalleryDownloadModePresentationPolicy {
  static func canInteractWithGallery(isDownloading: Bool) -> Bool {
    !isDownloading
  }

  static func shouldScheduleThumbnailRefresh(isDownloading: Bool) -> Bool {
    !isDownloading
  }

  static func shouldKeepForegroundGallerySession(surface: NativeGallerySessionPresentationSurface) -> Bool {
    switch surface {
    case .gallery, .downloadCenter:
      return true
    case .other:
      return false
    }
  }

  static func shouldDelegateForegroundRecoveryToHome(surface: NativeGallerySessionPresentationSurface) -> Bool {
    !shouldKeepForegroundGallerySession(surface: surface)
  }

  static func shouldAutoReturnToGalleryAfterDownloadCompletion(
    surface: NativeGallerySessionPresentationSurface
  ) -> Bool {
    surface == .downloadCenter
  }
}

enum NativeGalleryDownloadFailurePolicy {
  static let connectionLostQueueStopMessage = "相机连接已断开，请重新进入相册后重试"

  static func shouldStopQueueAfterFailure(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
      return true
    }
    if nsError.domain == "CameraVendorPtpSocket", nsError.code == 9 {
      return true
    }
    return errorChainMessages(error).contains { message in
      message.range(of: "Not connected to camera", options: .caseInsensitive) != nil ||
        message.range(of: "Socket is closed", options: .caseInsensitive) != nil ||
        message.range(of: "Broken pipe", options: .caseInsensitive) != nil ||
        message.range(of: "Connection reset", options: .caseInsensitive) != nil ||
        message.range(of: "等待相机返回数据超时", options: .caseInsensitive) != nil
    }
  }

  private static func errorChainMessages(_ error: Error) -> [String] {
    var messages: [String] = []
    var current: NSError? = error as NSError
    while let nsError = current {
      messages.append(nsError.localizedDescription)
      current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return messages
  }
}

enum NativeGalleryPreviewDownloadPolicy {
  static let shouldDismissAfterStartingDownload = true
}

enum NativeGalleryPostDownloadSelectionPolicy {
  static func selectionAfterStartingDownload(selectedHandles: Set<Int>) -> Set<Int> {
    []
  }
}

enum NativeGalleryDragSelectionMode: Equatable {
  case selecting
  case deselecting
}

enum NativeGalleryDragSelectionPolicy {
  private static let horizontalIntentRatio: CGFloat = 1.25
  private static let minHorizontalSlopMultiplier: CGFloat = 1.15

  static func mode(startHandle: Int, selectedHandles: Set<Int>) -> NativeGalleryDragSelectionMode {
    selectedHandles.contains(startHandle) ? .deselecting : .selecting
  }

  static func shouldStartDragSelection(
    deltaX: CGFloat,
    deltaY: CGFloat,
    touchSlop: CGFloat,
    selectionActive: Bool = false
  ) -> Bool {
    let distance = hypot(deltaX, deltaY)
    if distance < touchSlop { return false }
    let horizontal = abs(deltaX)
    let vertical = abs(deltaY)
    let minHorizontal = touchSlop * minHorizontalSlopMultiplier
    return horizontal >= minHorizontal && horizontal >= vertical * horizontalIntentRatio
  }

  static func shouldCommitDragSelection(
    startHandle: Int,
    endHandle: Int?,
    canSelectEndHandle: Bool
  ) -> Bool {
    guard let endHandle else { return false }
    return endHandle != startHandle && canSelectEndHandle
  }

  static func updatedSelection(
    selectedHandles: Set<Int>,
    visiting handles: [Int],
    mode: NativeGalleryDragSelectionMode
  ) -> Set<Int> {
    var updated = selectedHandles
    switch mode {
    case .selecting:
      updated.formUnion(handles)
    case .deselecting:
      updated.subtract(handles)
    }
    return updated
  }

  static func updatedRangeSelection(
    selectedHandles: Set<Int>,
    orderedHandles: [Int],
    startHandle: Int,
    endHandle: Int,
    selectableHandles: Set<Int>,
    mode: NativeGalleryDragSelectionMode
  ) -> Set<Int> {
    guard let startIndex = orderedHandles.firstIndex(of: startHandle),
          let endIndex = orderedHandles.firstIndex(of: endHandle) else {
      return selectedHandles
    }
    let bounds = startIndex <= endIndex ? startIndex...endIndex : endIndex...startIndex
    let rangeHandles = Set(bounds.map { orderedHandles[$0] }).intersection(selectableHandles)
    var updated = selectedHandles
    switch mode {
    case .selecting:
      updated.formUnion(rangeHandles)
    case .deselecting:
      updated.subtract(rangeHandles)
    }
    return updated
  }

  static func autoScrollDelta(
    pointerY: CGFloat,
    viewportStart: CGFloat,
    viewportEnd: CGFloat,
    edgeSize: CGFloat,
    maxDelta: CGFloat
  ) -> CGFloat {
    guard edgeSize > 0, maxDelta > 0, viewportEnd > viewportStart else { return 0 }
    if pointerY < viewportStart + edgeSize {
      let intensity = min(max((viewportStart + edgeSize - pointerY) / edgeSize, 0), 1)
      return -maxDelta * intensity
    }
    if pointerY > viewportEnd - edgeSize {
      let intensity = min(max((pointerY - (viewportEnd - edgeSize)) / edgeSize, 0), 1)
      return maxDelta * intensity
    }
    return 0
  }
}

struct NativeGallerySelectionSummary: Equatable {
  let selectedCount: Int
  let totalSelectableCount: Int

  var text: String {
    "已选 \(selectedCount) / 共 \(totalSelectableCount) 张"
  }
}

enum NativeGallerySelectionSummaryPolicy {
  static func summary(items: [CameraVendorGalleryItem], state: CameraVendorGalleryState) -> NativeGallerySelectionSummary {
    let selectableHandles = Set(state.downloadableHandles(from: items.map(\.handle)))
    let selectedHandles = state.selectedHandles.intersection(selectableHandles)
    return NativeGallerySelectionSummary(
      selectedCount: selectedHandles.count,
      totalSelectableCount: selectableHandles.count
    )
  }
}

enum NativeGalleryPriorityDownloadPolicy {
  static func shouldInterruptPtpBeforeDownload(isThumbnailRequestInFlight: Bool) -> Bool {
    CameraVendorThumbnailLoadPolicy.shouldInterruptInFlightRequestBeforeDownload && isThumbnailRequestInFlight
  }

  static func shouldLoadPreviewThumbnail(isDownloading: Bool) -> Bool {
    !isDownloading || !CameraVendorThumbnailLoadPolicy.shouldPauseWhileDownloading
  }
}

enum NativeGalleryEntryNavigationPolicy {
  static let preloadingStatus = "正在与相机建立连接并读取照片…"
  static let waitingForWifiStatus = "相机相册初始化失败，暂不进入相册。"
  static let shouldPushGalleryBeforeDismissingPairingUI = true
  static let shouldHideConnectingOverlayAfterGalleryPush = true

  static func shouldEnterGalleryAfterPreload(fetchSucceeded: Bool) -> Bool {
    fetchSucceeded
  }
}
