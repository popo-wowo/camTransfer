import Foundation

enum FujifilmCameraSessionTerminationState: Equatable {
  case active
  case terminated(reason: String)
}

struct FujifilmRememberedBleConnectionResult {
  let execution: IOSCameraConnectionStepExecution
  let summary: CameraVendorConnectionSummary
}

struct FujifilmInitialCatalogRevisionResult: Equatable {
  let summary: CameraPlanRevisionSummary
  let plan: CameraConnectionPlan
  let strategySnapshot: FujifilmProtocolStrategySnapshot
}

final class FujifilmCameraSession: Equatable {
  let connectionSessionID: UUID
  let sessionID: String
  let cameraID: String
  let observedIdentity: CameraObservedIdentity
  let executionState: CameraConnectionExecutionState
  private let compatibilityEnvironment: FujifilmCompatibilityEnvironment
  let commandLane: CameraCommandLane
  private(set) var terminalBarrierEvidence: [IOSCameraConnectionStep: IOSCameraConnectionStepEvidence]
  private let terminationLock = NSLock()
  private let planLock = NSLock()
  private var storedTerminationState: FujifilmCameraSessionTerminationState = .active
  private var terminationHandler: ((String) -> Void)?
  private var planSealedForCatalog = false

  init(
    sessionID: String,
    cameraID: String,
    observedIdentity: CameraObservedIdentity,
    executionState: CameraConnectionExecutionState,
    compatibilityEnvironment: FujifilmCompatibilityEnvironment = .production,
    commandLane: CameraCommandLane,
    terminalBarrierEvidence: [IOSCameraConnectionStep: IOSCameraConnectionStepEvidence],
    terminationHandler: @escaping (String) -> Void
  ) {
    self.connectionSessionID = executionState.connectionSessionID
    self.sessionID = sessionID
    self.cameraID = cameraID
    self.observedIdentity = observedIdentity
    self.executionState = executionState
    self.compatibilityEnvironment = compatibilityEnvironment
    self.commandLane = commandLane
    self.terminalBarrierEvidence = terminalBarrierEvidence
    self.terminationHandler = terminationHandler
  }

  convenience init(
    connectionSessionID: UUID,
    sessionID: String,
    cameraID: String,
    observedIdentity: CameraObservedIdentity,
    plan: CameraConnectionPlan,
    compatibilityEnvironment: FujifilmCompatibilityEnvironment = .production,
    commandLane: CameraCommandLane,
    terminalBarrierEvidence: [IOSCameraConnectionStep: IOSCameraConnectionStepEvidence],
    terminationHandler: @escaping (String) -> Void
  ) {
    self.init(
      sessionID: sessionID,
      cameraID: cameraID,
      observedIdentity: observedIdentity,
      executionState: CameraConnectionExecutionState(
        connectionSessionID: connectionSessionID,
        plan: plan
      ),
      compatibilityEnvironment: compatibilityEnvironment,
      commandLane: commandLane,
      terminalBarrierEvidence: terminalBarrierEvidence,
      terminationHandler: terminationHandler
    )
  }

  var facts: CameraCompatibilityFacts {
    CameraCompatibilityFacts(
      observedIdentity: observedIdentity,
      protocolFacts: executionState.plan.protocolFacts
    )
  }

  var plan: CameraConnectionPlan { executionState.plan }
  var planID: CameraConnectionPlanID { plan.id }
  var planRevision: Int { plan.revision }

