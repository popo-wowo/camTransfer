import Foundation

enum IOSCameraRememberedGalleryEntryDecision: Equatable {
  case blockedByCleanup
  case ignoreUntilUserApproval
  case ignoreBecauseInFlight
  case failMissingOfficialWifiRecord
  case proceed
}

enum IOSCameraRememberedGalleryEntryGate {
  static func evaluate(
    hasSystemCleanupBlock: Bool,
    hasUserApproval: Bool,
    hasInFlightAttempt: Bool,
    hasOfficialWifiRecord: Bool
  ) -> IOSCameraRememberedGalleryEntryDecision {
    if hasSystemCleanupBlock {
      return .blockedByCleanup
    }
    if !hasUserApproval {
      return .ignoreUntilUserApproval
    }
    if hasInFlightAttempt {
      return .ignoreBecauseInFlight
    }
    if !hasOfficialWifiRecord {
      return .failMissingOfficialWifiRecord
    }
    return .proceed
  }
}

enum IOSCameraHandshakeCompletionReason: Equatable {
  case gallery
}

enum IOSCameraHandshakeCompletionDecision: Equatable {
  case wait
  case startTransferActivation
  case failActivationNotReady
  case complete(IOSCameraHandshakeCompletionReason)
}

enum IOSCameraHandshakeCompletionGate {
  static func evaluate(
    didCompleteHandshake: Bool,
    isRunningPostHandshakeProbe: Bool,
    isRunningTransferActivation: Bool,
    hasCompletedPairing: Bool,
    hasUserInitiatedTransfer: Bool,
    hasPendingHandshakeSummary: Bool,
    hasAttemptedAutomaticTransferActivation: Bool,
    transferActivationObservedChange: Bool,
    transferActivationObservedWifiLaunch: Bool,
    hadAutomaticTransferActivationFeature: Bool
  ) -> IOSCameraHandshakeCompletionDecision {
    guard !didCompleteHandshake,
          !isRunningPostHandshakeProbe,
          hasPendingHandshakeSummary,
          IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
            hasCompletedPairing: hasCompletedPairing,
            hasUserInitiatedTransfer: hasUserInitiatedTransfer
          ) else {
      return .wait
    }

    if !hasAttemptedAutomaticTransferActivation {
      return .startTransferActivation
    }

    if isRunningTransferActivation {
      return .wait
    }

    guard hasAttemptedAutomaticTransferActivation,
          hadAutomaticTransferActivationFeature,
          transferActivationObservedChange else {
      return .failActivationNotReady
    }

    return .complete(.gallery)
  }
}
