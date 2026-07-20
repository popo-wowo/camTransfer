import Foundation
import ImageCaptureCore
import UIKit

protocol WiredCameraImportServiceDelegate: AnyObject {
  func wiredCameraImportServiceDidUpdateAuthorization(_ service: WiredCameraImportService, isAuthorized: Bool)
  func wiredCameraImportServiceDidUpdateDevices(_ service: WiredCameraImportService, devices: [WiredCameraImportDevice])
  func wiredCameraImportServiceDidStartLoadingItems(_ service: WiredCameraImportService)
  func wiredCameraImportService(_ service: WiredCameraImportService, didUpdateItems items: [WiredCameraImportItem])
  func wiredCameraImportService(_ service: WiredCameraImportService, didUpdateThumbnailFor itemID: String, thumbnail: UIImage)
  func wiredCameraImportService(_ service: WiredCameraImportService, didFailWith message: String)
}

final class WiredCameraImportService: NSObject {
  weak var delegate: WiredCameraImportServiceDelegate?
  var downloadProgressHandler: ((String, Int64, Int64) -> Void)?

  private let browser = ICDeviceBrowser()
  private var camerasByID: [String: ICCameraDevice] = [:]
  private var filesByID: [String: ICCameraFile] = [:]
  private weak var activeCamera: ICCameraDevice?
  private var isDeleteRequestInFlight = false
  private var isForegroundOperationInFlight = false
  private var activeThumbnailRequestItemID: String?
  private var queuedThumbnailItemIDs: [String] = []
  private var queuedThumbnailItemIDSet: Set<String> = []
  private var resolvedThumbnailItemIDs: Set<String> = []
  private var thumbnailIdleWaiters: [CheckedContinuation<Void, Never>] = []
  private var activeDownloadProgressObservation: NSKeyValueObservation?

