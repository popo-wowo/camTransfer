import Foundation

enum CameraGalleryConfirmedValue<Value: Equatable & Sendable>: Equatable, Sendable {
  case confirmed(Value)
  case unknown
}

enum CameraGalleryFormat: Equatable, Sendable {
  case jpg
  case heif
  case raw
  case video
}

enum CameraGallerySortKey: Equatable, Sendable {
  case handleDescending(Int)
  case captureDateDescending(Date)
}

struct CameraGalleryEntrySummary: Equatable, Sendable {
  let handle: Int
  var filename: CameraGalleryConfirmedValue<String>
  var format: CameraGalleryConfirmedValue<CameraGalleryFormat>
  var captureDate: CameraGalleryConfirmedValue<Date>
  var size: CameraGalleryConfirmedValue<Int64>
  let sortKey: CameraGallerySortKey
}

enum CameraGalleryThumbnailState: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case failed
}

struct CameraGalleryEntryThumbnail: Equatable, Sendable {
  let handle: Int
  var state: CameraGalleryThumbnailState
  var imageData: Data?
}

struct CameraGalleryEntryDetails: Equatable, Sendable {
  let handle: Int
  var orientation: CameraGalleryConfirmedValue<Int>
  var refinedFormat: CameraGalleryConfirmedValue<CameraGalleryFormat>
  var notes: [String]
}

struct CameraGalleryEntryViewState: Equatable, Sendable {
  var summary: CameraGalleryEntrySummary
  var thumbnail: CameraGalleryEntryThumbnail
  var details: CameraGalleryEntryDetails
}

enum CameraGalleryDateIntent: Equatable, Sendable {
  case all
  case today
  case specificDay(Date)
}

enum CameraGalleryFormatIntent: Equatable, Sendable {
  case all
  case jpg
  case heif
  case raw
}

enum CameraGallerySortIntent: String, Equatable, Codable, Sendable {
  case newest
  case oldest
  case notDownloaded
}

enum CameraGalleryDownloadStatusIntent: Equatable, Sendable {
  case all
  case notDownloaded
}

struct CameraGalleryFilterIntent: Equatable, Codable, Sendable {
  let rule: CameraMediaFilterRule
  let sort: CameraGallerySortIntent

  static let all = CameraGalleryFilterIntent(
    rule: .galleryDefault,
    sort: .newest
  )

  init(rule: CameraMediaFilterRule, sort: CameraGallerySortIntent) {
    self.rule = rule
    self.sort = sort
  }

  init(
    date: CameraGalleryDateIntent,
    format: CameraGalleryFormatIntent,
    sort: CameraGallerySortIntent,
    downloadStatus: CameraGalleryDownloadStatusIntent
  ) {
    let dateSelection: CameraMediaDateSelection
    switch date {
    case .all: dateSelection = .all
    case .today: dateSelection = .today
    case .specificDay(let day): dateSelection = .specificDay(day)
    }
    let formatSelection: CameraMediaFormatSelection
    switch format {
    case .all: formatSelection = .all
    case .jpg: formatSelection = .selected([.jpg])
    case .heif: formatSelection = .selected([.heif])
    case .raw: formatSelection = .selected([.raw])
    }
    rule = CameraMediaFilterRule(
      formats: formatSelection,
      date: dateSelection,
      downloadScope: downloadStatus == .notDownloaded ? .notDownloaded : .all
    )
    self.sort = sort
  }

  var date: CameraGalleryDateIntent {
    switch rule.date {
    case .all: return .all
    case .today: return .today
    case .specificDay(let day): return .specificDay(day)
    }
  }

  var format: CameraGalleryFormatIntent {
    switch rule.formats {
    case .all:
      return .all
    case .selected(let formats) where formats == [.jpg]:
      return .jpg
    case .selected(let formats) where formats == [.heif]:
      return .heif
    case .selected(let formats) where formats == [.raw]:
      return .raw
    case .selected:
      return .all
    }
  }

  var downloadStatus: CameraGalleryDownloadStatusIntent {
    rule.downloadScope == .notDownloaded ? .notDownloaded : .all
  }

  var requiresCameraCatalogTransaction: Bool {
    CameraFilterEngine.plan(for: rule.formats) != .allCatalog
  }

  func hasSameCameraMembership(as other: CameraGalleryFilterIntent) -> Bool {
    rule == other.rule
  }
}

struct CameraGalleryGenerationID: Equatable, Hashable, Sendable {
  let rawValue: UInt64
}

/// Orders UI command delivery into the catalog actor. This is not a catalog
/// generation and has no authority to install or publish catalog state.
struct CameraGalleryIntentSubmissionID: Equatable, Comparable, Hashable, Sendable {
  let rawValue: UInt64

  static func < (
    lhs: CameraGalleryIntentSubmissionID,
    rhs: CameraGalleryIntentSubmissionID
  ) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

struct CameraGallerySnapshotID: Equatable, Hashable, Sendable {
  let rawValue: UUID

  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

enum CameraGalleryUnsupportedReason: Equatable, Sendable {
  case dateWireFormatUnproven
  case heifCatalogUnverified

  var message: String {
    switch self {
    case .dateWireFormatUnproven:
      return "日期筛选尚未取得原厂 XApp 的完整 wire 证据"
    case .heifCatalogUnverified:
      return "当前相机尚未验证 HEIF 精确目录"
    }
  }
}

struct CameraGalleryCatalogFailure: Equatable, Sendable {
  let message: String
  let restorationMessage: String?
  let provesTransportLost: Bool
}

enum CameraGalleryCatalogState: Equatable, Sendable {
  case unavailable
  case loading(generation: CameraGalleryGenerationID, intent: CameraGalleryFilterIntent)
  case ready(generation: CameraGalleryGenerationID, snapshotID: CameraGallerySnapshotID)
  case unsupported(generation: CameraGalleryGenerationID, reason: CameraGalleryUnsupportedReason)
  case failed(generation: CameraGalleryGenerationID, failure: CameraGalleryCatalogFailure)
  case transportLost(String)
}

struct CameraGalleryPresentation: Equatable, @unchecked Sendable {
  let state: CameraGalleryCatalogState
  let intent: CameraGalleryFilterIntent
  let items: [CameraVendorGalleryItem]
  let entries: [CameraGalleryEntryViewState]

  static let unavailable = CameraGalleryPresentation(
    state: .unavailable,
    intent: .all,
    items: [],
    entries: []
  )

  var generation: CameraGalleryGenerationID? {
    switch state {
    case .loading(let generation, _),
         .ready(let generation, _),
         .unsupported(let generation, _),
         .failed(let generation, _):
      return generation
    case .unavailable, .transportLost:
      return nil
    }
  }

  var errorMessage: String? {
    switch state {
    case .unsupported(_, let reason):
      return reason.message
    case .failed(_, let failure):
      return failure.message
    case .transportLost(let message):
      return message
    case .unavailable, .loading, .ready:
      return nil
    }
  }

  var isLoading: Bool {
    if case .loading = state { return true }
    return false
  }
}

struct CameraGalleryCatalogSnapshot: Equatable, @unchecked Sendable {
  let snapshotID: CameraGallerySnapshotID
  let dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  let orderedHandles: [UInt32]
  let items: [CameraVendorGalleryItem]
}

struct CameraGalleryChildIdentity: Equatable, Hashable, Sendable {
  let generation: CameraGalleryGenerationID
  let snapshotID: CameraGallerySnapshotID
  let handle: Int
}
