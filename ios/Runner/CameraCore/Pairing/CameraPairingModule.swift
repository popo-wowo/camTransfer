import Foundation

struct IOSCameraPairingResult: Equatable {
  let record: IOSCameraPairingRecord
}

struct IOSCameraPairingModule {
  private let pairBlock: () async throws -> IOSCameraPairingResult

  init(pair: @escaping () async throws -> IOSCameraPairingResult) {
    self.pairBlock = pair
  }

  func pair() async throws -> IOSCameraPairingResult {
    try await pairBlock()
  }
}