  func applyRevision(_ revisedPlan: CameraConnectionPlan) throws {
    try planLock.withLock {
      guard !planSealedForCatalog else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "Prepared physical session plan is sealed for Catalog"]
        )
      }
      guard executionState.plan == revisedPlan else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Physical session revision must already belong to its execution state",
          ]
        )
      }
    }
  }

  func applyInitialCatalogResponseRevision(
    facts revisedFacts: CameraCompatibilityFacts
  ) throws -> FujifilmInitialCatalogRevisionResult? {
    try planLock.withLock {
      guard planSealedForCatalog else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey: "Catalog response revision requires a sealed plan"]
        )
      }
      guard plan.initialCatalogStrategy == .directSpecifiedCatalog,
            let catalogFacts = revisedFacts.protocolFacts.catalogResponseFacts,
            catalogFacts.operationCode == 0x9053,
            catalogFacts.responseCode == 0x2013,
            catalogFacts.classification == .storeNotAvailable else {
        return nil
      }
      let expectedProtocolFacts = plan.protocolFacts.updating(
        catalogResponseFacts: catalogFacts
      )
      guard revisedFacts.protocolFacts == expectedProtocolFacts else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 6,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Catalog response revision cannot replace previously observed protocol facts",
          ]
        )
      }

      let resolved = compatibilityEnvironment.resolve(
        protocolFacts: revisedFacts.protocolFacts,
        revising: plan.version
      ).plan
      guard resolved.id == plan.id,
            resolved.revision == plan.revision + 1,
            resolved.supportStatus != .unsupported,
            resolved.initialCatalogStrategy == .storeNotAvailableRecovery else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Catalog response revision must be adjacent and supported"]
        )
      }

      let candidate = CameraConnectionPlan(
        id: plan.id,
        revision: resolved.revision,
        registryVersion: resolved.registryVersion,
        supportStatus: resolved.supportStatus,
        protocolFacts: revisedFacts.protocolFacts,
        pairingStrategy: plan.pairingStrategy,
        activationStrategy: plan.activationStrategy,
        ptpInitStrategy: plan.ptpInitStrategy,
        negotiationStrategy: plan.negotiationStrategy,
        galleryBootstrapStrategy: plan.galleryBootstrapStrategy,
        initialCatalogStrategy: resolved.initialCatalogStrategy
      )
      guard executionState.plan == plan,
            candidate.id == plan.id,
            candidate.revision == plan.revision + 1,
            candidate.supportStatus != .unsupported,
            candidate.pairingStrategy == plan.pairingStrategy,
            candidate.activationStrategy == plan.activationStrategy,
            candidate.ptpInitStrategy == plan.ptpInitStrategy,
            candidate.negotiationStrategy == plan.negotiationStrategy,
            candidate.galleryBootstrapStrategy == plan.galleryBootstrapStrategy,
            candidate.initialCatalogStrategy == .storeNotAvailableRecovery else {
        throw NSError(
          domain: "FujifilmCameraSession",
          code: 5,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Catalog response revision may change only the initial Catalog strategy",
          ]
        )
      }
      let summary = try executionState.applyRevision(
        candidate,
        reason: .catalogResponseClassified,
        preservingExecutedStages: [
          .pairing,
          .activation,
          .ptpInit,
          .negotiation,
          .bootstrap,
        ]
      )
      let revisedPlan = executionState.plan
      let strategySnapshot = try compatibilityEnvironment.strategyRegistry.snapshot(
        for: revisedPlan,
        compatibilityFacts: CameraCompatibilityFacts(
          observedIdentity: observedIdentity,
          protocolFacts: revisedPlan.protocolFacts
        )
      )
      return FujifilmInitialCatalogRevisionResult(
        summary: summary,
        plan: revisedPlan,
        strategySnapshot: strategySnapshot
      )
    }
  }

  var isPlanSealedForCatalog: Bool {
    planLock.withLock { planSealedForCatalog }
  }

  func sealPlanForCatalog() {
    planLock.withLock {
      planSealedForCatalog = true
    }
  }

  func recordBarrierEvidence(
    step: IOSCameraConnectionStep,
    evidence: IOSCameraConnectionStepEvidence
  ) {
    terminalBarrierEvidence[step] = evidence
  }

  var terminationState: FujifilmCameraSessionTerminationState {
    terminationLock.withLock { storedTerminationState }
  }

  @discardableResult
  func terminate(reason: String) -> Bool {
    let handler: ((String) -> Void)? = terminationLock.withLock {
      guard case .active = storedTerminationState else { return nil }
      storedTerminationState = .terminated(reason: reason)
      let handler = terminationHandler
      terminationHandler = nil
      return handler
    }
    guard let handler else { return false }
    handler(reason)
    if !commandLane.isTerminated {
      commandLane.terminate()
    }
    return true
  }

  static func == (lhs: FujifilmCameraSession, rhs: FujifilmCameraSession) -> Bool {
    lhs === rhs
  }
}

