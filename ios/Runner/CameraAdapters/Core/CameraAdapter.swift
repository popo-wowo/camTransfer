import Foundation

struct CameraAdapterDescriptor: Equatable {
  let id: String
  let displayName: String
  let legalDisclaimer: String?
}

protocol CameraGallerySession: CameraVendorGalleryService,
  CameraVendorGalleryConnectionTerminating,
  CameraVendorGalleryDiagnosticReporting,
  CameraVendorGalleryConfigurable,
  CameraVendorGalleryReadySummaryProviding,
  CameraVendorReservedReceiveDiagnosticService {}

protocol CameraAdapter {
  var descriptor: CameraAdapterDescriptor { get }
  func makeGallerySession() -> CameraGallerySession
}
