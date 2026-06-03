import Foundation

struct FujifilmCameraAdapter: CameraAdapter {
  let profile: FujifilmXSeriesProfile

  let descriptor = CameraAdapterDescriptor(
    id: "fujifilm-x-series",
    displayName: "FUJIFILM X Series",
    legalDisclaimer: "FUJIFILM is a trademark of FUJIFILM Corporation. This app is not affiliated with or endorsed by FUJIFILM Corporation."
  )

  func makeGallerySession() -> CameraGallerySession {
    CameraVendorRealtimeGalleryService()
  }
}
