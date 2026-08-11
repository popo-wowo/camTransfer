import Foundation

struct IOSCameraGalleryDestination {
  let rememberedPeripheralID: UUID
  let summary: CameraVendorConnectionSummary
  let galleryService: CameraGalleryTransportSession
  let bluetoothKeepAliveService: CameraVendorBleBackgroundKeepAlive
  let fujifilmSession: FujifilmCameraSession
}

final class CameraVendorRememberedGalleryAttempt {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<CameraVendorConnectionSummary, Error>?
  private var terminalResult: Result<CameraVendorConnectionSummary, Error>?
  private var didBeginWait = false

  func wait(
    start: (@escaping (IOSCameraConnectionIssue) -> Void) -> Bool
  ) async throws -> CameraVendorConnectionSummary {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      precondition(!didBeginWait, "Remembered gallery attempt may wait only once")
      didBeginWait = true
      if let terminalResult {
        lock.unlock()
        continuation.resume(with: terminalResult)
        return
      }
      self.continuation = continuation
      lock.unlock()

      let started = start { [weak self] issue in
        self?.fail(issue)
      }
      if !started {
        fail(
          IOSCameraConnectionIssue(
            step: .reconnectPairedBle,
            reason: "Remembered gallery flow could not start"
          )
        )
      }
    }
  }

  func succeed(_ summary: CameraVendorConnectionSummary) {
    finish(.success(summary))
  }

  func fail(_ error: Error) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<CameraVendorConnectionSummary, Error>) {
    let continuation: CheckedContinuation<CameraVendorConnectionSummary, Error>? = lock.withLock {
      guard terminalResult == nil else { return nil }
      terminalResult = result
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }
}

/// Runtime-owned adapter from a completed connect flow to the one active PTP
/// transport. Home constructs this dependency but never invokes it.
@MainActor
final class CameraVendorRuntimeGallerySessionActivator: CameraSessionRuntimeGallerySessionActivating {
  private let bridge: CameraVendorConnectFlowBridge
  private let deferredTransport: CameraSessionRuntimeDeferredTransport
  private let deferredBackgroundMaintainer: CameraSessionRuntimeDeferredBackgroundMaintainer

  init(
    bridge: CameraVendorConnectFlowBridge,
    deferredTransport: CameraSessionRuntimeDeferredTransport,
    deferredBackgroundMaintainer: CameraSessionRuntimeDeferredBackgroundMaintainer
  ) {
    self.bridge = bridge
    self.deferredTransport = deferredTransport
    self.deferredBackgroundMaintainer = deferredBackgroundMaintainer
    deferredTransport.attachUnboundTerminationHandler { [weak bridge] reason in
      bridge?.disconnectActiveCameraSession(reason: reason)
    }
  }

  func activateGallerySession(
    _ session: IOSCameraGallerySession,
    runtime: CameraSessionRuntime
  ) throws -> CameraSessionRuntimeGalleryPresentationPayload {
    guard let rememberedPeripheralID = session.rememberedPeripheralID,
          let destination = bridge.consumeGalleryDestination(for: rememberedPeripheralID),
          destination.rememberedPeripheralID == rememberedPeripheralID else {
      throw IOSCameraConnectFlowRuntimeError.invalidRememberedPairing
    }
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: destination.galleryService,
      fujifilmSession: destination.fujifilmSession,
      fileSaver: CameraSessionRuntimePhotoLibraryFileSaver(),
      diagnosticHandler: { CameraVendorGalleryDiagnostics.log($0) },
      onRuntimeTermination: { [weak bridge] in
        bridge?.finishRuntimeCameraTermination()
      }
    )
    runtime.installFujifilmCameraSession(destination.fujifilmSession)
    let binding = runtime.beginTransportBinding(
      identity: CameraSessionIdentity(
        cameraName: destination.summary.navigationTitle,
        peripheralID: rememberedPeripheralID,
        historyKey: destination.summary.serialNumber.isEmpty
          ? destination.summary.deviceName
          : destination.summary.serialNumber
      )
    )
    transport.bind(to: runtime, binding: binding)
    transport.onThumbnailGenerated = { [weak runtime] handle, image in
      runtime?.onDownloadThumbnailGenerated?(handle, image)
    }
    deferredTransport.attach(transport, binding: binding)
    deferredBackgroundMaintainer.attach(
      CameraVendorSessionRuntimeBackgroundMaintainer(
        galleryService: destination.galleryService,
        bluetoothKeepAlive: destination.bluetoothKeepAliveService,
        backgroundActivitySource: destination.bluetoothKeepAliveService as? CameraVendorBackgroundActivityObserving
      ),
      binding: binding
    )
    return CameraSessionRuntimeGalleryPresentationPayload(
      rememberedPeripheralID: rememberedPeripheralID,
      summary: destination.summary
    )
  }
}

