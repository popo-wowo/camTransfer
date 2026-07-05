import Foundation

final class CameraVendorGalleryEntryCoordinator {
  private let startupCoordinator: CameraVendorGalleryStartupCoordinator

  init(startupCoordinator: CameraVendorGalleryStartupCoordinator = CameraVendorGalleryStartupCoordinator()) {
    self.startupCoordinator = startupCoordinator
  }

  func loadEntryEvidence(
    using galleryService: CameraVendorGalleryService
  ) async throws -> CameraVendorGalleryReadyEvidence {
    let evidence = try await startupCoordinator.loadGalleryReadyEvidence(using: galleryService)
    guard evidence.hasGalleryReadyEvidence else {
      throw NSError(
        domain: "CameraVendorGalleryEntryCoordinator",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "相机相册尚未返回可进入的照片列表"
        ]
      )
    }
    return evidence
  }
}
