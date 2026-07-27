import Foundation
import UIKit

@MainActor
protocol CameraSessionRuntimeTransport: AnyObject {
  func beginDownloadLease()
  func endDownloadLease()
  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail
  func fetchPreviewImage(for handle: Int) async throws -> Data
  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot
  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot
  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo
  func beginVisibleThumbnailBatch(handles: [Int])
  func finishVisibleThumbnailBatch(handles: [Int])
  func startTransfer(handle: UInt32, mode: CameraVendorTransferDownloadMode)
  func cancelActiveTransfer(reason: String)
  /// Stops callbacks and local commit work for an obsolete wrapper without
  /// sending any command to the shared physical PTP service.
  func retireForSessionSupersession()
  func terminateCameraCommunication(reason: String)
  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult
}

extension CameraSessionRuntimeTransport {
  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    CameraVendorGalleryPreview(data: try await fetchPreviewImage(for: handle), item: nil)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraSessionRuntimeTransport",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前传输层不支持读取相机初始目录"]
    )
  }

  func fetchCameraCatalog(query _: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraSessionRuntimeTransport",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前传输层不支持相机端目录筛选"]
    )
  }

  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo {
    throw NSError(
      domain: "CameraSessionRuntimeTransport",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前传输层不支持读取对象信息 handle=\(handle)"]
    )
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    throw NSError(
      domain: "CameraSessionRuntimeTransport",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前传输层不支持 count sweep 实验"]
    )
  }
}

@MainActor
final class CameraSessionRuntimeDeferredTransport: CameraSessionRuntimeTransport {
  private var transport: CameraSessionRuntimeTransport?
  private var unboundTerminationHandler: ((String) -> Void)?
  private var binding: CameraSessionRuntimeBinding?

  func attach(_ transport: CameraSessionRuntimeTransport) {
    attach(transport, binding: nil)
  }

  func attach(
    _ transport: CameraSessionRuntimeTransport,
    binding: CameraSessionRuntimeBinding?
  ) {
    if self.binding != binding, self.transport != nil {
      // The bridge intentionally reuses one physical gallery/PTP service while
      // a new runtime generation wraps it. Retiring the old wrapper must stop
      // only its local Task/callbacks; an interrupt command closes the shared
      // socket and would immediately break the newly activated session.
      self.transport?.retireForSessionSupersession()
    }
    self.transport = transport
    self.binding = binding
  }

  func attachUnboundTerminationHandler(_ handler: @escaping (String) -> Void) {
    unboundTerminationHandler = handler
  }

  func startTransfer(handle: UInt32, mode: CameraVendorTransferDownloadMode) {
    transport?.startTransfer(handle: handle, mode: mode)
  }

  func beginDownloadLease() {
    transport?.beginDownloadLease()
  }

  func endDownloadLease() {
    transport?.endDownloadLease()
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchThumbnailWithInfo(for: handle)
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchPreviewImage(for: handle)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchInitialCameraCatalog()
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchCameraCatalog(query: query)
  }

  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchObjectInfo(for: handle)
  }

  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    guard let transport else { throw CancellationError() }
    return try await transport.fetchPreviewImageWithInfo(for: handle)
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    transport?.beginVisibleThumbnailBatch(handles: handles)
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    transport?.finishVisibleThumbnailBatch(handles: handles)
  }

  func cancelActiveTransfer(reason: String) {
    transport?.cancelActiveTransfer(reason: reason)
  }

  func retireForSessionSupersession() {
    transport?.retireForSessionSupersession()
  }

  func terminateCameraCommunication(reason: String) {
    if let transport {
      transport.terminateCameraCommunication(reason: reason)
    } else {
      unboundTerminationHandler?(reason)
    }
  }

}

@MainActor
final class CameraSessionGalleryCatalogRuntimeSource: CameraGalleryCatalogRuntimeSource {
  private let transport: CameraSessionRuntimeTransport

  init(transport: CameraSessionRuntimeTransport) {
    self.transport = transport
  }

