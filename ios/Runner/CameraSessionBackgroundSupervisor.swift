import Foundation
import UIKit

@MainActor
final class CameraSessionRuntimeLifecycleAdapter {
  private let center: NotificationCenter
  private weak var runtime: CameraSessionRuntimeCommandHandling?
  private var observerTokens: [NSObjectProtocol] = []

  init(center: NotificationCenter = .default, runtime: CameraSessionRuntimeCommandHandling) {
    self.center = center
    self.runtime = runtime
    observerTokens = [
      center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.runtime?.send(.applicationWillResignActive)
        }
      },
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.runtime?.send(.applicationEnteredBackground)
        }
      },
      center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.runtime?.send(.applicationBecameActive)
        }
      },
    ]
  }

  func invalidate() {
    observerTokens.forEach(center.removeObserver)
    observerTokens = []
  }
}
@MainActor
protocol CameraSessionRuntimeBackgroundMaintaining: AnyObject {
  func start(allowingPtpKeepAlive: Bool)
  func stop(reason: String)
}

/// A runtime-owned background mechanism may keep the process executing after a
/// short UIKit background task has ended.  This must report `true` only after
/// the underlying iOS capability is actually running; BLE timers alone never
/// qualify.
@MainActor
protocol CameraSessionRuntimeBackgroundExecutionSustaining: AnyObject {
  var isSustainingBackgroundExecution: Bool { get }
}

@MainActor
protocol CameraSessionRuntimeBackgroundExecutionPreparing: AnyObject {
  func prepareBackgroundExecution()
}

protocol CameraVendorBackgroundActivityObserving: AnyObject {
  func setBackgroundActivityObserver(_ observer: (() -> Void)?)
}

@MainActor
final class CameraSessionRuntimeBackgroundActivityLease {
  private var isBackgroundEpochActive = false
  private var didObserveHardwareActivity = false

  var hasObservedHardwareActivity: Bool {
    isBackgroundEpochActive && didObserveHardwareActivity
  }

  func beginBackgroundEpoch() {
    isBackgroundEpochActive = true
    didObserveHardwareActivity = false
  }

  @discardableResult
  func recordHardwareCallback() -> Bool {
    guard isBackgroundEpochActive, !didObserveHardwareActivity else { return false }
    didObserveHardwareActivity = true
    return true
  }

  func endBackgroundEpoch() {
    isBackgroundEpochActive = false
    didObserveHardwareActivity = false
  }
}
@MainActor
final class CameraSessionRuntimeDeferredBackgroundMaintainer: CameraSessionRuntimeBackgroundMaintaining, CameraSessionRuntimeBackgroundExecutionSustaining, CameraSessionRuntimeBackgroundExecutionPreparing {
  private var maintainer: CameraSessionRuntimeBackgroundMaintaining?
  private var desiredPtpKeepAlive: Bool?
  private var shouldPrepareBackgroundExecution = false
  private var binding: CameraSessionRuntimeBinding?

  func attach(_ maintainer: CameraSessionRuntimeBackgroundMaintaining) {
    attach(maintainer, binding: nil)
  }

  func attach(
    _ maintainer: CameraSessionRuntimeBackgroundMaintaining,
    binding: CameraSessionRuntimeBinding?
  ) {
    if self.binding != binding, self.maintainer != nil {
      self.maintainer?.stop(reason: "runtime-session-superseded")
    }
    self.maintainer = maintainer
    self.binding = binding
    if let desiredPtpKeepAlive {
      maintainer.start(allowingPtpKeepAlive: desiredPtpKeepAlive)
    }
    if shouldPrepareBackgroundExecution {
      (maintainer as? CameraSessionRuntimeBackgroundExecutionPreparing)?
        .prepareBackgroundExecution()
    }
  }

  func start(allowingPtpKeepAlive: Bool) {
    desiredPtpKeepAlive = allowingPtpKeepAlive
    maintainer?.start(allowingPtpKeepAlive: allowingPtpKeepAlive)
  }

  func stop(reason: String) {
    desiredPtpKeepAlive = nil
    maintainer?.stop(reason: reason)
  }

  var isSustainingBackgroundExecution: Bool {
    (maintainer as? CameraSessionRuntimeBackgroundExecutionSustaining)?
      .isSustainingBackgroundExecution ?? false
  }

  func prepareBackgroundExecution() {
    shouldPrepareBackgroundExecution = true
    (maintainer as? CameraSessionRuntimeBackgroundExecutionPreparing)?
      .prepareBackgroundExecution()
  }

}

@MainActor
final class CameraVendorSessionRuntimeBackgroundMaintainer: CameraSessionRuntimeBackgroundMaintaining, CameraSessionRuntimeBackgroundExecutionSustaining, CameraSessionRuntimeBackgroundExecutionPreparing {
  private let galleryKeepAlive: CameraVendorGalleryBackgroundKeepAlive?
  private let bluetoothKeepAlive: CameraVendorBleBackgroundKeepAlive
  private let backgroundActivityLease = CameraSessionRuntimeBackgroundActivityLease()
  private var ptpKeepAliveTask: Task<Void, Never>?
  private var bleKeepAliveTask: Task<Void, Never>?

