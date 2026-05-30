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

  private let browser = ICDeviceBrowser()
  private var camerasByID: [String: ICCameraDevice] = [:]
  private var filesByID: [String: ICCameraFile] = [:]
  private weak var activeCamera: ICCameraDevice?

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
      delegate?.wiredCameraImportService(self, didUpdateThumbnailFor: itemID, thumbnail: UIImage(cgImage: thumbnail))
      return
    }
    file.requestThumbnail()
    file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: 320]) { [weak self] data, error in
      guard let self else { return }
      if let error {
        print("CamTransferWired thumbnail request failed item=\(itemID) error=\(error)")
        return
      }
      guard let data, let image = UIImage(data: data) else {
        print("CamTransferWired thumbnail request returned empty data item=\(itemID)")
        return
      }
      DispatchQueue.main.async {
        self.delegate?.wiredCameraImportService(self, didUpdateThumbnailFor: itemID, thumbnail: image)
      }
    }
  }

  func downloadFile(for itemID: String) async throws -> WiredCameraDownloadedFile {
    guard let file = filesByID[itemID] else {
      throw NSError(
        domain: "WiredCameraImportService",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "相机文件已不可用，请刷新后重试"]
      )
    }

    let filename = sanitizedFilename(file.originalFilename ?? file.name ?? "camera-file")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CamTransferWiredImport", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let destination = directory.appendingPathComponent(filename)
    try? FileManager.default.removeItem(at: destination)

    return try await withCheckedThrowingContinuation { continuation in
      let options: [ICDownloadOption: Any] = [
        .downloadsDirectoryURL: directory,
        .saveAsFilename: filename,
        .overwrite: true,
      ]

      _ = file.requestDownload(options: options) { savedFilename, error in
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

        print("CamTransferWired download succeeded item=\(itemID) saved=\(savedURL.path)")

        continuation.resume(
          returning: WiredCameraDownloadedFile(
            fileURL: savedURL,
            filename: savedURL.lastPathComponent,
            mediaType: WiredCameraImportPolicy.mediaType(filename: savedURL.lastPathComponent, uti: file.uti)
          )
        )
      }
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
    let items = files.map(item(for:)).sorted { left, right in
      switch (left.createdAt, right.createdAt) {
      case let (lhs?, rhs?):
        return lhs > rhs
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      case (nil, nil):
        return left.name < right.name
      }
    }
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
    refreshItems(from: camera)
  }

  func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
    refreshItems(from: camera)
  }

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem,
    error: Error?
  ) {}

  func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

  func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

  func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}

  func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

  func cameraDevice(
    _ camera: ICCameraDevice,
    didReceiveThumbnail thumbnail: CGImage?,
    for item: ICCameraItem,
    error: Error?
  ) {
    if let error {
      print("CamTransferWired delegate thumbnail failed item=\(item.name ?? "unknown") error=\(error)")
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
