import Foundation

enum CameraGalleryRepositoryAdapter {
  static func item(
    existingItem: CameraVendorGalleryItem,
    thumbnailData: Data,
    resolvedItem: CameraVendorGalleryItem?
  ) -> CameraVendorGalleryItem {
    var item = resolvedItem.map {
      mergedItem(existingItem: existingItem, resolvedItem: $0)
    } ?? existingItem
    item.thumbnailData = thumbnailData
    return item
  }

  static func mergedItem(
    existingItem: CameraVendorGalleryItem,
    resolvedItem: CameraVendorGalleryItem
  ) -> CameraVendorGalleryItem {
    let existingFilename = existingItem.filename.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedFilename = resolvedItem.filename.trimmingCharacters(in: .whitespacesAndNewlines)
    let filename = isPlaceholderFilename(existingFilename) && !resolvedFilename.isEmpty
      ? resolvedItem.filename
      : existingItem.filename
    let formatLabel = confirmedFormatLabel(existingItem.formatLabel) != nil
      ? existingItem.formatLabel
      : resolvedItem.formatLabel
    return CameraVendorGalleryItem(
      handle: existingItem.handle,
      filename: filename,
      formatLabel: formatLabel,
      captureDate: resolvedItem.captureDate.isEmpty ? existingItem.captureDate : resolvedItem.captureDate,
      byteSizeText: existingItem.byteSizeText.isEmpty ? resolvedItem.byteSizeText : existingItem.byteSizeText,
      compressedSize: existingItem.compressedSize ?? resolvedItem.compressedSize,
      orientation: resolvedItem.orientation ?? existingItem.orientation,
      formatHints: confirmedFormatLabel(formatLabel) == nil
        ? (resolvedItem.formatHints.isEmpty ? existingItem.formatHints : resolvedItem.formatHints)
        : [],
      thumbnailData: existingItem.thumbnailData
    )
  }

  static func summary(from item: CameraVendorGalleryItem) -> CameraGalleryEntrySummary {
    let normalizedFilename = item.filename.trimmingCharacters(in: .whitespacesAndNewlines)
    let filename: CameraGalleryConfirmedValue<String> =
      normalizedFilename.hasPrefix("0x") ? .unknown : .confirmed(normalizedFilename)

    return CameraGalleryEntrySummary(
      handle: item.handle,
      filename: filename,
      format: format(from: item.formatLabel, filename: normalizedFilename),
      captureDate: .unknown,
      size: .unknown,
      sortKey: .handleDescending(item.handle)
    )
  }

  static func details(from info: CameraVendorCameraObjectInfo) -> CameraGalleryEntryDetails {
    entryDetails(from: detailsResult(from: info))
  }

  static func details(from item: CameraVendorGalleryItem) -> CameraGalleryEntryDetails {
    entryDetails(from: detailsResult(from: item))
  }

  static func detailsResult(from info: CameraVendorCameraObjectInfo) -> CameraGalleryDetailsSourceResult {
    CameraGalleryDetailsSourceResult(
      handle: info.handle,
      orientation: info.orientation.map(CameraGalleryConfirmedValue.confirmed) ?? .unknown,
      refinedFormat: info.hasResolvedFormat
        ? format(from: info.formatLabel, filename: info.filename)
        : .unknown,
      notes: []
    )
  }

  static func detailsResult(from item: CameraVendorGalleryItem) -> CameraGalleryDetailsSourceResult {
    CameraGalleryDetailsSourceResult(
      handle: item.handle,
      orientation: item.orientation.map(CameraGalleryConfirmedValue.confirmed) ?? .unknown,
      refinedFormat: format(from: item.formatLabel, filename: item.filename),
      notes: []
    )
  }

  static func entryDetails(from result: CameraGalleryDetailsSourceResult) -> CameraGalleryEntryDetails {
    CameraGalleryEntryDetails(
      handle: result.handle,
      orientation: result.orientation,
      refinedFormat: result.refinedFormat,
      notes: result.notes
    )
  }

  static func legacyItem(
    from summary: CameraGalleryEntrySummary,
    fallback item: CameraVendorGalleryItem
  ) -> CameraVendorGalleryItem {
    let formatLabel = confirmedFormatLabel(from: summary.format) ?? item.formatLabel
    return CameraVendorGalleryItem(
      handle: item.handle,
      filename: confirmedFilename(from: summary.filename) ?? item.filename,
      formatLabel: formatLabel,
      captureDate: item.captureDate,
      byteSizeText: item.byteSizeText,
      compressedSize: item.compressedSize,
      orientation: item.orientation,
      formatHints: formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.formatHints : [],
      thumbnailData: item.thumbnailData
    )
  }

  private static func format(
    from formatLabel: String,
    filename: String
  ) -> CameraGalleryConfirmedValue<CameraGalleryFormat> {
    switch normalizedFormatLabel(formatLabel) {
    case "JPG", "JPEG":
      return .confirmed(.jpg)
    case "HEIF", "HEIC", "HIF":
      return .confirmed(.heif)
    case "RAW", "RAF":
      return .confirmed(.raw)
    case "VIDEO", "MOV", "MP4":
      return .confirmed(.video)
    default:
      return formatFromFilename(filename)
    }
  }

  private static func normalizedFormatLabel(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private static func isPlaceholderFilename(_ filename: String) -> Bool {
    guard filename.hasPrefix("0x"), filename.count == 10 else { return filename.isEmpty }
    return filename.dropFirst(2).allSatisfy(\.isHexDigit)
  }

  private static func confirmedFormatLabel(_ value: String) -> String? {
    switch normalizedFormatLabel(value) {
    case "JPG", "JPEG", "HEIF", "HEIC", "HIF", "RAW", "RAF", "VIDEO", "MOV", "MP4":
      return value
    default:
      return nil
    }
  }

  private static func formatFromFilename(_ filename: String) -> CameraGalleryConfirmedValue<CameraGalleryFormat> {
    let normalizedFilename = filename.uppercased()
    if normalizedFilename.hasSuffix(".JPG") || normalizedFilename.hasSuffix(".JPEG") {
      return .confirmed(.jpg)
    }
    if normalizedFilename.hasSuffix(".HEIC") || normalizedFilename.hasSuffix(".HEIF") || normalizedFilename.hasSuffix(".HIF") {
      return .confirmed(.heif)
    }
    if normalizedFilename.hasSuffix(".RAF") || normalizedFilename.hasSuffix(".RAW") {
      return .confirmed(.raw)
    }
    if normalizedFilename.hasSuffix(".MOV") || normalizedFilename.hasSuffix(".MP4") {
      return .confirmed(.video)
    }
    return .unknown
  }

  private static func confirmedFilename(
    from value: CameraGalleryConfirmedValue<String>
  ) -> String? {
    guard case let .confirmed(filename) = value else { return nil }
    return filename
  }

  private static func confirmedFormatLabel(
    from value: CameraGalleryConfirmedValue<CameraGalleryFormat>
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
}
