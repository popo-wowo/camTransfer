import Foundation

enum CameraMediaFormat: String, Codable, Hashable, CaseIterable, Sendable {
  case jpg
  case raw
  case heif
  case video
}

enum CameraMediaFormatSelection: Equatable, Codable, Sendable {
  case all
  case selected(Set<CameraMediaFormat>)

  static func normalized(_ formats: Set<CameraMediaFormat>) -> CameraMediaFormatSelection {
    formats.isEmpty ? .all : .selected(formats)
  }

  func selectingAll() -> CameraMediaFormatSelection {
    .all
  }

  var specificFormats: Set<CameraMediaFormat> {
    switch self {
    case .all:
      return []
    case .selected(let formats):
      return formats
    }
  }

  init(from decoder: Decoder) throws {
    switch try CodableValue(from: decoder) {
    case .all:
      self = .all
    case .selected(let formats):
      self = Self.normalized(formats)
    }
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .all:
      try CodableValue.all.encode(to: encoder)
    case .selected(let formats):
      try CodableValue.normalized(formats).encode(to: encoder)
    }
  }

  private enum CodableValue: Codable {
    case all
    case selected(Set<CameraMediaFormat>)

    static func normalized(_ formats: Set<CameraMediaFormat>) -> CodableValue {
      formats.isEmpty ? .all : .selected(formats)
    }
  }
}

enum CameraMediaDateSelection: Equatable, Codable, Sendable {
  case all
  case today
  case specificDay(Date)

  var isSpecificDay: Bool {
    if case .specificDay = self { return true }
    return false
  }
}

enum CameraMediaDownloadScope: String, Codable, Equatable, Sendable {
  case all
  case notDownloaded
}

struct CameraMediaFilterRule: Equatable, Codable, Sendable {
  let formats: CameraMediaFormatSelection
  let date: CameraMediaDateSelection
  let downloadScope: CameraMediaDownloadScope

  static let galleryDefault = CameraMediaFilterRule(
    formats: .all,
    date: .all,
    downloadScope: .all
  )

  static let quickDownloadDefault = CameraMediaFilterRule(
    formats: .selected([.jpg]),
    date: .all,
    downloadScope: .notDownloaded
  )
}
