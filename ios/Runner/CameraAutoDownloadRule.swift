import Foundation

// MARK: - Auto Download Rule

struct CameraAutoDownloadRule: Codable, Equatable {
  var isEnabled: Bool = false
  var format: CameraAutoDownloadFormat = .all
  var date: CameraAutoDownloadDate = .all
  var downloadStatus: CameraAutoDownloadStatus = .notDownloaded
  var downloadMode: CameraAutoDownloadMode = .original
  var disconnectAfterDownload: Bool = true

  var summaryText: String {
    guard isEnabled else { return "未启用" }
    let parts = [formatText, dateText, statusText, modeText].filter { !$0.isEmpty }
    return parts.joined(separator: " · ")
  }

  private var formatText: String {
    switch format {
    case .all: return "全部格式"
    case .jpg: return "JPG"
    case .heif: return "HEIF"
    case .raw: return "RAW"
    case .jpgAndHeif: return "JPG+HEIF"
    case .jpgAndRaw: return "JPG+RAW"
    }
  }

  private var dateText: String {
    switch date {
    case .all: return ""
    case .today: return "今天"
    case .lastNDays(let n): return "最近\(n)天"
    }
  }

  private var statusText: String {
    switch downloadStatus {
    case .all: return ""
    case .notDownloaded: return "未下载"
    }
  }

  private var modeText: String {
    switch downloadMode {
    case .original: return "原图"
    case .compressed: return "压缩"
    }
  }
}

enum CameraAutoDownloadFormat: String, Codable, Equatable, CaseIterable {
  case all
  case jpg
  case heif
  case raw
  case jpgAndHeif
  case jpgAndRaw

  var displayTitle: String {
    switch self {
    case .all: return "全部格式"
    case .jpg: return "JPG"
    case .heif: return "HEIF"
    case .raw: return "RAW"
    case .jpgAndHeif: return "JPG + HEIF"
    case .jpgAndRaw: return "JPG + RAW"
    }
  }
}

enum CameraAutoDownloadDate: Codable, Equatable {
  case all
  case today
  case lastNDays(Int)

  var displayTitle: String {
    switch self {
    case .all: return "全部日期"
    case .today: return "今天"
    case .lastNDays(let n): return "最近 \(n) 天"
    }
  }

  static var presets: [CameraAutoDownloadDate] {
    [.all, .today, .lastNDays(3), .lastNDays(7)]
  }
}

enum CameraAutoDownloadStatus: String, Codable, Equatable, CaseIterable {
  case all
  case notDownloaded

  var displayTitle: String {
    switch self {
    case .all: return "全部（含已下载）"
    case .notDownloaded: return "只下载未下载的"
    }
  }
}

enum CameraAutoDownloadMode: String, Codable, Equatable {
  case original
  case compressed

  var transferMode: CameraVendorTransferDownloadMode {
    switch self {
    case .original: return .original
    case .compressed: return .compressed
    }
  }
}

// MARK: - Rule Store

final class CameraAutoDownloadRuleStore {
  private static let key = "com.camtransfer.auto-download-rule"

  static func load() -> CameraAutoDownloadRule {
    guard let data = UserDefaults.standard.data(forKey: key),
          let rule = try? JSONDecoder().decode(CameraAutoDownloadRule.self, from: data) else {
      return CameraAutoDownloadRule()
    }
    return rule
  }

  static func save(_ rule: CameraAutoDownloadRule) {
    guard let data = try? JSONEncoder().encode(rule) else { return }
    UserDefaults.standard.set(data, forKey: key)
  }
}

// MARK: - Rule Filter

enum CameraAutoDownloadRuleFilter {
  /// Match handles using format hint sets (derived from camera directory differences).
  /// `heifHandles`: handles that are in D604=2 result but NOT in the ALL result.
  /// `videoHandles`: handles that are in D604=4|8 result but NOT in the ALL result.
  /// If these sets are empty, format filtering falls back to formatLabel/filename.
  static func matchingHandles(
    items: [CameraVendorGalleryItem],
    rule: CameraAutoDownloadRule,
    savedHandles: Set<Int>,
    heifHandles: Set<Int> = [],
    videoHandles: Set<Int> = [],
    now: Date = Date(),
    calendar: Calendar = Calendar(identifier: .gregorian)
  ) -> [UInt32] {
    items.filter { item in
      matchesFormat(item, rule.format, heifHandles: heifHandles, videoHandles: videoHandles) &&
        matchesDate(item.captureDate, rule.date, now: now, calendar: calendar) &&
        matchesStatus(item.handle, rule.downloadStatus, savedHandles: savedHandles)
    }.map { UInt32($0.handle) }
  }

