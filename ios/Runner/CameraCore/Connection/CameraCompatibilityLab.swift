import Foundation

enum CameraCompatibilityLabBuildChannel: Equatable {
  case release
  case debug
  case internalBuild

  static var current: CameraCompatibilityLabBuildChannel {
#if INTERNAL
    return .internalBuild
#elseif DEBUG
    return .debug
#else
    return .release
#endif
  }
}

enum CameraCompatibilityLabChangedVariable: String, Equatable {
  case pairingStrategy
  case activationStrategy
  case ptpInitStrategy
  case negotiationStrategy
  case galleryBootstrapStrategy
  case initialCatalogStrategy
}

enum CameraCompatibilityLabPlanOverride: Equatable {
  case pairingStrategy(PairingStrategyID)
  case activationStrategy(ActivationStrategyID)
  case ptpInitStrategy(PtpInitStrategyID)
  case negotiationStrategy(SessionNegotiationStrategyID)
  case galleryBootstrapStrategy(GalleryBootstrapStrategyID)
  case initialCatalogStrategy(InitialCatalogStrategyID)

  var changedVariable: CameraCompatibilityLabChangedVariable {
    switch self {
    case .pairingStrategy: return .pairingStrategy
    case .activationStrategy: return .activationStrategy
    case .ptpInitStrategy: return .ptpInitStrategy
    case .negotiationStrategy: return .negotiationStrategy
    case .galleryBootstrapStrategy: return .galleryBootstrapStrategy
    case .initialCatalogStrategy: return .initialCatalogStrategy
    }
  }

  func applying(
    to plan: CameraConnectionPlan,
    incrementRevision: Bool = true
  ) -> CameraConnectionPlan {
    CameraConnectionPlan(
      id: plan.id,
      revision: plan.revision + (incrementRevision ? 1 : 0),
      registryVersion: plan.registryVersion,
      supportStatus: .experimental,
      protocolFacts: plan.protocolFacts,
      pairingStrategy: pairingStrategy(in: plan),
      activationStrategy: activationStrategy(in: plan),
      ptpInitStrategy: ptpInitStrategy(in: plan),
      negotiationStrategy: negotiationStrategy(in: plan),
      galleryBootstrapStrategy: galleryBootstrapStrategy(in: plan),
      initialCatalogStrategy: initialCatalogStrategy(in: plan)
    )
  }

  private func pairingStrategy(in plan: CameraConnectionPlan) -> PairingStrategyID {
    if case let .pairingStrategy(value) = self { return value }
    return plan.pairingStrategy
  }

  private func activationStrategy(in plan: CameraConnectionPlan) -> ActivationStrategyID {
    if case let .activationStrategy(value) = self { return value }
    return plan.activationStrategy
  }

  private func ptpInitStrategy(in plan: CameraConnectionPlan) -> PtpInitStrategyID {
    if case let .ptpInitStrategy(value) = self { return value }
    return plan.ptpInitStrategy
  }

  private func negotiationStrategy(in plan: CameraConnectionPlan) -> SessionNegotiationStrategyID {
    if case let .negotiationStrategy(value) = self { return value }
    return plan.negotiationStrategy
  }

  private func galleryBootstrapStrategy(in plan: CameraConnectionPlan) -> GalleryBootstrapStrategyID {
    if case let .galleryBootstrapStrategy(value) = self { return value }
    return plan.galleryBootstrapStrategy
  }

  private func initialCatalogStrategy(in plan: CameraConnectionPlan) -> InitialCatalogStrategyID {
    if case let .initialCatalogStrategy(value) = self { return value }
    return plan.initialCatalogStrategy
  }
}

enum CameraCompatibilityLabExperimentalStrategyDefinition: Equatable {
  case activation(ActivationStrategyDefinition)
  case ptpInit(PtpInitStrategyDefinition)
  case negotiation(SessionNegotiationStrategyDefinition)
  case galleryBootstrap(GalleryBootstrapStrategyDefinition)
  case initialCatalog(InitialCatalogStrategyDefinition)

