import Foundation

struct CameraAutoDownloadRule: Codable, Equatable {
  var isEnabled: Bool = false
  var filter: CameraMediaFilterRule = .quickDownloadDefault
  var downloadMode: CameraAutoDownloadMode = .original
  var disconnectAfterDownload: Bool = true

  var completionPolicy: CameraDownloadCompletionPolicy {
    disconnectAfterDownload ? .disconnectToHome : .returnToGallery
  }

  var catalogFilter: CameraMediaFilterRule? {
    let formats: CameraMediaFormatSelection
    switch filter.formats {
    case .all:
      formats = .selected([.jpg, .raw, .heif])
    case .selected(let selectedFormats):
      let supportedFormats = selectedFormats.intersection([.jpg, .raw, .heif])
      guard !supportedFormats.isEmpty else { return nil }
      formats = .selected(supportedFormats)
    }
    return CameraMediaFilterRule(
      formats: formats,
      date: filter.date,
      downloadScope: filter.downloadScope
    )
  }

  var summaryText: String {
    guard isEnabled else { return "未启用" }
    return [formatText, dateText, downloadScopeText, modeText]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
  }

  private var formatText: String {
    switch filter.formats {
    case .all:
      return "全部格式"
    case .selected(let formats):
      return CameraMediaFormat.allCases
        .filter(formats.contains)
        .map(\.displayTitle)
        .joined(separator: "+")
    }
  }

  private var dateText: String {
    switch filter.date {
    case .all:
      return ""
    case .today:
      return "今天"
    case .specificDay(let date):
      let formatter = DateFormatter()
      formatter.dateFormat = "M月d日"
      return formatter.string(from: date)
    }
  }

  private var downloadScopeText: String {
    filter.downloadScope == .notDownloaded ? "未下载" : ""
  }

  private var modeText: String {
    downloadMode == .original ? "原图" : "压缩"
  }
}

extension CameraMediaFormat {
  var displayTitle: String {
    switch self {
    case .jpg: return "JPG"
    case .raw: return "RAW"
    case .heif: return "HEIF"
    case .video: return "视频"
    }
  }
}

extension CameraMediaDownloadScope {
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
