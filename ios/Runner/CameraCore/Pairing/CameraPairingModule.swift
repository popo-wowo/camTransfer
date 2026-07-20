import Foundation

enum IOSCameraPairingModuleError: Error {
  case confirmNotConfigured
}

struct IOSCameraPairingResult: Equatable {
  let record: IOSCameraPairingRecord
}

struct IOSCameraPairingModule {
  private let startBlock: () async throws -> Void
  private let confirmBlock: () async throws -> IOSCameraPairingResult

  init(
    start: @escaping () async throws -> Void,
    confirm: @escaping () async throws -> IOSCameraPairingResult = {
      throw IOSCameraPairingModuleError.confirmNotConfigured
    }
  ) {
    self.startBlock = start
    self.confirmBlock = confirm
  }

  func startPairing() async throws {
    try await startBlock()
  }

  func confirmPairing() async throws -> IOSCameraPairingResult {
    try await confirmBlock()
  }
}
