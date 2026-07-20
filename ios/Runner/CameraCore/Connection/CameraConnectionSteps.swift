import Foundation

enum IOSCameraConnectionStep: String, CaseIterable, Equatable {
  case environmentCheck
  case staleBondCheck
  case registrationConsistencyCheck
  case cameraPairingMode
  case bleScan
  case bleHandshake
  case pairingConfirmation
  case savePairing
  case existingPtpProbe
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

  static func officialGalleryOrderPrefix(through step: IOSCameraConnectionStep) -> [IOSCameraConnectionStep] {
    guard let index = officialGalleryOrder.firstIndex(of: step) else {
      return []
    }
    return Array(officialGalleryOrder[...index])
  }

  var androidDisplayName: String {
    switch self {
    case .environmentCheck:
      return "EnvironmentCheck"
    case .staleBondCheck:
      return "StaleBondCheck"
    case .registrationConsistencyCheck:
      return "RegistrationConsistencyCheck"
    case .cameraPairingMode:
      return "CameraPairingMode"
    case .bleScan:
      return "BleScan"
    case .bleHandshake:
      return "BleHandshake"
    case .pairingConfirmation:
      return "PairingConfirmation"
    case .savePairing:
      return "SavePairing"
    case .existingPtpProbe:
      return "ExistingPtpProbe"
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

enum IOSCameraConnectionAction: Equatable {
  case retryStep
  case restartPairing
  case resetConnection
  case confirmCameraReady
  case confirmWifiJoined
  case enterGallery
}

enum IOSCameraConnectionRetryTarget: Equatable {
  case pairingConfirmation
  case wifiHandoffWithoutBle
  case existingPtpProbe
  case pairingScan
  case pairingModeConfirmation
  case galleryEntryWithBle
  case resetConnection
}

enum IOSCameraConnectionStepEvidence: Equatable {
  case bleIdentityVerified(cameraID: String)
  case officialWifiCredential(IOSCameraWifiCredential)
  case cameraWifiActivationAcknowledged
  case cameraWifiReady
  case joinedCameraWifi(ssid: String)
  case ptpConnected(IOSCameraPtpSessionEvidence)
  case galleryModeConfirmed
  case galleryLoaded(IOSCameraGalleryReadyEvidence)
}

struct IOSCameraConnectionAdvanceDecision: Equatable {
  let nextStep: IOSCameraConnectionStep?
  let hasGalleryReadyEvidence: Bool
}

struct IOSCameraConnectionStepExecution: Equatable {
  let context: IOSCameraConnectionContext
  let evidence: IOSCameraConnectionStepEvidence
}

struct IOSCameraConnectionContext: Equatable {
  let cameraID: String
  var pairingRecord: IOSCameraPairingRecord?
  var wifiCredential: IOSCameraWifiCredential?
  var ptpSessionID: String?
  var presentation: IOSCameraGalleryPresentation?
  var rememberedPeripheralID: UUID? = nil
}

struct IOSCameraConnectionIssue: Error, Equatable {
  let step: IOSCameraConnectionStep
  let reason: String
  let action: IOSCameraConnectionAction
  let retryTarget: IOSCameraConnectionRetryTarget

  init(
    step: IOSCameraConnectionStep,
    reason: String,
    action: IOSCameraConnectionAction = .retryStep,
    retryTarget: IOSCameraConnectionRetryTarget? = nil
  ) {
    self.step = step
    self.reason = reason
    self.action = action
    self.retryTarget = retryTarget ?? IOSCameraConnectionRetryPolicy.target(for: step)
  }
}

extension IOSCameraConnectionIssue: LocalizedError {
  var errorDescription: String? {
    "\(step.androidDisplayName): \(reason)"
  }
}

enum IOSCameraConnectionRetryPolicy {
  static func target(for step: IOSCameraConnectionStep?) -> IOSCameraConnectionRetryTarget {
    switch step {
    case .pairingConfirmation:
      return .pairingConfirmation
    case .joinCameraWifi:
      return .wifiHandoffWithoutBle
    case .loadGallery:
      return .galleryEntryWithBle
    case .connectPtp, .registrationConsistencyCheck:
      return .resetConnection
    case .staleBondCheck, .bleScan, .bleHandshake, .environmentCheck, nil:
      return .pairingScan
    case .cameraPairingMode:
      return .pairingModeConfirmation
    default:
      return .galleryEntryWithBle
    }
  }
}

struct IOSCameraConnectionStepRunner {
  let step: IOSCameraConnectionStep
  private let runBlock: (IOSCameraConnectionContext) async throws -> IOSCameraConnectionStepExecution

  init(
    step: IOSCameraConnectionStep,
    run: @escaping (IOSCameraConnectionContext) async throws -> IOSCameraConnectionStepExecution
  ) {
    self.step = step
    self.runBlock = run
  }

  func run(context: IOSCameraConnectionContext) async throws -> IOSCameraConnectionStepExecution {
    try await runBlock(context)
  }
}
