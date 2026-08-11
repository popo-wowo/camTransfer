import Foundation

struct CameraVendorGalleryMainlineLoadResult {
  let confirmedSteps: [IOSCameraConnectionStep]
  let connectionSummary: CameraVendorConnectionSummary
  let fujifilmSession: FujifilmCameraSession

  var ptpSessionID: String { fujifilmSession.sessionID }
}

final class CameraVendorCompatibilityLabAttemptFailure: Error {
  let issue: IOSCameraConnectionIssue
  let formalRouteFailure: CameraCompatibilityLabFormalRouteFailure
  let diagnosticHandler: CameraCompatibilityLab.DiagnosticHandler

  init(
    issue: IOSCameraConnectionIssue,
    formalRouteFailure: CameraCompatibilityLabFormalRouteFailure,
    diagnosticHandler: @escaping CameraCompatibilityLab.DiagnosticHandler
  ) {
    self.issue = issue
    self.formalRouteFailure = formalRouteFailure
    self.diagnosticHandler = diagnosticHandler
  }
}

final class CameraVendorGalleryMainlineSessionLoader {
  typealias CompatibilityLabAttemptExecutor = (
    CameraCompatibilityLabCandidate,
    CameraConnectionPlan
  ) async throws -> CameraVendorGalleryMainlineLoadResult

  private let galleryService: CameraVendorRealtimeGalleryService
  private let compatibilityEnvironment: FujifilmCompatibilityEnvironment
  private let compatibilityLabCandidateProvider: CameraCompatibilityLabCandidateProvider

  init(
    galleryService: CameraVendorRealtimeGalleryService,
    compatibilityEnvironment: FujifilmCompatibilityEnvironment = .production,
    compatibilityLabCandidateProvider: CameraCompatibilityLabCandidateProvider = .production
  ) {
    self.galleryService = galleryService
    self.compatibilityEnvironment = compatibilityEnvironment
    self.compatibilityLabCandidateProvider = compatibilityLabCandidateProvider
  }

  func loadGallerySession(
    context: IOSCameraConnectionContext,
    publishStep: @escaping (IOSCameraConnectionStep) -> Void,
    performBleConnection: @escaping (
      @escaping (CameraCompatibilityFacts) throws -> ActivationStrategyDefinition
    ) async throws -> CameraVendorConnectionSummary,
    compatibilityLabReset: @escaping CameraCompatibilityLab.ResetHandler
  ) async throws -> CameraVendorGalleryMainlineLoadResult {
    do {
      return try await loadGallerySessionAttempt(
        context: context,
        publishStep: publishStep,
        performBleConnection: performBleConnection,
        forcedLabCandidate: nil,
        allowCompatibilityLab: true
      )
    } catch let failure as CameraVendorCompatibilityLabAttemptFailure {
      return try await recoverWithCompatibilityLab(
        failure: failure,
        context: context,
        publishStep: publishStep,
        performBleConnection: performBleConnection,
        compatibilityLabReset: compatibilityLabReset
      )
    }
  }

  private func loadGallerySessionAttempt(
    context: IOSCameraConnectionContext,
    publishStep: @escaping (IOSCameraConnectionStep) -> Void,
    performBleConnection: @escaping (
      @escaping (CameraCompatibilityFacts) throws -> ActivationStrategyDefinition
    ) async throws -> CameraVendorConnectionSummary,
    forcedLabCandidate: CameraCompatibilityLabCandidate?,
    allowCompatibilityLab: Bool
  ) async throws -> CameraVendorGalleryMainlineLoadResult {
    let connectionSessionID = UUID()
    try galleryService.beginConnectionPlanAttempt()
    let attemptEnvironment: FujifilmCompatibilityEnvironment
    if let forcedLabCandidate {
      attemptEnvironment = try compatibilityEnvironment.addingCompatibilityLabCandidate(
        forcedLabCandidate
      )
    } else {
      attemptEnvironment = compatibilityEnvironment
    }
    let protocolEngine = FujifilmProtocolEngine(
      galleryService: galleryService,
      environment: attemptEnvironment
    )
    let compatibilityFacts = context.compatibilityFacts ?? .unknown
    var observedIdentity = compatibilityFacts.observedIdentity
    let initialDecision = try Self.makeInitialDecision(
      connectionSessionID: connectionSessionID,
      compatibilityFacts: compatibilityFacts,
      attemptEnvironment: attemptEnvironment
    )
    let executionState = CameraConnectionExecutionState(
      connectionSessionID: connectionSessionID,
      plan: initialDecision.plan,
      onBarrierEvent: { event in
        protocolEngine.appendRuntimeMessage(self.barrierDiagnostic(event: event))
      }
    )
    protocolEngine.appendRuntimeMessage(planResolutionDiagnostic(
      decision: initialDecision,
      connectionSessionID: connectionSessionID.uuidString,
      observedIdentity: observedIdentity
    ))
    guard initialDecision.plan.supportStatus != .unsupported else {
      let issue = IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "当前 remembered Session 缺少可验证的兼容家族/Service 事实，不能启动 Fujifilm BLE 主链"
      )
      executionState.recordFailure(issue)
      protocolEngine.appendRuntimeMessage(terminalDiagnostic(
        connectionSessionID: connectionSessionID,
        plan: initialDecision.plan,
        firstMissingBarrier: .reconnectPairedBle,
        error: issue
      ))
      throw issue
    }
    try protocolEngine.bind(plan: executionState.plan)
    var sessionContext = context
    sessionContext.connectionPlan = executionState.plan

