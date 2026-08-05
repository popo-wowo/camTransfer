import Foundation

enum CameraFilterPlan: Equatable, Sendable {
  case allCatalog
  case exactFormats(Set<CameraMediaFormat>)
  case subtractBaseline(Set<CameraMediaFormat>)
}

struct CameraMediaFilterCandidate: Equatable, Sendable {
  let handle: Int
  let captureDate: Date?
}

enum CameraFilterEngine {
  static func plan(for selection: CameraMediaFormatSelection) -> CameraFilterPlan {
    switch selection {
    case .all:
      return .allCatalog
    case .selected(let formats):
      let normalized = CameraMediaFormatSelection.normalized(formats)
      guard case .selected(let requestedFormats) = normalized else {
        return .allCatalog
      }
      if requestedFormats.contains(.heif) {
        // HEIF is the only product format whose current camera response needs
        // compatibility subtraction. Video uses direct MOV + MP4 catalogs.
        return .subtractBaseline(requestedFormats)
      }
      return .exactFormats(requestedFormats)
    }
  }

  static func project(
    _ candidates: [CameraMediaFilterCandidate],
    rule: CameraMediaFilterRule,
    downloadedHandles: Set<Int>,
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [CameraMediaFilterCandidate] {
    candidates.filter { candidate in
      matchesDate(candidate.captureDate, selection: rule.date, now: now, calendar: calendar) &&
        matchesDownloadScope(candidate.handle, scope: rule.downloadScope, downloadedHandles: downloadedHandles)
    }
  }

  static func parseCaptureDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for formatter in captureDateFormatters {
      if let date = formatter.date(from: trimmed) {
        return date
      }
    }
    return nil
  }

  private static func matchesDate(
    _ captureDate: Date?,
    selection: CameraMediaDateSelection,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    switch selection {
    case .all:
      return true
    case .today:
      guard let captureDate else { return false }
      return calendar.isDate(captureDate, inSameDayAs: now)
    case .specificDay(let day):
      guard let captureDate else { return false }
      return calendar.isDate(captureDate, inSameDayAs: day)
    }
  }

  private static func matchesDownloadScope(
    _ handle: Int,
    scope: CameraMediaDownloadScope,
    downloadedHandles: Set<Int>
  ) -> Bool {
    switch scope {
    case .all:
      return true
    case .notDownloaded:
      return !downloadedHandles.contains(handle)
    }
  }

  private static let captureDateFormatters: [DateFormatter] = [
    "yyyy:MM:dd HH:mm:ss",
    "yyyy-MM-dd",
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
}