@MainActor
final class CameraVendorConnectFlowBridge: NSObject, IOSCameraConnectFlowRuntimeEnvironment {
  private let service: CameraVendorBluetoothService
  private let galleryService: CameraGalleryTransportSession
  private let galleryRuntimeService: CameraVendorRealtimeGalleryService
  private lazy var gallerySessionLoader = CameraVendorGalleryMainlineSessionLoader(
    galleryService: galleryRuntimeService
  )
  private var pendingPairingConfirmation: CheckedContinuation<IOSCameraPairingResult, Error>?
  private var pendingGalleryConnection: CameraVendorRememberedGalleryAttempt?
  private var pendingPairingPeripheralID: UUID?
  private var pendingGalleryPeripheralID: UUID?
  private var activeGalleryDestinationByPeripheralID: [UUID: IOSCameraGalleryDestination] = [:]

  var onSnapshotChanged: ((IOSCameraHomeSnapshot) -> Void)?
  var onLogAppended: ((String) -> Void)?

  init(
    service: CameraVendorBluetoothService = CameraVendorBluetoothService(),
    galleryService: CameraGalleryTransportSession = NativeCameraAdapterRegistry.defaultAdapter.makeGallerySession()
  ) {
    guard let galleryRuntimeService = galleryService as? CameraVendorRealtimeGalleryService else {
      fatalError("CameraVendorConnectFlowBridge requires CameraVendorRealtimeGalleryService")
    }
    self.service = service
    self.galleryService = galleryService
    self.galleryRuntimeService = galleryRuntimeService
    super.init()
    self.service.delegate = self
  }

  var currentLogText: String {
    service.currentLogText
  }

  var logFileURL: URL {
    service.logFileURL
  }

  var rememberedCameraRecords: [IOSCameraRememberedCameraRecord] {
    serviceRememberedCameras()
  }

  func clearLogs() {
    service.clearLogs()
  }

  func forgetLastPairedCamera() {
    service.forgetLastPairedCamera()
    publishSnapshot()
  }

  func snapshot() -> IOSCameraHomeSnapshot {
    IOSCameraHomeSnapshot(
      discoveredCameras: serviceDiscoveredCameras(),
      rememberedCameras: serviceRememberedCameras(),
      status: latestStatus,
      isBusy: latestIsBusy,
      requiresSystemBluetoothPairingCleanup: service.requiresSystemBluetoothPairingCleanup
    )
  }

  func restoreLastPairedCameraIfAvailable() -> Bool {
    let restored = service.restoreLastPairedCameraIfAvailable()
    publishSnapshot()
    return restored
  }

  func publishSystemBluetoothCleanupBlockIfNeeded() -> Bool {
    let blocked = service.publishSystemBluetoothCleanupBlockIfNeeded()
    publishSnapshot()
    return blocked
  }

  func acknowledgeSystemBluetoothPairingCleanupForFreshPairing() {
    service.acknowledgeSystemBluetoothPairingCleanupForFreshPairing()
    publishSnapshot()
  }

  func forgetRememberedCamera(peripheralID: UUID) {
    service.forgetPairedCamera(peripheralID: peripheralID)
    publishSnapshot()
  }

  func startScan() {
    service.startScan()
  }

  func isRememberedCamera(_ camera: IOSCameraDiscoveredCamera) -> Bool {
    service.rememberedCameraRecords.contains { $0.peripheralID == camera.id }
  }