  func loadInitialCatalog() async throws -> CameraGalleryCatalogSnapshot {
    do {
      let snapshot = try await transport.fetchInitialCameraCatalog()
      return CameraGalleryCatalogSnapshot(
        snapshotID: CameraGallerySnapshotID(),
        dateGroups: snapshot.dateGroups,
        orderedHandles: snapshot.orderedHandles,
        items: snapshot.items
      )
    } catch let failure as CameraGalleryCatalogTransactionFailure {
      throw failure
    } catch {
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: false
      )
    }
  }

  func loadCatalog(for intent: CameraGalleryFilterIntent) async throws -> CameraGalleryCatalogSnapshot {
    // "All" uses the same expanded initial catalog logic (which includes HEIF handles)
    if intent.format == .all && intent.date == .all {
      return try await loadInitialCatalog()
    }
    let query = try cameraCatalogQuery(for: intent)
    do {
      let snapshot = try await transport.fetchCameraCatalog(query: query)
      return CameraGalleryCatalogSnapshot(
        snapshotID: CameraGallerySnapshotID(),
        dateGroups: snapshot.dateGroups,
        orderedHandles: snapshot.orderedHandles,
        items: snapshot.items
      )
    } catch let failure as CameraGalleryCatalogTransactionFailure {
      throw failure
    } catch {
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: false
      )
    }
  }

  func loadThumbnail(handle: Int) async throws -> CameraVendorGalleryThumbnail {
    try await transport.fetchThumbnailWithInfo(for: handle)
  }

  func loadDetails(handle: Int) async throws -> CameraGalleryDetailsSourceResult {
    let info = try await transport.fetchObjectInfo(for: handle)
    let item = CameraVendorGalleryItem(
      handle: info.handle,
      filename: info.filename,
      formatLabel: info.galleryFormatLabel,
      captureDate: info.captureDate,
      byteSizeText: info.compressedSize > 0
        ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
        : "",
      compressedSize: info.compressedSize == 0 ? nil : info.compressedSize,
      orientation: info.orientation
    )
    let details = CameraGalleryRepositoryAdapter.detailsResult(from: info)
    return CameraGalleryDetailsSourceResult(
      handle: details.handle,
      orientation: details.orientation,
      refinedFormat: details.refinedFormat,
      notes: details.notes,
      resolvedItem: item,
      objectInfo: info
    )
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    transport.beginVisibleThumbnailBatch(handles: handles)
  }

  func finishVisibleThumbnailBatch(handles: [Int]) async {
    transport.finishVisibleThumbnailBatch(handles: handles)
  }

  private func cameraCatalogQuery(
    for intent: CameraGalleryFilterIntent
  ) throws -> CameraVendorCatalogQuery {
    switch intent.format {
    case .all:
      return CameraVendorCatalogQuery(conditions: [], label: "all")
    case .jpg:
      return CameraVendorCatalogQuery(
        conditions: [
          .uint16(
            propertyCode: CameraVendorSearchModeAllPayload.objectFormatPropertyCode,
            value: CameraVendorSearchModeAllPayload.jpegObjectFormatMask
          ),
        ],
        label: "format-jpg"
      )
    case .raw:
      return CameraVendorCatalogQuery(
        conditions: [
          .uint16(
            propertyCode: CameraVendorSearchModeAllPayload.objectFormatPropertyCode,
            value: CameraVendorSearchModeAllPayload.rawObjectFormatMask
          ),
        ],
        label: "format-raw"
      )
    case .heif:
      return CameraVendorCatalogQuery(
        conditions: [
          .uint16(
            propertyCode: CameraVendorSearchModeAllPayload.objectFormatPropertyCode,
            value: CameraVendorSearchModeAllPayload.heifObjectFormatMask
          ),
        ],
        label: "format-heif",
        membershipPolicy: .subtractBaseline
      )
    case .video:
      return CameraVendorCatalogQuery(
        conditions: [
          .uint16(
            propertyCode: CameraVendorSearchModeAllPayload.objectFormatPropertyCode,
            value: CameraVendorSearchModeAllPayload.movObjectFormatMask | CameraVendorSearchModeAllPayload.mp4ObjectFormatMask
          ),
        ],
        label: "format-video",
        membershipPolicy: .subtractBaseline
      )
    }
  }
}

