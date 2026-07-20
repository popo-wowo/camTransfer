import Foundation

enum IOSCameraRememberedConnectionStartDecision: Equatable {
  case blockedByCleanup
  case beginMainline(orderDescription: String)
}

enum IOSCameraRememberedConnectionAttemptDecision: Equatable {
  case blockedByCleanup
  case waitForUserApproval
  case ignoreBecauseInFlight
  case failMissingOfficialWifiRecord
  case proceed(shouldAttemptAutoReconnect: Bool)
}

enum IOSCameraRememberedConnectionFlowDriver {
  static func startRememberedConnection(
    cleanupBlocked: Bool,
    order: [IOSCameraConnectionStep]
  ) -> IOSCameraRememberedConnectionStartDecision {
    guard !cleanupBlocked else {
      return .blockedByCleanup
    }

    let orderDescription = order
      .map(\.androidDisplayName)
      .joined(separator: " -> ")
    return .beginMainline(orderDescription: orderDescription)
  }

  static func connectPairedCamera(
    record: IOSCameraRememberedCameraRecord,
    cleanupBlocked: Bool,
    hasUserApproval: Bool,
    hasInFlightAttempt: Bool,
    hasOfficialWifiRecord: Bool,
    centralPoweredOn: Bool
  ) -> IOSCameraRememberedConnectionAttemptDecision {
    let entryDecision = IOSCameraRememberedGalleryEntryGate.evaluate(
      hasSystemCleanupBlock: cleanupBlocked,
      hasUserApproval: hasUserApproval,
      hasInFlightAttempt: hasInFlightAttempt,
      hasOfficialWifiRecord: hasOfficialWifiRecord
    )

    switch entryDecision {
    case .blockedByCleanup:
      return .blockedByCleanup
    case .ignoreUntilUserApproval:
      return .waitForUserApproval
    case .ignoreBecauseInFlight:
      return .ignoreBecauseInFlight
    case .failMissingOfficialWifiRecord:
      return .failMissingOfficialWifiRecord
    case .proceed:
      return .proceed(shouldAttemptAutoReconnect: centralPoweredOn)
    }
  }
}