  private static func matchesFormat(
    _ item: CameraVendorGalleryItem,
    _ format: CameraAutoDownloadFormat,
    heifHandles: Set<Int>,
    videoHandles: Set<Int>
  ) -> Bool {
    switch format {
    case .all:
      return true
    case .jpg:
      return matchesByLabelOrHandle(item, labels: ["JPG", "JPEG"], extensions: ["JPG", "JPEG"],
                                     handleSet: nil, heifHandles: heifHandles, videoHandles: videoHandles,
                                     excludeHeif: true, excludeVideo: true)
    case .heif:
      if !heifHandles.isEmpty {
        return heifHandles.contains(item.handle)
      }
      return matchesByLabel(item, labels: ["HEIF", "HEIC"], extensions: ["HEIF", "HEIC", "HIF"])
    case .raw:
      return matchesByLabelOrHandle(item, labels: ["RAW", "RAF"], extensions: ["RAF", "RAW"],
                                     handleSet: nil, heifHandles: heifHandles, videoHandles: videoHandles,
                                     excludeHeif: true, excludeVideo: true)
    case .jpgAndHeif:
      return matchesFormat(item, .jpg, heifHandles: heifHandles, videoHandles: videoHandles) ||
        matchesFormat(item, .heif, heifHandles: heifHandles, videoHandles: videoHandles)
    case .jpgAndRaw:
      return matchesFormat(item, .jpg, heifHandles: heifHandles, videoHandles: videoHandles) ||
        matchesFormat(item, .raw, heifHandles: heifHandles, videoHandles: videoHandles)
    }
  }

  /// For JPG/RAW where we don't have a dedicated handle set:
  /// If item has a known label/extension, use that.
  /// If item is a placeholder (empty label), exclude it if it's in heif/video sets,
  /// otherwise assume it's this format (JPG/RAW are in the baseline directory).
  private static func matchesByLabelOrHandle(
    _ item: CameraVendorGalleryItem,
    labels: Set<String>,
    extensions: Set<String>,
    handleSet: Set<Int>?,
    heifHandles: Set<Int>,
    videoHandles: Set<Int>,
    excludeHeif: Bool,
    excludeVideo: Bool
  ) -> Bool {
    // If we have explicit format info, use it
    if matchesByLabel(item, labels: labels, extensions: extensions) {
      return true
    }
    // For placeholder items (no format info): check handle sets
    let label = item.formatLabel.uppercased()
    if label.isEmpty {
      // Placeholder — it's in baseline (ALL) directory = JPG or RAW or Video
      if excludeHeif, heifHandles.contains(item.handle) { return false }
      if excludeVideo, videoHandles.contains(item.handle) { return false }
      // Can't determine format without ObjectInfo — don't include in auto-download
      // unless this is the "all" format which is handled above
      return false
    }
    return false
  }

  private static func matchesByLabel(
    _ item: CameraVendorGalleryItem,
    labels: Set<String>,
    extensions: Set<String>
  ) -> Bool {
    let label = item.formatLabel.uppercased()
    if !label.isEmpty, labels.contains(label) { return true }
    let ext = (item.filename as NSString).pathExtension.uppercased()
    if !ext.isEmpty, extensions.contains(ext) { return true }
    return false
  }

  private static func matchesDate(
    _ captureDate: String,
    _ date: CameraAutoDownloadDate,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard date != .all else { return true }
    guard let parsed = parseCaptureDate(captureDate) else { return false }
    switch date {
    case .all:
      return true
    case .today:
      return calendar.isDate(parsed, inSameDayAs: now)
    case .lastNDays(let n):
      guard let cutoff = calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: now)) else {
        return false
      }
      return parsed >= cutoff
    }
  }

  private static func matchesStatus(
    _ handle: Int,
    _ status: CameraAutoDownloadStatus,
    savedHandles: Set<Int>
  ) -> Bool {
    switch status {
    case .all:
      return true
    case .notDownloaded:
      return !savedHandles.contains(handle)
    }
  }

  private static func parseCaptureDate(_ text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if trimmed.count >= 15, trimmed.contains("T") {
      formatter.dateFormat = "yyyyMMdd'T'HHmmss"
      return formatter.date(from: String(trimmed.prefix(15)))
    }
    if trimmed.count >= 8 {
      formatter.dateFormat = "yyyyMMdd"
      return formatter.date(from: String(trimmed.prefix(8)))
    }
    return nil
  }
}
