import Foundation

struct IOSCameraGallerySession: Equatable {
  let cameraID: String
  let rememberedPeripheralID: UUID?
  let ptpSessionID: String
  let presentation: IOSCameraGalleryPresentation?
  let fujifilmSession: FujifilmCameraSession?

  init(
    cameraID: String,
    rememberedPeripheralID: UUID? = nil,
    ptpSessionID: String,
    presentation: IOSCameraGalleryPresentation? = nil,
    fujifilmSession: FujifilmCameraSession? = nil
  ) {
    self.cameraID = cameraID
    self.rememberedPeripheralID = rememberedPeripheralID
    self.ptpSessionID = ptpSessionID
    self.presentation = presentation
    self.fujifilmSession = fujifilmSession
  }

  static func == (lhs: IOSCameraGallerySession, rhs: IOSCameraGallerySession) -> Bool {
    lhs.cameraID == rhs.cameraID
      && lhs.rememberedPeripheralID == rhs.rememberedPeripheralID
      && lhs.ptpSessionID == rhs.ptpSessionID
      && lhs.presentation == rhs.presentation
      && lhs.fujifilmSession === rhs.fujifilmSession
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
