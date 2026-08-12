import Foundation

final class CameraConnectionExecutionState {
  static let stagesLockedBeforeInitialCatalog: Set<CameraConnectionPlanStage> = [
    .pairing,
    .activation,
    .ptpInit,
    .negotiation,
    .bootstrap,
  ]

  let connectionSessionID: UUID
  private(set) var plan: CameraConnectionPlan
  private(set) var completedSteps: [IOSCameraConnectionStep]
  private(set) var firstFailure: IOSCameraConnectionIssue?
  private(set) var currentBarrier: IOSCameraConnectionStep?
  private(set) var lastRevisionReason: CameraPlanRevisionReason?
  private(set) var lastRevisionSummary: CameraPlanRevisionSummary?
  private(set) var barrierEvents: [CameraConnectionBarrierLifecycleEvent] = []
  private var evidenceByStep: [IOSCameraConnectionStep: IOSCameraConnectionStepEvidence]
  private let onBarrierEvent: ((CameraConnectionBarrierLifecycleEvent) -> Void)?

  init(
    connectionSessionID: UUID = UUID(),
    plan: CameraConnectionPlan,
    initialConfirmedSteps: [IOSCameraConnectionStep] = [],
    onBarrierEvent: ((CameraConnectionBarrierLifecycleEvent) -> Void)? = nil
  ) {
    precondition(
      initialConfirmedSteps == Array(IOSCameraConnectionStep.officialGalleryOrder.prefix(initialConfirmedSteps.count)),
      "Initial iOS camera connection steps must be an official prefix"
    )
    self.connectionSessionID = connectionSessionID
    self.plan = plan
    self.completedSteps = initialConfirmedSteps
    self.evidenceByStep = [:]
    self.onBarrierEvent = onBarrierEvent
  }

  func record(
    step: IOSCameraConnectionStep,
    evidence: IOSCameraConnectionStepEvidence
  ) throws -> IOSCameraConnectionStep? {
    if currentBarrier == nil {
      try begin(step: step)
    }
    let decision = try decideAdvance(from: step, with: evidence)
    completedSteps.append(step)
    evidenceByStep[step] = evidence
    appendBarrierEvent(
      CameraConnectionBarrierLifecycleEvent(
        connectionSessionID: connectionSessionID,
        planVersion: plan.version,
        step: step,
        outcome: barrierOutcome(for: evidence)
      )
    )
    currentBarrier = nil
    return decision.nextStep
  }

  func record(_ event: CameraConnectionBarrierEvent) throws -> IOSCameraConnectionStep? {
    try validate(event)
    return try record(step: event.step, evidence: event.evidence)
  }

  func validate(_ event: CameraConnectionBarrierEvent) throws {
    guard event.connectionSessionID == connectionSessionID else {
      throw IOSCameraConnectionIssue(
        step: event.step,
        reason: "Stale connection session event"
      )
    }
    guard event.planVersion == plan.version else {
      throw IOSCameraConnectionIssue(
        step: event.step,
        reason: "Stale plan revision \(event.planVersion.revision); current revision is \(plan.revision)"
      )
    }
  }

  func begin(step: IOSCameraConnectionStep) throws {
    guard nextExpectedStep == step else {
      throw IOSCameraConnectionIssue(
        step: nextExpectedStep ?? step,
        reason: "Cannot begin \(step.androidDisplayName) outside the current connection order"
      )
    }
    if let currentBarrier, currentBarrier != step {
      throw IOSCameraConnectionIssue(
        step: currentBarrier,
        reason: "Cannot begin \(step.androidDisplayName) while \(currentBarrier.androidDisplayName) is active"
      )
    }
    currentBarrier = step
    appendBarrierEvent(
      CameraConnectionBarrierLifecycleEvent(
        connectionSessionID: connectionSessionID,
        planVersion: plan.version,
        step: step,
        outcome: .began
      )
    )
  }

