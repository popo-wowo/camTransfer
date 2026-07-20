import Foundation

enum IOSCameraConnectFlowRuntimeError: Error {
  case missingPairingCamera
  case missingRememberedCamera
  case invalidRememberedPairing
}

extension IOSCameraConnectFlowRuntimeError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .missingPairingCamera:
      return "没有可用的配对相机"
    case .missingRememberedCamera:
      return "没有可用的已配对相机"
    case .invalidRememberedPairing:
      return "已配对记录缺少官方 Wi-Fi 配置，请重新配对"
    }
  }
}

@MainActor
protocol IOSCameraConnectFlowRuntimeEnvironment: AnyObject {
  func evaluateRegistrationIssue(
    intent: IOSCameraConnectFlowIntent,
    discoveredCamera: IOSCameraDiscoveredCamera?,
    rememberedRecord: IOSCameraRememberedCameraRecord?
  ) async -> IOSCameraRegistrationIssue
  func startPairing(camera: IOSCameraDiscoveredCamera) async throws
  func confirmPairing() async throws -> IOSCameraPairingResult
  func enterRememberedGallery(record: IOSCameraRememberedCameraRecord) async throws -> IOSCameraConnectionContext
  func loadGallerySession(
    from context: IOSCameraConnectionContext,
    publishStep: @escaping (IOSCameraConnectionStep) -> Void
  ) async throws -> IOSCameraGallerySession
  func cancelActiveFlow()
}

enum IOSCameraConnectFlowIntent {
  case freshPairing
  case pairingConfirmation
  case rememberedGallery
}

@MainActor
final class IOSCameraConnectFlowRuntime {
  private let environment: IOSCameraConnectFlowRuntimeEnvironment
  private var activeIntent: IOSCameraConnectFlowIntent = .freshPairing

  private lazy var coordinator: IOSCameraConnectFlowCoordinator = {
    IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { [unowned self] in
          await environment.evaluateRegistrationIssue(
            intent: activeIntent,
            discoveredCamera: activeDiscoveredCamera,
            rememberedRecord: activeRememberedRecord
          )
        },
        pairingModule: IOSCameraPairingModule(
          start: { [unowned self] in
            try await startPairingOperation()
          },
          confirm: { [unowned self] in
            try await environment.confirmPairing()
          }
        ),
        galleryConnector: { [unowned self] _ in
          try await enterRememberedGalleryOperation()
        }
      ),
      gallerySessionLoader: { [unowned self] context, publishStep in
        try await environment.loadGallerySession(from: context, publishStep: publishStep)
      }
    )
  }()

  private var activeDiscoveredCamera: IOSCameraDiscoveredCamera?
  private var activeRememberedRecord: IOSCameraRememberedCameraRecord?

  init(environment: IOSCameraConnectFlowRuntimeEnvironment) {
    self.environment = environment
  }

  var state: IOSCameraConnectFlowState {
    coordinator.state
  }

  var issue: IOSCameraConnectionIssue? {
    coordinator.issue
  }

  var retryTarget: IOSCameraConnectionRetryTarget? {
    coordinator.retryTarget
  }

  var navigationEvent: IOSCameraConnectFlowNavigationEvent? {
    coordinator.navigationEvent
  }

  func startPairing(camera: IOSCameraDiscoveredCamera) async throws {
    activeIntent = .freshPairing
    activeDiscoveredCamera = camera
    try await coordinator.startPairing()
  }

  func confirmPairing() async throws {
    activeIntent = .pairingConfirmation
    try await coordinator.confirmPairing()
  }

  func enterRememberedGallery(record: IOSCameraRememberedCameraRecord) async throws {
    activeIntent = .rememberedGallery
    activeRememberedRecord = record
    try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
  }

  func cancelActiveFlow() {
    activeIntent = .freshPairing
    activeDiscoveredCamera = nil
    activeRememberedRecord = nil
    environment.cancelActiveFlow()
    coordinator.resetConnection()
  }

  private func startPairingOperation() async throws {
    guard let activeDiscoveredCamera else {
      throw IOSCameraConnectFlowRuntimeError.missingPairingCamera
    }
    try await environment.startPairing(camera: activeDiscoveredCamera)
  }

  private func enterRememberedGalleryOperation() async throws -> IOSCameraConnectionContext {
    guard let activeRememberedRecord else {
      throw IOSCameraConnectFlowRuntimeError.missingRememberedCamera
    }
    return try await environment.enterRememberedGallery(record: activeRememberedRecord)
  }
}
