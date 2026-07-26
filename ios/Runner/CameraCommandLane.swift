import Foundation

enum CameraCommandPriority: Int, Sendable {
  case sessionMutation = -1
  case download = 0
  case hdPreview = 1
  case visibleThumbnail = 2
  case details = 3
  case keepAlive = 4
}

final class CameraCommandLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseHandler: (() -> Void)?

  init(releaseHandler: @escaping () -> Void) {
    self.releaseHandler = releaseHandler
  }

  func release() {
    let handler: (() -> Void)?
    lock.lock()
    handler = releaseHandler
    releaseHandler = nil
    lock.unlock()
    handler?()
  }

  deinit {
    release()
  }
}

final class CameraCommandLane {
  private final class WaiterToken {
    private let lock = NSLock()
    private var waiterID: Int?
    private var isCancelled = false

    func register(waiterID: Int) -> Bool {
      lock.lock()
      self.waiterID = waiterID
      let cancelled = isCancelled
      lock.unlock()
      return cancelled
    }

    func cancel() -> Int? {
      lock.lock()
      isCancelled = true
      let id = waiterID
      lock.unlock()
      return id
    }
  }

  private final class Waiter {
    let id: Int
    let priority: CameraCommandPriority
    let sequence: Int
    let continuation: CheckedContinuation<Void, Error>

    init(
      id: Int,
      priority: CameraCommandPriority,
      sequence: Int,
      continuation: CheckedContinuation<Void, Error>
    ) {
      self.id = id
      self.priority = priority
      self.sequence = sequence
      self.continuation = continuation
    }
  }

  private let lock = NSLock()
  private var isCommandActive = false
  private var waiters: [Waiter] = []
  private var nextSequence = 0
  private var nextWaiterID = 0
  private var isExclusiveDownloadBarrierActive = false
  private var isExclusiveSessionMutationBarrierActive = false
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private let onWaiterQueued: ((CameraCommandPriority) -> Void)?

  init(onWaiterQueued: ((CameraCommandPriority) -> Void)? = nil) {
    self.onWaiterQueued = onWaiterQueued
  }

  func run<T>(
    priority: CameraCommandPriority,
    _ operation: () throws -> T
  ) async throws -> T {
    try await acquire(priority: priority)
    if Task.isCancelled {
      releaseNext()
      throw CancellationError()
    }
    do {
      let value = try operation()
      releaseNext()
      return value
    } catch {
      releaseNext()
      throw error
    }
  }

  func runExclusiveSessionMutation<T>(_ operation: () throws -> T) async throws -> T {
    beginExclusiveSessionMutationBarrier()
    defer { endExclusiveSessionMutationBarrier() }
    return try await run(priority: .sessionMutation, operation)
  }

  func acquireExclusiveDownloadLease() async -> CameraCommandLease {
    beginExclusiveDownloadBarrier()
    await waitUntilIdle()
    return CameraCommandLease { [weak self] in
      self?.endExclusiveDownloadBarrier()
    }
  }

  func waitUntilIdle() async {
    await withCheckedContinuation { continuation in
      var shouldResumeImmediately = false
      lock.lock()
      if isIdleLocked {
        shouldResumeImmediately = true
      } else {
        idleWaiters.append(continuation)
      }
      lock.unlock()
      if shouldResumeImmediately {
        continuation.resume()
      }
    }
  }

  private func beginExclusiveDownloadBarrier() {
    let cancelledWaiters: [Waiter]
    let idleContinuations: [CheckedContinuation<Void, Never>]
    lock.lock()
    isExclusiveDownloadBarrierActive = true
    cancelledWaiters = waiters.filter { $0.priority != .download }
    waiters.removeAll { $0.priority != .download }
    idleContinuations = takeIdleWaitersIfReadyLocked()
    lock.unlock()
    for waiter in cancelledWaiters {
      waiter.continuation.resume(throwing: CancellationError())
    }
    idleContinuations.forEach { $0.resume() }
  }

  private func endExclusiveDownloadBarrier() {
    let next: Waiter?
    lock.lock()
    isExclusiveDownloadBarrierActive = false
    if !isCommandActive {
      next = removeNextRunnableWaiterLocked()
      if next != nil {
        isCommandActive = true
      }
    } else {
      next = nil
    }
    lock.unlock()
    next?.continuation.resume()
  }