  var supportStatus: CameraSupportStatus {
    switch self {
    case .activation(let definition): return definition.supportStatus
    case .ptpInit(let definition): return definition.supportStatus
    case .negotiation(let definition): return definition.supportStatus
    case .galleryBootstrap(let definition): return definition.supportStatus
    case .initialCatalog(let definition): return definition.supportStatus
    }
  }

  var planOverride: CameraCompatibilityLabPlanOverride {
    switch self {
    case .activation(let definition):
      return .activationStrategy(definition.id)
    case .ptpInit(let definition):
      return .ptpInitStrategy(definition.id)
    case .negotiation(let definition):
      return .negotiationStrategy(definition.id)
    case .galleryBootstrap(let definition):
      return .galleryBootstrapStrategy(definition.id)
    case .initialCatalog(let definition):
      return .initialCatalogStrategy(definition.id)
    }
  }
}

struct CameraCompatibilityLabEvidence: Equatable {
  let id: String
  let source: String
}

enum CameraCompatibilityLabResetRequirement: String, Equatable {
  case fullConnectionReset
}

enum CameraCompatibilityLabResetResult: String, Equatable {
  case succeeded
  case failed
}

enum CameraCompatibilityLabTerminalOutcome: String, Equatable {
  case succeeded
  case failed
  case resetFailed
}

struct CameraCompatibilityLabCandidate: Equatable {
  let id: String
  let barrier: IOSCameraConnectionStep
  let strategyDefinition: CameraCompatibilityLabExperimentalStrategyDefinition
  let evidence: CameraCompatibilityLabEvidence
  let resetRequirement: CameraCompatibilityLabResetRequirement

  init(
    id: String,
    barrier: IOSCameraConnectionStep,
    strategyDefinition: CameraCompatibilityLabExperimentalStrategyDefinition,
    evidence: CameraCompatibilityLabEvidence,
    resetRequirement: CameraCompatibilityLabResetRequirement
  ) {
    self.id = id
    self.barrier = barrier
    self.strategyDefinition = strategyDefinition
    self.evidence = evidence
    self.resetRequirement = resetRequirement
  }

  var changedVariable: CameraCompatibilityLabChangedVariable {
    strategyDefinition.planOverride.changedVariable
  }

  func revisedPlan(from plan: CameraConnectionPlan) throws -> CameraConnectionPlan {
    guard Self.isScoped(changedVariable, to: barrier) else {
      throw CameraCompatibilityLabValidationError.candidateBarrierMismatch(
        candidateID: id,
        barrier: barrier,
        changedVariable: changedVariable
      )
    }
    return strategyDefinition.planOverride.applying(to: plan)
  }

  func preservingOverride(in plan: CameraConnectionPlan) -> CameraConnectionPlan {
    strategyDefinition.planOverride.applying(to: plan, incrementRevision: false)
  }

  private static func isScoped(
    _ changedVariable: CameraCompatibilityLabChangedVariable,
    to barrier: IOSCameraConnectionStep
  ) -> Bool {
    switch changedVariable {
    case .pairingStrategy:
      return [.reconnectPairedBle, .transferAuthorization].contains(barrier)
    case .activationStrategy:
      return [.activateCameraWifi, .waitCameraWifiReady, .joinCameraWifi].contains(barrier)
    case .ptpInitStrategy:
      return [.ptpTransportConnected, .ptpInitAcknowledged].contains(barrier)
    case .negotiationStrategy:
      return barrier == .functionNegotiated
    case .galleryBootstrapStrategy, .initialCatalogStrategy:
      return barrier == .gallerySessionPrepared
    }
  }
}

enum CameraCompatibilityLabCandidateEmptyReason: String, Equatable {
  case noRegisteredExperimentalStrategyDefinitions
  case noCandidatesForBarrier
}

struct CameraCompatibilityLabCandidateCatalog: Equatable {
  let candidates: [CameraCompatibilityLabCandidate]
  let emptyReason: CameraCompatibilityLabCandidateEmptyReason?

