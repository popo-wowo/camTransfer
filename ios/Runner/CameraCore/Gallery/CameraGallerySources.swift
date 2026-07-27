import Foundation

struct CameraGalleryDetailsSourceResult: Equatable {
  let handle: Int
  let orientation: CameraGalleryConfirmedValue<Int>
  let refinedFormat: CameraGalleryConfirmedValue<CameraGalleryFormat>
  let notes: [String]
  let resolvedItem: CameraVendorGalleryItem?
  let objectInfo: CameraVendorCameraObjectInfo?

  init(
    handle: Int,
    orientation: CameraGalleryConfirmedValue<Int>,
    refinedFormat: CameraGalleryConfirmedValue<CameraGalleryFormat>,
    notes: [String],
    resolvedItem: CameraVendorGalleryItem? = nil,
    objectInfo: CameraVendorCameraObjectInfo? = nil
  ) {
    self.handle = handle
    self.orientation = orientation
    self.refinedFormat = refinedFormat
    self.notes = notes
    self.resolvedItem = resolvedItem
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
  func loadExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot
  func loadExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot
  func loadObjectInfo(handle: Int) async throws -> CameraVendorCameraObjectInfo
}

@MainActor
protocol CameraGalleryThumbnailPipelineSource: AnyObject {
  func loadThumbnail(handle: Int) async throws -> CameraVendorGalleryThumbnail
  func loadDetails(handle: Int) async throws -> CameraGalleryDetailsSourceResult
  func beginVisibleThumbnailBatch(handles: [Int])
  func finishVisibleThumbnailBatch(handles: [Int]) async
}

@MainActor
protocol CameraGalleryCatalogRuntimeSource: CameraCatalogQuerySource, CameraGalleryThumbnailPipelineSource {
  func loadInitialCatalog() async throws -> CameraGalleryCatalogSnapshot
  func loadCatalog(for intent: CameraGalleryFilterIntent) async throws -> CameraGalleryCatalogSnapshot
}
