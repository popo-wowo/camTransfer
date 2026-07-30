import Foundation

enum CameraCatalogAccessOwner: Equatable, Hashable, Sendable {
  case gallery(UUID)
  case quickDownload(UUID)
}

actor CameraCatalogAccessLease {
  let owner: CameraCatalogAccessOwner

  private let releaseAction: @Sendable () async -> Void
  private var didRelease = false

  init(
    owner: CameraCatalogAccessOwner,
    releaseAction: @escaping @Sendable () async -> Void
  ) {
    self.owner = owner
    self.releaseAction = releaseAction
  }

  func release() async {
    guard !didRelease else { return }
    didRelease = true
    await releaseAction()
  }
}

actor CameraCatalogAccessGate {
  private struct Waiter {
    let id: UUID
    let owner: CameraCatalogAccessOwner
    let continuation: CheckedContinuation<CameraCatalogAccessLease, Error>
  }

  private var activeOwner: CameraCatalogAccessOwner?
  private var waiters: [Waiter] = []

  func acquire(owner: CameraCatalogAccessOwner) async throws -> CameraCatalogAccessLease {
    try Task.checkCancellation()
    guard activeOwner != nil else {
      activeOwner = owner
      return makeLease(for: owner)
    }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        waiters.append(Waiter(id: waiterID, owner: owner, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: waiterID) }
    }
  }

  private func makeLease(for owner: CameraCatalogAccessOwner) -> CameraCatalogAccessLease {
    CameraCatalogAccessLease(owner: owner) { [weak self] in
      await self?.release(owner: owner)
    }
  }

  private func release(owner: CameraCatalogAccessOwner) {
    guard activeOwner == owner else { return }
    guard !waiters.isEmpty else {
      activeOwner = nil
      return
    }
    let waiter = waiters.removeFirst()
    activeOwner = waiter.owner
    waiter.continuation.resume(returning: makeLease(for: waiter.owner))
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}