  @discardableResult
  func applyRevision(
    _ candidate: CameraConnectionPlan,
    reason: CameraPlanRevisionReason,
    preservingExecutedStages: Set<CameraConnectionPlanStage> = []
  ) throws -> CameraPlanRevisionSummary {
    guard candidate.id == plan.id else {
      throw NSError(
        domain: "CameraConnectionExecutionState",
        code: 20,
        userInfo: [NSLocalizedDescriptionKey: "Plan revision must keep the current session lineage"]
      )
    }
    guard candidate.revision == plan.revision + 1 else {
      throw NSError(
        domain: "CameraConnectionExecutionState",
        code: 21,
        userInfo: [NSLocalizedDescriptionKey: "Plan revision must be adjacent"]
      )
    }
    guard candidate.supportStatus != .unsupported else {
      throw NSError(
        domain: "CameraConnectionExecutionState",
        code: 22,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported revision requires session termination"]
      )
    }

    let old = plan
    let revised = CameraConnectionPlan(
      id: old.id,
      revision: candidate.revision,
      registryVersion: candidate.registryVersion,
      supportStatus: candidate.supportStatus,
      protocolFacts: candidate.protocolFacts,
      pairingStrategy: isLocked(.pairing) || preservingExecutedStages.contains(.pairing)
        ? old.pairingStrategy
        : candidate.pairingStrategy,
      activationStrategy: isLocked(.activation) || preservingExecutedStages.contains(.activation)
        ? old.activationStrategy
        : candidate.activationStrategy,
      ptpInitStrategy: isLocked(.ptpInit) || preservingExecutedStages.contains(.ptpInit)
        ? old.ptpInitStrategy
        : candidate.ptpInitStrategy,
      negotiationStrategy: isLocked(.negotiation) || preservingExecutedStages.contains(.negotiation)
        ? old.negotiationStrategy
        : candidate.negotiationStrategy,
      galleryBootstrapStrategy: isLocked(.bootstrap) || preservingExecutedStages.contains(.bootstrap)
        ? old.galleryBootstrapStrategy
        : candidate.galleryBootstrapStrategy,
      initialCatalogStrategy: candidate.initialCatalogStrategy
    )
    let changedStages = CameraConnectionPlanStage.allCases.filter {
      strategyChanged(for: $0, from: old, to: revised)
    }
    let preservedLockedStages = CameraConnectionPlanStage.allCases.filter {
      strategyChanged(for: $0, from: old, to: candidate)
        && !strategyChanged(for: $0, from: old, to: revised)
    }
    plan = revised
    lastRevisionReason = reason
    let summary = CameraPlanRevisionSummary(
      fromVersion: old.version,
      toVersion: revised.version,
      reason: reason,
      changedStages: changedStages,
      preservedLockedStages: preservedLockedStages
    )
    lastRevisionSummary = summary
    return summary
  }

  func recordFailure(_ failure: IOSCameraConnectionIssue) {
    guard firstFailure == nil else { return }
    firstFailure = failure
    let failedStep = currentBarrier ?? failure.step
    appendBarrierEvent(
      CameraConnectionBarrierLifecycleEvent(
        connectionSessionID: connectionSessionID,
        planVersion: plan.version,
        step: failedStep,
        outcome: .failed
      )
    )
    currentBarrier = nil
  }

  func recordCancellation(step: IOSCameraConnectionStep) {
    guard firstFailure == nil else { return }
    firstFailure = IOSCameraConnectionIssue(step: step, reason: "Connection cancelled")
    appendBarrierEvent(
      CameraConnectionBarrierLifecycleEvent(
        connectionSessionID: connectionSessionID,
        planVersion: plan.version,
        step: currentBarrier ?? step,
        outcome: .cancelled
      )
    )
    currentBarrier = nil
  }

  func evidence(for step: IOSCameraConnectionStep) -> IOSCameraConnectionStepEvidence? {
    evidenceByStep[step]
  }

  var nextExpectedStep: IOSCameraConnectionStep? {
    IOSCameraConnectionStep.officialGalleryOrder[safe: completedSteps.count]
  }

