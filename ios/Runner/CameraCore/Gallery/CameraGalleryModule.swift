import Foundation

struct IOSCameraGallerySession: Equatable {
  let cameraID: String
  let rememberedPeripheralID: UUID?
  let ptpSessionID: String
  let presentation: IOSCameraGalleryPresentation?

  init(
    cameraID: String,
    rememberedPeripheralID: UUID? = nil,
    ptpSessionID: String,
    presentation: IOSCameraGalleryPresentation? = nil
  ) {
    self.cameraID = cameraID
    self.rememberedPeripheralID = rememberedPeripheralID
    self.ptpSessionID = ptpSessionID
    self.presentation = presentation
  }
}

struct IOSCameraGalleryItem: Equatable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: Date?
  let byteSize: Int64?
  let orientation: Int?
  let thumbnailBytes: Data?
}