@MainActor
protocol CameraSessionRuntimeFileSaving: AnyObject {
  func save(
    _ file: CameraVendorDownloadedFile,
    commitGate: CameraSessionRuntimeTransferCommitGate,
    onPhotoLibraryCommit: @escaping @MainActor () -> Void
  ) async throws
}

final class CameraSessionRuntimeTransferCommitGate: @unchecked Sendable {
  private enum State {
    case pending
    case committed
    case cancelled
  }

  private let lock = NSLock()
  private var state: State = .pending

  var allowsPhotoLibraryCommit: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .pending
  }

  var didBeginPhotoLibraryCommit: Bool {
    lock.lock()
    defer { lock.unlock() }
    return state == .committed
  }

  func beginPhotoLibraryCommit() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard state == .pending else { return false }
    state = .committed
    return true
  }

  func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    guard state == .pending else { return }
    state = .cancelled
  }
}

@MainActor
final class CameraSessionRuntimePhotoLibraryFileSaver: CameraSessionRuntimeFileSaving {
  func save(
    _ file: CameraVendorDownloadedFile,
    commitGate: CameraSessionRuntimeTransferCommitGate,
    onPhotoLibraryCommit: @escaping @MainActor () -> Void
  ) async throws {
    try await CameraVendorPhotoLibrarySaver.save(
      file: file,
      commitGate: commitGate,
      onPhotoLibraryCommit: onPhotoLibraryCommit
    )
  }
}

enum CameraVendorOriginalDownloadTimingLogPolicy {
  static func completedMessage(
    handle: UInt32,
    filename: String,
    mode: CameraVendorTransferDownloadMode,
    timing: CameraVendorOriginalFileTransferTiming,
    photoSaveMs: Int,
    totalMs: Int
  ) -> String {
    "[OBS] ORIGINAL_DOWNLOAD_TIMING " +
      "handle=0x\(String(format: "%08X", handle)) filename=\(filename) mode=\(mode) " +
      "bytes=\(timing.byteCount) prepareMs=\(timing.prepareMs) " +
      "requestToFirstByteMs=\(timing.requestToFirstByteMs) socketReceiveMs=\(timing.socketReceiveMs) " +
      "fileWriteMs=\(timing.fileWriteMs) commandGapMs=\(timing.commandGapMs) " +
      "transferMs=\(timing.transferMs) photoSaveMs=\(photoSaveMs) totalMs=\(totalMs) " +
      "speedMBps=\(String(format: "%.2f", timing.speedMBps))"
  }
}

@MainActor
final class CameraVendorGallerySessionRuntimeTransport: CameraSessionRuntimeTransport {
  private let galleryService: CameraVendorGalleryService
  private let fileSaver: CameraSessionRuntimeFileSaving
  private let diagnosticHandler: ((String) -> Void)?
  private var onTransferFinished: ((UInt32) -> Void)?
  private var onTransportFailed: ((Error) -> Void)?
  private var onFileSaveFailed: ((UInt32, Error) -> Void)?
  private let onFileSaved: ((UInt32) -> Void)?
  private let onRuntimeTermination: (() -> Void)?
  var onThumbnailGenerated: ((UInt32, UIImage) -> Void)?
  private weak var boundRuntime: CameraSessionRuntime?
  private var binding: CameraSessionRuntimeBinding?
  private var activeTransferTask: Task<Void, Never>?
  private var activeTransferID: UUID?
  private var activeTransferCommitGate: CameraSessionRuntimeTransferCommitGate?
  private var exclusiveDownloadWindowOwnerID: CameraVendorExclusiveDownloadWindowOwnerID?

