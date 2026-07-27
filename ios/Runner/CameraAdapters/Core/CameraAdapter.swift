import Foundation

struct CameraAdapterDescriptor: Equatable {
  let id: String
  let displayName: String
  let legalDisclaimer: String?
}

protocol CameraGalleryTransportSession: CameraVendorGalleryService,
  CameraVendorGalleryConnectionTerminating,
  CameraVendorGalleryDiagnosticReporting,
  CameraVendorGalleryConfigurable,
  CameraVendorGalleryReadySummaryProviding,
  CameraVendorReservedReceiveDiagnosticService {}

protocol CameraAdapter {
  var descriptor: CameraAdapterDescriptor { get }
  func makeGallerySession() -> CameraGalleryTransportSession
}
