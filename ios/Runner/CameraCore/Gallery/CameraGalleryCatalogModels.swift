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
  case range(from: Date, to: Date)
}

enum CameraGalleryFormatIntent: Equatable, Sendable {
  case all
  case jpg
  case heif
  case raw
  case video
}

enum CameraGallerySortIntent: Equatable, Sendable {
  case newest
  case oldest
  case notDownloaded
}

enum CameraGalleryDownloadStatusIntent: Equatable, Sendable {
  case all
  case notDownloaded
}

struct CameraGalleryFilterIntent: Equatable, Sendable {
  let date: CameraGalleryDateIntent
  let format: CameraGalleryFormatIntent
  let sort: CameraGallerySortIntent
  let downloadStatus: CameraGalleryDownloadStatusIntent

  static let all = CameraGalleryFilterIntent(
    date: .all,
    format: .all,
    sort: .newest,
    downloadStatus: .all
  )

  var requiresCameraCatalogTransaction: Bool {
    date != .all || format != .all
  }

  func hasSameCameraMembership(as other: CameraGalleryFilterIntent) -> Bool {
    date == other.date && format == other.format
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
  case videoCatalogUnverified

  var message: String {
    switch self {
    case .dateWireFormatUnproven:
      return "日期筛选尚未取得原厂 XApp 的完整 wire 证据"
    case .heifCatalogUnverified:
      return "当前相机尚未验证 HEIF 精确目录"
    case .videoCatalogUnverified:
      return "当前相机尚未验证视频格式目录"
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
