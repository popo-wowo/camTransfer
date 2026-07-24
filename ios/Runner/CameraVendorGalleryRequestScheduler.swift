import Foundation

enum CameraVendorGalleryRequestPriority: Int {
  case mutation = -1
  case downloadOriginal = 0
  case previewImage = 1
  case visibleThumbnail = 2
  case previewNeighborThumbnail = 3
  case backgroundMetadata = 4
}

final class CameraVendorGalleryRequestScheduler {
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
    let priority: CameraVendorGalleryRequestPriority
    let sequence: Int
    let continuation: CheckedContinuation<Void, Error>

    init(
      id: Int,
      priority: CameraVendorGalleryRequestPriority,
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
  private var isCameraReadActive = false
  private var waiters: [Waiter] = []
  private var nextSequence = 0
  private var nextWaiterID = 0
  private var isPriorityDownloadBarrierActive = false
  private var isExclusiveMutationBarrierActive = false
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private let onWaiterQueued: ((CameraVendorGalleryRequestPriority) -> Void)?

  init(onWaiterQueued: ((CameraVendorGalleryRequestPriority) -> Void)? = nil) {
    self.onWaiterQueued = onWaiterQueued
  }

  func run<T>(
    priority: CameraVendorGalleryRequestPriority,
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

  func runExclusiveMutation<T>(_ operation: () throws -> T) async throws -> T {
    beginExclusiveMutationBarrier()
    defer { endExclusiveMutationBarrier() }
    try await acquire(priority: .mutation)
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

  func beginPriorityDownloadBarrier() {
    let cancelledWaiters: [Waiter]
    let idleContinuations: [CheckedContinuation<Void, Never>]
    lock.lock()
    isPriorityDownloadBarrierActive = true
    cancelledWaiters = waiters.filter { $0.priority != .downloadOriginal }
    waiters.removeAll { $0.priority != .downloadOriginal }
    idleContinuations = takeIdleWaitersIfReadyLocked()
    lock.unlock()
    for waiter in cancelledWaiters {
      waiter.continuation.resume(throwing: CancellationError())
    }
    idleContinuations.forEach { $0.resume() }
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

  func endPriorityDownloadBarrier() {
    let next: Waiter?
    lock.lock()
    isPriorityDownloadBarrierActive = false
    if !isCameraReadActive {
      next = removeNextRunnableWaiterLocked()
      if next != nil {
        isCameraReadActive = true
      }
    } else {
      next = nil
    }
    lock.unlock()
    next?.continuation.resume()
  }

  private func beginExclusiveMutationBarrier() {
    lock.lock()
    isExclusiveMutationBarrierActive = true
    lock.unlock()
  }

  private func endExclusiveMutationBarrier() {
    let next: Waiter?
    lock.lock()
    isExclusiveMutationBarrierActive = false
    if !isCameraReadActive {
      next = removeNextRunnableWaiterLocked()
      if next != nil {
        isCameraReadActive = true
      }
    } else {
      next = nil
    }
    lock.unlock()
    next?.continuation.resume()
  }

  private func acquire(priority: CameraVendorGalleryRequestPriority) async throws {
    if Task.isCancelled {
      throw CancellationError()
    }
    let token = WaiterToken()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var shouldAcquireImmediately = false
        var shouldResumeCancelled = false
        var queuedPriority: CameraVendorGalleryRequestPriority?
        lock.lock()
        if Task.isCancelled {
          shouldResumeCancelled = true
        } else if isPriorityDownloadBarrierActive && priority != .downloadOriginal {
          shouldResumeCancelled = true
        } else if !isCameraReadActive
          && canRunImmediatelyLocked(priority: priority)
          && (waiters.isEmpty || isPriorityDownloadBarrierActive) {
          isCameraReadActive = true
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
      isCameraReadActive = false
      next = nil
      idleContinuations = takeIdleWaitersIfReadyLocked()
    }
    lock.unlock()
    next?.continuation.resume()
    idleContinuations.forEach { $0.resume() }
  }

  private var isIdleLocked: Bool {
    !isCameraReadActive && waiters.isEmpty
  }

  private func takeIdleWaitersIfReadyLocked() -> [CheckedContinuation<Void, Never>] {
    guard isIdleLocked else { return [] }
    let continuations = idleWaiters
    idleWaiters.removeAll(keepingCapacity: false)
    return continuations
  }

  private func canRunImmediatelyLocked(priority: CameraVendorGalleryRequestPriority) -> Bool {
    if isExclusiveMutationBarrierActive {
      return priority == .mutation
    }
    return !isPriorityDownloadBarrierActive || priority == .downloadOriginal
  }

  private func removeNextRunnableWaiterLocked() -> Waiter? {
    let runnableIndices = waiters.indices.filter { canRunImmediatelyLocked(priority: waiters[$0].priority) }
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
