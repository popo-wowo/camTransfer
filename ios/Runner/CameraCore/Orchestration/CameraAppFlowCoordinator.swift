import Foundation

struct IOSCameraAppFlowCoordinator {
  private let registrationGuard: () async -> IOSCameraRegistrationIssue
  private let pairingModule: IOSCameraPairingModule
  private let galleryConnector: (String) async throws -> IOSCameraConnectionContext

  init(
    registrationGuard: @escaping () async -> IOSCameraRegistrationIssue,
    pairingModule: IOSCameraPairingModule,
    galleryConnector: @escaping (String) async throws -> IOSCameraConnectionContext
  ) {
    self.registrationGuard = registrationGuard
    self.pairingModule = pairingModule
    self.galleryConnector = galleryConnector
  }

  func startPairing() async throws -> IOSCameraPairingResult {
    let issue = await registrationGuard()
    guard issue == .pass else {
      throw IOSCameraAppFlowIssue.registrationBlocked(issue)
    }
    return try await pairingModule.pair()
  }

  func enterCameraGallery(cameraID: String) async throws -> IOSCameraConnectionContext {
    let issue = await registrationGuard()
    guard issue == .pass else {
      throw IOSCameraAppFlowIssue.registrationBlocked(issue)
    }
    return try await galleryConnector(cameraID)
  }
}

enum IOSCameraAppFlowIssue: Error, Equatable {
  case registrationBlocked(IOSCameraRegistrationIssue)
}

