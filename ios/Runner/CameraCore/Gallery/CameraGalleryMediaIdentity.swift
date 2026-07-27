import Foundation

struct CameraGalleryCatalogIdentity: Hashable, Sendable {
  let cameraID: String
  let sessionEpoch: UUID
  let generation: CameraGalleryGenerationID
  let snapshotID: CameraGallerySnapshotID
}

enum CameraGalleryMediaVariant: Hashable, Sendable {
  case thumbnail
  case hdPreview
}

struct CameraGalleryMediaIdentity: Hashable, Sendable {
  let catalog: CameraGalleryCatalogIdentity
  let handle: Int
  let variant: CameraGalleryMediaVariant
}

struct CameraGalleryMediaCacheKey: Hashable, Sendable {
  let sessionEpoch: UUID
  let handle: Int
  let variant: CameraGalleryMediaVariant

  init(
    sessionEpoch: UUID,
    handle: Int,
    variant: CameraGalleryMediaVariant
  ) {
    self.sessionEpoch = sessionEpoch
    self.handle = handle
    self.variant = variant
  }

  init(mediaIdentity: CameraGalleryMediaIdentity) {
    self.init(
      sessionEpoch: mediaIdentity.catalog.sessionEpoch,
      handle: mediaIdentity.handle,
      variant: mediaIdentity.variant
    )
  }
}
