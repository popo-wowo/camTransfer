import Foundation

final class IOSCameraGalleryConnectionCoordinator {
  let runners: [IOSCameraConnectionStepRunner]
  private let initialConfirmedSteps: [IOSCameraConnectionStep]
  private var completedSteps: [IOSCameraConnectionStep] = []

  init(
    initialConfirmedSteps: [IOSCameraConnectionStep] = [],
    runners: [IOSCameraConnectionStepRunner]
  ) {
    precondition(
      initialConfirmedSteps == Array(IOSCameraConnectionStep.officialGalleryOrder.prefix(initialConfirmedSteps.count)),
      "Initial iOS camera connection steps must be an official prefix"
    )
    self.initialConfirmedSteps = initialConfirmedSteps
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
      context = try await runner.run(context: context)
      completedSteps.append(runner.step)
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