  var firstMissingBarrier: IOSCameraConnectionStep? {
    firstFailure?.step ?? nextExpectedStep
  }

  private func barrierOutcome(
    for evidence: IOSCameraConnectionStepEvidence
  ) -> CameraConnectionBarrierOutcome {
    if case let .functionNegotiated(_, strategy) = evidence,
       strategy == .notRequiredCurrentBaseline {
      return .notRequired
    }
    return .succeeded
  }

  private func appendBarrierEvent(_ event: CameraConnectionBarrierLifecycleEvent) {
    barrierEvents.append(event)
    onBarrierEvent?(event)
  }

  private func isLocked(_ stage: CameraConnectionPlanStage) -> Bool {
    if let currentBarrier, CameraConnectionPlanStage.stage(for: currentBarrier) == stage {
      return true
    }
    return completedSteps.contains {
      CameraConnectionPlanStage.stage(for: $0) == stage
    }
  }

  private func strategyChanged(
    for stage: CameraConnectionPlanStage,
    from old: CameraConnectionPlan,
    to new: CameraConnectionPlan
  ) -> Bool {
    switch stage {
    case .pairing:
      return old.pairingStrategy != new.pairingStrategy
    case .activation:
      return old.activationStrategy != new.activationStrategy
    case .ptpInit:
      return old.ptpInitStrategy != new.ptpInitStrategy
    case .openSession:
      return false
    case .negotiation:
      return old.negotiationStrategy != new.negotiationStrategy
    case .bootstrap:
      return old.galleryBootstrapStrategy != new.galleryBootstrapStrategy
    case .initialCatalog:
      return old.initialCatalogStrategy != new.initialCatalogStrategy
    }
  }

  func decideAdvance(
    from step: IOSCameraConnectionStep,
    with evidence: IOSCameraConnectionStepEvidence
  ) throws -> IOSCameraConnectionAdvanceDecision {
    switch (step, evidence) {
    case let (.reconnectPairedBle, .bleIdentityVerified(cameraID))
      where !cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .transferAuthorization)

    case (.transferAuthorization, .officialWifiCredential):
      return IOSCameraConnectionAdvanceDecision(nextStep: .activateCameraWifi)

    case (.activateCameraWifi, .cameraWifiActivationAcknowledged):
      return IOSCameraConnectionAdvanceDecision(nextStep: .waitCameraWifiReady)

    case (.waitCameraWifiReady, .cameraWifiReady):
      return IOSCameraConnectionAdvanceDecision(nextStep: .joinCameraWifi)

    case let (.joinCameraWifi, .joinedCameraWifi(ssid))
      where !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .ptpTransportConnected)

    case let (.ptpTransportConnected, .ptpTransportConnected(host, port))
      where !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && port > 0:
      return IOSCameraConnectionAdvanceDecision(nextStep: .ptpInitAcknowledged)

    case let (.ptpInitAcknowledged, .ptpInitAcknowledged(strategy, _, _))
      where strategy == plan.ptpInitStrategy:
      return IOSCameraConnectionAdvanceDecision(nextStep: .ptpSessionOpened)

    case let (.ptpSessionOpened, .ptpSessionOpened(sessionID))
      where !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return IOSCameraConnectionAdvanceDecision(nextStep: .functionNegotiated)

    case let (.functionNegotiated, .functionNegotiated(planID, strategy))
      where planID == plan.id && strategy == plan.negotiationStrategy:
      return IOSCameraConnectionAdvanceDecision(nextStep: .gallerySessionPrepared)

    case let (.gallerySessionPrepared, .gallerySessionPrepared(planID, strategy))
      where planID == plan.id && strategy == plan.galleryBootstrapStrategy:
      return IOSCameraConnectionAdvanceDecision(nextStep: nil)

    default:
      throw IOSCameraConnectionIssue(
        step: step,
        reason: "Missing required evidence for \(step.androidDisplayName)"
      )
    }
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
