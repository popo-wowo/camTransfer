import Darwin
import Foundation


enum CameraVendorPtpOperationTransport {
  case standardPtpIp
  case cameraVendorLegacy
}

enum CameraPtpFramingFailure: Equatable {
  case legacyPacketLength(UInt32)
  case responseTransactionMismatch(expected: UInt32, actual: UInt32)
  case packetBoundaryUnknown

  var invalidatesPhysicalSession: Bool {
    switch self {
    case .legacyPacketLength, .responseTransactionMismatch, .packetBoundaryUnknown:
      true
    }
  }
}

enum CameraVendorPtpSessionPurpose {
  case gallery
  case reservedReceiveDiagnostic
}

enum CameraVendorPtpStrategyDispatcher {
  static func validatePtpInitStrategy(_ strategy: PtpInitStrategyID) throws {
    _ = try ptpInitDefinition(for: strategy)
  }

  static func ptpInitDefinition(
    for strategy: PtpInitStrategyID,
    environment: FujifilmCompatibilityEnvironment = .production
  ) throws -> PtpInitStrategyDefinition {
    try environment.strategyRegistry.ptpInitDefinition(for: strategy)
  }

  static func validateSessionNegotiationStrategy(
    _ strategy: SessionNegotiationStrategyID
  ) throws {
    _ = try sessionNegotiationDefinition(for: strategy)
  }

  static func sessionNegotiationDefinition(
    for strategy: SessionNegotiationStrategyID,
    environment: FujifilmCompatibilityEnvironment = .production
  ) throws -> SessionNegotiationStrategyDefinition {
    try environment.strategyRegistry.sessionNegotiationDefinition(
      for: strategy
    )
  }

  static func validateGalleryBootstrapStrategy(
    _ strategy: GalleryBootstrapStrategyID
  ) throws {
    _ = try galleryBootstrapDefinition(for: strategy)
  }

  static func galleryBootstrapDefinition(
    for strategy: GalleryBootstrapStrategyID,
    environment: FujifilmCompatibilityEnvironment = .production
  ) throws -> GalleryBootstrapStrategyDefinition {
    try environment.strategyRegistry.galleryBootstrapDefinition(
      for: strategy
    )
  }
}

enum FujifilmSessionNegotiationStrategyExecutor {
  static func execute(
    definition: SessionNegotiationStrategyDefinition,
    performNotRequired: () throws -> Void
  ) rethrows {
    switch definition.action {
    case .notRequired:
      try performNotRequired()
    }
  }
}

enum FujifilmGalleryBootstrapStrategyExecutorError: Swift.Error, Equatable {
  case completionPredicateNotSatisfied(
    strategyID: GalleryBootstrapStrategyID,
    predicate: GalleryBootstrapCompletionPredicate
  )
}

enum FujifilmGalleryBootstrapStrategyExecutor {
  enum CompletionEvidence: Equatable {
    case legacyReferenceAppGalleryModeConfirmed

    func satisfies(_ predicate: GalleryBootstrapCompletionPredicate) -> Bool {
      switch (self, predicate) {
      case (.legacyReferenceAppGalleryModeConfirmed, .legacyReferenceAppGalleryModeConfirmed):
        return true
      case (.legacyReferenceAppGalleryModeConfirmed, .standardGalleryHandshakeCompleted):
        return false
      }
    }
  }

  static func execute(
    definition: GalleryBootstrapStrategyDefinition,
    performCurrentLegacyReferenceAppGalleryMode: () throws -> Void
  ) throws -> CompletionEvidence {
    let evidence: CompletionEvidence
    switch definition.action {
    case .currentLegacyReferenceAppGalleryMode:
      try performCurrentLegacyReferenceAppGalleryMode()
      evidence = .legacyReferenceAppGalleryModeConfirmed
    }
    guard evidence.satisfies(definition.completionPredicate) else {
      throw FujifilmGalleryBootstrapStrategyExecutorError.completionPredicateNotSatisfied(
        strategyID: definition.id,
        predicate: definition.completionPredicate
      )
    }
    return evidence
  }
}

struct CameraVendorSpecifiedObjectSnapshot {
  let declaredCount: UInt32?
  let dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  let handles: [UInt32]
}

enum CameraVendorReferenceAppFunctionVersionPolicy {
  static let fallbackRemotePhotoViewExVersion: UInt32 = 3

  static func versionToWrite(from data: Data) -> UInt32 {
    fallbackRemotePhotoViewExVersion
  }
}

enum CameraVendorReferenceAppRemoteImageViewerPolicy {
  static let cameraStateRemoteAccess: UInt32 = 6
  static let remoteModeClientState: UInt32 = 5
  static let referenceAppRemoteImageViewerClientState: UInt32 = 20
  static let remoteGetObjectVersionToWrite: UInt32 = 5
}

enum CameraVendorReferenceAppReservedReceiveProbePolicy {
  static let shouldProbeDuringGalleryHandshake = false
  static let shouldUseSeparatePtpSession = true
  static let shouldExposeManualDiagnosticEntry = false
  static let reservedReceiveClientState: UInt32 = 21
  static let reservedReceiveVersionToWrite: UInt32 = 3
  static let reservedObjectHandle: UInt32 = 1
  static let sampleReadBytes = CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
}


struct CameraVendorThumbnailFetchResult {
  let data: Data
  let objectInfo: CameraVendorCameraObjectInfo?
}

struct CameraVendorPreviewImageFetchResult {
  let data: Data
  let objectInfo: CameraVendorCameraObjectInfo
}

enum CameraVendorThumbnailResultPolicy {
  static func result(
    data: Data,
    primedObjectInfo: CameraVendorCameraObjectInfo?
  ) throws -> CameraVendorThumbnailFetchResult {
    guard let primedObjectInfo else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [
          NSLocalizedDescriptionKey: "GetThumb completed without matching ObjectInfo context"
        ]
      )
    }
    return CameraVendorThumbnailFetchResult(data: data, objectInfo: primedObjectInfo)
  }
}

struct CameraVendorCameraObjectInfo: Equatable {
  static let undefinedFormatCode: UInt16 = 0x3000

  let handle: Int
  let storageID: UInt32
  let formatCode: UInt16
  let compressedSize: UInt32
  let thumbCompressedSize: UInt32
  let filename: String
  let captureDate: String
  let orientation: Int?

  init(
    handle: Int,
    storageID: UInt32,
    formatCode: UInt16,
    compressedSize: UInt32,
    thumbCompressedSize: UInt32,
    filename: String,
    captureDate: String,
    orientation: Int? = nil
  ) {
    self.handle = handle
    self.storageID = storageID
    self.formatCode = formatCode
    self.compressedSize = compressedSize
    self.thumbCompressedSize = thumbCompressedSize
    self.filename = filename
    self.captureDate = captureDate
    self.orientation = orientation
  }

  var hasResolvedFormat: Bool {
    formatCode != 0 && formatCode != Self.undefinedFormatCode
  }

  var galleryFormatLabel: String {
    hasResolvedFormat ? formatLabel : ""
  }

  var reliableDownloadMetadata: CameraVendorCameraObjectInfo? {
    guard hasResolvedFormat,
          hasResolvedDownloadFilename else {
      return nil
    }
    return self
  }

  func mergingMissingDownloadMetadata(
    from cached: CameraVendorCameraObjectInfo?
  ) -> CameraVendorCameraObjectInfo {
    guard let cached, cached.handle == handle else { return self }
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID == 0 ? cached.storageID : storageID,
      formatCode: hasResolvedFormat ? formatCode : cached.formatCode,
      compressedSize: compressedSize == 0 ? cached.compressedSize : compressedSize,
      thumbCompressedSize: thumbCompressedSize == 0 ? cached.thumbCompressedSize : thumbCompressedSize,
      filename: hasResolvedDownloadFilename ? filename : cached.filename,
      captureDate: captureDate.isEmpty ? cached.captureDate : captureDate,
      orientation: orientation ?? cached.orientation
    )
  }

  private var hasResolvedDownloadFilename: Bool {
    !filename.isEmpty && !filename.hasPrefix("0x")
  }

  var formatLabel: String {
    switch formatCode {
    case 0x3801:
      return "JPG"
    case CameraVendorWirelessRealFileFormat.heif:
      return "HEIF"
    case 0xB101, 0xB103:
      return "RAW"
    case 0x300B, 0x300D:
      return "Video"
    default:
      return String(format: "0x%04X", formatCode)
    }
  }

  static func placeholder(handle: UInt32, captureDate: String = "") -> CameraVendorCameraObjectInfo {
    CameraVendorCameraObjectInfo(
      handle: Int(handle),
      storageID: 0,
      formatCode: undefinedFormatCode,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: String(format: "0x%08X", handle),
      captureDate: captureDate,
      orientation: nil
    )
  }
}

struct CameraVendorObjectInfoCache {
  private var storage: [Int: CameraVendorCameraObjectInfo] = [:]

  subscript(handle: Int) -> CameraVendorCameraObjectInfo? {
    storage[handle]
  }

  mutating func store(_ info: CameraVendorCameraObjectInfo) {
    storage[info.handle] = info
  }

  mutating func resetForPhysicalSession() {
    storage.removeAll(keepingCapacity: true)
  }
}

/// Returns the IPv4 address of the WiFi (en0) interface, or nil.
func getWifiIPv4Address() -> String? {
  var ifaddr: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
  defer { freeifaddrs(ifaddr) }
  for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
    let name = String(cString: ptr.pointee.ifa_name)
    guard name == "en0",
          ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
      return String(cString: hostname)
    }
  }
  return nil
}


final class CameraVendorPtpDownloadCancellation {
  private let lock = NSLock()
  private var generation: UInt64 = 0

  func snapshot() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  func request() {
    lock.lock()
    generation += 1
    lock.unlock()
  }

  func wasRequested(since snapshot: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation != snapshot
  }
}

final class CameraVendorPtpSession {
  private let commandSocket = CameraVendorPtpSocket()
  private let eventSocket = CameraVendorPtpSocket()
  private let originalTransferWorker = CameraVendorOriginalTransferWorker()
  private let lifecycleLock = NSLock()
  private var connectionNumber: UInt32 = 0
  private var transactionID: UInt32 = 0
  private var isConnected = false
  private var transportStateMachine = CameraPtpTransportStateMachine(generation: 0)
  private var transferCapabilitySerialNumber: String?
  private let originalTransferCapabilityStore = CameraVendorOriginalTransferCapabilityStore()
  private let activeDownloadCancellation = CameraVendorPtpDownloadCancellation()
  var isSessionConnected: Bool {
    isConnected
  }

  var requiresCommandTransportRecovery: Bool {
    if case .terminal = transportStateMachine.state { return true }
    return false
  }

  func beginTransportOperation(_ operation: CameraPtpTransportOperation) throws {
    _ = try transportStateMachine.begin(operation: operation)
  }

  func finishTransportOperation() {
    if case .executing = transportStateMachine.state {
      let generation: UInt64
      switch transportStateMachine.state {
      case let .executing(current, _): generation = current
      default: return
      }
      transportStateMachine = CameraPtpTransportStateMachine(generation: generation)
    }
  }

  private var physicalSessionSequence: UInt64 = 0

  #if DEBUG
  var physicalSessionID: String? {
    guard isConnected else { return nil }
    return "\(connectedHost)-\(connectionNumber)-\(physicalSessionSequence)"
  }

  private var debugPhysicalSessionLabel: String {
    return physicalSessionID ?? "none"
  }
  #endif

  #if !DEBUG
  private var debugPhysicalSessionLabel: String { "none" }
  #endif

  func configureTransferProfile(cameraSerialNumber: String?) {
    transferCapabilitySerialNumber = cameraSerialNumber
  }

  /// Binds the single session-scoped media operation contract produced from
  /// the current compatibility facts.  The session keeps the aggregate
  /// definition; individual catalog/download/thumbnail callers never resolve
  /// capabilities independently.
  func configureMediaOperations(_ definition: FujifilmMediaOperationDefinition) {
    mediaOperationDefinition = definition
    catalogSearchModeStrategy = definition.searchMode
  }

  func setPriorityDownloadReconnectClientIP(_ clientIP: String?) {
    priorityDownloadReconnectClientIP = clientIP
  }
  private var operationTransport: CameraVendorPtpOperationTransport = .standardPtpIp
  private var diagnosticHandler: ((String) -> Void)?
  private var connectedHost = CameraVendorPtpConstants.defaultHost
  private var connectedClientName = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
  private var priorityDownloadReconnectClientIP: String?
  private var connectedPurpose: CameraVendorPtpSessionPurpose = .gallery
  private var priorityDownloadInterruptionGeneration: UInt64 = 0
  private var transferModeCoordinator = CameraVendorTransferModeCoordinator()
  private let networkServiceProfile: CameraVendorPtpNetworkServiceProfile = {
    #if DEBUG
    return CameraVendorDebugPtpNetworkServicePolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .current
    #endif
  }()
  private let socketBufferProfile: CameraVendorPtpSocketBufferProfile = {
    #if DEBUG
    return CameraVendorDebugPtpSocketBufferPolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .kernelAutotuning
    #endif
  }()
  private let tcpNoDelayPolicy: CameraVendorPtpTcpNoDelayPolicy = {
    #if DEBUG
    return CameraVendorDebugPtpTcpNoDelayPolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .enabled
    #endif
  }()
  private var cameraVendorSpecifiedObjectHandles: [UInt32] = []
  private var cameraVendorSpecifiedObjectDateGroups: [CameraVendorSpecifiedObjectDateGroup] = []
  private var cameraVendorSpecifiedObjectHandlesByFormatMask: [UInt16: [UInt32]] = [:]
  private var catalogSearchModeStrategy: CameraVendorCatalogSearchModeStrategy = .backupAndRestore
  private var mediaOperationDefinition: FujifilmMediaOperationDefinition?
  private var cameraVendorCurrentSlotStatus: UInt8?
  private var didConfirmGalleryMode = false
  private var didPrepareLegacyGalleryLoad = false
  private var boundPtpInitDefinition: PtpInitStrategyDefinition?
  private var boundNegotiationDefinition: SessionNegotiationStrategyDefinition?
  private var boundGalleryBootstrapDefinition: GalleryBootstrapStrategyDefinition?
  private var boundConnectionPlanID: CameraConnectionPlanID?

  private func invalidatePhysicalSessionForFramingFailure(
    _ failure: CameraPtpFramingFailure = .packetBoundaryUnknown
  ) {
    guard failure.invalidatesPhysicalSession else { return }
    transportStateMachine.failFraming(reason: transportFailure(from: failure))
    commandSocket.close()
    eventSocket.close()
    isConnected = false
    didConfirmGalleryMode = false
    didPrepareLegacyGalleryLoad = false
    transferModeCoordinator.invalidate()
  }

  var hasExplicitGalleryModeEvidence: Bool {
    didConfirmGalleryMode
  }

  func connectTransportAndOpenSession(
    host: String = CameraVendorPtpConstants.defaultHost,
    clientName: String = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName,
    clientIP: String? = nil,
    commandConnectTimeout: TimeInterval = CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
    diagnosticHandler: ((String) -> Void)? = nil,
    purpose: CameraVendorPtpSessionPurpose = .gallery,
    ptpInitDefinition: PtpInitStrategyDefinition,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws {
    let ptpInitStrategy = ptpInitDefinition.id
    _ = try FujifilmProtocolStrategyRegistry(ptpInitDefinitions: [ptpInitDefinition])
    boundPtpInitDefinition = ptpInitDefinition
    boundNegotiationDefinition = nil
    boundGalleryBootstrapDefinition = nil
    boundConnectionPlanID = nil

    disconnect()
    transportStateMachine = CameraPtpTransportStateMachine(generation: physicalSessionSequence + 1)
    transactionID = 0
    didConfirmGalleryMode = false
    didPrepareLegacyGalleryLoad = false
    cameraVendorSpecifiedObjectHandles = []
    cameraVendorSpecifiedObjectDateGroups = []
    cameraVendorSpecifiedObjectHandlesByFormatMask = [:]
    self.diagnosticHandler = diagnosticHandler

    report("准备连接 PTP 命令端口 \(host):\(CameraVendorPtpConstants.commandPort)")
    report("[OBS] PTP_CONNECT_START host=\(host) port=\(CameraVendorPtpConstants.commandPort) clientName=\(clientName)")
    connectedHost = host
    connectedClientName = clientName
    connectedPurpose = purpose
    try commandSocket.connect(
      host: host,
      port: CameraVendorPtpConstants.commandPort,
      timeout: commandConnectTimeout,
      diagnosticHandler: diagnosticHandler,
      networkServiceProfile: networkServiceProfile,
      socketBufferProfile: socketBufferProfile,
      tcpNoDelayPolicy: tcpNoDelayPolicy
    )
    try progressHandler?(
      .ptpTransportConnected,
      .ptpTransportConnected(host: host, port: CameraVendorPtpConstants.commandPort)
    )
    let initResult = try performInitHandshake(
      host: host,
      clientName: clientName,
      strategy: ptpInitDefinition,
      clientIP: clientIP
    )
    connectionNumber = initResult.connectionNumber
    operationTransport = initResult.operationTransport
    report("收到 PTP INIT_COMMAND_ACK，连接号 \(connectionNumber)")
    report("[OBS] PTP_INIT_ACK direction=cameraToApp connectionNumber=\(connectionNumber) transport=\(operationTransport == .cameraVendorLegacy ? "cameraVendorLegacy" : "standard")")
    report("PTP 命令格式: \(operationTransport == .cameraVendorLegacy ? "CameraVendor legacy" : "standard PTP/IP")")
    try progressHandler?(
      .ptpInitAcknowledged,
      .ptpInitAcknowledged(
        strategy: ptpInitStrategy,
        connectionNumber: connectionNumber,
        transport: operationTransport == .cameraVendorLegacy ? .cameraVendorLegacy : .standardPtpIp
      )
    )

    // CameraVendor does NOT use standard InitEventRequest before OpenSession.
    // NewCameraVendorInitEventRequestPacket returns nil in the Go implementation.
    // The event port (55741) only becomes available after InitiateOpenCapture.

    report("打开 PTP Session")
    _ = try sendCommand(
      operationCode: UInt16(CameraVendorPtpOperationCode.openSession),
      parameters: [1]
    )
    report("PTP Session 已打开")
    report("[OBS] PTP_OPEN_SESSION_OK")
    try progressHandler?(
      .ptpSessionOpened,
      .ptpSessionOpened(sessionID: "\(connectedClientName)-ptp")
    )

    isConnected = true
    #if DEBUG
    physicalSessionSequence &+= 1
    #endif
    report("PTP transport and OpenSession complete, purpose=\(purpose)")
  }

  private func transportFailure(from failure: CameraPtpFramingFailure) -> CameraPtpTransportFailure {
    switch failure {
    case let .legacyPacketLength(length):
      return .invalidPacketLength(length)
    case let .responseTransactionMismatch(expected, actual):
      return .transactionMismatch(expected: expected, actual: actual)
    case .packetBoundaryUnknown:
      return .invalidPacketLength(0)
    }
  }

  func negotiateGalleryFunction(
    definition: SessionNegotiationStrategyDefinition,
    connectionPlanID: CameraConnectionPlanID?,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws {
    guard isConnected else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorNotConnectedToInternet,
        userInfo: [NSLocalizedDescriptionKey: "Function negotiation requires an open PTP session"]
      )
    }
    try FujifilmSessionNegotiationStrategyExecutor.execute(
      definition: definition,
      performNotRequired: {
      report("[OBS] PTP_FUNCTION_NEGOTIATION strategy=\(definition.id.rawValue)")
      if let connectionPlanID {
        try progressHandler?(
          .functionNegotiated,
          .functionNegotiated(planID: connectionPlanID, strategy: definition.id)
        )
      }
      }
    )
    boundNegotiationDefinition = definition
    boundConnectionPlanID = connectionPlanID
  }

