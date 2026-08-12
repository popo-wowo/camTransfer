import Foundation

final class CameraConnectionOrchestrator {
  let runners: [IOSCameraConnectionStepRunner]
  private let executionState: CameraConnectionExecutionState
  private let onStepStarted: ((IOSCameraConnectionStep) -> Void)?
  private let onStepCompleted: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)?

  init(
    executionState: CameraConnectionExecutionState,
    onStepStarted: ((IOSCameraConnectionStep) -> Void)? = nil,
    onStepCompleted: ((IOSCameraConnectionStep, IOSCameraConnectionStepEvidence) throws -> Void)? = nil,
    runners: [IOSCameraConnectionStepRunner]
  ) {
    self.executionState = executionState
    self.onStepStarted = onStepStarted
    self.onStepCompleted = onStepCompleted
    self.runners = runners
  }

  func connect(context initialContext: IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext {
    var context = initialContext
    for runner in runners {
      guard let expectedStep = executionState.nextExpectedStep else {
        let issue = IOSCameraConnectionIssue(
          step: runner.step,
          reason: "Cannot run \(runner.step.androidDisplayName) after the connection plan is complete"
        )
        executionState.recordFailure(issue)
        throw issue
      }
      guard runner.step == expectedStep else {
        let issue = IOSCameraConnectionIssue(
          step: expectedStep,
          reason: "Cannot run \(runner.step.androidDisplayName) before \(expectedStep.androidDisplayName)"
        )
        executionState.recordFailure(issue)
        throw issue
      }
      try executionState.begin(step: runner.step)
      if let onStepStarted {
        onStepStarted(runner.step)
      }
      do {
        let execution = try await runner.run(context: context)
        let nextStep = try executionState.record(
          CameraConnectionBarrierEvent(
            connectionSessionID: executionState.connectionSessionID,
            planVersion: executionState.plan.version,
            step: runner.step,
            evidence: execution.evidence
          )
        )
        if nextStep != executionState.nextExpectedStep {
          let issue = IOSCameraConnectionIssue(
            step: runner.step,
            reason: "Evidence advanced to \(nextStep?.androidDisplayName ?? "Complete") instead of \(executionState.nextExpectedStep?.androidDisplayName ?? "Complete")"
          )
          executionState.recordFailure(issue)
          throw issue
        }
        try onStepCompleted?(runner.step, execution.evidence)
        context = execution.context
      } catch is CancellationError {
        executionState.recordCancellation(step: runner.step)
        throw CancellationError()
      } catch let issue as IOSCameraConnectionIssue {
        executionState.recordFailure(issue)
        throw issue
      } catch {
        let issue = IOSCameraConnectionIssue(step: runner.step, reason: error.localizedDescription)
        executionState.recordFailure(issue)
        throw issue
      }
    }
    return context
  }

  func recordProgress(_ event: CameraConnectionBarrierEvent) throws {
    try executionState.validate(event)
    if executionState.completedSteps.contains(event.step) {
      return
    }
    guard executionState.nextExpectedStep == event.step else {
      let issue = IOSCameraConnectionIssue(
        step: executionState.nextExpectedStep ?? event.step,
        reason: "Cannot record \(event.step.androidDisplayName) outside the current connection order"
      )
      executionState.recordFailure(issue)
      throw issue
    }
    try executionState.begin(step: event.step)
    onStepStarted?(event.step)
    _ = try executionState.record(event)
  }

  func recordFailure(_ error: Error) -> IOSCameraConnectionIssue {
    let issue: IOSCameraConnectionIssue
    if let connectionIssue = error as? IOSCameraConnectionIssue {
      issue = connectionIssue
    } else {
      issue = IOSCameraConnectionIssue(
        step: executionState.nextExpectedStep ?? .gallerySessionPrepared,
        reason: error.localizedDescription
      )
    }
    executionState.recordFailure(issue)
    return issue
  }

  var nextExpectedStep: IOSCameraConnectionStep? {
    executionState.nextExpectedStep
  }

  func confirmedSteps() -> [IOSCameraConnectionStep] {
    executionState.completedSteps
  }

  var currentPlan: CameraConnectionPlan {
    executionState.plan
  }

  var barrierEvents: [CameraConnectionBarrierLifecycleEvent] {
    executionState.barrierEvents
  }

  var firstMissingBarrier: IOSCameraConnectionStep? {
    executionState.firstMissingBarrier
  }

  @discardableResult
  func applyRevision(
    _ plan: CameraConnectionPlan,
    reason: CameraPlanRevisionReason
  ) throws -> CameraPlanRevisionSummary {
    try executionState.applyRevision(plan, reason: reason)
  }
}
