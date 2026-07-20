import Foundation

enum IOSCameraTransferStartDecision: Equatable {
  case blockedNotPaired
  case alreadyReady
  case missingPeripheral
  case disconnectedPeripheral
  case beginPreparation
}

struct IOSCameraHandshakeCompletionContext {
  let didCompleteHandshake: Bool
  let isRunningPostHandshakeProbe: Bool
  let isRunningTransferActivation: Bool
  let hasCompletedPairing: Bool
  let hasUserInitiatedTransfer: Bool
  let hasPendingHandshakeSummary: Bool
  let hasAttemptedAutomaticTransferActivation: Bool
  let transferActivationObservedChange: Bool
  let transferActivationObservedWifiLaunch: Bool
  let hadAutomaticTransferActivationFeature: Bool
  let availableCharacteristicUUIDStrings: Set<String>
  let availableTransferStrategies: [IOSCameraTransferActivationStrategy]
  let hasSelectedPeripheral: Bool
}

enum IOSCameraHandshakeCompletionAction: Equatable {
  case wait
  case complete(IOSCameraHandshakeCompletionReason)
  case beginTransferActivation(
    strategies: [IOSCameraTransferActivationStrategy],
    availableCharacteristicUUIDStrings: [String]
  )
  case failMissingActivationFeature(availableCharacteristicUUIDStrings: [String])
  case failActivationNotReady
}

enum IOSCameraPeripheralConnectionState: Equatable {
  case connected
  case disconnected
}

enum IOSCameraTransferFlowDriver {
  static func canBeginRememberedGalleryEntry(
    hasCompletedPairing: Bool,
    hasUserInitiatedTransfer: Bool
  ) -> Bool {
    hasCompletedPairing && hasUserInitiatedTransfer
  }

  static func startTransfer(
    hasCompletedPairing: Bool,
    didCompleteHandshake: Bool,
    peripheralState: IOSCameraPeripheralConnectionState?
  ) -> IOSCameraTransferStartDecision {
    guard canBeginRememberedGalleryEntry(
      hasCompletedPairing: hasCompletedPairing,
      hasUserInitiatedTransfer: true
    ) else {
      return .blockedNotPaired
    }

    guard !didCompleteHandshake else {
      return .alreadyReady
    }

    guard let peripheralState else {
      return .missingPeripheral
    }

    guard peripheralState == .connected else {
      return .disconnectedPeripheral
    }

    return .beginPreparation
  }

  static func handshakeCompletionAction(
    context: IOSCameraHandshakeCompletionContext
  ) -> IOSCameraHandshakeCompletionAction {
    let decision = IOSCameraHandshakeCompletionGate.evaluate(
      didCompleteHandshake: context.didCompleteHandshake,
      isRunningPostHandshakeProbe: context.isRunningPostHandshakeProbe,
      isRunningTransferActivation: context.isRunningTransferActivation,
      hasCompletedPairing: context.hasCompletedPairing,
      hasUserInitiatedTransfer: context.hasUserInitiatedTransfer,
      hasPendingHandshakeSummary: context.hasPendingHandshakeSummary,
      hasAttemptedAutomaticTransferActivation: context.hasAttemptedAutomaticTransferActivation,
      transferActivationObservedChange: context.transferActivationObservedChange,
      transferActivationObservedWifiLaunch: context.transferActivationObservedWifiLaunch,
      hadAutomaticTransferActivationFeature: context.hadAutomaticTransferActivationFeature
    )

    switch decision {
    case .wait:
      return .wait
    case .complete(let reason):
      return .complete(reason)
    case .startTransferActivation:
      let availableCharacteristicUUIDStrings = context.availableCharacteristicUUIDStrings
        .sorted()
      let strategies = context.hasSelectedPeripheral ? context.availableTransferStrategies : []
      if strategies.isEmpty {
        return .failMissingActivationFeature(
          availableCharacteristicUUIDStrings: availableCharacteristicUUIDStrings
        )
      }
      return .beginTransferActivation(
        strategies: strategies,
        availableCharacteristicUUIDStrings: availableCharacteristicUUIDStrings
      )
    case .failActivationNotReady:
      return .failActivationNotReady
    }
  }
}