    var connectionSummary: CameraVendorConnectionSummary?
    var fetchGeneration: UInt64?
    defer {
      if let fetchGeneration {
        protocolEngine.finishMainlineGalleryFetch(generation: fetchGeneration)
      }
    }
    var didCompleteWifiHandoff = false
    let orchestrator = CameraConnectionOrchestrator(
      executionState: executionState,
      onStepStarted: publishStep,
      onStepCompleted: { step, _ in
        guard step == .reconnectPairedBle else { return }
        guard connectionSummary?.compatibilityFacts != nil else {
          throw IOSCameraConnectionIssue(
            step: .reconnectPairedBle,
            reason: "BLE reconnect completed without typed GATT compatibility facts"
          )
        }
      },
      runners: [
        IOSCameraConnectionStepRunner(step: .reconnectPairedBle) { stepContext in
          let result = try await protocolEngine.executeReconnectPairedBleStep(
            context: stepContext,
            onGattFacts: { facts in
              observedIdentity = facts.observedIdentity
              let gattDecision = attemptEnvironment.resolve(
                protocolFacts: facts.protocolFacts,
                revising: executionState.plan.version
              )
              guard gattDecision.plan.supportStatus != .unsupported else {
                protocolEngine.appendRuntimeMessage(self.planResolutionDiagnostic(
                  decision: gattDecision,
                  connectionSessionID: connectionSessionID.uuidString,
                  observedIdentity: observedIdentity,
                  revisionReason: .gattDiscoveryCompleted
                ))
                throw IOSCameraConnectionIssue(
                  step: .transferAuthorization,
                  reason: "当前相机的 Service/Characteristic 事实未匹配安全连接 Plan"
                )
              }
              let gattRevision = try executionState.applyRevision(
                gattDecision.plan,
                reason: .gattDiscoveryCompleted
              )
              protocolEngine.appendRuntimeMessage(self.planResolutionDiagnostic(
                decision: gattDecision,
                connectionSessionID: connectionSessionID.uuidString,
                observedIdentity: observedIdentity,
                revisionReason: .gattDiscoveryCompleted,
                revisionSummary: gattRevision
              ))
              return executionState.plan
            },
            performConnection: performBleConnection
          )
          connectionSummary = result.summary
          return result.execution
        },
        IOSCameraConnectionStepRunner(step: .transferAuthorization) { stepContext in
          try await protocolEngine.executeTransferAuthorizationStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .activateCameraWifi) { stepContext in
          try await protocolEngine.executeActivateCameraWifiStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .waitCameraWifiReady) { stepContext in
          try await protocolEngine.executeWaitCameraWifiReadyStep(context: stepContext)
        },
        IOSCameraConnectionStepRunner(step: .joinCameraWifi) { stepContext in
          let generation = try protocolEngine.beginMainlineGalleryFetch()
          fetchGeneration = generation
          let result = try await protocolEngine.executeJoinCameraWifiStep(
            context: stepContext,
            communicationGeneration: generation
          )
          didCompleteWifiHandoff = result.didCompleteWifiHandoff
          return result.execution
        },
      ]
    )
    do {
      _ = try await orchestrator.connect(context: sessionContext)
    } catch {
      let issue = orchestrator.recordFailure(error)
      protocolEngine.appendRuntimeMessage(
        terminalDiagnostic(
          connectionSessionID: connectionSessionID,
          plan: orchestrator.currentPlan,
          firstMissingBarrier: orchestrator.firstMissingBarrier,
          error: issue
        )
      )
      if allowCompatibilityLab {
        throw CameraVendorCompatibilityLabAttemptFailure(
          issue: issue,
          formalRouteFailure: CameraCompatibilityLabFormalRouteFailure(
            firstMissingBarrier: orchestrator.firstMissingBarrier ?? issue.step,
            failedPlan: orchestrator.currentPlan
          ),
          diagnosticHandler: { message in
            protocolEngine.appendRuntimeMessage(message)
          }
        )
      }
      throw issue
    }
    guard let connectionSummary, let fetchGeneration else {
      throw IOSCameraConnectionIssue(
        step: orchestrator.firstMissingBarrier ?? .joinCameraWifi,
        reason: "Fujifilm connection owner did not retain BLE summary or communication generation"
      )
    }
    let confirmedConnectionSteps = orchestrator.confirmedSteps()
    protocolEngine.appendRuntimeMessage(
      "[OBS] IOS_OFFICIAL_GALLERY_PRE_PTP_CONFIRMED steps=" +
      confirmedConnectionSteps.map(\.androidDisplayName).joined(separator: "->")
    )