  // MARK: - Pairing Probe

  func probePairing(peripheralID: UUID) async -> CameraVendorPairingProbeResult {
    await service.probePairing(peripheralID: peripheralID)
  }

  var hasPreconnectedProbe: Bool {
    service.hasPreconnectedProbe
  }

  var preconnectedProbePeripheralID: UUID? {
    service.preconnectedProbePeripheralID
  }

  func cancelPairingProbe(reason: String) {
    service.cancelPairingProbe(reason: reason)
  }

  func consumeGalleryDestination(for peripheralID: UUID) -> IOSCameraGalleryDestination? {
    activeGalleryDestinationByPeripheralID.removeValue(forKey: peripheralID)
  }

  func evaluateRegistrationIssue(
    intent: IOSCameraConnectFlowIntent,
    discoveredCamera: IOSCameraDiscoveredCamera?,
    rememberedRecord: IOSCameraRememberedCameraRecord?
  ) async -> IOSCameraRegistrationIssue {
    if service.requiresSystemBluetoothPairingCleanup {
      let blockedAddress = rememberedRecord?.identity.bleEndpoint.address
        ?? rememberedRecord?.identity.bleEndpoint.identifier
        ?? discoveredCamera?.id.uuidString.uppercased()
        ?? "UNKNOWN"
      return .needsSystemBondCleanup(address: blockedAddress)
    }

    switch intent {
    case .freshPairing, .pairingConfirmation:
      return .pass
    case .rememberedGallery:
      guard let rememberedRecord else {
        return .pass
      }
      guard rememberedRecord.wifiCredential != nil else {
        return .needsRePairing(cameraID: rememberedRecord.identity.cameraID)
      }
      return .pass
    }
  }

  func startPairing(camera: IOSCameraDiscoveredCamera) async throws {
    pendingPairingPeripheralID = camera.id
    service.startFreshPairingConnection(cameraID: camera.id)
  }

  func confirmPairing() async throws -> IOSCameraPairingResult {
    try await withCheckedThrowingContinuation { continuation in
      pendingPairingConfirmation = continuation
      service.confirmPendingPairing()
    }
  }

  func enterRememberedGallery(record: IOSCameraRememberedCameraRecord) async throws -> IOSCameraConnectionContext {
    let pairingRecord = record.wifiCredential.map {
      IOSCameraPairingRecord(identity: record.identity, wifiCredential: $0)
    }
    return IOSCameraConnectionContext(
      cameraID: record.identity.cameraID,
      pairingRecord: pairingRecord,
      wifiCredential: record.wifiCredential,
      ptpSessionID: nil,
      rememberedPeripheralID: record.peripheralID,
      compatibilityFacts: service.rememberedCompatibilityFacts(
        peripheralID: record.peripheralID
      )
    )
  }

  func loadGallerySession(
    from context: IOSCameraConnectionContext,
    publishStep: @escaping (IOSCameraConnectionStep) -> Void
  ) async throws -> IOSCameraGallerySession {
    guard let rememberedPeripheralID = context.rememberedPeripheralID else {
      throw IOSCameraConnectFlowRuntimeError.invalidRememberedPairing
    }
    let galleryLoadResult = try await gallerySessionLoader.loadGallerySession(
      context: context,
      publishStep: publishStep,
      performBleConnection: { [weak self] activationResolver in
        guard let self else { throw CancellationError() }
        return try await self.performRememberedBluetoothConnection(
          peripheralID: rememberedPeripheralID,
          activationResolver: activationResolver
        )
      },
      compatibilityLabReset: { [weak self] _ in
        guard let self else { return .failed }
        guard await self.galleryRuntimeService.terminateCameraCommunicationAndWait(
          reason: "compatibility-lab-full-connection-reset"
        ) == .succeeded else { return .failed }
        return await self.service.resetWirelessCameraFlowAndWait()
      }
    )
    let summary = galleryLoadResult.connectionSummary
    let gallerySessionPreparedSummary = galleryService.gallerySessionPreparedConnectionSummary(
      from: summary,
      confirmedSteps: galleryLoadResult.confirmedSteps
    )
    let session = IOSCameraGallerySession(
      cameraID: context.cameraID,
      rememberedPeripheralID: rememberedPeripheralID,
      ptpSessionID: galleryLoadResult.ptpSessionID,
      presentation: IOSCameraGalleryPresentation(
        deviceName: gallerySessionPreparedSummary.deviceName,
        serialNumber: gallerySessionPreparedSummary.serialNumber,
        connectedDeviceName: gallerySessionPreparedSummary.connectedDeviceName,
        preferCompressedDownloads: gallerySessionPreparedSummary.preferCompressedDownloads
      ),
      fujifilmSession: galleryLoadResult.fujifilmSession
    )
    activeGalleryDestinationByPeripheralID[rememberedPeripheralID] = IOSCameraGalleryDestination(
      rememberedPeripheralID: rememberedPeripheralID,
      summary: gallerySessionPreparedSummary,
      galleryService: galleryService,
      bluetoothKeepAliveService: service,
      fujifilmSession: galleryLoadResult.fujifilmSession
    )
    return session
  }