  func prepareGallerySession(
    definition: GalleryBootstrapStrategyDefinition,
    connectionPlanID: CameraConnectionPlanID?,
    progressHandler: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil
  ) throws {
    guard isConnected else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorNotConnectedToInternet,
        userInfo: [NSLocalizedDescriptionKey: "Gallery bootstrap requires an open PTP session"]
      )
    }
    switch (operationTransport, connectedPurpose) {
    case (.cameraVendorLegacy, .gallery):
      let completionEvidence = try FujifilmGalleryBootstrapStrategyExecutor.execute(
        definition: definition,
        performCurrentLegacyReferenceAppGalleryMode: {
          try confirmCameraVendorLegacyReferenceAppGalleryMode()
        }
      )
      if let connectionPlanID {
        try progressHandler?(
          .gallerySessionPrepared,
          .gallerySessionPrepared(
            planID: connectionPlanID,
            strategy: definition.id
          )
        )
      }
      didConfirmGalleryMode = completionEvidence.satisfies(definition.completionPredicate)
      boundGalleryBootstrapDefinition = definition
      boundConnectionPlanID = connectionPlanID
    case (.cameraVendorLegacy, .reservedReceiveDiagnostic):
      try performCameraVendorReservedReceiveDiagnosticHandshake()
    case (.standardPtpIp, .gallery):
      try performStandardGalleryHandshake()
      didConfirmGalleryMode = true
    case (.standardPtpIp, .reservedReceiveDiagnostic):
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState),
        userInfo: [NSLocalizedDescriptionKey: "Reserved Receive 诊断需要 CameraVendor legacy PTP 连接"]
      )
    }
    report("PTP 连接完成，purpose=\(connectedPurpose)")
    report("[OBS] PTP_HANDSHAKE_OK purpose=\(connectedPurpose)")
  }

  func interruptInFlightOperationForPriorityDownload() {
    guard CameraVendorThumbnailLoadPolicy.shouldInterruptInFlightRequestBeforeDownload else { return }
    guard isConnected else { return }
    priorityDownloadInterruptionGeneration += 1
    report("[OBS] PTP_PRIORITY_DOWNLOAD_INTERRUPT_IN_FLIGHT_REQUEST")
    guard CameraVendorThumbnailLoadPolicy.shouldClosePtpSocketForPriorityDownloadInterruption else {
      report("[OBS] PTP_PRIORITY_DOWNLOAD_SOCKET_CLOSE_SKIPPED")
      return
    }
    commandSocket.close()
    eventSocket.close()
    isConnected = false
    transferModeCoordinator.invalidate()
  }

  func invalidateInFlightOperationForPriorityDownload(reason: String) {
    guard isConnected else { return }
    priorityDownloadInterruptionGeneration += 1
    report("[OBS] PTP_PRIORITY_DOWNLOAD_INVALIDATE_IN_FLIGHT_REQUEST reason=\(reason)")
    commandSocket.close()
    eventSocket.close()
    isConnected = false
    transferModeCoordinator.invalidate()
  }

  func requestActiveDownloadCancellation(reason: String) {
    activeDownloadCancellation.request()
    report(
      "[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCELLATION_REQUESTED reason=\(reason)"
    )
  }

  private func throwIfActiveDownloadCancelled(since generation: UInt64) throws {
    guard activeDownloadCancellation.wasRequested(since: generation) else { return }
    report("[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCELLED_AT_CHUNK_BOUNDARY")
    throw NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "用户已终止当前下载"]
    )
  }

  @discardableResult
  private func prepareDownloadModeForPriorityBatch(
    _ mode: CameraVendorTransferDownloadMode,
    handle: UInt32,
    reason: String
  ) throws -> Bool {
    try prepareTransferMode(
      physicalPurpose(for: mode),
      handle: handle,
      reason: reason
    )
  }

  func ensureConnectedForPriorityDownload(
    reconnectLabel: String = "PTP_PRIORITY_DOWNLOAD_RECONNECT"
  ) throws {
    // The default label remains PTP_PRIORITY_DOWNLOAD_RECONNECT for the real
    // download path; catalog recovery supplies its own label explicitly.
    // Diagnostic compatibility: PTP_PRIORITY_DOWNLOAD_RECONNECT_RETRY.
    guard !isConnected else { return }
    guard let reconnectClientIP = priorityDownloadReconnectClientIP,
          CameraVendorPriorityDownloadReconnectPolicy.shouldStartPtpInit(
            currentIP: reconnectClientIP,
            isPtpReachable: true
          ) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 16,
        userInfo: [NSLocalizedDescriptionKey: "未取得已验证的相机 Wi‑Fi IPv4，禁止发送 PTP INIT"]
      )
    }
    guard let ptpInitDefinition = boundPtpInitDefinition,
          let negotiationDefinition = boundNegotiationDefinition,
          let galleryBootstrapDefinition = boundGalleryBootstrapDefinition else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 15,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Priority download reconnect requires an explicitly bound Strategy snapshot"
        ]
      )
    }
    let connectionPlanID = boundConnectionPlanID
    let reconnectDiagnosticHandler = diagnosticHandler
    var lastError: Error?
    for attempt in 1...ptpInitDefinition.retryTiming.connectionMaxAttempts {
      report("[OBS] \(reconnectLabel)_BEGIN clientName=\(connectedClientName) attempt=\(attempt)")
      guard !isConnected else { return }
      do {
        if ptpInitDefinition.startupDelaySeconds > 0 {
          Thread.sleep(forTimeInterval: ptpInitDefinition.startupDelaySeconds)
        }
        try connectTransportAndOpenSession(
          host: connectedHost,
          clientName: connectedClientName,
          clientIP: reconnectClientIP,
          diagnosticHandler: reconnectDiagnosticHandler,
          purpose: connectedPurpose,
          ptpInitDefinition: ptpInitDefinition
        )
        try negotiateGalleryFunction(
          definition: negotiationDefinition,
          connectionPlanID: connectionPlanID
        )
        try prepareGallerySession(
          definition: galleryBootstrapDefinition,
          connectionPlanID: connectionPlanID
        )
        report("[OBS] \(reconnectLabel)_COMPLETE attempt=\(attempt)")
        return
      } catch {
        commandSocket.close()
        eventSocket.close()
        isConnected = false
        if CameraVendorPtpReconnectErrorPolicy.shouldRetry(error) == false {
          throw error
        }

        lastError = error
        guard attempt < ptpInitDefinition.retryTiming.connectionMaxAttempts else {
          break
        }

        let delay = retryDelaySeconds(
          afterFailedAttempt: attempt,
          backoff: ptpInitDefinition.retryTiming.connectionRetryBackoff
        )
        report(
          "[OBS] \(reconnectLabel)_RETRY " +
          "attempt=\(attempt) delay=\(String(format: "%.1f", delay)) " +
          "error=\(error.localizedDescription)"
        )
        Thread.sleep(forTimeInterval: delay)
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: 12,
      userInfo: [NSLocalizedDescriptionKey: "优先下载重连多次失败"]
    )
  }

  private func retryDelaySeconds(
    afterFailedAttempt attempt: Int,
    backoff: CameraConnectionRetryBackoffID
  ) -> TimeInterval {
    switch backoff {
    case .currentLinearHalfSecond:
      return CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(
        afterFailedAttempt: attempt
      )
    }
  }

  private func performStandardGalleryHandshake() throws {
    // Wait for camera to be ready (poll CameraState 0xDF00).
    // On first connection, user may need to press OK on camera screen.
    report("等待相机就绪 (轮询 CameraState 0xDF00)")
    try waitForCameraAccess()

    // Set InitSequence (0xDF01 = 0x00000005) — matches Go reference implementation.
    // This is the handshake value that tells the camera we're a valid client.
    report("设置 InitSequence (0xDF01 = 0x00000005)")
    var initSeqData = Data()
    let initSeqValue = UInt32(5).littleEndian
    withUnsafeBytes(of: initSeqValue) { initSeqData.append(contentsOf: $0) }
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.initSequence],
      data: initSeqData
    )
    report("InitSequence 已设置")

    // Read and echo back app version (required handshake step)
    report("读取 CameraVendor AppVersion (0xDF24)")
    let appVersionData = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [CameraVendorDevicePropCode.appVersion]
    )
    report("收到 AppVersion 数据 (\(appVersionData.count) bytes): \(appVersionData.map { String(format: "%02x", $0) }.joined(separator: " "))")

    report("回写 CameraVendor AppVersion")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.appVersion],
      data: appVersionData
    )
    report("CameraVendor AppVersion 已确认")

    // Set InitSequence to gallery/transfer mode (0xDF01 = 0x00000002 = VIEW_ALL_IMGS)
    // This tells the camera we want to browse and transfer photos.
    // (InitiateOpenCapture 0x101C is for remote shooting mode, not gallery.)
    report("设置图库浏览模式 (0xDF01 = 0x00000002)")
    var modeData = Data()
    let modeValue = UInt32(2).littleEndian
    withUnsafeBytes(of: modeValue) { modeData.append(contentsOf: $0) }
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.initSequence],
      data: modeData
    )
    report("图库浏览模式已设置")

    // Reset D226/D227 from any previous abnormal exit (crash, user kill, etc.)
    // so the camera doesn't remain in forced-compression transfer mode.
    try resetCameraVendorCompressionMode()
  }

  private func confirmCameraVendorLegacyReferenceAppGalleryMode() throws {
    report("确认 CameraVendor/ReferenceApp legacy 相册模式")

    let factoryContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #1 (38 bytes)"
    )
    report(
      "[OBS] PTP_FACTORY_D212_1 bytes=\(factoryContext.count) " +
      "hex=\(factoryContext.map { String(format: "%02x", $0) }.joined())"
    )

    try setCameraVendorReferenceAppClientState(
      CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState,
      reason: "referenceApp-remote-image-viewer"
    )

    let imageHostVersion = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppImageHost,
      name: "CameraVendor/ReferenceApp ImageHost 版本 (0xDF28)"
    )

    let versionToWrite = CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: imageHostVersion)
    report("按 ReferenceApp 图库模式回写 CameraVendor/ReferenceApp ImageHost 版本 (0xDF28 = \(versionToWrite))")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppImageHost],
      data: littleEndianData(versionToWrite)
    )

    try requestCameraVendorCardSlotStatus()
    report("CameraVendor/ReferenceApp legacy 相册模式确认完成")
  }

  private func prepareCameraVendorLegacyGalleryLoad() throws {
    guard !didPrepareLegacyGalleryLoad else {
      report("[OBS] PTP_GALLERY_BOOTSTRAP_SKIPPED reason=already-prepared")
      return
    }

    report("执行 CameraVendor/ReferenceApp legacy Gallery bootstrap")

    let initialContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #2 (14 bytes)"
    )
    reportCameraVendorGalleryContextMarker(initialContext)
    report("[OBS] PTP_FACTORY_D212_2 bytes=\(initialContext.count) hex=\(initialContext.map { String(format: "%02x", $0) }.joined())")

    try requestCameraVendorCardSlotStatus()

    report("[OBS] PTP_GALLERY_BOOTSTRAP_9054_SKIPPED reason=optional-current-image-prime")
    report("[OBS] PTP_GALLERY_BOOTSTRAP_9055_SKIPPED reason=optional-current-thumbnail-prime")
    report("[OBS] PTP_GALLERY_BOOTSTRAP_9050_SKIPPED reason=unused-search-mode-description")
    report("[OBS] PTP_GALLERY_BOOTSTRAP_D22B")
    try requestCameraVendorCurrentObjectHandleSnapshot(stage: "gallery-bootstrap")

    let context3 = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #3 (7 bytes)"
    )
    report("[OBS] PTP_FACTORY_D212_3 bytes=\(context3.count) hex=\(context3.map { String(format: "%02x", $0) }.joined())")

    didPrepareLegacyGalleryLoad = true
    report("[OBS] PTP_GALLERY_BOOTSTRAP_COMPLETE")
  }

  func prepareCameraVendorLegacyGalleryLoadIfNeeded() throws {
    guard operationTransport == .cameraVendorLegacy else { return }
    try prepareCameraVendorLegacyGalleryLoad()
  }

  private func performCameraVendorReservedReceiveDiagnosticHandshake() throws {
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_HANDSHAKE_BEGIN")

    let initialContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp Reserved Receive 初始上下文 (0xD212)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_INITIAL_D212 bytes=\(initialContext.map { String(format: "%02x", $0) }.joined())")

    try setCameraVendorReferenceAppClientState(
      CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState,
      reason: "reserved-receive-diagnostic"
    )

    let versionData = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppReservedReceive,
      name: "CameraVendor/ReferenceApp ReservedPhotoReceiveEx (0xDF29)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_VERSION_READ value=\(cameraVendorPropValueDescription(versionData))")

    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppReservedReceive],
      data: littleEndianData(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)
    )
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_VERSION_WRITE value=\(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)")

    let readyContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp Reserved Receive 上下文 (0xD212)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_READY_D212 bytes=\(readyContext.map { String(format: "%02x", $0) }.joined())")
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_HANDSHAKE_OK")
  }

  private func reportCameraVendorVersionSnapshot(stage: String) {
    let props: [(UInt32, String)] = [
      (CameraVendorDevicePropCode.cameraState, "CameraState"),
      (CameraVendorDevicePropCode.imageGetVersion, "ImageGetVersion"),
      (CameraVendorDevicePropCode.getObjectVersion, "GetObjectVersion"),
      (CameraVendorDevicePropCode.appVersion, "RemoteVersion/AppVersion"),
      (CameraVendorDevicePropCode.remoteGetObjectVersion, "RemoteGetObjectVersion"),
      (CameraVendorDevicePropCode.referenceAppImageHost, "ReferenceAppImageHost"),
    ]
    for (code, name) in props {
      do {
        let data = try readCameraVendorDeviceProperty(
          code: code,
          name: "CameraVendor \(name) (0x\(String(format: "%04X", code)))"
        )
        report("[OBS] PTP_CAMERA_VENDOR_VERSION_PROP stage=\(stage) name=\(name) value=\(cameraVendorPropValueDescription(data))")
      } catch {
        report("[OBS] PTP_CAMERA_VENDOR_VERSION_PROP_FAILED stage=\(stage) name=\(name) error=\(error.localizedDescription)")
      }
    }
  }

  private func primeCameraVendorReferenceAppRemoteImageViewerContext() {
    do {
      try setCameraVendorDevicePropUInt16(
        CameraVendorDevicePropCode.cameraState,
        value: UInt16(CameraVendorReferenceAppRemoteImageViewerPolicy.cameraStateRemoteAccess),
        name: "CameraState remote access"
      )
      report("[OBS] PTP_SET_CAMERA_STATE_REMOTE_ACCESS")
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after CameraState remote access (0xD212)"
      )
    } catch {
      report("[OBS] PTP_SET_CAMERA_STATE_REMOTE_ACCESS_FAILED error=\(error.localizedDescription)")
    }
  }

  private func primeCameraVendorRemoteGetObjectVersionIfAvailable() {
    do {
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.remoteGetObjectVersion,
        name: "CameraVendor RemoteGetObjectVersion (0xDF25)"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.remoteGetObjectVersion],
        data: littleEndianData(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite)
      )
      report("[OBS] PTP_SET_REMOTE_GET_OBJECT_VERSION value=\(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite)")
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after RemoteGetObjectVersion (0xD212)"
      )
    } catch {
      report("[OBS] PTP_REMOTE_GET_OBJECT_VERSION_SKIPPED error=\(error.localizedDescription)")
    }
  }

  private func probeCameraVendorReservedReceiveModeIfNeeded() {
    guard CameraVendorReferenceAppReservedReceiveProbePolicy.shouldProbeDuringGalleryHandshake else {
      return
    }

    report("[OBS] PTP_RESERVED_RECEIVE_PROBE_BEGIN")
    do {
      try setCameraVendorReferenceAppClientState(
        CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState,
        reason: "reserved-receive-probe"
      )

      let versionData = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppReservedReceive,
        name: "CameraVendor/ReferenceApp ReservedPhotoReceiveEx (0xDF29)"
      )
      report("[OBS] PTP_RESERVED_RECEIVE_VERSION_READ value=\(cameraVendorPropValueDescription(versionData))")

      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.referenceAppReservedReceive],
        data: littleEndianData(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)
      )
      report("[OBS] PTP_SET_RESERVED_RECEIVE_VERSION value=\(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)")

      let context = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after ReservedReceive (0xD212)"
      )
      report("[OBS] PTP_RESERVED_RECEIVE_D212 bytes=\(context.map { String(format: "%02x", $0) }.joined())")

      do {
        let info = try objectInfo(handle: CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle)
        report(
          "[OBS] PTP_RESERVED_RECEIVE_OBJECT_INFO " +
          "handle=\(info.handle) format=\(info.formatLabel) filename=\(info.filename) size=\(info.compressedSize)"
        )
      } catch {
        report("[OBS] PTP_RESERVED_RECEIVE_OBJECT_INFO_FAILED error=\(error.localizedDescription)")
      }

      let reservedCount = try? requestCameraVendorSpecifiedObjectCount(stage: "reserved-receive-probe")
      let reservedHandles = (try? requestCameraVendorSpecifiedObjectHandles(stage: "reserved-receive-probe")) ?? []
      report(
        "[OBS] PTP_RESERVED_RECEIVE_SPECIFIED_SNAPSHOT " +
        "count=\(reservedCount.flatMap { $0 }.map(String.init) ?? "nil") handles=\(reservedHandles.count)"
      )
    } catch {
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_FAILED error=\(error.localizedDescription)")
    }

    do {
      try setCameraVendorReferenceAppClientState(
        CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState,
        reason: "reserved-receive-probe-restore"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.referenceAppImageHost],
        data: littleEndianData(CameraVendorReferenceAppFunctionVersionPolicy.fallbackRemotePhotoViewExVersion)
      )
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_RESTORE_OK")
    } catch {
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_RESTORE_FAILED error=\(error.localizedDescription)")
    }
    report("[OBS] PTP_RESERVED_RECEIVE_PROBE_END")
  }

  private func setCameraVendorReferenceAppClientState(_ state: UInt32, reason: String) throws {
    report("设置 ReferenceApp ClientState (0xDF01 = \(state)) reason=\(reason)")
    try setCameraVendorDevicePropUInt16(
      CameraVendorDevicePropCode.initSequence,
      value: UInt16(state),
      name: "CameraVendor/ReferenceApp ClientState"
    )
    report("[OBS] PTP_SET_CLIENT_STATE_UINT16 state=\(state) reason=\(reason)")
  }

  private func setCameraVendorDevicePropUInt16(_ code: UInt32, value: UInt16, name: String) throws {
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [code],
      data: littleEndianData(value)
    )
    report("\(name) 已设置为 \(value)")
  }

  private func requestCameraVendorSearchModeDescAll() throws {
    var lastError: Error?
    for attempt in 1...CameraVendorSearchModeDescRetryPolicy.maxAttempts {
      do {
        report("按 ReferenceApp 初始化链请求 SearchModeDescAll (0x9050) attempt=\(attempt)")
        let data = try sendCommandForData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll)
        )
        let preview = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: "")
        report("[OBS] PTP_SEARCH_MODE_DESC_ALL bytes=\(data.count) head=\(preview) attempts=\(attempt)")
        return
      } catch {
        lastError = error
        guard attempt < CameraVendorSearchModeDescRetryPolicy.maxAttempts,
              CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: error) else {
          throw error
        }
        let delay = CameraVendorSearchModeDescRetryPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
        report("[OBS] PTP_SEARCH_MODE_DESC_ALL_RETRY attempt=\(attempt) delay=\(String(format: "%.1f", delay)) error=\(error.localizedDescription)")
        Thread.sleep(forTimeInterval: delay)
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: CameraVendorSearchModeDescRetryPolicy.retryableResponseCode,
      userInfo: [NSLocalizedDescriptionKey: "SearchModeDescAll retry exhausted"]
    )
  }

  private func requestCameraVendorSearchModeAll(stage: String = "initial") throws -> Data {
    report("按 ReferenceApp 初始化链请求 SearchModeAll (0x9052) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll)
    )
    let preview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_SEARCH_MODE_ALL stage=\(stage) bytes=\(data.count) head=\(preview)")
    return data
  }

  private func restoreCameraVendorSearchModeAll(_ data: Data, stage: String) throws {
    report("[OBS] PTP_RESTORE_SEARCH_MODE_ALL_BEGIN stage=\(stage) bytes=\(data.count)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: data
    )
    report("[OBS] PTP_RESTORE_SEARCH_MODE_ALL_END stage=\(stage) response=0x\(String(format: "%04X", response.responseCode))")
  }

  private func catalogSearchModeBackup(stage: String) throws -> Data {
    if mediaOperationDefinition?.failClosedForUnknownSearchMode == true,
       catalogSearchModeStrategy.readsBackupFromCamera {
      report(
        "[OBS] PTP_SEARCH_MODE_BACKUP_REJECTED stage=\(stage) " +
          "reason=unknown-search-mode-behavior"
      )
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorUnsupportedURL,
        userInfo: [
          NSLocalizedDescriptionKey:
            "当前 SearchMode 行为事实未知，拒绝读取并恢复未知状态",
        ]
      )
    }
    guard catalogSearchModeStrategy.readsBackupFromCamera else {
      report("[OBS] PTP_SEARCH_MODE_BACKUP_SKIPPED stage=\(stage) reason=explicit-all-restore")
      return Data()
    }
    return try requestCameraVendorSearchModeAll(stage: stage)
  }

  private func restoreCatalogSearchModeAll(_ saved: Data, stage: String) throws {
    guard let explicitPayload = catalogSearchModeStrategy.restorationPayload else {
      try restoreCameraVendorSearchModeAll(saved, stage: stage)
      return
    }
    report("[OBS] PTP_SEARCH_MODE_EXPLICIT_ALL_BEGIN stage=\(stage) bytes=\(explicitPayload.count)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: explicitPayload
    )
    report("[OBS] PTP_SEARCH_MODE_EXPLICIT_ALL_END stage=\(stage) response=0x\(String(format: "%04X", response.responseCode))")
  }

  func cameraVendorInitialCatalogSnapshot() throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask

    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_INITIAL_CAMERA_CATALOG_BEGIN")
    if catalogSearchModeStrategy.requiresExplicitAllBeforeUnfilteredCatalog {
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
        data: CameraVendorSearchModeAllPayload.payload(for: [])
      )
      report("[OBS] PTP_INITIAL_CAMERA_CATALOG_EXPLICIT_ALL")
    }
    let snapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "initial-camera-catalog",
      allowsEmptyRetry: false
    )

    guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
      declaredCount: snapshot.declaredCount,
      dateGroups: snapshot.dateGroups,
      orderedHandles: snapshot.handles
    ) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "相机返回的初始目录计数、日期组或句柄不一致"]
      )
    }
    let catalog = CameraVendorCatalogSnapshot(
      dateGroups: snapshot.dateGroups,
      orderedHandles: snapshot.handles,
      items: CameraVendorCatalogPlaceholderPolicy.placeholderItems(
        from: snapshot.handles,
        dateGroups: snapshot.dateGroups,
        formatHintsByHandle: [:]
      ),
      coverage: .unknown
    )
    report(
      "[OBS] PTP_INITIAL_CAMERA_CATALOG_END groups=\(catalog.dateGroups.count) " +
      "handles=\(catalog.orderedHandles.count) coverage=unknown extendedStill=0"
    )
    return catalog
  }

  func cameraVendorCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    if let definition = mediaOperationDefinition,
       definition.usesConservativeSearchMode {
      report(
        "[OBS] PTP_CATALOG_SEARCH_MODE_CONSERVATIVE label=\(query.label) " +
          "evidence=\(definition.searchModeEvidence.rawValue) " +
          "backupRead=\(definition.backupReadAllowed) " +
          "explicitAllRestore=\(definition.explicitAllRestoreAllowed)"
      )
    }
    switch query.membershipPolicy {
    case .countSweepThenApply:
      return try cameraVendorCountSweepCatalogSnapshot(query: query)
    case .subtractBaseline:
      return try cameraVendorSubtractBaselineCatalogSnapshot(query: query)
    case .direct:
      return try cameraVendorDirectCatalogSnapshot(query: query)
    }
  }

  /// HEIF/Video catalog: camera doesn't correctly filter D604=2 on this session,
  /// so we use set subtraction: (D604=X result) minus (ALL result) = format-only handles.
  /// This does not depend on ObjectInfo and completes instantly.
  private func cameraVendorSubtractBaselineCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_SUBTRACT_BASELINE_BEGIN label=\(query.label)")

    // Step 1: Read ALL directory (baseline)
    let baselineSnapshot = try CameraVendorCatalogTransactionExecutor.execute(
      backup: {
        try catalogSearchModeBackup(stage: "subtract-all-backup-\(query.label)")
      },
      perform: {
        let allPayload = CameraVendorSearchModeAllPayload.payload(for: [])
        _ = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
          data: allPayload
        )
        return try requestCameraVendorSpecifiedObjectSnapshot(
          stage: "subtract-all-\(query.label)",
          allowsEmptyRetry: false
        )
      },
      restore: { saved in
        try restoreCatalogSearchModeAll(saved, stage: "subtract-all-restore-\(query.label)")
      }
    )
    report("[OBS] PTP_SUBTRACT_BASELINE_ALL handles=\(baselineSnapshot.handles.count)")

    // Step 2: Read format-filtered directory (D604=X, returns broad result)
    let formatSnapshot = try CameraVendorCatalogTransactionExecutor.execute(
      backup: {
        try catalogSearchModeBackup(stage: "subtract-fmt-backup-\(query.label)")
      },
      perform: {
        let payload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
        report("[OBS] PTP_SUBTRACT_FORMAT_WRITE label=\(query.label) payload=\(payload.map { String(format: "%02x", $0) }.joined())")
        _ = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
          data: payload
        )
        return try requestCameraVendorSpecifiedObjectSnapshot(
          stage: "subtract-fmt-\(query.label)",
          allowsEmptyRetry: false
        )
      },
      restore: { saved in
        try restoreCatalogSearchModeAll(saved, stage: "subtract-fmt-restore-\(query.label)")
      }
    )
    report("[OBS] PTP_SUBTRACT_FORMAT_RAW handles=\(formatSnapshot.handles.count)")

    // Step 3: Validate both snapshots and require the format response to be a
    // complete superset before treating the difference as format membership.
    guard let isolatedHandles = CameraVendorSubtractBaselineValidationPolicy.isolatedHandles(
      baseline: baselineSnapshot,
      format: formatSnapshot
    ) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "相机返回的格式目录无法证明 subtract-baseline 成员关系"]
      )
    }
    report(
      "[OBS] PTP_SUBTRACT_BASELINE_END label=\(query.label) " +
      "all=\(baselineSnapshot.handles.count) " +
      "format_raw=\(formatSnapshot.handles.count) " +
      "isolated=\(isolatedHandles.count) coverage=complete(heif)"
    )

    // Build date groups for isolated handles by mapping from the format snapshot's date groups
    let isolatedHandleSet = Set(isolatedHandles)
    var isolatedDateGroups: [CameraVendorSpecifiedObjectDateGroup] = []
    var handleCursor = 0
    for group in formatSnapshot.dateGroups {
      let groupEnd = handleCursor + Int(group.objectCount)
      let groupHandles = formatSnapshot.handles[handleCursor..<min(groupEnd, formatSnapshot.handles.count)]
      let matchCount = groupHandles.filter { isolatedHandleSet.contains($0) }.count
      if matchCount > 0 {
        isolatedDateGroups.append(CameraVendorSpecifiedObjectDateGroup(
          dateText: group.dateText,
          objectCount: UInt32(matchCount)
        ))
      }
      handleCursor = groupEnd
    }

    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: isolatedHandles,
      dateGroups: isolatedDateGroups
    )
    return CameraVendorCatalogSnapshot(
      dateGroups: isolatedDateGroups,
      orderedHandles: isolatedHandles,
      items: items,
      coverage: .complete(knownFormats: [.heif])
    )
  }

  /// Standard direct catalog transaction: backup -> write -> read -> restore.
  private func cameraVendorDirectCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    do {
      report(
        "[OBS] CATALOG_SEARCH_MODE_STRATEGY strategy=\(catalogSearchModeStrategy.rawValue) " +
        "readsBackup=\(catalogSearchModeStrategy.readsBackupFromCamera) " +
        "factsDriven=true sessionScoped=true label=\(query.label)"
      )
      let catalog = try CameraVendorCatalogTransactionExecutor.execute(
        backup: {
          return try catalogSearchModeBackup(
            stage: "catalog-query-backup-\(query.label)"
          )
        },
        perform: {
          let payload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
          report(
            "[OBS] PTP_CAMERA_CATALOG_BEGIN label=\(query.label) " +
            "conditions=\(query.conditions.count) bytes=\(payload.count) " +
            "payload=\(payload.map { String(format: "%02x", $0) }.joined())"
          )
          _ = try sendCommandWithData(
            operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
            data: payload
          )
          let snapshot = try requestCameraVendorSpecifiedObjectSnapshot(
            stage: "camera-catalog-\(query.label)",
            allowsEmptyRetry: false
          )
          guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
            declaredCount: snapshot.declaredCount,
            dateGroups: snapshot.dateGroups,
            orderedHandles: snapshot.handles
          ) else {
            throw NSError(
              domain: "CameraVendorPtpSession",
              code: NSURLErrorCannotParseResponse,
              userInfo: [NSLocalizedDescriptionKey: "相机返回的筛选目录计数、日期组或句柄不一致"]
            )
          }
          let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
            from: snapshot.handles,
            dateGroups: snapshot.dateGroups
          )
          return CameraVendorCatalogSnapshot(
            dateGroups: snapshot.dateGroups,
            orderedHandles: snapshot.handles,
            items: items,
            coverage: query.conditions.isEmpty
              ? .unknown
              : .complete(knownFormats: Set(query.conditions.compactMap { condition in
                guard case let .uint16(propertyCode, value) = condition,
                      propertyCode == CameraVendorSearchModeAllPayload.objectFormatPropertyCode else {
                  return nil
                }
                switch value {
                case CameraVendorSearchModeAllPayload.jpegObjectFormatMask: return .jpg
                case CameraVendorSearchModeAllPayload.rawObjectFormatMask: return .raw
                case CameraVendorSearchModeAllPayload.heifObjectFormatMask: return .heif
                default: return nil
                }
              }))
          )
        },
        restore: { savedSearchMode in
          try restoreCatalogSearchModeAll(
            savedSearchMode,
            stage: "catalog-query-restore-\(query.label)"
          )
        }
      )
      report(
        "[OBS] PTP_CAMERA_CATALOG_END label=\(query.label) groups=\(catalog.dateGroups.count) " +
        "handles=\(catalog.orderedHandles.count) coverage=\(catalog.coverage)"
      )
      return catalog
    } catch {
      if let failure = error as? CameraGalleryCatalogTransactionFailure {
        report(
          "[OBS] PTP_CAMERA_CATALOG_FAILED label=\(query.label) " +
          "primary=\(failure.primaryMessage) restore=\(failure.restorationMessage ?? "ok")"
        )
      } else {
        report("[OBS] PTP_CAMERA_CATALOG_FAILED label=\(query.label) error=\(error.localizedDescription)")
      }
      throw error
    }
  }

  /// Count sweep then apply: replicates XApp's exact pre-apply state.
  /// 1. Backup -> sweep all formats (read count only) -> restore
  /// 2. Write D604=31 (all formats) baseline, read full directory
  /// 3. Apply target format from the D604=31 state, read filtered directory
  /// 4. Do NOT restore — leave the filter active (XApp behavior)
  private func cameraVendorCountSweepCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_COUNT_SWEEP_CATALOG_BEGIN label=\(query.label)")

    // Step 1: Backup current SearchMode
    let savedSearchMode = try requestCameraVendorSearchModeAll(stage: "sweep-backup-\(query.label)")

    // Step 2: Sweep each format mask (XApp order)
    let sweepOrder: [(label: String, mask: UInt16)] = [
      ("jpg", CameraVendorSearchModeAllPayload.jpegObjectFormatMask),
      ("heif", CameraVendorSearchModeAllPayload.heifObjectFormatMask),
      ("mp4", CameraVendorSearchModeAllPayload.mp4ObjectFormatMask),
      ("mov", CameraVendorSearchModeAllPayload.movObjectFormatMask),
      ("raw", CameraVendorSearchModeAllPayload.rawObjectFormatMask),
    ]
    for (label, mask) in sweepOrder {
      let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
        data: payload
      )
      let count = try requestCameraVendorSpecifiedObjectCount(stage: "sweep-\(label)")
      report("[OBS] PTP_COUNT_SWEEP_FORMAT label=\(label) mask=0x\(String(format: "%04X", mask)) count=\(count.map(String.init) ?? "nil")")
    }

    // Step 3: Restore the backed-up SearchMode
    try restoreCameraVendorSearchModeAll(savedSearchMode, stage: "sweep-restore-\(query.label)")

    // Step 4: Establish D604=31 baseline with full directory
    let allPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.allObjectFormatMask
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: allPayload
    )
    let baselineSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "sweep-baseline-\(query.label)",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE handles=\(baselineSnapshot.handles.count)"
    )

    // Step 5: Apply the target format from the D604=31 state
    let targetPayload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
    report(
      "[OBS] PTP_COUNT_SWEEP_APPLY label=\(query.label) " +
      "payload=\(targetPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: targetPayload
    )
    let filteredSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "sweep-apply-\(query.label)",
      allowsEmptyRetry: false
    )

    // Step 6: Confirm readback (do NOT restore — XApp leaves the filter active)
    _ = try requestCameraVendorSearchModeAll(stage: "sweep-confirm-\(query.label)")

    guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
      declaredCount: filteredSnapshot.declaredCount,
      dateGroups: filteredSnapshot.dateGroups,
      orderedHandles: filteredSnapshot.handles
    ) else {
      // Restore on failure
      try? restoreCameraVendorSearchModeAll(savedSearchMode, stage: "sweep-fail-restore-\(query.label)")
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "相机返回的筛选目录计数、日期组或句柄不一致"]
      )
    }

    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: filteredSnapshot.handles,
      dateGroups: filteredSnapshot.dateGroups
    )
    let catalog = CameraVendorCatalogSnapshot(
      dateGroups: filteredSnapshot.dateGroups,
      orderedHandles: filteredSnapshot.handles,
      items: items
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_CATALOG_END label=\(query.label) " +
      "baseline=\(baselineSnapshot.handles.count) " +
      "filtered=\(filteredSnapshot.handles.count)"
    )
    return catalog
  }

  /// Executes the full XApp count sweep sequence as a HEIF diagnostic experiment.
  /// This replicates the exact XApp pre-apply state:
  /// 1. Backup current SearchMode (9052)
  /// 2. Sweep each format mask writing 9051 + reading D620 count
  /// 3. Restore backup
  /// 4. Establish D604=31 baseline with full D620/D621
  /// 5. Apply D604=2 from the baseline state (no restore)
  /// 6. Confirm readback (9052)
  ///
  /// This method does NOT restore after a successful HEIF apply, matching XApp behavior.
  /// The caller is responsible for subsequent SearchMode management.
  func cameraVendorCountSweepExperiment() throws -> CameraVendorCountSweepResult {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_COUNT_SWEEP_EXPERIMENT_BEGIN")

    // Step 1: Backup current SearchMode
    let savedSearchMode = try requestCameraVendorSearchModeAll(stage: "count-sweep-backup")

    // Step 2: Sweep each format mask (XApp order: JPG, HEIF, MP4, MOV, RAW)
    let sweepOrder: [(label: String, mask: UInt16)] = [
      ("jpg", CameraVendorSearchModeAllPayload.jpegObjectFormatMask),
      ("heif", CameraVendorSearchModeAllPayload.heifObjectFormatMask),
      ("mp4", CameraVendorSearchModeAllPayload.mp4ObjectFormatMask),
      ("mov", CameraVendorSearchModeAllPayload.movObjectFormatMask),
      ("raw", CameraVendorSearchModeAllPayload.rawObjectFormatMask),
    ]
    var sweepCounts: [CameraVendorCountSweepFormatCount] = []
    for (label, mask) in sweepOrder {
      let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
      report(
        "[OBS] PTP_COUNT_SWEEP_WRITE label=\(label) mask=0x\(String(format: "%04X", mask)) " +
        "payload=\(payload.map { String(format: "%02x", $0) }.joined())"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
        data: payload
      )
      let count = try requestCameraVendorSpecifiedObjectCount(stage: "count-sweep-\(label)")
      sweepCounts.append(CameraVendorCountSweepFormatCount(label: label, mask: mask, count: count))
      report("[OBS] PTP_COUNT_SWEEP_READ label=\(label) count=\(count.map(String.init) ?? "nil")")
    }

    // Step 3: Restore the backed-up SearchMode
    try restoreCameraVendorSearchModeAll(savedSearchMode, stage: "count-sweep-restore")

    // Step 4: Establish D604=31 baseline (all formats) with full directory
    let allPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.allObjectFormatMask
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE payload=\(allPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: allPayload
    )
    let baselineSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "count-sweep-baseline-all",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE_RESULT " +
      "count=\(baselineSnapshot.declaredCount.map(String.init) ?? "nil") " +
      "handles=\(baselineSnapshot.handles.count)"
    )

    // Step 5: Apply D604=2 from the D604=31 baseline state (XApp precondition)
    let heifPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.heifObjectFormatMask
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_HEIF_APPLY payload=\(heifPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: heifPayload
    )
    let heifSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "count-sweep-heif-apply",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_HEIF_RESULT " +
      "declared=\(heifSnapshot.declaredCount.map(String.init) ?? "nil") " +
      "handles=\(heifSnapshot.handles.count)"
    )

    // Step 6: Confirm readback (9052) — XApp does this, does NOT restore
    let confirmReadback = try requestCameraVendorSearchModeAll(stage: "count-sweep-heif-confirm")

    let result = CameraVendorCountSweepResult(
      sweepCounts: sweepCounts,
      baselineHandleCount: baselineSnapshot.handles.count,
      heifDeclaredCount: heifSnapshot.declaredCount,
      heifHandleCount: heifSnapshot.handles.count,
      heifHandles: heifSnapshot.handles,
      confirmReadback: confirmReadback
    )
    report("[OBS] PTP_COUNT_SWEEP_EXPERIMENT_END \(result.diagnosticSummary)")
    return result
  }

  private func primeCameraVendorCurrentImageContextIfNeeded(
    stage: String,
    galleryReadyMarker: UInt32?
  ) -> Bool {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
      galleryReadyMarker: galleryReadyMarker
    ) else {
      let marker = galleryReadyMarker.map { String(format: "0x%04X", $0) } ?? "nil"
      let reason = CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList
        ? "gallery-marker-not-ready"
        : "production-route-disabled"
      report("[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=\(reason) d222=\(marker)")
      return false
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前图上下文 (0x9054, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let result = try sendCommandForDataWithTiming(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
        parameters: [handle]
      )
      let data = result.data
      report(
        CameraVendorDataCommandTimingLogPolicy.completedMessage(
          operationCode: 0x9054,
          handle: handle,
          byteCount: data.count,
          timing: result.timing
        )
      )
      let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
      report(
        "[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME stage=\(stage) bytes=\(data.count) head=\(preview)"
      )
      return true
    } catch {
      report("[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
      return false
    }
  }

  private func primeCameraVendorCurrentThumbnailContextIfNeeded(stage: String, imagePrimeSucceeded: Bool) {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription else {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=production-route-disabled")
      return
    }

    guard imagePrimeSucceeded else {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=image-prime-failed")
      return
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前缩略图上下文 (0x9055, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let result = try sendCommandForDataWithTiming(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb),
        parameters: [handle]
      )
      let data = result.data
      report(
        CameraVendorDataCommandTimingLogPolicy.completedMessage(
          operationCode: 0x9055,
          handle: handle,
          byteCount: data.count,
          timing: result.timing
        )
      )
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME stage=\(stage) bytes=\(data.count)")
    } catch {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
    }
  }

  private func requestCameraVendorCurrentObjectHandleSnapshot(stage: String) throws {
    if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleViaObjectPropList {
      let objectPropListHandle = try readCameraVendorCurrentObjectHandleViaObjectPropList()
      if let objectPropListHandle, objectPropListHandle != 0 {
        report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT stage=\(stage) source=objectPropList value=0x\(String(format: "%08X", objectPropListHandle))")
      }
    }
    do {
      if let propHandle = try readCameraVendorCurrentObjectHandle(), propHandle != 0 {
        report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT stage=\(stage) source=deviceProp value=0x\(String(format: "%08X", propHandle))")
      }
    } catch {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT_FAILED stage=\(stage) error=\(error.localizedDescription)")
      throw error
    }
  }

  private func resetCameraVendorSearchModeAll(stage: String = "default") throws {
    report("按 ReferenceApp resetSearchModeAll 写入空 SearchModeAll (0x9051) stage=\(stage)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: Data([0x00, 0x00, 0x00, 0x00])
    )
    report("[OBS] PTP_SET_SEARCH_MODE_ALL_EMPTY stage=\(stage) response=0x\(String(format: "%04X", response.responseCode))")
  }

  private func setCameraVendorStillImageObjectFormatSearchMode() throws {
    let mask = CameraVendorSearchModeAllPayload.stillImageObjectFormatMask
    try setCameraVendorObjectFormatSearchMode(mask: mask, label: "STILL")
  }

  private func setCameraVendorObjectFormatSearchMode(mask: UInt16, label: String) throws {
    let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
    report(
      "[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT_BEGIN " +
      "label=\(label) " +
      "property=0x\(String(format: "%04X", CameraVendorSearchModeAllPayload.objectFormatPropertyCode)) " +
      "mask=0x\(String(format: "%04X", mask)) payload=\(payload.map { String(format: "%02x", $0) }.joined())"
    )
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: payload
    )
    report("[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT label=\(label) response=0x\(String(format: "%04X", response.responseCode))")
  }

  private func physicalPurpose(
    for mode: CameraVendorTransferDownloadMode
  ) -> CameraVendorPhysicalTransferPurpose {
    switch mode {
    case .compressed: return .compressedDownload
    case .original: return .originalDownload
    }
  }

  @discardableResult
  private func prepareTransferMode(
    _ purpose: CameraVendorPhysicalTransferPurpose,
    handle: UInt32? = nil,
    reason: String
  ) throws -> Bool {
    let before = transferModeCoordinator.currentPurpose
    let actions = transferModeCoordinator.actionsForPreparing(purpose)
    report(
      "[OBS] PTP_TRANSFER_MODE_PREPARE before=\(before.label) requested=\(purpose.label) " +
      "actions=\(actions.count) reason=\(reason)"
    )
    do {
      for action in actions {
        switch action {
        case .setProperty(let property):
          _ = try setCameraVendorTransferModeProperty(
            property,
            handle: handle,
            purpose: purpose,
            reason: reason
          )
        }
      }
      transferModeCoordinator.recordPreparationSucceeded(purpose)
      report(
        "[OBS] PTP_TRANSFER_MODE_READY requested=\(purpose.label) " +
        "actual=\(transferModeCoordinator.currentPurpose.label) reason=\(reason)"
      )
      return !actions.isEmpty
    } catch {
      transferModeCoordinator.recordPreparationFailed()
      report(
        "[OBS] PTP_TRANSFER_MODE_PREPARE_FAILED requested=\(purpose.label) " +
        "actual=\(transferModeCoordinator.currentPurpose.label) reason=\(reason) " +
        "error=\(error.localizedDescription)"
      )
      throw error
    }
  }

  @discardableResult
  private func resetTransferMode(
    reason: String,
    handle: UInt32? = nil
  ) throws -> Bool {
    let before = transferModeCoordinator.currentPurpose
    let actions = transferModeCoordinator.actionsForReset()
    report(
      "[OBS] PTP_TRANSFER_MODE_PREPARE before=\(before.label) requested=reset " +
      "actions=\(actions.count) reason=\(reason)"
    )
    do {
      for action in actions {
        switch action {
        case .setProperty(let property):
          _ = try setCameraVendorTransferModeProperty(
            property,
            handle: handle,
            purpose: .reset,
            reason: reason
          )
        }
      }
      transferModeCoordinator.recordResetSucceeded()
      report(
        "[OBS] PTP_TRANSFER_MODE_READY requested=reset actual=reset reason=\(reason)"
      )
      return !actions.isEmpty
    } catch {
      transferModeCoordinator.recordResetFailed()
      report(
        "[OBS] PTP_TRANSFER_MODE_RESET_FAILED before=\(before.label) reason=\(reason) " +
        "error=\(error.localizedDescription)"
      )
      throw error
    }
  }

  func resetCameraVendorCompressionMode() throws {
    do {
      report("按 ReferenceApp resetCompressionMode 写入 ImageForceCompression (0xD226 = 0)")
      _ = try resetTransferMode(reason: "resetCompressionMode")

      report("按 ReferenceApp resetCompressionMode 写入 ImageCompressionRealInfo (0xD227 = 0)")
      let realInfoResponse = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
        data: littleEndianData(UInt32(0))
      )
      report("[OBS] PTP_SET_IMAGE_COMPRESSION_REAL_INFO_ZERO response=0x\(String(format: "%04X", realInfoResponse.responseCode))")
    } catch {
      transferModeCoordinator.recordResetFailed()
      throw error
    }
  }

  @discardableResult
  private func setCameraVendorTransferModeProperty(
    _ property: CameraVendorDownloadModeProperty,
    handle: UInt32?,
    purpose: CameraVendorPhysicalTransferPurpose,
    reason: String
  ) throws -> CameraVendorOperationResponse {
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [property.code],
      data: CameraVendorDownloadModePolicy.payload(for: property)
    )
    report(
      "[OBS] PTP_TRANSFER_MODE_PROPERTY " +
      "handle=\(handle.map { String(format: "0x%08X", $0) } ?? "none") " +
      "purpose=\(purpose.label) reason=\(reason) " +
      "prop=0x\(String(format: "%04X", property.code)) value=\(property.value) " +
      "width=\(property.width) response=0x\(String(format: "%04X", response.responseCode))"
    )
    if purpose == .compressedDownload || purpose == .originalDownload {
      report(
        "[OBS] PTP_DOWNLOAD_MODE_PROPERTY " +
        "handle=\(handle.map { String(format: "0x%08X", $0) } ?? "none") " +
        "mode=\(purpose.label) reason=\(reason) " +
        "prop=0x\(String(format: "%04X", property.code)) value=\(property.value) " +
        "width=\(property.width) response=0x\(String(format: "%04X", response.responseCode))"
      )
    }
    return response
  }

  @discardableResult
  private func setCameraVendorDownloadModeProperty(
    _ property: CameraVendorDownloadModeProperty,
    handle: UInt32,
    mode: CameraVendorTransferDownloadMode,
    reason: String
  ) throws -> CameraVendorOperationResponse {
    try setCameraVendorTransferModeProperty(
      property,
      handle: handle,
      purpose: physicalPurpose(for: mode),
      reason: reason
    )
  }

  private func requestCameraVendorCardSlotStatus() throws {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.dualSlotStatus,
      name: "CameraVendor/ReferenceApp CardSlotStatus/DualSlotStatus (0xD244)"
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    cameraVendorCurrentSlotStatus = data.first
    report("[OBS] PTP_CARD_SLOT_STATUS bytes=\(data.count) hex=\(hex)")
  }

  private func setCameraVendorCardSlotStatus(_ slotStatus: UInt32) throws {
    report("按 ReferenceApp ChangeCardSlot 写入 DualSlotStatus (0xD244 = \(slotStatus))")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.dualSlotStatus],
      data: littleEndianData(slotStatus)
    )
    report("[OBS] PTP_SET_CARD_SLOT_STATUS status=\(slotStatus) response=0x\(String(format: "%04X", response.responseCode))")
    try requestCameraVendorCardSlotStatus()
  }

  @discardableResult
  private func requestCameraVendorSpecifiedObjectSnapshot(
    stage: String,
    allowsEmptyRetry: Bool = true
  ) throws -> CameraVendorSpecifiedObjectSnapshot {
    var retryCount = 0
    while true {
      let attemptStage = retryCount == 0 ? stage : "\(stage)-empty-retry-\(retryCount)"
      report("[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_BEGIN stage=\(attemptStage)")
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_9053")
      }
      try requestCameraVendorSpecifiedObjectCountGroupByDate(stage: attemptStage)
      if CameraVendorCatalogWireRequestPolicy.shouldRefreshGalleryContextBeforeSpecifiedList {
        let context = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
          name: "CameraVendor/ReferenceApp 图库上下文 before specified list (0xD212)"
        )
        reportCameraVendorGalleryContextMarker(context)
        report("[OBS] PTP_D212_BEFORE_SPECIFIED_LIST stage=\(attemptStage) bytes=\(context.map { String(format: "%02x", $0) }.joined(separator: ""))")
        if attemptStage == "initial-camera-catalog" {
          report("[OBS] PTP_FACTORY_D212_4 bytes=\(context.count)")
        }
      }
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_D620")
      }
      let count = try requestCameraVendorSpecifiedObjectCount(stage: attemptStage)
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_D621")
      }
      let handles = try requestCameraVendorSpecifiedObjectHandles(stage: attemptStage)
      let snapshot = CameraVendorSpecifiedObjectSnapshot(
        declaredCount: count,
        dateGroups: cameraVendorSpecifiedObjectDateGroups,
        handles: handles
      )
      report(
        "[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_END stage=\(attemptStage) " +
        "count=\(count.map(String.init) ?? "nil") handles=\(handles.count)"
      )

      guard CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: count,
        handles: handles,
        retryCount: retryCount,
        isRequiredPrimaryList: allowsEmptyRetry
      ) else {
        return snapshot
      }

      retryCount += 1
      report(
        "[OBS] PTP_SPECIFIED_OBJECT_EMPTY_RECOVERY " +
        "stage=\(stage) retry=\(retryCount) delay=\(String(format: "%.1f", CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.retryDelaySeconds))"
      )
      Thread.sleep(forTimeInterval: CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.retryDelaySeconds)
      try requestCameraVendorSearchModeDescAll()
      if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList {
        try requestCameraVendorCurrentObjectHandleSnapshot(stage: "\(stage)-empty-recovery")
      }
    }
  }

  private func requestCameraVendorSpecifiedObjectCountGroupByDate(stage: String = "default") throws {
    report("按 ReferenceApp 图片列表链请求 SpecifiedObjectCountGroupByDate (0x9053, offset=0, count=30000) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate),
      parameters: [0, 30000]
    )
    let groups = CameraVendorPtpDataParser.specifiedObjectDateGroups(from: data)
    cameraVendorSpecifiedObjectDateGroups = groups
    let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
    let groupSummary = groups.map { "\($0.dateText):\($0.objectCount)" }.joined(separator: ",")
    report("[OBS] PTP_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE stage=\(stage) bytes=\(data.count) groups=\(groupSummary) head=\(preview)")
  }

  private func requestCameraVendorSpecifiedObjectCount(stage: String = "default") throws -> UInt32? {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.specifiedObjectCount,
      name: "CameraVendor/ReferenceApp SpecifiedObjectCount (0xD620)"
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    let value = data.count >= 4
      ? UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
      : nil
    report("[OBS] PTP_SPECIFIED_OBJECT_COUNT stage=\(stage) bytes=\(data.count) value=\(value.map(String.init) ?? "nil") hex=\(hex)")
    return value
  }

  private func requestCameraVendorSpecifiedObjectHandles(stage: String = "default") throws -> [UInt32] {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.specifiedObjectHandles,
      name: "CameraVendor/ReferenceApp SpecifiedObjectHandles (0xD621)"
    )
    let handles = CameraVendorPtpDataParser.uint32Array(from: data)
    cameraVendorSpecifiedObjectHandles = handles
    report(
      CameraDiagnosticPayloadSummary.specifiedHandles(
        stage: stage,
        rawData: data,
        handles: handles
      )
    )
    return handles
  }

  private func readCameraVendorDeviceProperty(
    code: UInt32,
    name: String,
    timingHandler: ((CameraVendorDataCommandTiming, Int) -> Void)? = nil
  ) throws -> Data {
    report("读取 \(name)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [code],
      timingHandler: timingHandler
    )
    if code != CameraVendorDevicePropCode.specifiedObjectHandles {
      report(
        "[OBS] PTP_DEVICE_PROPERTY_DATA direction=cameraToApp " +
        "code=\(String(format: "0x%08X", code)) name=\(name) " +
        CameraDiagnosticPayloadSummary.controlSignal(
          name: "payload",
          direction: .cameraToApp,
          data: data
        )
      )
    }
    return data
  }

  private func validateCameraVendorGalleryReadyMarker(_ context: Data) throws {
    let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: context
    )
    if CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: marker) {
      report("[OBS] PTP_D222_READY value=\(marker.map { String(format: "0x%04X", $0) } ?? "nil")")
      return
    }
    let actual = marker.map { String(format: "0x%04X", $0) } ?? "nil"
    if CameraVendorGalleryHandshakeDiagnosticPolicy.isD222ObservationOnly(
      hasSuccessfulPtpHandshake: true,
      marker: marker
    ) {
      report("[OBS] PTP_D222_NOT_READY_DIAGNOSTIC value=\(actual) expected=0x0992")
      return
    }
    report("[OBS] PTP_D222_NOT_READY_DIAGNOSTIC value=\(actual) expected=0x0992")
  }

  private func littleEndianData(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  private func littleEndianData(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  private func cameraVendorPropValueDescription(_ data: Data) -> String {
    let hex = data.map { String(format: "%02x", $0) }.joined()
    if data.count >= 4 {
      let value = UInt32(data[0]) |
        (UInt32(data[1]) << 8) |
        (UInt32(data[2]) << 16) |
        (UInt32(data[3]) << 24)
      return "\(value) hex=\(hex)"
    }
    if data.count >= 2 {
      let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
      return "\(value) hex=\(hex)"
    }
    return "bytes=\(data.count) hex=\(hex)"
  }

  private func waitForCameraAccess() throws {
    let maxPolls = 40
    for i in 1...maxPolls {
      do {
        let stateData = try sendCommandForData(
          operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
          parameters: [CameraVendorDevicePropCode.cameraState]
        )
        if stateData.count >= 2 {
          let state = stateData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
          report("CameraState 轮询 #\(i): 0x\(String(state, radix: 16))")
          if state != 0 {
            report("相机已授权访问")
            return
          }
        }
      } catch {
        report("CameraState 轮询 #\(i) 失败: \(error.localizedDescription)")
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
    report("相机授权等待超时，继续尝试")
  }

  private func performInitHandshake(
    host: String,
    clientName: String,
    strategy: PtpInitStrategyDefinition,
    clientIP: String? = nil
  ) throws -> (connectionNumber: UInt32, operationTransport: CameraVendorPtpOperationTransport) {
    let resolvedClientIP = clientIP ?? getWifiIPv4Address()
    report("客户端 IP: \(resolvedClientIP ?? "nil")")
    report("PTP 客户端名称: \(clientName)")
    report("[OBS] PTP_INIT_CONTEXT clientIP=\(resolvedClientIP ?? "nil") clientName=\(clientName)")

    let attempts = CameraVendorOfficialGalleryPtpInitPolicy.initAttempts(
      packetVariants: strategy.packetVariants,
      clientName: clientName,
      clientIP: resolvedClientIP,
      timeout: strategy.retryTiming.perPacketAckTimeoutSeconds
    )

    var lastError: Error?
    for (index, attempt) in attempts.enumerated() {
      if index > 0, strategy.retryTiming.reconnectSocketBetweenPacketVariants {
        report("重新建立 PTP socket，尝试 \(attempt.name) INIT")
        commandSocket.close()
        try commandSocket.connect(
          host: host,
          port: CameraVendorPtpConstants.commandPort,
          timeout: CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
          diagnosticHandler: diagnosticHandler,
          networkServiceProfile: networkServiceProfile,
          socketBufferProfile: socketBufferProfile,
          tcpNoDelayPolicy: tcpNoDelayPolicy
        )
      }

      do {
        let connectionNumber = try sendInitCommandRequest(
          packet: attempt.packet,
          variantName: attempt.name,
          timeout: attempt.timeout,
          ackParser: strategy.ackParser
        )
        return (connectionNumber, .cameraVendorLegacy)
      } catch {
        lastError = error
        report("\(attempt.name) INIT 未收到 ACK: \(error.localizedDescription)")
      }
    }

    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "PTP 初始化失败"]
    )
  }

  private func sendInitCommandRequest(
    packet: Data,
    variantName: String,
    timeout: TimeInterval,
    ackParser: PtpInitAckParserID = .currentLegacyTypeAndConnectionNumber
  ) throws -> UInt32 {
    report("发送 \(variantName) PTP INIT_COMMAND_REQUEST (\(packet.count) bytes)")
    report(
      "[OBS] PTP_INIT_REQUEST direction=appToCamera variant=\(variantName) " +
      CameraDiagnosticPayloadSummary.controlSignal(
        name: "packet",
        direction: .appToCamera,
        data: packet
      )
    )
    try commandSocket.write(packet)
    Thread.sleep(forTimeInterval: 0.05)
    report("等待 \(variantName) PTP INIT_COMMAND_ACK (超时 \(Int(timeout))s)")
    let initAck = try readPacket(from: commandSocket, timeout: timeout)
    report(
      "[OBS] PTP_INIT_ACK_PACKET direction=cameraToApp variant=\(variantName) type=\(initAck.type) " +
      CameraDiagnosticPayloadSummary.controlSignal(
        name: "payload",
        direction: .cameraToApp,
        data: initAck.payload
      )
    )
    switch ackParser {
    case .currentLegacyTypeAndConnectionNumber:
      break
    }
    if initAck.type == CameraVendorPtpPacketType.initFail {
      let reason = initAck.payload.count >= 4
        ? "0x\(String(initAck.payload.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }, radix: 16))"
        : "unknown"
      throw NSError(domain: "CameraVendorPtpSession", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "相机拒绝连接 (InitFail reason=\(reason))。可能需要在相机上选择「更改」以接受新客户端。"
      ])
    }
    guard initAck.type == CameraVendorPtpPacketType.initCommandAck else {
      throw NSError(domain: "CameraVendorPtpSession", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "相机返回未知包类型 \(initAck.type)，期望 InitCommandAck"
      ])
    }
    guard initAck.payload.count >= 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "PTP 初始化 ACK 长度异常"])
    }
    return initAck.payload.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
  }

  func storageIDs() throws -> [UInt32] {
    report("请求 storage IDs")
    let ids = CameraVendorPtpDataParser.uint32Array(
      from: try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getStorageIDs))
    )
    report("收到 storage IDs: \(ids.map(String.init).joined(separator: ", "))")
    return ids
  }

  func objectHandles(storageID: UInt32) throws -> [UInt32] {
    report("请求对象句柄，storageID \(storageID)")
    let handles = CameraVendorPtpDataParser.uint32Array(
      from: try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.getObjectHandles),
        parameters: [storageID, UInt32(CameraVendorPtpConstants.allFormats), UInt32(bitPattern: Int32(-1))]
      )
    )
    report("收到对象句柄 \(handles.count) 个，storageID \(storageID)")
    return handles
  }

  func objectInfo(
    handle: UInt32,
    readTimeout: TimeInterval = 15
  ) throws -> CameraVendorCameraObjectInfo {
    report("请求对象信息 handle \(handle)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getObjectInfo),
      parameters: [handle],
      readTimeout: readTimeout
    )
    let info = CameraVendorPtpDataParser.objectInfo(handle: Int(handle), data: data)
    report(
      "对象 \(handle): \(info.filename) \(info.formatLabel) " +
      "size=\(info.compressedSize) thumbSize=\(info.thumbCompressedSize) captureDate=\(info.captureDate)"
    )
    return info
  }

  func reservedReceiveObjectInfo() throws -> CameraVendorCameraObjectInfo {
    let handle = CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle
    report("[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_INFO_BEGIN handle=0x\(String(format: "%08X", handle))")
    let info = try objectInfo(handle: handle)
    report(
      "[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_INFO_OK " +
      "handle=\(info.handle) format=\(info.formatLabel) filename=\(info.filename) size=\(info.compressedSize)"
    )
    return info
  }

  func reservedReceiveDiagnosticObject() throws -> CameraVendorReservedReceiveDiagnosticResult {
    let handle = CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle
    let info = try reservedReceiveObjectInfo()

    let sample = try readObjectSample(
      handle: handle,
      byteCount: CameraVendorReferenceAppReservedReceiveProbePolicy.sampleReadBytes
    )
    report(
      "[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_SAMPLE_OK " +
      "handle=0x\(String(format: "%08X", handle)) bytes=\(sample.count)"
    )
    return CameraVendorReservedReceiveDiagnosticResult(
      objectInfo: info,
      sampleByteCount: sample.count
    )
  }

  func cameraVendorLatestObjectInfo(
    preferredHandle: UInt32? = nil,
    readTimeout: TimeInterval = 15
  ) throws -> CameraVendorCameraObjectInfo {
    try prepareCameraVendorVendorGalleryCommands()
    let handle = preferredHandle ?? cameraVendorCurrentObjectHandleForLatestProbe()
      ?? CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report("请求 CameraVendor 专有图库首图信息 (0x9054, handle 0x\(String(format: "%08X", handle)))")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
      parameters: [handle],
      readTimeout: readTimeout
    )
    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: Int(handle), data: data)
    report("CameraVendor 专有图库首图: \(info.filename) \(info.formatLabel)")
    return info
  }

  private func cameraVendorCurrentObjectHandleForLatestProbe() -> UInt32? {
    guard CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleBeforeLatestProbe else {
      return nil
    }
    if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleViaObjectPropList,
       let currentHandle = try? readCameraVendorCurrentObjectHandleViaObjectPropList(),
       currentHandle != 0 {
      return currentHandle
    }
    do {
      if let currentHandle = try readCameraVendorCurrentObjectHandle(), currentHandle != 0 {
        return currentHandle
      }
    } catch {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_FAILED error=\(error.localizedDescription)")
    }
    return nil
  }

  private func readCameraVendorCurrentObjectHandleViaObjectPropList() throws -> UInt32? {
    report("尝试 MTP GetObjectPropList 读取当前对象 handle (0x9805 / 0xD22B)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.mtpGetObjectPropList),
      parameters: CameraVendorPtpPacketBuilder.mtpObjectPropListParameters(
        objectHandle: UInt32(bitPattern: -1),
        propertyCode: CameraVendorDevicePropCode.currentObjectHandle
      )
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_OBJECT_PROP_LIST_D22B bytes=\(data.count) hex=\(hex)")
    guard data.count >= 16 else {
      return nil
    }
    let tail = data.count - 4
    let candidate =
      UInt32(data[tail]) |
      (UInt32(data[tail + 1]) << 8) |
      (UInt32(data[tail + 2]) << 16) |
      (UInt32(data[tail + 3]) << 24)
    report("[OBS] PTP_OBJECT_PROP_LIST_D22B_CANDIDATE_HANDLE value=0x\(String(format: "%08X", candidate))")
    return candidate
  }

  private func readCameraVendorCurrentObjectHandle() throws -> UInt32? {
    report("读取 CameraVendor/ReferenceApp 当前对象 handle (0xD22B)")
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.currentObjectHandle,
      name: "CameraVendor/ReferenceApp 当前对象 handle (0xD22B)",
      timingHandler: { [weak self] timing, byteCount in
        self?.report(
          CameraVendorDataCommandTimingLogPolicy.completedMessage(
            operationCode: 0xD22B,
            handle: nil,
            byteCount: byteCount,
            timing: timing
          )
        )
      }
    )
    guard data.count >= 4 else {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SHORT bytes=\(data.count)")
      return nil
    }
    let handle = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    report("[OBS] PTP_CURRENT_OBJECT_HANDLE value=0x\(String(format: "%08X", handle))")
    return handle
  }

  private func prepareCameraVendorVendorGalleryCommands() throws {
    report("CameraVendor/ReferenceApp 图库前置命令已按 ReferenceApp 顺序完成，直接请求 0x9054")
  }

  private func reportCameraVendorGalleryContextMarker(_ context: Data) {
    let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: context
    )
    report(
      "CameraVendor/ReferenceApp 图库上下文 0xD222=" +
      (marker.map { String(format: "0x%04X", $0) } ?? "nil") +
      " (ReferenceApp ready=0x\(String(format: "%04X", CameraVendorReferenceAppGalleryReadyPolicy.readyMarker)))"
    )
  }

  func thumb(handle: UInt32) throws -> Data {
    try thumb(handle: handle, expectedSize: nil)
  }

  func thumb(handle: UInt32, expectedSize: UInt32?) throws -> Data {
    try thumbWithInfo(handle: handle, expectedSize: expectedSize).data
  }

  func thumbWithInfo(handle: UInt32, expectedSize: UInt32?) throws -> CameraVendorThumbnailFetchResult {
    let operationInterruptionGeneration = priorityDownloadInterruptionGeneration
    var standardGetThumbError: Error?
    if CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst {
      do {
        let result = try readStandardThumbnailObjectWithInfo(handle: handle)
        return CameraVendorThumbnailFetchResult(
          data: normalizedThumbnailData(result.data, handle: handle, source: "standardGetThumb"),
          objectInfo: result.objectInfo
        )
      } catch {
        standardGetThumbError = error
        report("[OBS] PTP_GET_THUMB_FALLBACK_TO_PARTIAL handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }

    let wasInterruptedForPriorityDownload =
      priorityDownloadInterruptionGeneration != operationInterruptionGeneration
    guard CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
      afterPriorityDownloadInterruption: wasInterruptedForPriorityDownload,
      isConnected: isConnected
    ) else {
      report("[OBS] PTP_GET_THUMB_PARTIAL_FALLBACK_SKIPPED_FOR_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw standardGetThumbError ?? CancellationError()
    }

    guard CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback else {
      throw standardGetThumbError ?? NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorPtpOperationCode.getThumb),
        userInfo: [
          NSLocalizedDescriptionKey: "Thumbnail fallback is disabled"
        ]
      )
    }

    let data = try readPreviewObject(handle: handle, size: CameraVendorThumbnailFetchPolicy.partialPreviewReadSize)
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW_EXPECTED handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0) bytes=\(data.count)")
    return CameraVendorThumbnailFetchResult(
      data: normalizedThumbnailData(data, handle: handle, source: "standardPartialPreview"),
      objectInfo: nil
    )
  }

  private func readStandardThumbnailObject(handle: UInt32) throws -> Data {
    try readStandardThumbnailObjectWithInfo(handle: handle).data
  }

  private func readStandardThumbnailObjectWithInfo(handle: UInt32) throws -> CameraVendorThumbnailFetchResult {
    let primedObjectInfo = CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb
      ? primeThumbnailObjectContext(handle: handle)
      : nil

    report("[OBS] PTP_GET_THUMB_REQUEST handle=0x\(String(format: "%08X", handle))")
    let startedAt = Date()
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getThumb),
      parameters: [handle],
      readTimeout: CameraVendorThumbnailFetchPolicy.standardGetThumbReadTimeoutSeconds
    )
    report(
      "[OBS] PTP_GET_THUMB_DATA bytes=\(data.count) handle=0x\(String(format: "%08X", handle)) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
    guard data.count >= CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorPtpOperationCode.getThumb),
        userInfo: [
          NSLocalizedDescriptionKey: "GetThumb returned too few bytes: \(data.count)"
        ]
      )
    }
    let resolvedObjectInfo = primedObjectInfo ?? recoverThumbnailObjectInfoAfterGetThumb(handle: handle)
    // The catalog merge keeps its confirmed identity fields. Carry ObjectInfo
    // with this thumbnail so format and orientation reach the renderer together.
    return try CameraVendorThumbnailResultPolicy.result(
      data: data,
      primedObjectInfo: resolvedObjectInfo
    )
  }

  private func recoverThumbnailObjectInfoAfterGetThumb(
    handle: UInt32
  ) -> CameraVendorCameraObjectInfo? {
    let startedAt = Date()
    do {
      let info = try objectInfo(
        handle: handle,
        readTimeout: CameraVendorThumbnailFetchPolicy.postGetThumbObjectInfoReadTimeoutSeconds
      )
      report(
        "[OBS] PTP_GET_THUMB_CONTEXT_RECOVERED handle=0x\(String(format: "%08X", handle)) " +
        "format=0x\(String(format: "%04X", info.formatCode)) " +
        "orientation=\(info.orientation.map(String.init) ?? "unknown") " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
      )
      return info
    } catch {
      report(
        "[OBS] PTP_GET_THUMB_CONTEXT_RECOVERY_FAILED handle=0x\(String(format: "%08X", handle)) " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)"
      )
      return nil
    }
  }

  private func primeThumbnailObjectContext(handle: UInt32) -> CameraVendorCameraObjectInfo? {
    let startedAt = Date()
    do {
      let info = try cameraVendorLatestObjectInfo(
        preferredHandle: handle,
        readTimeout: CameraVendorThumbnailFetchPolicy.objectInfoReadTimeoutSeconds
      )
      report(
        "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED handle=0x\(String(format: "%08X", handle)) " +
        "format=0x\(String(format: "%04X", info.formatCode)) thumbBytes=\(info.thumbCompressedSize) " +
        "orientation=\(info.orientation.map(String.init) ?? "unknown") " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
      )
      return info
    } catch {
      report(
        "[OBS] PTP_GET_THUMB_VENDOR_CONTEXT_PRIME_FAILED handle=0x\(String(format: "%08X", handle)) " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)"
      )
      do {
        let fallbackStartedAt = Date()
        let info = try objectInfo(
          handle: handle,
          readTimeout: CameraVendorThumbnailFetchPolicy.objectInfoReadTimeoutSeconds
        )
        report(
          "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED_STANDARD handle=0x\(String(format: "%08X", handle)) " +
          "format=0x\(String(format: "%04X", info.formatCode)) thumbBytes=\(info.thumbCompressedSize) " +
          "orientation=\(info.orientation.map(String.init) ?? "unknown") " +
          "elapsedMs=\(Int(Date().timeIntervalSince(fallbackStartedAt) * 1000))"
        )
        return info
      } catch {
        report(
          "[OBS] PTP_GET_THUMB_CONTEXT_PRIME_FAILED handle=0x\(String(format: "%08X", handle)) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)"
        )
        return nil
      }
    }
  }

  private func readPreviewObject(handle: UInt32, size previewReadSize: UInt32) throws -> Data {
    let maximumBytes = UInt64(min(
      previewReadSize,
      CameraVendorPreviewImageReadPolicy.maximumScreenPreviewBytes
    ))
    var result = Data()
    var offset: UInt64 = 0
    var selectedReadSize = CameraVendorPreviewImageReadPolicy.initialReadSize
    var previousLastByte: UInt8?

    while offset < maximumBytes {
      let requestSize = CameraVendorPreviewImageReadPolicy.requestSize(
        remaining: maximumBytes - offset,
        selectedReadSize: selectedReadSize
      )
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=preview " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize)"
      )
      let chunk: Data
      do {
        chunk = try sendCommandForData(
          operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
          parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
            handle: handle,
            offset: offset,
            size: requestSize
          )
        )
      } catch {
        if let fallback = CameraVendorPreviewImageReadPolicy.fallbackReadSize(after: selectedReadSize) {
          report(
            "[OBS] PTP_PREVIEW_PARTIAL_FALLBACK handle=0x\(String(format: "%08X", handle)) " +
            "offset=\(offset) from=\(selectedReadSize) to=\(fallback) error=\(error.localizedDescription)"
          )
          selectedReadSize = fallback
          continue
        }
        throw error
      }

      if chunk.isEmpty { break }
      result.append(chunk)
      offset += UInt64(chunk.count)
      let isComplete = CameraVendorPreviewImageReadPolicy.shouldStopAfterChunk(
        previousLastByte: previousLastByte,
        chunk: chunk,
        totalBytes: offset,
        maximumBytes: maximumBytes
      )
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW_CHUNK " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset)/\(maximumBytes) " +
        "bytes=\(chunk.count) readSize=\(selectedReadSize) complete=\(isComplete)"
      )
      if isComplete || chunk.count < Int(requestSize) { break }
      previousLastByte = chunk.last
    }
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW bytes=\(result.count) handle=0x\(String(format: "%08X", handle))")
    return result
  }

  func previewImage(handle: UInt32) throws -> Data {
    try previewImageWithInfo(handle: handle).data
  }

  func previewImageWithInfo(handle: UInt32) throws -> CameraVendorPreviewImageFetchResult {
    report("[OBS] PTP_PREVIEW_IMAGE_REQUEST handle=0x\(String(format: "%08X", handle))")
    try prepareTransferMode(
      .screenPreview,
      handle: handle,
      reason: "previewImage"
    )
    defer {
      do {
        try resetTransferMode(reason: "previewImageReset", handle: handle)
      } catch {
        report("[OBS] PTP_PREVIEW_IMAGE_RESET_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }
    let originalInfo = try objectInfo(handle: handle)
    var companionInfo: CameraVendorCameraObjectInfo?
    if let companionHandle = CameraVendorPreviewImageSourcePolicy.companionCandidateHandle(
      for: originalInfo
    ) {
      do {
        companionInfo = try objectInfo(handle: companionHandle)
      } catch {
        report(
          "[OBS] PTP_RAW_PREVIEW_COMPANION_REJECTED " +
          "rawHandle=0x\(String(format: "%08X", handle)) " +
          "candidateHandle=0x\(String(format: "%08X", companionHandle)) " +
          "reason=object-info-read-failed error=\(error.localizedDescription)"
        )
      }
    }
    guard let source = CameraVendorPreviewImageSourcePolicy.source(
      originalInfo: originalInfo,
      companionInfo: companionInfo
    ) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 22,
        userInfo: [NSLocalizedDescriptionKey: "Compressed preview size unavailable handle=\(handle) size=\(originalInfo.compressedSize)"]
      )
    }

    let image: Data
    let sourceDescription: String
    switch source {
    case .compressedObject(let previewHandle, let previewSize):
      if previewHandle != handle, let companionInfo {
        report(
          "[OBS] PTP_RAW_PREVIEW_COMPANION_SELECTED " +
          "rawHandle=0x\(String(format: "%08X", handle)) " +
          "companionHandle=0x\(String(format: "%08X", previewHandle)) " +
          "rawFilename=\(originalInfo.filename) companionFilename=\(companionInfo.filename) " +
          "companionFormat=\(companionInfo.formatLabel) companionSize=\(previewSize)"
        )
      }
      let data = try readPreviewObject(handle: previewHandle, size: previewSize)
      image = CameraVendorImageDataNormalizer.imageData(from: data)
      sourceDescription =
        "compressedObject sourceHandle=0x\(String(format: "%08X", previewHandle)) " +
        "rawBytes=\(data.count) readSize=\(previewSize)"
    case .standardThumbnail(let thumbnailHandle):
      if let companionInfo {
        report(
          "[OBS] PTP_RAW_PREVIEW_COMPANION_REJECTED " +
          "rawHandle=0x\(String(format: "%08X", handle)) " +
          "candidateHandle=0x\(String(format: "%08X", UInt32(clamping: companionInfo.handle))) " +
          "reason=metadata-mismatch rawFilename=\(originalInfo.filename) " +
          "candidateFilename=\(companionInfo.filename) candidateFormat=\(companionInfo.formatLabel) " +
          "candidateSize=\(companionInfo.compressedSize)"
        )
      }
      report(
        "[OBS] PTP_RAW_PREVIEW_THUMB_FALLBACK " +
        "handle=0x\(String(format: "%08X", thumbnailHandle)) " +
        "filename=\(originalInfo.filename) rawSize=\(originalInfo.compressedSize)"
      )
      let thumbnail = try readStandardThumbnailObjectWithInfo(handle: thumbnailHandle)
      image = normalizedThumbnailData(
        thumbnail.data,
        handle: thumbnailHandle,
        source: "rawPreviewStandardGetThumb"
      )
      sourceDescription = "standardThumbnail sourceHandle=0x\(String(format: "%08X", thumbnailHandle))"
    }

    guard CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(image) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 23,
        userInfo: [
          NSLocalizedDescriptionKey: "Preview image invalid handle=\(handle) bytes=\(image.count) head=\(CameraVendorDownloadDataDiagnosticPolicy.headHex(from: image))"
        ]
      )
    }
    report(
      "[OBS] PTP_PREVIEW_IMAGE_COMPRESSED handle=0x\(String(format: "%08X", handle)) " +
      "imageBytes=\(image.count) \(sourceDescription) object=\(originalInfo.formatLabel)"
    )
    return CameraVendorPreviewImageFetchResult(data: image, objectInfo: originalInfo)
  }

  private func readObjectSample(handle: UInt32, byteCount: UInt32) throws -> Data {
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=reserved-receive-sample " +
      "handle=0x\(String(format: "%08X", handle)) offset=0 size=\(byteCount)"
    )
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: handle,
        offset: 0,
        size: byteCount
      )
    )
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_SAMPLE bytes=\(data.count) handle=0x\(String(format: "%08X", handle))")
    return data
  }

  private func readObjectByPartialObjects(
    handle: UInt32,
    expectedSize: UInt32?,
    purpose: String,
    usesFileDownloadChunks: Bool = true
  ) throws -> Data {
    var received = Data()
    if let expected = expectedSize, expected > 0 {
      // Pre-allocate so chunk appends don't trigger O(n) reallocations.
      received.reserveCapacity(Int(expected))
    }
    var offset: UInt64 = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(
      expectedSize: expectedSize
    )
    var isJpegObject = false
    let startedAt = Date()
    let cachedReadSize = usesFileDownloadChunks
      ? originalTransferCapabilityStore.readSize(serialNumber: transferCapabilitySerialNumber)
      : nil
    let initialReadSize = CameraVendorTransferChunkProfile.preferredReadSize(
      cachedReadSize: cachedReadSize
    )
    var selectedReadSize = initialReadSize

    while offset < maxByteCount {
      let remaining = maxByteCount - offset
      let requestSize = usesFileDownloadChunks
        ? CameraVendorTransferChunkProfile.requestSize(
          remaining: remaining,
          selectedReadSize: selectedReadSize
        )
        : UInt32(min(UInt64(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize), remaining))
      let chunkStartedAt = Date()
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) expected=\(expectedSize ?? 0)"
      )
      let parameters = CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: handle,
        offset: offset,
        size: requestSize
      )
      let chunk: Data
      do {
        chunk = usesFileDownloadChunks
          ? try sendCommandForData(
            operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
            parameters: parameters,
            readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
          )
          : try sendCommandForData(
            operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
            parameters: parameters
          )
      } catch {
        if usesFileDownloadChunks,
           CameraVendorTransferChunkProfile.shouldFallback(
             after: error,
             sessionIsConnected: isConnected
           ), let fallbackReadSize = CameraVendorTransferChunkProfile.fallbackReadSize(
             after: selectedReadSize
           ) {
          selectedReadSize = fallbackReadSize
          continue
        }
        throw error
      }
      guard !chunk.isEmpty else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }

      received.append(chunk)
      if offset == 0 {
        isJpegObject = CameraVendorJpegDataPolicy.hasStartMarker(CameraVendorImageDataNormalizer.imageData(from: received))
      }
      offset += UInt64(chunk.count)
      let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(chunk.count) " +
        "totalBytes=\(received.count) chunkMs=\(chunkElapsedMs) " +
        "isJpeg=\(isJpegObject)"
      )

      let hasJpegEndMarker = CameraVendorJpegDataPolicy.hasEndMarker(received)
      if CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: received.count,
        expectedBytes: expectedByteCount,
        isJpegObject: isJpegObject,
        hasJpegEndMarker: hasJpegEndMarker
      ) {
        if usesFileDownloadChunks,
           CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
             totalBytes: received.count,
             expectedBytes: expectedByteCount,
             hasJpegEndMarker: hasJpegEndMarker
           ) {
          _ = persistOriginalTransferCapability(readSize: selectedReadSize)
        }
        let reason = hasJpegEndMarker ? "jpeg-eoi" : "expected-size"
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=\(reason) " +
          "handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
        return received
      }
    }

    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=max-or-empty " +
      "handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
    return received
  }

  private struct CameraVendorPartialObjectFileTransferResult {
    let byteCount: Int
    let requestToFirstByteMs: Int
    let socketReceiveMs: Int
    let fileWriteMs: Int
    let elapsedMs: Int
    let executor: String
    let initialReadSize: UInt32
    let finalReadSize: UInt32
    let fallbackCount: Int
  }

  private func readObjectByPartialObjectsToFile(
    handle: UInt32,
    expectedSize: UInt32?,
    fileURL: URL,
    purpose: String,
    formatLabel: String,
    downloadMode: CameraVendorTransferDownloadMode,
    cancellationGeneration: UInt64,
    negotiatedReadSize: UInt32?
  ) throws -> CameraVendorPartialObjectFileTransferResult {
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    let handleForWriting = try FileHandle(forWritingTo: fileURL)
    defer {
      try? handleForWriting.close()
    }

    var offset: UInt64 = 0
    var totalBytes = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(
      expectedSize: expectedSize
    )
    let startedAt = Date()
    let cachedReadSize = originalTransferCapabilityStore.readSize(
      serialNumber: transferCapabilitySerialNumber
    )
    let initialReadSize = CameraVendorTransferChunkProfile.preferredReadSize(
      cachedReadSize: cachedReadSize
    )
    let capabilitySource = cachedReadSize == nil ? "maximum" : "cached"
    var chunkState = CameraVendorAdaptiveDownloadChunkState(readSize: initialReadSize)
    var fallbackCount = 0
    var requestToFirstByteMs = 0
    var socketReceiveMs = 0
    var fileWriteMs = 0

    if CameraVendorOriginalReadImageExecutorPolicy.shouldUse(
      downloadMode: downloadMode,
      purpose: purpose
    ) {
      let dedicatedInitialReadSize = CameraVendorOriginalReadImageExecutorPolicy.initialReadSize(
        cachedReadSize: cachedReadSize,
        negotiatedReadSize: negotiatedReadSize
      )
      let dedicatedProfileSource = CameraVendorOriginalReadImageExecutorPolicy.profileSource(
        negotiatedReadSize: negotiatedReadSize
      )
      report(
        "[OBS] PTP_DOWNLOAD_REQUEST_PROFILE " +
        "handle=0x\(String(format: "%08X", handle)) d235=\(negotiatedReadSize ?? 0) " +
        "selectedReadSize=\(dedicatedInitialReadSize) source=\(dedicatedProfileSource)"
      )
      let executor = CameraVendorOriginalReadImageExecutor(
        nextTransactionID: {
          self.transactionID += 1
          return self.transactionID
        },
        sendRequest: { transactionID, requestedHandle, requestedOffset, requestedSize in
          self.report(
            "[OBS] PTP_ORIGINAL_READ_IMAGE_REQUEST purpose=\(purpose) " +
            "handle=0x\(String(format: "%08X", requestedHandle)) transaction=\(transactionID) " +
            "offset=\(requestedOffset) size=\(requestedSize) expected=\(expectedSize ?? 0)"
          )
          try self.sendOriginalReadImageRequest(
            transactionID: transactionID,
            handle: requestedHandle,
            offset: requestedOffset,
            size: requestedSize
          )
        },
        receivePayloadAndResponse: { transactionID, expectedMaximum, sink in
          let chunk = try self.receiveOriginalReadImagePayloadAndResponse(
            transactionID: transactionID,
            expectedMaximum: expectedMaximum,
            fileHandle: sink,
            readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
          )
          return chunk
        },
        cancellationCheck: {
          try self.throwIfActiveDownloadCancelled(since: cancellationGeneration)
        },
        fallbackReadSize: { error, currentReadSize, _ in
          guard CameraVendorTransferChunkProfile.shouldFallback(
            after: error,
            sessionIsConnected: self.isConnected
          ) else {
            return nil
          }
          return CameraVendorTransferChunkProfile.fallbackReadSize(after: currentReadSize)
        },
        report: { self.report($0) }
      )
      let callerThreadID = pthread_mach_thread_np(pthread_self())
      let result = try originalTransferWorker.execute {
        let workerThreadID = pthread_mach_thread_np(pthread_self())
        self.report(
          "[OBS] PTP_ORIGINAL_TRANSFER_WORKER_BEGIN " +
          "handle=0x\(String(format: "%08X", handle)) " +
          "callerThread=\(callerThreadID) workerThread=\(workerThreadID)"
        )
        defer {
          self.report(
            "[OBS] PTP_ORIGINAL_TRANSFER_WORKER_END " +
            "handle=0x\(String(format: "%08X", handle)) " +
            "workerThread=\(workerThreadID)"
          )
        }
        return try executor.execute(
          handle: handle,
          expectedByteCount: expectedByteCount,
          maximumByteCount: maxByteCount,
          initialReadSize: dedicatedInitialReadSize,
          fileHandle: handleForWriting,
          executeOperation: { body in
            try body()
          }
        )
      }
      let capabilityPersisted = CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: result.byteCount,
        expectedBytes: expectedByteCount,
        hasJpegEndMarker: false
      ) ? persistOriginalTransferCapability(readSize: result.finalReadSize) : false
      let speedMBps = result.elapsedMs > 0
        ? (Double(result.byteCount) / 1_048_576.0) / (Double(result.elapsedMs) / 1000.0)
        : 0
      let headHex = CameraVendorDownloadDataDiagnosticPolicy.headHex(from: result.prefix)
      let ftypOffset = CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: result.prefix)
      report(
        "[OBS] PTP_ORIGINAL_RECEIVE_CADENCE " +
        "handle=0x\(String(format: "%08X", handle)) " +
        "pollWaitMs=\(result.receiveCadence.pollWaitMs) " +
        "maxPollWaitMs=\(result.receiveCadence.maxPollWaitMs) " +
        "pollWaitCount=\(result.receiveCadence.pollWaitCount) " +
        "immediatePollCount=\(result.receiveCadence.immediatePollCount) " +
        "recvCallCount=\(result.receiveCadence.recvCallCount)"
      )
      report(
        "[OBS] PTP_ORIGINAL_READ_IMAGE_HEAD purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) bytes=\(result.byteCount) " +
        "head=\(headHex) ftypOffset=\(ftypOffset.map(String.init) ?? "nil")"
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_TIMING executor=original-read-image " +
        "handle=0x\(String(format: "%08X", handle)) format=\(formatLabel) mode=\(downloadMode) " +
        "bytes=\(result.byteCount) initialReadSize=\(dedicatedInitialReadSize) finalReadSize=\(result.finalReadSize) " +
        "fallbackCount=\(result.fallbackCount) capabilitySource=\(dedicatedProfileSource) " +
        "capabilityPersisted=\(capabilityPersisted) requestToFirstByteMs=\(result.requestToFirstByteMs) " +
        "socketReceiveMs=\(result.socketReceiveMs) fileWriteMs=\(result.fileWriteMs) " +
        "elapsedMs=\(result.elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
      )
      return CameraVendorPartialObjectFileTransferResult(
        byteCount: result.byteCount,
        requestToFirstByteMs: result.requestToFirstByteMs,
        socketReceiveMs: result.socketReceiveMs,
        fileWriteMs: result.fileWriteMs,
        elapsedMs: result.elapsedMs,
        executor: "original-read-image",
        initialReadSize: dedicatedInitialReadSize,
        finalReadSize: result.finalReadSize,
        fallbackCount: result.fallbackCount
      )
    }

    while offset < maxByteCount {
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      let remaining = maxByteCount - offset
      let requestSize = CameraVendorTransferChunkProfile.requestSize(
        remaining: remaining,
        selectedReadSize: chunkState.readSize
      )
      let chunkStartedAt = Date()
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) " +
        "adaptiveReadSize=\(chunkState.readSize) strategy=\(CameraVendorAdaptiveDownloadChunkPolicy.strategyName) " +
        "slowLargeChunks=\(chunkState.consecutiveSlowLargeChunks) expected=\(expectedSize ?? 0)"
      )
      let streamedChunk: CameraVendorFileCommandResult
      do {
        streamedChunk = try sendCommandForFileData(
          operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
          parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
            handle: handle,
            offset: offset,
            size: requestSize
          ),
          fileHandle: handleForWriting,
          readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
        )
      } catch {
        if CameraVendorTransferChunkProfile.shouldFallback(
          after: error,
          sessionIsConnected: isConnected
        ), let fallbackReadSize = CameraVendorTransferChunkProfile.fallbackReadSize(after: chunkState.readSize) {
          let previousReadSize = chunkState.readSize
          chunkState.readSize = fallbackReadSize
          chunkState.consecutiveFastChunks = 0
          fallbackCount += 1
          report(
            "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_FALLBACK_READ_SIZE " +
            "handle=0x\(String(format: "%08X", handle)) offset=\(offset) " +
            "from=\(previousReadSize) to=\(chunkState.readSize) " +
            "error=\(error.localizedDescription)"
          )
          continue
        }
        throw error
      }
      requestToFirstByteMs += streamedChunk.requestToFirstByteMs
      socketReceiveMs += streamedChunk.socketReceiveMs
      fileWriteMs += streamedChunk.fileWriteMs
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      guard streamedChunk.byteCount > 0 else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }
      if offset == 0 {
        let headHex = CameraVendorDownloadDataDiagnosticPolicy.headHex(from: streamedChunk.prefix)
        let ftypOffset = CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: streamedChunk.prefix)
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_HEAD purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) bytes=\(streamedChunk.byteCount) " +
          "head=\(headHex) ftypOffset=\(ftypOffset.map(String.init) ?? "nil")"
        )
      }
      totalBytes += streamedChunk.byteCount
      offset += UInt64(streamedChunk.byteCount)
      let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
      let previousReadSize = chunkState.readSize
      CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
        byteCount: streamedChunk.byteCount,
        elapsedMs: chunkElapsedMs,
        state: &chunkState
      )
      if previousReadSize != chunkState.readSize {
        report(
          "[OBS] PTP_ADAPTIVE_CHUNK_SIZE_CHANGED purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) from=\(previousReadSize) " +
          "to=\(chunkState.readSize) strategy=\(CameraVendorAdaptiveDownloadChunkPolicy.strategyName) " +
          "chunkBytes=\(streamedChunk.byteCount) chunkMs=\(chunkElapsedMs)"
        )
      }
      report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(streamedChunk.byteCount) totalBytes=\(totalBytes) " +
        "chunkMs=\(chunkElapsedMs) nextReadSize=\(chunkState.readSize) " +
        "slowLargeChunks=\(chunkState.consecutiveSlowLargeChunks)"
      )
      if let expectedByteCount, UInt64(totalBytes) >= expectedByteCount {
        let capabilityPersisted = CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
          totalBytes: totalBytes,
          expectedBytes: expectedByteCount,
          hasJpegEndMarker: false
        ) ? persistOriginalTransferCapability(readSize: chunkState.readSize) : false
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let speedMBps = elapsedMs > 0
          ? (Double(totalBytes) / 1_048_576.0) / (Double(elapsedMs) / 1000.0)
          : 0
        report(
          "[OBS] PTP_DOWNLOAD_FILE_TIMING handle=0x\(String(format: "%08X", handle)) " +
            "format=\(formatLabel) mode=\(downloadMode) bytes=\(totalBytes) " +
            "initialReadSize=\(initialReadSize) finalReadSize=\(chunkState.readSize) " +
            "fallbackCount=\(fallbackCount) capabilitySource=\(capabilitySource) " +
            "capabilityPersisted=\(capabilityPersisted) requestToFirstByteMs=\(requestToFirstByteMs) " +
            "socketReceiveMs=\(socketReceiveMs) fileWriteMs=\(fileWriteMs) " +
            "elapsedMs=\(elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
        )
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=expected-size " +
          "handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) finalReadSize=\(chunkState.readSize)"
        )
        return CameraVendorPartialObjectFileTransferResult(
          byteCount: totalBytes,
          requestToFirstByteMs: requestToFirstByteMs,
          socketReceiveMs: socketReceiveMs,
          fileWriteMs: fileWriteMs,
          elapsedMs: elapsedMs,
          executor: "standard-partial-object",
          initialReadSize: initialReadSize,
          finalReadSize: chunkState.readSize,
          fallbackCount: fallbackCount
        )
      }
    }

    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    let speedMBps = elapsedMs > 0
      ? (Double(totalBytes) / 1_048_576.0) / (Double(elapsedMs) / 1000.0)
      : 0
    report(
      "[OBS] PTP_DOWNLOAD_FILE_TIMING handle=0x\(String(format: "%08X", handle)) " +
        "format=\(formatLabel) mode=\(downloadMode) bytes=\(totalBytes) " +
        "initialReadSize=\(initialReadSize) finalReadSize=\(chunkState.readSize) " +
        "fallbackCount=\(fallbackCount) capabilitySource=\(capabilitySource) " +
        "capabilityPersisted=false requestToFirstByteMs=\(requestToFirstByteMs) " +
        "socketReceiveMs=\(socketReceiveMs) fileWriteMs=\(fileWriteMs) " +
        "elapsedMs=\(elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
    )
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=max-or-empty " +
      "handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) finalReadSize=\(chunkState.readSize)"
    )
    return CameraVendorPartialObjectFileTransferResult(
      byteCount: totalBytes,
      requestToFirstByteMs: requestToFirstByteMs,
      socketReceiveMs: socketReceiveMs,
      fileWriteMs: fileWriteMs,
      elapsedMs: elapsedMs,
      executor: "standard-partial-object",
      initialReadSize: initialReadSize,
      finalReadSize: chunkState.readSize,
      fallbackCount: fallbackCount
    )
  }

  private func persistOriginalTransferCapability(readSize: UInt32) -> Bool {
    let serial = transferCapabilitySerialNumber?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !serial.isEmpty, serial != "-" else {
      return false
    }
    originalTransferCapabilityStore.persist(
      readSize: readSize,
      serialNumber: serial
    )
    return true
  }

  private func normalizedThumbnailData(_ data: Data, handle: UInt32, source: String) -> Data {
    let normalized = CameraVendorImageDataNormalizer.imageData(from: data)
    let rawHead = data.prefix(16).map { String(format: "%02x", $0) }.joined()
    let normalizedHead = normalized.prefix(16).map { String(format: "%02x", $0) }.joined()
    report(
      "[OBS] PTP_THUMB_DATA source=\(source) handle=0x\(String(format: "%08X", handle)) " +
      "rawBytes=\(data.count) normalizedBytes=\(normalized.count) rawHead=\(rawHead) normalizedHead=\(normalizedHead)"
    )
    return normalized
  }

  func object(handle: UInt32) throws -> Data {
    try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getObject), parameters: [handle])
  }

  func object(handle: UInt32, expectedSize: UInt32?) throws -> Data {
    do {
      if CameraVendorOriginalDownloadPolicy.shouldDownloadUsingPartialObjectFallback {
        return try downloadObjectByPartialObjectFallback(handle: handle, cachedExpectedSize: expectedSize)
      }

      guard CameraVendorOriginalDownloadPolicy.shouldAttemptStandardGetObjectDownload else {
        report(
          "[OBS] PTP_DOWNLOAD_STANDARD_GET_OBJECT_DISABLED " +
          "handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0)"
        )
        throw NSError(
          domain: "CameraVendorPtpSession",
          code: Int(CameraVendorPtpOperationCode.getObject),
          userInfo: [
            NSLocalizedDescriptionKey: "原图下载需要 ReferenceApp ReadImage 传输链，已暂时阻止标准 GetObject 以避免卡死"
          ]
        )
      }

      var shouldResetForceCompression = false
      defer {
        if shouldResetForceCompression {
          do {
            try resetTransferMode(reason: "download-reset", handle: handle)
          } catch {
            report("[OBS] PTP_DOWNLOAD_RESET_FORCE_COMPRESSION_FAILED error=\(error.localizedDescription)")
          }
        }
      }
      if CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeStandardGetObject {
        shouldResetForceCompression = try prepareTransferMode(
          .originalDownload,
          handle: handle,
          reason: "download"
        )
      } else {
        report("[OBS] PTP_DOWNLOAD_SKIP_FORCE_COMPRESSION_BEFORE_GET_OBJECT")
      }
      return try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getObject), parameters: [handle])
    } catch {
      report("[OBS] PTP_GET_OBJECT_FAILED handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0) error=\(error.localizedDescription)")
      throw error
    }
  }

  private func downloadObjectByPartialObjectFallback(
    handle: UInt32,
    cachedExpectedSize: UInt32?
  ) throws -> Data {
    report(
      "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_BEGIN " +
      "handle=0x\(String(format: "%08X", handle)) cachedExpectedSize=\(cachedExpectedSize ?? 0)"
    )
    var shouldResetRealInfo = false
    var shouldResetForceCompression = false
    defer {
      if shouldResetRealInfo {
        do {
          let resetResponse = try sendCommandWithData(
            operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
            parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
            data: CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: false)
          )
          report("[OBS] PTP_DOWNLOAD_RESET_REAL_INFO_ZERO response=0x\(String(format: "%04X", resetResponse.responseCode))")
        } catch {
          report("[OBS] PTP_DOWNLOAD_RESET_REAL_INFO_ZERO_FAILED error=\(error.localizedDescription)")
        }
      }
      if shouldResetForceCompression {
        do {
          try resetTransferMode(
            reason: "download-partial-fallback-reset",
            handle: handle
          )
        } catch {
          report("[OBS] PTP_DOWNLOAD_RESET_FORCE_COMPRESSION_ZERO_FAILED error=\(error.localizedDescription)")
        }
      }
    }
    do {
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList before file download (0xD212)"
      )
      if CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        shouldResetForceCompression = try prepareTransferMode(
          .originalDownload,
          handle: handle,
          reason: "download-partial-fallback-prepare"
        )
      }
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeFreshFileInfo(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
        )
      }
      if CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        let realInfoResponse = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
          parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
          data: CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: true)
        )
        shouldResetRealInfo = true
        report("[OBS] PTP_DOWNLOAD_SET_REAL_INFO_ONE response=0x\(String(format: "%04X", realInfoResponse.responseCode))")
      } else {
        report("[OBS] PTP_DOWNLOAD_SKIP_REAL_INFO_ONE reason=reference-app-fast-start")
      }

      let freshInfo = try objectInfo(
        handle: handle,
        readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
      )
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffAfterFreshFileInfo(
        formatLabel: freshInfo.formatLabel,
        cachedExpectedSize: cachedExpectedSize
      ) {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
        )
      }
      let expectedSize = freshInfo.compressedSize.nonzero ?? cachedExpectedSize
      report(
        "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_INFO " +
        "handle=0x\(String(format: "%08X", handle)) format=\(freshInfo.formatLabel) " +
        "filename=\(freshInfo.filename) expectedSize=\(expectedSize ?? 0)"
      )
      let data = try readObjectByPartialObjects(
        handle: handle,
        expectedSize: expectedSize,
        purpose: "download"
      )
      report(
        "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) bytes=\(data.count)"
      )
      return CameraVendorImageDataNormalizer.imageData(from: data)
    } catch {
      report("[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      throw error
    }
  }

  func objectData(
    handle: UInt32,
    expectedSize: UInt32?,
    formatLabel: String = "JPG",
    downloadMode: CameraVendorTransferDownloadMode = .original
  ) throws -> (data: Data, info: CameraVendorCameraObjectInfo?) {
    let cachedExpectedSize = expectedSize
    let startedAt = Date()
    var prepMs = 0
    var freshInfoMs = 0
    var readMs = 0
    var normalizeMs = 0
    var shouldResetTransferMode = false
    defer {
      if shouldResetTransferMode {
        do {
          try resetTransferMode(reason: "download-data-reset", handle: handle)
        } catch {
          report(
            "[OBS] PTP_DOWNLOAD_DATA_RESET_MODE_FAILED " +
            "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
            "error=\(error.localizedDescription)"
          )
        }
      }
    }
    do {
      report(
        "[OBS] PTP_DOWNLOAD_DATA_PREPARE_BEGIN " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "cachedFormat=\(formatLabel) cachedExpectedSize=\(expectedSize ?? 0)"
      )
      let prepStartedAt = Date()
      if CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeDataDownload() {
        _ = try? readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
          name: "CameraVendor/ReferenceApp EventsList before data download (0xD212)"
        )
      } else {
        report("[OBS] PTP_DOWNLOAD_DATA_SKIP_D212_CONTEXT reason=data-download-uses-photo-path")
      }
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeDataDownload() {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize before data download (0xD235)"
        )
      } else {
        report("[OBS] PTP_DOWNLOAD_DATA_SKIP_D235_CONTEXT reason=data-download-uses-object-info-size")
      }
      shouldResetTransferMode = try prepareTransferMode(
        physicalPurpose(for: downloadMode),
        handle: handle,
        reason: "download-data-prepare"
      )
      prepMs = Int(Date().timeIntervalSince(prepStartedAt) * 1000)
      let shouldUseCachedInfo = CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: formatLabel,
        cachedExpectedSize: cachedExpectedSize,
        mode: downloadMode
      )
      let info: CameraVendorCameraObjectInfo?
      let expectedSize: UInt32?
      let sizeSource: String
      if shouldUseCachedInfo {
        info = nil
        expectedSize = cachedExpectedSize
        sizeSource = "cached-object-info"
      } else {
        let freshInfoStartedAt = Date()
        let freshInfo = try objectInfo(
          handle: handle,
          readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
        )
        freshInfoMs = Int(Date().timeIntervalSince(freshInfoStartedAt) * 1000)
        info = freshInfo
        let sizeResolution = CameraVendorDownloadSizeSourcePolicy.resolution(
          freshSize: freshInfo.compressedSize,
          cachedSize: cachedExpectedSize
        )
        expectedSize = sizeResolution.size
        sizeSource = sizeResolution.label
      }
      report(
        "[OBS] PTP_DOWNLOAD_DATA_INFO " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) format=\(info?.formatLabel ?? formatLabel) " +
        "filename=\(info?.filename ?? "cached") expectedSize=\(expectedSize ?? 0) cachedExpectedSize=\(cachedExpectedSize ?? 0) " +
        "freshSize=\(info?.compressedSize ?? 0) sizeSource=\(sizeSource) freshProbe=\(!shouldUseCachedInfo)"
      )
      let readStartedAt = Date()
      let data = try readObjectByPartialObjects(
        handle: handle,
        expectedSize: expectedSize,
        purpose: "download-data",
        usesFileDownloadChunks: true
      )
      readMs = Int(Date().timeIntervalSince(readStartedAt) * 1000)
      let normalizeStartedAt = Date()
      let normalizedData = CameraVendorImageDataNormalizer.imageData(from: data)
      normalizeMs = Int(Date().timeIntervalSince(normalizeStartedAt) * 1000)
      let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
      report(
        "[OBS] PTP_DOWNLOAD_DATA_TIMING " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "bytes=\(normalizedData.count) prepMs=\(prepMs) freshInfoMs=\(freshInfoMs) " +
        "readMs=\(readMs) normalizeMs=\(normalizeMs) totalMs=\(totalMs) " +
        "sizeSource=\(sizeSource)"
      )
      report(
        "[OBS] PTP_DOWNLOAD_DATA_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) bytes=\(normalizedData.count) " +
        "elapsedMs=\(totalMs)"
      )
      return (normalizedData, info)
    } catch {
      throw error
    }
  }

  func objectFile(
    handle: UInt32,
    cachedInfo: CameraVendorCameraObjectInfo?,
    downloadMode: CameraVendorTransferDownloadMode = .original
  ) throws -> (
    fileURL: URL,
    info: CameraVendorCameraObjectInfo,
    timing: CameraVendorOriginalFileTransferTiming
  ) {
    let cancellationGeneration = activeDownloadCancellation.snapshot()
    let matchingCachedInfo = cachedInfo?.handle == Int(handle) ? cachedInfo : nil
    let cachedExpectedSize = matchingCachedInfo?.compressedSize.nonzero
    let cachedFilename = matchingCachedInfo?.filename ?? "CamTransfer-\(handle).bin"
    var temporaryFileURL: URL?
    var shouldResetTransferMode = false
    let startedAt = Date()
    var prepareMs = 0
    defer {
      if shouldResetTransferMode {
        do {
          try resetTransferMode(reason: "download-file-reset", handle: handle)
        } catch {
          report(
            "[OBS] PTP_DOWNLOAD_FILE_RESET_MODE_FAILED " +
            "handle=0x\(String(format: "%08X", handle)) " +
            "error=\(error.localizedDescription)"
          )
        }
      }
    }
    do {
      report(
        "[OBS] PTP_DOWNLOAD_FILE_PREPARE_BEGIN " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "cachedExpectedSize=\(cachedExpectedSize ?? 0)"
      )
      let prepareStartedAt = Date()
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      let didPrepareBatchMode = try prepareDownloadModeForPriorityBatch(
        downloadMode,
        handle: handle,
        reason: "download-batch-prepare"
      )
      shouldResetTransferMode = didPrepareBatchMode
      report(
        "[OBS] PTP_DOWNLOAD_FILE_BATCH_MODE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "prepared=\(didPrepareBatchMode)"
      )
      let freshInfo = try objectInfo(
        handle: handle,
        readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
      )
      let info = freshInfo.mergingMissingDownloadMetadata(from: matchingCachedInfo)
      let downloadFormatLabel = info.formatLabel
      let downloadFilename = info.filename
      let resolvedFilename = downloadFilename.isEmpty ? cachedFilename : downloadFilename
      let fileExtension = ((resolvedFilename as NSString).pathExtension.isEmpty
        ? "bin"
        : (resolvedFilename as NSString).pathExtension)
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
      temporaryFileURL = fileURL
      let sizeResolution = CameraVendorDownloadSizeSourcePolicy.resolution(
        freshSize: freshInfo.compressedSize,
        cachedSize: cachedExpectedSize
      )
      let expectedSize = sizeResolution.size
      let sizeSource = sizeResolution.label
      let compressionCutOffData = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.compressionCutOff,
        name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
      )
      let d235RawReadSize = CameraVendorOriginalReadImageExecutorPolicy.rawReadSize(from: compressionCutOffData)
      let d235NegotiatedReadSize = CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(from: compressionCutOffData)
      report(
        "[OBS] PTP_DOWNLOAD_D235_PROFILE " +
        "handle=0x\(String(format: "%08X", handle)) raw=\(d235RawReadSize ?? 0) " +
        "selected=\(d235NegotiatedReadSize ?? 0) " +
        "source=\(CameraVendorOriginalReadImageExecutorPolicy.profileSource(negotiatedReadSize: d235NegotiatedReadSize))"
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_INFO " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) format=\(downloadFormatLabel) " +
        "filename=\(downloadFilename) expectedSize=\(expectedSize ?? 0) cachedExpectedSize=\(cachedExpectedSize ?? 0) " +
        "freshSize=\(freshInfo.compressedSize) resolvedSize=\(info.compressedSize) " +
        "sizeSource=\(sizeSource) freshProbe=true"
      )
      prepareMs = Int(Date().timeIntervalSince(prepareStartedAt) * 1000)
      let readResult = try readObjectByPartialObjectsToFile(
        handle: handle,
        expectedSize: expectedSize,
        fileURL: fileURL,
        purpose: "download-file",
        formatLabel: downloadFormatLabel,
        downloadMode: downloadMode,
        cancellationGeneration: cancellationGeneration,
        negotiatedReadSize: CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(from: compressionCutOffData)
      )
      if shouldResetTransferMode {
        do {
          try resetTransferMode(reason: "download-file-reset", handle: handle)
          shouldResetTransferMode = false
        } catch {
          // The reset attempt has already marked the coordinator unknown. Do
          // not issue a second reset from defer on the same broken transport.
          shouldResetTransferMode = false
          throw error
        }
      }
      let transferMs = Int(Date().timeIntervalSince(startedAt) * 1000)
      let commandGapMs = max(
        0,
        readResult.elapsedMs - readResult.requestToFirstByteMs - readResult.socketReceiveMs - readResult.fileWriteMs
      )
      let timing = CameraVendorOriginalFileTransferTiming(
        byteCount: readResult.byteCount,
        prepareMs: prepareMs,
        requestToFirstByteMs: readResult.requestToFirstByteMs,
        socketReceiveMs: readResult.socketReceiveMs,
        fileWriteMs: readResult.fileWriteMs,
        commandGapMs: commandGapMs,
        transferMs: transferMs,
        executor: readResult.executor,
        d235ReadSize: d235NegotiatedReadSize,
        initialReadSize: readResult.initialReadSize,
        finalReadSize: readResult.finalReadSize,
        fallbackCount: readResult.fallbackCount
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) bytes=\(readResult.byteCount) " +
        "prepareMs=\(prepareMs) elapsedMs=\(transferMs)"
      )
      return (fileURL, info, timing)
    } catch {
      if let temporaryFileURL {
        try? FileManager.default.removeItem(at: temporaryFileURL)
      }
      throw error
    }
  }

  func disconnect() {
    lifecycleLock.lock()
    if isConnected {
      _ = try? sendCommand(operationCode: UInt16(CameraVendorPtpOperationCode.closeSession))
    }
    commandSocket.close()
    eventSocket.close()
    isConnected = false
    didConfirmGalleryMode = false
    transferModeCoordinator.invalidate()
    diagnosticHandler = nil
    lifecycleLock.unlock()
  }

  func keepAlive(readTimeout: TimeInterval = 3) throws {
    guard isConnected else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorNotConnectedToInternet,
        userInfo: [NSLocalizedDescriptionKey: "PTP session is not connected"]
      )
    }
    _ = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppGalleryObjectContext],
      readTimeout: readTimeout
    )
  }

  private func sendCommand(operationCode: UInt16, parameters: [UInt32] = []) throws -> CameraVendorOperationResponse {
    let response = try sendCommandCapturingResponse(
      operationCode: operationCode,
      parameters: parameters
    )
    try CameraVendorPtpResponsePolicy.validateOK(
      responseCode: response.responseCode,
      operationName: "PTP command"
    )
    return response
  }

  private func sendCommandCapturingResponse(
    operationCode: UInt16,
    parameters: [UInt32] = []
  ) throws -> CameraVendorOperationResponse {
    do {
      guard !requiresCommandTransportRecovery else {
        throw NSError(domain: "CameraVendorPtpSession", code: 14, userInfo: [
          NSLocalizedDescriptionKey: "PTP command lane framing is unknown"
        ])
      }
      transactionID += 1
      let expectedTransactionID = transactionID
      let packet: Data
      switch operationTransport {
      case .standardPtpIp:
        packet = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        packet = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      reportPtpCommandSend(
        operationCode: operationCode,
        parameters: parameters,
        transactionID: transactionID,
        packet: packet
      )
      try commandSocket.write(packet)
      let response = try readCameraVendorOperationResponse(
        validatesOK: false,
        expectedTransactionID: expectedTransactionID
      )
      reportPtpCommandResponse(operationCode: operationCode, response: response)
      return response
    }
  }

  private func sendCommandWithData(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    data: Data
  ) throws -> CameraVendorOperationResponse {
    do {
      guard !requiresCommandTransportRecovery else {
        throw NSError(domain: "CameraVendorPtpSession", code: 14, userInfo: [
          NSLocalizedDescriptionKey: "PTP command lane framing is unknown"
        ])
      }
      transactionID += 1
      let expectedTransactionID = transactionID
      let commandPacket: Data
      let dataPacket: Data
      switch operationTransport {
      case .standardPtpIp:
        commandPacket = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters,
          dataPhase: 2
        )
        dataPacket = CameraVendorPtpPacketBuilder.buildCameraVendorDataOutRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          data: data
        )
      case .cameraVendorLegacy:
        commandPacket = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
        dataPacket = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          data: data
        )
      }
      reportPtpCommandSend(
        operationCode: operationCode,
        parameters: parameters,
        transactionID: transactionID,
        packet: commandPacket
      )
      report(
        "[OBS] PTP_DATA_OUT_SEND direction=appToCamera operation=0x\(String(format: "%04X", operationCode)) " +
        "transaction=\(transactionID) " +
        CameraDiagnosticPayloadSummary.controlSignal(
          name: "packet",
          direction: .appToCamera,
          data: dataPacket
        )
      )
      try commandSocket.write(commandPacket)
      try commandSocket.write(dataPacket)
      let response = try readCameraVendorOperationResponse(
        expectedTransactionID: expectedTransactionID
      )
      reportPtpCommandResponse(operationCode: operationCode, response: response)
      return response
    }
  }

  private struct CameraVendorFileCommandResult {
    let byteCount: Int
    let prefix: Data
    let requestToFirstByteMs: Int
    let socketReceiveMs: Int
    let fileWriteMs: Int
  }

  private func sendOriginalReadImageRequest(
    transactionID: UInt32,
    handle: UInt32,
    offset: UInt64,
    size: UInt32
  ) throws {
    let parameters = CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
      handle: handle,
      offset: offset,
      size: size
    )
    let request: Data
    switch operationTransport {
    case .standardPtpIp:
      request = CameraVendorPtpPacketBuilder.buildOperationRequest(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        transactionID: transactionID,
        parameters: parameters
      )
    case .cameraVendorLegacy:
      request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        transactionID: transactionID,
        parameters: parameters
      )
    }
    try commandSocket.write(request)
  }

  private func receiveOriginalReadImagePayloadAndResponse(
    transactionID: UInt32,
    expectedMaximum: Int,
    fileHandle: FileHandle,
    readTimeout: TimeInterval
  ) throws -> CameraVendorOriginalReadImageTransactionResult {
    switch operationTransport {
    case .standardPtpIp:
      var totalBytes = 0
      var prefix = Data()
      while true {
        let packet = try readPacket(from: commandSocket, timeout: readTimeout)
        switch packet.type {
        case CameraVendorPtpPacketType.startDataPacket:
          continue
        case CameraVendorPtpPacketType.dataPacket:
          try fileHandle.write(contentsOf: packet.payload)
          totalBytes += packet.payload.count
          if prefix.count < 64 {
            prefix.append(packet.payload.prefix(64 - prefix.count))
          }
        case CameraVendorPtpPacketType.endDataPacket:
          let data = packet.payload.count > 4 ? Data(packet.payload.dropFirst(4)) : Data()
          try fileHandle.write(contentsOf: data)
          totalBytes += data.count
          if prefix.count < 64 {
            prefix.append(data.prefix(64 - prefix.count))
          }
        case CameraVendorPtpPacketType.operationResponse:
          guard totalBytes <= expectedMaximum else {
            throw NSError(
              domain: "CameraVendorPtpSession",
              code: 13,
              userInfo: [NSLocalizedDescriptionKey: "原图 ReadImage 返回超过请求上限的数据"]
            )
          }
          let response = try parseOperationResponsePayload(packet.payload)
          return CameraVendorOriginalReadImageTransactionResult(
            byteCount: totalBytes,
            prefix: prefix,
            requestToFirstByteMs: 0,
            socketReceiveMs: 0,
            fileWriteMs: 0,
            receiveCadence: CameraVendorPtpReceiveCadenceSummary(),
            responseCode: response.responseCode,
            responseTransactionID: response.transactionID
          )
        default:
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 收到未知 PTP 包类型 \(packet.type)",
          ])
        }
      }

    case .cameraVendorLegacy:
      var totalBytes = 0
      var prefix = Data()
      var requestToFirstByteMs = 0
      var socketReceiveMs = 0
      var fileWriteMs = 0
      var receiveCadence = CameraVendorPtpReceiveCadenceSummary()
      while true {
        let packet = try readCameraVendorLegacyFilePacket(
          from: commandSocket,
          fileHandle: fileHandle,
          timeout: readTimeout,
          prefixByteCount: max(0, 64 - prefix.count),
          transactionID: transactionID
        )
        totalBytes += packet.byteCount
        if packet.byteCount > 0 {
          requestToFirstByteMs += packet.requestToFirstByteMs
          socketReceiveMs += packet.socketReceiveMs
          fileWriteMs += packet.fileWriteMs
          receiveCadence.merge(packet.receiveCadence)
        }
        if prefix.count < 64 {
          prefix.append(packet.prefix.prefix(64 - prefix.count))
        }
        guard let controlPacket = packet.controlPacket else { continue }
        guard controlPacket.type == CameraVendorPtpPacketType.operationResponse else {
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 收到未知 CameraVendor PTP 包类型 \(controlPacket.type)",
          ])
        }
        guard totalBytes <= expectedMaximum else {
          throw NSError(
            domain: "CameraVendorPtpSession",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "原图 ReadImage 返回超过请求上限的数据"]
          )
        }
        let response = try parseOperationResponsePayload(controlPacket.payload)
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: totalBytes,
          prefix: prefix,
          requestToFirstByteMs: requestToFirstByteMs,
          socketReceiveMs: socketReceiveMs,
          fileWriteMs: fileWriteMs,
          receiveCadence: receiveCadence,
          responseCode: response.responseCode,
          responseTransactionID: response.transactionID
        )
      }
    }
  }

  private func sendCommandForFileData(
    operationCode: UInt16,
    parameters: [UInt32],
    fileHandle: FileHandle,
    readTimeout: TimeInterval
  ) throws -> CameraVendorFileCommandResult {
    do {
      transactionID += 1
      let request: Data
      switch operationTransport {
      case .standardPtpIp:
        request = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      reportPtpCommandSend(
        operationCode: operationCode,
        parameters: parameters,
        transactionID: transactionID,
        packet: request
      )
      try commandSocket.write(request)

      switch operationTransport {
      case .standardPtpIp:
        // Current Fujifilm transfer sessions use the legacy reader below. Keep
        // standard PTP/IP behavior intact until it has matching wire fixtures.
        var totalBytes = 0
        var prefix = Data()
        while true {
          let packet = try readPacket(from: commandSocket, timeout: readTimeout)
          switch packet.type {
          case CameraVendorPtpPacketType.startDataPacket:
            continue
          case CameraVendorPtpPacketType.dataPacket:
            try fileHandle.write(contentsOf: packet.payload)
            totalBytes += packet.payload.count
            if prefix.count < 64 {
              prefix.append(packet.payload.prefix(64 - prefix.count))
            }
          case CameraVendorPtpPacketType.endDataPacket:
            let data = packet.payload.count > 4 ? Data(packet.payload.dropFirst(4)) : Data()
            try fileHandle.write(contentsOf: data)
            totalBytes += data.count
            if prefix.count < 64 {
              prefix.append(data.prefix(64 - prefix.count))
            }
          case CameraVendorPtpPacketType.operationResponse:
            let response = try parseOperationResponsePayload(packet.payload)
            reportPtpCommandResponse(operationCode: operationCode, response: response)
            try CameraVendorPtpResponsePolicy.validateOK(
              responseCode: response.responseCode,
              operationName: String(format: "PTP operation 0x%04X", operationCode)
            )
            return CameraVendorFileCommandResult(
              byteCount: totalBytes,
              prefix: prefix,
              requestToFirstByteMs: 0,
              socketReceiveMs: 0,
              fileWriteMs: 0
            )
          default:
            throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
              NSLocalizedDescriptionKey: "读取文件数据时收到未知 PTP 包类型 \(packet.type)",
            ])
          }
        }

      case .cameraVendorLegacy:
        var totalBytes = 0
        var prefix = Data()
        var requestToFirstByteMs = 0
        var socketReceiveMs = 0
        var fileWriteMs = 0
        while true {
          let packet = try readCameraVendorLegacyFilePacket(
            from: commandSocket,
            fileHandle: fileHandle,
            timeout: readTimeout,
            prefixByteCount: max(0, 64 - prefix.count)
          )
          totalBytes += packet.byteCount
          if packet.byteCount > 0 {
            requestToFirstByteMs += packet.requestToFirstByteMs
            socketReceiveMs += packet.socketReceiveMs
            fileWriteMs += packet.fileWriteMs
          }
          if prefix.count < 64 {
            prefix.append(packet.prefix.prefix(64 - prefix.count))
          }
          guard let controlPacket = packet.controlPacket else { continue }
          switch controlPacket.type {
          case CameraVendorPtpPacketType.startDataPacket:
            continue
          case CameraVendorPtpPacketType.operationResponse:
            let response = try parseOperationResponsePayload(controlPacket.payload)
            reportPtpCommandResponse(operationCode: operationCode, response: response)
            try CameraVendorPtpResponsePolicy.validateOK(
              responseCode: response.responseCode,
              operationName: String(format: "PTP operation 0x%04X", operationCode)
            )
            return CameraVendorFileCommandResult(
              byteCount: totalBytes,
              prefix: prefix,
              requestToFirstByteMs: requestToFirstByteMs,
              socketReceiveMs: socketReceiveMs,
              fileWriteMs: fileWriteMs
            )
          default:
            throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
              NSLocalizedDescriptionKey: "读取文件数据时收到未知 PTP 包类型 \(controlPacket.type)",
            ])
          }
        }
      }
    }
  }

  private func sendCommandForData(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    readTimeout: TimeInterval = 15,
    timingHandler: ((CameraVendorDataCommandTiming, Int) -> Void)? = nil
  ) throws -> Data {
    do {
      let commandStartedAt = Date()
      var firstByteAt: Date?
      var dataCompleteAt: Date?
      let firstByteHandler = {
        if firstByteAt == nil {
          firstByteAt = Date()
        }
      }
      transactionID += 1
      let request: Data
      switch operationTransport {
      case .standardPtpIp:
        request = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      reportPtpCommandSend(
        operationCode: operationCode,
        parameters: parameters,
        transactionID: transactionID,
        packet: request
      )
      try commandSocket.write(request)

      var received = Data()
      while true {
        let packet = try readOperationPacket(
          timeout: readTimeout,
          firstByteHandler: firstByteHandler
        )
        switch packet.type {
        case CameraVendorPtpPacketType.startDataPacket:
          report("收到 StartDataPacket (\(packet.payload.count) bytes)")
        case CameraVendorPtpPacketType.dataPacket:
          received.append(packet.payload)
          dataCompleteAt = Date()
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.endDataPacket:
          if packet.payload.count > 4 {
            received.append(packet.payload.dropFirst(4))
          }
          dataCompleteAt = Date()
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.operationResponse:
          let response = try parseOperationResponsePayload(packet.payload)
          reportPtpCommandResponse(operationCode: operationCode, response: response)
          report("操作响应: responseCode=0x\(String(response.responseCode, radix: 16)), 总数据大小=\(received.count)")
          try CameraVendorPtpResponsePolicy.validateTransactionID(
            response: response.transactionID,
            expected: transactionID
          )
          try CameraVendorPtpResponsePolicy.validateOK(
            responseCode: response.responseCode,
            operationName: String(format: "PTP operation 0x%04X", operationCode),
            operationCode: operationCode,
            transactionID: response.transactionID
          )
          let responseCompleteAt = Date()
          if let timingHandler {
            let firstByte = firstByteAt ?? responseCompleteAt
            let dataComplete = dataCompleteAt ?? responseCompleteAt
            timingHandler(
              CameraVendorDataCommandTiming(
                requestToFirstByteMs: Int(firstByte.timeIntervalSince(commandStartedAt) * 1000),
                dataCompleteMs: Int(dataComplete.timeIntervalSince(commandStartedAt) * 1000),
                responseCompleteMs: Int(responseCompleteAt.timeIntervalSince(commandStartedAt) * 1000),
                totalMs: Int(responseCompleteAt.timeIntervalSince(commandStartedAt) * 1000)
              ),
              received.count
            )
          }
          return received
        default:
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "读取数据时收到未知 PTP 包类型 \(packet.type)"
          ])
        }
      }
    }
  }

  private func sendCommandForDataWithTiming(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    readTimeout: TimeInterval = 15
  ) throws -> (data: Data, timing: CameraVendorDataCommandTiming) {
    var capturedTiming: CameraVendorDataCommandTiming?
    let data = try sendCommandForData(
      operationCode: operationCode,
      parameters: parameters,
      readTimeout: readTimeout,
      timingHandler: { timing, _ in
        capturedTiming = timing
      }
    )
    guard let capturedTiming else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "未取得 CameraVendor 命令阶段计时"]
      )
    }
    return (data, capturedTiming)
  }

  private func readCameraVendorOperationResponse(
    validatesOK: Bool = true,
    expectedTransactionID: UInt32? = nil
  ) throws -> CameraVendorOperationResponse {
    let packet = try readOperationPacket(timeout: 15)
    guard packet.type == CameraVendorPtpPacketType.operationResponse else {
      throw NSError(domain: "CameraVendorPtpSession", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "收到未知 PTP 包类型 \(packet.type)，期望 OperationResponse"
      ])
    }
    let response = try parseOperationResponsePayload(packet.payload)
    if let expectedTransactionID, response.transactionID != expectedTransactionID {
      invalidatePhysicalSessionForFramingFailure(
        .responseTransactionMismatch(expected: expectedTransactionID, actual: response.transactionID)
      )
      throw NSError(domain: "CameraVendorPtpSession", code: 15, userInfo: [
        NSLocalizedDescriptionKey: "PTP response transaction \(response.transactionID) does not match request transaction \(expectedTransactionID)"
      ])
    }
    report("CameraVendor 操作响应: responseCode=0x\(String(response.responseCode, radix: 16)) txnID=\(response.transactionID)")
    if validatesOK {
      try CameraVendorPtpResponsePolicy.validateOK(
        responseCode: response.responseCode,
        operationName: "PTP command"
      )
    }
    return response
  }

  private func reportPtpCommandSend(
    operationCode: UInt16,
    parameters: [UInt32],
    transactionID: UInt32,
    packet: Data
  ) {
    let parameterText = parameters.isEmpty
      ? "none"
      : parameters.map { String(format: "0x%08X", $0) }.joined(separator: ",")
    report(
      "[OBS] PTP_COMMAND_SEND direction=appToCamera " +
      "operation=0x\(String(format: "%04X", operationCode)) " +
      "transaction=\(transactionID) parameters=\(parameterText) " +
      CameraDiagnosticPayloadSummary.controlSignal(
        name: "packet",
        direction: .appToCamera,
        data: packet
      )
    )
  }

  private func reportPtpCommandResponse(
    operationCode: UInt16,
    response: CameraVendorOperationResponse
  ) {
    let parameterText = response.params.isEmpty
      ? "none"
      : response.params.map { String(format: "0x%08X", $0) }.joined(separator: ",")
    report(
      "[OBS] PTP_COMMAND_RESPONSE direction=cameraToApp " +
      "operation=0x\(String(format: "%04X", operationCode)) " +
      "transaction=\(response.transactionID) response=0x\(String(format: "%04X", response.responseCode)) " +
      "parameters=\(parameterText)"
    )
  }

  private func readOperationPacket(
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    switch operationTransport {
    case .standardPtpIp:
      return try readPacket(
        from: commandSocket,
        timeout: timeout,
        firstByteHandler: firstByteHandler
      )
    case .cameraVendorLegacy:
      return try readCameraVendorLegacyPacket(
        from: commandSocket,
        timeout: timeout,
        firstByteHandler: firstByteHandler
      )
    }
  }

  private func parseOperationResponsePayload(_ payload: Data) throws -> CameraVendorOperationResponse {
    guard payload.count >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "CameraVendor 操作响应太短: \(payload.count) bytes"
      ])
    }
    let responseCode = payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    let txnID = payload.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let params = payload.count > 6 ? payload.subdata(in: 6..<payload.count) : Data()
    return CameraVendorOperationResponse(dataPhase: 0, responseCode: responseCode, transactionID: txnID, params: params)
  }

  /// Read a CameraVendor legacy packet with [4 length] followed by a 2-byte packet kind.
  private func readCameraVendorLegacyPacket(
    from socket: CameraVendorPtpSocket,
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    report("等待 CameraVendor legacy PTP 包头")
    let headerStartedAt = Date()
    let header = try socket.readExactly(
      4,
      timeout: timeout,
      firstByteHandler: firstByteHandler
    )
    let headerMs = Int(Date().timeIntervalSince(headerStartedAt) * 1000)
    guard header.count == 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包头读取失败"])
    }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length >= 6 else {
      invalidatePhysicalSessionForFramingFailure(.legacyPacketLength(length))
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包长度异常 \(length)"])
    }
    let payloadLength = Int(length) - 4
    let payloadStartedAt = Date()
    let progressEveryBytes = CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength)
      ? CameraVendorPtpSocketReadDiagnosticPolicy.progressIntervalBytes
      : nil
    let payload = try socket.readExactly(
      payloadLength,
      timeout: timeout,
      progressEveryBytes: progressEveryBytes,
      firstByteHandler: firstByteHandler
    ) { [weak self] bytesRead, totalBytes, elapsedMs in
      self?.report(
        "[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=legacy " +
        "bytesRead=\(bytesRead) totalBytes=\(totalBytes) payloadMs=\(elapsedMs)"
      )
    }
    let payloadMs = Int(Date().timeIntervalSince(payloadStartedAt) * 1000)
    guard payload.count >= 2 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包内容为空"])
    }
    let kind = payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    let body = payload.subdata(in: 2..<payload.count)
    report("收到 CameraVendor legacy PTP 包 kind=\(kind) length=\(length)")
    if CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength) {
      report(
        "[OBS] PTP_SOCKET_PACKET_READ transport=legacy kind=\(kind) " +
        "length=\(length) headerMs=\(headerMs) payloadMs=\(payloadMs)"
      )
    }
    switch CameraVendorLegacyPacketMapper.packetType(forKind: kind) {
    case CameraVendorPtpPacketType.dataPacket:
      guard body.count >= 6 else {
        throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy Data 包太短: \(body.count) bytes"])
      }
      return CameraVendorPtpPacket(type: CameraVendorPtpPacketType.dataPacket, payload: body.dropFirst(6))
    case CameraVendorPtpPacketType.operationResponse:
      return CameraVendorPtpPacket(
        type: CameraVendorPtpPacketType.operationResponse,
        payload: CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: kind, body: body)
      )
    default:
      return CameraVendorPtpPacket(type: Int(kind), payload: body)
    }
  }

  private func readCameraVendorLegacyFilePacket(
    from socket: CameraVendorPtpSocket,
    fileHandle: FileHandle,
    timeout: TimeInterval,
    prefixByteCount: Int,
    transactionID: UInt32? = nil
  ) throws -> (
    controlPacket: CameraVendorPtpPacket?,
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary
  ) {
    let transactionLabel = transactionID.map(String.init) ?? "none"
    let requestWaitStartedAt = Date()
    report("[OBS] PTP_ORIGINAL_LEGACY_HEADER_WAIT transaction=\(transactionLabel)")
    let header = try socket.readExactly(4, timeout: timeout)
    guard header.count == 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包头读取失败"])
    }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    report(
      "[OBS] PTP_ORIGINAL_LEGACY_HEADER_RECEIVED " +
      "transaction=\(transactionLabel) length=\(length)"
    )
    guard length >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包长度异常 \(length)"])
    }
    let payloadLength = Int(length) - 4
    let kindData = try socket.readExactly(2, timeout: timeout)
    let kind = kindData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }

    if CameraVendorLegacyPacketMapper.packetType(forKind: kind) == CameraVendorPtpPacketType.dataPacket {
      guard payloadLength >= 8 else {
        throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy Data 包太短: \(payloadLength)"])
      }
      _ = try socket.readExactly(6, timeout: timeout)
      let requestToFirstByteMs = Int(Date().timeIntervalSince(requestWaitStartedAt) * 1000)
      report(
        "[OBS] PTP_ORIGINAL_LEGACY_PAYLOAD_BEGIN " +
        "transaction=\(transactionLabel) bytes=\(payloadLength - 8)"
      )
      let result = try socket.readExactlyToFile(
        payloadLength - 8,
        fileHandle: fileHandle,
        timeout: timeout,
        prefixByteCount: prefixByteCount
      )
      report(
        "[OBS] PTP_ORIGINAL_LEGACY_PAYLOAD_END " +
        "transaction=\(transactionLabel) bytes=\(result.byteCount)"
      )
      return (
        nil,
        result.byteCount,
        result.prefix,
        requestToFirstByteMs,
        result.socketReceiveMs,
        result.fileWriteMs,
        result.receiveCadence
      )
    }

    let body = try socket.readExactly(
      payloadLength - 2,
      timeout: timeout
    )
    switch CameraVendorLegacyPacketMapper.packetType(forKind: kind) {
    case CameraVendorPtpPacketType.operationResponse:
      return (
        CameraVendorPtpPacket(
          type: CameraVendorPtpPacketType.operationResponse,
          payload: CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: kind, body: body)
        ),
        0,
        Data(),
        0,
        0,
        0,
        CameraVendorPtpReceiveCadenceSummary()
      )
    default:
      return (
        CameraVendorPtpPacket(type: Int(kind), payload: body),
        0,
        Data(),
        0,
        0,
        0,
        CameraVendorPtpReceiveCadenceSummary()
      )
    }
  }

  /// Read a standard PTP/IP packet with [4 length][4 type] header.
  private func readPacket(
    from socket: CameraVendorPtpSocket,
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    report("等待 PTP 包头")
    let headerStartedAt = Date()
    let header = try socket.readExactly(
      8,
      timeout: timeout,
      firstByteHandler: firstByteHandler
    )
    let headerMs = Int(Date().timeIntervalSince(headerStartedAt) * 1000)
    guard header.count == 8 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "PTP 包头读取失败"])
    }
    let length = header.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let type = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let payloadLength = Int(length) - 8
    let payloadStartedAt = Date()
    let progressEveryBytes = CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength)
      ? CameraVendorPtpSocketReadDiagnosticPolicy.progressIntervalBytes
      : nil
    let payload = payloadLength > 0
      ? try socket.readExactly(
        payloadLength,
        timeout: timeout,
        progressEveryBytes: progressEveryBytes,
        firstByteHandler: firstByteHandler
      ) { [weak self] bytesRead, totalBytes, elapsedMs in
        self?.report(
          "[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=standard " +
          "bytesRead=\(bytesRead) totalBytes=\(totalBytes) payloadMs=\(elapsedMs)"
        )
      }
      : Data()
    let payloadMs = Int(Date().timeIntervalSince(payloadStartedAt) * 1000)
    report("收到 PTP 包 type=\(type) length=\(length)")
    if CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength) {
      report(
        "[OBS] PTP_SOCKET_PACKET_READ transport=standard type=\(type) " +
        "length=\(length) headerMs=\(headerMs) payloadMs=\(payloadMs)"
      )
    }
    return CameraVendorPtpPacket(type: Int(type), payload: payload)
  }

  private func report(_ message: String) {
    guard CameraVendorPtpDiagnosticLogPolicy.shouldEmit(message) else { return }
    if let diagnosticHandler {
      diagnosticHandler(message)
    } else {
      CameraVendorGalleryDiagnostics.log(message)
    }
  }
}
