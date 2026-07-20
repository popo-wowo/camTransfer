import Foundation

final class IOSCameraGalleryConnectionCoordinator {
  let runners: [IOSCameraConnectionStepRunner]
  private let initialConfirmedSteps: [IOSCameraConnectionStep]
  private let stateMachine: IOSCameraConnectionStateMachine
  private let onStepStarted: ((IOSCameraConnectionStep) -> Void)?
  private var completedSteps: [IOSCameraConnectionStep] = []

  init(
    initialConfirmedSteps: [IOSCameraConnectionStep] = [],
    stateMachine: IOSCameraConnectionStateMachine = IOSCameraConnectionStateMachine(),
    onStepStarted: ((IOSCameraConnectionStep) -> Void)? = nil,
    runners: [IOSCameraConnectionStepRunner]
  ) {
    precondition(
      initialConfirmedSteps == Array(IOSCameraConnectionStep.officialGalleryOrder.prefix(initialConfirmedSteps.count)),
      "Initial iOS camera connection steps must be an official prefix"
    )
    self.initialConfirmedSteps = initialConfirmedSteps
    self.stateMachine = stateMachine
    self.onStepStarted = onStepStarted
    self.runners = runners
  }

  func connect(context initialContext: IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext {
    completedSteps = initialConfirmedSteps
    var context = initialContext
    for runner in runners {
      guard let expectedStep = IOSCameraConnectionStep.officialGalleryOrder[safe: completedSteps.count],
            runner.step == expectedStep else {
        let expectedStep = IOSCameraConnectionStep.officialGalleryOrder[safe: completedSteps.count]
          ?? IOSCameraConnectionStep.officialGalleryOrder.last!
        throw IOSCameraConnectionIssue(
          step: expectedStep,
          reason: "Cannot run \(runner.step.androidDisplayName) before \(expectedStep.androidDisplayName)"
        )
      }
      if let onStepStarted {
        onStepStarted(runner.step)
      }
      let execution = try await runner.run(context: context)
      let nextStep = try stateMachine.advance(from: runner.step, with: execution.evidence)
      completedSteps.append(runner.step)
      if let expectedNextStep = IOSCameraConnectionStep.officialGalleryOrder[safe: completedSteps.count],
         nextStep != expectedNextStep {
        throw IOSCameraConnectionIssue(
          step: runner.step,
          reason: "Evidence advanced to \(nextStep?.androidDisplayName ?? "Complete") instead of \(expectedNextStep.androidDisplayName)"
        )
      }
      context = execution.context
    }
    return context
  }

  func confirmedSteps() -> [IOSCameraConnectionStep] {
    completedSteps
  }
}

private extension Array {
  subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