    var diagnostics: [String] = []
    let recorder: (String) -> Void = { message in
      diagnostics.append(message)
      protocolEngine.appendRuntimeMessage(message)
    }
    let preparedFujifilmSession: FujifilmCameraSession
    do {
      preparedFujifilmSession = try await protocolEngine.connectGallerySession(
        executionState: executionState,
        cameraID: context.cameraID,
        observedIdentity: observedIdentity,
        communicationGeneration: fetchGeneration,
        didCompleteWifiHandoff: didCompleteWifiHandoff,
        recorder: recorder,
        onBarrierProgress: { event in
          try orchestrator.recordProgress(event)
          guard case let .ptpInitAcknowledged(strategy, _, transport) = event.evidence else {
            return
          }
          let currentPlan = orchestrator.currentPlan
          let revisedProtocolFacts = currentPlan.protocolFacts.updating(
            successfulInitStrategy: strategy,
            operationTransport: transport
          )
          guard revisedProtocolFacts != currentPlan.protocolFacts else { return }
          let revisedDecision = attemptEnvironment.resolve(
            protocolFacts: revisedProtocolFacts,
            revising: currentPlan.version
          )
          let revisionSummary = try orchestrator.applyRevision(
            revisedDecision.plan,
            reason: .ptpInitAcknowledged
          )
          try protocolEngine.applyRevision(
            orchestrator.currentPlan,
            reason: .ptpInitAcknowledged
          )
          protocolEngine.appendRuntimeMessage(self.planResolutionDiagnostic(
            decision: revisedDecision,
            connectionSessionID: connectionSessionID.uuidString,
            observedIdentity: observedIdentity,
            revisionReason: .ptpInitAcknowledged,
            revisionSummary: revisionSummary
          ))
        },
        onFunctionFactsInspected: { functionFacts in
          let currentPlan = orchestrator.currentPlan
          let revisedProtocolFacts = currentPlan.protocolFacts.updating(functionFacts: functionFacts)
          guard revisedProtocolFacts != currentPlan.protocolFacts else { return currentPlan }
          let revisedDecision = attemptEnvironment.resolve(
            protocolFacts: revisedProtocolFacts,
            revising: currentPlan.version
          )
          let revisionSummary = try orchestrator.applyRevision(
            revisedDecision.plan,
            reason: .functionFactsInspected
          )
          protocolEngine.appendRuntimeMessage(self.planResolutionDiagnostic(
            decision: revisedDecision,
            connectionSessionID: connectionSessionID.uuidString,
            observedIdentity: observedIdentity,
            revisionReason: .functionFactsInspected,
            revisionSummary: revisionSummary
          ))
          return orchestrator.currentPlan
        }
      )
    } catch {
      let routeError = protocolEngine.buildGalleryRouteFailure(
        didCompleteWifiHandoff: didCompleteWifiHandoff,
        diagnostics: diagnostics,
        error: error
      )
      protocolEngine.appendRuntimeMessage("[OBS] FUJIFILM_PROTOCOL_ENGINE_FAILED error=\(error.localizedDescription)")
      let issue = orchestrator.recordFailure(routeError)
      protocolEngine.appendRuntimeMessage(
        terminalDiagnostic(
          connectionSessionID: connectionSessionID,
          plan: orchestrator.currentPlan,
          firstMissingBarrier: orchestrator.firstMissingBarrier,
          error: issue
        )
      )
      if allowCompatibilityLab {
        throw CameraVendorCompatibilityLabAttemptFailure(
          issue: issue,
          formalRouteFailure: CameraCompatibilityLabFormalRouteFailure(
            firstMissingBarrier: orchestrator.firstMissingBarrier ?? issue.step,
            failedPlan: orchestrator.currentPlan
          ),
          diagnosticHandler: { message in
            protocolEngine.appendRuntimeMessage(message)
          }
        )
      }
      throw issue
    }

