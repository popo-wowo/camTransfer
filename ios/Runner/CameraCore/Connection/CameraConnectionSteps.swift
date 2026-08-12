import Foundation

enum IOSCameraConnectionStep: String, CaseIterable, Equatable, Hashable {
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
  case ptpTransportConnected
  case ptpInitAcknowledged
  case ptpSessionOpened
  case functionNegotiated
  case gallerySessionPrepared

  static let officialGalleryOrder: [IOSCameraConnectionStep] = [
    .reconnectPairedBle,
    .transferAuthorization,
    .activateCameraWifi,
    .waitCameraWifiReady,
    .joinCameraWifi,
    .ptpTransportConnected,
    .ptpInitAcknowledged,
    .ptpSessionOpened,
    .functionNegotiated,
    .gallerySessionPrepared,
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
    case .ptpTransportConnected:
      return "PtpTransportConnected"
    case .ptpInitAcknowledged:
      return "PtpInitAcknowledged"
    case .ptpSessionOpened:
      return "PtpSessionOpened"
    case .functionNegotiated:
      return "FunctionNegotiated"
    case .gallerySessionPrepared:
      return "GallerySessionPrepared"
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
  case ptpTransportConnected(host: String, port: Int)
  case ptpInitAcknowledged(
    strategy: PtpInitStrategyID,
    connectionNumber: UInt32?,
    transport: CameraPtpTransport
  )
  case ptpSessionOpened(sessionID: String)
  case functionNegotiated(
    planID: CameraConnectionPlanID,
    strategy: SessionNegotiationStrategyID
  )
  case gallerySessionPrepared(
    planID: CameraConnectionPlanID,
    strategy: GalleryBootstrapStrategyID
  )
}

struct CameraConnectionBarrierEvent: Equatable {
  let connectionSessionID: UUID
  let planVersion: CameraConnectionPlanVersion
  let step: IOSCameraConnectionStep
  let evidence: IOSCameraConnectionStepEvidence
}

enum CameraConnectionBarrierOutcome: String, Codable, Equatable {
  case began
  case succeeded
  case notRequired
  case failed
  case cancelled
}

struct CameraConnectionBarrierLifecycleEvent: Equatable {
  let connectionSessionID: UUID
  let planVersion: CameraConnectionPlanVersion
  let step: IOSCameraConnectionStep
  let outcome: CameraConnectionBarrierOutcome
}

struct CameraPlanRevisionSummary: Equatable {
  let fromVersion: CameraConnectionPlanVersion
  let toVersion: CameraConnectionPlanVersion
  let reason: CameraPlanRevisionReason
  let changedStages: [CameraConnectionPlanStage]
  let preservedLockedStages: [CameraConnectionPlanStage]
}

enum CameraConnectionPlanStage: String, Codable, Equatable, CaseIterable {
  case pairing
  case activation
  case ptpInit
  case openSession
  case negotiation
  case bootstrap
  case initialCatalog

  static func stage(for step: IOSCameraConnectionStep) -> CameraConnectionPlanStage? {
    switch step {
    case .reconnectPairedBle, .transferAuthorization:
      return .pairing
    case .activateCameraWifi, .waitCameraWifiReady, .joinCameraWifi:
      return .activation
    case .ptpTransportConnected, .ptpInitAcknowledged:
      return .ptpInit
    case .ptpSessionOpened:
      return .openSession
    case .functionNegotiated:
      return .negotiation
    case .gallerySessionPrepared:
      return .bootstrap
    default:
      return nil
    }
  }
}

struct IOSCameraConnectionAdvanceDecision: Equatable {
  let nextStep: IOSCameraConnectionStep?
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
  var compatibilityFacts: CameraCompatibilityFacts? = nil
  var connectionPlan: CameraConnectionPlan? = nil
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
    case .gallerySessionPrepared:
      return .galleryEntryWithBle
    case .ptpTransportConnected, .ptpInitAcknowledged, .ptpSessionOpened,
         .functionNegotiated, .registrationConsistencyCheck:
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