  init(
    galleryService: CameraVendorGalleryService,
    bluetoothKeepAlive: CameraVendorBleBackgroundKeepAlive,
    backgroundActivitySource: CameraVendorBackgroundActivityObserving?
  ) {
    self.galleryKeepAlive = galleryService as? CameraVendorGalleryBackgroundKeepAlive
    self.bluetoothKeepAlive = bluetoothKeepAlive
    backgroundActivitySource?.setBackgroundActivityObserver { [weak backgroundActivityLease] in
      guard backgroundActivityLease?.recordHardwareCallback() == true else { return }
      CameraVendorFileLogger.log(
        "[RUNTIME_BACKGROUND_BLE] activity-observed epoch=current source=corebluetooth-callback"
      )
    }
  }

  func start(allowingPtpKeepAlive: Bool) {
    backgroundActivityLease.beginBackgroundEpoch()
    startBleKeepAliveLoopIfNeeded()
    if allowingPtpKeepAlive {
      startPtpKeepAliveLoopIfNeeded()
    } else {
      ptpKeepAliveTask?.cancel()
      ptpKeepAliveTask = nil
    }
  }

  func stop(reason: String) {
    ptpKeepAliveTask?.cancel()
    ptpKeepAliveTask = nil
    bleKeepAliveTask?.cancel()
    bleKeepAliveTask = nil
    backgroundActivityLease.endBackgroundEpoch()
  }

  var isSustainingBackgroundExecution: Bool {
    backgroundActivityLease.hasObservedHardwareActivity
  }

  func prepareBackgroundExecution() {
    CameraVendorFileLogger.log("[RUNTIME_BACKGROUND_BLE] prepared reason=gallery-session-ready")
  }

  private func startBleKeepAliveLoopIfNeeded() {
    guard bleKeepAliveTask == nil else { return }
    bleKeepAliveTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.bluetoothKeepAlive.performBackgroundBleKeepAlive(reason: "runtime-background")
        do {
          try await Task.sleep(
            nanoseconds: UInt64(CameraVendorBleBackgroundKeepAlivePolicy.intervalSeconds * 1_000_000_000)
          )
        } catch {
          return
        }
      }
    }
  }

  private func startPtpKeepAliveLoopIfNeeded() {
    guard ptpKeepAliveTask == nil, let galleryKeepAlive else { return }
    ptpKeepAliveTask = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await Task.sleep(
            nanoseconds: UInt64(CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveIntervalSeconds * 1_000_000_000)
          )
          try Task.checkCancellation()
          try await galleryKeepAlive.performBackgroundKeepAlive()
        } catch {
          return
        }
      }
    }
  }
}

@MainActor
protocol CameraSessionRuntimeExecutionAuthorizing: AnyObject {
  func acquire(reason: String) -> Bool
  func release(reason: String)
}

@MainActor
final class CameraSessionBackgroundExecutionLease {
  private var activeLeaseID: UUID?

  func acquire() -> UUID {
    let leaseID = UUID()
    activeLeaseID = leaseID
    CameraVendorFileLogger.log("[RUNTIME_BACKGROUND_LEASE] event=acquired lease=\(leaseID.uuidString)")
    return leaseID
  }

  func release() {
    guard let activeLeaseID else { return }
    self.activeLeaseID = nil
    CameraVendorFileLogger.log("[RUNTIME_BACKGROUND_LEASE] event=released lease=\(activeLeaseID.uuidString)")
  }

  func consumeExpiry(for leaseID: UUID) -> Bool {
    guard activeLeaseID == leaseID else {
      CameraVendorFileLogger.log("[RUNTIME_BACKGROUND_LEASE] event=expiry-ignored lease=\(leaseID.uuidString)")
      return false
    }
    activeLeaseID = nil
    CameraVendorFileLogger.log("[RUNTIME_BACKGROUND_LEASE] event=expiry-accepted lease=\(leaseID.uuidString)")
    return true
  }
}

@MainActor
final class CameraSessionUIKitExecutionAuthority: CameraSessionRuntimeExecutionAuthorizing {
  private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
  private let executionLease = CameraSessionBackgroundExecutionLease()
  var onExpired: (() -> Void)?

  func acquire(reason: String) -> Bool {
    guard backgroundTaskID == .invalid else { return true }
    let leaseID = executionLease.acquire()
    backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "CameraSessionRuntime-\(reason)") { [weak self] in
      DispatchQueue.main.async {
        self?.expire(leaseID: leaseID)
      }
    }
    guard backgroundTaskID != .invalid else {
      executionLease.release()
      return false
    }
    return true
  }

  func release(reason _: String) {
    guard backgroundTaskID != .invalid else { return }
    let taskID = backgroundTaskID
    backgroundTaskID = .invalid
    executionLease.release()
    UIApplication.shared.endBackgroundTask(taskID)
  }

  private func expire(leaseID: UUID) {
    guard executionLease.consumeExpiry(for: leaseID), backgroundTaskID != .invalid else { return }
    release(reason: "expired")
    onExpired?()
  }
}
