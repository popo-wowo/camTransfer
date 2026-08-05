import Foundation

enum CameraGalleryFormatHint: String, Equatable, Hashable, Sendable {
  case jpg
  case heif
  case raw
  case video
  case extendedStillCandidate
}

struct CameraGalleryCatalogItem: Equatable, Sendable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: String
  let byteSizeText: String
  let compressedSize: UInt32?
  let orientation: Int?
  let formatHints: Set<CameraGalleryFormatHint>
  var thumbnailData: Data? = nil

  init(
    handle: Int,
    filename: String,
    formatLabel: String,
    captureDate: String,
    byteSizeText: String,
    compressedSize: UInt32? = nil,
    orientation: Int? = nil,
    formatHints: Set<CameraGalleryFormatHint> = [],
    thumbnailData: Data? = nil
  ) {
    self.handle = handle
    self.filename = filename
    self.formatLabel = formatLabel
    self.captureDate = captureDate
    self.byteSizeText = byteSizeText
    self.compressedSize = compressedSize
    self.orientation = orientation
    self.formatHints = formatHints
    self.thumbnailData = thumbnailData
  }
}

struct CameraGalleryDateGroup: Equatable, Sendable {
  let dateText: String
  let objectCount: UInt32
}

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
  case video
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
    case .video: formatSelection = .selected([.video])
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
    case .selected(let formats) where formats == [.video]:
      return .video
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
    rule.formats == other.rule.formats
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
  let items: [CameraGalleryCatalogItem]
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

struct CameraGalleryIncrementalDelta: Equatable, Sendable {
  let changedHandles: Set<Int>
  let orientationChangedHandles: Set<Int>
  let requiresStructuralRefresh: Bool

  static func between(
    previous: CameraGalleryPresentation,
    current: CameraGalleryPresentation,
    changedHandles: Set<Int>
  ) -> CameraGalleryIncrementalDelta {
    let previousByHandle = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.handle, $0) })
    let currentByHandle = Dictionary(uniqueKeysWithValues: current.items.map { ($0.handle, $0) })
    let orientationChangedHandles = Set(changedHandles.filter {
      previousByHandle[$0]?.thumbnailData != nil &&
        previousByHandle[$0]?.orientation != currentByHandle[$0]?.orientation
    })
    let didChangeSectionIdentity = changedHandles.contains {
      sectionIdentity(for: previousByHandle[$0]?.captureDate) !=
        sectionIdentity(for: currentByHandle[$0]?.captureDate)
    }
    let didChangeMembershipOrOrder = previous.items.map(\.handle) != current.items.map(\.handle)
    return CameraGalleryIncrementalDelta(
      changedHandles: changedHandles,
      orientationChangedHandles: orientationChangedHandles,
      requiresStructuralRefresh: didChangeSectionIdentity || didChangeMembershipOrOrder
    )
  }

  private static func sectionIdentity(for captureDate: String?) -> DateComponents? {
    guard let captureDate,
          let date = CameraFilterEngine.parseCaptureDate(captureDate) else { return nil }
    return Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
  }
}

struct CameraGalleryCatalogSnapshot: Equatable, @unchecked Sendable {
  let snapshotID: CameraGallerySnapshotID
  let dateGroups: [CameraGalleryDateGroup]
  let orderedHandles: [UInt32]
  let items: [CameraGalleryCatalogItem]
}

struct CameraGalleryChildIdentity: Equatable, Hashable, Sendable {
  let generation: CameraGalleryGenerationID
  let snapshotID: CameraGallerySnapshotID
  let handle: Int
}