final class FujifilmProtocolEngine {
  private let galleryService: CameraVendorRealtimeGalleryService
  private let compatibilityEnvironment: FujifilmCompatibilityEnvironment
  private let strategyRegistry: FujifilmProtocolStrategyRegistry
  private(set) var boundPlan: CameraConnectionPlan?
  private var boundStrategySnapshot: FujifilmProtocolStrategySnapshot?
  private var boundCompatibilityFacts: CameraCompatibilityFacts?

  init(
    galleryService: CameraVendorRealtimeGalleryService,
    environment: FujifilmCompatibilityEnvironment = .production
  ) {
    self.galleryService = galleryService
    self.compatibilityEnvironment = environment
    self.strategyRegistry = environment.strategyRegistry
  }

  func bind(
    plan: CameraConnectionPlan,
    compatibilityFacts: CameraCompatibilityFacts
  ) throws {
    if let boundPlan, boundPlan != plan {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "A Fujifilm protocol engine cannot change plans mid-session"]
      )
    }
    let strategySnapshot = try strategyRegistry.snapshot(
      for: plan,
      compatibilityFacts: compatibilityFacts
    )
    try galleryService.bindConnectionPlan(plan, strategySnapshot: strategySnapshot)
    boundPlan = plan
    boundStrategySnapshot = strategySnapshot
    boundCompatibilityFacts = compatibilityFacts
  }

  func bind(plan: CameraConnectionPlan) throws {
    try bind(
      plan: plan,
      compatibilityFacts: CameraCompatibilityFacts(
        observedIdentity: .unknown,
        protocolFacts: plan.protocolFacts
      )
    )
  }

  func applyRevision(
    _ plan: CameraConnectionPlan,
    reason: CameraPlanRevisionReason
  ) throws {
    let current = try requireBoundPlan()
    guard plan.id == current.id, plan.revision == current.revision + 1 else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 12,
        userInfo: [NSLocalizedDescriptionKey: "Protocol engine plan revision must be adjacent"]
      )
    }
    let previousFacts = boundCompatibilityFacts ?? CameraCompatibilityFacts(
      observedIdentity: .unknown,
      protocolFacts: current.protocolFacts
    )
    let revisedFacts = CameraCompatibilityFacts(
      observedIdentity: previousFacts.observedIdentity,
      protocolFacts: plan.protocolFacts
    )
    let strategySnapshot = try strategyRegistry.snapshot(
      for: plan,
      compatibilityFacts: revisedFacts
    )
    try galleryService.bindConnectionPlan(plan, strategySnapshot: strategySnapshot)
    boundPlan = plan
    boundStrategySnapshot = strategySnapshot
    boundCompatibilityFacts = revisedFacts
    appendRuntimeMessage(
      "[OBS] CAMERA_PLAN_REVISION planID=\(plan.id.rawValue) revision=\(plan.revision) reason=\(reason.rawValue)"
    )
  }

  func beginMainlineGalleryFetch() throws -> UInt64 {
    try galleryService.beginMainlineGalleryFetch()
  }

  func finishMainlineGalleryFetch(generation: UInt64) {
    galleryService.finishMainlineGalleryFetch(generation: generation)
  }

  func appendRuntimeMessage(_ message: String) {
    galleryService.appendGalleryRuntimeMessage(message)
  }

  func executeReconnectPairedBleStep(
    context: IOSCameraConnectionContext,
    onGattFacts: @escaping (CameraCompatibilityFacts) throws -> CameraConnectionPlan,
    performConnection: @escaping (
      @escaping (CameraCompatibilityFacts) throws -> ActivationStrategyDefinition
    ) async throws -> CameraVendorConnectionSummary
  ) async throws -> FujifilmRememberedBleConnectionResult {
    let plan = try requireBoundPlan()
    try validatePairingStrategy(plan.pairingStrategy)
    var gattResolutionCount = 0
    let summary = try await performConnection { facts in
      guard gattResolutionCount == 0 else {
        throw IOSCameraConnectionIssue(
          step: .reconnectPairedBle,
          reason: "GATT compatibility facts may resolve Activation Strategy only once"
        )
      }
      gattResolutionCount += 1
      let revisedPlan = try onGattFacts(facts)
      try self.applyRevision(revisedPlan, reason: .gattDiscoveryCompleted)
      return try self.requireBoundStrategySnapshot(for: revisedPlan).activation
    }
    guard gattResolutionCount == 1 else {
      throw IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "BLE reconnect completed before GATT facts selected an Activation Strategy"
      )
    }
    let activePlan = try requireBoundPlan()
    galleryService.configure(connectionSummary: summary)
    try galleryService.bindConnectionPlan(
      activePlan,
      strategySnapshot: try requireBoundStrategySnapshot(for: activePlan)
    )
    guard summary.verifiedConnectionSteps.contains(.reconnectPairedBle) else {
      throw IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "必须先完成已配对相机 BLE 重连，不能从页面重试进入相册"
      )
    }
    return FujifilmRememberedBleConnectionResult(
      execution: IOSCameraConnectionStepExecution(
        context: context,
        evidence: .bleIdentityVerified(cameraID: context.cameraID)
      ),
      summary: summary
    )
  }

  func executeTransferAuthorizationStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.transferAuthorization) else {
      throw IOSCameraConnectionIssue(
        step: .transferAuthorization,
        reason: "相机没有返回本次官方 Wi-Fi 名称和密码，已停止进入 PTP"
      )
    }
    guard let wifiCredential = galleryService.currentOfficialWifiCredential() else {
      throw IOSCameraConnectionIssue(
        step: .transferAuthorization,
        reason: "当前官方 Wi-Fi 凭据不完整，已停止进入 PTP"
      )
    }
    var updatedContext = context
    updatedContext.wifiCredential = wifiCredential
    return IOSCameraConnectionStepExecution(
      context: updatedContext,
      evidence: .officialWifiCredential(wifiCredential)
    )
  }

  func executeActivateCameraWifiStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.activateCameraWifi) else {
      throw IOSCameraConnectionIssue(
        step: .activateCameraWifi,
        reason: "未确认传图激活命令已按官方流程写入相机"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .cameraWifiActivationAcknowledged
    )
  }

  func executeWaitCameraWifiReadyStep(
    context: IOSCameraConnectionContext
  ) async throws -> IOSCameraConnectionStepExecution {
    guard galleryService.hasVerifiedConnectionStep(.waitCameraWifiReady) else {
      throw IOSCameraConnectionIssue(
        step: .waitCameraWifiReady,
        reason: "未收到相机进入可连接传图状态的正向信号"
      )
    }
    return IOSCameraConnectionStepExecution(
      context: context,
      evidence: .cameraWifiReady
    )
  }

  func executeJoinCameraWifiStep(
    context: IOSCameraConnectionContext,
    communicationGeneration: UInt64
  ) async throws -> CameraVendorGalleryWifiHandoffStepResult {
    let plan = try requireBoundPlan()
    let activation = try requireBoundStrategySnapshot(for: plan).activation
    let handoff = try await galleryService.joinCameraWifi(
      context: context,
      communicationGeneration: communicationGeneration,
      allowUnverifiedAssociationAfterRecoverableError:
        activation.allowsUnverifiedWifiHandoffAfterRecoverableError
    )
    return CameraVendorGalleryWifiHandoffStepResult(
      execution: IOSCameraConnectionStepExecution(
        context: context,
        evidence: .joinedCameraWifi(ssid: handoff.joinedSSID)
      ),
      didCompleteWifiHandoff: handoff.didCompleteWifiHandoff
    )
  }

  func connectGallerySession(
    executionState: CameraConnectionExecutionState,
    cameraID: String,
    observedIdentity: CameraObservedIdentity,
    communicationGeneration: UInt64,
    didCompleteWifiHandoff: Bool,
    recorder: @escaping (String) -> Void,
    onBarrierProgress: @escaping (CameraConnectionBarrierEvent) throws -> Void,
    onFunctionFactsInspected: @escaping (
      CameraGalleryFunctionFacts
    ) throws -> CameraConnectionPlan
  ) async throws -> FujifilmCameraSession {
    let connectionSessionID = executionState.connectionSessionID
    let initialPlan = try requireBoundPlan()
    let initialStrategySnapshot = try requireBoundStrategySnapshot(for: initialPlan)
    guard let initDefinition = initialStrategySnapshot.ptpInit else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 16,
        userInfo: [NSLocalizedDescriptionKey: "PTP INIT Strategy is not available in the bound plan"]
      )
    }
    let connectionAttemptRange = Self.connectionAttemptRange(for: initDefinition)
    let activationDefinition = initialStrategySnapshot.activation
    var lastError: Error?
    let startedAt = Date()

    prepareGalleryConnectionAttempt(
      activation: activationDefinition,
      ptpInit: initDefinition,
      didCompleteWifiHandoff: didCompleteWifiHandoff,
      recorder: recorder
    )

    for attempt in connectionAttemptRange {
      var terminalBarrierEvidence: [IOSCameraConnectionStep: IOSCameraConnectionStepEvidence] = [:]
      do {
        let ptpEvidence = try galleryService.connectGalleryPtp(
          communicationGeneration: communicationGeneration,
          recorder: recorder,
          plan: try requireBoundPlan(),
          progressHandler: { step, evidence in
            terminalBarrierEvidence[step] = evidence
            try onBarrierProgress(CameraConnectionBarrierEvent(
              connectionSessionID: connectionSessionID,
              planVersion: try self.requireBoundPlan().version,
              step: step,
              evidence: evidence
            ))
          }
        )
        let activePlan = try requireBoundPlan()
        guard executionState.plan == activePlan else {
          throw NSError(
            domain: "FujifilmProtocolEngine",
            code: 18,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Physical session must use the loader connection execution state",
            ]
          )
        }
        let session = FujifilmCameraSession(
          sessionID: ptpEvidence.sessionID,
          cameraID: cameraID,
          observedIdentity: observedIdentity,
          executionState: executionState,
          compatibilityEnvironment: compatibilityEnvironment,
          commandLane: galleryService.currentCommandLane,
          terminalBarrierEvidence: terminalBarrierEvidence,
          terminationHandler: { [weak galleryService] reason in
            galleryService?.performPhysicalSessionTermination(reason: reason)
          }
        )
        try await session.commandLane.runExclusiveSessionMutation {
          let functionFacts = try galleryService.inspectGalleryFunction(plan: activePlan)
          let revisedPlan = try onFunctionFactsInspected(functionFacts)
          if revisedPlan != activePlan {
            try applyRevision(revisedPlan, reason: .functionFactsInspected)
            try session.applyRevision(revisedPlan)
          }
          let postInspectionPlan = session.plan
          try galleryService.negotiateGalleryFunction(
            plan: postInspectionPlan,
            progressHandler: { step, evidence in
              session.recordBarrierEvidence(step: step, evidence: evidence)
              try onBarrierProgress(CameraConnectionBarrierEvent(
                connectionSessionID: connectionSessionID,
                planVersion: try self.requireBoundPlan().version,
                step: step,
                evidence: evidence
              ))
            }
          )
          try galleryService.prepareGallerySession(
            plan: postInspectionPlan,
            progressHandler: { step, evidence in
              session.recordBarrierEvidence(step: step, evidence: evidence)
              try onBarrierProgress(CameraConnectionBarrierEvent(
                connectionSessionID: connectionSessionID,
                planVersion: try self.requireBoundPlan().version,
                step: step,
                evidence: evidence
              ))
            }
          )
          session.sealPlanForCatalog()
        }
        galleryService.installPhysicalSession(session)
        return session
      } catch {
        galleryService.resetFailedGalleryPtpAttempt()
        if CameraVendorPtpReconnectErrorPolicy.shouldRetry(error) == false
          || !Self.shouldRetryConnection(forCompletedSteps: Set(terminalBarrierEvidence.keys)) {
          throw error
        }
        lastError = error
        guard attempt < connectionAttemptRange.upperBound else { break }
        let delay = retryDelaySeconds(
          afterFailedAttempt: attempt,
          backoff: initDefinition.retryTiming.connectionRetryBackoff
        )
        let retryOwner = Self.retryOwner(
          forCompletedSteps: Set(terminalBarrierEvidence.keys),
          ptpInitRetryOwner: initDefinition.retryTiming.retryOwner
        )
        recorder(
          "PTP 连接失败 (第 \(attempt) 次，已等待 " +
          "\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s/最多 " +
          "\(connectionAttemptRange.upperBound) 次)，" +
          "\(String(format: "%.1f", delay))s 后重试: \(error.localizedDescription) " +
          "retryOwner=\(retryOwner.rawValue)"
        )
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      }
    }
    throw lastError ?? NSError(
      domain: "FujifilmProtocolEngine",
      code: 13,
      userInfo: [NSLocalizedDescriptionKey: "PTP connection attempts exhausted"]
    )
  }

  func completeSuccessfulGalleryRouteSearch() {
    galleryService.completeSuccessfulGalleryRouteSearch()
  }

  func connectionAttemptRangeForBoundPtpInit() throws -> ClosedRange<Int> {
    let plan = try requireBoundPlan()
    let snapshot = try requireBoundStrategySnapshot(for: plan)
    guard let definition = snapshot.ptpInit else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 16,
        userInfo: [NSLocalizedDescriptionKey: "PTP INIT Strategy is not available in the bound plan"]
      )
    }
    return Self.connectionAttemptRange(for: definition)
  }

  func buildGalleryRouteFailure(
    didCompleteWifiHandoff: Bool,
    diagnostics: [String],
    error: Error
  ) -> NSError {
    galleryService.buildGalleryRouteFailure(
      didCompleteWifiHandoff: didCompleteWifiHandoff,
      diagnostics: diagnostics,
      error: error
    )
  }

  private func requireBoundPlan() throws -> CameraConnectionPlan {
    guard let boundPlan else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Fujifilm protocol work requires one bound session plan"]
      )
    }
    return boundPlan
  }

  private func requireBoundStrategySnapshot(
    for plan: CameraConnectionPlan
  ) throws -> FujifilmProtocolStrategySnapshot {
    guard boundPlan == plan, let boundStrategySnapshot else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 14,
        userInfo: [NSLocalizedDescriptionKey: "Protocol Strategy definitions are not bound to this plan"]
      )
    }
    return boundStrategySnapshot
  }

  private func validatePairingStrategy(_ strategy: PairingStrategyID) throws {
    guard strategy == .currentBaseline else {
      throw NSError(
        domain: "FujifilmProtocolEngine",
        code: 15,
        userInfo: [NSLocalizedDescriptionKey: "Unregistered pairing strategy: \(strategy.rawValue)"]
      )
    }
  }

  private func prepareGalleryConnectionAttempt(
    activation: ActivationStrategyDefinition,
    ptpInit: PtpInitStrategyDefinition,
    didCompleteWifiHandoff: Bool,
    recorder: (String) -> Void
  ) {
    let payload = activation.launchRequestPayload
      .map { String(format: "%02x", $0) }
      .joined()
    recorder(
      "[OBS] FUJIFILM_GALLERY_CONNECTION_ATTEMPT " +
      "activationStrategy=\(activation.id.rawValue) " +
      "ptpInitStrategy=\(ptpInit.id.rawValue) " +
      "handoff=\(didCompleteWifiHandoff) launchPayload=\(payload)"
    )
    if ptpInit.startupDelaySeconds > 0 {
      recorder(
        "等待 \(String(format: "%.1f", ptpInit.startupDelaySeconds)) 秒让相机 PTP 服务就绪"
      )
      Thread.sleep(forTimeInterval: ptpInit.startupDelaySeconds)
    } else {
      recorder("跳过额外 PTP 启动等待")
    }
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

  static func retryOwner(
    forCompletedSteps completedSteps: Set<IOSCameraConnectionStep>,
    ptpInitRetryOwner: CameraConnectionRetryOwner = .ptpInitStrategy
  ) -> CameraConnectionRetryOwner {
    if !completedSteps.contains(.ptpTransportConnected) {
      return .protocolEngine
    }
    if !completedSteps.contains(.ptpInitAcknowledged) {
      return ptpInitRetryOwner
    }
    if !completedSteps.contains(.ptpSessionOpened) {
      return .protocolEngine
    }
    if !completedSteps.contains(.functionNegotiated) {
      return .negotiationStrategy
    }
    if !completedSteps.contains(.gallerySessionPrepared) {
      return .galleryBootstrapStrategy
    }
    return .sessionRuntime
  }

  static func shouldRetryConnection(
    forCompletedSteps completedSteps: Set<IOSCameraConnectionStep>
  ) -> Bool {
    !completedSteps.contains(.ptpSessionOpened)
  }

  private static func connectionAttemptRange(
    for definition: PtpInitStrategyDefinition
  ) -> ClosedRange<Int> {
    1...definition.retryTiming.connectionMaxAttempts
  }
}
