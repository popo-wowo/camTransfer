import Foundation

struct IOSCameraGalleryConnectionCoordinator {
  let runners: [IOSCameraConnectionStepRunner]

  init(runners: [IOSCameraConnectionStepRunner]) {
    self.runners = runners
  }

  func connect(context initialContext: IOSCameraConnectionContext) async throws -> IOSCameraConnectionContext {
    var context = initialContext
    for runner in runners {
      context = try await runner.run(context: context)
    }
    return context
  }
}

