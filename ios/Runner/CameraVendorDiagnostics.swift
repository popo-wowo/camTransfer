import Foundation
import UIKit
import os.log

enum CamTransferDiagnosticLogRedactor {
  static func redacted(_ text: String) -> String {
    var result = text
    result = result.replacingOccurrences(
      of: #"(?i)\b(password|passphrase|pwd)(\s*[:=]\s*)[^\s,;，；\n]+"#,
      with: #"$1$2********"#,
      options: .regularExpression
    )
    result = result.replacingOccurrences(
      of: #"(密码\s*[:：=]\s*)[^\s,;，；\n]+"#,
      with: #"$1********"#,
      options: .regularExpression
    )
    return result
  }
}

enum CamTransferDiagnosticExportPayload {
  static func compose(
    appVersion: String,
    buildNumber: String,
    deviceModel: String,
    systemVersion: String,
    generatedAt: String,
    logText: String
  ) -> String {
    """
    CamTransfer Diagnostic Log
    App Version: \(appVersion) (\(buildNumber))
    Device: \(deviceModel)
    System: \(systemVersion)
    Generated At: \(generatedAt)

    ---- Log ----
    \(CamTransferDiagnosticLogRedactor.redacted(logText))
    """
  }
}

enum CamTransferDiagnosticLogExporter {
  static func makeExportFile(sourceLogURL: URL) throws -> URL {
    try makeExportFile(sourceLogURLs: [sourceLogURL])
  }

  static func makeExportFile(sourceLogURLs: [URL]) throws -> URL {
    let rawLog = sourceLogURLs.map { url in
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "(no log file)"
      return "Source: \(url.lastPathComponent)\n\(text)"
    }.joined(separator: "\n\n")
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let generatedAt = ISO8601DateFormatter().string(from: Date())
    let payload = CamTransferDiagnosticExportPayload.compose(
      appVersion: appVersion,
      buildNumber: buildNumber,
      deviceModel: UIDevice.current.model,
      systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      generatedAt: generatedAt,
      logText: rawLog
    )
    let filenameTimestamp = generatedAt
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    let exportURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("CamTransfer-Diagnostics-\(filenameTimestamp).log")
    try payload.write(to: exportURL, atomically: true, encoding: .utf8)
    return exportURL
  }
}

final class CameraVendorFileLogger {
  static let shared = CameraVendorFileLogger()
  private let fileURL: URL
  private let queue: DispatchQueue

  private convenience init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    self.init(fileURL: docs.appendingPathComponent("camtransfer_debug.log"))
  }

  init(fileURL: URL) {
    self.fileURL = fileURL
    queue = DispatchQueue(label: "com.camtransfer.fileLogger")
    queue.sync {
      appendOnQueue("\n=== CamTransfer Log \(Date()) ===\n")
    }
  }

  static func log(_ message: String) {
    CameraDiagnosticPipeline.shared.emitLegacy(message)
  }

  static func persist(_ message: String) {
    shared.persist(message)
  }

  func persist(_ message: String) {
    queue.async {
      let safeMessage = CamTransferDiagnosticLogRedactor.redacted(message)
      let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(safeMessage)\n"
      os_log("%{public}@", line)
      if let data = line.data(using: .utf8) {
        self.trimAndRotateIfNeeded(addingBytes: data.count)
        self.appendDataOnQueue(data)
      }
    }
  }

  func flushForTesting() {
    queue.sync {}
  }

  static var logFileURL: URL { shared.fileURL }

  private func appendOnQueue(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    appendDataOnQueue(data)
  }

  private func appendDataOnQueue(_ data: Data) {
    ensurePrimaryFileExistsOnQueue()
    guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
    handle.seekToEndOfFile()
    handle.write(data)
    handle.closeFile()
  }

  private func ensurePrimaryFileExistsOnQueue() {
    let fileManager = FileManager.default
    let directoryURL = fileURL.deletingLastPathComponent()
    try? fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    if !fileManager.fileExists(atPath: fileURL.path) {
      fileManager.createFile(atPath: fileURL.path, contents: nil)
    }
  }

  private func trimAndRotateIfNeeded(addingBytes: Int) {
    let fileManager = FileManager.default
    let currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
    guard currentSize + addingBytes > CameraVendorFileLogPolicy.maxPrimaryLogBytes else {
      return
    }

    let oldestArchiveURL = archivedFileURL(index: CameraVendorFileLogPolicy.maxArchiveLogCount)
    try? fileManager.removeItem(at: oldestArchiveURL)
    if CameraVendorFileLogPolicy.maxArchiveLogCount > 1 {
      for index in stride(from: CameraVendorFileLogPolicy.maxArchiveLogCount - 1, through: 1, by: -1) {
        let sourceURL = archivedFileURL(index: index)
        let destinationURL = archivedFileURL(index: index + 1)
        guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.moveItem(at: sourceURL, to: destinationURL)
      }
    }

    let firstArchiveURL = archivedFileURL(index: 1)
    try? fileManager.removeItem(at: firstArchiveURL)
    if fileManager.fileExists(atPath: fileURL.path) {
      try? fileManager.moveItem(at: fileURL, to: firstArchiveURL)
    }
    ensurePrimaryFileExistsOnQueue()
  }

  private func archivedFileURL(index: Int) -> URL {
    let baseName = fileURL.deletingPathExtension().lastPathComponent
    let fileExtension = fileURL.pathExtension
    let archiveName = fileExtension.isEmpty
      ? "\(baseName).\(index)"
      : "\(baseName).\(index).\(fileExtension)"
    return fileURL.deletingLastPathComponent().appendingPathComponent(archiveName)
  }
}

enum CameraVendorFileLogPolicy {
  static let maxPrimaryLogBytes = 2 * 1024 * 1024
  static let maxArchiveLogCount = 3
}

enum CameraVendorFastDiagnosticLogPolicy {
  private static let memoryOnlyTokens = [
    "PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK",
    "PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST",
    "PTP_STANDARD_PARTIAL_OBJECT_CHUNK",
    "PTP_STANDARD_PARTIAL_OBJECT_REQUEST",
    "BLE_BACKGROUND_KEEP_ALIVE_",
    "GALLERY_BACKGROUND_READ_IMAGE_INFO_KEEP_ALIVE_OK",
    "GALLERY_BACKGROUND_METADATA_REQUEST_BEGIN",
    "GALLERY_BACKGROUND_METADATA_REQUEST_END",
  ]

  static func shouldWriteToDisk(_ message: String) -> Bool {
    let uppercaseMessage = message.uppercased()
    if uppercaseMessage.contains("FAILED") || uppercaseMessage.contains("ERROR=") {
      return true
    }
    return !memoryOnlyTokens.contains { message.contains($0) }
  }
}