    let ptpSessionID = preparedFujifilmSession.sessionID
    guard !ptpSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IOSCameraConnectionIssue(
        step: .gallerySessionPrepared,
        reason: "Gallery Session 准备完成后缺少有效的 PTP session"
      )
    }
    let preparedConfirmedSteps = orchestrator.confirmedSteps()
    protocolEngine.appendRuntimeMessage(
      "[OBS] IOS_GALLERY_SESSION_PREPARED steps=" +
      preparedConfirmedSteps.map(\.androidDisplayName).joined(separator: "->")
    )
    protocolEngine.appendRuntimeMessage("[OBS] FUJIFILM_GALLERY_SESSION_PREPARED firstCatalogOwner=CatalogRuntime")
    protocolEngine.completeSuccessfulGalleryRouteSearch()

    return CameraVendorGalleryMainlineLoadResult(
      confirmedSteps: preparedConfirmedSteps,
      connectionSummary: connectionSummary,
      fujifilmSession: preparedFujifilmSession
    )
  }

  static func makeInitialDecision(
    connectionSessionID: UUID,
    compatibilityFacts: CameraCompatibilityFacts,
    compatibilityEnvironment: FujifilmCompatibilityEnvironment,
    forcedLabCandidate: CameraCompatibilityLabCandidate?
  ) throws -> CameraConnectionPlanDecision {
    let attemptEnvironment: FujifilmCompatibilityEnvironment
    if let forcedLabCandidate {
      attemptEnvironment = try compatibilityEnvironment.addingCompatibilityLabCandidate(
        forcedLabCandidate
      )
    } else {
      attemptEnvironment = compatibilityEnvironment
    }
    return try makeInitialDecision(
      connectionSessionID: connectionSessionID,
      compatibilityFacts: compatibilityFacts,
      attemptEnvironment: attemptEnvironment
    )
  }

  private static func makeInitialDecision(
    connectionSessionID: UUID,
    compatibilityFacts: CameraCompatibilityFacts,
    attemptEnvironment: FujifilmCompatibilityEnvironment
  ) throws -> CameraConnectionPlanDecision {
    return attemptEnvironment.resolve(
      protocolFacts: compatibilityFacts.protocolFacts,
      revising: CameraConnectionPlanVersion(
        id: CameraConnectionPlanID(
          rawValue: "connection-session-\(connectionSessionID.uuidString)"
        ),
        revision: 0
      )
    )
  }

  private func planResolutionDiagnostic(
    decision: CameraConnectionPlanDecision,
    connectionSessionID: String,
    observedIdentity: CameraObservedIdentity,
    revisionReason: CameraPlanRevisionReason? = nil,
    revisionSummary: CameraPlanRevisionSummary? = nil
  ) -> String {
    let plan = decision.plan
    return "[OBS] CAMERA_PLAN_RESOLUTION " +
      "connectionSessionID=\(connectionSessionID) planID=\(plan.id.rawValue) " +
      "revision=\(plan.revision) revisionReason=\(revisionReason?.rawValue ?? "initial") " +
      "fromRevision=\(revisionSummary.map { String($0.fromVersion.revision) } ?? "none") " +
      "changedStages=\(revisionSummary?.changedStages.map(\.rawValue).joined(separator: ",") ?? "none") " +
      "preservedLockedStages=\(revisionSummary?.preservedLockedStages.map(\.rawValue).joined(separator: ",") ?? "none") " +
      "supportStatus=\(plan.supportStatus.rawValue) " +
      "compatibilityFamily=\(plan.protocolFacts.compatibilityFamily?.rawValue ?? "unknown") " +
      "model=\(observedIdentity.modelName ?? "unknown") " +
      "firmware=\(observedIdentity.firmwareVersion ?? "unknown") " +
      "matchedRules=\(decision.matchedRuleIDs.map(\.rawValue).joined(separator: ",")) " +
      "unresolvedFacts=\(decision.unresolvedFacts.map(\.rawValue).joined(separator: ","))"
  }

  private func barrierDiagnostic(event: CameraConnectionBarrierLifecycleEvent) -> String {
    let outcome: String
    switch event.outcome {
    case .began: outcome = "BEGIN"
    case .succeeded: outcome = "SUCCEEDED"
    case .notRequired: outcome = "NOT_REQUIRED"
    case .failed: outcome = "FAILED"
    case .cancelled: outcome = "CANCELLED"
    }
    return "[OBS] CONNECTION_BARRIER_\(outcome) " +
      "connectionSessionID=\(event.connectionSessionID.uuidString) " +
      "planID=\(event.planVersion.id.rawValue) revision=\(event.planVersion.revision) " +
      "step=\(event.step.rawValue)"
  }

  private func terminalDiagnostic(
    connectionSessionID: UUID,
    plan: CameraConnectionPlan,
    firstMissingBarrier: IOSCameraConnectionStep?,
    error: Error
  ) -> String {
    let firstMissingBarrier = firstMissingBarrier ?? .gallerySessionPrepared
    return "[OBS] CONNECTION_TERMINAL " +
      "connectionSessionID=\(connectionSessionID.uuidString) " +
      "firstMissingBarrier=\(firstMissingBarrier.rawValue) " +
      "planID=\(plan.id.rawValue) revision=\(plan.revision) " +
      "strategyID=\(strategyID(for: firstMissingBarrier, plan: plan)) " +
      "lastWireOutcome=\(diagnosticValue(error.localizedDescription)) " +
      "retryOwner=\(retryOwner(for: firstMissingBarrier).rawValue)"
  }

  private func diagnosticValue(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "encoding-failed"
  }

  func recoverWithCompatibilityLab(
    failure: CameraVendorCompatibilityLabAttemptFailure,
    context: IOSCameraConnectionContext,
    publishStep: @escaping (IOSCameraConnectionStep) -> Void,
    performBleConnection: @escaping (
      @escaping (CameraCompatibilityFacts) throws -> ActivationStrategyDefinition
    ) async throws -> CameraVendorConnectionSummary,
    compatibilityLabReset: @escaping CameraCompatibilityLab.ResetHandler,
    compatibilityLabAttempt: CompatibilityLabAttemptExecutor? = nil
  ) async throws -> CameraVendorGalleryMainlineLoadResult {
    let lab = try CameraCompatibilityLab(
      buildChannel: .current,
      candidateProvider: compatibilityLabCandidateProvider,
      diagnosticHandler: failure.diagnosticHandler
    )
    var recoveredResult: CameraVendorGalleryMainlineLoadResult?
    _ = await lab.run(
      formalRouteFailure: failure.formalRouteFailure,
      reset: compatibilityLabReset,
      executeProductionRoute: { candidate, revisedPlan in
        do {
          if let compatibilityLabAttempt {
            recoveredResult = try await compatibilityLabAttempt(candidate, revisedPlan)
          } else {
            recoveredResult = try await self.loadGallerySessionAttempt(
              context: context,
              publishStep: publishStep,
              performBleConnection: performBleConnection,
              forcedLabCandidate: candidate,
              allowCompatibilityLab: false
            )
          }
          return .succeeded
        } catch {
          return .failed
        }
      }
    )
    guard let recoveredResult else { throw failure.issue }
    return recoveredResult
  }

  private func strategyID(
    for step: IOSCameraConnectionStep,
    plan: CameraConnectionPlan
  ) -> String {
    switch CameraConnectionPlanStage.stage(for: step) {
    case .pairing: return plan.pairingStrategy.rawValue
    case .activation: return plan.activationStrategy.rawValue
    case .ptpInit: return plan.ptpInitStrategy.rawValue
    case .openSession: return "fujifilm-open-session"
    case .negotiation: return plan.negotiationStrategy.rawValue
    case .bootstrap: return plan.galleryBootstrapStrategy.rawValue
    case .initialCatalog: return plan.initialCatalogStrategy.rawValue
    case nil: return "unknown"
    }
  }

  private func retryOwner(
    for step: IOSCameraConnectionStep
  ) -> CameraConnectionRetryOwner {
    switch CameraConnectionPlanStage.stage(for: step) {
    case .pairing, .activation, .openSession, nil: return .protocolEngine
    case .ptpInit: return .ptpInitStrategy
    case .negotiation: return .negotiationStrategy
    case .bootstrap: return .galleryBootstrapStrategy
    case .initialCatalog: return .catalogRuntime
    }
  }

}
