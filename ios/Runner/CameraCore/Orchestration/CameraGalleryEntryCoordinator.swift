import Foundation

final class IOSCameraGalleryEntryCoordinator {
  func validate(_ session: IOSCameraGallerySession) throws -> IOSCameraGallerySession {
    guard !session.ptpSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw NSError(
        domain: "IOSCameraGalleryEntryCoordinator",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "相机相册 PTP 会话尚未完成"]
      )
    }
    return session
  }
}