  init(
    candidates: [CameraCompatibilityLabCandidate],
    emptyReason: CameraCompatibilityLabCandidateEmptyReason?
  ) throws {
    guard candidates.count <= CameraCompatibilityLab.maximumCandidateCount else {
      throw CameraCompatibilityLabValidationError.tooManyCandidates(candidates.count)
    }
    guard candidates.isEmpty == (emptyReason != nil) else {
      if candidates.isEmpty {
        throw CameraCompatibilityLabValidationError.missingEmptyCatalogReason
      }
      throw CameraCompatibilityLabValidationError.unexpectedEmptyCatalogReason
    }

    var seenIDs = Set<String>()
    for candidate in candidates {
      guard Self.isSafeIdentifier(candidate.id) else {
        throw CameraCompatibilityLabValidationError.invalidCandidateID(candidate.id)
      }
      guard seenIDs.insert(candidate.id).inserted else {
        throw CameraCompatibilityLabValidationError.duplicateCandidateID(candidate.id)
      }
      guard candidate.strategyDefinition.supportStatus == .experimental else {
        throw CameraCompatibilityLabValidationError.nonExperimentalStrategyDefinition(
          candidateID: candidate.id,
          supportStatus: candidate.strategyDefinition.supportStatus
        )
      }
      guard Self.isSafeIdentifier(candidate.evidence.id) else {
        throw CameraCompatibilityLabValidationError.invalidEvidenceID(candidate.evidence.id)
      }
      guard !candidate.evidence.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CameraCompatibilityLabValidationError.invalidEvidenceSource(candidate.evidence.source)
      }
      _ = try candidate.revisedPlan(from: CameraCompatibilityLab.validationPlan)
    }

    self.candidates = candidates
    self.emptyReason = emptyReason
  }

  static let production: CameraCompatibilityLabCandidateCatalog = {
    do {
      return try CameraCompatibilityLabCandidateCatalog(
        candidates: [],
        emptyReason: .noRegisteredExperimentalStrategyDefinitions
      )
    } catch {
      preconditionFailure("Invalid production Compatibility Lab candidate catalog: \(error)")
    }
  }()

  private static func isSafeIdentifier(_ id: String) -> Bool {
    id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
  }
}

struct CameraCompatibilityLabCandidateProvider: Equatable {
  let catalog: CameraCompatibilityLabCandidateCatalog

  static let production = CameraCompatibilityLabCandidateProvider(catalog: .production)

  func candidates(for barrier: IOSCameraConnectionStep) -> [CameraCompatibilityLabCandidate] {
    catalog.candidates.filter { $0.barrier == barrier }
  }

  func emptyReason(
    for barrier: IOSCameraConnectionStep
  ) -> CameraCompatibilityLabCandidateEmptyReason? {
    guard candidates(for: barrier).isEmpty else { return nil }
    return catalog.emptyReason ?? .noCandidatesForBarrier
  }
}

struct CameraCompatibilityLabFormalRouteFailure: Equatable {
  let firstMissingBarrier: IOSCameraConnectionStep
  let failedPlan: CameraConnectionPlan
}

enum CameraCompatibilityLabUnsupportedReason: String, Equatable {
  case releaseBuild
  case formalRouteDidNotFail
  case verifiedPlanRegression
  case noCandidatesForBarrier
}

struct CameraCompatibilityLabAttemptResult: Equatable {
  let firstMissingBarrier: IOSCameraConnectionStep
  let candidateID: String
  let evidenceID: String
  let changedVariable: CameraCompatibilityLabChangedVariable
  let resetResult: CameraCompatibilityLabResetResult
  let terminalOutcome: CameraCompatibilityLabTerminalOutcome
}

enum CameraCompatibilityLabRunResult: Equatable {
  case unsupported(CameraCompatibilityLabUnsupportedReason)
  case completed([CameraCompatibilityLabAttemptResult])
}