  override init() {
    super.init()
    browser.delegate = self
    if #available(iOS 15.2, *) {
      if let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) {
        browser.browsedDeviceTypeMask = mask
      }
    }
  }

  deinit {
    stop()
  }

  func start() {
    requestContentsAuthorizationIfNeeded { [weak self] authorized in
      guard let self else { return }
      self.delegate?.wiredCameraImportServiceDidUpdateAuthorization(self, isAuthorized: authorized)
      guard authorized else {
        self.delegate?.wiredCameraImportService(self, didFailWith: "没有外部相机访问权限，请在系统弹窗中允许后重试")
        return
      }
      if !self.browser.isBrowsing {
        self.browser.start()
      }
      self.publishDevices()
    }
  }

  func stop() {
    if browser.isBrowsing {
      browser.stop()
    }
    activeCamera?.requestCloseSession(options: nil, completion: { _ in })
    activeCamera = nil
    filesByID.removeAll()
    isDeleteRequestInFlight = false
    isForegroundOperationInFlight = false
    activeDownloadProgressObservation = nil
    activeThumbnailRequestItemID = nil
    queuedThumbnailItemIDs.removeAll()
    queuedThumbnailItemIDSet.removeAll()
    resolvedThumbnailItemIDs.removeAll()
    resumeThumbnailIdleWaiters()
  }

  func openDevice(id: String) {
    guard let camera = camerasByID[id] else {
      delegate?.wiredCameraImportService(self, didFailWith: "没有找到这台有线相机")
      return
    }

    activeCamera = camera
    camera.delegate = self
    delegate?.wiredCameraImportServiceDidStartLoadingItems(self)

    if camera.hasOpenSession {
      refreshItems(from: camera)
      return
    }

    camera.requestOpenSession(options: nil) { [weak self, weak camera] error in
      DispatchQueue.main.async {
        guard let self, let camera else { return }
        if let error {
          self.delegate?.wiredCameraImportService(self, didFailWith: "打开相机会话失败：\(error.localizedDescription)")
          return
        }
        self.refreshItems(from: camera)
      }
    }
  }

  func requestThumbnail(for itemID: String) {
    guard let file = filesByID[itemID] else { return }
    if let thumbnail = file.thumbnail {
      resolvedThumbnailItemIDs.insert(itemID)
      delegate?.wiredCameraImportService(self, didUpdateThumbnailFor: itemID, thumbnail: UIImage(cgImage: thumbnail))
      return
    }
    guard !isDeleteRequestInFlight,
          !isForegroundOperationInFlight,
          !resolvedThumbnailItemIDs.contains(itemID),
          activeThumbnailRequestItemID != itemID,
          !queuedThumbnailItemIDSet.contains(itemID) else { return }
    queuedThumbnailItemIDs.append(itemID)
    queuedThumbnailItemIDSet.insert(itemID)
    startNextThumbnailRequestIfNeeded()
  }

  func requestThumbnails(in priorityOrder: [String]) {
    guard !isDeleteRequestInFlight, !isForegroundOperationInFlight else { return }
    let requestedIDs = priorityOrder.reduce(into: [String]()) { result, itemID in
      guard !result.contains(itemID),
            itemID != activeThumbnailRequestItemID,
            !resolvedThumbnailItemIDs.contains(itemID),
            let file = filesByID[itemID],
            file.thumbnail == nil else {
        return
      }
      result.append(itemID)
    }
    guard !requestedIDs.isEmpty else { return }

    let requestedSet = Set(requestedIDs)
    let remainingIDs = queuedThumbnailItemIDs.filter { !requestedSet.contains($0) }
    queuedThumbnailItemIDs = requestedIDs + remainingIDs
    queuedThumbnailItemIDSet = Set(queuedThumbnailItemIDs)
    startNextThumbnailRequestIfNeeded()
  }

  func downloadFile(for itemID: String) async throws -> WiredCameraDownloadedFile {
    guard let file = filesByID[itemID] else {
      throw NSError(
        domain: "WiredCameraImportService",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "相机文件已不可用，请刷新后重试"]
      )
    }
    try await beginForegroundOperation(named: "download")
    defer { finishForegroundOperation(named: "download") }

    let filename = sanitizedFilename(file.originalFilename ?? file.name ?? "camera-file")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CamTransferWiredImport", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let destination = directory.appendingPathComponent(filename)
    try? FileManager.default.removeItem(at: destination)

    let startedAt = Date()
    return try await withCheckedThrowingContinuation { continuation in
      let options: [ICDownloadOption: Any] = [
        .downloadsDirectoryURL: directory,
        .saveAsFilename: filename,
        .overwrite: true,
      ]

      let progress = file.requestDownload(options: options) { [weak self] savedFilename, error in
        self?.activeDownloadProgressObservation = nil
        if let error {
          continuation.resume(throwing: error)
          return
        }

        let savedURL = WiredCameraDownloadResolutionPolicy.resolvedURL(
          savedFilename: savedFilename,
          requestedFilename: filename,
          directory: directory
        )

        guard FileManager.default.fileExists(atPath: savedURL.path) else {
          let directoryContents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
          let contentsText = directoryContents.joined(separator: ", ")
          continuation.resume(
            throwing: NSError(
              domain: "WiredCameraImportService",
              code: 2,
              userInfo: [
                NSLocalizedDescriptionKey: "相机下载完成但本地文件不存在：\(savedURL.lastPathComponent)。目录内容：\(contentsText)"
              ]
            )
          )
          return
        }

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        let size = Int64(file.fileSize)
        let megabytesPerSecond = Double(size) / elapsed / 1_000_000
        let message = "CamTransferWired download succeeded item=\(itemID) saved=\(savedURL.path) bytes=\(size) duration=\(String(format: "%.3f", elapsed))s rate=\(String(format: "%.2f", megabytesPerSecond))MBps"
        print(message)
        CameraVendorFileLogger.log(message)

        continuation.resume(
          returning: WiredCameraDownloadedFile(
            fileURL: savedURL,
            filename: savedURL.lastPathComponent,
            mediaType: WiredCameraImportPolicy.mediaType(filename: savedURL.lastPathComponent, uti: file.uti)
          )
        )
      }
      let reportProgress = downloadProgressHandler
      activeDownloadProgressObservation = progress?.observe(
        \.completedUnitCount,
        options: [.initial, .new]
      ) { [weak progress] _, _ in
        guard let progress else { return }
        let completedBytes = Int64(progress.completedUnitCount)
        let totalBytes = Int64(progress.totalUnitCount)
        DispatchQueue.main.async {
          reportProgress?(itemID, completedBytes, totalBytes)
        }
      }
    }
  }

  func requestPreview(for itemID: String) async throws -> UIImage {
    guard let file = filesByID[itemID] else {
      throw NSError(
        domain: "WiredCameraImportService.Preview",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "相机文件已不可用，请返回图库后重试"]
      )
    }

    try await beginForegroundOperation(named: "preview")
    defer { finishForegroundOperation(named: "preview") }

    let message = "CamTransferWired preview begin item=\(itemID) maxPixel=\(WiredCameraPreviewPolicy.maximumPixelSize)"
    print(message)
    CameraVendorFileLogger.log(message)
    return try await withCheckedThrowingContinuation { continuation in
      file.requestThumbnailData(options: [
        .imageSourceThumbnailMaxPixelSize: WiredCameraPreviewPolicy.maximumPixelSize,
      ]) { data, error in
        DispatchQueue.main.async {
          if let error {
            let message = "CamTransferWired preview failed item=\(itemID) error=\(error)"
            print(message)
            CameraVendorFileLogger.log(message)
            continuation.resume(throwing: error)
          } else if let data, let image = UIImage(data: data) {
            let message = "CamTransferWired preview succeeded item=\(itemID) bytes=\(data.count) size=\(Int(image.size.width))x\(Int(image.size.height))"
            print(message)
            CameraVendorFileLogger.log(message)
            continuation.resume(returning: image)
          } else {
            let error = NSError(
              domain: "WiredCameraImportService.Preview",
              code: 2,
              userInfo: [NSLocalizedDescriptionKey: "相机没有返回可解码的高清预览"]
            )
            let message = "CamTransferWired preview empty item=\(itemID)"
            print(message)
            CameraVendorFileLogger.log(message)
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  func deleteFile(
    for itemID: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let camera = activeCamera, camera.hasOpenSession else {
      completion(.failure(deleteError(code: 10, message: "相机会话未打开，请重新连接后再试")))
      return
    }
    guard let file = filesByID[itemID] else {
      completion(.failure(deleteError(code: 11, message: "相机文件已不可用，请刷新后重试")))
      return
    }

    let capability = ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue
    let advertisesSingleDelete = camera.capabilities.contains(capability)
    let filename = file.originalFilename ?? file.name ?? "camera-file"
    let handle = file.ptpObjectHandle
    isDeleteRequestInFlight = true
    Task { [weak self, weak camera] in
      guard let self, let camera else { return }
      do {
        try await self.beginForegroundOperation(named: "delete")
      } catch {
        self.isDeleteRequestInFlight = false
        completion(.failure(error))
        return
      }

      let discardedThumbnailCount = self.queuedThumbnailItemIDs.count
      self.logDelete(
        "begin device=\(camera.name ?? camera.productKind ?? "unknown") " +
          "transport=\(camera.transportType ?? "unknown") " +
          "advertisesSingleDelete=\(advertisesSingleDelete) " +
          "capabilities=\(camera.capabilities.sorted()) " +
          "item=\(itemID) filename=\(filename) handle=0x\(String(format: "%08X", handle)) " +
          "thumbnailActive=\(self.activeThumbnailRequestItemID ?? "none") thumbnailDiscarded=\(discardedThumbnailCount)"
      )

      _ = camera.requestDeleteFiles(
        [file],
        deleteFailed: { [weak self] failures in
          let details = failures.map { key, item in
            "error=\(key.rawValue) filename=\(item.name ?? "unknown") handle=0x\(String(format: "%08X", item.ptpObjectHandle))"
          }.sorted().joined(separator: ";")
          self?.logDelete("deleteFailed item=\(itemID) details=\(details)")
        },
        completion: { [weak self, weak camera] result, error in
          DispatchQueue.main.async {
            guard let self else { return }
            let successfulCount = result[.successful]?.count ?? 0
            let failedCount = result[.failed]?.count ?? 0
            self.isDeleteRequestInFlight = false
            self.finishForegroundOperation(named: "delete")
            if let error {
              let nsError = error as NSError
              self.logDelete(
                "completion failed item=\(itemID) successCount=\(successfulCount) failedCount=\(failedCount) " +
                  "domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
              )
              completion(.failure(error))
              return
            }

            self.logDelete(
              "completion succeeded item=\(itemID) successCount=\(successfulCount) failedCount=\(failedCount)"
            )
            if let camera {
              self.refreshItems(from: camera)
            }
            completion(.success(()))
          }
        }
      )
    }
  }

  private func requestContentsAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
    guard #available(iOS 14.0, *) else {
      completion(true)
      return
    }

    switch browser.contentsAuthorizationStatus {
    case .authorized:
      completion(true)
    case .notDetermined:
      browser.requestContentsAuthorization { status in
        DispatchQueue.main.async {
          completion(status == .authorized)
        }
      }
    default:
      completion(false)
    }
  }

  private func publishDevices() {
    let cameras = browser.devices?.compactMap { $0 as? ICCameraDevice } ?? []
    camerasByID = Dictionary(uniqueKeysWithValues: cameras.map { (deviceID(for: $0), $0) })
    delegate?.wiredCameraImportServiceDidUpdateDevices(self, devices: cameras.map(summary(for:)))
  }

  private func refreshItems(from camera: ICCameraDevice) {
    let files = camera.mediaFiles?.compactMap { $0 as? ICCameraFile } ?? []
    filesByID = Dictionary(uniqueKeysWithValues: files.map { (itemID(for: $0), $0) })
    resolvedThumbnailItemIDs.formIntersection(Set(filesByID.keys))
    let items = WiredCameraImportSortPolicy.newestFirst(files.map(item(for:)))
    delegate?.wiredCameraImportService(self, didUpdateItems: items)
  }

  private func summary(for camera: ICCameraDevice) -> WiredCameraImportDevice {
    WiredCameraImportDevice(
      id: deviceID(for: camera),
      name: camera.name ?? camera.productKind ?? "有线相机",
      transportName: camera.transportType ?? "USB"
    )
  }

  private func item(for file: ICCameraFile) -> WiredCameraImportItem {
    let filename = file.originalFilename ?? file.name ?? "camera-file"
    let thumbnail = file.thumbnail.map { UIImage(cgImage: $0) }
    return WiredCameraImportItem(
      id: itemID(for: file),
      ptpObjectHandle: file.ptpObjectHandle,
      name: filename,
      uti: file.uti,
      fileSize: Int64(file.fileSize),
      createdAt: file.creationDate ?? file.exifCreationDate ?? file.fileCreationDate,
      thumbnail: thumbnail,
      isImportable: WiredCameraImportPolicy.isSupportedMedia(filename: filename, uti: file.uti)
    )
  }

  private func deviceID(for camera: ICCameraDevice) -> String {
    camera.uuidString ?? "\(camera.usbVendorID)-\(camera.usbProductID)-\(camera.usbLocationID)"
  }

  private func itemID(for file: ICCameraFile) -> String {
    let filename = file.originalFilename ?? file.name ?? "camera-file"
    return WiredCameraImportItemIdentity.make(
      ptpObjectHandle: file.ptpObjectHandle,
      filename: filename,
      fileSize: file.fileSize,
      createdAt: file.creationDate ?? file.exifCreationDate ?? file.fileCreationDate
    )
  }

  private func sanitizedFilename(_ filename: String) -> String {
    let fallback = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !fallback.isEmpty else { return "camera-file" }
    let invalid = CharacterSet(charactersIn: "/:")
    return fallback.components(separatedBy: invalid).joined(separator: "-")
  }

  private func startNextThumbnailRequestIfNeeded() {
    guard WiredCameraThumbnailQueuePolicy.shouldStartRequest(
      isDeleteInFlight: isDeleteRequestInFlight,
      isForegroundOperationInFlight: isForegroundOperationInFlight,
      hasActiveThumbnailRequest: activeThumbnailRequestItemID != nil
    ) else { return }

    while !queuedThumbnailItemIDs.isEmpty {
      let itemID = queuedThumbnailItemIDs.removeFirst()
      queuedThumbnailItemIDSet.remove(itemID)
      guard let file = filesByID[itemID],
            file.thumbnail == nil,
            !resolvedThumbnailItemIDs.contains(itemID) else { continue }
      activeThumbnailRequestItemID = itemID
      file.requestThumbnailData(options: [
        .imageSourceThumbnailMaxPixelSize: WiredCameraPreviewPolicy.gridMaximumPixelSize,
      ]) { [weak self] data, error in
        DispatchQueue.main.async {
          guard let self else { return }
          self.completeActiveThumbnailRequest()
          if let error {
            let message = "CamTransferWired thumbnail request failed item=\(itemID) error=\(error)"
            print(message)
            CameraVendorFileLogger.log(message)
          } else if let data, let image = UIImage(data: data) {
            self.resolvedThumbnailItemIDs.insert(itemID)
            self.delegate?.wiredCameraImportService(self, didUpdateThumbnailFor: itemID, thumbnail: image)
          } else {
            let message = "CamTransferWired thumbnail request returned empty data item=\(itemID)"
            print(message)
            CameraVendorFileLogger.log(message)
          }
          self.startNextThumbnailRequestIfNeeded()
        }
      }
      return
    }
  }

  private func beginForegroundOperation(named name: String) async throws {
    guard !isForegroundOperationInFlight else {
      throw NSError(
        domain: "WiredCameraImportService.Transfer",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "相机正在处理另一项操作，请稍后再试"]
      )
    }
    isForegroundOperationInFlight = true
    let discardedThumbnailCount = queuedThumbnailItemIDs.count
    queuedThumbnailItemIDs.removeAll()
    queuedThumbnailItemIDSet.removeAll()
    let message = "CamTransferWired transfer begin operation=\(name) thumbnailActive=\(activeThumbnailRequestItemID ?? "none") thumbnailDiscarded=\(discardedThumbnailCount)"
    print(message)
    CameraVendorFileLogger.log(message)

    while activeThumbnailRequestItemID != nil {
      await withCheckedContinuation { continuation in
        thumbnailIdleWaiters.append(continuation)
      }
    }
  }

  private func finishForegroundOperation(named name: String) {
    guard isForegroundOperationInFlight else { return }
    isForegroundOperationInFlight = false
    let message = "CamTransferWired transfer finish operation=\(name)"
    print(message)
    CameraVendorFileLogger.log(message)
    startNextThumbnailRequestIfNeeded()
  }

  private func completeActiveThumbnailRequest() {
    activeThumbnailRequestItemID = nil
    resumeThumbnailIdleWaiters()
  }

  private func resumeThumbnailIdleWaiters() {
    let waiters = thumbnailIdleWaiters
    thumbnailIdleWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func deleteError(code: Int, message: String) -> NSError {
    NSError(
      domain: "WiredCameraImportService.Delete",
      code: code,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  private func logDelete(_ detail: String) {
    let message = "CamTransferWired delete \(detail)"
    print(message)
    CameraVendorFileLogger.log(message)
  }
}

extension WiredCameraImportService: ICDeviceBrowserDelegate {
  func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
    guard device is ICCameraDevice else { return }
    publishDevices()
  }

  func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
    if let camera = device as? ICCameraDevice, deviceID(for: camera) == activeCamera.map(deviceID(for:)) {
      activeCamera = nil
      filesByID.removeAll()
      delegate?.wiredCameraImportService(self, didUpdateItems: [])
    }
    publishDevices()
  }
}

extension WiredCameraImportService: ICCameraDeviceDelegate {
  func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

  func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    guard let camera = device as? ICCameraDevice, error == nil else { return }
    refreshItems(from: camera)
  }

  func didRemove(_ device: ICDevice) {
    if let camera = device as? ICCameraDevice, deviceID(for: camera) == activeCamera.map(deviceID(for:)) {
      activeCamera = nil
      filesByID.removeAll()
      delegate?.wiredCameraImportService(self, didUpdateItems: [])
    }
  }

  func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
    refreshItems(from: device)
  }

  func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
    refreshItems(from: camera)
  }

  func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
    let details = items.map {
      "\($0.name ?? "unknown")@0x\(String(format: "%08X", $0.ptpObjectHandle))"
    }.joined(separator: ",")
    logDelete("didRemove count=\(items.count) items=\(details)")
    refreshItems(from: camera)
  }

  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
    refreshItems(from: camera)
  }

  func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: Error?) {
    if let error {
      let nsError = error as NSError
      logDelete(
        "delegate completion failed domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
      )
    } else {
      logDelete("delegate completion succeeded")
    }
  }

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem,
    error: Error?
  ) {}

  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
    let capability = ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue
    logDelete(
      "capabilityChanged advertisesSingleDelete=\(camera.capabilities.contains(capability)) capabilities=\(camera.capabilities.sorted())"
    )
  }

  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

  func cameraDevice(_ cameraDevice: ICCameraDevice, shouldGetThumbnailOf item: ICCameraItem) -> Bool {
    !isForegroundOperationInFlight
  }

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveThumbnail thumbnail: CGImage?,
    for item: ICCameraItem,
    error: Error?
  ) {
    if let error {
      let message = "CamTransferWired delegate thumbnail failed item=\(item.name ?? "unknown") error=\(error)"
      print(message)
      CameraVendorFileLogger.log(message)
      return
    }
    guard let file = item as? ICCameraFile, let thumbnail else { return }
    delegate?.wiredCameraImportService(
      self,
      didUpdateThumbnailFor: itemID(for: file),
      thumbnail: UIImage(cgImage: thumbnail)
    )
  }
}
