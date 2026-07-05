import Foundation

enum IOSCameraConnectionStep: String, CaseIterable, Equatable {
  case reconnectPairedBle
  case transferAuthorization
  case activateCameraWifi
  case waitCameraWifiReady
  case joinCameraWifi
  case connectPtp
  case confirmGalleryMode
  case loadGallery

  static let officialGalleryOrder: [IOSCameraConnectionStep] = [
    .reconnectPairedBle,
    .transferAuthorization,
    .activateCameraWifi,
    .waitCameraWifiReady,
    .joinCameraWifi,
    .connectPtp,
    .confirmGalleryMode,
    .loadGallery,
  ]

  var androidDisplayName: String {
    switch self {
    case .reconnectPairedBle:
      return "ReconnectPairedBle"
    case .transferAuthorization:
      return "TransferAuthorization"
    case .activateCameraWifi:
      return "ActivateCameraWifi"
    case .waitCameraWifiReady:
      return "WaitCameraWifiReady"
    case .joinCameraWifi:
      return "JoinCameraWifi"
    case .connectPtp:
      return "ConnectPtp"
    case .confirmGalleryMode:
      return "ConfirmGalleryMode"
    case .loadGallery:
      return "LoadGallery"
    }
  }
}

struct IOSCameraConnectionContext: Equatable {
  let cameraID: String
  var pairingRecord: IOSCameraPairingRecord?
  var wifiCredential: IOSCameraWifiCredential?
  var ptpSessionID: String?
}

struct IOSCameraConnectionIssue: Error, Equatable {
  let step: IOSCameraConnectionStep
  let reason: String
}

struct IOSCameraConnectionStepRunner {
  let step: IOSCameraConnectionStep
  private let runBlock: (IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext

  init(
    step: IOSCameraConnectionStep,
    run: @escaping (IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext
  ) {
    self.step = step
    self.runBlock = run
  }

  func run(context: IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext {
    try await runBlock(context)
  }
}