  init(
    galleryService: CameraVendorGalleryService,
    fileSaver: CameraSessionRuntimeFileSaving,
    diagnosticHandler: ((String) -> Void)? = nil,
    onTransferFinished: ((UInt32) -> Void)? = nil,
    onTransportFailed: ((Error) -> Void)? = nil,
    onFileSaveFailed: ((UInt32, Error) -> Void)? = nil,
    onFileSaved: ((UInt32) -> Void)? = nil,
    onRuntimeTermination: (() -> Void)? = nil
  ) {
    self.galleryService = galleryService
    self.fileSaver = fileSaver
    self.diagnosticHandler = diagnosticHandler
    self.onTransferFinished = onTransferFinished
    self.onTransportFailed = onTransportFailed
    self.onFileSaveFailed = onFileSaveFailed
    self.onFileSaved = onFileSaved
    self.onRuntimeTermination = onRuntimeTermination
  }

  func bind(to runtime: CameraSessionRuntime, binding: CameraSessionRuntimeBinding) {
    boundRuntime = runtime
    self.binding = binding
  }

  func bind(to runtime: CameraSessionRuntime) {
    bind(
      to: runtime,
      binding: runtime.beginTransportBinding(identity: CameraSessionIdentity(cameraName: "bound-transport"))
    )
  }

