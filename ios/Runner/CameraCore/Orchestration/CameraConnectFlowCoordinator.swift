import Foundation

enum IOSCameraConnectFlowState: Equatable {
  case idle
  case waitingForPairingConfirmation
  case paired(IOSCameraPairingRecord)
  case connecting(IOSCameraConnectionStep)
  case galleryReady(IOSCameraGallerySession)
  case failed(IOSCameraConnectionIssue)
}

enum IOSCameraConnectFlowNavigationEvent: Equatable {
  case enterGallery(IOSCameraGallerySession)
}

final class IOSCameraConnectFlowCoordinator {
  private let appFlow: IOSCameraAppFlowCoordinator
  private let gallerySessionLoader: (
    IOSCameraConnectionContext,
    @escaping (IOSCameraConnectionStep) -> Void
  ) async throws -> IOSCameraGallerySession
  private var activeConnectionStep: IOSCameraConnectionStep?

  private(set) var state: IOSCameraConnectFlowState = .idle
  private(set) var issue: IOSCameraConnectionIssue?
  private(set) var retryTarget: IOSCameraConnectionRetryTarget?
  private(set) var navigationEvent: IOSCameraConnectFlowNavigationEvent?

  init(
    appFlow: IOSCameraAppFlowCoordinator,
    gallerySessionLoader: @escaping (
      IOSCameraConnectionContext,
      @escaping (IOSCameraConnectionStep) -> Void
    ) async throws -> IOSCameraGallerySession
  ) {
    self.appFlow = appFlow
    self.gallerySessionLoader = gallerySessionLoader
  }

  func startPairing() async throws {
    resetTransientState()
    try await appFlow.startPairing()
    state = .waitingForPairingConfirmation
  }

  func confirmPairing() async throws {
    resetTransientState()
    let result = try await appFlow.confirmPairing()
    state = .paired(result.record)
  }

  func enterRememberedGallery(cameraID: String) async throws {
    resetTransientState()
    publishConnectionStep(.reconnectPairedBle)
    var didEnterGalleryLoader = false
    do {
      let context = try await appFlow.enterCameraGallery(cameraID: cameraID)
      didEnterGalleryLoader = true
      let session = try await gallerySessionLoader(context) { [weak self] step in
        self?.publishConnectionStep(step)
      }
      activeConnectionStep = nil
      state = .galleryReady(session)
      navigationEvent = .enterGallery(session)
    } catch {
      let fallbackStep: IOSCameraConnectionStep
      if didEnterGalleryLoader, activeConnectionStep == .reconnectPairedBle {
        fallbackStep = .loadGallery
      } else {
        fallbackStep = activeConnectionStep ?? .reconnectPairedBle
      }
      let flowIssue = mapIssue(error, fallbackStep: fallbackStep)
      activeConnectionStep = nil
      issue = flowIssue
      retryTarget = flowIssue.retryTarget
      state = .failed(flowIssue)
    }
  }

  func resetConnection() {
    state = .idle
    resetTransientState()
  }

  private func resetTransientState() {
    activeConnectionStep = nil
    issue = nil
    retryTarget = nil
    navigationEvent = nil
  }

  private func publishConnectionStep(_ step: IOSCameraConnectionStep) {
    activeConnectionStep = step
    state = .connecting(step)
  }

  private func mapIssue(
    _ error: Error,
    fallbackStep: IOSCameraConnectionStep
  ) -> IOSCameraConnectionIssue {
    if let issue = error as? IOSCameraConnectionIssue {
      return issue
    }

    if let appFlowIssue = error as? IOSCameraAppFlowIssue {
      switch appFlowIssue {
      case .registrationBlocked(let registrationIssue):
        return IOSCameraConnectionIssue(
          step: .registrationConsistencyCheck,
          reason: registrationFailureReason(for: registrationIssue),
          action: .resetConnection,
          retryTarget: .resetConnection
        )
      }
    }

    if let runtimeError = error as? IOSCameraConnectFlowRuntimeError {
      switch runtimeError {
      case .missingPairingCamera, .missingRememberedCamera:
        return IOSCameraConnectionIssue(
          step: .reconnectPairedBle,
          reason: runtimeError.localizedDescription
        )
      case .invalidRememberedPairing:
        return IOSCameraConnectionIssue(
          step: .transferAuthorization,
          reason: runtimeError.localizedDescription
        )
      }
    }

    let description = (error as? LocalizedError)?.errorDescription
      ?? (error as NSError).localizedDescription
    return IOSCameraConnectionIssue(
      step: fallbackStep,
      reason: description
    )
  }

  private func registrationFailureReason(for issue: IOSCameraRegistrationIssue) -> String {
    switch issue {
    case .pass:
      return "Registration guard reported pass unexpectedly"
    case .needsSystemBondCleanup(let address):
      return "System Bluetooth pairing cleanup required for \(address)"
    case .needsRePairing(let cameraID):
      return "Stored pairing is stale and must be recreated for \(cameraID)"
    }
  }
}
