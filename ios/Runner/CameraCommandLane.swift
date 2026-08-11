import Foundation

enum CameraCommandPriority: Int, Sendable {
  case sessionMutation = -1
  case download = 0
  case hdPreview = 1
  case visibleThumbnail = 2
  case details = 3
  case keepAlive = 4
}

enum CameraCommandLaneError: Error {
  case waitTimeout
  case terminated
}

final class CameraCommandLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseHandler: (((() -> Void)?) -> Void)?

  init(releaseHandler: @escaping ((() -> Void)?) -> Void) {
    self.releaseHandler = releaseHandler
  }

  func release(afterSerialized finalizer: (() -> Void)? = nil) {
    let handler: (((() -> Void)?) -> Void)?
    lock.lock()
    handler = releaseHandler
    releaseHandler = nil
    lock.unlock()
    handler?(finalizer)
  }

  deinit {
    release()
  }
}

final class CameraCommandLane {
  let identity = UUID()
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

  private final class IdleWaiter {
    let id: Int
    let continuation: CheckedContinuation<Void, Error>

    init(id: Int, continuation: CheckedContinuation<Void, Error>) {
      self.id = id
      self.continuation = continuation
    }
  }

  private let lock = NSLock()
  private var isCommandActive = false
  private var waiters: [Waiter] = []
  private var nextSequence = 0
  private var nextWaiterID = 0
  private var exclusiveDownloadLeaseIDs = Set<Int>()
  private var nextExclusiveDownloadLeaseID = 0
  private var isExclusiveSessionMutationBarrierActive = false
  private var serializedFinalizers: [() -> Void] = []
  private var idleWaiters: [IdleWaiter] = []
  private var nextIdleWaiterID = 0
  private var terminated = false
  private var terminationFinalizer: (() -> Void)?
  private let onWaiterQueued: ((CameraCommandPriority) -> Void)?
  private let waitTimeout: TimeInterval?

  init(
    waitTimeout: TimeInterval? = nil,
    onWaiterQueued: ((CameraCommandPriority) -> Void)? = nil
  ) {
    self.waitTimeout = waitTimeout
    self.onWaiterQueued = onWaiterQueued
  }

  var isTerminated: Bool {
    lock.withLock { terminated }
  }

  @discardableResult
  func terminate() -> Bool {
    terminateAfterDrainingActiveOperation {}
  }

