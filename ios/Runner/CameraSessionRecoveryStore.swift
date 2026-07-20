import Foundation

enum CameraSessionRuntimeRecoveryStoreError: Error {
  case missingPeripheralIdentity
}
@MainActor
protocol CameraSessionRuntimeLegacyResumeMigrating: AnyObject {
  func discardLegacyRememberedGalleryResume()
}

@MainActor
final class CameraSessionRuntimeLegacyResumeMigrator: CameraSessionRuntimeLegacyResumeMigrating {
  private let store: CameraGalleryResumeStore

  init(store: CameraGalleryResumeStore = .shared) {
    self.store = store
  }

  func discardLegacyRememberedGalleryResume() {
    store.clearPendingRememberedGalleryResume()
    store.clearPendingRememberedCameraSession()
  }
}
@MainActor
protocol CameraSessionRuntimeRecoveryConnecting: AnyObject {
  func requestRecoveredConnection(
    identity: CameraSessionIdentity,
    completion: @escaping (Bool) -> Void
  )
}

@MainActor
protocol CameraSessionRuntimeRecoveryCancelling: AnyObject {
  func cancelRecoveryConnection(reason: String)
}

@MainActor
final class CameraSessionRuntimeDeferredRecoveryConnector: CameraSessionRuntimeRecoveryConnecting, CameraSessionRuntimeRecoveryCancelling {
  private var handler: ((CameraSessionIdentity, @escaping (Bool) -> Void) -> Void)?
  private var cancellationHandler: ((String) -> Void)?
  private var activeRequestID: UUID?

  func attach(
    _ handler: @escaping (CameraSessionIdentity, @escaping (Bool) -> Void) -> Void,
    cancellationHandler: @escaping (String) -> Void
  ) {
    self.handler = handler
    self.cancellationHandler = cancellationHandler
  }

  func requestRecoveredConnection(
    identity: CameraSessionIdentity,
    completion: @escaping (Bool) -> Void
  ) {
    guard activeRequestID == nil, let handler else {
      completion(false)
      return
    }
    let requestID = UUID()
    activeRequestID = requestID
    handler(identity) { [weak self] accepted in
      guard let self, self.activeRequestID == requestID else { return }
      self.activeRequestID = nil
      completion(accepted)
    }
  }

  func cancelRecoveryConnection(reason: String) {
    activeRequestID = nil
    cancellationHandler?(reason)
  }

}

@MainActor
protocol CameraSessionRuntimeRecoveryStoring: AnyObject {
  func persistInterruptedRecoverable(
    sessionID: UUID,
    identity: CameraSessionIdentity,
    downloads: [CameraSessionQueuedDownload],
    inFlightHandle: UInt32?,
    completedCount: Int,
    failedCount: Int,
    reason: String
  ) throws
  func loadInterruptedRecoverable() -> CameraDownloadSessionSnapshot?
  func clear()
}

@MainActor
protocol CameraSessionRuntimeSavedHandleStoring: AnyObject {
  func savedHandles(identity: CameraSessionIdentity) -> Set<Int>
  func historyItems(identity: CameraSessionIdentity) -> [CameraVendorGalleryItem]
  func recordSaved(handle: Int, item: CameraVendorGalleryItem?, identity: CameraSessionIdentity)
  func removeSaved(handle: Int, identity: CameraSessionIdentity)
  func clear(identity: CameraSessionIdentity)
}

@MainActor
final class CameraSessionRuntimeSavedHandleStore: CameraSessionRuntimeSavedHandleStoring {
  func savedHandles(identity: CameraSessionIdentity) -> Set<Int> {
    CameraVendorDownloadHistoryStore.savedHandles(for: identity.historyKey)
  }

  func historyItems(identity: CameraSessionIdentity) -> [CameraVendorGalleryItem] {
    CameraVendorDownloadHistoryStore.historyItems(for: identity.historyKey)
  }

  func recordSaved(handle: Int, item: CameraVendorGalleryItem?, identity: CameraSessionIdentity) {
    if let item {
      CameraVendorDownloadHistoryStore.markSaved(item: item, for: identity.historyKey)
    } else {
      CameraVendorDownloadHistoryStore.markSaved(handle: handle, for: identity.historyKey)
    }
  }

  func removeSaved(handle: Int, identity: CameraSessionIdentity) {
    CameraVendorDownloadHistoryStore.removeSaved(handle: handle, for: identity.historyKey)
  }

  func clear(identity: CameraSessionIdentity) {
    CameraVendorDownloadHistoryStore.clear(for: identity.historyKey)
  }
}

@MainActor
final class CameraDownloadSessionRuntimeRecoveryStore: CameraSessionRuntimeRecoveryStoring {
  private let store: CameraDownloadSessionStore

  init(store: CameraDownloadSessionStore = CameraDownloadSessionStore()) {
    self.store = store
  }

  func persistInterruptedRecoverable(
    sessionID: UUID,
    identity: CameraSessionIdentity,
    downloads: [CameraSessionQueuedDownload],
    inFlightHandle: UInt32?,
    completedCount: Int,
    failedCount: Int,
    reason: String
  ) throws {
    guard let peripheralID = identity.peripheralID else {
      throw CameraSessionRuntimeRecoveryStoreError.missingPeripheralIdentity
    }
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: sessionID,
      peripheralID: peripheralID,
      cameraName: identity.cameraName,
      historyKey: identity.historyKey,
      state: .interruptedRecoverable,
      recoveryIntent: reason,
      presentationSurface: "runtime",
      queue: downloads.map {
        CameraDownloadSessionItem(handle: Int($0.handle), mode: $0.mode)
      },
      inFlightHandle: inFlightHandle.map(Int.init),
      completedCount: completedCount,
      failedCount: failedCount,
      updatedAt: Date()
    )
    try store.save(snapshot)
  }

  func loadInterruptedRecoverable() -> CameraDownloadSessionSnapshot? {
    guard let snapshot = try? store.load(),
          snapshot.state == .interruptedRecoverable,
          !snapshot.queue.isEmpty else {
      return nil
    }
    return snapshot
  }

  func clear() {
    try? store.clear()
  }
}