  private func beginExclusiveSessionMutationBarrier() {
    lock.lock()
    isExclusiveSessionMutationBarrierActive = true
    lock.unlock()
  }

  private func endExclusiveSessionMutationBarrier() {
    let next: Waiter?
    lock.lock()
    isExclusiveSessionMutationBarrierActive = false
    if !isCommandActive {
      next = removeNextRunnableWaiterLocked()
      if next != nil {
        isCommandActive = true
      }
    } else {
      next = nil
    }
    lock.unlock()
    next?.continuation.resume()
  }

  private func acquire(priority: CameraCommandPriority) async throws {
    if Task.isCancelled {
      throw CancellationError()
    }
    let token = WaiterToken()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var shouldAcquireImmediately = false
        var shouldResumeCancelled = false
        var queuedPriority: CameraCommandPriority?
        lock.lock()
        if Task.isCancelled {
          shouldResumeCancelled = true
        } else if isExclusiveDownloadBarrierActive && priority != .download {
          shouldResumeCancelled = true
        } else if !isCommandActive
          && canRunImmediatelyLocked(priority: priority)
          && (waiters.isEmpty || isExclusiveDownloadBarrierActive) {
          isCommandActive = true
          shouldAcquireImmediately = true
        } else {
          let waiterID = nextWaiterID
          nextWaiterID += 1
          waiters.append(
            Waiter(
              id: waiterID,
              priority: priority,
              sequence: nextSequence,
              continuation: continuation
            )
          )
          nextSequence += 1
          queuedPriority = priority
          if token.register(waiterID: waiterID) {
            waiters.removeAll { $0.id == waiterID }
            shouldResumeCancelled = true
            queuedPriority = nil
          }
        }
        lock.unlock()

        if let queuedPriority {
          onWaiterQueued?(queuedPriority)
        }
        if shouldAcquireImmediately {
          continuation.resume()
        } else if shouldResumeCancelled {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: { [weak self] in
      guard let waiterID = token.cancel() else { return }
      self?.cancelWaiter(id: waiterID)
    }
  }

  private func releaseNext() {
    let next: Waiter?
    let idleContinuations: [CheckedContinuation<Void, Never>]
    lock.lock()
    if let runnable = removeNextRunnableWaiterLocked() {
      next = runnable
      idleContinuations = []
    } else {
      isCommandActive = false
      next = nil
      idleContinuations = takeIdleWaitersIfReadyLocked()
    }
    lock.unlock()
    next?.continuation.resume()
    idleContinuations.forEach { $0.resume() }
  }

  private var isIdleLocked: Bool {
    !isCommandActive && waiters.isEmpty
  }

  private func takeIdleWaitersIfReadyLocked() -> [CheckedContinuation<Void, Never>] {
    guard isIdleLocked else { return [] }
    let continuations = idleWaiters
    idleWaiters.removeAll(keepingCapacity: false)
    return continuations
  }

  private func canRunImmediatelyLocked(priority: CameraCommandPriority) -> Bool {
    if isExclusiveSessionMutationBarrierActive {
      return priority == .sessionMutation
    }
    return !isExclusiveDownloadBarrierActive || priority == .download
  }

  private func removeNextRunnableWaiterLocked() -> Waiter? {
    let runnableIndices = waiters.indices.filter {
      canRunImmediatelyLocked(priority: waiters[$0].priority)
    }
    guard let index = runnableIndices.min(by: { left, right in
      let leftWaiter = waiters[left]
      let rightWaiter = waiters[right]
      if leftWaiter.priority.rawValue != rightWaiter.priority.rawValue {
        return leftWaiter.priority.rawValue < rightWaiter.priority.rawValue
      }
      return leftWaiter.sequence < rightWaiter.sequence
    }) else {
      return nil
    }
    return waiters.remove(at: index)
  }

  private func cancelWaiter(id: Int) {
    let continuation: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = waiters.firstIndex(where: { $0.id == id }) {
      continuation = waiters.remove(at: index).continuation
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}