  private func performRememberedBluetoothConnection(
    peripheralID: UUID,
    activationResolver: @escaping (
      CameraCompatibilityFacts
    ) throws -> ActivationStrategyDefinition
  ) async throws -> CameraVendorConnectionSummary {
    let attempt = CameraVendorRememberedGalleryAttempt()
    pendingGalleryPeripheralID = peripheralID
    pendingGalleryConnection = attempt
    defer {
      if pendingGalleryConnection === attempt {
        pendingGalleryConnection = nil
        pendingGalleryPeripheralID = nil
      }
    }
    return try await attempt.wait { [weak self] fail in
      guard let self else { return false }
      return self.service.startRememberedCameraConnection(
        peripheralID: peripheralID,
        activationResolver: activationResolver,
        onRememberedGalleryFailure: fail
      )
    }
  }

  func cancelActiveFlow() {
    if let pendingPairingConfirmation {
      self.pendingPairingConfirmation = nil
      pendingPairingConfirmation.resume(throwing: CancellationError())
    }
    if let pendingGalleryConnection {
      self.pendingGalleryConnection = nil
      pendingGalleryConnection.fail(CancellationError())
    }
    pendingPairingPeripheralID = nil
    pendingGalleryPeripheralID = nil
    service.resetWirelessCameraFlow()
    publishSnapshot()
  }

  func disconnectActiveCameraSession(reason: String) {
    if let pendingPairingConfirmation {
      self.pendingPairingConfirmation = nil
      pendingPairingConfirmation.resume(throwing: CancellationError())
    }
    if let pendingGalleryConnection {
      self.pendingGalleryConnection = nil
      pendingGalleryConnection.fail(CancellationError())
    }
    pendingPairingPeripheralID = nil
    pendingGalleryPeripheralID = nil
    activeGalleryDestinationByPeripheralID.removeAll()
    galleryRuntimeService.terminateCameraCommunication(reason: reason)
    service.resetWirelessCameraFlow()
    publishSnapshot()
  }

  /// Runtime has already terminated the PTP session.  This performs only the
  /// paired BLE/connect-flow cleanup so Home never bypasses runtime ownership.
  func finishRuntimeCameraTermination() {
    pendingPairingPeripheralID = nil
    pendingGalleryPeripheralID = nil
    activeGalleryDestinationByPeripheralID.removeAll()
    service.resetWirelessCameraFlow()
    publishSnapshot()
  }

  private var latestStatus = ""
  private var latestIsBusy = false
  private var currentDiscoveredVendorCameras: [CameraVendorDiscoveredCamera] = []

  private func serviceDiscoveredCameras() -> [IOSCameraDiscoveredCamera] {
    serviceDiscoveredVendorCameras().map {
      IOSCameraDiscoveredCamera(id: $0.id, displayName: $0.name, rssi: $0.rssi)
    }
  }

  private func serviceRememberedCameras() -> [IOSCameraRememberedCameraRecord] {
    service.rememberedCameraRecords.map(makeCoreRememberedCameraRecord(from:))
  }

