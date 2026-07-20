import Foundation

enum IOSCameraServiceWirelessIntent: Equatable {
  case idle
  case freshPairing
  case rememberedGallery
}

enum IOSCameraPairingConfirmationDecision: Equatable {
  case completeImmediately
  case waitForCameraAck
  case rejectUntilReady
}

enum IOSCameraPhoneConfirmationRoute: Equatable {
  case reconnectBeforeCompletion
  case completePairing
}

enum IOSCameraIdentifierWriteRoute: Equatable {
  case waitForPhoneConfirmation
  case completeFreshPairing
  case beginRememberedGalleryMainline
  case failRememberedGalleryRequiresRepair
}

enum IOSCameraPairingConfirmationFlowDriver {
  static func canFinishPairing(
    hasWrittenIdentifier: Bool,
    hasUserConfirmedCameraSuccess: Bool
  ) -> Bool {
    hasWrittenIdentifier && hasUserConfirmedCameraSuccess
  }

  static func canCompleteQueuedPhoneConfirmation(
    hasWrittenIdentifier: Bool,
    hasPendingHandshakeSummary: Bool,
    hasQueuedPhoneConfirmation: Bool
  ) -> Bool {
    hasQueuedPhoneConfirmation && hasWrittenIdentifier && hasPendingHandshakeSummary
  }

  static func confirmPairingSucceeded(
    hasWrittenIdentifier: Bool,
    hasPendingHandshakeSummary: Bool
  ) -> IOSCameraPairingConfirmationDecision {
    if canCompleteQueuedPhoneConfirmation(
      hasWrittenIdentifier: hasWrittenIdentifier,
      hasPendingHandshakeSummary: hasPendingHandshakeSummary,
      hasQueuedPhoneConfirmation: true
    ) {
      return .completeImmediately
    }

    return .waitForCameraAck
  }

  static func routeAfterPhoneConfirmation(
    hasWrittenIdentifier: Bool,
    hasPendingHandshakeSummary: Bool,
    shouldBypassManualConfirmation: Bool
  ) -> IOSCameraPhoneConfirmationRoute {
    if hasWrittenIdentifier && hasPendingHandshakeSummary && !shouldBypassManualConfirmation {
      return .reconnectBeforeCompletion
    }

    return .completePairing
  }

  static func routeAfterIdentifierWrite(
    intent: IOSCameraServiceWirelessIntent,
    shouldBypassManualConfirmation: Bool
  ) -> IOSCameraIdentifierWriteRoute {
    if intent == .rememberedGallery {
      return shouldBypassManualConfirmation
        ? .beginRememberedGalleryMainline
        : .failRememberedGalleryRequiresRepair
    }

    if !shouldBypassManualConfirmation {
      return .waitForPhoneConfirmation
    }

    return .completeFreshPairing
  }
}
