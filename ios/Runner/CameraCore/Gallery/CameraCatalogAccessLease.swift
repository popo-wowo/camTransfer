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
    let owner: CameraCatalogAccessOwner
    let continuation: CheckedContinuation<CameraCatalogAccessLease, Never>
  }

  private var activeOwner: CameraCatalogAccessOwner?
  private var waiters: [Waiter] = []

  func acquire(owner: CameraCatalogAccessOwner) async -> CameraCatalogAccessLease {
    guard activeOwner != nil else {
      activeOwner = owner
      return makeLease(for: owner)
    }
    return await withCheckedContinuation { continuation in
      waiters.append(Waiter(owner: owner, continuation: continuation))
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
}