  func startTransfer(handle: UInt32, mode: CameraVendorTransferDownloadMode) {
    guard activeTransferTask == nil else { return }
    let transferID = UUID()
    let commitGate = CameraSessionRuntimeTransferCommitGate()
    activeTransferID = transferID
    activeTransferCommitGate = commitGate
    activeTransferTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let totalStartedAt = Date()
      do {
        let file = try await galleryService.downloadOriginalFile(for: Int(handle), mode: mode)
        defer {
          try? FileManager.default.removeItem(at: file.fileURL)
        }
        guard self.isCurrentTransfer(transferID), !Task.isCancelled else {
          self.finishCancelledTransfer(handle: handle, transferID: transferID)
          return
        }

        // Generate thumbnail from downloaded file before saving to Photo Library
        self.generateAndCacheThumbnail(handle: handle, fileURL: file.fileURL)

        let photoSaveStartedAt = Date()
        do {
          try await fileSaver.save(
            file,
            commitGate: commitGate,
            onPhotoLibraryCommit: { [weak self] in
              guard let self, self.isCurrentTransfer(transferID) else { return }
              if let boundRuntime = self.boundRuntime {
                boundRuntime.recordSavedHandle(handle)
              } else {
                self.onFileSaved?(handle)
              }
            }
          )
        } catch {
          guard self.isCurrentTransfer(transferID), !Task.isCancelled else {
            self.finishCancelledTransfer(handle: handle, transferID: transferID)
            return
          }
          self.clearActiveTransfer(transferID)
          if let onFileSaveFailed {
            onFileSaveFailed(handle, error)
          } else {
            boundRuntime?.send(.fileSaveFailed(handle: handle, error: error))
          }
          return
        }
        guard self.isCurrentTransfer(transferID), !Task.isCancelled else {
          self.finishCancelledTransfer(handle: handle, transferID: transferID)
          return
        }
        if let timing = file.transferTiming {
          diagnosticHandler?(
            CameraVendorOriginalDownloadTimingLogPolicy.completedMessage(
              handle: handle,
              filename: file.filename,
              mode: mode,
              timing: timing,
              photoSaveMs: Int(Date().timeIntervalSince(photoSaveStartedAt) * 1000),
              totalMs: Int(Date().timeIntervalSince(totalStartedAt) * 1000)
            )
          )
        }
        clearActiveTransfer(transferID)
        if let onTransferFinished {
          onTransferFinished(handle)
        } else {
          guard let runtime = boundRuntime, runtime.acceptsTransportCallback(binding) else { return }
          runtime.send(.transferFinished(handle: handle))
        }
      } catch {
        guard self.isCurrentTransfer(transferID), !Task.isCancelled else {
          self.finishCancelledTransfer(handle: handle, transferID: transferID)
          return
        }
        self.clearActiveTransfer(transferID)
        if let onTransportFailed {
          onTransportFailed(error)
        } else {
          guard let runtime = boundRuntime, runtime.acceptsTransportCallback(binding) else { return }
          runtime.send(.transportFailed(error))
        }
      }
    }
  }

  func beginDownloadLease() {
    guard exclusiveDownloadWindowOwnerID == nil else { return }
    exclusiveDownloadWindowOwnerID =
      (galleryService as? CameraVendorExclusiveDownloadWindowControlling)?
        .beginExclusiveDownloadWindow()
  }

  func endDownloadLease() {
    guard let ownerID = exclusiveDownloadWindowOwnerID else { return }
    exclusiveDownloadWindowOwnerID = nil
    (galleryService as? CameraVendorExclusiveDownloadWindowControlling)?
      .endExclusiveDownloadWindow(ownerID: ownerID)
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    try await galleryService.fetchThumbnailWithInfo(for: handle)
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await galleryService.fetchPreviewImage(for: handle)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await galleryService.fetchInitialCameraCatalog()
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await galleryService.fetchCameraCatalog(query: query)
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await galleryService.executeCountSweepExperiment()
  }

  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo {
    guard let source = galleryService as? CameraVendorGalleryObjectInfoSource else {
      throw NSError(
        domain: "CameraSessionRuntimeTransport",
        code: NSURLErrorUnsupportedURL,
        userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持读取对象信息"]
      )
    }
    return try await source.fetchObjectInfo(for: handle)
  }

  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    try await galleryService.fetchPreviewImageWithInfo(for: handle)
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    (galleryService as? CameraVendorVisibleThumbnailLaneCoordinating)?
      .beginVisibleThumbnailBatch(handles: handles)
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    (galleryService as? CameraVendorVisibleThumbnailLaneCoordinating)?
      .finishVisibleThumbnailBatch(handles: handles)
  }

  func cancelActiveTransfer(reason: String) {
    activeTransferTask?.cancel()
    activeTransferCommitGate?.invalidate()
    if reason == "user-cancelled-download" {
      (galleryService as? CameraVendorActiveDownloadCancellationRequesting)?
        .requestActiveDownloadCancellation(reason: reason)
      return
    }
    (galleryService as? CameraVendorActiveDownloadInterrupting)?
      .interruptActiveDownload(reason: reason)
  }

  func retireForSessionSupersession() {
    activeTransferTask?.cancel()
    activeTransferCommitGate?.invalidate()
    activeTransferTask = nil
    activeTransferID = nil
    activeTransferCommitGate = nil
  }

  func terminateCameraCommunication(reason: String) {
    cancelActiveTransfer(reason: reason)
    (galleryService as? CameraVendorGalleryConnectionTerminating)?
      .terminateCameraCommunication(reason: reason)
    onRuntimeTermination?()
  }

  private func isCurrentTransfer(_ transferID: UUID) -> Bool {
    activeTransferID == transferID
  }

  private func clearActiveTransfer(_ transferID: UUID) {
    guard isCurrentTransfer(transferID) else { return }
    activeTransferTask = nil
    activeTransferID = nil
    activeTransferCommitGate = nil
  }

  private func finishCancelledTransfer(handle: UInt32, transferID: UUID) {
    guard isCurrentTransfer(transferID) else { return }
    clearActiveTransfer(transferID)
    guard let runtime = boundRuntime, runtime.acceptsTransportCallback(binding) else { return }
    runtime.send(.transferCancelled(handle: handle))
  }

  private func generateAndCacheThumbnail(handle: UInt32, fileURL: URL) {
    let targetSize = CGSize(width: 200, height: 200)
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as? [CFString: Any],
          let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return
    }
    let thumbnail = UIImage(cgImage: cgImage)
    onThumbnailGenerated?(handle, thumbnail)
  }
}