enum CameraCompatibilityLabValidationError: Error, Equatable, LocalizedError {
  case tooManyCandidates(Int)
  case duplicateCandidateID(String)
  case invalidCandidateID(String)
  case invalidEvidenceID(String)
  case invalidEvidenceSource(String)
  case nonExperimentalStrategyDefinition(
    candidateID: String,
    supportStatus: CameraSupportStatus
  )
  case missingEmptyCatalogReason
  case unexpectedEmptyCatalogReason
  case candidateBarrierMismatch(
    candidateID: String,
    barrier: IOSCameraConnectionStep,
    changedVariable: CameraCompatibilityLabChangedVariable
  )

  var errorDescription: String? {
    switch self {
    case .tooManyCandidates(let count):
      return "Compatibility Lab candidate list exceeds the finite limit: \(count)"
    case .duplicateCandidateID(let id):
      return "Compatibility Lab candidate ID is duplicated: \(id)"
    case .invalidCandidateID(let id):
      return "Compatibility Lab candidate ID is invalid: \(id)"
    case .invalidEvidenceID(let id):
      return "Compatibility Lab evidence ID is invalid: \(id)"
    case .invalidEvidenceSource(let source):
      return "Compatibility Lab evidence source is invalid: \(source)"
    case let .nonExperimentalStrategyDefinition(candidateID, supportStatus):
      return "Compatibility Lab candidate \(candidateID) must use an experimental Strategy Definition, got \(supportStatus.rawValue)"
    case .missingEmptyCatalogReason:
      return "Compatibility Lab empty candidate catalog must include a reason"
    case .unexpectedEmptyCatalogReason:
      return "Compatibility Lab non-empty candidate catalog cannot include an empty reason"
    case let .candidateBarrierMismatch(candidateID, barrier, changedVariable):
      return "Compatibility Lab candidate \(candidateID) changes \(changedVariable.rawValue) outside barrier \(barrier.rawValue)"
    }
  }
}

final class CameraCompatibilityLab {
  static let maximumCandidateCount = 8

  typealias DiagnosticHandler = (String) -> Void
  typealias ResetHandler = (
    CameraCompatibilityLabResetRequirement
  ) async -> CameraCompatibilityLabResetResult
  typealias ProductionRouteExecutor = (
    CameraCompatibilityLabCandidate,
    CameraConnectionPlan
  ) async -> CameraCompatibilityLabTerminalOutcome

  let buildChannel: CameraCompatibilityLabBuildChannel
  private let candidateProvider: CameraCompatibilityLabCandidateProvider
  private let diagnosticHandler: DiagnosticHandler

  init(
    buildChannel: CameraCompatibilityLabBuildChannel,
    candidateProvider: CameraCompatibilityLabCandidateProvider,
    diagnosticHandler: @escaping DiagnosticHandler
  ) throws {
    self.buildChannel = buildChannel
    self.candidateProvider = candidateProvider
    self.diagnosticHandler = diagnosticHandler
  }

