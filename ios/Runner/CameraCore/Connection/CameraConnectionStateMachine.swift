import Foundation

final class IOSCameraConnectionStateMachine {
  private(set) var hasGalleryReadyEvidence = false

  func advance(
    from step: IOSCameraConnectionStep,
    with evidence: IOSCameraConnectionStepEvidence
  ) throws -> IOSCameraConnectionStep? {
    let decision = try decideAdvance(from: step, with: evidence)
    hasGalleryReadyEvidence = decision.hasGalleryReadyEvidence
    return decision.nextStep
  }

  func decideAdvance(
    from step: IOSCameraConnectionStep,
    with evidence: IOSCameraConnectionStepEvidence
  ) throws -> IOSCameraConnectionAdvanceDecision {
    switch (step, evidence) {
    case let (.reconnectPairedBle, .bleIdentityVerified(cameraID))
      where !cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .transferAuthorization, hasGalleryReadyEvidence: false)

    case (.transferAuthorization, .officialWifiCredential):
      return IOSCameraConnectionAdvanceDecision(nextStep: .activateCameraWifi, hasGalleryReadyEvidence: false)

    case (.activateCameraWifi, .cameraWifiActivationAcknowledged):
      return IOSCameraConnectionAdvanceDecision(nextStep: .waitCameraWifiReady, hasGalleryReadyEvidence: false)

    case (.waitCameraWifiReady, .cameraWifiReady):
      return IOSCameraConnectionAdvanceDecision(nextStep: .joinCameraWifi, hasGalleryReadyEvidence: false)

    case let (.joinCameraWifi, .joinedCameraWifi(ssid))
      where !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .connectPtp, hasGalleryReadyEvidence: false)

    case let (.connectPtp, .ptpConnected(session))
      where !session.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .confirmGalleryMode, hasGalleryReadyEvidence: false)

    case (.confirmGalleryMode, .galleryModeConfirmed):
      return IOSCameraConnectionAdvanceDecision(nextStep: .loadGallery, hasGalleryReadyEvidence: false)

    case let (.loadGallery, .galleryLoaded(evidence))
      where evidence.hasGalleryReadyEvidence:
      return IOSCameraConnectionAdvanceDecision(nextStep: nil, hasGalleryReadyEvidence: true)

    default:
      throw IOSCameraConnectionIssue(
        step: step,
        reason: "Missing required evidence for \(step.androidDisplayName)"
      )
    }
  }
}
