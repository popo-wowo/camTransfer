import Foundation

struct CameraGalleryResolvedItemMetadata: Equatable, Sendable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: String
  let byteSizeText: String
  let compressedSize: UInt32?
  let orientation: Int?
  let formatHints: [String]
}

struct CameraGalleryObjectInfoResult: Equatable, Sendable {
  let metadata: CameraGalleryResolvedItemMetadata
  let formatCode: UInt16
  let hasResolvedFormat: Bool

  var handle: Int { metadata.handle }
  var captureDate: String { metadata.captureDate }
}

struct CameraGalleryThumbnailResult: Equatable, Sendable {
  let data: Data
  let resolvedMetadata: CameraGalleryResolvedItemMetadata?
  let objectInfo: CameraGalleryObjectInfoResult?

  init(
    data: Data,
    resolvedMetadata: CameraGalleryResolvedItemMetadata?,
    objectInfo: CameraGalleryObjectInfoResult? = nil
  ) {
    self.data = data
    self.resolvedMetadata = resolvedMetadata
    self.objectInfo = objectInfo
  }
}

struct CameraGalleryPreviewResult: Equatable, Sendable {
  let data: Data
  let objectOrientation: Int?
}

struct CameraGalleryDetailsSourceResult: Equatable {
  let handle: Int
  let orientation: CameraGalleryConfirmedValue<Int>
  let refinedFormat: CameraGalleryConfirmedValue<CameraGalleryFormat>
  let notes: [String]
  let resolvedMetadata: CameraGalleryResolvedItemMetadata?
  let objectInfo: CameraGalleryObjectInfoResult?

  init(
    handle: Int,
    orientation: CameraGalleryConfirmedValue<Int>,
    refinedFormat: CameraGalleryConfirmedValue<CameraGalleryFormat>,
    notes: [String],
    resolvedMetadata: CameraGalleryResolvedItemMetadata? = nil,
    objectInfo: CameraGalleryObjectInfoResult? = nil
  ) {
    self.handle = handle
    self.orientation = orientation
    self.refinedFormat = refinedFormat
    self.notes = notes
    self.resolvedMetadata = resolvedMetadata
    self.objectInfo = objectInfo
  }
}

struct CameraGalleryCatalogResponseEvidence: Equatable, Sendable {
  let domain: String
  let responseCode: UInt16
  let operationCode: UInt16
  let transactionID: UInt32

  init?(error: Error) {
    let responseError = error as NSError
    guard let responseCode = UInt16(exactly: responseError.code),
          let operationNumber = responseError.userInfo["operationCode"] as? NSNumber,
          let transactionNumber = responseError.userInfo["transactionID"] as? NSNumber,
          let operationCode = Self.exactUInt16(operationNumber),
          let transactionID = Self.exactUInt32(transactionNumber) else {
      return nil
    }
    domain = responseError.domain
    self.responseCode = responseCode
    self.operationCode = operationCode
    self.transactionID = transactionID
  }

  private static func exactUInt16(_ number: NSNumber) -> UInt16? {
    exactUnsignedInteger(number, maximum: UInt64(UInt16.max)).map(UInt16.init)
  }

  private static func exactUInt32(_ number: NSNumber) -> UInt32? {
    exactUnsignedInteger(number, maximum: UInt64(UInt32.max)).map(UInt32.init)
  }

  private static func exactUnsignedInteger(
    _ number: NSNumber,
    maximum: UInt64
  ) -> UInt64? {
    let value = number.doubleValue
    guard value.isFinite,
          value >= 0,
          value <= Double(maximum),
          value.rounded(.towardZero) == value else {
      return nil
    }
    let converted = UInt64(value)
    guard Double(converted) == value else { return nil }
    return converted
  }
}

struct CameraGalleryCatalogTransactionFailure: Error, Equatable, Sendable {
  let primaryMessage: String
  let restorationMessage: String?
  let provesTransportLost: Bool
  let responseEvidence: CameraGalleryCatalogResponseEvidence?

  init(
    primaryMessage: String,
    restorationMessage: String?,
    provesTransportLost: Bool,
    responseEvidence: CameraGalleryCatalogResponseEvidence? = nil
  ) {
    self.primaryMessage = primaryMessage
    self.restorationMessage = restorationMessage
    self.provesTransportLost = provesTransportLost
    self.responseEvidence = responseEvidence
  }

  var catalogFailure: CameraGalleryCatalogFailure {
    CameraGalleryCatalogFailure(
      message: primaryMessage,
      restorationMessage: restorationMessage,
      provesTransportLost: provesTransportLost
    )
  }
}

@MainActor
protocol CameraCatalogQuerySource: AnyObject {
  func loadExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot
  func loadInitialExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot
  func loadExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
  func loadSubtractBaselineCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
  func loadInitialExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
  func loadInitialSubtractBaselineCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
}

extension CameraCatalogQuerySource {
  func loadInitialExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot {
    try await loadExpandedCatalog()
  }

  func loadInitialExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot {
    try await loadExactCatalog(for: format)
  }

  func loadInitialSubtractBaselineCatalog(
    for format: CameraMediaFormat
  ) async throws -> CameraGalleryCatalogSnapshot {
    try await loadSubtractBaselineCatalog(for: format)
  }
}

@MainActor
protocol CameraGalleryThumbnailPipelineSource: AnyObject {
  func loadThumbnail(handle: Int) async throws -> CameraGalleryThumbnailResult
  func loadDetails(handle: Int) async throws -> CameraGalleryDetailsSourceResult
  func beginVisibleThumbnailBatch(handles: [Int])
  func finishVisibleThumbnailBatch(handles: [Int]) async
}

@MainActor
protocol CameraGalleryCatalogRuntimeSource: CameraCatalogQuerySource, CameraGalleryThumbnailPipelineSource {}