  func run(
    formalRouteFailure: CameraCompatibilityLabFormalRouteFailure?,
    reset: @escaping ResetHandler,
    executeProductionRoute: @escaping ProductionRouteExecutor
  ) async -> CameraCompatibilityLabRunResult {
    guard buildChannel != .release else {
      emitGate(
        firstMissingBarrier: formalRouteFailure?.firstMissingBarrier,
        reason: .releaseBuild
      )
      return .unsupported(.releaseBuild)
    }
    guard let formalRouteFailure else {
      emitGate(firstMissingBarrier: nil, reason: .formalRouteDidNotFail)
      return .unsupported(.formalRouteDidNotFail)
    }
    guard formalRouteFailure.failedPlan.supportStatus != .verified else {
      emitGate(
        firstMissingBarrier: formalRouteFailure.firstMissingBarrier,
        reason: .verifiedPlanRegression
      )
      return .unsupported(.verifiedPlanRegression)
    }
    let scopedCandidates = candidateProvider.candidates(
      for: formalRouteFailure.firstMissingBarrier
    )
    guard !scopedCandidates.isEmpty else {
      emitGate(
        firstMissingBarrier: formalRouteFailure.firstMissingBarrier,
        reason: .noCandidatesForBarrier,
        candidateProviderReason: candidateProvider.emptyReason(
          for: formalRouteFailure.firstMissingBarrier
        )
      )
      return .unsupported(.noCandidatesForBarrier)
    }

    var results: [CameraCompatibilityLabAttemptResult] = []
    for candidate in scopedCandidates {
      let resetResult = await reset(candidate.resetRequirement)
      guard resetResult == .succeeded else {
        let result = CameraCompatibilityLabAttemptResult(
          firstMissingBarrier: formalRouteFailure.firstMissingBarrier,
          candidateID: candidate.id,
          evidenceID: candidate.evidence.id,
          changedVariable: candidate.changedVariable,
          resetResult: resetResult,
          terminalOutcome: .resetFailed
        )
        results.append(result)
        emitAttempt(result)
        continue
      }

      let revisedPlan: CameraConnectionPlan
      do {
        revisedPlan = try candidate.revisedPlan(from: formalRouteFailure.failedPlan)
      } catch {
        let result = CameraCompatibilityLabAttemptResult(
          firstMissingBarrier: formalRouteFailure.firstMissingBarrier,
          candidateID: candidate.id,
          evidenceID: candidate.evidence.id,
          changedVariable: candidate.changedVariable,
          resetResult: resetResult,
          terminalOutcome: .failed
        )
        results.append(result)
        emitAttempt(result)
        continue
      }
      let terminalOutcome = await executeProductionRoute(candidate, revisedPlan)
      let result = CameraCompatibilityLabAttemptResult(
        firstMissingBarrier: formalRouteFailure.firstMissingBarrier,
        candidateID: candidate.id,
        evidenceID: candidate.evidence.id,
        changedVariable: candidate.changedVariable,
        resetResult: resetResult,
        terminalOutcome: terminalOutcome
      )
      results.append(result)
      emitAttempt(result)
      if terminalOutcome == .succeeded { break }
    }
    return .completed(results)
  }

  private func emitGate(
    firstMissingBarrier: IOSCameraConnectionStep?,
    reason: CameraCompatibilityLabUnsupportedReason,
    candidateProviderReason: CameraCompatibilityLabCandidateEmptyReason? = nil
  ) {
    diagnosticHandler(
      "[OBS] CAMERA_COMPATIBILITY_LAB_GATE " +
      "firstMissingBarrier=\(firstMissingBarrier?.rawValue ?? "none") " +
      "candidateID=none changedVariable=none resetResult=notRun " +
      "terminalOutcome=unsupported reason=\(reason.rawValue) " +
      "candidateProviderReason=\(candidateProviderReason?.rawValue ?? "notEvaluated")"
    )
  }

  private func emitAttempt(_ result: CameraCompatibilityLabAttemptResult) {
    diagnosticHandler(
      "[OBS] CAMERA_COMPATIBILITY_LAB_ATTEMPT " +
      "firstMissingBarrier=\(result.firstMissingBarrier.rawValue) " +
      "candidateID=\(result.candidateID) " +
      "evidenceID=\(result.evidenceID) " +
      "changedVariable=\(result.changedVariable.rawValue) " +
      "resetResult=\(result.resetResult.rawValue) " +
      "terminalOutcome=\(result.terminalOutcome.rawValue)"
    )
  }

  fileprivate static let validationPlan = CameraConnectionPlan(
    id: CameraConnectionPlanID(rawValue: "compatibility-lab-validation"),
    revision: 0,
    registryVersion: "compatibility-lab-validation",
    supportStatus: .verified,
    protocolFacts: CameraProtocolFacts(
      compatibilityFamily: nil,
      advertisedServices: [],
      discoveredCharacteristics: []
    ),
    pairingStrategy: PairingStrategyID(rawValue: "lab-pairing"),
    activationStrategy: ActivationStrategyID(rawValue: "lab-activation"),
    ptpInitStrategy: PtpInitStrategyID(rawValue: "lab-ptp-init"),
    negotiationStrategy: SessionNegotiationStrategyID(rawValue: "lab-negotiation"),
    galleryBootstrapStrategy: GalleryBootstrapStrategyID(rawValue: "lab-bootstrap"),
    initialCatalogStrategy: InitialCatalogStrategyID(rawValue: "lab-catalog")
  )
}
