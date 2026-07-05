import Foundation

enum IOSCameraGalleryDateFilter: Equatable {
  case all
  case today
  case specificDay(Date)
  case range(Date, Date)
}

enum IOSCameraGalleryFormatFilter: Equatable {
  case all
  case jpg
  case heif
  case raw
  case video
}

enum IOSCameraGallerySortMode: Equatable {
  case newest
  case oldest
  case notDownloaded
}

struct IOSCameraGalleryFilterState: Equatable {
  var date: IOSCameraGalleryDateFilter = .all
  var format: IOSCameraGalleryFormatFilter = .all
  var sort: IOSCameraGallerySortMode = .newest
}

struct IOSCameraGalleryItem: Equatable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: Date?
  let byteSize: Int64?
  let orientation: Int?
  let thumbnailBytes: Data?
}

enum IOSCameraGalleryPolicy {
  static func filteredItems(
    _ items: [IOSCameraGalleryItem],
    state: IOSCameraGalleryFilterState,
    downloadedHandles: Set<Int>,
    now: Date,
    calendar: Calendar = .current
  ) -> [IOSCameraGalleryItem] {
    let filtered = items.filter { item in
      matchesDate(item.captureDate, filter: state.date, now: now, calendar: calendar)
        && matchesFormat(item.formatLabel, filter: state.format)
    }

    return filtered.sorted { left, right in
      switch state.sort {
      case .newest:
        return sortNewest(left, right)
      case .oldest:
        return sortOldest(left, right)
      case .notDownloaded:
        let leftDownloaded = downloadedHandles.contains(left.handle)
        let rightDownloaded = downloadedHandles.contains(right.handle)
        if leftDownloaded != rightDownloaded {
          return !leftDownloaded && rightDownloaded
        }
        return sortNewest(left, right)
      }
    }
  }

  static func filteredItems(
    _ items: [IOSCameraGalleryItem],
    state: IOSCameraGalleryFilterState,
    downloadedHandles: [Int],
    now: Date,
    calendar: Calendar = .current
  ) -> [IOSCameraGalleryItem] {
    filteredItems(
      items,
      state: state,
      downloadedHandles: Set(downloadedHandles),
      now: now,
      calendar: calendar
    )
  }

  private static func matchesDate(
    _ date: Date?,
    filter: IOSCameraGalleryDateFilter,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    switch filter {
    case .all:
      return true
    case .today:
      guard let date else { return false }
      return calendar.isDate(date, inSameDayAs: now)
    case .specificDay(let target):
      guard let date else { return false }
      return calendar.isDate(date, inSameDayAs: target)
    case .range(let first, let second):
      guard let date else { return false }
      let start = calendar.startOfDay(for: min(first, second))
      let endStart = calendar.startOfDay(for: max(first, second))
      guard let end = calendar.date(byAdding: .day, value: 1, to: endStart) else {
        return false
      }
      return date >= start && date < end
    }
  }

  private static func matchesFormat(_ formatLabel: String, filter: IOSCameraGalleryFormatFilter) -> Bool {
    let normalized = formatLabel.uppercased()
    switch filter {
    case .all:
      return true
    case .jpg:
      return normalized == "JPG" || normalized == "JPEG"
    case .heif:
      return normalized == "HEIF" || normalized == "HEIC"
    case .raw:
      return normalized == "RAW" || normalized == "RAF"
    case .video:
      return normalized == "MOV" || normalized == "MP4" || normalized == "VIDEO"
    }
  }

  private static func sortNewest(_ left: IOSCameraGalleryItem, _ right: IOSCameraGalleryItem) -> Bool {
    switch (left.captureDate, right.captureDate) {
    case let (leftDate?, rightDate?) where leftDate != rightDate:
      return leftDate > rightDate
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return left.handle > right.handle
    }
  }

  private static func sortOldest(_ left: IOSCameraGalleryItem, _ right: IOSCameraGalleryItem) -> Bool {
    switch (left.captureDate, right.captureDate) {
    case let (leftDate?, rightDate?) where leftDate != rightDate:
      return leftDate < rightDate
    case (nil, _?):
      return false
    case (_?, nil):
      return true
    default:
      return left.handle < right.handle
    }
  }
}
