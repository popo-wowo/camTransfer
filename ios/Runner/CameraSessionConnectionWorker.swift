import Foundation

@MainActor
protocol CameraSessionRuntimeConnectionFlow: AnyObject {
  var state: IOSCameraConnectFlowState { get }
  var navigationEvent: IOSCameraConnectFlowNavigationEvent? { get }
  func startPairing(camera: IOSCameraDiscoveredCamera) async throws
  func confirmPairing() async throws
  func enterRememberedGallery(record: IOSCameraRememberedCameraRecord) async throws
  func cancelActiveFlow()
}

extension IOSCameraConnectFlowRuntime: CameraSessionRuntimeConnectionFlow {}

/// The Runtime is the sole command boundary for the BLE/connect-flow bridge.
/// Home receives snapshots and logs from this adapter, but never calls the
/// bridge's Bluetooth or remembered-camera mutation APIs itself.
@MainActor
protocol CameraSessionRuntimeConnectionControlling: AnyObject {
  var onSnapshotChanged: ((IOSCameraHomeSnapshot) -> Void)? { get set }
  var onLogAppended: ((String) -> Void)? { get set }
  var currentLogText: String { get }
  var logFileURL: URL { get }
  var rememberedCameraRecords: [IOSCameraRememberedCameraRecord] { get }
  func snapshot() -> IOSCameraHomeSnapshot
  func clearLogs()
  func restoreLastPairedCameraIfAvailable() -> Bool
  func publishSystemBluetoothCleanupBlockIfNeeded() -> Bool
  func acknowledgeSystemBluetoothPairingCleanupForFreshPairing()
  func forgetLastPairedCamera()
  func forgetRememberedCamera(peripheralID: UUID)
  func startScan()
  func probePairing(peripheralID: UUID) async -> CameraVendorPairingProbeResult
  var hasPreconnectedProbe: Bool { get }
  var preconnectedProbePeripheralID: UUID? { get }
  func cancelPairingProbe(reason: String)
  func cancelPairingProbeAndWait(reason: String) async -> Bool
}

struct CameraSessionRuntimeGalleryPresentationPayload {
  let rememberedPeripheralID: UUID
  let summary: CameraVendorConnectionSummary
}

/// UIKit only routes this event.  The runtime has already selected the active
/// camera session and, for recovery, has already resumed its durable queue.
enum CameraSessionRuntimePresentationDestination {
  case gallery(CameraSessionRuntimeGalleryPresentationPayload)
  case recoveryDownloadCenter(CameraSessionRuntimeGalleryPresentationPayload)
  case home
}

enum CameraSessionRuntimeGalleryActivationError: LocalizedError {
  case missingGalleryNavigation
  case missingGallerySessionActivator
  case mismatchedRememberedCamera

  var errorDescription: String? {
    switch self {
    case .missingGalleryNavigation:
      return "相机相册连接尚未完成"
    case .missingGallerySessionActivator:
      return "相机相册会话不可用"
    case .mismatchedRememberedCamera:
      return "相机相册会话与已连接相机不一致"
    }
  }
}

@MainActor
protocol CameraSessionRuntimeGallerySessionActivating: AnyObject {
  func activateGallerySession(
    _ session: IOSCameraGallerySession,
    runtime: CameraSessionRuntime
  ) throws -> CameraSessionRuntimeGalleryPresentationPayload
}

/// Owns the connection Task for the whole runtime.  UIKit may render its result,
/// but it must never retain or cancel a second connection Task.
@MainActor
final class CameraSessionRuntimeConnectionWorker {
  private let flow: CameraSessionRuntimeConnectionFlow
  private var activeTask: Task<Void, Never>?
  private var activeTaskID: UUID?

  init(flow: CameraSessionRuntimeConnectionFlow) {
    self.flow = flow
  }

  var isActive: Bool { activeTask != nil }
  var state: IOSCameraConnectFlowState { flow.state }
  var navigationEvent: IOSCameraConnectFlowNavigationEvent? { flow.navigationEvent }

  func startPairing(
    camera: IOSCameraDiscoveredCamera,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    cancelActiveTaskForSupersedingConnection(reason: "superseded-by-fresh-pairing")
    run(completion: completion) { [flow] in
      try await flow.startPairing(camera: camera)
    }
  }

  func confirmPairing(completion: @escaping (Result<Void, Error>) -> Void) {
    guard activeTask == nil else { return }
    run(completion: completion) { [flow] in
      try await flow.confirmPairing()
    }
  }

  func enterRememberedGallery(
    record: IOSCameraRememberedCameraRecord,
    completion: @escaping (IOSCameraConnectFlowState) -> Void
  ) {
    cancelActiveTaskForSupersedingConnection(reason: "superseded-by-remembered-gallery")
    let taskID = UUID()
    activeTaskID = taskID
    activeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.clearTask(id: taskID) }
      do {
        try await self.flow.enterRememberedGallery(record: record)
        guard self.activeTaskID == taskID, !Task.isCancelled else { return }
        completion(self.flow.state)
      } catch is CancellationError {
        return
      } catch {
        guard self.activeTaskID == taskID else { return }
        completion(.failed(IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: error.localizedDescription)))
      }
    }
  }

  func cancel(reason: String) {
    CameraVendorFileLogger.log("[RUNTIME_CONNECTION_WORKER_CANCEL] reason=\(reason) active=\(activeTask != nil)")
    cancelTaskOnly()
    flow.cancelActiveFlow()
  }

  private func run(
    completion: @escaping (Result<Void, Error>) -> Void,
    operation: @escaping () async throws -> Void
  ) {
    let taskID = UUID()
    activeTaskID = taskID
    activeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.clearTask(id: taskID) }
      do {
        try await operation()
        guard self.activeTaskID == taskID, !Task.isCancelled else { return }
        completion(.success(()))
      } catch is CancellationError {
        return
      } catch {
        guard self.activeTaskID == taskID else { return }
        completion(.failure(error))
      }
    }
  }

  private func cancelTaskOnly() {
    activeTask?.cancel()
    activeTask = nil
    activeTaskID = nil
  }

  private func cancelActiveTaskForSupersedingConnection(reason: String) {
    guard activeTask != nil else { return }
    CameraVendorFileLogger.log("[RUNTIME_CONNECTION_WORKER_CANCEL] reason=\(reason) active=true")
    cancelTaskOnly()
    flow.cancelActiveFlow()
  }

  private func clearTask(id: UUID) {
    guard activeTaskID == id else { return }
    activeTask = nil
    activeTaskID = nil
  }
}
