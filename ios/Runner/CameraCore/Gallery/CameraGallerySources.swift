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

struct CameraGalleryCatalogTransactionFailure: Error, Equatable, Sendable {
  let primaryMessage: String
  let restorationMessage: String?
  let provesTransportLost: Bool

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
  func loadInitialCatalog() async throws -> CameraGalleryCatalogSnapshot
  func loadExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
  func loadSubtractBaselineCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
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