  private func serviceDiscoveredVendorCameras() -> [CameraVendorDiscoveredCamera] {
    currentDiscoveredVendorCameras
  }

  private func publishSnapshot() {
    onSnapshotChanged?(snapshot())
  }

  private func makeCoreRememberedCameraRecord(
    from record: CameraVendorPairedCameraRecord
  ) -> IOSCameraRememberedCameraRecord {
    let wifiCredential = IOSCameraWifiCredential.official(
      ssid: record.preferredWifiNetwork?.ssid,
      passphrase: record.preferredWifiNetwork?.passphrase,
      bssid: record.preferredWifiNetwork?.bssid,
      source: .bleHandshake
    )
    let cameraID = [
      record.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines),
      record.deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
    ].filter { !$0.isEmpty }.joined(separator: "_")
    return IOSCameraRememberedCameraRecord(
      peripheralID: record.peripheralID,
      identity: IOSCameraIdentity(
        cameraID: cameraID.isEmpty ? record.peripheralID.uuidString.uppercased() : cameraID,
        displayName: record.deviceName,
        serialNumber: record.serialNumber,
        bleEndpoint: IOSCameraBleEndpoint(
          identifier: record.peripheralID.uuidString.uppercased(),
          address: nil
        )
      ),
      wifiCredential: wifiCredential,
      connectedDeviceName: record.connectedDeviceName,
      systemBluetoothPairingValidatedAt: record.systemBluetoothPairingValidatedAt
    )
  }

}

extension CameraVendorConnectFlowBridge: CameraSessionRuntimeConnectionControlling {}

extension CameraVendorConnectFlowBridge: CameraVendorBluetoothServiceDelegate {
  nonisolated func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateStatus status: String,
    isBusy: Bool
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.latestStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latestIsBusy = isBusy
        self.publishSnapshot()
      }
    }
  }

  nonisolated func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateDiscoveredCameras cameras: [CameraVendorDiscoveredCamera]
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.currentDiscoveredVendorCameras = cameras
        self.publishSnapshot()
      }
    }
  }

  nonisolated func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didAppendLog message: String
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.onLogAppended?(message)
      }
    }
  }

  nonisolated func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompletePairing summary: CameraVendorConnectionSummary
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        let rememberedRecords = self.service.rememberedCameraRecords
        guard let continuation = self.pendingPairingConfirmation,
              let pendingPairingPeripheralID = self.pendingPairingPeripheralID,
              let record = rememberedRecords.first(where: { $0.peripheralID == pendingPairingPeripheralID }) else {
          return
        }
        self.pendingPairingConfirmation = nil
        self.pendingPairingPeripheralID = nil
        let coreRecord = self.makeCoreRememberedCameraRecord(from: record)
        guard let wifiCredential = coreRecord.wifiCredential else {
          continuation.resume(throwing: IOSCameraConnectFlowRuntimeError.invalidRememberedPairing)
          return
        }
        continuation.resume(
          returning: IOSCameraPairingResult(
            record: IOSCameraPairingRecord(
              identity: coreRecord.identity,
              wifiCredential: wifiCredential
            )
          )
        )
        _ = summary
        self.publishSnapshot()
      }
    }
  }

  nonisolated func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompleteHandshake summary: CameraVendorConnectionSummary
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      MainActor.assumeIsolated {
        let rememberedRecords = self.service.rememberedCameraRecords
        guard let attempt = self.pendingGalleryConnection,
              let pendingGalleryPeripheralID = self.pendingGalleryPeripheralID,
              let record = rememberedRecords.first(where: { $0.peripheralID == pendingGalleryPeripheralID }) else {
          return
        }
        self.pendingGalleryConnection = nil
        self.pendingGalleryPeripheralID = nil
        guard self.makeCoreRememberedCameraRecord(from: record).wifiCredential != nil else {
          attempt.fail(IOSCameraConnectFlowRuntimeError.invalidRememberedPairing)
          return
        }
        attempt.succeed(summary)
        self.publishSnapshot()
      }
    }
  }
}