  @discardableResult
  func terminateAfterDrainingActiveOperation(
    _ finalizer: @escaping () -> Void
  ) -> Bool {
    let commandWaiters: [Waiter]
    let idleWaitersToCancel: [IdleWaiter]
    let finalizerToRun: (() -> Void)?
    lock.lock()
    guard !terminated else {
      lock.unlock()
      return false
    }
    terminated = true
    commandWaiters = waiters
    idleWaitersToCancel = idleWaiters
    waiters.removeAll(keepingCapacity: false)
    idleWaiters.removeAll(keepingCapacity: false)
    exclusiveDownloadLeaseIDs.removeAll(keepingCapacity: false)
    isExclusiveSessionMutationBarrierActive = false
    if isCommandActive {
      terminationFinalizer = finalizer
      finalizerToRun = nil
    } else if let serializedFinalizer = takeNextSerializedFinalizerLocked() {
      isCommandActive = true
      terminationFinalizer = finalizer
      finalizerToRun = serializedFinalizer
    } else {
      finalizerToRun = finalizer
    }
    lock.unlock()
    commandWaiters.forEach { $0.continuation.resume(throwing: CameraCommandLaneError.terminated) }
    idleWaitersToCancel.forEach {
      $0.continuation.resume(throwing: CameraCommandLaneError.terminated)
    }
    if let finalizerToRun {
      finalizerToRun()
      releaseNext()
    }
    return true
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

  func acquireExclusiveDownloadLease() async throws -> CameraCommandLease {
    try Task.checkCancellation()
    let leaseID = try beginExclusiveDownloadBarrier()
    do {
      try await waitUntilIdle()
      try Task.checkCancellation()
      return CameraCommandLease { [weak self] finalizer in
        self?.endExclusiveDownloadBarrier(leaseID: leaseID, finalizer: finalizer)
      }
    } catch {
      endExclusiveDownloadBarrier(leaseID: leaseID)
      throw error
    }
  }

  func waitUntilIdle() async throws {
    try Task.checkCancellation()
    let token = WaiterToken()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var shouldResumeImmediately = false
        var resumeError: Error?
        lock.lock()
        if terminated {
          resumeError = CameraCommandLaneError.terminated
        } else if Task.isCancelled {
          resumeError = CancellationError()
        } else if isIdleLocked {
          shouldResumeImmediately = true
        } else {
          let waiterID = nextIdleWaiterID
          nextIdleWaiterID += 1
          idleWaiters.append(IdleWaiter(id: waiterID, continuation: continuation))
          if token.register(waiterID: waiterID) {
            idleWaiters.removeAll { $0.id == waiterID }
            resumeError = CancellationError()
          }
        }
        lock.unlock()
        if shouldResumeImmediately {
          continuation.resume()
        } else if let resumeError {
          continuation.resume(throwing: resumeError)
        }
      }
    } onCancel: { [weak self] in
      guard let waiterID = token.cancel() else { return }
      self?.cancelIdleWaiter(id: waiterID)
    }
    try Task.checkCancellation()
  }

  private func beginExclusiveDownloadBarrier() throws -> Int {
    let cancelledWaiters: [Waiter]
    let idleWaitersToResume: [IdleWaiter]
    lock.lock()
    guard !terminated else {
      lock.unlock()
      throw CameraCommandLaneError.terminated
    }
    let leaseID = nextExclusiveDownloadLeaseID
    nextExclusiveDownloadLeaseID += 1
    exclusiveDownloadLeaseIDs.insert(leaseID)
    cancelledWaiters = waiters.filter {
      !canRunDuringExclusiveDownloadBarrier(priority: $0.priority)
    }
    waiters.removeAll {
      !canRunDuringExclusiveDownloadBarrier(priority: $0.priority)
    }
    idleWaitersToResume = takeIdleWaitersIfReadyLocked()
    lock.unlock()
    for waiter in cancelledWaiters {
      waiter.continuation.resume(throwing: CancellationError())
    }
    idleWaitersToResume.forEach { $0.continuation.resume() }
    return leaseID
  }

  private func endExclusiveDownloadBarrier(
    leaseID: Int,
    finalizer: (() -> Void)? = nil
  ) {
    let next: Waiter?
    let finalizerToRun: (() -> Void)?
    lock.lock()
    guard exclusiveDownloadLeaseIDs.remove(leaseID) != nil else {
      lock.unlock()
      return
    }
    if let finalizer {
      serializedFinalizers.append(finalizer)
    }
    if !isCommandActive {
      finalizerToRun = takeNextSerializedFinalizerLocked()
      if finalizerToRun != nil {
        isCommandActive = true
        next = nil
      } else {
        next = removeNextRunnableWaiterLocked()
        if next != nil {
          isCommandActive = true
        }
      }
    } else {
      next = nil
      finalizerToRun = nil
    }
    lock.unlock()
    if let finalizerToRun {
      finalizerToRun()
      releaseNext()
    } else {
      next?.continuation.resume()
    }
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
        var resumeError: Error?
        var queuedPriority: CameraCommandPriority?
        var registeredWaiterID: Int?
        lock.lock()
        if terminated {
          resumeError = CameraCommandLaneError.terminated
        } else if Task.isCancelled {
          resumeError = CancellationError()
        } else if isExclusiveDownloadBarrierActive
          && !canRunDuringExclusiveDownloadBarrier(priority: priority) {
          resumeError = CancellationError()
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
          registeredWaiterID = waiterID
          if token.register(waiterID: waiterID) {
            waiters.removeAll { $0.id == waiterID }
            resumeError = CancellationError()
            queuedPriority = nil
            registeredWaiterID = nil
          }
        }
        lock.unlock()

        if let queuedPriority {
          onWaiterQueued?(queuedPriority)
        }
        if shouldAcquireImmediately {
          continuation.resume()
        } else if let resumeError {
          continuation.resume(throwing: resumeError)
        } else if let waiterID = registeredWaiterID, let timeout = waitTimeout {
          scheduleWaitTimeout(waiterID: waiterID, timeout: timeout)
        }
      }
    } onCancel: { [weak self] in
      guard let waiterID = token.cancel() else { return }
      self?.cancelWaiter(id: waiterID)
    }
  }

  private func releaseNext() {
    let next: Waiter?
    let finalizerToRun: (() -> Void)?
    let idleWaitersToResume: [IdleWaiter]
    lock.lock()
    if terminated {
      if let serializedFinalizer = takeNextSerializedFinalizerLocked() {
        isCommandActive = true
        finalizerToRun = serializedFinalizer
      } else {
        isCommandActive = false
        finalizerToRun = terminationFinalizer
        terminationFinalizer = nil
      }
      next = nil
      idleWaitersToResume = []
    } else if let finalizer = takeNextSerializedFinalizerLocked() {
      finalizerToRun = finalizer
      next = nil
      idleWaitersToResume = []
    } else if let runnable = removeNextRunnableWaiterLocked() {
      finalizerToRun = nil
      next = runnable
      idleWaitersToResume = []
    } else {
      finalizerToRun = nil
      isCommandActive = false
      next = nil
      idleWaitersToResume = takeIdleWaitersIfReadyLocked()
    }
    lock.unlock()
    if let finalizerToRun {
      finalizerToRun()
      releaseNext()
    } else {
      next?.continuation.resume()
      idleWaitersToResume.forEach { $0.continuation.resume() }
    }
  }

  private var isIdleLocked: Bool {
    !isCommandActive && waiters.isEmpty && serializedFinalizers.isEmpty
  }

  private func takeNextSerializedFinalizerLocked() -> (() -> Void)? {
    guard !serializedFinalizers.isEmpty else { return nil }
    return serializedFinalizers.removeFirst()
  }

  private func takeIdleWaitersIfReadyLocked() -> [IdleWaiter] {
    guard isIdleLocked else { return [] }
    let waiters = idleWaiters
    idleWaiters.removeAll(keepingCapacity: false)
    return waiters
  }

  private var isExclusiveDownloadBarrierActive: Bool {
    !exclusiveDownloadLeaseIDs.isEmpty
  }

  private func canRunImmediatelyLocked(priority: CameraCommandPriority) -> Bool {
    if isExclusiveSessionMutationBarrierActive {
      return priority == .sessionMutation
    }
    return !isExclusiveDownloadBarrierActive
      || canRunDuringExclusiveDownloadBarrier(priority: priority)
  }

  private func canRunDuringExclusiveDownloadBarrier(priority: CameraCommandPriority) -> Bool {
    priority == .sessionMutation || priority == .download
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

  private func scheduleWaitTimeout(waiterID: Int, timeout: TimeInterval) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.expireWaiter(id: waiterID)
    }
  }

  private func expireWaiter(id: Int) {
    let continuation: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = waiters.firstIndex(where: { $0.id == id }) {
      continuation = waiters.remove(at: index).continuation
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(throwing: CameraCommandLaneError.waitTimeout)
  }

  private func cancelIdleWaiter(id: Int) {
    let continuation: CheckedContinuation<Void, Error>?
    lock.lock()
    if let index = idleWaiters.firstIndex(where: { $0.id == id }) {
      continuation = idleWaiters.remove(at: index).continuation
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(throwing: CancellationError())
  }
}
