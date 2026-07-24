import CoreLocation
import CoreBluetooth
import Darwin
import Foundation
import NetworkExtension
import UIKit
import os.log


struct CameraVendorWifiNetworkConfiguration: Codable, Equatable {
  let ssid: String
  let passphrase: String
  let isHidden: Bool
  let bssid: String?

  init(
    ssid: String,
    passphrase: String,
    isHidden: Bool,
    bssid: String? = nil
  ) {
    self.ssid = ssid
    self.passphrase = passphrase
    self.isHidden = isHidden
    self.bssid = CameraVendorReferenceAppNetworkConfigDecoder.normalizedBSSID(from: bssid)
  }

  enum CodingKeys: String, CodingKey {
    case ssid
    case passphrase
    case isHidden
    case bssid
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.ssid = try container.decode(String.self, forKey: .ssid)
    self.passphrase = try container.decode(String.self, forKey: .passphrase)
    self.isHidden = try container.decode(Bool.self, forKey: .isHidden)
    self.bssid = CameraVendorReferenceAppNetworkConfigDecoder.normalizedBSSID(
      from: try container.decodeIfPresent(String.self, forKey: .bssid)
    )
  }
}

struct CameraVendorConnectionSummary: Equatable {
  let deviceName: String
  let serialNumber: String
  let connectedDeviceName: String
  let preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?
  let preferCompressedDownloads: Bool
  let verifiedConnectionSteps: [IOSCameraConnectionStep]

  init(
    deviceName: String,
    serialNumber: String,
    connectedDeviceName: String = CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName(),
    preferredWifiNetwork: CameraVendorWifiNetworkConfiguration? = nil,
    preferCompressedDownloads: Bool = true,
    verifiedConnectionSteps: [IOSCameraConnectionStep] = []
  ) {
    self.deviceName = deviceName
    self.serialNumber = serialNumber
    self.connectedDeviceName = connectedDeviceName
    self.preferredWifiNetwork = preferredWifiNetwork
    self.preferCompressedDownloads = preferCompressedDownloads
    self.verifiedConnectionSteps = verifiedConnectionSteps
  }

  var navigationTitle: String { deviceName }
  var activeTransferDownloadMode: CameraVendorTransferDownloadMode {
    preferCompressedDownloads ? .compressed : .original
  }

  var subtitle: String { "序列号 \(serialNumber)" }
  func updatingVerifiedConnectionSteps(
    _ steps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    CameraVendorConnectionSummary(
      deviceName: deviceName,
      serialNumber: serialNumber,
      connectedDeviceName: connectedDeviceName,
      preferredWifiNetwork: preferredWifiNetwork,
      preferCompressedDownloads: preferCompressedDownloads,
      verifiedConnectionSteps: steps
    )
  }

  var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] {
    var configurations: [CameraVendorWifiNetworkConfiguration] = []
    if let preferredWifiNetwork {
      configurations.append(
        CameraVendorWifiNetworkConfiguration(
          ssid: preferredWifiNetwork.ssid,
          passphrase: preferredWifiNetwork.passphrase,
          isHidden: preferredWifiNetwork.isHidden,
          bssid: preferredWifiNetwork.bssid
        )
      )
    }

    var seen: Set<String> = []
    var result: [CameraVendorWifiNetworkConfiguration] = []
    for configuration in configurations {
      let trimmedSSID = configuration.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
      let deduplicationKey = "\(trimmedSSID)|\(configuration.passphrase)|\(configuration.isHidden)|\(configuration.bssid ?? "")"
      guard !trimmedSSID.isEmpty, !seen.contains(deduplicationKey) else {
        continue
      }
      seen.insert(deduplicationKey)
      result.append(
        CameraVendorWifiNetworkConfiguration(
          ssid: trimmedSSID,
          passphrase: configuration.passphrase,
          isHidden: configuration.isHidden,
          bssid: configuration.bssid
        )
      )
    }
    return result
  }

  var wifiCandidates: [String] {
    wifiConfigurations.map(\.ssid)
  }
}

enum CameraVendorGalleryDiagnostics {
  static var externalLogHandler: ((String) -> Void)?

  static func log(_ message: String) {
    let safeMessage = CamTransferDiagnosticLogRedactor.redacted(message)
    print("CamTransferGallery \(safeMessage)")
    NSLog("CamTransferGallery %@", safeMessage)
    if CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(safeMessage) {
      CameraVendorFileLogger.log(safeMessage)
    }
    externalLogHandler?(safeMessage)
  }

  static func observe(_ message: String) {
    log("[OBS] \(message)")
  }

  static func readLogFile() -> String {
    (try? String(contentsOf: CameraVendorFileLogger.logFileURL)) ?? "(no log file)"
  }

  static func clearLogFile() {
    try? FileManager.default.removeItem(at: CameraVendorFileLogger.logFileURL)
  }

  static func composeFailureMessage(baseMessage: String, diagnostics: [String]) -> String {
    let lines = uniqueNonEmpty(diagnostics)
    guard !lines.isEmpty else {
      return baseMessage
    }
    return ([baseMessage, "诊断信息:"] + lines).joined(separator: "\n")
  }

  static func galleryReadFailureBaseMessage(
    errorDescription: String,
    didCompleteWifiHandoff: Bool
  ) -> String {
    if didCompleteWifiHandoff {
      return "无法读取相机图库。相机 Wi-Fi 已连接，但 PTP/相册初始化失败。原始错误: \(errorDescription)"
    }
    return "无法读取相机图库。相机 Wi-Fi 尚未完全就绪，请确认 iPhone 已连接相机 Wi-Fi 后返回 App 重试。原始错误: \(errorDescription)"
  }

  static func cameraWifiSuffix(from serialNumber: String) -> String? {
    let trimmed = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard trimmed.count >= 4 else {
      return nil
    }
    return String(trimmed.suffix(4))
  }

  static func uniqueNonEmpty(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !seen.contains(trimmed) else {
        continue
      }
      seen.insert(trimmed)
      result.append(trimmed)
    }
    return result
  }

  static func manualWifiJoinInstructions(for configuration: CameraVendorWifiNetworkConfiguration) -> [String] {
    var instructions = [
      "自动连接失败，请到系统设置手动加入相机 Wi-Fi。",
      "SSID: \(configuration.ssid)",
      "密码: \(configuration.passphrase)",
    ]
    if configuration.isHidden {
      instructions.append("这是隐藏网络；如果列表里看不到，请在 Wi‑Fi 的“其他...”里手动输入。")
    }
    instructions.append("连上后回到 CamTransfer，点“重新加载”。")
    return instructions
  }
}

enum CameraVendorGalleryPreparationPolicy {
  static let automaticWifiJoinEnabled = true

  static func shouldAttemptAutomaticWifiJoin(
    hasWifiConfigurations: Bool,
    prefersManualWifiRecovery: Bool
  ) -> Bool {
    automaticWifiJoinEnabled && hasWifiConfigurations && !prefersManualWifiRecovery
  }

  static func shouldPauseBeforeStartingPTP(
    didJoinWifiAutomatically: Bool,
    prefersManualWifiRecovery: Bool,
    skippedAutoJoinBecauseManual: Bool = false,
    currentSSIDMatchesCamera: Bool = false,
    isCameraPtpReachable: Bool = false,
    hasCurrentWifiConfigurations: Bool = true
  ) -> Bool {
    guard hasCurrentWifiConfigurations else {
      return true
    }
    if isCameraPtpReachable {
      return false
    }
    return true
  }

  static func shouldStopAutomaticWifiAttemptsAfterFailure(
    attemptedConfigurationIndex: Int
  ) -> Bool {
    attemptedConfigurationIndex == 0
  }
}

enum CameraVendorWifiHandoffCompletionPolicy {
  static func didCompleteWifiHandoff(
    hasConfirmedCameraNetwork: Bool,
    postJoinConfirmedCameraNetwork: Bool,
    didJoinWifiAutomatically: Bool,
    skippedAutoJoinBecauseManual: Bool,
    manualRecoveryNetworkEvidence: Bool,
    postJoinCameraPtpReachable: Bool
  ) -> Bool {
    if skippedAutoJoinBecauseManual {
      return manualRecoveryNetworkEvidence && postJoinCameraPtpReachable
    }
    if didJoinWifiAutomatically {
      return postJoinConfirmedCameraNetwork && postJoinCameraPtpReachable
    }
    return (hasConfirmedCameraNetwork || postJoinConfirmedCameraNetwork) && postJoinCameraPtpReachable
  }
}

enum CameraVendorPtpRouteStartPolicy {
  static func shouldStartPtpRoute(didCompleteWifiHandoff: Bool) -> Bool {
    didCompleteWifiHandoff
  }
}

enum CameraVendorGalleryPtpStartupPolicy {
  static func startupDelaySeconds(didCompleteWifiHandoff: Bool) -> TimeInterval {
    0
  }
}

struct CameraVendorOfficialGalleryPtpInitVariant: Equatable {
  let name: String
  let includesClientIP: Bool
}

struct CameraVendorOfficialGalleryPtpInitAttempt: Equatable {
  let name: String
  let packet: Data
  let timeout: TimeInterval
}

enum CameraVendorOfficialGalleryPtpInitPolicy {
  static let initAckTimeoutSeconds: TimeInterval = 12

  static func variants() -> [CameraVendorOfficialGalleryPtpInitVariant] {
    [
      CameraVendorOfficialGalleryPtpInitVariant(
        name: "CameraVendor legacy + client IP GUID",
        includesClientIP: true
      ),
      CameraVendorOfficialGalleryPtpInitVariant(
        name: "CameraVendor legacy",
        includesClientIP: false
      ),
    ]
  }

  static func initAttempts(
    clientName: String,
    clientIP: String?
  ) -> [CameraVendorOfficialGalleryPtpInitAttempt] {
    variants().map { variant in
      CameraVendorOfficialGalleryPtpInitAttempt(
        name: variant.name,
        packet: CameraVendorPtpPacketBuilder.buildInitCommandRequest(
          friendlyName: clientName,
          clientIP: variant.includesClientIP ? clientIP : nil
        ),
        timeout: initAckTimeoutSeconds
      )
    }
  }
}

enum CameraVendorWifiAssociationReadinessPolicy {
  static let maxWaitSeconds: TimeInterval = 8
  static let pollIntervalSeconds: TimeInterval = 0.25

  static func shouldWaitForCameraIPv4Address(
    didJoinWifiAutomatically: Bool,
    currentWifiIP: String?
  ) -> Bool {
    shouldWaitForCameraIPv4Address(
      didJoinWifiAutomatically: didJoinWifiAutomatically,
      hasConfirmedCameraNetwork: false,
      hasManualRecoveryNetworkEvidence: false,
      currentWifiIP: currentWifiIP
    )
  }

  static func shouldWaitForCameraIPv4Address(
    didJoinWifiAutomatically: Bool,
    hasConfirmedCameraNetwork: Bool,
    hasManualRecoveryNetworkEvidence: Bool,
    currentWifiIP: String?
  ) -> Bool {
    let hasAssociationEvidence = didJoinWifiAutomatically
      || hasConfirmedCameraNetwork
      || hasManualRecoveryNetworkEvidence
    return hasAssociationEvidence && !CameraVendorPtpConstants.isCameraWifiIPv4Address(currentWifiIP)
  }
}

enum CameraVendorPtpConnectionStartupPolicy {
  static let commandConnectTimeoutSeconds: TimeInterval = 1.5
  static let maxAttempts = 5

  static func retryDelaySeconds(afterFailedAttempt attempt: Int) -> TimeInterval {
    0.5 * TimeInterval(attempt)
  }

  static func shouldRetry(afterFailedAttempt attempt: Int) -> Bool {
    attempt < maxAttempts
  }
}

enum CameraVendorPtpReconnectErrorPolicy {
  static func shouldRetry(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "CameraVendorPtpSession", nsError.code == 0xD222 {
      return false
    }
    return true
  }
}

enum CameraVendorSearchModeDescRetryPolicy {
  static let maxAttempts = 3
  static let retryableResponseCode = 0x2019

  static func retryDelaySeconds(afterFailedAttempt attempt: Int) -> TimeInterval {
    0.5 * TimeInterval(attempt)
  }

  static func shouldRetry(error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "CameraVendorPtpSession" && nsError.code == retryableResponseCode
  }
}

enum CameraVendorSpecifiedObjectSnapshotPolicy {
  static let shouldCompareBeforeAndAfterEmptySearchMode = false
}

enum CameraVendorInitialCatalogBootstrapRecoveryPolicy {
  static let storeNotAvailableResponseCode = 0x2013

  static func shouldRecover(after error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "CameraVendorPtpSession"
      && nsError.code == storeNotAvailableResponseCode
  }
}

struct CameraVendorSpecifiedObjectDateGroup: Equatable {
  let dateText: String
  let objectCount: UInt32
}

enum CameraVendorSearchModeAllCondition: Equatable {
  case uint16(propertyCode: UInt16, value: UInt16)
}

enum CameraVendorWirelessRealFileFormat {
  static let heif: UInt16 = 0x3812
}

enum CameraVendorCatalogMembershipPolicy: Equatable {
  case direct
  case countSweepThenApply
  /// D604=X returns a broad directory; subtract the baseline (ALL) handles
  /// to isolate the format-specific handles that are NOT in the initial catalog.
  case subtractBaseline
}

struct CameraVendorCatalogQuery: Equatable {
  let conditions: [CameraVendorSearchModeAllCondition]
  let label: String
  let membershipPolicy: CameraVendorCatalogMembershipPolicy

  init(
    conditions: [CameraVendorSearchModeAllCondition],
    label: String,
    membershipPolicy: CameraVendorCatalogMembershipPolicy = .direct
  ) {
    self.conditions = conditions
    self.label = label
    self.membershipPolicy = membershipPolicy
  }
}

struct CameraVendorCatalogSnapshot: Equatable {
  let dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  let orderedHandles: [UInt32]
  let items: [CameraVendorGalleryItem]
}

struct CameraVendorCountSweepFormatCount {
  let label: String
  let mask: UInt16
  let count: UInt32?
}

struct CameraVendorCountSweepResult {
  let sweepCounts: [CameraVendorCountSweepFormatCount]
  let baselineHandleCount: Int
  let heifDeclaredCount: UInt32?
  let heifHandleCount: Int
  let heifHandles: [UInt32]
  let confirmReadback: Data

  var heifExact616: Bool {
    heifDeclaredCount == 616 && heifHandleCount == 616
  }

  var diagnosticSummary: String {
    let sweepSummary = sweepCounts.map { "\($0.label)=\($0.count.map(String.init) ?? "nil")" }.joined(separator: " ")
    return "[COUNT_SWEEP_RESULT] sweep=[\(sweepSummary)] " +
      "baseline=\(baselineHandleCount) " +
      "heif_declared=\(heifDeclaredCount.map(String.init) ?? "nil") " +
      "heif_handles=\(heifHandleCount) " +
      "exact_616=\(heifExact616) " +
      "readback_bytes=\(confirmReadback.count)"
  }
}

enum CameraVendorCatalogTransportEvidencePolicy {
  static func provesTransportLost(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "CameraVendorPtpSocket" {
      return true
    }
    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorCannotConnectToHost,
           NSURLErrorNetworkConnectionLost,
           NSURLErrorNotConnectedToInternet,
           NSURLErrorTimedOut:
        return true
      default:
        break
      }
    }
    let message = nsError.localizedDescription.lowercased()
    return message.contains("socket 未建立") ||
      message.contains("connection reset") ||
      message.contains("broken pipe")
  }
}

enum CameraVendorCatalogTransactionExecutor {
  static func execute<Output>(
    backup: () throws -> Data,
    perform: () throws -> Output,
    restore: (Data) throws -> Void
  ) throws -> Output {
    let savedSearchMode: Data
    do {
      savedSearchMode = try backup()
    } catch {
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(error)
      )
    }

    let primaryResult: Result<Output, Error>
    do {
      primaryResult = .success(try perform())
    } catch {
      primaryResult = .failure(error)
    }

    let restorationError: Error?
    do {
      try restore(savedSearchMode)
      restorationError = nil
    } catch {
      restorationError = error
    }

    switch (primaryResult, restorationError) {
    case let (.success(result), nil):
      return result
    case let (.success, restorationError?):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: "目录读取已完成，但 SearchMode 恢复失败",
        restorationMessage: restorationError.localizedDescription,
        provesTransportLost: true
      )
    case let (.failure(primaryError), nil):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: primaryError.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(primaryError)
      )
    case let (.failure(primaryError), restorationError?):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: primaryError.localizedDescription,
        restorationMessage: restorationError.localizedDescription,
        provesTransportLost: true
      )
    }
  }
}

enum CameraVendorSearchModeAllPayload {
  static let objectFormatPropertyCode: UInt16 = 0xD604
  static let jpegObjectFormatMask: UInt16 = 0x0001
  static let heifObjectFormatMask: UInt16 = 0x0002
  static let movObjectFormatMask: UInt16 = 0x0004
  static let mp4ObjectFormatMask: UInt16 = 0x0008
  static let rawObjectFormatMask: UInt16 = 0x0010

  static var stillImageObjectFormatMask: UInt16 {
    jpegObjectFormatMask | heifObjectFormatMask | rawObjectFormatMask
  }

  static var allObjectFormatMask: UInt16 {
    jpegObjectFormatMask | heifObjectFormatMask | movObjectFormatMask | mp4ObjectFormatMask | rawObjectFormatMask
  }

  static func objectFormatMaskPayload(_ mask: UInt16) -> Data {
    payload(for: [.uint16(propertyCode: objectFormatPropertyCode, value: mask)])
  }

  static func payload(for conditions: [CameraVendorSearchModeAllCondition]) -> Data {
    var data = Data()
    data.append(littleEndian(UInt32(conditions.count)))
    for condition in conditions {
      switch condition {
      case let .uint16(propertyCode, value):
        data.append(littleEndian(UInt32(8)))
        data.append(littleEndian(propertyCode))
        data.append(littleEndian(value))
      }
    }
    return data
  }

  private static func littleEndian(_ value: UInt16) -> Data {
    var little = value.littleEndian
    return withUnsafeBytes(of: &little) { Data($0) }
  }

  private static func littleEndian(_ value: UInt32) -> Data {
    var little = value.littleEndian
    return withUnsafeBytes(of: &little) { Data($0) }
  }
}

enum CameraVendorSearchModeAllReadback {
  static func uint16Value(propertyCode: UInt16, from data: Data) -> UInt16? {
    guard data.count >= 4 else { return nil }
    let count = Int(readUInt32LE(data, at: 0))
    guard count >= 0, count <= 32 else { return nil }
    var offset = 4
    for _ in 0..<count {
      guard offset + 8 <= data.count else { return nil }
      let recordLength = Int(readUInt32LE(data, at: offset))
      guard recordLength >= 8,
            offset + recordLength <= data.count else { return nil }
      let recordProperty = readUInt16LE(data, at: offset + 4)
      if recordProperty == propertyCode {
        return readUInt16LE(data, at: offset + 6)
      }
      offset += recordLength
    }
    return nil
  }

  private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }
}

enum CameraVendorCatalogSnapshotValidationPolicy {
  static func isPublishable(
    declaredCount: UInt32?,
    dateGroups: [CameraVendorSpecifiedObjectDateGroup],
    orderedHandles: [UInt32]
  ) -> Bool {
    guard declaredCount == UInt32(orderedHandles.count),
          dateGroups.reduce(UInt32(0), { $0 + $1.objectCount }) == UInt32(orderedHandles.count),
          Set(orderedHandles).count == orderedHandles.count else {
      return false
    }
    return true
  }
}

enum CameraVendorPtpCommandSerializationPolicy {
  static let shouldSerializeCommandSocketAccess = true
}

enum CameraVendorThumbnailLoadPolicy {
  static let shouldLoadSequentially = true
  static let shouldPauseWhileDownloading = true
  static let shouldInterruptInFlightRequestBeforeDownload = false
  static let shouldClosePtpSocketForPriorityDownloadInterruption = false
}

enum CameraVendorThumbnailTimingLogPolicy {
  static func successMessage(
    handle: Int,
    bytes: Int,
    ptpElapsedMs: Int,
    decodeElapsedMs: Int,
    totalElapsedMs: Int
  ) -> String {
    "[OBS] THUMBNAIL_TIMING_OK handle=0x\(String(format: "%08X", handle)) " +
      "bytes=\(bytes) ptpMs=\(ptpElapsedMs) decodeMs=\(decodeElapsedMs) totalMs=\(totalElapsedMs)"
  }

  static func failureMessage(handle: Int, elapsedMs: Int, errorDescription: String) -> String {
    "[OBS] THUMBNAIL_TIMING_FAILED handle=0x\(String(format: "%08X", handle)) " +
      "totalMs=\(elapsedMs) error=\(errorDescription)"
  }
}

enum CameraVendorPtpDiagnosticLogPolicy {
  private static let suppressedPrefixes = [
    "[OBS] PTP_GET_THUMB_REQUEST",
    "[OBS] PTP_GET_THUMB_DATA",
    "[OBS] PTP_THUMB_DATA",
    "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED",
    "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED_STANDARD",
    "[OBS] PTP_GET_THUMB_CONTEXT_PRIME_FAILED",
    "[OBS] PTP_GET_THUMB_VENDOR_CONTEXT_PRIME_FAILED",
    "[OBS] PTP_GET_THUMB_FALLBACK_TO_PARTIAL",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW_EXPECTED",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=download-data",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=download-data",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK",
    "[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE",
    "[OBS] PTP_DOWNLOAD",
    "[OBS] PTP_SOCKET_PACKET_READ",
    "[OBS] PTP_SOCKET_PAYLOAD_PROGRESS",
    "[OBS] THUMBNAIL_TIMING_OK",
    "等待 PTP 包头",
    "等待 CameraVendor legacy PTP 包头",
    "收到 PTP 包",
    "收到 CameraVendor legacy PTP 包",
    "收到 StartDataPacket",
    "收到数据包",
    "操作响应:",
    "CameraVendor 操作响应:",
  ]

  static func shouldEmit(_ message: String) -> Bool {
    if message.hasPrefix("[OBS] PTP_DOWNLOAD_DATA_TIMING") {
      return true
    }
    if message.hasPrefix("[OBS] PTP_DOWNLOAD_FILE_TIMING") {
      return true
    }
    return !suppressedPrefixes.contains { message.hasPrefix($0) }
  }
}

enum CameraVendorThumbnailPriorityDownloadPolicy {
  static func shouldContinueToPartialPreviewFallback(
    afterPriorityDownloadInterruption: Bool,
    isConnected: Bool
  ) -> Bool {
    !afterPriorityDownloadInterruption && isConnected
  }
}

enum CameraVendorPriorityDownloadThumbnailGatePolicy {
  static let suspendedThumbnailErrorCode = 19
}

enum CameraVendorPartialObjectRequestPolicy {
  /// Conservative default for formats/modes not yet verified against XApp.
  static let referenceAppInitialReadSize: UInt32 = 1 * 1_048_576
  static let fileDownloadReadSize: UInt32 = 4 * 1_048_576
  static let fileDownloadFallbackReadSize = referenceAppInitialReadSize
  static let fileDownloadReadTimeoutSeconds: TimeInterval = 60
  static let maxReadBytesWithoutKnownObjectSize = 128 * 1_024 * 1_024

  static func fileDownloadRequestSize(remaining: UInt64, useFallback: Bool = false) -> UInt32 {
    let preferredSize = useFallback ? fileDownloadFallbackReadSize : fileDownloadReadSize
    return UInt32(min(UInt64(preferredSize), remaining))
  }

  static func maximumReadableByteCount(expectedSize: UInt32?) -> UInt64 {
    if let expectedSize, expectedSize > 0 {
      return UInt64(expectedSize)
    }
    return UInt64(maxReadBytesWithoutKnownObjectSize)
  }

  static func extensionPartialObjectParameters(
    handle: UInt32,
    offset: UInt64 = 0,
    size: UInt32 = referenceAppInitialReadSize
  ) -> [UInt32] {
    [
      handle,
      UInt32(offset & 0xFFFF_FFFF),
      size,
      UInt32(offset >> 32),
    ]
  }

  static func standardPartialObjectParameters(
    handle: UInt32,
    offset: UInt64 = 0,
    size: UInt32 = referenceAppInitialReadSize
  ) -> [UInt32] {
    [
      handle,
      UInt32(offset & 0xFFFF_FFFF),
      size,
    ]
  }
}

private struct CameraVendorOriginalTransferCapabilityRecord: Codable, Equatable {
  let readSize: UInt32
  let updatedAt: Date
}

final class CameraVendorOriginalTransferCapabilityStore {
  private let defaults: UserDefaults
  private let storageKey = "cameraVendor.originalTransferCapability.v1"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func readSize(serialNumber: String?) -> UInt32? {
    guard let serial = normalizedSerialNumber(serialNumber),
          let record = records()[serial],
          CameraVendorTransferChunkProfile.isSupportedReadSize(record.readSize) else {
      return nil
    }
    return record.readSize
  }

  func persist(readSize: UInt32, serialNumber: String?) {
    guard let serial = normalizedSerialNumber(serialNumber),
          CameraVendorTransferChunkProfile.isSupportedReadSize(readSize) else {
      return
    }
    var updatedRecords = records()
    updatedRecords[serial] = CameraVendorOriginalTransferCapabilityRecord(
      readSize: readSize,
      updatedAt: Date()
    )
    guard let encoded = try? JSONEncoder().encode(updatedRecords) else { return }
    defaults.set(encoded, forKey: storageKey)
  }

  private func records() -> [String: CameraVendorOriginalTransferCapabilityRecord] {
    guard let data = defaults.data(forKey: storageKey),
          let decoded = try? JSONDecoder().decode(
            [String: CameraVendorOriginalTransferCapabilityRecord].self,
            from: data
          ) else {
      return [:]
    }
    return decoded
  }

  private func normalizedSerialNumber(_ serialNumber: String?) -> String? {
    let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !serial.isEmpty, serial != "-" else { return nil }
    return serial.uppercased()
  }
}

enum CameraVendorTransferChunkProfile {
  /// Observed in the XApp original-import trace: 12 MiB minus PTP overhead.
  static let maximumReadSize: UInt32 = 0x00BFFFE0

  static func preferredReadSize(cachedReadSize: UInt32?) -> UInt32 {
    guard let cachedReadSize, isSupportedReadSize(cachedReadSize) else {
      return maximumReadSize
    }
    return cachedReadSize
  }

  static func requestSize(remaining: UInt64, selectedReadSize: UInt32) -> UInt32 {
    UInt32(min(remaining, UInt64(selectedReadSize)))
  }

  static func isSupportedReadSize(_ readSize: UInt32) -> Bool {
    readSize == maximumReadSize ||
      readSize == CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize ||
      readSize == CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize
  }

  static func fallbackReadSize(after currentReadSize: UInt32) -> UInt32? {
    if currentReadSize > CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize {
      return CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    }
    if currentReadSize > CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize {
      return CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    }
    return nil
  }

  static func shouldFallback(after error: Error, sessionIsConnected: Bool) -> Bool {
    guard sessionIsConnected else { return false }
    let error = error as NSError
    return error.domain == "CameraVendorPtpSession" && (0x2000...0x2FFF).contains(error.code)
  }
}

enum CameraVendorOriginalTransferCompletionPolicy {
  static func shouldPersistCapability(
    totalBytes: Int,
    expectedBytes: UInt64?,
    hasJpegEndMarker: Bool
  ) -> Bool {
    if let expectedBytes {
      return totalBytes > 0 && UInt64(totalBytes) >= expectedBytes
    }
    return totalBytes > 0 && hasJpegEndMarker
  }
}

enum CameraVendorJpegDataPolicy {
  static func hasEndMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[data.count - 2] == 0xFF && data[data.count - 1] == 0xD9
  }

  static func hasStartMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
  }
}

enum CameraVendorPreviewImageValidationPolicy {
  private static let heifBrands: Set<Data> = [
    Data("heic".utf8),
    Data("heix".utf8),
    Data("hevc".utf8),
    Data("hevx".utf8),
    Data("heis".utf8),
    Data("hevm".utf8),
    Data("heif".utf8),
    Data("mif1".utf8),
    Data("msf1".utf8),
  ]

  static func isValidPreviewImageData(_ data: Data) -> Bool {
    isLikelyImageData(data) && !shouldRejectIncompletePartialPreview(data)
  }

  static func shouldRejectIncompletePartialPreview(_ data: Data) -> Bool {
    CameraVendorJpegDataPolicy.hasStartMarker(data) && !CameraVendorJpegDataPolicy.hasEndMarker(data)
  }

  private static func isLikelyImageData(_ data: Data) -> Bool {
    if CameraVendorJpegDataPolicy.hasStartMarker(data) { return true }
    guard data.count >= 12 else { return false }
    let ftyp = Data("ftyp".utf8)
    for index in data.indices.dropFirst(4) where index + 8 <= data.count {
      guard data[index..<(index + 4)] == ftyp else {
        continue
      }
      let brandStart = index + 4
      if heifBrands.contains(Data(data[brandStart..<(brandStart + 4)])) {
        return true
      }
    }
    return false
  }
}

enum CameraVendorDownloadDataDiagnosticPolicy {
  static let headByteCount = 32

  static func headHex(from data: Data, byteCount: Int = headByteCount) -> String {
    data.prefix(byteCount).map { String(format: "%02x", $0) }.joined()
  }

  static func firstFtypOffset(in data: Data) -> Int? {
    data.range(of: Data([0x66, 0x74, 0x79, 0x70]))?.lowerBound
  }
}

enum CameraVendorBleScanDiagnosticsPolicy {
  static let maxUnmatchedAdvertisementSamples = 12

  static func shouldLogUnmatchedAdvertisement(sampleCount: Int) -> Bool {
    sampleCount <= maxUnmatchedAdvertisementSamples
  }
}

struct CameraVendorAdaptiveDownloadChunkState: Equatable {
  var readSize: UInt32 = CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
  var consecutiveFastChunks: Int = 0
  var consecutiveSlowLargeChunks: Int = 0
  var lastSlowLargeBytesPerSecond: Double?
}

enum CameraVendorAdaptiveDownloadChunkPolicy {
  static let isEnabled = false
  static let slowChunkBytesPerSecond: Double = 1.2 * 1_048_576
  static let fastChunkBytesPerSecond: Double = 2.5 * 1_048_576
  static let fastChunksRequiredForUpgrade = 2
  static let slowLargeChunksRequiredForDowngrade = 1
  static let fallbackImprovementFactor = 1.15
  static let strategyName = "android-fixed-4mb"

  static func requestSize(remaining: UInt64, state: CameraVendorAdaptiveDownloadChunkState) -> UInt32 {
    UInt32(min(UInt64(state.readSize), remaining))
  }

  static func recordChunk(
    byteCount: Int,
    elapsedMs: Int,
    state: inout CameraVendorAdaptiveDownloadChunkState
  ) {
    guard isEnabled, byteCount > 0, elapsedMs > 0 else { return }
    let bytesPerSecond = Double(byteCount) / (Double(elapsedMs) / 1000.0)
    let largeReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    let fallbackReadSize = CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize

    if state.readSize >= largeReadSize {
      if bytesPerSecond < slowChunkBytesPerSecond {
        state.consecutiveSlowLargeChunks += 1
        state.lastSlowLargeBytesPerSecond = bytesPerSecond
        state.consecutiveFastChunks = 0
        if state.consecutiveSlowLargeChunks >= slowLargeChunksRequiredForDowngrade {
          state.readSize = fallbackReadSize
        }
      } else {
        state.consecutiveSlowLargeChunks = 0
        state.lastSlowLargeBytesPerSecond = nil
      }
      return
    }

    if let baseline = state.lastSlowLargeBytesPerSecond,
       bytesPerSecond < baseline * fallbackImprovementFactor {
      state.readSize = largeReadSize
      state.consecutiveFastChunks = 0
      state.consecutiveSlowLargeChunks = 0
      state.lastSlowLargeBytesPerSecond = nil
      return
    }

    if bytesPerSecond < slowChunkBytesPerSecond {
      state.consecutiveFastChunks = 0
      return
    }

    if bytesPerSecond > fastChunkBytesPerSecond {
      state.consecutiveFastChunks += 1
      if state.consecutiveFastChunks >= fastChunksRequiredForUpgrade {
        state.readSize = largeReadSize
        state.consecutiveSlowLargeChunks = 0
        state.lastSlowLargeBytesPerSecond = nil
      }
    } else {
      state.consecutiveFastChunks = 0
    }
  }
}

enum CameraVendorPtpSocketReadDiagnosticPolicy {
  static let progressIntervalBytes = 1 * 1_048_576

  static func shouldReportProgress(totalBytes: Int) -> Bool {
    totalBytes >= progressIntervalBytes
  }
}

private extension UInt32 {
  var nonzero: UInt32? {
    self == 0 ? nil : self
  }
}

enum CameraVendorImageDataNormalizer {
  static func imageData(from data: Data) -> Data {
    let jpeg = jpegData(from: data)
    if jpeg.count != data.count || (jpeg.count >= 2 && jpeg[0] == 0xFF && jpeg[1] == 0xD8) {
      return jpeg
    }
    return heifData(from: data)
  }

  static func jpegData(from data: Data) -> Data {
    guard data.count >= 2 else {
      return data
    }
    if data[0] == 0xFF, data[1] == 0xD8 {
      return data
    }
    guard let start = data.indices.dropLast().first(where: { index in
      data[index] == 0xFF && data[data.index(after: index)] == 0xD8
    }) else {
      return data
    }
    return data.subdata(in: start..<data.endIndex)
  }

  private static func heifData(from data: Data) -> Data {
    guard data.count >= 12 else {
      return data
    }
    let ftyp = Data([0x66, 0x74, 0x79, 0x70])
    let brands: Set<Data> = [
      Data("heic".utf8),
      Data("heix".utf8),
      Data("hevc".utf8),
      Data("hevx".utf8),
      Data("heis".utf8),
      Data("hevm".utf8),
      Data("heif".utf8),
      Data("mif1".utf8),
      Data("msf1".utf8),
    ]
    for index in data.indices.dropFirst(4) where index + 8 <= data.count {
      guard data[index..<(index + 4)] == ftyp else {
        continue
      }
      let brandStart = index + 4
      let brand = data[brandStart..<(brandStart + 4)]
      guard brands.contains(Data(brand)) else {
        continue
      }
      let boxStart = index - 4
      return data.subdata(in: boxStart..<data.endIndex)
    }
    return data
  }
}

enum CameraVendorReferenceAppGalleryReadyPolicy {
  static let readyMarker: UInt32 = 0x0992
  static let pcapObservedReadyMarker: UInt32 = 0x0993

  static func isReady(marker: UInt32?) -> Bool {
    marker == readyMarker || marker == pcapObservedReadyMarker
  }

  static func shouldContinueToLatestObjectProbe(marker: UInt32?) -> Bool {
    true
  }
}

enum CameraVendorGalleryHandshakeDiagnosticPolicy {
  static let fixedReferenceD212ReadCount = 2

  static func isD222ObservationOnly(
    hasSuccessfulPtpHandshake: Bool,
    marker: UInt32?
  ) -> Bool {
    hasSuccessfulPtpHandshake && !CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: marker)
  }
}

enum CameraVendorGalleryAssociationPreflight {
  private static func ssidMatchesCamera(
    _ currentSSID: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration]
  ) -> Bool {
    let normalizedCurrentSSID = currentSSID?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let normalizedCurrentSSID else { return false }
    return wifiConfigurations.contains {
      $0.ssid.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedCurrentSSID
    }
  }

  static func hasConfirmedCameraNetwork(
    currentSSID: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration],
    isCameraPtpReachable: Bool
  ) -> Bool {
    ssidMatchesCamera(currentSSID, wifiConfigurations: wifiConfigurations)
      || isCameraPtpReachable
  }

  static func hasManualRecoveryCameraNetworkEvidence(
    currentSSID: String?,
    currentIP: String?,
    manualPromptBaselineIP: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration]
  ) -> Bool {
    if ssidMatchesCamera(currentSSID, wifiConfigurations: wifiConfigurations) {
      return true
    }

    return CameraVendorPtpConstants.isCameraWifiIPv4Address(currentIP)
  }

  static func shouldSkipAutomaticWifiJoin(
    currentSSID: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration],
    isCameraPtpReachable: Bool
  ) -> Bool {
    guard !wifiConfigurations.isEmpty else {
      return false
    }
    return hasConfirmedCameraNetwork(
      currentSSID: currentSSID,
      wifiConfigurations: wifiConfigurations,
      isCameraPtpReachable: isCameraPtpReachable
    )
  }
}

enum CameraVendorGalleryReloadPolicy {
  static func shouldRetryWhenAppBecomesActive(
    itemCount: Int,
    isLoading: Bool,
    errorMessage: String?,
    currentWifiIP: String?,
    baselineWifiIP: String?,
    hasVerifiedConnectionHandoff: Bool = false
  ) -> Bool {
    !isLoading
      && itemCount == 0
      && errorMessage?.isEmpty == false
      && CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: currentWifiIP,
        baselineWifiIP: baselineWifiIP,
        itemCount: itemCount,
        isLoading: isLoading,
        hasVerifiedConnectionHandoff: hasVerifiedConnectionHandoff
      )
  }
}

struct CameraVendorPairedCameraRecord: Codable, Equatable {
  let peripheralID: UUID
  let deviceName: String
  let serialNumber: String
  let connectedDeviceName: String?
  let appVariant: CameraVendorAppVariant
  let preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?
  let systemBluetoothPairingValidatedAt: Date?

  init(
    peripheralID: UUID,
    deviceName: String,
    serialNumber: String,
    connectedDeviceName: String? = nil,
    appVariant: CameraVendorAppVariant,
    preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?,
    systemBluetoothPairingValidatedAt: Date? = nil
  ) {
    self.peripheralID = peripheralID
    self.deviceName = deviceName
    self.serialNumber = serialNumber
    self.connectedDeviceName = connectedDeviceName
    self.appVariant = appVariant
    self.preferredWifiNetwork = preferredWifiNetwork
    self.systemBluetoothPairingValidatedAt = systemBluetoothPairingValidatedAt
  }

  var connectionSummary: CameraVendorConnectionSummary {
    CameraVendorConnectionSummary(
      deviceName: deviceName,
      serialNumber: serialNumber,
      connectedDeviceName: connectedDeviceName ?? CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName(),
      preferredWifiNetwork: preferredWifiNetwork
    )
  }
}

enum CameraVendorStoredPairingPolicy {
  static func canEnterGallery(record: CameraVendorPairedCameraRecord) -> Bool {
    guard let wifi = record.preferredWifiNetwork else {
      return false
    }
    return !wifi.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !wifi.passphrase.isEmpty
  }

  static func hasVerifiedSystemBluetoothPairing(record: CameraVendorPairedCameraRecord) -> Bool {
    record.systemBluetoothPairingValidatedAt != nil
  }

  static func shouldRequireSystemBluetoothCleanupForUnverifiedRecord(
    _ record: CameraVendorPairedCameraRecord
  ) -> Bool {
    false
  }

  static func matchesRememberedIdentity(
    record: CameraVendorPairedCameraRecord,
    summary: CameraVendorConnectionSummary,
    peripheralID: UUID?
  ) -> Bool {
    let rememberedCameraID = cameraID(
      serialNumber: record.serialNumber,
      deviceName: record.deviceName,
      peripheralID: record.peripheralID,
      wifiSSID: record.preferredWifiNetwork?.ssid
    )
    let candidateCameraID = cameraID(
      serialNumber: summary.serialNumber,
      deviceName: summary.deviceName,
      peripheralID: peripheralID,
      wifiSSID: summary.wifiConfigurations.first?.ssid
    )
    if isOfficialCameraID(rememberedCameraID), isOfficialCameraID(candidateCameraID) {
      return rememberedCameraID == candidateCameraID
    }

    let rememberedSerial = normalizedIdentity(record.serialNumber)
    let connectedSerial = normalizedIdentity(summary.serialNumber)
    if !rememberedSerial.isEmpty, !connectedSerial.isEmpty {
      return rememberedSerial == connectedSerial
    }

    let rememberedEndpoint = normalizedEndpoint(record.peripheralID)
    let connectedEndpoint = normalizedEndpoint(peripheralID)
    if !rememberedEndpoint.isEmpty, !connectedEndpoint.isEmpty {
      return rememberedEndpoint == connectedEndpoint
    }

    let rememberedName = normalizedIdentity(record.deviceName)
    let connectedName = normalizedIdentity(summary.deviceName)
    return !rememberedName.isEmpty
      && !connectedName.isEmpty
      && rememberedName == connectedName
  }

  private static func cameraID(
    serialNumber: String?,
    deviceName: String?,
    peripheralID: UUID?,
    wifiSSID: String?
  ) -> String {
    let serial = normalizedIdentity(serialNumber)
    let name = normalizedIdentity(deviceName)
    if !serial.isEmpty, !name.isEmpty {
      return "\(serial)_\(name)"
    }

    return [
      serial,
      name,
      normalizedEndpoint(peripheralID),
      normalizedIdentity(wifiSSID),
    ].first(where: { !$0.isEmpty }) ?? ""
  }

  private static func normalizedIdentity(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func normalizedEndpoint(_ value: UUID?) -> String {
    value?.uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
  }

  private static func isOfficialCameraID(_ value: String) -> Bool {
    value.contains("_")
  }
}

final class CameraVendorPairedCameraStore {
  static let storageKey = "CamTransfer.LastPairedCamera"
  static let listStorageKey = "CamTransfer.PairedCameras"

  private let defaults: UserDefaults
  private let legacyStorageKey: String
  private let listStorageKey: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = CameraVendorPairedCameraStore.storageKey,
    listStorageKey: String? = nil
  ) {
    self.defaults = defaults
    self.legacyStorageKey = storageKey
    if let listStorageKey {
      self.listStorageKey = listStorageKey
    } else if storageKey == CameraVendorPairedCameraStore.storageKey {
      self.listStorageKey = CameraVendorPairedCameraStore.listStorageKey
    } else {
      self.listStorageKey = "\(storageKey).List"
    }
  }

  func load() -> CameraVendorPairedCameraRecord? {
    loadAll().first
  }

  func loadAll() -> [CameraVendorPairedCameraRecord] {
    if let data = defaults.data(forKey: listStorageKey) {
      guard let records = try? decoder.decode([CameraVendorPairedCameraRecord].self, from: data) else {
        defaults.removeObject(forKey: listStorageKey)
        return loadLegacyRecord().map { [$0] } ?? []
      }
      return unique(records)
    }

    guard let legacyRecord = loadLegacyRecord() else {
      return []
    }
    saveAll([legacyRecord])
    defaults.removeObject(forKey: legacyStorageKey)
    return [legacyRecord]
  }

  func save(_ record: CameraVendorPairedCameraRecord) {
    var records = loadAll().filter { !isSameCamera($0, record) }
    records.insert(record, at: 0)
    saveAll(records)
  }

  func remove(peripheralID: UUID) {
    saveAll(loadAll().filter { $0.peripheralID != peripheralID })
  }

  func clear() {
    defaults.removeObject(forKey: listStorageKey)
    defaults.removeObject(forKey: legacyStorageKey)
  }

  private func loadLegacyRecord() -> CameraVendorPairedCameraRecord? {
    guard let data = defaults.data(forKey: legacyStorageKey) else {
      return nil
    }

    guard let record = try? decoder.decode(CameraVendorPairedCameraRecord.self, from: data) else {
      defaults.removeObject(forKey: legacyStorageKey)
      return nil
    }

    return record
  }

  private func saveAll(_ records: [CameraVendorPairedCameraRecord]) {
    let cleaned = unique(records)
    guard !cleaned.isEmpty else {
      clear()
      return
    }
    guard let data = try? encoder.encode(cleaned) else { return }
    defaults.set(data, forKey: listStorageKey)
    defaults.removeObject(forKey: legacyStorageKey)
  }

  private func unique(_ records: [CameraVendorPairedCameraRecord]) -> [CameraVendorPairedCameraRecord] {
    var result: [CameraVendorPairedCameraRecord] = []
    for record in records where !result.contains(where: { isSameCamera($0, record) }) {
      result.append(record)
    }
    return result
  }

  private func isSameCamera(
    _ lhs: CameraVendorPairedCameraRecord,
    _ rhs: CameraVendorPairedCameraRecord
  ) -> Bool {
    if lhs.peripheralID == rhs.peripheralID {
      return true
    }
    let leftSerial = lhs.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    let rightSerial = rhs.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    return !leftSerial.isEmpty && leftSerial != "-" && leftSerial == rightSerial
  }
}

enum CameraVendorRememberedPairingPolicy {
  static func shouldSkipManualPairingConfirmation(
    rememberedPeripheralID: UUID?,
    selectedPeripheralID: UUID?
  ) -> Bool {
    guard let rememberedPeripheralID, let selectedPeripheralID else {
      return false
    }
    return rememberedPeripheralID == selectedPeripheralID
  }

  static func shouldBypassManualConfirmation(
    isRememberedPeripheral: Bool,
    isAlreadyPairedIdentificationNumber: Bool
  ) -> Bool {
    isRememberedPeripheral
  }
}

enum CameraVendorRememberedPairingConsistencyPolicy {
  static func isStalePairingCandidate(
    record: CameraVendorPairedCameraRecord,
    camera: CameraVendorDiscoveredCamera
  ) -> Bool {
    guard record.peripheralID != camera.id else {
      return false
    }

    let rememberedName = normalized(record.deviceName)
    let discoveredName = normalized(camera.name)
    return !rememberedName.isEmpty && rememberedName == discoveredName
  }

  static func stalePairingCandidate(
    records: [CameraVendorPairedCameraRecord],
    cameras: [CameraVendorDiscoveredCamera]
  ) -> (record: CameraVendorPairedCameraRecord, camera: CameraVendorDiscoveredCamera)? {
    for camera in cameras {
      if let record = records.first(where: { isStalePairingCandidate(record: $0, camera: camera) }) {
        return (record, camera)
      }
    }
    return nil
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }
}

enum CameraVendorFreshPairingRegistrationPolicy {
  static func shouldRequireSystemBluetoothCleanup(
    hasRememberedRecord: Bool,
    isAlreadyPairedIdentificationNumber: Bool
  ) -> Bool {
    isAlreadyPairedIdentificationNumber && !hasRememberedRecord
  }
}

enum CameraVendorRememberedReconnectPolicy {
  static let shouldStartNormalDiscoveryAfterTargetTimeout = false
  static let shouldTrySystemRetrievedPeripheralBeforeScanning = false
}

enum CameraVendorConnectionResetPolicy {
  static func shouldSkipPassiveResetDuringTransferHandoff(
    force: Bool,
    didCompleteHandshakeCallback: Bool,
    hasCompletedPairing: Bool,
    hasUserInitiatedTransfer: Bool,
    hasPendingHandshakeSummary: Bool,
    isRunningTransferActivation: Bool,
    awaitingBluetoothDisconnectForWifiHandoff: Bool,
    awaitingTransferActivationStateChange: Bool
  ) -> Bool {
    guard !force else { return false }
    if isRunningTransferActivation || awaitingBluetoothDisconnectForWifiHandoff || awaitingTransferActivationStateChange {
      return true
    }
    return !didCompleteHandshakeCallback
      && hasCompletedPairing
      && hasUserInitiatedTransfer
      && hasPendingHandshakeSummary
  }
}

enum CameraVendorGalleryLoadPolicy {
  static let shouldLoadAutomaticallyOnEntry = false
  static let shouldRetryAutomaticallyWhenAppBecomesActive = false

  static func shouldStartLoad(
    isLoading: Bool,
    hasVerifiedConnectionHandoff: Bool = true
  ) -> Bool {
    !isLoading && hasVerifiedConnectionHandoff
  }

  static func shouldAllowManualReload(
    currentWifiIP: String?,
    hasVerifiedConnectionHandoff: Bool = false
  ) -> Bool {
    hasVerifiedConnectionHandoff && CameraVendorPtpConstants.isCameraWifiIPv4Address(currentWifiIP)
  }

  static func shouldLoadOnEntry(hasVerifiedConnectionHandoff: Bool) -> Bool {
    false
  }

  static func shouldAutoLoadWhenCameraWifiReady(
    currentWifiIP: String?,
    baselineWifiIP: String?,
    itemCount: Int,
    isLoading: Bool,
    hasVerifiedConnectionHandoff: Bool = false
  ) -> Bool {
    false
  }
}

enum CameraVendorTransferActivationStatusTextPolicy {
  static let enteringGalleryStatus = "正在进入相机相册"
  static let readyToEnterGalleryStatus = "相机 Wi‑Fi 已启动，正在进入相册"
}

enum CameraVendorCameraPairingConfirmationPolicy {
  static let waitingForPhoneConfirmationStatus = "相机确认后，请在手机上确认"
}

enum CameraVendorBluetoothConnectFailurePolicy {
  private static let cleanupRequiredTokens = [
    "peer removed pairing information",
    "insufficient encryption",
    "authentication",
    "encryption",
  ]

  static func requiresSystemBluetoothPairingCleanup(for errorDescription: String?) -> Bool {
    let value = normalized(errorDescription)
    return cleanupRequiredTokens.contains { value.contains($0) }
  }

  static func shouldClearRememberedPairing(for errorDescription: String?) -> Bool {
    requiresSystemBluetoothPairingCleanup(for: errorDescription)
  }

  static func userFacingStatus(for errorDescription: String?) -> String {
    if requiresSystemBluetoothPairingCleanup(for: errorDescription) {
      return CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    }

    return "连接失败"
  }

  private static func normalized(_ errorDescription: String?) -> String {
    errorDescription?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
  }
}

enum CameraVendorSystemBluetoothPairingCleanupPolicy {
  private static let cleanupRequiredKey = "camtransfer.systemBluetoothPairingCleanupRequired"
  private static let cleanupReasonKey = "camtransfer.systemBluetoothPairingCleanupReason"

  static let requiredCleanupStatus = "请先删除本地蓝牙配对：在 iPhone 设置 > 蓝牙里忽略这台相机，再重新配对"

  static func requiresCleanup(defaults: UserDefaults = .standard) -> Bool {
    clearLegacyUnverifiedRecordMisclassificationIfNeeded(defaults: defaults)
    return defaults.bool(forKey: cleanupRequiredKey)
  }

  static func markCleanupRequired(reason: String, defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: cleanupRequiredKey)
    defaults.set(reason, forKey: cleanupReasonKey)
  }

  static func clearCleanupRequired(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: cleanupRequiredKey)
    defaults.removeObject(forKey: cleanupReasonKey)
  }

  private static func clearLegacyUnverifiedRecordMisclassificationIfNeeded(
    defaults: UserDefaults
  ) {
    let reason = defaults.string(forKey: cleanupReasonKey) ?? ""
    guard reason.hasPrefix("已配对记录缺少系统蓝牙有效性校验") else {
      return
    }
    clearCleanupRequired(defaults: defaults)
  }
}

enum CameraVendorTransferActivationFailureStatusPolicy {
  static let activationFailedStatus = "相机未进入传图模式，请确认相机已允许传图后重试"
}

enum CameraVendorWifiJoinDiagnostics {
  static let shouldRemoveExistingConfigurationBeforeJoin = false
  static let applyCallbackTimeoutSeconds: TimeInterval = 8
  static let applyCallbackTimeoutErrorDomain = "CameraVendorWifiApply"

  static func describeHotspotError(_ error: NSError) -> String {
    var message = "\(error.domain) code=\(error.code) \(error.localizedDescription)"
    guard error.domain == NEHotspotConfigurationErrorDomain,
          let hotspotError = NEHotspotConfigurationError(rawValue: error.code) else {
      return message
    }

    message += " | hotspot=\(label(for: hotspotError))"
    return message
  }

  static func label(for error: NEHotspotConfigurationError) -> String {
    switch error {
    case .invalid:
      return "invalid"
    case .invalidSSID:
      return "invalidSSID"
    case .invalidWPAPassphrase:
      return "invalidWPAPassphrase"
    case .invalidWEPPassphrase:
      return "invalidWEPPassphrase"
    case .invalidEAPSettings:
      return "invalidEAPSettings"
    case .invalidHS20Settings:
      return "invalidHS20Settings"
    case .invalidHS20DomainName:
      return "invalidHS20DomainName"
    case .userDenied:
      return "userDenied"
    case .internal:
      return "internal"
    case .pending:
      return "pending"
    case .systemConfiguration:
      return "systemConfiguration"
    case .unknown:
      return "unknown"
    case .joinOnceNotSupported:
      return "joinOnceNotSupported"
    case .alreadyAssociated:
      return "alreadyAssociated"
    case .applicationIsNotInForeground:
      return "applicationIsNotInForeground"
    case .invalidSSIDPrefix:
      return "invalidSSIDPrefix"
    case .userUnauthorized:
      return "userUnauthorized"
    case .systemDenied:
      return "systemDenied"
    @unknown default:
      return "unrecognized"
    }
  }

  static func shouldContinueAssociationCheck(after error: NSError) -> Bool {
    if isApplyCallbackTimeout(error) {
      return true
    }

    guard error.domain == NEHotspotConfigurationErrorDomain else {
      return false
    }

    return error.code == NEHotspotConfigurationError.internal.rawValue
      || error.code == NEHotspotConfigurationError.pending.rawValue
      || error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
  }

  static func applyCallbackTimeoutError(ssid: String) -> NSError {
    NSError(
      domain: applyCallbackTimeoutErrorDomain,
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "等待系统 Wi-Fi 连接回调超时，继续确认当前是否已切换到 \(ssid)"
      ]
    )
  }

  static func isApplyCallbackTimeout(_ error: NSError) -> Bool {
    error.domain == applyCallbackTimeoutErrorDomain && error.code == 1
  }

  static func associationTimeout(after error: NSError?) -> TimeInterval {
    guard let error else { return 15 }
    return shouldContinueAssociationCheck(after: error) ? 15 : 15
  }

  static func shouldAllowUnverifiedAssociation(
    requested: Bool,
    targetSSID: String,
    currentSSID: String?
  ) -> Bool {
    guard requested else {
      return false
    }

    return CameraVendorWifiAssociationReadiness.isReadyToProceed(
      targetSSID: targetSSID,
      currentSSID: currentSSID,
      isCameraPtpReachable: false
    )
  }

  static func shouldRequestLocationAuthorization(for status: CLAuthorizationStatus) -> Bool {
    status == .notDetermined
  }

  static func canReadCurrentSSID(with status: CLAuthorizationStatus) -> Bool {
    status == .authorizedAlways || status == .authorizedWhenInUse
  }

  static func describeLocationAuthorizationStatus(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    case .denied:
      return "denied"
    case .authorizedAlways:
      return "authorizedAlways"
    case .authorizedWhenInUse:
      return "authorizedWhenInUse"
    @unknown default:
      return "unknown"
    }
  }
}

enum CameraVendorWifiHandoffStabilizationPolicy {
  static let delayAfterSSIDAssociationSeconds: TimeInterval = 0
}

enum CameraVendorWifiAssociationReadiness {
  static func isReadyToProceed(
    targetSSID: String,
    currentSSID: String?,
    isCameraPtpReachable: Bool
  ) -> Bool {
    let normalizedTargetSSID = targetSSID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedCurrentSSID = currentSSID?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if normalizedCurrentSSID == normalizedTargetSSID {
      return true
    }

    return false
  }
}

enum CameraVendorMainThread {
  static func run(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}

enum CameraVendorReferenceAppNetworkConfigDecoder {
  static let ssidCharacteristicUUIDString = "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4"
  static let passphraseCharacteristicUUIDString = "E809256A-915C-4967-92E8-53B7D4CAD213"
  static let macAddressCharacteristicUUIDString = "49A12959-DFAA-4EB2-89CE-62548AD948F3"

  static func networkConfiguration(from characteristicValues: [String: Data]) -> CameraVendorWifiNetworkConfiguration? {
    guard
      let ssid = decodedString(
        from: characteristicValues[ssidCharacteristicUUIDString]
      ),
      let passphrase = decodedString(
        from: characteristicValues[passphraseCharacteristicUUIDString]
      )
    else {
      return nil
    }

    return CameraVendorWifiNetworkConfiguration(
      ssid: ssid,
      passphrase: passphrase,
      isHidden: false,
      bssid: decodedBSSID(from: characteristicValues[macAddressCharacteristicUUIDString])
    )
  }

  static func normalizedBSSID(from value: String?) -> String? {
    let hex = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .filter { $0.isLetter || $0.isNumber }
      .lowercased() ?? ""
    guard hex.count == 12,
          hex.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
      return nil
    }
    return stride(from: 0, to: hex.count, by: 2)
      .map { index in
        let start = hex.index(hex.startIndex, offsetBy: index)
        let end = hex.index(start, offsetBy: 2)
        return String(hex[start..<end])
      }
      .joined(separator: ":")
  }

  private static func decodedBSSID(from data: Data?) -> String? {
    guard let data else { return nil }
    if data.count >= 6 {
      return data.prefix(6)
        .map { String(format: "%02x", $0) }
        .joined(separator: ":")
    }
    return decodedString(from: data).flatMap(normalizedBSSID(from:))
  }

  private static func decodedString(from data: Data?) -> String? {
    guard let data else {
      return nil
    }

    let trimmedData = Data(data.prefix { $0 != 0x00 })
    guard !trimmedData.isEmpty else {
      return nil
    }

    let decoded = String(data: trimmedData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded, !decoded.isEmpty else {
      return nil
    }

    return decoded
  }
}

struct CameraVendorBleWriteRequest: Equatable {
  let characteristicUUIDString: String
  let payload: Data
}

enum CameraVendorReferenceAppTransferActivationStrategy: String, CaseIterable {
  case officialImportImage = "Official Import Image"
  case preferredRemoteImageView = "Legacy Remote Image View (mode 20)"
  case compatibleRemoteImageView = "Legacy Remote Image View (mode 11)"
}

enum CameraVendorGalleryRouteID: String, CaseIterable {
  case strictReferenceApp = "strict-reference-app"
  case importImageLaunch = "import-image-launch"
  case referenceAppLongSettle = "reference-app-long-settle"
  case referenceAppBleDisconnectVariant = "reference-app-ble-disconnect-variant"
}

struct CameraVendorGalleryRoute: Equatable {
  let id: CameraVendorGalleryRouteID
  let launchRequestPayload: Data
  let ptpStartupDelaySeconds: TimeInterval
  let allowsUnverifiedWifiHandoffAfterRecoverableError: Bool
}

enum CameraVendorGalleryRoutePolicy {
  // ReferenceApp's WlanConnectImageImport retry path uses InCameraViewIng = 3
  // before handing over to Wi-Fi for camera image browsing; PTP starts as soon
  // as Wi-Fi is available.
  static let hiddenDiagnosticRoutes: [CameraVendorGalleryRoute] = [
    CameraVendorGalleryRoute(
      id: .strictReferenceApp,
      launchRequestPayload: Data([0x03, 0x00]),
      ptpStartupDelaySeconds: 0,
      allowsUnverifiedWifiHandoffAfterRecoverableError: false
    ),
  ]

  static var strictReferenceAppLaunchRequestPayload: Data {
    hiddenDiagnosticRoutes.first?.launchRequestPayload ?? Data([0x03, 0x00])
  }

  static func shouldStopRouteSearch(after items: [CameraVendorGalleryItem]) -> Bool {
    !items.isEmpty
  }
}

enum CameraVendorReferenceAppApState: Equatable {
  case notLaunched
  case launched
  case launching
  case launchedForReservedImageTransfer
  case unknown(UInt16)

  init?(data: Data) {
    guard data.count >= 2 else {
      return nil
    }

    let rawValue = UInt16(data[0]) | (UInt16(data[1]) << 8)
    switch rawValue {
    case 0x8000:
      self = .notLaunched
    case 0x8001:
      self = .launched
    case 0x8002:
      self = .launching
    case 0x8003:
      self = .launchedForReservedImageTransfer
    default:
      self = .unknown(rawValue)
    }
  }

  var isReadyToJoinWifi: Bool {
    switch self {
    case .launched, .launchedForReservedImageTransfer:
      return true
    case .notLaunched, .launching, .unknown:
      return false
    }
  }

  var isReadyForGalleryImport: Bool {
    switch self {
    case .launchedForReservedImageTransfer:
      return true
    case .notLaunched, .launched, .launching, .unknown:
      return false
    }
  }

  var debugName: String {
    switch self {
    case .notLaunched:
      return "NotLaunched(0x8000)"
    case .launched:
      return "Launched(0x8001)"
    case .launching:
      return "Launching(0x8002)"
    case .launchedForReservedImageTransfer:
      return "LaunchedForReservedImageTransfer(0x8003)"
    case .unknown(let rawValue):
      return String(format: "Unknown(0x%04X)", rawValue)
    }
  }
}

enum CameraVendorReferenceAppTransferState: Equatable {
  case untransferable
  case transferable
  case unknown(UInt16)

  init?(data: Data) {
    guard data.count >= 2 else {
      return nil
    }

    let rawValue = UInt16(data[0]) | (UInt16(data[1]) << 8)
    switch rawValue {
    case 0x8000:
      self = .untransferable
    case 0x8001:
      self = .transferable
    default:
      self = .unknown(rawValue)
    }
  }

  var debugName: String {
    switch self {
    case .untransferable:
      return "UnTransferable(0x8000)"
    case .transferable:
      return "Transferable(0x8001)"
    case .unknown(let rawValue):
      return String(format: "Unknown(0x%04X)", rawValue)
    }
  }
}

enum CameraVendorReferenceAppTransferActivationPlan {
  static let connectedDeviceImageReceiveStateCharacteristicUUIDString = "A80BE3F8-8BCB-4ADD-A725-170B7A53ADC9"
  static let imageTransferSettingCharacteristicUUIDString = "CAEDB497-83BF-482C-91EF-91CF6F1216FF"
  static let imageTransferSettingExCharacteristicUUIDString = "98934B2C-756C-4632-AA2F-DCBA1BFEC824"
  static let imageResizeSettingCharacteristicUUIDString = "82A9F452-C5CE-4EF5-8203-3FC9A47F8171"
  static let launchRequestCharacteristicUUIDString = "600655E6-3637-42F1-8FB2-44EFC5C63B13"
  static let apStateCharacteristicUUIDString = "A68E3F66-0FCC-4395-8D4C-AA980B5877FA"
  static let transferStateCharacteristicUUIDString = "BD17BA04-B76B-4892-A545-B73BA1F74DAE"
  static let actionCommandCharacteristicUUIDString = "68052E8A-FB91-404F-8847-0EB4BE24308C"
  static let modeCommandCharacteristicUUIDString = "051DD980-DF9D-4472-A2E1-35811DD24EE1"
  static let legacyTrackedStatusCharacteristicUUIDStrings = [
    apStateCharacteristicUUIDString,
    "E3FBBFCF-F326-4B0F-82CF-B00AE1B107A2",
    "2E27ED9F-5506-41CD-BA48-DAC06669AD95",
    "7F3400FE-17E7-4B80-8A0E-81B0343C1B49",
    "F90F7D3A-3B64-45C6-AB21-933900184837",
    "7170FD5A-56D9-4C19-B043-7A7047D8E1A0",
  ]

  static func writes(for strategy: CameraVendorReferenceAppTransferActivationStrategy) -> [CameraVendorBleWriteRequest] {
    switch strategy {
    case .officialImportImage:
      return [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: imageTransferSettingCharacteristicUUIDString,
          payload: Data([0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: imageTransferSettingExCharacteristicUUIDString,
          payload: Data([0x01])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: imageResizeSettingCharacteristicUUIDString,
          payload: CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: launchRequestCharacteristicUUIDString,
          payload: CameraVendorGalleryRoutePolicy.strictReferenceAppLaunchRequestPayload
        )
      ]
    case .preferredRemoteImageView:
      return legacyWrites(ptpMode: 20)
    case .compatibleRemoteImageView:
      return legacyWrites(ptpMode: 11)
    }
  }

  static func trackedStatusCharacteristicUUIDStrings(
    for strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> [String] {
    switch strategy {
    case .officialImportImage:
      return [apStateCharacteristicUUIDString, transferStateCharacteristicUUIDString]
    case .preferredRemoteImageView, .compatibleRemoteImageView:
      return legacyTrackedStatusCharacteristicUUIDStrings
    }
  }

  static func supportedStrategies(
    forAvailableCharacteristicUUIDStrings availableCharacteristicUUIDStrings: Set<String>
  ) -> [CameraVendorReferenceAppTransferActivationStrategy] {
    [
      .officialImportImage,
    ].filter { strategy in
      requiredCharacteristicUUIDStrings(for: strategy).isSubset(of: availableCharacteristicUUIDStrings)
    }
  }

  static func isModeCommandCharacteristic(uuidString: String) -> Bool {
    uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      == modeCommandCharacteristicUUIDString
  }

  static func isActivationCommandCharacteristic(uuidString: String) -> Bool {
    let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return normalized == connectedDeviceImageReceiveStateCharacteristicUUIDString
      || normalized == imageTransferSettingCharacteristicUUIDString
      || normalized == imageTransferSettingExCharacteristicUUIDString
      || normalized == imageResizeSettingCharacteristicUUIDString
      || normalized == launchRequestCharacteristicUUIDString
      || normalized == actionCommandCharacteristicUUIDString
      || normalized == modeCommandCharacteristicUUIDString
  }

  static func isTrackedStatusCharacteristic(
    uuidString: String,
    for strategy: CameraVendorReferenceAppTransferActivationStrategy?
  ) -> Bool {
    guard let strategy else {
      return false
    }

    return trackedStatusCharacteristicUUIDStrings(for: strategy).contains(
      uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    )
  }

  static func isReadyToJoinWifi(
    uuidString: String,
    value: Data,
    for strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> Bool {
    let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalized == apStateCharacteristicUUIDString,
          let apState = CameraVendorReferenceAppApState(data: value) else {
      return false
    }

    switch strategy {
    case .officialImportImage:
      return apState.isReadyToJoinWifi
    case .preferredRemoteImageView, .compatibleRemoteImageView:
      return apState.isReadyToJoinWifi
    }
  }

  static func debugStatusDescription(uuidString: String, value: Data) -> String? {
    let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if normalized == apStateCharacteristicUUIDString,
       let apState = CameraVendorReferenceAppApState(data: value) {
      return "APState=\(apState.debugName)"
    }
    if normalized == transferStateCharacteristicUUIDString,
       let transferState = CameraVendorReferenceAppTransferState(data: value) {
      return "TransferState=\(transferState.debugName)"
    }
    return nil
  }

  private static func requiredCharacteristicUUIDStrings(
    for strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> Set<String> {
    switch strategy {
    case .officialImportImage:
      return [
        imageResizeSettingCharacteristicUUIDString,
        imageTransferSettingCharacteristicUUIDString,
        imageTransferSettingExCharacteristicUUIDString,
        launchRequestCharacteristicUUIDString,
      ]
    case .preferredRemoteImageView, .compatibleRemoteImageView:
      return [
        actionCommandCharacteristicUUIDString,
        modeCommandCharacteristicUUIDString,
      ]
    }
  }

  private static func legacyWrites(ptpMode: UInt32) -> [CameraVendorBleWriteRequest] {
    [
      CameraVendorBleWriteRequest(
        characteristicUUIDString: actionCommandCharacteristicUUIDString,
        payload: littleEndianPayload(UInt16(2))
      ),
      CameraVendorBleWriteRequest(
        characteristicUUIDString: modeCommandCharacteristicUUIDString,
        payload: littleEndianPayload(ptpMode)
      )
    ]
  }

  private static func littleEndianPayload(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  private static func littleEndianPayload(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }
}

enum CameraVendorBleStateSamplingPlan {
  static let sampleDelaysSeconds: [TimeInterval] = []
  static let shouldDelayGalleryUntilSamplingCompletes = false
  static let characteristicUUIDStrings: [String] = []
}

enum CameraVendorBleBackgroundKeepAlivePolicy {
  static let intervalSeconds: TimeInterval = 8
  static let readSpacingSeconds: TimeInterval = 0.08
  static let preferredReadableCharacteristicUUIDStrings: [String] = [
    CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
    CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
    CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
    CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
    "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4",
    "BD45F887-A6BE-4CB7-8565-390DF38BF5BF",
    "AAB609C4-94DD-4D89-BC60-665D5090B828",
    "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B",
    "75823784-FBB7-4B71-ABAE-CD9A34072E3C",
    CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
    CameraVendorReferenceAppNetworkConfigDecoder.ssidCharacteristicUUIDString,
    "00002A00-0000-1000-8000-00805F9B34FB",
    "00002A25-0000-1000-8000-00805F9B34FB",
    "00002A26-0000-1000-8000-00805F9B34FB",
  ]
}

enum CameraVendorTransferActivationResizePolicy {
  static let resizeDisabledPayload = Data([0x00])
  /// Camera-side downsize. The exact mapping is firmware specific; on
  /// DEVICE-A / DEVICE-B the value 0x01 produces a "S" sized JPG (~3M) regardless
  /// of the in-camera setting, while preserving image quality. This is
  /// the same path CameraVendor's own "transfer compressed" toggle uses.
  static let resizeEnabledPayload = Data([0x01])
  static let postWriteDelaySeconds: TimeInterval = 0.5

  private static let preferenceKey = "camtransfer.downloadCompressionEnabled"

  static var preferCompressedDownloads: Bool {
    get {
      guard UserDefaults.standard.object(forKey: preferenceKey) != nil else {
        return true
      }
      return UserDefaults.standard.bool(forKey: preferenceKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
  }

  static var currentPayload: Data {
    preferCompressedDownloads ? resizeEnabledPayload : resizeDisabledPayload
  }
}

enum CameraVendorTransferDownloadMode: Equatable {
  case original
  case compressed
}

enum CameraVendorOriginalDownloadD226Lifetime: Equatable {
  case batch
  case session

  var label: String {
    switch self {
    case .batch: return "batch"
    case .session: return "session"
    }
  }
}

enum CameraVendorDebugOriginalDownloadD226LifetimePolicy {
  static let argumentPrefix = "--camtransfer-debug-d226-lifetime="

  static func resolve(
    arguments: [String],
    debugBuild: Bool
  ) -> CameraVendorOriginalDownloadD226Lifetime {
    guard debugBuild else { return .batch }
    guard let argument = arguments.first(where: { $0.hasPrefix(argumentPrefix) }) else {
      return .batch
    }
    return argument == "\(argumentPrefix)session" ? .session : .batch
  }
}

enum CameraVendorOriginalDownloadBatchModeAction: Equatable {
  case prepare(CameraVendorTransferDownloadMode)
  case reset
}

struct CameraVendorOriginalDownloadBatchModeState {
  private var preparedMode: CameraVendorTransferDownloadMode?

  mutating func begin(lifetime: CameraVendorOriginalDownloadD226Lifetime) {
    guard lifetime == .batch else { return }
    preparedMode = nil
  }

  mutating func actionsForPreparing(
    _ mode: CameraVendorTransferDownloadMode
  ) -> [CameraVendorOriginalDownloadBatchModeAction] {
    guard let preparedMode else {
      self.preparedMode = mode
      return [.prepare(mode)]
    }
    guard preparedMode != mode else { return [] }
    self.preparedMode = mode
    return [.reset, .prepare(mode)]
  }

  mutating func actionsForEndingBatch() -> [CameraVendorOriginalDownloadBatchModeAction] {
    guard preparedMode != nil else { return [] }
    preparedMode = nil
    return [.reset]
  }

  mutating func actionsForEndingBatch(
    lifetime: CameraVendorOriginalDownloadD226Lifetime
  ) -> [CameraVendorOriginalDownloadBatchModeAction] {
    guard lifetime == .batch else { return [] }
    return actionsForEndingBatch()
  }

  mutating func resetForSessionEnd() {
    preparedMode = nil
  }
}

enum CameraVendorReservedImageReceiveStateProbePlan {
  static let stagedWriteDelaySeconds: TimeInterval = 4
  static let writeRequests: [CameraVendorBleWriteRequest] = []
}

enum CameraVendorTransferActivationCompletionPolicy {
  static func shouldProceedToGallery(
    observedChange: Bool,
    hasMoreStrategies: Bool
  ) -> Bool {
    observedChange
  }

  static func shouldAllowHandshakeCompletion(
    hasAttemptedActivation: Bool,
    observedChange: Bool,
    observedWifiLaunch: Bool,
    hadActivationFeature: Bool
  ) -> Bool {
    hasAttemptedActivation && hadActivationFeature && observedChange
  }

  static func shouldTryNextStrategy(
    observedChange: Bool,
    hasMoreStrategies: Bool
  ) -> Bool {
    !observedChange && hasMoreStrategies
  }

  static func shouldWaitForBluetoothDisconnect(
    afterObservedChangeFor strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> Bool {
    false
  }

  static func shouldActivelyDisconnectBluetooth(
    for strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> Bool {
    false
  }

  static func shouldFastHandoffAfterCommandWrites(
    for strategy: CameraVendorReferenceAppTransferActivationStrategy
  ) -> Bool {
    false
  }

  static func shouldAttemptWifiHandoffAfterExhaustedStrategies(
    observedChange: Bool,
    observedWifiLaunch: Bool
  ) -> Bool {
    observedChange
  }

  static func shouldFallbackToWifiLaunchAfterCameraResponse(
    observedChange: Bool,
    observedWifiLaunch: Bool
  ) -> Bool {
    observedChange
  }
}

enum CameraVendorIOSOfficialConnectionEvidencePolicy {
  static func verifiedStepsBeforeWifiJoin(
    hasBleReconnect: Bool,
    hasTransferAuthorization: Bool,
    hasActivationCommand: Bool,
    hasCameraWifiReady: Bool
  ) -> [IOSCameraConnectionStep] {
    var steps: [IOSCameraConnectionStep] = []
    guard hasBleReconnect else {
      return steps
    }
    steps.append(.reconnectPairedBle)

    guard hasTransferAuthorization else {
      return steps
    }
    steps.append(.transferAuthorization)

    guard hasActivationCommand else {
      return steps
    }
    steps.append(.activateCameraWifi)

    guard hasCameraWifiReady else {
      return steps
    }
    steps.append(.waitCameraWifiReady)
    return steps
  }

  static func hasVerifiedStep(
    _ step: IOSCameraConnectionStep,
    in steps: [IOSCameraConnectionStep]
  ) -> Bool {
    steps.contains(step)
  }
}

enum CameraVendorTransferActivationStateUpdatePolicy {
  static func shouldHandleTrackedStatusUpdate(
    previousValue: Data?,
    newValue: Data,
    isReadyToJoinWifi: Bool
  ) -> Bool {
    previousValue != newValue || isReadyToJoinWifi
  }
}

enum CameraVendorTransferActivationDisconnectPolicy {
  private static let wifiHandoffWindowSeconds: TimeInterval = 8

  static func shouldTreatDisconnectAsWifiHandoff(
    elapsedSinceWaitingForConfirmation: TimeInterval
  ) -> Bool {
    elapsedSinceWaitingForConfirmation <= wifiHandoffWindowSeconds
  }
}

enum CameraVendorHandshakeCompletionPolicy {
  static func shouldDisconnectBluetoothBeforeGallery(
    transferActivationObservedChange: Bool
  ) -> Bool {
    false
  }
}

enum CameraVendorGalleryFormatHint: String, Equatable, Hashable {
  case jpg
  case heif
  case raw
  case video
}

enum CameraVendorGalleryFormatResolutionPolicy {
  static func isResolvedStillOrVideoFormat(_ formatLabel: String) -> Bool {
    switch formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "JPG", "JPEG", "HEIF", "HEIC", "HIF", "RAW", "RAF", "VIDEO", "MOV", "MP4":
      return true
    default:
      return false
    }
  }
}

struct CameraVendorGalleryItem: Equatable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: String
  let byteSizeText: String
  let compressedSize: UInt32?
  let orientation: Int?
  let formatHints: Set<CameraVendorGalleryFormatHint>
  var thumbnailData: Data? = nil

  init(
    handle: Int,
    filename: String,
    formatLabel: String,
    captureDate: String,
    byteSizeText: String,
    compressedSize: UInt32? = nil,
    orientation: Int? = nil,
    formatHints: Set<CameraVendorGalleryFormatHint> = [],
    thumbnailData: Data? = nil
  ) {
    self.handle = handle
    self.filename = filename
    self.formatLabel = formatLabel
    self.captureDate = captureDate
    self.byteSizeText = byteSizeText
    self.compressedSize = compressedSize
    self.orientation = orientation
    self.formatHints = formatHints
    self.thumbnailData = thumbnailData
  }
}

enum CameraVendorCatalogPlaceholderPolicy {
  static func placeholderItems(
    from handles: [UInt32],
    dateGroups: [CameraVendorSpecifiedObjectDateGroup] = []
  ) -> [CameraVendorGalleryItem] {
    let orderedHandles = orderedUniqueHandles(from: handles)
    let datesByHandle = captureDatesByHandle(
      orderedHandles: orderedHandles,
      dateGroups: dateGroups
    )
    return orderedHandles.map { handle in
      CameraVendorGalleryItem(
        handle: Int(handle),
        filename: String(format: "0x%08X", handle),
        formatLabel: "",
        captureDate: datesByHandle[handle] ?? "",
        byteSizeText: ""
      )
    }
  }

  private static func orderedUniqueHandles(from handles: [UInt32]) -> [UInt32] {
    var seen = Set<UInt32>()
    return handles.filter { seen.insert($0).inserted }
  }

  private static func captureDatesByHandle(
    orderedHandles: [UInt32],
    dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  ) -> [UInt32: String] {
    guard !orderedHandles.isEmpty, !dateGroups.isEmpty else { return [:] }
    var result: [UInt32: String] = [:]
    var handleIndex = 0
    for group in dateGroups {
      for _ in 0..<Int(group.objectCount) {
        guard handleIndex < orderedHandles.count else { return result }
        result[orderedHandles[handleIndex]] = group.dateText
        handleIndex += 1
      }
    }
    return result
  }
}

enum CameraVendorBackgroundMetadataRefreshPolicy {
  static let objectInfoReadTimeoutSeconds: TimeInterval = 3.0
  static let readImageInfoTimeoutSeconds: TimeInterval = 3.0
  static let readImageInfoKeepAliveIntervalSeconds: TimeInterval = 6.0
  static let readImageInfoKeepAliveHandle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle

  static func shouldContinue(
    taskIsCancelled: Bool,
    sessionIsConnected: Bool,
    capturedGeneration: UInt64,
    currentGeneration: UInt64,
    isPriorityDownloadActive: Bool = false
  ) -> Bool {
    !taskIsCancelled && sessionIsConnected && capturedGeneration == currentGeneration && !isPriorityDownloadActive
  }

  static func shouldDisconnectSessionAfterFailure(
    _ error: Error,
    isPriorityDownloadActive: Bool = false
  ) -> Bool {
    guard !isPriorityDownloadActive else { return false }
    let nsError = error as NSError
    return nsError.domain == "CameraVendorPtpSocket"
  }

  static func shouldCacheReadImageInfoKeepAliveResult() -> Bool { false }
}

struct CameraVendorBackgroundMetadataRefreshState: Equatable {
  let communicationGeneration: UInt64
  let pendingHandles: [Int]
}

enum CameraVendorBackgroundMetadataRefreshResumePolicy {
  static func initialState(
    handles: [Int],
    communicationGeneration: UInt64
  ) -> CameraVendorBackgroundMetadataRefreshState? {
    let uniqueHandles = deduplicatedHandles(handles)
    guard !uniqueHandles.isEmpty else { return nil }
    return CameraVendorBackgroundMetadataRefreshState(
      communicationGeneration: communicationGeneration,
      pendingHandles: uniqueHandles
    )
  }

  static func appendingHandles(
    _ handles: [Int],
    to state: CameraVendorBackgroundMetadataRefreshState?
  ) -> CameraVendorBackgroundMetadataRefreshState? {
    guard let state else { return nil }
    let pendingHandles = deduplicatedHandles(state.pendingHandles + handles)
    guard !pendingHandles.isEmpty else { return nil }
    return CameraVendorBackgroundMetadataRefreshState(
      communicationGeneration: state.communicationGeneration,
      pendingHandles: pendingHandles
    )
  }

  static func removingResolvedHandles(
    _ handles: [Int],
    from state: CameraVendorBackgroundMetadataRefreshState?
  ) -> CameraVendorBackgroundMetadataRefreshState? {
    guard let state else { return nil }
    let resolvedHandles = Set(handles)
    let pendingHandles = state.pendingHandles.filter { !resolvedHandles.contains($0) }
    guard !pendingHandles.isEmpty else { return nil }
    return CameraVendorBackgroundMetadataRefreshState(
      communicationGeneration: state.communicationGeneration,
      pendingHandles: pendingHandles
    )
  }

  static func resumableState(
    _ state: CameraVendorBackgroundMetadataRefreshState?,
    currentGeneration: UInt64,
    sessionIsConnected: Bool,
    isPriorityDownloadActive: Bool
  ) -> CameraVendorBackgroundMetadataRefreshState? {
    guard let state,
          state.communicationGeneration == currentGeneration,
          sessionIsConnected,
          !isPriorityDownloadActive,
          !state.pendingHandles.isEmpty else {
      return nil
    }
    return state
  }

  private static func deduplicatedHandles(_ handles: [Int]) -> [Int] {
    var seen = Set<Int>()
    return handles.filter { seen.insert($0).inserted }
  }
}

enum CameraVendorPriorityDownloadExclusivePtpPolicy {
  static func shouldInvalidateInFlightPtpOperation(
    activeThumbnailRequests: Int,
    activeBackgroundMetadataRequests: Int
  ) -> Bool {
    false
  }
}

enum CameraVendorGalleryItemOrderingPolicy {
  static func galleryItems(
    from infos: [CameraVendorCameraObjectInfo],
    formatHintsByHandle: [Int: Set<CameraVendorGalleryFormatHint>] = [:],
    preserveInputOrder: Bool = false
  ) -> [CameraVendorGalleryItem] {
    let orderedInfos = preserveInputOrder ? infos : infos.sorted {
      if $0.captureDate != $1.captureDate {
        return $0.captureDate > $1.captureDate
      }
      return $0.handle > $1.handle
    }
    return orderedInfos.map { info in
      CameraVendorGalleryItem(
        handle: info.handle,
        filename: info.filename,
        formatLabel: info.galleryFormatLabel,
        captureDate: info.captureDate,
        byteSizeText: info.compressedSize > 0
          ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
          : "",
        compressedSize: info.compressedSize.nonzero,
        orientation: info.orientation,
        formatHints: formatHintsByHandle[info.handle, default: []]
      )
    }
  }
}

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

enum CameraVendorDownloadedMediaType: Equatable {
  case photo
  case raw
  case video
}

struct CameraVendorOriginalFileTransferTiming: Equatable, Sendable {
  let byteCount: Int
  let prepareMs: Int
  let requestToFirstByteMs: Int
  let socketReceiveMs: Int
  let fileWriteMs: Int
  let commandGapMs: Int
  let transferMs: Int
  let executor: String
  let d235ReadSize: UInt32?
  let initialReadSize: UInt32
  let finalReadSize: UInt32
  let fallbackCount: Int

  init(
    byteCount: Int,
    prepareMs: Int,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    commandGapMs: Int,
    transferMs: Int,
    executor: String = "unknown",
    d235ReadSize: UInt32? = nil,
    initialReadSize: UInt32 = 0,
    finalReadSize: UInt32 = 0,
    fallbackCount: Int = 0
  ) {
    self.byteCount = byteCount
    self.prepareMs = prepareMs
    self.requestToFirstByteMs = requestToFirstByteMs
    self.socketReceiveMs = socketReceiveMs
    self.fileWriteMs = fileWriteMs
    self.commandGapMs = commandGapMs
    self.transferMs = transferMs
    self.executor = executor
    self.d235ReadSize = d235ReadSize
    self.initialReadSize = initialReadSize
    self.finalReadSize = finalReadSize
    self.fallbackCount = fallbackCount
  }

  var speedMBps: Double {
    guard transferMs > 0 else { return 0 }
    return (Double(byteCount) / 1_048_576.0) / (Double(transferMs) / 1_000.0)
  }
}

struct CameraVendorDownloadedFile {
  let fileURL: URL
  let filename: String
  let mediaType: CameraVendorDownloadedMediaType
  let transferTiming: CameraVendorOriginalFileTransferTiming?

  init(
    fileURL: URL,
    filename: String,
    mediaType: CameraVendorDownloadedMediaType,
    transferTiming: CameraVendorOriginalFileTransferTiming? = nil
  ) {
    self.fileURL = fileURL
    self.filename = filename
    self.mediaType = mediaType
    self.transferTiming = transferTiming
  }
}

struct CameraVendorOriginalReadImageTransactionResult {
  let byteCount: Int
  let prefix: Data
  let requestToFirstByteMs: Int
  let socketReceiveMs: Int
  let fileWriteMs: Int
  let receiveCadence: CameraVendorPtpReceiveCadenceSummary
  let responseCode: UInt16
  let responseTransactionID: UInt32

  init(
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary = CameraVendorPtpReceiveCadenceSummary(),
    responseCode: UInt16,
    responseTransactionID: UInt32
  ) {
    self.byteCount = byteCount
    self.prefix = prefix
    self.requestToFirstByteMs = requestToFirstByteMs
    self.socketReceiveMs = socketReceiveMs
    self.fileWriteMs = fileWriteMs
    self.receiveCadence = receiveCadence
    self.responseCode = responseCode
    self.responseTransactionID = responseTransactionID
  }
}

struct CameraVendorPtpReceiveCadenceSummary: Equatable, Sendable {
  private(set) var pollWaitMs = 0
  private(set) var maxPollWaitMs = 0
  private(set) var pollWaitCount = 0
  private(set) var immediatePollCount = 0
  private(set) var recvCallCount = 0

  mutating func recordPoll(waitMs: Int) {
    let normalizedWaitMs = max(0, waitMs)
    pollWaitMs += normalizedWaitMs
    maxPollWaitMs = max(maxPollWaitMs, normalizedWaitMs)
    if normalizedWaitMs > 0 {
      pollWaitCount += 1
    } else {
      immediatePollCount += 1
    }
  }

  mutating func recordRecv() {
    recvCallCount += 1
  }

  mutating func merge(_ other: CameraVendorPtpReceiveCadenceSummary) {
    pollWaitMs += other.pollWaitMs
    maxPollWaitMs = max(maxPollWaitMs, other.maxPollWaitMs)
    pollWaitCount += other.pollWaitCount
    immediatePollCount += other.immediatePollCount
    recvCallCount += other.recvCallCount
  }
}

struct CameraVendorOriginalReadImageExecutionResult {
  let byteCount: Int
  let prefix: Data
  let requestToFirstByteMs: Int
  let socketReceiveMs: Int
  let fileWriteMs: Int
  let receiveCadence: CameraVendorPtpReceiveCadenceSummary
  let elapsedMs: Int
  let finalReadSize: UInt32
  let fallbackCount: Int

  init(
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary = CameraVendorPtpReceiveCadenceSummary(),
    elapsedMs: Int,
    finalReadSize: UInt32,
    fallbackCount: Int
  ) {
    self.byteCount = byteCount
    self.prefix = prefix
    self.requestToFirstByteMs = requestToFirstByteMs
    self.socketReceiveMs = socketReceiveMs
    self.fileWriteMs = fileWriteMs
    self.receiveCadence = receiveCadence
    self.elapsedMs = elapsedMs
    self.finalReadSize = finalReadSize
    self.fallbackCount = fallbackCount
  }
}

final class CameraVendorOriginalTransferWorker {
  private final class ResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
      lock.lock()
      self.result = result
      lock.unlock()
    }

    func take() -> Result<Value, Error> {
      lock.lock()
      defer { lock.unlock() }
      return result!
    }
  }

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UInt8>()

  init(
    label: String = "com.camtransfer.camera-vendor.original-transfer",
    qos: DispatchQoS = .userInitiated
  ) {
    queue = DispatchQueue(label: label, qos: qos)
    queue.setSpecific(key: queueKey, value: 1)
  }

  func execute<T>(_ operation: @escaping () throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }

    let resultBox = ResultBox<T>()
    let completion = DispatchSemaphore(value: 0)
    queue.async {
      resultBox.store(Result {
        try operation()
      })
      completion.signal()
    }
    completion.wait()
    return try resultBox.take().get()
  }
}

struct CameraVendorOriginalReadImageExecutor {
  private let nextTransactionID: () -> UInt32
  private let sendRequest: (_ transactionID: UInt32, _ handle: UInt32, _ offset: UInt64, _ size: UInt32) throws -> Void
  private let receivePayloadAndResponse: (_ transactionID: UInt32, _ expectedMaximum: Int, _ sink: FileHandle) throws -> CameraVendorOriginalReadImageTransactionResult
  private let cancellationCheck: () throws -> Void
  private let fallbackReadSize: (_ error: Error, _ currentReadSize: UInt32, _ bytesWritten: Int) -> UInt32?
  private let report: (String) -> Void

  init(
    nextTransactionID: @escaping () -> UInt32,
    sendRequest: @escaping (_ transactionID: UInt32, _ handle: UInt32, _ offset: UInt64, _ size: UInt32) throws -> Void,
    receivePayloadAndResponse: @escaping (_ transactionID: UInt32, _ expectedMaximum: Int, _ sink: FileHandle) throws -> CameraVendorOriginalReadImageTransactionResult,
    cancellationCheck: @escaping () throws -> Void,
    fallbackReadSize: @escaping (_ error: Error, _ currentReadSize: UInt32, _ bytesWritten: Int) -> UInt32? = { _, _, _ in nil },
    report: @escaping (String) -> Void = { _ in }
  ) {
    self.nextTransactionID = nextTransactionID
    self.sendRequest = sendRequest
    self.receivePayloadAndResponse = receivePayloadAndResponse
    self.cancellationCheck = cancellationCheck
    self.fallbackReadSize = fallbackReadSize
    self.report = report
  }

  func execute(
    handle: UInt32,
    expectedByteCount: UInt64?,
    maximumByteCount: UInt64,
    initialReadSize: UInt32,
    fileHandle: FileHandle,
    withSerializedLease: (_ body: () throws -> CameraVendorOriginalReadImageExecutionResult) throws -> CameraVendorOriginalReadImageExecutionResult
  ) throws -> CameraVendorOriginalReadImageExecutionResult {
    try withSerializedLease {
      let startedAt = Date()
      var state = CameraVendorAdaptiveDownloadChunkState(readSize: initialReadSize)
      var offset: UInt64 = 0
      var totalBytes = 0
      var prefix = Data()
      var requestToFirstByteMs = 0
      var socketReceiveMs = 0
      var fileWriteMs = 0
      var receiveCadence = CameraVendorPtpReceiveCadenceSummary()
      var fallbackCount = 0

      while offset < maximumByteCount {
        try cancellationCheck()
        let remaining = maximumByteCount - offset
        let requestSize = CameraVendorTransferChunkProfile.requestSize(
          remaining: remaining,
          selectedReadSize: state.readSize
        )
        let transactionID = nextTransactionID()
        let chunkStartedAt = Date()
        try sendRequest(transactionID, handle, offset, requestSize)

        let streamedChunk: CameraVendorOriginalReadImageTransactionResult
        do {
          streamedChunk = try receivePayloadAndResponse(
            transactionID,
            Int(requestSize),
            fileHandle
          )
        } catch {
          throw error
        }

        guard streamedChunk.responseTransactionID == transactionID else {
          throw NSError(
            domain: "CameraVendorPtpSession",
            code: 12,
            userInfo: [
              NSLocalizedDescriptionKey: "原图 ReadImage 响应 transaction 不匹配，期望 \(transactionID)，实际 \(streamedChunk.responseTransactionID)"
            ]
          )
        }

        do {
          try CameraVendorPtpResponsePolicy.validateOK(
            responseCode: streamedChunk.responseCode,
            operationName: "原图 ReadImage transaction \(transactionID)"
          )
        } catch {
          if streamedChunk.byteCount == 0,
             let reducedReadSize = fallbackReadSize(error, state.readSize, totalBytes) {
            let previousReadSize = state.readSize
            state.readSize = reducedReadSize
            fallbackCount += 1
            report(
              "[OBS] PTP_ORIGINAL_READ_IMAGE_FALLBACK_READ_SIZE " +
              "handle=0x\(String(format: "%08X", handle)) offset=\(offset) " +
              "from=\(previousReadSize) to=\(reducedReadSize)"
            )
            continue
          }
          throw error
        }

        try cancellationCheck()
        guard streamedChunk.byteCount > 0 else { break }
        if prefix.count < 64 {
          prefix.append(streamedChunk.prefix.prefix(64 - prefix.count))
        }
        totalBytes += streamedChunk.byteCount
        offset += UInt64(streamedChunk.byteCount)
        requestToFirstByteMs += streamedChunk.requestToFirstByteMs
        socketReceiveMs += streamedChunk.socketReceiveMs
        fileWriteMs += streamedChunk.fileWriteMs
        receiveCadence.merge(streamedChunk.receiveCadence)

        let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
        CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
          byteCount: streamedChunk.byteCount,
          elapsedMs: chunkElapsedMs,
          state: &state
        )

        if let expectedByteCount, UInt64(totalBytes) >= expectedByteCount {
          break
        }
      }

      if let expectedByteCount, UInt64(totalBytes) != expectedByteCount {
        throw NSError(
          domain: "CameraVendorPtpSession",
          code: 14,
          userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 文件长度不完整，期望 \(expectedByteCount)，实际 \(totalBytes)"
          ]
        )
      }

      return CameraVendorOriginalReadImageExecutionResult(
        byteCount: totalBytes,
        prefix: prefix,
        requestToFirstByteMs: requestToFirstByteMs,
        socketReceiveMs: socketReceiveMs,
        fileWriteMs: fileWriteMs,
        receiveCadence: receiveCadence,
        elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
        finalReadSize: state.readSize,
        fallbackCount: fallbackCount
      )
    }
  }
}

enum CameraVendorOriginalReadImageExecutorPolicy {
  static func rawReadSize(from data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    return UInt32(data[0]) |
      (UInt32(data[1]) << 8) |
      (UInt32(data[2]) << 16) |
      (UInt32(data[3]) << 24)
  }

  static func negotiatedReadSize(from data: Data) -> UInt32? {
    guard data.count >= 4,
          let readSize = rawReadSize(from: data),
          readSize == 0x00BFFFE0 ||
            readSize == 0x00400000 ||
            readSize == 0x00100000 else {
      return nil
    }
    return readSize
  }

  static func initialReadSize(
    cachedReadSize: UInt32?,
    negotiatedReadSize: UInt32? = nil
  ) -> UInt32 {
    _ = cachedReadSize
    if let negotiatedReadSize,
       CameraVendorTransferChunkProfile.isSupportedReadSize(negotiatedReadSize) {
      return negotiatedReadSize
    }
    return CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
  }

  static func profileSource(negotiatedReadSize: UInt32?) -> String {
    negotiatedReadSize == nil ? "safe-fallback-4mb" : "d235"
  }

  static func shouldUse(
    downloadMode: CameraVendorTransferDownloadMode,
    purpose: String
  ) -> Bool {
    downloadMode == .original && purpose == "download-file"
  }
}

struct CameraVendorDownloadedPhotoData {
  let data: Data
  let filename: String
}

enum CameraVendorGalleryDownloadPolicy {
  static func canDownloadOriginal(_ item: CameraVendorGalleryItem) -> Bool {
    item.formatLabel != "Video"
  }

  static func mediaType(for item: CameraVendorGalleryItem) -> CameraVendorDownloadedMediaType {
    switch item.formatLabel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "VIDEO", "MOV", "MP4":
      return .video
    case "RAW", "RAF":
      return .raw
    default:
      return .photo
    }
  }
}

enum CameraVendorPhotoLibrarySaveInputPolicy {
  static let shouldSavePhotoDownloadsFromTemporaryFile = false

  static func shouldSavePhotoDownloadFromData(
    filename: String,
    mediaType: CameraVendorDownloadedMediaType
  ) -> Bool {
    guard mediaType == .photo else { return false }
    let ext = (filename as NSString).pathExtension.lowercased()
    return ext == "heic" || ext == "heif"
  }
}

enum CameraVendorDownloadPipelinePolicy {
  static let streamDownloadThresholdBytes: UInt32 = 64 * 1_024 * 1_024

  static func shouldUseDataFastPath(
    mediaType: CameraVendorDownloadedMediaType,
    compressedSize: UInt32?
  ) -> Bool {
    false
  }
}

enum CameraVendorDownloadExecutionRoute: Equatable {
  case dataFastPath
  case file
}

enum CameraVendorDownloadExecutionRoutePolicy {
  static func route(
    mediaType: CameraVendorDownloadedMediaType,
    compressedSize: UInt32?
  ) -> CameraVendorDownloadExecutionRoute {
    CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
      mediaType: mediaType,
      compressedSize: compressedSize
    ) ? .dataFastPath : .file
  }
}

enum CameraVendorDownloadState: Equatable {
  case idle
  case queued
  case downloading
  case saved
  case failed(String)
}

struct CameraVendorQueuedDownloadRequest: Equatable {
  let handle: Int
  let mode: CameraVendorTransferDownloadMode
}

struct CameraVendorDownloadProgress: Equatable {
  let position: Int
  let total: Int

  var displayText: String {
    "\(position)/\(total)"
  }
}

struct CameraVendorGalleryState: Equatable {
  var items: [CameraVendorGalleryItem] = []
  var selectedHandles: Set<Int> = []
  var isLoading = false
  var errorMessage: String?
  private var downloadStates: [Int: CameraVendorDownloadState] = [:]
  private var downloadProgress: [Int: CameraVendorDownloadProgress] = [:]
  private var downloadModes: [Int: CameraVendorTransferDownloadMode] = [:]
  private var downloadQueue: [Int] = []

  init(items: [CameraVendorGalleryItem] = []) {
    self.items = items
  }

  mutating func replaceItems(_ items: [CameraVendorGalleryItem]) {
    self.items = items
    let validHandles = Set(items.map(\.handle))
    selectedHandles = selectedHandles.intersection(validHandles)
  }

  mutating func toggleSelection(handle: Int) {
    if selectedHandles.contains(handle) {
      selectedHandles.remove(handle)
    } else {
      selectedHandles.insert(handle)
    }
  }

  mutating func setSelection(handles: Set<Int>) {
    selectedHandles = handles
  }

  mutating func selectAll() {
    selectedHandles = Set(downloadableHandles(from: items.map(\.handle)))
  }

  mutating func clearSelection() {
    selectedHandles.removeAll()
  }

  mutating func enqueueDownloads(
    for handles: [Int],
    mode: CameraVendorTransferDownloadMode = .original
  ) {
    enqueueDownloads(
      handles.map { CameraVendorQueuedDownloadRequest(handle: $0, mode: mode) }
    )
  }

  mutating func enqueueDownloads(_ requests: [CameraVendorQueuedDownloadRequest]) {
    for request in requests {
      let handle = request.handle
      guard downloadStates[handle] != .saved else { continue }
      if downloadStates[handle] != .queued, !downloadQueue.contains(handle) {
        downloadQueue.append(handle)
      }
      downloadStates[handle] = .queued
      downloadProgress[handle] = nil
      downloadModes[handle] = request.mode
    }
    selectedHandles.subtract(requests.map(\.handle))
  }

  mutating func markDownloadStarted(handle: Int) {
    downloadQueue.removeAll { $0 == handle }
    downloadStates[handle] = .downloading
  }

  mutating func markDownloadStarted(handle: Int, position: Int, total: Int) {
    downloadQueue.removeAll { $0 == handle }
    downloadStates[handle] = .downloading
    downloadProgress[handle] = CameraVendorDownloadProgress(position: position, total: total)
  }

  mutating func markDownloadFinished(handle: Int) {
    downloadQueue.removeAll { $0 == handle }
    downloadStates[handle] = .saved
    downloadProgress[handle] = nil
    downloadModes.removeValue(forKey: handle)
  }

  mutating func markDownloadFailed(handle: Int, message: String) {
    downloadQueue.removeAll { $0 == handle }
    downloadStates[handle] = .failed(message)
    downloadProgress[handle] = nil
  }

  @discardableResult
  mutating func markPendingDownloadsFailedAfterFatalFailure(message: String) -> Set<Int> {
    var changedHandles = Set<Int>()
    for handle in downloadQueue where downloadStates[handle] == .queued {
      downloadStates[handle] = .failed(message)
      downloadProgress[handle] = nil
      changedHandles.insert(handle)
    }
    downloadQueue.removeAll { changedHandles.contains($0) }
    return changedHandles
  }

  @discardableResult
  mutating func pauseQueuedDownloads() -> [Int] {
    let pausedHandles = queuedDownloadHandles()
    for handle in pausedHandles {
      downloadStates[handle] = .idle
      downloadProgress.removeValue(forKey: handle)
      downloadModes.removeValue(forKey: handle)
    }
    downloadQueue.removeAll { pausedHandles.contains($0) }
    return pausedHandles
  }

  @discardableResult
  mutating func terminateActiveDownloadSession(activeHandle: Int?) -> Set<Int> {
    var changedHandles = Set(pauseQueuedDownloads())
    if let activeHandle, downloadStates[activeHandle] == .downloading {
      downloadStates[activeHandle] = .idle
      downloadProgress.removeValue(forKey: activeHandle)
      downloadModes.removeValue(forKey: activeHandle)
      changedHandles.insert(activeHandle)
    }
    return changedHandles
  }

  mutating func requeueInterruptedDownload(
    handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) {
    downloadQueue.removeAll { $0 == handle }
    downloadQueue.insert(handle, at: 0)
    downloadStates[handle] = .queued
    downloadProgress[handle] = nil
    downloadModes[handle] = mode
  }

  mutating func clearSavedDownloadCache(handle: Int) {
    guard downloadStates[handle] == .saved else { return }
    downloadStates.removeValue(forKey: handle)
    downloadProgress.removeValue(forKey: handle)
    downloadModes.removeValue(forKey: handle)
    downloadQueue.removeAll { $0 == handle }
    selectedHandles.remove(handle)
  }

  @discardableResult
  mutating func clearAllSavedDownloadCache() -> Int {
    let savedHandles = downloadStates.compactMap { entry in
      entry.value == .saved ? entry.key : nil
    }
    for handle in savedHandles {
      downloadStates.removeValue(forKey: handle)
      downloadProgress.removeValue(forKey: handle)
      downloadModes.removeValue(forKey: handle)
    }
    downloadQueue.removeAll { savedHandles.contains($0) }
    selectedHandles.subtract(savedHandles)
    return savedHandles.count
  }

  mutating func updateThumbnail(handle: Int, data: Data, resolvedItem: CameraVendorGalleryItem? = nil) {
    guard let index = items.firstIndex(where: { $0.handle == handle }) else {
      return
    }
    if let resolvedItem {
      var merged = NativeGalleryMetadataMergePolicy.mergedItem(
        existingItem: items[index],
        resolvedItem: resolvedItem
      )
      merged.thumbnailData = data
      items[index] = merged
    } else {
      items[index].thumbnailData = data
    }
  }

  func downloadState(for handle: Int) -> CameraVendorDownloadState {
    downloadStates[handle] ?? .idle
  }

  func downloadMode(for handle: Int) -> CameraVendorTransferDownloadMode {
    downloadModes[handle] ?? .original
  }

  func savedDownloadHandles() -> Set<Int> {
    Set(downloadStates.compactMap { entry in
      entry.value == .saved ? entry.key : nil
    })
  }

  func downloadableHandles(from handles: [Int]) -> [Int] {
    handles.filter { handle in
      switch downloadState(for: handle) {
      case .idle, .failed:
        return true
      case .queued, .downloading, .saved:
        return false
      }
    }
  }

  func queuedDownloadHandles() -> [Int] {
    downloadQueue.filter { downloadStates[$0] == .queued }
  }

  func pendingDownloadRequests() -> [CameraVendorQueuedDownloadRequest] {
    var activeHandles = downloadStates.compactMap { entry -> Int? in
      guard entry.value == .downloading else { return nil }
      return entry.key
    }
    activeHandles.sort { lhs, rhs in
      let leftPosition = downloadProgress[lhs]?.position ?? Int.max
      let rightPosition = downloadProgress[rhs]?.position ?? Int.max
      if leftPosition != rightPosition {
        return leftPosition < rightPosition
      }
      return lhs < rhs
    }
    let orderedHandles = activeHandles + queuedDownloadHandles()
    return orderedHandles.map {
      CameraVendorQueuedDownloadRequest(handle: $0, mode: downloadMode(for: $0))
    }
  }

  func nextQueuedDownloadHandle() -> Int? {
    queuedDownloadHandles().first
  }

  func downloadProgressText(for handle: Int) -> String? {
    downloadProgress[handle]?.displayText
  }
}

protocol CameraVendorGalleryService {
  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot
  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot
  func fetchThumbnail(for handle: Int) async throws -> Data
  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail
  func fetchPreviewImage(for handle: Int) async throws -> Data
  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview
  func downloadOriginal(for handle: Int) async throws -> Data
  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData
  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile
  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile
  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult
}

protocol CameraVendorGalleryObjectInfoSource {
  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo
}

struct CameraVendorGalleryThumbnail {
  let data: Data
  let item: CameraVendorGalleryItem?
}

struct CameraVendorGalleryPreview {
  let data: Data
  let item: CameraVendorGalleryItem?
}

struct CameraVendorGalleryWifiHandoffResult {
  let joinedSSID: String
  let didCompleteWifiHandoff: Bool
}

struct CameraVendorGalleryWifiHandoffStepResult {
  let execution: IOSCameraConnectionStepExecution
  let didCompleteWifiHandoff: Bool
}

extension CameraVendorGalleryService {
  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraVendorGalleryService",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持读取初始目录"]
    )
  }

  func fetchCameraCatalog(query _: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraVendorGalleryService",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持相机端目录筛选"]
    )
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    CameraVendorGalleryThumbnail(data: try await fetchThumbnail(for: handle), item: nil)
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await fetchThumbnail(for: handle)
  }

  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    CameraVendorGalleryPreview(data: try await fetchPreviewImage(for: handle), item: nil)
  }

  func downloadOriginalData(
    for handle: Int,
    mode _: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData {
    CameraVendorDownloadedPhotoData(
      data: try await downloadOriginal(for: handle),
      filename: "CamTransfer-\(handle).jpg"
    )
  }

  func downloadOriginalFile(
    for handle: Int,
    mode _: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile {
    try await downloadOriginalFile(for: handle)
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    throw NSError(
      domain: "CameraVendorGalleryService",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持 count sweep 实验"]
    )
  }
}

protocol CameraVendorGalleryConnectionTerminating: AnyObject {
  func terminateCameraCommunication(reason: String)
}

protocol CameraVendorGalleryBackgroundKeepAlive: AnyObject {
  func performBackgroundKeepAlive() async throws
}

protocol CameraVendorBleBackgroundKeepAlive: AnyObject {
  func performBackgroundBleKeepAlive(reason: String)
}

protocol CameraVendorExclusiveDownloadWindowControlling: AnyObject {
  func beginExclusiveDownloadWindow()
  func awaitExclusiveDownloadWindowReady() async
  func endExclusiveDownloadWindow()
  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async rethrows -> T
}

protocol CameraVendorActiveDownloadInterrupting: AnyObject {
  func interruptActiveDownload(reason: String)
}

/// Cancels the current file at the next verified PTP chunk boundary.  Unlike
/// `CameraVendorActiveDownloadInterrupting`, this does not close either PTP
/// socket, so a user can stop a file without turning a healthy camera session
/// into a reconnect.
protocol CameraVendorActiveDownloadCancellationRequesting: AnyObject {
  func requestActiveDownloadCancellation(reason: String)
}

protocol CameraVendorVisibleThumbnailLaneCoordinating: AnyObject {
  func beginVisibleThumbnailBatch(handles: [Int])
  func finishVisibleThumbnailBatch(handles: [Int])
}

enum CameraVendorGalleryFetchConcurrencyPolicy {
  static let shouldRejectConcurrentFetch = true
  static let concurrentFetchErrorCode = 7
}

struct CameraVendorReservedReceiveDiagnosticResult: Equatable {
  let objectInfo: CameraVendorCameraObjectInfo
  let sampleByteCount: Int

  var summary: String {
    let sizeText = ByteCountFormatter.string(
      fromByteCount: Int64(objectInfo.compressedSize),
      countStyle: .file
    )
    let sampleText = NumberFormatter.localizedString(
      from: NSNumber(value: sampleByteCount),
      number: .decimal
    )
    return "\(objectInfo.filename) \(objectInfo.formatLabel) \(sizeText) sample=\(sampleText) bytes"
  }
}

protocol CameraVendorReservedReceiveDiagnosticService: AnyObject {
  func probeReservedReceive() async throws -> CameraVendorReservedReceiveDiagnosticResult
}

protocol CameraVendorGalleryDiagnosticReporting: AnyObject {
  var diagnosticHandler: ((String) -> Void)? { get set }
}

protocol CameraVendorGalleryConfigurable: AnyObject {
  func configure(connectionSummary: CameraVendorConnectionSummary)
}

protocol CameraVendorGalleryReadySummaryProviding {
  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary
}

extension CameraVendorGalleryReadySummaryProviding {
  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return galleryReadyConnectionSummary(from: summary)
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }
}

private enum CameraVendorPtpOperationTransport {
  case standardPtpIp
  case cameraVendorLegacy
}

private enum CameraVendorPtpSessionPurpose {
  case gallery
  case reservedReceiveDiagnostic
}

fileprivate struct CameraVendorSpecifiedObjectSnapshot {
  let declaredCount: UInt32?
  let dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  let handles: [UInt32]
}

enum CameraVendorCatalogWireRequestPolicy {
  static let shouldReadCurrentObjectHandleViaObjectPropList = false
  static let shouldReadCurrentObjectHandleBeforeSpecifiedList = false
  static let shouldRefreshGalleryContextBeforeSpecifiedList = true
  static let shouldReadCurrentObjectHandleBeforeLatestProbe = true
}

enum CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy {
  static let maxRetryCount = 1
  static let retryDelaySeconds: TimeInterval = 1.5

  static func shouldRetry(
    count: UInt32?,
    handles: [UInt32],
    retryCount: Int,
    isRequiredPrimaryList: Bool = true
  ) -> Bool {
    isRequiredPrimaryList && (count ?? 0) == 0 && handles.isEmpty && retryCount < maxRetryCount
  }
}

enum CameraVendorReferenceAppCurrentImageContextPolicy {
  static let currentImageHandle: UInt32 = 0x10000001
  static let shouldPrimeBeforeImageHandleList = true
  static let shouldPrimeThumbnailBeforeSearchDescription = true

  static func shouldAttemptCurrentImagePrime(galleryReadyMarker: UInt32?) -> Bool {
    return shouldPrimeBeforeImageHandleList
      && CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(
        marker: galleryReadyMarker
      )
  }

  static func shouldPrimeThumbnailAfterImageContextPrime(imagePrimeSucceeded: Bool) -> Bool {
    shouldPrimeThumbnailBeforeSearchDescription && imagePrimeSucceeded
  }
}

enum CameraVendorOriginalDownloadPolicy {
  // ReferenceApp only sets this before its ReadImage transfer state machine. Pairing it
  // with plain GetObject leaves this camera waiting without a useful response.
  static let shouldSetForceCompressionBeforeStandardGetObject = false
  static let shouldAttemptStandardGetObjectDownload = false
  static let shouldDownloadUsingPartialObjectFallback = true
  static let shouldPreparePartialObjectFileDownload = true
  static let shouldPreferReferenceAppPreparationForFileDownload = true
  static let referenceAppFileDownloadForceCompressionMode: UInt32 = 2

  static func shouldUseReferenceAppFastStartPreparation(formatLabel: String) -> Bool {
    shouldPreferReferenceAppPreparationForFileDownload && formatLabel == "RAW"
  }

  static func correctFileSizePayload(enabled: Bool) -> Data {
    var value = UInt16(enabled ? 1 : 0).littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }

  static func expectedDownloadSize(
    formatLabel: String,
    freshCompressedSize: UInt32?,
    cachedExpectedSize: UInt32?
  ) -> UInt32? {
    if formatLabel == "RAW", let cachedExpectedSize {
      return cachedExpectedSize
    }
    return freshCompressedSize ?? cachedExpectedSize
  }

  static func shouldSkipFreshFileInfoProbe(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    guard cachedExpectedSize != nil else { return false }
    return formatLabel == "RAW"
  }

  static func shouldPrepareTransferStateBeforeFileDownload(
    formatLabel _: String,
    cachedExpectedSize _: UInt32?
  ) -> Bool {
    shouldPreparePartialObjectFileDownload
  }

  static func shouldReadReferenceAppContextBeforeDataDownload() -> Bool {
    true
  }

  static func shouldReadCompressionCutOffBeforeDataDownload() -> Bool {
    true
  }

  static func shouldUseCachedObjectInfoForDataDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?,
    mode: CameraVendorTransferDownloadMode
  ) -> Bool {
    false
  }

  static func shouldSetCorrectFileSizeBeforeFileDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && !shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }

  static func shouldSetForceCompressionBeforeFileDownload(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }

  static func shouldReadCompressionCutOffBeforeFreshFileInfo(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldSetCorrectFileSizeBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    )
  }

  static func shouldReadCompressionCutOffAfterFreshFileInfo(
    formatLabel: String,
    cachedExpectedSize: UInt32?
  ) -> Bool {
    shouldPrepareTransferStateBeforeFileDownload(
      formatLabel: formatLabel,
      cachedExpectedSize: cachedExpectedSize
    ) && shouldUseReferenceAppFastStartPreparation(formatLabel: formatLabel)
  }
}

enum CameraVendorDownloadModePolicy {
  private static let resizeRateS: UInt32 = 1
  private static let forceCompressed: UInt32 = 1
  private static let forceOriginal: UInt32 = 2
  private static let forceReset: UInt32 = 0

  static func prepareProperties(
    mode: CameraVendorTransferDownloadMode
  ) -> [CameraVendorDownloadModeProperty] {
    switch mode {
    case .compressed:
      return [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: resizeRateS,
          width: .uint16
        ),
        imageForceCompression(forceCompressed),
      ]
    case .original:
      return [imageForceCompression(forceOriginal)]
    }
  }

  static func resetProperty(
    for property: CameraVendorDownloadModeProperty
  ) -> CameraVendorDownloadModeProperty? {
    guard property.code == CameraVendorDevicePropCode.imageForceCompression else {
      return nil
    }
    return imageForceCompression(forceReset)
  }

  static func payload(for property: CameraVendorDownloadModeProperty) -> Data {
    switch property.width {
    case .uint16:
      var value = UInt16(property.value).littleEndian
      return withUnsafeBytes(of: &value) { Data($0) }
    case .uint32:
      var value = UInt32(property.value).littleEndian
      return withUnsafeBytes(of: &value) { Data($0) }
    }
  }

  private static func imageForceCompression(_ value: UInt32) -> CameraVendorDownloadModeProperty {
    CameraVendorDownloadModeProperty(
      code: CameraVendorDevicePropCode.imageForceCompression,
      value: value,
      width: .uint16
    )
  }
}

enum CameraVendorThumbnailFetchPolicy {
  static let shouldReadObjectInfoBeforeGetThumb = true
  static let shouldTryStandardGetThumbFirst = true
  static let shouldUsePartialPreviewFallback = false
  static let standardGetThumbReadTimeoutSeconds: TimeInterval = 3
  static let partialPreviewReadSize: UInt32 = 256 * 1_024
  static let minimumUsefulThumbnailBytes = 100
}

enum CameraVendorPartialObjectDownloadPolicy {
  static func shouldStopAfterChunk(
    totalBytes: Int,
    expectedBytes: UInt64?,
    isJpegObject: Bool,
    hasJpegEndMarker: Bool
  ) -> Bool {
    if hasJpegEndMarker {
      return true
    }
    if let expectedBytes, UInt64(totalBytes) >= expectedBytes {
      return true
    }
    return false
  }
}

enum CameraVendorReferenceAppFunctionVersionPolicy {
  static let fallbackRemotePhotoViewExVersion: UInt32 = 3

  static func versionToWrite(from data: Data) -> UInt32 {
    fallbackRemotePhotoViewExVersion
  }
}

enum CameraVendorReferenceAppRemoteImageViewerPolicy {
  static let cameraStateRemoteAccess: UInt32 = 6
  static let remoteModeClientState: UInt32 = 5
  static let referenceAppRemoteImageViewerClientState: UInt32 = 20
  static let remoteGetObjectVersionToWrite: UInt32 = 5
}

enum CameraVendorReferenceAppReservedReceiveProbePolicy {
  static let shouldProbeDuringGalleryHandshake = false
  static let shouldUseSeparatePtpSession = true
  static let shouldExposeManualDiagnosticEntry = false
  static let reservedReceiveClientState: UInt32 = 21
  static let reservedReceiveVersionToWrite: UInt32 = 3
  static let reservedObjectHandle: UInt32 = 1
  static let sampleReadBytes = CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
}


enum CameraVendorNetworkUtils {
  /// Returns the IPv4 address of the WiFi (en0) interface, or nil.
  static func wifiIPv4Address() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
      let name = String(cString: ptr.pointee.ifa_name)
      guard name == "en0",
            ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      if getnameinfo(ptr.pointee.ifa_addr, socklen_t(MemoryLayout<sockaddr_in>.size),
                     &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
        return String(cString: hostname)
      }
    }
    return nil
  }
}

enum CameraVendorManualWifiReadinessPolicy {
  static let maxWaitSeconds: TimeInterval = 14
  static let pollIntervalSeconds: TimeInterval = 1
}

struct CameraVendorThumbnailFetchResult {
  let data: Data
  let objectInfo: CameraVendorCameraObjectInfo?
}

struct CameraVendorPreviewImageFetchResult {
  let data: Data
  let objectInfo: CameraVendorCameraObjectInfo
}

enum CameraVendorThumbnailResultPolicy {
  static func result(
    data: Data,
    primedObjectInfo: CameraVendorCameraObjectInfo?
  ) -> CameraVendorThumbnailFetchResult {
    CameraVendorThumbnailFetchResult(data: data, objectInfo: primedObjectInfo)
  }
}

struct CameraVendorCameraObjectInfo: Equatable {
  static let undefinedFormatCode: UInt16 = 0x3000

  let handle: Int
  let storageID: UInt32
  let formatCode: UInt16
  let compressedSize: UInt32
  let thumbCompressedSize: UInt32
  let filename: String
  let captureDate: String
  let orientation: Int?

  init(
    handle: Int,
    storageID: UInt32,
    formatCode: UInt16,
    compressedSize: UInt32,
    thumbCompressedSize: UInt32,
    filename: String,
    captureDate: String,
    orientation: Int? = nil
  ) {
    self.handle = handle
    self.storageID = storageID
    self.formatCode = formatCode
    self.compressedSize = compressedSize
    self.thumbCompressedSize = thumbCompressedSize
    self.filename = filename
    self.captureDate = captureDate
    self.orientation = orientation
  }

  var hasResolvedFormat: Bool {
    formatCode != 0 && formatCode != Self.undefinedFormatCode
  }

  var galleryFormatLabel: String {
    hasResolvedFormat ? formatLabel : ""
  }

  var reliableDownloadMetadata: CameraVendorCameraObjectInfo? {
    guard hasResolvedFormat,
          hasResolvedDownloadFilename else {
      return nil
    }
    return self
  }

  func mergingMissingDownloadMetadata(
    from cached: CameraVendorCameraObjectInfo?
  ) -> CameraVendorCameraObjectInfo {
    guard let cached, cached.handle == handle else { return self }
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID == 0 ? cached.storageID : storageID,
      formatCode: hasResolvedFormat ? formatCode : cached.formatCode,
      compressedSize: compressedSize == 0 ? cached.compressedSize : compressedSize,
      thumbCompressedSize: thumbCompressedSize == 0 ? cached.thumbCompressedSize : thumbCompressedSize,
      filename: hasResolvedDownloadFilename ? filename : cached.filename,
      captureDate: captureDate.isEmpty ? cached.captureDate : captureDate,
      orientation: orientation ?? cached.orientation
    )
  }

  private var hasResolvedDownloadFilename: Bool {
    !filename.isEmpty && !filename.hasPrefix("0x")
  }

  var formatLabel: String {
    switch formatCode {
    case 0x3801:
      return "JPG"
    case CameraVendorWirelessRealFileFormat.heif:
      return "HEIF"
    case 0xB101, 0xB103:
      return "RAW"
    case 0x300B, 0x300D:
      return "Video"
    default:
      return String(format: "0x%04X", formatCode)
    }
  }

  static func placeholder(handle: UInt32, captureDate: String = "") -> CameraVendorCameraObjectInfo {
    CameraVendorCameraObjectInfo(
      handle: Int(handle),
      storageID: 0,
      formatCode: undefinedFormatCode,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: String(format: "0x%08X", handle),
      captureDate: captureDate,
      orientation: nil
    )
  }
}

struct CameraVendorObjectInfoCache {
  private var storage: [Int: CameraVendorCameraObjectInfo] = [:]

  subscript(handle: Int) -> CameraVendorCameraObjectInfo? {
    storage[handle]
  }

  mutating func store(_ info: CameraVendorCameraObjectInfo) {
    storage[info.handle] = info
  }

  mutating func resetForPhysicalSession() {
    storage.removeAll(keepingCapacity: true)
  }
}

enum CameraVendorDownloadSizeSourcePolicy {
  static func resolution(
    freshSize: UInt32,
    cachedSize: UInt32?
  ) -> (size: UInt32?, label: String) {
    if let freshSize = freshSize.nonzero {
      return (freshSize, "fresh-object-info")
    }
    if let cachedSize {
      return (cachedSize, "cached-after-empty-fresh")
    }
    return (nil, "unknown-after-empty-fresh")
  }
}

/// Returns the IPv4 address of the WiFi (en0) interface, or nil.
private func getWifiIPv4Address() -> String? {
  var ifaddr: UnsafeMutablePointer<ifaddrs>?
  guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
  defer { freeifaddrs(ifaddr) }
  for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
    let name = String(cString: ptr.pointee.ifa_name)
    guard name == "en0",
          ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                   &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
      return String(cString: hostname)
    }
  }
  return nil
}


private final class CameraVendorPtpDownloadCancellation {
  private let lock = NSLock()
  private var generation: UInt64 = 0

  func snapshot() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return generation
  }

  func request() {
    lock.lock()
    generation += 1
    lock.unlock()
  }

  func wasRequested(since snapshot: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation != snapshot
  }
}

private final class CameraVendorPtpSession {
  private let commandSocket = CameraVendorPtpSocket()
  private let eventSocket = CameraVendorPtpSocket()
  private let originalTransferWorker = CameraVendorOriginalTransferWorker()
  private let commandLock = NSLock()
  private var connectionNumber: UInt32 = 0
  private var transactionID: UInt32 = 0
  private var isConnected = false
  private var transferCapabilitySerialNumber: String?
  private let originalTransferCapabilityStore = CameraVendorOriginalTransferCapabilityStore()
  private let activeDownloadCancellation = CameraVendorPtpDownloadCancellation()
  var isSessionConnected: Bool {
    isConnected
  }

  #if DEBUG
  private var physicalSessionSequence: UInt64 = 0

  var physicalSessionID: String? {
    guard isConnected else { return nil }
    return "\(connectedHost)-\(connectionNumber)-\(physicalSessionSequence)"
  }

  private var debugPhysicalSessionLabel: String {
    return physicalSessionID ?? "none"
  }
  #endif

  #if !DEBUG
  private var debugPhysicalSessionLabel: String { "none" }
  #endif

  func configureTransferProfile(cameraSerialNumber: String?) {
    transferCapabilitySerialNumber = cameraSerialNumber
  }
  private var operationTransport: CameraVendorPtpOperationTransport = .standardPtpIp
  private var diagnosticHandler: ((String) -> Void)?
  private var connectedHost = CameraVendorPtpConstants.defaultHost
  private var connectedClientName = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
  private var connectedPurpose: CameraVendorPtpSessionPurpose = .gallery
  private var priorityDownloadInterruptionGeneration: UInt64 = 0
  private var originalDownloadBatchModeState = CameraVendorOriginalDownloadBatchModeState()
  private let networkServiceProfile: CameraVendorPtpNetworkServiceProfile = {
    #if DEBUG
    return CameraVendorDebugPtpNetworkServicePolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .current
    #endif
  }()
  private let socketBufferProfile: CameraVendorPtpSocketBufferProfile = {
    #if DEBUG
    return CameraVendorDebugPtpSocketBufferPolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .kernelAutotuning
    #endif
  }()
  private let tcpNoDelayPolicy: CameraVendorPtpTcpNoDelayPolicy = {
    #if DEBUG
    return CameraVendorDebugPtpTcpNoDelayPolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .enabled
    #endif
  }()
  private let originalDownloadD226Lifetime: CameraVendorOriginalDownloadD226Lifetime = {
    #if DEBUG
    return CameraVendorDebugOriginalDownloadD226LifetimePolicy.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      debugBuild: true
    )
    #else
    return .batch
    #endif
  }()
  private var cameraVendorSpecifiedObjectHandles: [UInt32] = []
  private var cameraVendorSpecifiedObjectDateGroups: [CameraVendorSpecifiedObjectDateGroup] = []
  private var cameraVendorSpecifiedObjectHandlesByFormatMask: [UInt16: [UInt32]] = [:]
  private var cameraVendorCurrentSlotStatus: UInt8?
  private var didConfirmGalleryMode = false
  private var didPrepareLegacyGalleryLoad = false

  var hasExplicitGalleryModeEvidence: Bool {
    didConfirmGalleryMode
  }

  func connect(
    host: String = CameraVendorPtpConstants.defaultHost,
    clientName: String = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName,
    commandConnectTimeout: TimeInterval = CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
    diagnosticHandler: ((String) -> Void)? = nil,
    purpose: CameraVendorPtpSessionPurpose = .gallery
  ) throws {
    disconnect()
    transactionID = 0
    didConfirmGalleryMode = false
    didPrepareLegacyGalleryLoad = false
    cameraVendorSpecifiedObjectHandles = []
    cameraVendorSpecifiedObjectDateGroups = []
    cameraVendorSpecifiedObjectHandlesByFormatMask = [:]
    self.diagnosticHandler = diagnosticHandler

    report("准备连接 PTP 命令端口 \(host):\(CameraVendorPtpConstants.commandPort)")
    report("[OBS] PTP_CONNECT_START host=\(host) port=\(CameraVendorPtpConstants.commandPort) clientName=\(clientName)")
    connectedHost = host
    connectedClientName = clientName
    connectedPurpose = purpose
    try commandSocket.connect(
      host: host,
      port: CameraVendorPtpConstants.commandPort,
      timeout: commandConnectTimeout,
      diagnosticHandler: diagnosticHandler,
      networkServiceProfile: networkServiceProfile,
      socketBufferProfile: socketBufferProfile,
      tcpNoDelayPolicy: tcpNoDelayPolicy
    )
    let initResult = try performInitHandshake(host: host, clientName: clientName)
    connectionNumber = initResult.connectionNumber
    operationTransport = initResult.operationTransport
    report("收到 PTP INIT_COMMAND_ACK，连接号 \(connectionNumber)")
    report("[OBS] PTP_INIT_ACK connectionNumber=\(connectionNumber) transport=\(operationTransport == .cameraVendorLegacy ? "cameraVendorLegacy" : "standard")")
    report("PTP 命令格式: \(operationTransport == .cameraVendorLegacy ? "CameraVendor legacy" : "standard PTP/IP")")

    // CameraVendor does NOT use standard InitEventRequest before OpenSession.
    // NewCameraVendorInitEventRequestPacket returns nil in the Go implementation.
    // The event port (55741) only becomes available after InitiateOpenCapture.

    report("打开 PTP Session")
    _ = try sendCommand(
      operationCode: UInt16(CameraVendorPtpOperationCode.openSession),
      parameters: [1]
    )
    report("PTP Session 已打开")
    report("[OBS] PTP_OPEN_SESSION_OK")

    switch (operationTransport, purpose) {
    case (.cameraVendorLegacy, .gallery):
      try confirmCameraVendorLegacyReferenceAppGalleryMode()
      didConfirmGalleryMode = true
    case (.cameraVendorLegacy, .reservedReceiveDiagnostic):
      try performCameraVendorReservedReceiveDiagnosticHandshake()
    case (.standardPtpIp, .gallery):
      try performStandardGalleryHandshake()
      didConfirmGalleryMode = true
    case (.standardPtpIp, .reservedReceiveDiagnostic):
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState),
        userInfo: [NSLocalizedDescriptionKey: "Reserved Receive 诊断需要 CameraVendor legacy PTP 连接"]
      )
    }

    isConnected = true
    #if DEBUG
    physicalSessionSequence &+= 1
    #endif
    report("PTP 连接完成，purpose=\(purpose)")
    report("[OBS] PTP_HANDSHAKE_OK purpose=\(purpose)")
  }

  func interruptInFlightOperationForPriorityDownload() {
    guard CameraVendorThumbnailLoadPolicy.shouldInterruptInFlightRequestBeforeDownload else { return }
    guard isConnected else { return }
    priorityDownloadInterruptionGeneration += 1
    report("[OBS] PTP_PRIORITY_DOWNLOAD_INTERRUPT_IN_FLIGHT_REQUEST")
    guard CameraVendorThumbnailLoadPolicy.shouldClosePtpSocketForPriorityDownloadInterruption else {
      report("[OBS] PTP_PRIORITY_DOWNLOAD_SOCKET_CLOSE_SKIPPED")
      return
    }
    commandSocket.close()
    eventSocket.close()
    isConnected = false
  }

  func invalidateInFlightOperationForPriorityDownload(reason: String) {
    guard isConnected else { return }
    priorityDownloadInterruptionGeneration += 1
    report("[OBS] PTP_PRIORITY_DOWNLOAD_INVALIDATE_IN_FLIGHT_REQUEST reason=\(reason)")
    commandSocket.close()
    eventSocket.close()
    isConnected = false
  }

  func requestActiveDownloadCancellation(reason: String) {
    activeDownloadCancellation.request()
    report("[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCEL_REQUESTED reason=\(reason)")
  }

  private func throwIfActiveDownloadCancelled(since generation: UInt64) throws {
    guard activeDownloadCancellation.wasRequested(since: generation) else { return }
    report("[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCELLED_AT_CHUNK_BOUNDARY")
    throw NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "用户已终止当前下载"]
    )
  }

  func beginPriorityDownloadBatch(generation: UInt64) {
    originalDownloadBatchModeState.begin(lifetime: originalDownloadD226Lifetime)
    report(
      "[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_BEGIN " +
      "d226Lifetime=\(originalDownloadD226Lifetime.label) " +
      "session=\(debugPhysicalSessionLabel) generation=\(generation)"
    )
  }

  func finishPriorityDownloadBatch() {
    let actions = originalDownloadBatchModeState.actionsForEndingBatch(
      lifetime: originalDownloadD226Lifetime
    )
    guard isConnected else {
      report("[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_RESET_SKIPPED_DISCONNECTED")
      report("[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_FINISH")
      return
    }
    if originalDownloadD226Lifetime == .session, actions.isEmpty {
      report(
        "[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_D226_RESET_SUPPRESSED " +
        "branch=d226-session-lifetime session=\(debugPhysicalSessionLabel)"
      )
    }
    for action in actions {
      guard action == .reset else { continue }
      do {
        _ = try setCameraVendorImageForceCompression(
          0,
          reason: "priority-download-batch-finish"
        )
      } catch {
        report(
          "[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_MODE_RESET_FAILED " +
          "error=\(error.localizedDescription)"
        )
      }
    }
    report("[OBS] PTP_PRIORITY_DOWNLOAD_BATCH_FINISH")
  }

  @discardableResult
  private func prepareDownloadModeForPriorityBatch(
    _ mode: CameraVendorTransferDownloadMode,
    handle: UInt32,
    reason: String
  ) throws -> Bool {
    let actions = originalDownloadBatchModeState.actionsForPreparing(mode)
    do {
      for action in actions {
        switch action {
        case .reset:
          _ = try setCameraVendorImageForceCompression(
            0,
            reason: "\(reason)-mode-switch-reset"
          )
        case .prepare(let preparedMode):
          for property in CameraVendorDownloadModePolicy.prepareProperties(mode: preparedMode) {
            try setCameraVendorDownloadModeProperty(
              property,
              handle: handle,
              mode: preparedMode,
              reason: reason
            )
          }
        }
      }
      return actions.contains { action in
        if case .prepare = action { return true }
        return false
      }
    } catch {
      originalDownloadBatchModeState.resetForSessionEnd()
      throw error
    }
  }

  func ensureConnectedForPriorityDownload() throws {
    guard !isConnected else { return }
    var lastError: Error?
    for attempt in 1...CameraVendorPtpConnectionStartupPolicy.maxAttempts {
      report("[OBS] PTP_PRIORITY_DOWNLOAD_RECONNECT_BEGIN clientName=\(connectedClientName) attempt=\(attempt)")
      commandLock.lock()
      commandLock.unlock()
      guard !isConnected else { return }
      do {
        try connect(
          host: connectedHost,
          clientName: connectedClientName,
          diagnosticHandler: diagnosticHandler,
          purpose: connectedPurpose
        )
        report("[OBS] PTP_PRIORITY_DOWNLOAD_RECONNECT_COMPLETE attempt=\(attempt)")
        return
      } catch {
        commandSocket.close()
        eventSocket.close()
        isConnected = false
        if CameraVendorPtpReconnectErrorPolicy.shouldRetry(error) == false {
          throw error
        }

        lastError = error
        guard CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: attempt) else {
          break
        }

        let delay = CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
        report(
          "[OBS] PTP_PRIORITY_DOWNLOAD_RECONNECT_RETRY " +
          "attempt=\(attempt) delay=\(String(format: "%.1f", delay)) " +
          "error=\(error.localizedDescription)"
        )
        Thread.sleep(forTimeInterval: delay)
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: 12,
      userInfo: [NSLocalizedDescriptionKey: "优先下载重连多次失败"]
    )
  }

  private func performStandardGalleryHandshake() throws {
    // Wait for camera to be ready (poll CameraState 0xDF00).
    // On first connection, user may need to press OK on camera screen.
    report("等待相机就绪 (轮询 CameraState 0xDF00)")
    try waitForCameraAccess()

    // Set InitSequence (0xDF01 = 0x00000005) — matches Go reference implementation.
    // This is the handshake value that tells the camera we're a valid client.
    report("设置 InitSequence (0xDF01 = 0x00000005)")
    var initSeqData = Data()
    let initSeqValue = UInt32(5).littleEndian
    withUnsafeBytes(of: initSeqValue) { initSeqData.append(contentsOf: $0) }
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.initSequence],
      data: initSeqData
    )
    report("InitSequence 已设置")

    // Read and echo back app version (required handshake step)
    report("读取 CameraVendor AppVersion (0xDF24)")
    let appVersionData = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [CameraVendorDevicePropCode.appVersion]
    )
    report("收到 AppVersion 数据 (\(appVersionData.count) bytes): \(appVersionData.map { String(format: "%02x", $0) }.joined(separator: " "))")

    report("回写 CameraVendor AppVersion")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.appVersion],
      data: appVersionData
    )
    report("CameraVendor AppVersion 已确认")

    // Set InitSequence to gallery/transfer mode (0xDF01 = 0x00000002 = VIEW_ALL_IMGS)
    // This tells the camera we want to browse and transfer photos.
    // (InitiateOpenCapture 0x101C is for remote shooting mode, not gallery.)
    report("设置图库浏览模式 (0xDF01 = 0x00000002)")
    var modeData = Data()
    let modeValue = UInt32(2).littleEndian
    withUnsafeBytes(of: modeValue) { modeData.append(contentsOf: $0) }
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.initSequence],
      data: modeData
    )
    report("图库浏览模式已设置")
  }

  private func confirmCameraVendorLegacyReferenceAppGalleryMode() throws {
    report("确认 CameraVendor/ReferenceApp legacy 相册模式")

    let factoryContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #1 (38 bytes)"
    )
    report(
      "[OBS] PTP_FACTORY_D212_1 bytes=\(factoryContext.count) " +
      "hex=\(factoryContext.map { String(format: "%02x", $0) }.joined())"
    )

    try setCameraVendorReferenceAppClientState(
      CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState,
      reason: "referenceApp-remote-image-viewer"
    )

    let imageHostVersion = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppImageHost,
      name: "CameraVendor/ReferenceApp ImageHost 版本 (0xDF28)"
    )

    let versionToWrite = CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: imageHostVersion)
    report("按 ReferenceApp 图库模式回写 CameraVendor/ReferenceApp ImageHost 版本 (0xDF28 = \(versionToWrite))")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppImageHost],
      data: littleEndianData(versionToWrite)
    )

    try requestCameraVendorCardSlotStatus()
    report("CameraVendor/ReferenceApp legacy 相册模式确认完成")
  }

  private func prepareCameraVendorLegacyGalleryLoad() throws {
    guard !didPrepareLegacyGalleryLoad else {
      report("[OBS] PTP_GALLERY_BOOTSTRAP_SKIPPED reason=already-prepared")
      return
    }

    report("执行 CameraVendor/ReferenceApp legacy Gallery bootstrap")

    let initialContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #2 (14 bytes)"
    )
    let galleryReadyMarker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: initialContext
    )
    reportCameraVendorGalleryContextMarker(initialContext)
    report("[OBS] PTP_FACTORY_D212_2 bytes=\(initialContext.count) hex=\(initialContext.map { String(format: "%02x", $0) }.joined())")

    try requestCameraVendorCardSlotStatus()

    report("[OBS] PTP_GALLERY_BOOTSTRAP_9054")
    let didPrimeCurrentImage = primeCameraVendorCurrentImageContextIfNeeded(
      stage: "gallery-bootstrap",
      galleryReadyMarker: galleryReadyMarker
    )
    report("[OBS] PTP_GALLERY_BOOTSTRAP_9055")
    primeCameraVendorCurrentThumbnailContextIfNeeded(
      stage: "gallery-bootstrap",
      imagePrimeSucceeded: didPrimeCurrentImage
    )
    report("[OBS] PTP_GALLERY_BOOTSTRAP_9050")
    try requestCameraVendorSearchModeDescAll()
    report("[OBS] PTP_GALLERY_BOOTSTRAP_D22B")
    requestCameraVendorCurrentObjectHandleSnapshot(stage: "gallery-bootstrap")

    let context3 = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp factory D212 #3 (7 bytes)"
    )
    report("[OBS] PTP_FACTORY_D212_3 bytes=\(context3.count) hex=\(context3.map { String(format: "%02x", $0) }.joined())")

    didPrepareLegacyGalleryLoad = true
    report("[OBS] PTP_GALLERY_BOOTSTRAP_COMPLETE")
  }

  func prepareCameraVendorLegacyGalleryLoadIfNeeded() throws {
    guard operationTransport == .cameraVendorLegacy else { return }
    try prepareCameraVendorLegacyGalleryLoad()
  }

  func recoverInitialCameraCatalogAfterStoreNotAvailable() throws {
    report("[OBS] PTP_INITIAL_CAMERA_CATALOG_BOOTSTRAP_RECOVERY response=0x2013")
    try prepareCameraVendorLegacyGalleryLoadIfNeeded()
  }

  private func performCameraVendorReservedReceiveDiagnosticHandshake() throws {
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_HANDSHAKE_BEGIN")

    let initialContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp Reserved Receive 初始上下文 (0xD212)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_INITIAL_D212 bytes=\(initialContext.map { String(format: "%02x", $0) }.joined())")

    try setCameraVendorReferenceAppClientState(
      CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState,
      reason: "reserved-receive-diagnostic"
    )

    let versionData = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppReservedReceive,
      name: "CameraVendor/ReferenceApp ReservedPhotoReceiveEx (0xDF29)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_VERSION_READ value=\(cameraVendorPropValueDescription(versionData))")

    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppReservedReceive],
      data: littleEndianData(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)
    )
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_VERSION_WRITE value=\(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)")

    let readyContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp Reserved Receive 上下文 (0xD212)"
    )
    report("[OBS] PTP_RESERVED_RECEIVE_READY_D212 bytes=\(readyContext.map { String(format: "%02x", $0) }.joined())")
    report("[OBS] PTP_RESERVED_RECEIVE_DIAGNOSTIC_HANDSHAKE_OK")
  }

  private func reportCameraVendorVersionSnapshot(stage: String) {
    let props: [(UInt32, String)] = [
      (CameraVendorDevicePropCode.cameraState, "CameraState"),
      (CameraVendorDevicePropCode.imageGetVersion, "ImageGetVersion"),
      (CameraVendorDevicePropCode.getObjectVersion, "GetObjectVersion"),
      (CameraVendorDevicePropCode.appVersion, "RemoteVersion/AppVersion"),
      (CameraVendorDevicePropCode.remoteGetObjectVersion, "RemoteGetObjectVersion"),
      (CameraVendorDevicePropCode.referenceAppImageHost, "ReferenceAppImageHost"),
    ]
    for (code, name) in props {
      do {
        let data = try readCameraVendorDeviceProperty(
          code: code,
          name: "CameraVendor \(name) (0x\(String(format: "%04X", code)))"
        )
        report("[OBS] PTP_CAMERA_VENDOR_VERSION_PROP stage=\(stage) name=\(name) value=\(cameraVendorPropValueDescription(data))")
      } catch {
        report("[OBS] PTP_CAMERA_VENDOR_VERSION_PROP_FAILED stage=\(stage) name=\(name) error=\(error.localizedDescription)")
      }
    }
  }

  private func primeCameraVendorReferenceAppRemoteImageViewerContext() {
    do {
      try setCameraVendorDevicePropUInt16(
        CameraVendorDevicePropCode.cameraState,
        value: UInt16(CameraVendorReferenceAppRemoteImageViewerPolicy.cameraStateRemoteAccess),
        name: "CameraState remote access"
      )
      report("[OBS] PTP_SET_CAMERA_STATE_REMOTE_ACCESS")
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after CameraState remote access (0xD212)"
      )
    } catch {
      report("[OBS] PTP_SET_CAMERA_STATE_REMOTE_ACCESS_FAILED error=\(error.localizedDescription)")
    }
  }

  private func primeCameraVendorRemoteGetObjectVersionIfAvailable() {
    do {
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.remoteGetObjectVersion,
        name: "CameraVendor RemoteGetObjectVersion (0xDF25)"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.remoteGetObjectVersion],
        data: littleEndianData(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite)
      )
      report("[OBS] PTP_SET_REMOTE_GET_OBJECT_VERSION value=\(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite)")
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after RemoteGetObjectVersion (0xD212)"
      )
    } catch {
      report("[OBS] PTP_REMOTE_GET_OBJECT_VERSION_SKIPPED error=\(error.localizedDescription)")
    }
  }

  private func probeCameraVendorReservedReceiveModeIfNeeded() {
    guard CameraVendorReferenceAppReservedReceiveProbePolicy.shouldProbeDuringGalleryHandshake else {
      return
    }

    report("[OBS] PTP_RESERVED_RECEIVE_PROBE_BEGIN")
    do {
      try setCameraVendorReferenceAppClientState(
        CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState,
        reason: "reserved-receive-probe"
      )

      let versionData = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppReservedReceive,
        name: "CameraVendor/ReferenceApp ReservedPhotoReceiveEx (0xDF29)"
      )
      report("[OBS] PTP_RESERVED_RECEIVE_VERSION_READ value=\(cameraVendorPropValueDescription(versionData))")

      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.referenceAppReservedReceive],
        data: littleEndianData(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)
      )
      report("[OBS] PTP_SET_RESERVED_RECEIVE_VERSION value=\(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite)")

      let context = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList after ReservedReceive (0xD212)"
      )
      report("[OBS] PTP_RESERVED_RECEIVE_D212 bytes=\(context.map { String(format: "%02x", $0) }.joined())")

      do {
        let info = try objectInfo(handle: CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle)
        report(
          "[OBS] PTP_RESERVED_RECEIVE_OBJECT_INFO " +
          "handle=\(info.handle) format=\(info.formatLabel) filename=\(info.filename) size=\(info.compressedSize)"
        )
      } catch {
        report("[OBS] PTP_RESERVED_RECEIVE_OBJECT_INFO_FAILED error=\(error.localizedDescription)")
      }

      let reservedCount = try? requestCameraVendorSpecifiedObjectCount(stage: "reserved-receive-probe")
      let reservedHandles = (try? requestCameraVendorSpecifiedObjectHandles(stage: "reserved-receive-probe")) ?? []
      report(
        "[OBS] PTP_RESERVED_RECEIVE_SPECIFIED_SNAPSHOT " +
        "count=\(reservedCount.flatMap { $0 }.map(String.init) ?? "nil") handles=\(reservedHandles.count)"
      )
    } catch {
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_FAILED error=\(error.localizedDescription)")
    }

    do {
      try setCameraVendorReferenceAppClientState(
        CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState,
        reason: "reserved-receive-probe-restore"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.referenceAppImageHost],
        data: littleEndianData(CameraVendorReferenceAppFunctionVersionPolicy.fallbackRemotePhotoViewExVersion)
      )
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_RESTORE_OK")
    } catch {
      report("[OBS] PTP_RESERVED_RECEIVE_PROBE_RESTORE_FAILED error=\(error.localizedDescription)")
    }
    report("[OBS] PTP_RESERVED_RECEIVE_PROBE_END")
  }

  private func setCameraVendorReferenceAppClientState(_ state: UInt32, reason: String) throws {
    report("设置 ReferenceApp ClientState (0xDF01 = \(state)) reason=\(reason)")
    try setCameraVendorDevicePropUInt16(
      CameraVendorDevicePropCode.initSequence,
      value: UInt16(state),
      name: "CameraVendor/ReferenceApp ClientState"
    )
    report("[OBS] PTP_SET_CLIENT_STATE_UINT16 state=\(state) reason=\(reason)")
  }

  private func setCameraVendorDevicePropUInt16(_ code: UInt32, value: UInt16, name: String) throws {
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [code],
      data: littleEndianData(value)
    )
    report("\(name) 已设置为 \(value)")
  }

  private func requestCameraVendorSearchModeDescAll() throws {
    var lastError: Error?
    for attempt in 1...CameraVendorSearchModeDescRetryPolicy.maxAttempts {
      do {
        report("按 ReferenceApp 初始化链请求 SearchModeDescAll (0x9050) attempt=\(attempt)")
        let data = try sendCommandForData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll)
        )
        let preview = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: "")
        report("[OBS] PTP_SEARCH_MODE_DESC_ALL bytes=\(data.count) head=\(preview) attempts=\(attempt)")
        return
      } catch {
        lastError = error
        guard attempt < CameraVendorSearchModeDescRetryPolicy.maxAttempts,
              CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: error) else {
          throw error
        }
        let delay = CameraVendorSearchModeDescRetryPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
        report("[OBS] PTP_SEARCH_MODE_DESC_ALL_RETRY attempt=\(attempt) delay=\(String(format: "%.1f", delay)) error=\(error.localizedDescription)")
        Thread.sleep(forTimeInterval: delay)
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: CameraVendorSearchModeDescRetryPolicy.retryableResponseCode,
      userInfo: [NSLocalizedDescriptionKey: "SearchModeDescAll retry exhausted"]
    )
  }

  private func requestCameraVendorSearchModeAll(stage: String = "initial") throws -> Data {
    report("按 ReferenceApp 初始化链请求 SearchModeAll (0x9052) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll)
    )
    let preview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_SEARCH_MODE_ALL stage=\(stage) bytes=\(data.count) head=\(preview)")
    return data
  }

  private func restoreCameraVendorSearchModeAll(_ data: Data, stage: String) throws {
    report("[OBS] PTP_RESTORE_SEARCH_MODE_ALL_BEGIN stage=\(stage) bytes=\(data.count)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: data
    )
    report("[OBS] PTP_RESTORE_SEARCH_MODE_ALL_END stage=\(stage) response=0x\(String(format: "%04X", response.responseCode))")
  }

  fileprivate func cameraVendorInitialCatalogSnapshot() throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask

    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_INITIAL_CAMERA_CATALOG_BEGIN")

    // Reset SearchMode before reading initial directory
    let resetPayload = CameraVendorSearchModeAllPayload.payload(for: [])
    report("[OBS] PTP_INITIAL_CATALOG_RESET_SEARCH_MODE payload=\(resetPayload.map { String(format: "%02x", $0) }.joined())")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: resetPayload
    )

    // Read the default directory first
    let defaultSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "initial-camera-catalog",
      allowsEmptyRetry: false
    )
    report("[OBS] PTP_INITIAL_CATALOG_DEFAULT handles=\(defaultSnapshot.handles.count)")

    // Also read D604=2 (HEIF) which on this camera returns ALL handles including HEIF
    // The default directory (1808) is missing ~617 HEIF handles
    let heifPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.heifObjectFormatMask
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: heifPayload
    )
    let expandedSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "initial-camera-catalog-expanded",
      allowsEmptyRetry: false
    )
    report("[OBS] PTP_INITIAL_CATALOG_EXPANDED handles=\(expandedSnapshot.handles.count)")

    // Restore SearchMode to empty
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: resetPayload
    )

    // Use whichever has more handles as the initial catalog
    let bestSnapshot = expandedSnapshot.handles.count > defaultSnapshot.handles.count
      ? expandedSnapshot : defaultSnapshot

    guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
      declaredCount: bestSnapshot.declaredCount,
      dateGroups: bestSnapshot.dateGroups,
      orderedHandles: bestSnapshot.handles
    ) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "相机返回的初始目录计数、日期组或句柄不一致"]
      )
    }
    let catalog = CameraVendorCatalogSnapshot(
      dateGroups: bestSnapshot.dateGroups,
      orderedHandles: bestSnapshot.handles,
      items: CameraVendorCatalogPlaceholderPolicy.placeholderItems(
        from: bestSnapshot.handles,
        dateGroups: bestSnapshot.dateGroups
      )
    )
    report(
      "[OBS] PTP_INITIAL_CAMERA_CATALOG_END groups=\(catalog.dateGroups.count) " +
      "handles=\(catalog.orderedHandles.count)"
    )
    return catalog
  }

  fileprivate func cameraVendorCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    switch query.membershipPolicy {
    case .countSweepThenApply:
      return try cameraVendorCountSweepCatalogSnapshot(query: query)
    case .subtractBaseline:
      return try cameraVendorSubtractBaselineCatalogSnapshot(query: query)
    case .direct:
      return try cameraVendorDirectCatalogSnapshot(query: query)
    }
  }

  /// HEIF/Video catalog: camera doesn't correctly filter D604=2 on this session,
  /// so we use set subtraction: (D604=X result) minus (ALL result) = format-only handles.
  /// This does not depend on ObjectInfo and completes instantly.
  private func cameraVendorSubtractBaselineCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_SUBTRACT_BASELINE_BEGIN label=\(query.label)")

    // Step 1: Read ALL directory (baseline)
    let baselineSnapshot = try CameraVendorCatalogTransactionExecutor.execute(
      backup: {
        try requestCameraVendorSearchModeAll(stage: "subtract-all-backup-\(query.label)")
      },
      perform: {
        let allPayload = CameraVendorSearchModeAllPayload.payload(for: [])
        _ = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
          data: allPayload
        )
        return try requestCameraVendorSpecifiedObjectSnapshot(
          stage: "subtract-all-\(query.label)",
          allowsEmptyRetry: false
        )
      },
      restore: { saved in
        try restoreCameraVendorSearchModeAll(saved, stage: "subtract-all-restore-\(query.label)")
      }
    )
    let baselineHandleSet = Set(baselineSnapshot.handles)
    report("[OBS] PTP_SUBTRACT_BASELINE_ALL handles=\(baselineSnapshot.handles.count)")

    // Step 2: Read format-filtered directory (D604=X, returns broad result)
    let formatSnapshot = try CameraVendorCatalogTransactionExecutor.execute(
      backup: {
        try requestCameraVendorSearchModeAll(stage: "subtract-fmt-backup-\(query.label)")
      },
      perform: {
        let payload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
        report("[OBS] PTP_SUBTRACT_FORMAT_WRITE label=\(query.label) payload=\(payload.map { String(format: "%02x", $0) }.joined())")
        _ = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
          data: payload
        )
        return try requestCameraVendorSpecifiedObjectSnapshot(
          stage: "subtract-fmt-\(query.label)",
          allowsEmptyRetry: false
        )
      },
      restore: { saved in
        try restoreCameraVendorSearchModeAll(saved, stage: "subtract-fmt-restore-\(query.label)")
      }
    )
    report("[OBS] PTP_SUBTRACT_FORMAT_RAW handles=\(formatSnapshot.handles.count)")

    // Step 3: Subtract — handles in format result but NOT in baseline = format-only
    let isolatedHandles = formatSnapshot.handles.filter { !baselineHandleSet.contains($0) }
    report(
      "[OBS] PTP_SUBTRACT_BASELINE_END label=\(query.label) " +
      "all=\(baselineSnapshot.handles.count) " +
      "format_raw=\(formatSnapshot.handles.count) " +
      "isolated=\(isolatedHandles.count)"
    )

    // Build date groups for isolated handles by mapping from the format snapshot's date groups
    let isolatedHandleSet = Set(isolatedHandles)
    var isolatedDateGroups: [CameraVendorSpecifiedObjectDateGroup] = []
    var handleCursor = 0
    for group in formatSnapshot.dateGroups {
      let groupEnd = handleCursor + Int(group.objectCount)
      let groupHandles = formatSnapshot.handles[handleCursor..<min(groupEnd, formatSnapshot.handles.count)]
      let matchCount = groupHandles.filter { isolatedHandleSet.contains($0) }.count
      if matchCount > 0 {
        isolatedDateGroups.append(CameraVendorSpecifiedObjectDateGroup(
          dateText: group.dateText,
          objectCount: UInt32(matchCount)
        ))
      }
      handleCursor = groupEnd
    }

    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: isolatedHandles,
      dateGroups: isolatedDateGroups
    )
    return CameraVendorCatalogSnapshot(
      dateGroups: isolatedDateGroups,
      orderedHandles: isolatedHandles,
      items: items
    )
  }

  /// Standard direct catalog transaction: backup -> write -> read -> restore.
  private func cameraVendorDirectCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    do {
      let catalog = try CameraVendorCatalogTransactionExecutor.execute(
        backup: {
          try requestCameraVendorSearchModeAll(
            stage: "catalog-query-backup-\(query.label)"
          )
        },
        perform: {
          let payload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
          report(
            "[OBS] PTP_CAMERA_CATALOG_BEGIN label=\(query.label) " +
            "conditions=\(query.conditions.count) bytes=\(payload.count) " +
            "payload=\(payload.map { String(format: "%02x", $0) }.joined())"
          )
          _ = try sendCommandWithData(
            operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
            data: payload
          )
          let snapshot = try requestCameraVendorSpecifiedObjectSnapshot(
            stage: "camera-catalog-\(query.label)",
            allowsEmptyRetry: false
          )
          guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
            declaredCount: snapshot.declaredCount,
            dateGroups: snapshot.dateGroups,
            orderedHandles: snapshot.handles
          ) else {
            throw NSError(
              domain: "CameraVendorPtpSession",
              code: NSURLErrorCannotParseResponse,
              userInfo: [NSLocalizedDescriptionKey: "相机返回的筛选目录计数、日期组或句柄不一致"]
            )
          }
          let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
            from: snapshot.handles,
            dateGroups: snapshot.dateGroups
          )
          return CameraVendorCatalogSnapshot(
            dateGroups: snapshot.dateGroups,
            orderedHandles: snapshot.handles,
            items: items
          )
        },
        restore: { savedSearchMode in
          try restoreCameraVendorSearchModeAll(
            savedSearchMode,
            stage: "catalog-query-restore-\(query.label)"
          )
        }
      )
      report(
        "[OBS] PTP_CAMERA_CATALOG_END label=\(query.label) groups=\(catalog.dateGroups.count) handles=\(catalog.orderedHandles.count)"
      )
      return catalog
    } catch {
      if let failure = error as? CameraGalleryCatalogTransactionFailure {
        report(
          "[OBS] PTP_CAMERA_CATALOG_FAILED label=\(query.label) " +
          "primary=\(failure.primaryMessage) restore=\(failure.restorationMessage ?? "ok")"
        )
      } else {
        report("[OBS] PTP_CAMERA_CATALOG_FAILED label=\(query.label) error=\(error.localizedDescription)")
      }
      throw error
    }
  }

  /// Count sweep then apply: replicates XApp's exact pre-apply state.
  /// 1. Backup -> sweep all formats (read count only) -> restore
  /// 2. Write D604=31 (all formats) baseline, read full directory
  /// 3. Apply target format from the D604=31 state, read filtered directory
  /// 4. Do NOT restore — leave the filter active (XApp behavior)
  private func cameraVendorCountSweepCatalogSnapshot(
    query: CameraVendorCatalogQuery
  ) throws -> CameraVendorCatalogSnapshot {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_COUNT_SWEEP_CATALOG_BEGIN label=\(query.label)")

    // Step 1: Backup current SearchMode
    let savedSearchMode = try requestCameraVendorSearchModeAll(stage: "sweep-backup-\(query.label)")

    // Step 2: Sweep each format mask (XApp order)
    let sweepOrder: [(label: String, mask: UInt16)] = [
      ("jpg", CameraVendorSearchModeAllPayload.jpegObjectFormatMask),
      ("heif", CameraVendorSearchModeAllPayload.heifObjectFormatMask),
      ("mp4", CameraVendorSearchModeAllPayload.mp4ObjectFormatMask),
      ("mov", CameraVendorSearchModeAllPayload.movObjectFormatMask),
      ("raw", CameraVendorSearchModeAllPayload.rawObjectFormatMask),
    ]
    for (label, mask) in sweepOrder {
      let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
        data: payload
      )
      let count = try requestCameraVendorSpecifiedObjectCount(stage: "sweep-\(label)")
      report("[OBS] PTP_COUNT_SWEEP_FORMAT label=\(label) mask=0x\(String(format: "%04X", mask)) count=\(count.map(String.init) ?? "nil")")
    }

    // Step 3: Restore the backed-up SearchMode
    try restoreCameraVendorSearchModeAll(savedSearchMode, stage: "sweep-restore-\(query.label)")

    // Step 4: Establish D604=31 baseline with full directory
    let allPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.allObjectFormatMask
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: allPayload
    )
    let baselineSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "sweep-baseline-\(query.label)",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE handles=\(baselineSnapshot.handles.count)"
    )

    // Step 5: Apply the target format from the D604=31 state
    let targetPayload = CameraVendorSearchModeAllPayload.payload(for: query.conditions)
    report(
      "[OBS] PTP_COUNT_SWEEP_APPLY label=\(query.label) " +
      "payload=\(targetPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: targetPayload
    )
    let filteredSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "sweep-apply-\(query.label)",
      allowsEmptyRetry: false
    )

    // Step 6: Confirm readback (do NOT restore — XApp leaves the filter active)
    _ = try requestCameraVendorSearchModeAll(stage: "sweep-confirm-\(query.label)")

    guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
      declaredCount: filteredSnapshot.declaredCount,
      dateGroups: filteredSnapshot.dateGroups,
      orderedHandles: filteredSnapshot.handles
    ) else {
      // Restore on failure
      try? restoreCameraVendorSearchModeAll(savedSearchMode, stage: "sweep-fail-restore-\(query.label)")
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "相机返回的筛选目录计数、日期组或句柄不一致"]
      )
    }

    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: filteredSnapshot.handles,
      dateGroups: filteredSnapshot.dateGroups
    )
    let catalog = CameraVendorCatalogSnapshot(
      dateGroups: filteredSnapshot.dateGroups,
      orderedHandles: filteredSnapshot.handles,
      items: items
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_CATALOG_END label=\(query.label) " +
      "baseline=\(baselineSnapshot.handles.count) " +
      "filtered=\(filteredSnapshot.handles.count)"
    )
    return catalog
  }

  /// Executes the full XApp count sweep sequence as a HEIF diagnostic experiment.
  /// This replicates the exact XApp pre-apply state:
  /// 1. Backup current SearchMode (9052)
  /// 2. Sweep each format mask writing 9051 + reading D620 count
  /// 3. Restore backup
  /// 4. Establish D604=31 baseline with full D620/D621
  /// 5. Apply D604=2 from the baseline state (no restore)
  /// 6. Confirm readback (9052)
  ///
  /// This method does NOT restore after a successful HEIF apply, matching XApp behavior.
  /// The caller is responsible for subsequent SearchMode management.
  fileprivate func cameraVendorCountSweepExperiment() throws -> CameraVendorCountSweepResult {
    let previousHandles = cameraVendorSpecifiedObjectHandles
    let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
    let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask
    defer {
      cameraVendorSpecifiedObjectHandles = previousHandles
      cameraVendorSpecifiedObjectDateGroups = previousDateGroups
      cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
    }

    report("[OBS] PTP_COUNT_SWEEP_EXPERIMENT_BEGIN")

    // Step 1: Backup current SearchMode
    let savedSearchMode = try requestCameraVendorSearchModeAll(stage: "count-sweep-backup")

    // Step 2: Sweep each format mask (XApp order: JPG, HEIF, MP4, MOV, RAW)
    let sweepOrder: [(label: String, mask: UInt16)] = [
      ("jpg", CameraVendorSearchModeAllPayload.jpegObjectFormatMask),
      ("heif", CameraVendorSearchModeAllPayload.heifObjectFormatMask),
      ("mp4", CameraVendorSearchModeAllPayload.mp4ObjectFormatMask),
      ("mov", CameraVendorSearchModeAllPayload.movObjectFormatMask),
      ("raw", CameraVendorSearchModeAllPayload.rawObjectFormatMask),
    ]
    var sweepCounts: [CameraVendorCountSweepFormatCount] = []
    for (label, mask) in sweepOrder {
      let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
      report(
        "[OBS] PTP_COUNT_SWEEP_WRITE label=\(label) mask=0x\(String(format: "%04X", mask)) " +
        "payload=\(payload.map { String(format: "%02x", $0) }.joined())"
      )
      _ = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
        data: payload
      )
      let count = try requestCameraVendorSpecifiedObjectCount(stage: "count-sweep-\(label)")
      sweepCounts.append(CameraVendorCountSweepFormatCount(label: label, mask: mask, count: count))
      report("[OBS] PTP_COUNT_SWEEP_READ label=\(label) count=\(count.map(String.init) ?? "nil")")
    }

    // Step 3: Restore the backed-up SearchMode
    try restoreCameraVendorSearchModeAll(savedSearchMode, stage: "count-sweep-restore")

    // Step 4: Establish D604=31 baseline (all formats) with full directory
    let allPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.allObjectFormatMask
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE payload=\(allPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: allPayload
    )
    let baselineSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "count-sweep-baseline-all",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_BASELINE_RESULT " +
      "count=\(baselineSnapshot.declaredCount.map(String.init) ?? "nil") " +
      "handles=\(baselineSnapshot.handles.count)"
    )

    // Step 5: Apply D604=2 from the D604=31 baseline state (XApp precondition)
    let heifPayload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
      CameraVendorSearchModeAllPayload.heifObjectFormatMask
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_HEIF_APPLY payload=\(heifPayload.map { String(format: "%02x", $0) }.joined())"
    )
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: heifPayload
    )
    let heifSnapshot = try requestCameraVendorSpecifiedObjectSnapshot(
      stage: "count-sweep-heif-apply",
      allowsEmptyRetry: false
    )
    report(
      "[OBS] PTP_COUNT_SWEEP_HEIF_RESULT " +
      "declared=\(heifSnapshot.declaredCount.map(String.init) ?? "nil") " +
      "handles=\(heifSnapshot.handles.count)"
    )

    // Step 6: Confirm readback (9052) — XApp does this, does NOT restore
    let confirmReadback = try requestCameraVendorSearchModeAll(stage: "count-sweep-heif-confirm")

    let result = CameraVendorCountSweepResult(
      sweepCounts: sweepCounts,
      baselineHandleCount: baselineSnapshot.handles.count,
      heifDeclaredCount: heifSnapshot.declaredCount,
      heifHandleCount: heifSnapshot.handles.count,
      heifHandles: heifSnapshot.handles,
      confirmReadback: confirmReadback
    )
    report("[OBS] PTP_COUNT_SWEEP_EXPERIMENT_END \(result.diagnosticSummary)")
    return result
  }

  private func primeCameraVendorCurrentImageContextIfNeeded(
    stage: String,
    galleryReadyMarker: UInt32?
  ) -> Bool {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
      galleryReadyMarker: galleryReadyMarker
    ) else {
      let marker = galleryReadyMarker.map { String(format: "0x%04X", $0) } ?? "nil"
      let reason = CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList
        ? "gallery-marker-not-ready"
        : "production-route-disabled"
      report("[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=\(reason) d222=\(marker)")
      return false
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前图上下文 (0x9054, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let result = try sendCommandForDataWithTiming(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
        parameters: [handle]
      )
      let data = result.data
      report(
        CameraVendorDataCommandTimingLogPolicy.completedMessage(
          operationCode: 0x9054,
          handle: handle,
          byteCount: data.count,
          timing: result.timing
        )
      )
      let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
      report(
        "[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME stage=\(stage) bytes=\(data.count) head=\(preview)"
      )
      return true
    } catch {
      report("[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
      return false
    }
  }

  private func primeCameraVendorCurrentThumbnailContextIfNeeded(stage: String, imagePrimeSucceeded: Bool) {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription else {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=production-route-disabled")
      return
    }

    guard imagePrimeSucceeded else {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_SKIPPED stage=\(stage) reason=image-prime-failed")
      return
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前缩略图上下文 (0x9055, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let result = try sendCommandForDataWithTiming(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb),
        parameters: [handle]
      )
      let data = result.data
      report(
        CameraVendorDataCommandTimingLogPolicy.completedMessage(
          operationCode: 0x9055,
          handle: handle,
          byteCount: data.count,
          timing: result.timing
        )
      )
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME stage=\(stage) bytes=\(data.count)")
    } catch {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
    }
  }

  private func requestCameraVendorCurrentObjectHandleSnapshot(stage: String) {
    if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleViaObjectPropList,
       let objectPropListHandle = try? readCameraVendorCurrentObjectHandleViaObjectPropList(),
       objectPropListHandle != 0 {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT stage=\(stage) source=objectPropList value=0x\(String(format: "%08X", objectPropListHandle))")
    }
    do {
      if let propHandle = try readCameraVendorCurrentObjectHandle(), propHandle != 0 {
        report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT stage=\(stage) source=deviceProp value=0x\(String(format: "%08X", propHandle))")
      }
    } catch {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SNAPSHOT_FAILED stage=\(stage) error=\(error.localizedDescription)")
    }
  }

  private func resetCameraVendorSearchModeAll(stage: String = "default") throws {
    report("按 ReferenceApp resetSearchModeAll 写入空 SearchModeAll (0x9051) stage=\(stage)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: Data([0x00, 0x00, 0x00, 0x00])
    )
    report("[OBS] PTP_SET_SEARCH_MODE_ALL_EMPTY stage=\(stage) response=0x\(String(format: "%04X", response.responseCode))")
  }

  private func setCameraVendorStillImageObjectFormatSearchMode() throws {
    let mask = CameraVendorSearchModeAllPayload.stillImageObjectFormatMask
    try setCameraVendorObjectFormatSearchMode(mask: mask, label: "STILL")
  }

  private func setCameraVendorObjectFormatSearchMode(mask: UInt16, label: String) throws {
    let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
    report(
      "[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT_BEGIN " +
      "label=\(label) " +
      "property=0x\(String(format: "%04X", CameraVendorSearchModeAllPayload.objectFormatPropertyCode)) " +
      "mask=0x\(String(format: "%04X", mask)) payload=\(payload.map { String(format: "%02x", $0) }.joined())"
    )
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: payload
    )
    report("[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT label=\(label) response=0x\(String(format: "%04X", response.responseCode))")
  }

  func resetCameraVendorCompressionMode() throws {
    report("按 ReferenceApp resetCompressionMode 写入 ImageForceCompression (0xD226 = 0)")
    let forceResponse = try setCameraVendorImageForceCompression(0, reason: "resetCompressionMode")
    report("[OBS] PTP_SET_IMAGE_FORCE_COMPRESSION_ZERO response=0x\(String(format: "%04X", forceResponse.responseCode))")

    report("按 ReferenceApp resetCompressionMode 写入 ImageCompressionRealInfo (0xD227 = 0)")
    let realInfoResponse = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
      data: littleEndianData(UInt32(0))
    )
    report("[OBS] PTP_SET_IMAGE_COMPRESSION_REAL_INFO_ZERO response=0x\(String(format: "%04X", realInfoResponse.responseCode))")
  }

  @discardableResult
  private func setCameraVendorImageForceCompression(_ mode: UInt32, reason: String) throws -> CameraVendorOperationResponse {
    report("写入 ImageForceCompression (0xD226 = \(mode)) reason=\(reason)")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.imageForceCompression],
      data: littleEndianData(UInt16(mode))
    )
    report("[OBS] PTP_SET_IMAGE_FORCE_COMPRESSION mode=\(mode) reason=\(reason) response=0x\(String(format: "%04X", response.responseCode))")
    return response
  }

  @discardableResult
  private func setCameraVendorDownloadModeProperty(
    _ property: CameraVendorDownloadModeProperty,
    handle: UInt32,
    mode: CameraVendorTransferDownloadMode,
    reason: String
  ) throws -> CameraVendorOperationResponse {
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [property.code],
      data: CameraVendorDownloadModePolicy.payload(for: property)
    )
    report(
      "[OBS] PTP_DOWNLOAD_MODE_PROPERTY " +
      "handle=0x\(String(format: "%08X", handle)) mode=\(mode) reason=\(reason) " +
      "prop=0x\(String(format: "%04X", property.code)) value=\(property.value) " +
      "width=\(property.width) response=0x\(String(format: "%04X", response.responseCode))"
    )
    return response
  }

  private func requestCameraVendorCardSlotStatus() throws {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.dualSlotStatus,
      name: "CameraVendor/ReferenceApp CardSlotStatus/DualSlotStatus (0xD244)"
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    cameraVendorCurrentSlotStatus = data.first
    report("[OBS] PTP_CARD_SLOT_STATUS bytes=\(data.count) hex=\(hex)")
  }

  private func setCameraVendorCardSlotStatus(_ slotStatus: UInt32) throws {
    report("按 ReferenceApp ChangeCardSlot 写入 DualSlotStatus (0xD244 = \(slotStatus))")
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.dualSlotStatus],
      data: littleEndianData(slotStatus)
    )
    report("[OBS] PTP_SET_CARD_SLOT_STATUS status=\(slotStatus) response=0x\(String(format: "%04X", response.responseCode))")
    try requestCameraVendorCardSlotStatus()
  }

  @discardableResult
  private func requestCameraVendorSpecifiedObjectSnapshot(
    stage: String,
    allowsEmptyRetry: Bool = true
  ) throws -> CameraVendorSpecifiedObjectSnapshot {
    var retryCount = 0
    while true {
      let attemptStage = retryCount == 0 ? stage : "\(stage)-empty-retry-\(retryCount)"
      report("[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_BEGIN stage=\(attemptStage)")
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_9053")
      }
      try requestCameraVendorSpecifiedObjectCountGroupByDate(stage: attemptStage)
      if CameraVendorCatalogWireRequestPolicy.shouldRefreshGalleryContextBeforeSpecifiedList {
        let context = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
          name: "CameraVendor/ReferenceApp 图库上下文 before specified list (0xD212)"
        )
        reportCameraVendorGalleryContextMarker(context)
        report("[OBS] PTP_D212_BEFORE_SPECIFIED_LIST stage=\(attemptStage) bytes=\(context.map { String(format: "%02x", $0) }.joined(separator: ""))")
        if attemptStage == "initial-camera-catalog" {
          report("[OBS] PTP_FACTORY_D212_4 bytes=\(context.count)")
        }
      }
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_D620")
      }
      let count = try requestCameraVendorSpecifiedObjectCount(stage: attemptStage)
      if attemptStage == "initial-camera-catalog" {
        report("[OBS] PTP_INITIAL_CAMERA_CATALOG_D621")
      }
      let handles = try requestCameraVendorSpecifiedObjectHandles(stage: attemptStage)
      let snapshot = CameraVendorSpecifiedObjectSnapshot(
        declaredCount: count,
        dateGroups: cameraVendorSpecifiedObjectDateGroups,
        handles: handles
      )
      report(
        "[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_END stage=\(attemptStage) " +
        "count=\(count.map(String.init) ?? "nil") handles=\(handles.count)"
      )

      guard CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: count,
        handles: handles,
        retryCount: retryCount,
        isRequiredPrimaryList: allowsEmptyRetry
      ) else {
        return snapshot
      }

      retryCount += 1
      report(
        "[OBS] PTP_SPECIFIED_OBJECT_EMPTY_RECOVERY " +
        "stage=\(stage) retry=\(retryCount) delay=\(String(format: "%.1f", CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.retryDelaySeconds))"
      )
      Thread.sleep(forTimeInterval: CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.retryDelaySeconds)
      try requestCameraVendorSearchModeDescAll()
      if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList {
        requestCameraVendorCurrentObjectHandleSnapshot(stage: "\(stage)-empty-recovery")
      }
    }
  }

  private func requestCameraVendorSpecifiedObjectCountGroupByDate(stage: String = "default") throws {
    report("按 ReferenceApp 图片列表链请求 SpecifiedObjectCountGroupByDate (0x9053, offset=0, count=30000) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate),
      parameters: [0, 30000]
    )
    let groups = CameraVendorPtpDataParser.specifiedObjectDateGroups(from: data)
    cameraVendorSpecifiedObjectDateGroups = groups
    let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
    let groupSummary = groups.map { "\($0.dateText):\($0.objectCount)" }.joined(separator: ",")
    report("[OBS] PTP_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE stage=\(stage) bytes=\(data.count) groups=\(groupSummary) head=\(preview)")
  }

  private func requestCameraVendorSpecifiedObjectCount(stage: String = "default") throws -> UInt32? {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.specifiedObjectCount,
      name: "CameraVendor/ReferenceApp SpecifiedObjectCount (0xD620)"
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    let value = data.count >= 4
      ? UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
      : nil
    report("[OBS] PTP_SPECIFIED_OBJECT_COUNT stage=\(stage) bytes=\(data.count) value=\(value.map(String.init) ?? "nil") hex=\(hex)")
    return value
  }

  private func requestCameraVendorSpecifiedObjectHandles(stage: String = "default") throws -> [UInt32] {
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.specifiedObjectHandles,
      name: "CameraVendor/ReferenceApp SpecifiedObjectHandles (0xD621)"
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    let handles = CameraVendorPtpDataParser.uint32Array(from: data)
    cameraVendorSpecifiedObjectHandles = handles
    report(
      "[OBS] PTP_SPECIFIED_OBJECT_HANDLES stage=\(stage) bytes=\(data.count) handles=" +
      handles.map { String(format: "0x%08X", $0) }.joined(separator: ",") +
      " hex=\(hex)"
    )
    return handles
  }

  private func readCameraVendorDeviceProperty(
    code: UInt32,
    name: String,
    timingHandler: ((CameraVendorDataCommandTiming, Int) -> Void)? = nil
  ) throws -> Data {
    report("读取 \(name)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [code],
      timingHandler: timingHandler
    )
    report("\(name): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
    return data
  }

  private func validateCameraVendorGalleryReadyMarker(_ context: Data) throws {
    let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: context
    )
    if CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: marker) {
      report("[OBS] PTP_D222_READY value=\(marker.map { String(format: "0x%04X", $0) } ?? "nil")")
      return
    }
    let actual = marker.map { String(format: "0x%04X", $0) } ?? "nil"
    if CameraVendorGalleryHandshakeDiagnosticPolicy.isD222ObservationOnly(
      hasSuccessfulPtpHandshake: true,
      marker: marker
    ) {
      report("[OBS] PTP_D222_NOT_READY_DIAGNOSTIC value=\(actual) expected=0x0992")
      return
    }
    report("[OBS] PTP_D222_NOT_READY_DIAGNOSTIC value=\(actual) expected=0x0992")
  }

  private func littleEndianData(_ value: UInt16) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  private func littleEndianData(_ value: UInt32) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  private func cameraVendorPropValueDescription(_ data: Data) -> String {
    let hex = data.map { String(format: "%02x", $0) }.joined()
    if data.count >= 4 {
      let value = UInt32(data[0]) |
        (UInt32(data[1]) << 8) |
        (UInt32(data[2]) << 16) |
        (UInt32(data[3]) << 24)
      return "\(value) hex=\(hex)"
    }
    if data.count >= 2 {
      let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
      return "\(value) hex=\(hex)"
    }
    return "bytes=\(data.count) hex=\(hex)"
  }

  private func waitForCameraAccess() throws {
    let maxPolls = 40
    for i in 1...maxPolls {
      do {
        let stateData = try sendCommandForData(
          operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
          parameters: [CameraVendorDevicePropCode.cameraState]
        )
        if stateData.count >= 2 {
          let state = stateData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
          report("CameraState 轮询 #\(i): 0x\(String(state, radix: 16))")
          if state != 0 {
            report("相机已授权访问")
            return
          }
        }
      } catch {
        report("CameraState 轮询 #\(i) 失败: \(error.localizedDescription)")
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
    report("相机授权等待超时，继续尝试")
  }

  private func performInitHandshake(
    host: String,
    clientName: String
  ) throws -> (connectionNumber: UInt32, operationTransport: CameraVendorPtpOperationTransport) {
    let clientIP = getWifiIPv4Address()
    report("客户端 IP: \(clientIP ?? "nil")")
    report("PTP 客户端名称: \(clientName)")
    report("[OBS] PTP_INIT_CONTEXT clientIP=\(clientIP ?? "nil") clientName=\(clientName)")

    let attempts = CameraVendorOfficialGalleryPtpInitPolicy.initAttempts(
      clientName: clientName,
      clientIP: clientIP
    )

    var lastError: Error?
    for (index, attempt) in attempts.enumerated() {
      if index > 0 {
        report("重新建立 PTP socket，尝试 \(attempt.name) INIT")
        commandSocket.close()
        try commandSocket.connect(
          host: host,
          port: CameraVendorPtpConstants.commandPort,
          timeout: CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
          diagnosticHandler: diagnosticHandler,
          networkServiceProfile: networkServiceProfile,
          socketBufferProfile: socketBufferProfile,
          tcpNoDelayPolicy: tcpNoDelayPolicy
        )
      }

      do {
        let connectionNumber = try sendInitCommandRequest(
          packet: attempt.packet,
          variantName: attempt.name,
          timeout: attempt.timeout
        )
        return (connectionNumber, .cameraVendorLegacy)
      } catch {
        lastError = error
        report("\(attempt.name) INIT 未收到 ACK: \(error.localizedDescription)")
      }
    }

    throw lastError ?? NSError(
      domain: "CameraVendorPtpSession",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "PTP 初始化失败"]
    )
  }

  private func sendInitCommandRequest(
    packet: Data,
    variantName: String,
    timeout: TimeInterval
  ) throws -> UInt32 {
    report("发送 \(variantName) PTP INIT_COMMAND_REQUEST (\(packet.count) bytes)")
    report("\(variantName) INIT hex: \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
    report("[OBS] PTP_INIT_REQUEST variant=\(variantName) bytes=\(packet.count)")
    try commandSocket.write(packet)
    Thread.sleep(forTimeInterval: 0.05)
    report("等待 \(variantName) PTP INIT_COMMAND_ACK (超时 \(Int(timeout))s)")
    let initAck = try readPacket(from: commandSocket, timeout: timeout)
    if initAck.type == CameraVendorPtpPacketType.initFail {
      let reason = initAck.payload.count >= 4
        ? "0x\(String(initAck.payload.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }, radix: 16))"
        : "unknown"
      throw NSError(domain: "CameraVendorPtpSession", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "相机拒绝连接 (InitFail reason=\(reason))。可能需要在相机上选择「更改」以接受新客户端。"
      ])
    }
    guard initAck.type == CameraVendorPtpPacketType.initCommandAck else {
      throw NSError(domain: "CameraVendorPtpSession", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "相机返回未知包类型 \(initAck.type)，期望 InitCommandAck"
      ])
    }
    guard initAck.payload.count >= 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "PTP 初始化 ACK 长度异常"])
    }
    return initAck.payload.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
  }

  func storageIDs() throws -> [UInt32] {
    report("请求 storage IDs")
    let ids = CameraVendorPtpDataParser.uint32Array(
      from: try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getStorageIDs))
    )
    report("收到 storage IDs: \(ids.map(String.init).joined(separator: ", "))")
    return ids
  }

  func objectHandles(storageID: UInt32) throws -> [UInt32] {
    report("请求对象句柄，storageID \(storageID)")
    let handles = CameraVendorPtpDataParser.uint32Array(
      from: try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.getObjectHandles),
        parameters: [storageID, UInt32(CameraVendorPtpConstants.allFormats), UInt32(bitPattern: Int32(-1))]
      )
    )
    report("收到对象句柄 \(handles.count) 个，storageID \(storageID)")
    return handles
  }

  func objectInfo(
    handle: UInt32,
    readTimeout: TimeInterval = 15
  ) throws -> CameraVendorCameraObjectInfo {
    report("请求对象信息 handle \(handle)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getObjectInfo),
      parameters: [handle],
      readTimeout: readTimeout
    )
    let info = CameraVendorPtpDataParser.objectInfo(handle: Int(handle), data: data)
    report(
      "对象 \(handle): \(info.filename) \(info.formatLabel) " +
      "size=\(info.compressedSize) thumbSize=\(info.thumbCompressedSize) captureDate=\(info.captureDate)"
    )
    return info
  }

  func reservedReceiveObjectInfo() throws -> CameraVendorCameraObjectInfo {
    let handle = CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle
    report("[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_INFO_BEGIN handle=0x\(String(format: "%08X", handle))")
    let info = try objectInfo(handle: handle)
    report(
      "[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_INFO_OK " +
      "handle=\(info.handle) format=\(info.formatLabel) filename=\(info.filename) size=\(info.compressedSize)"
    )
    return info
  }

  func reservedReceiveDiagnosticObject() throws -> CameraVendorReservedReceiveDiagnosticResult {
    let handle = CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle
    let info = try reservedReceiveObjectInfo()

    let sample = try readObjectSample(
      handle: handle,
      byteCount: CameraVendorReferenceAppReservedReceiveProbePolicy.sampleReadBytes
    )
    report(
      "[OBS] PTP_RESERVED_RECEIVE_READ_IMAGE_SAMPLE_OK " +
      "handle=0x\(String(format: "%08X", handle)) bytes=\(sample.count)"
    )
    return CameraVendorReservedReceiveDiagnosticResult(
      objectInfo: info,
      sampleByteCount: sample.count
    )
  }

  func cameraVendorLatestObjectInfo(preferredHandle: UInt32? = nil) throws -> CameraVendorCameraObjectInfo {
    try prepareCameraVendorVendorGalleryCommands()
    let handle = preferredHandle ?? cameraVendorCurrentObjectHandleForLatestProbe()
      ?? CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report("请求 CameraVendor 专有图库首图信息 (0x9054, handle 0x\(String(format: "%08X", handle)))")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
      parameters: [handle]
    )
    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: Int(handle), data: data)
    report("CameraVendor 专有图库首图: \(info.filename) \(info.formatLabel)")
    return info
  }

  private func cameraVendorCurrentObjectHandleForLatestProbe() -> UInt32? {
    guard CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleBeforeLatestProbe else {
      return nil
    }
    if CameraVendorCatalogWireRequestPolicy.shouldReadCurrentObjectHandleViaObjectPropList,
       let currentHandle = try? readCameraVendorCurrentObjectHandleViaObjectPropList(),
       currentHandle != 0 {
      return currentHandle
    }
    do {
      if let currentHandle = try readCameraVendorCurrentObjectHandle(), currentHandle != 0 {
        return currentHandle
      }
    } catch {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_FAILED error=\(error.localizedDescription)")
    }
    return nil
  }

  private func readCameraVendorCurrentObjectHandleViaObjectPropList() throws -> UInt32? {
    report("尝试 MTP GetObjectPropList 读取当前对象 handle (0x9805 / 0xD22B)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.mtpGetObjectPropList),
      parameters: CameraVendorPtpPacketBuilder.mtpObjectPropListParameters(
        objectHandle: UInt32(bitPattern: -1),
        propertyCode: CameraVendorDevicePropCode.currentObjectHandle
      )
    )
    let hex = data.map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_OBJECT_PROP_LIST_D22B bytes=\(data.count) hex=\(hex)")
    guard data.count >= 16 else {
      return nil
    }
    let tail = data.count - 4
    let candidate =
      UInt32(data[tail]) |
      (UInt32(data[tail + 1]) << 8) |
      (UInt32(data[tail + 2]) << 16) |
      (UInt32(data[tail + 3]) << 24)
    report("[OBS] PTP_OBJECT_PROP_LIST_D22B_CANDIDATE_HANDLE value=0x\(String(format: "%08X", candidate))")
    return candidate
  }

  private func readCameraVendorCurrentObjectHandle() throws -> UInt32? {
    report("读取 CameraVendor/ReferenceApp 当前对象 handle (0xD22B)")
    let data = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.currentObjectHandle,
      name: "CameraVendor/ReferenceApp 当前对象 handle (0xD22B)",
      timingHandler: { [weak self] timing, byteCount in
        self?.report(
          CameraVendorDataCommandTimingLogPolicy.completedMessage(
            operationCode: 0xD22B,
            handle: nil,
            byteCount: byteCount,
            timing: timing
          )
        )
      }
    )
    guard data.count >= 4 else {
      report("[OBS] PTP_CURRENT_OBJECT_HANDLE_SHORT bytes=\(data.count)")
      return nil
    }
    let handle = data.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    report("[OBS] PTP_CURRENT_OBJECT_HANDLE value=0x\(String(format: "%08X", handle))")
    return handle
  }

  private func prepareCameraVendorVendorGalleryCommands() throws {
    report("CameraVendor/ReferenceApp 图库前置命令已按 ReferenceApp 顺序完成，直接请求 0x9054")
  }

  private func reportCameraVendorGalleryContextMarker(_ context: Data) {
    let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: context
    )
    report(
      "CameraVendor/ReferenceApp 图库上下文 0xD222=" +
      (marker.map { String(format: "0x%04X", $0) } ?? "nil") +
      " (ReferenceApp ready=0x\(String(format: "%04X", CameraVendorReferenceAppGalleryReadyPolicy.readyMarker)))"
    )
  }

  func thumb(handle: UInt32) throws -> Data {
    try thumb(handle: handle, expectedSize: nil)
  }

  func thumb(handle: UInt32, expectedSize: UInt32?) throws -> Data {
    try thumbWithInfo(handle: handle, expectedSize: expectedSize).data
  }

  func thumbWithInfo(handle: UInt32, expectedSize: UInt32?) throws -> CameraVendorThumbnailFetchResult {
    let operationInterruptionGeneration = priorityDownloadInterruptionGeneration
    var standardGetThumbError: Error?
    if CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst {
      do {
        let result = try readStandardThumbnailObjectWithInfo(handle: handle)
        return CameraVendorThumbnailFetchResult(
          data: normalizedThumbnailData(result.data, handle: handle, source: "standardGetThumb"),
          objectInfo: result.objectInfo
        )
      } catch {
        standardGetThumbError = error
        report("[OBS] PTP_GET_THUMB_FALLBACK_TO_PARTIAL handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }

    let wasInterruptedForPriorityDownload =
      priorityDownloadInterruptionGeneration != operationInterruptionGeneration
    guard CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
      afterPriorityDownloadInterruption: wasInterruptedForPriorityDownload,
      isConnected: isConnected
    ) else {
      report("[OBS] PTP_GET_THUMB_PARTIAL_FALLBACK_SKIPPED_FOR_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw standardGetThumbError ?? CancellationError()
    }

    guard CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback else {
      throw standardGetThumbError ?? NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorPtpOperationCode.getThumb),
        userInfo: [
          NSLocalizedDescriptionKey: "Thumbnail fallback is disabled"
        ]
      )
    }

    let data = try readPreviewObject(handle: handle, size: CameraVendorThumbnailFetchPolicy.partialPreviewReadSize)
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW_EXPECTED handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0) bytes=\(data.count)")
    return CameraVendorThumbnailFetchResult(
      data: normalizedThumbnailData(data, handle: handle, source: "standardPartialPreview"),
      objectInfo: nil
    )
  }

  private func readStandardThumbnailObject(handle: UInt32) throws -> Data {
    try readStandardThumbnailObjectWithInfo(handle: handle).data
  }

  private func readStandardThumbnailObjectWithInfo(handle: UInt32) throws -> CameraVendorThumbnailFetchResult {
    let primedObjectInfo = CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb
      ? primeThumbnailObjectContext(handle: handle)
      : nil

    report("[OBS] PTP_GET_THUMB_REQUEST handle=0x\(String(format: "%08X", handle))")
    let startedAt = Date()
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getThumb),
      parameters: [handle],
      readTimeout: CameraVendorThumbnailFetchPolicy.standardGetThumbReadTimeoutSeconds
    )
    report(
      "[OBS] PTP_GET_THUMB_DATA bytes=\(data.count) handle=0x\(String(format: "%08X", handle)) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
    guard data.count >= CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorPtpOperationCode.getThumb),
        userInfo: [
          NSLocalizedDescriptionKey: "GetThumb returned too few bytes: \(data.count)"
        ]
      )
    }
    // The catalog merge keeps its confirmed identity fields. Carry the primed
    // ObjectInfo with this thumbnail so its orientation reaches the renderer.
    return CameraVendorThumbnailResultPolicy.result(
      data: data,
      primedObjectInfo: primedObjectInfo
    )
  }

  private func primeThumbnailObjectContext(handle: UInt32) -> CameraVendorCameraObjectInfo? {
    let startedAt = Date()
    do {
      let info = try cameraVendorLatestObjectInfo(preferredHandle: handle)
      report(
        "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED handle=0x\(String(format: "%08X", handle)) " +
        "format=0x\(String(format: "%04X", info.formatCode)) thumbBytes=\(info.thumbCompressedSize) " +
        "orientation=\(info.orientation.map(String.init) ?? "unknown") " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
      )
      return info
    } catch {
      report(
        "[OBS] PTP_GET_THUMB_VENDOR_CONTEXT_PRIME_FAILED handle=0x\(String(format: "%08X", handle)) " +
        "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)"
      )
      do {
        let fallbackStartedAt = Date()
        let info = try objectInfo(handle: handle)
        report(
          "[OBS] PTP_GET_THUMB_CONTEXT_PRIMED_STANDARD handle=0x\(String(format: "%08X", handle)) " +
          "format=0x\(String(format: "%04X", info.formatCode)) thumbBytes=\(info.thumbCompressedSize) " +
          "orientation=\(info.orientation.map(String.init) ?? "unknown") " +
          "elapsedMs=\(Int(Date().timeIntervalSince(fallbackStartedAt) * 1000))"
        )
        return info
      } catch {
        report(
          "[OBS] PTP_GET_THUMB_CONTEXT_PRIME_FAILED handle=0x\(String(format: "%08X", handle)) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(error.localizedDescription)"
        )
        return nil
      }
    }
  }

  private func readPreviewObject(handle: UInt32, size previewReadSize: UInt32) throws -> Data {
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=preview " +
      "handle=0x\(String(format: "%08X", handle)) offset=0 size=\(previewReadSize)"
    )
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: handle,
        offset: 0,
        size: previewReadSize
      )
    )
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW bytes=\(data.count) handle=0x\(String(format: "%08X", handle))")
    return data
  }

  func previewImage(handle: UInt32) throws -> Data {
    try previewImageWithInfo(handle: handle).data
  }

  func previewImageWithInfo(handle: UInt32) throws -> CameraVendorPreviewImageFetchResult {
    report("[OBS] PTP_PREVIEW_IMAGE_REQUEST handle=0x\(String(format: "%08X", handle))")
    let initialInfo = try objectInfo(handle: handle)
    guard initialInfo.formatLabel == "JPG" || initialInfo.formatLabel == "HEIF" else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 21,
        userInfo: [NSLocalizedDescriptionKey: "Compressed preview unavailable handle=\(handle) format=\(initialInfo.formatLabel)"]
      )
    }
    try setCameraVendorImageForceCompression(1, reason: "previewImage")
    defer {
      do {
        try setCameraVendorImageForceCompression(0, reason: "previewImageReset")
      } catch {
        report("[OBS] PTP_PREVIEW_IMAGE_RESET_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }
    let previewInfo = try objectInfo(handle: handle)
    guard previewInfo.compressedSize > 0,
          previewInfo.compressedSize <= 8 * 1024 * 1024 else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 22,
        userInfo: [NSLocalizedDescriptionKey: "Compressed preview size unavailable handle=\(handle) size=\(previewInfo.compressedSize)"]
      )
    }
    let data = try readPreviewObject(handle: handle, size: previewInfo.compressedSize)
    let image = CameraVendorImageDataNormalizer.imageData(from: data)
    guard CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(image) else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 23,
        userInfo: [
          NSLocalizedDescriptionKey: "Preview image invalid handle=\(handle) bytes=\(image.count) head=\(CameraVendorDownloadDataDiagnosticPolicy.headHex(from: image))"
        ]
      )
    }
    report(
      "[OBS] PTP_PREVIEW_IMAGE_COMPRESSED handle=0x\(String(format: "%08X", handle)) " +
      "rawBytes=\(data.count) imageBytes=\(image.count) readSize=\(previewInfo.compressedSize) " +
      "object=\(previewInfo.formatLabel)"
    )
    return CameraVendorPreviewImageFetchResult(data: image, objectInfo: previewInfo)
  }

  private func readObjectSample(handle: UInt32, byteCount: UInt32) throws -> Data {
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=reserved-receive-sample " +
      "handle=0x\(String(format: "%08X", handle)) offset=0 size=\(byteCount)"
    )
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: handle,
        offset: 0,
        size: byteCount
      )
    )
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_SAMPLE bytes=\(data.count) handle=0x\(String(format: "%08X", handle))")
    return data
  }

  private func readObjectByPartialObjects(
    handle: UInt32,
    expectedSize: UInt32?,
    purpose: String,
    usesFileDownloadChunks: Bool = true
  ) throws -> Data {
    var received = Data()
    if let expected = expectedSize, expected > 0 {
      // Pre-allocate so chunk appends don't trigger O(n) reallocations.
      received.reserveCapacity(Int(expected))
    }
    var offset: UInt64 = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(
      expectedSize: expectedSize
    )
    var isJpegObject = false
    let startedAt = Date()
    let cachedReadSize = usesFileDownloadChunks
      ? originalTransferCapabilityStore.readSize(serialNumber: transferCapabilitySerialNumber)
      : nil
    let initialReadSize = CameraVendorTransferChunkProfile.preferredReadSize(
      cachedReadSize: cachedReadSize
    )
    var selectedReadSize = initialReadSize

    while offset < maxByteCount {
      let remaining = maxByteCount - offset
      let requestSize = usesFileDownloadChunks
        ? CameraVendorTransferChunkProfile.requestSize(
          remaining: remaining,
          selectedReadSize: selectedReadSize
        )
        : UInt32(min(UInt64(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize), remaining))
      let chunkStartedAt = Date()
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) expected=\(expectedSize ?? 0)"
      )
      let parameters = CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: handle,
        offset: offset,
        size: requestSize
      )
      let chunk: Data
      do {
        chunk = usesFileDownloadChunks
          ? try sendCommandForData(
            operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
            parameters: parameters,
            readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
          )
          : try sendCommandForData(
            operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
            parameters: parameters
          )
      } catch {
        if usesFileDownloadChunks,
           CameraVendorTransferChunkProfile.shouldFallback(
             after: error,
             sessionIsConnected: isConnected
           ), let fallbackReadSize = CameraVendorTransferChunkProfile.fallbackReadSize(
             after: selectedReadSize
           ) {
          selectedReadSize = fallbackReadSize
          continue
        }
        throw error
      }
      guard !chunk.isEmpty else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }

      received.append(chunk)
      if offset == 0 {
        isJpegObject = CameraVendorJpegDataPolicy.hasStartMarker(CameraVendorImageDataNormalizer.imageData(from: received))
      }
      offset += UInt64(chunk.count)
      let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(chunk.count) " +
        "totalBytes=\(received.count) chunkMs=\(chunkElapsedMs) " +
        "isJpeg=\(isJpegObject)"
      )

      let hasJpegEndMarker = CameraVendorJpegDataPolicy.hasEndMarker(received)
      if CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: received.count,
        expectedBytes: expectedByteCount,
        isJpegObject: isJpegObject,
        hasJpegEndMarker: hasJpegEndMarker
      ) {
        if usesFileDownloadChunks,
           CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
             totalBytes: received.count,
             expectedBytes: expectedByteCount,
             hasJpegEndMarker: hasJpegEndMarker
           ) {
          _ = persistOriginalTransferCapability(readSize: selectedReadSize)
        }
        let reason = hasJpegEndMarker ? "jpeg-eoi" : "expected-size"
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=\(reason) " +
          "handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
        return received
      }
    }

    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=max-or-empty " +
      "handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
    )
    return received
  }

  private struct CameraVendorPartialObjectFileTransferResult {
    let byteCount: Int
    let requestToFirstByteMs: Int
    let socketReceiveMs: Int
    let fileWriteMs: Int
    let elapsedMs: Int
    let executor: String
    let initialReadSize: UInt32
    let finalReadSize: UInt32
    let fallbackCount: Int
  }

  private func readObjectByPartialObjectsToFile(
    handle: UInt32,
    expectedSize: UInt32?,
    fileURL: URL,
    purpose: String,
    formatLabel: String,
    downloadMode: CameraVendorTransferDownloadMode,
    cancellationGeneration: UInt64,
    negotiatedReadSize: UInt32?
  ) throws -> CameraVendorPartialObjectFileTransferResult {
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    let handleForWriting = try FileHandle(forWritingTo: fileURL)
    defer {
      try? handleForWriting.close()
    }

    var offset: UInt64 = 0
    var totalBytes = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(
      expectedSize: expectedSize
    )
    let startedAt = Date()
    let cachedReadSize = originalTransferCapabilityStore.readSize(
      serialNumber: transferCapabilitySerialNumber
    )
    let initialReadSize = CameraVendorTransferChunkProfile.preferredReadSize(
      cachedReadSize: cachedReadSize
    )
    let capabilitySource = cachedReadSize == nil ? "maximum" : "cached"
    var chunkState = CameraVendorAdaptiveDownloadChunkState(readSize: initialReadSize)
    var fallbackCount = 0
    var requestToFirstByteMs = 0
    var socketReceiveMs = 0
    var fileWriteMs = 0

    if CameraVendorOriginalReadImageExecutorPolicy.shouldUse(
      downloadMode: downloadMode,
      purpose: purpose
    ) {
      let dedicatedInitialReadSize = CameraVendorOriginalReadImageExecutorPolicy.initialReadSize(
        cachedReadSize: cachedReadSize,
        negotiatedReadSize: negotiatedReadSize
      )
      let dedicatedProfileSource = CameraVendorOriginalReadImageExecutorPolicy.profileSource(
        negotiatedReadSize: negotiatedReadSize
      )
      report(
        "[OBS] PTP_DOWNLOAD_REQUEST_PROFILE " +
        "handle=0x\(String(format: "%08X", handle)) d235=\(negotiatedReadSize ?? 0) " +
        "selectedReadSize=\(dedicatedInitialReadSize) source=\(dedicatedProfileSource)"
      )
      let executor = CameraVendorOriginalReadImageExecutor(
        nextTransactionID: {
          self.transactionID += 1
          return self.transactionID
        },
        sendRequest: { transactionID, requestedHandle, requestedOffset, requestedSize in
          self.report(
            "[OBS] PTP_ORIGINAL_READ_IMAGE_REQUEST purpose=\(purpose) " +
            "handle=0x\(String(format: "%08X", requestedHandle)) transaction=\(transactionID) " +
            "offset=\(requestedOffset) size=\(requestedSize) expected=\(expectedSize ?? 0)"
          )
          try self.sendOriginalReadImageRequest(
            transactionID: transactionID,
            handle: requestedHandle,
            offset: requestedOffset,
            size: requestedSize
          )
        },
        receivePayloadAndResponse: { transactionID, expectedMaximum, sink in
          let chunk = try self.receiveOriginalReadImagePayloadAndResponse(
            transactionID: transactionID,
            expectedMaximum: expectedMaximum,
            fileHandle: sink,
            readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
          )
          return chunk
        },
        cancellationCheck: {
          try self.throwIfActiveDownloadCancelled(since: cancellationGeneration)
        },
        fallbackReadSize: { error, currentReadSize, _ in
          guard CameraVendorTransferChunkProfile.shouldFallback(
            after: error,
            sessionIsConnected: self.isConnected
          ) else {
            return nil
          }
          return CameraVendorTransferChunkProfile.fallbackReadSize(after: currentReadSize)
        },
        report: { self.report($0) }
      )
      let callerThreadID = pthread_mach_thread_np(pthread_self())
      let result = try originalTransferWorker.execute {
        let workerThreadID = pthread_mach_thread_np(pthread_self())
        self.report(
          "[OBS] PTP_ORIGINAL_TRANSFER_WORKER_BEGIN " +
          "handle=0x\(String(format: "%08X", handle)) " +
          "callerThread=\(callerThreadID) workerThread=\(workerThreadID)"
        )
        defer {
          self.report(
            "[OBS] PTP_ORIGINAL_TRANSFER_WORKER_END " +
            "handle=0x\(String(format: "%08X", handle)) " +
            "workerThread=\(workerThreadID)"
          )
        }
        return try executor.execute(
          handle: handle,
          expectedByteCount: expectedByteCount,
          maximumByteCount: maxByteCount,
          initialReadSize: dedicatedInitialReadSize,
          fileHandle: handleForWriting,
          withSerializedLease: { body in
            try self.withSerializedCommand {
              try body()
            }
          }
        )
      }
      let capabilityPersisted = CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: result.byteCount,
        expectedBytes: expectedByteCount,
        hasJpegEndMarker: false
      ) ? persistOriginalTransferCapability(readSize: result.finalReadSize) : false
      let speedMBps = result.elapsedMs > 0
        ? (Double(result.byteCount) / 1_048_576.0) / (Double(result.elapsedMs) / 1000.0)
        : 0
      let headHex = CameraVendorDownloadDataDiagnosticPolicy.headHex(from: result.prefix)
      let ftypOffset = CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: result.prefix)
      report(
        "[OBS] PTP_ORIGINAL_RECEIVE_CADENCE " +
        "handle=0x\(String(format: "%08X", handle)) " +
        "pollWaitMs=\(result.receiveCadence.pollWaitMs) " +
        "maxPollWaitMs=\(result.receiveCadence.maxPollWaitMs) " +
        "pollWaitCount=\(result.receiveCadence.pollWaitCount) " +
        "immediatePollCount=\(result.receiveCadence.immediatePollCount) " +
        "recvCallCount=\(result.receiveCadence.recvCallCount)"
      )
      report(
        "[OBS] PTP_ORIGINAL_READ_IMAGE_HEAD purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) bytes=\(result.byteCount) " +
        "head=\(headHex) ftypOffset=\(ftypOffset.map(String.init) ?? "nil")"
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_TIMING executor=original-read-image " +
        "handle=0x\(String(format: "%08X", handle)) format=\(formatLabel) mode=\(downloadMode) " +
        "bytes=\(result.byteCount) initialReadSize=\(dedicatedInitialReadSize) finalReadSize=\(result.finalReadSize) " +
        "fallbackCount=\(result.fallbackCount) capabilitySource=\(dedicatedProfileSource) " +
        "capabilityPersisted=\(capabilityPersisted) requestToFirstByteMs=\(result.requestToFirstByteMs) " +
        "socketReceiveMs=\(result.socketReceiveMs) fileWriteMs=\(result.fileWriteMs) " +
        "elapsedMs=\(result.elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
      )
      return CameraVendorPartialObjectFileTransferResult(
        byteCount: result.byteCount,
        requestToFirstByteMs: result.requestToFirstByteMs,
        socketReceiveMs: result.socketReceiveMs,
        fileWriteMs: result.fileWriteMs,
        elapsedMs: result.elapsedMs,
        executor: "original-read-image",
        initialReadSize: dedicatedInitialReadSize,
        finalReadSize: result.finalReadSize,
        fallbackCount: result.fallbackCount
      )
    }

    while offset < maxByteCount {
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      let remaining = maxByteCount - offset
      let requestSize = CameraVendorTransferChunkProfile.requestSize(
        remaining: remaining,
        selectedReadSize: chunkState.readSize
      )
      let chunkStartedAt = Date()
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) " +
        "adaptiveReadSize=\(chunkState.readSize) strategy=\(CameraVendorAdaptiveDownloadChunkPolicy.strategyName) " +
        "slowLargeChunks=\(chunkState.consecutiveSlowLargeChunks) expected=\(expectedSize ?? 0)"
      )
      let streamedChunk: CameraVendorFileCommandResult
      do {
        streamedChunk = try sendCommandForFileData(
          operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
          parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
            handle: handle,
            offset: offset,
            size: requestSize
          ),
          fileHandle: handleForWriting,
          readTimeout: CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds
        )
      } catch {
        if CameraVendorTransferChunkProfile.shouldFallback(
          after: error,
          sessionIsConnected: isConnected
        ), let fallbackReadSize = CameraVendorTransferChunkProfile.fallbackReadSize(after: chunkState.readSize) {
          let previousReadSize = chunkState.readSize
          chunkState.readSize = fallbackReadSize
          chunkState.consecutiveFastChunks = 0
          fallbackCount += 1
          report(
            "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_FALLBACK_READ_SIZE " +
            "handle=0x\(String(format: "%08X", handle)) offset=\(offset) " +
            "from=\(previousReadSize) to=\(chunkState.readSize) " +
            "error=\(error.localizedDescription)"
          )
          continue
        }
        throw error
      }
      requestToFirstByteMs += streamedChunk.requestToFirstByteMs
      socketReceiveMs += streamedChunk.socketReceiveMs
      fileWriteMs += streamedChunk.fileWriteMs
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      guard streamedChunk.byteCount > 0 else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }
      if offset == 0 {
        let headHex = CameraVendorDownloadDataDiagnosticPolicy.headHex(from: streamedChunk.prefix)
        let ftypOffset = CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: streamedChunk.prefix)
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_HEAD purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) bytes=\(streamedChunk.byteCount) " +
          "head=\(headHex) ftypOffset=\(ftypOffset.map(String.init) ?? "nil")"
        )
      }
      totalBytes += streamedChunk.byteCount
      offset += UInt64(streamedChunk.byteCount)
      let chunkElapsedMs = Int(Date().timeIntervalSince(chunkStartedAt) * 1000)
      let previousReadSize = chunkState.readSize
      CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
        byteCount: streamedChunk.byteCount,
        elapsedMs: chunkElapsedMs,
        state: &chunkState
      )
      if previousReadSize != chunkState.readSize {
        report(
          "[OBS] PTP_ADAPTIVE_CHUNK_SIZE_CHANGED purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) from=\(previousReadSize) " +
          "to=\(chunkState.readSize) strategy=\(CameraVendorAdaptiveDownloadChunkPolicy.strategyName) " +
          "chunkBytes=\(streamedChunk.byteCount) chunkMs=\(chunkElapsedMs)"
        )
      }
      report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK purpose=\(purpose) " +
          "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(streamedChunk.byteCount) totalBytes=\(totalBytes) " +
        "chunkMs=\(chunkElapsedMs) nextReadSize=\(chunkState.readSize) " +
        "slowLargeChunks=\(chunkState.consecutiveSlowLargeChunks)"
      )
      if let expectedByteCount, UInt64(totalBytes) >= expectedByteCount {
        let capabilityPersisted = CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
          totalBytes: totalBytes,
          expectedBytes: expectedByteCount,
          hasJpegEndMarker: false
        ) ? persistOriginalTransferCapability(readSize: chunkState.readSize) : false
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let speedMBps = elapsedMs > 0
          ? (Double(totalBytes) / 1_048_576.0) / (Double(elapsedMs) / 1000.0)
          : 0
        report(
          "[OBS] PTP_DOWNLOAD_FILE_TIMING handle=0x\(String(format: "%08X", handle)) " +
            "format=\(formatLabel) mode=\(downloadMode) bytes=\(totalBytes) " +
            "initialReadSize=\(initialReadSize) finalReadSize=\(chunkState.readSize) " +
            "fallbackCount=\(fallbackCount) capabilitySource=\(capabilitySource) " +
            "capabilityPersisted=\(capabilityPersisted) requestToFirstByteMs=\(requestToFirstByteMs) " +
            "socketReceiveMs=\(socketReceiveMs) fileWriteMs=\(fileWriteMs) " +
            "elapsedMs=\(elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
        )
        report(
          "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=expected-size " +
          "handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes) " +
          "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) finalReadSize=\(chunkState.readSize)"
        )
        return CameraVendorPartialObjectFileTransferResult(
          byteCount: totalBytes,
          requestToFirstByteMs: requestToFirstByteMs,
          socketReceiveMs: socketReceiveMs,
          fileWriteMs: fileWriteMs,
          elapsedMs: elapsedMs,
          executor: "standard-partial-object",
          initialReadSize: initialReadSize,
          finalReadSize: chunkState.readSize,
          fallbackCount: fallbackCount
        )
      }
    }

    let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
    let speedMBps = elapsedMs > 0
      ? (Double(totalBytes) / 1_048_576.0) / (Double(elapsedMs) / 1000.0)
      : 0
    report(
      "[OBS] PTP_DOWNLOAD_FILE_TIMING handle=0x\(String(format: "%08X", handle)) " +
        "format=\(formatLabel) mode=\(downloadMode) bytes=\(totalBytes) " +
        "initialReadSize=\(initialReadSize) finalReadSize=\(chunkState.readSize) " +
        "fallbackCount=\(fallbackCount) capabilitySource=\(capabilitySource) " +
        "capabilityPersisted=false requestToFirstByteMs=\(requestToFirstByteMs) " +
        "socketReceiveMs=\(socketReceiveMs) fileWriteMs=\(fileWriteMs) " +
        "elapsedMs=\(elapsedMs) speedMBps=\(String(format: "%.2f", speedMBps))"
    )
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=max-or-empty " +
      "handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes) " +
      "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) finalReadSize=\(chunkState.readSize)"
    )
    return CameraVendorPartialObjectFileTransferResult(
      byteCount: totalBytes,
      requestToFirstByteMs: requestToFirstByteMs,
      socketReceiveMs: socketReceiveMs,
      fileWriteMs: fileWriteMs,
      elapsedMs: elapsedMs,
      executor: "standard-partial-object",
      initialReadSize: initialReadSize,
      finalReadSize: chunkState.readSize,
      fallbackCount: fallbackCount
    )
  }

  private func persistOriginalTransferCapability(readSize: UInt32) -> Bool {
    let serial = transferCapabilitySerialNumber?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !serial.isEmpty, serial != "-" else {
      return false
    }
    originalTransferCapabilityStore.persist(
      readSize: readSize,
      serialNumber: serial
    )
    return true
  }

  private func normalizedThumbnailData(_ data: Data, handle: UInt32, source: String) -> Data {
    let normalized = CameraVendorImageDataNormalizer.imageData(from: data)
    let rawHead = data.prefix(16).map { String(format: "%02x", $0) }.joined()
    let normalizedHead = normalized.prefix(16).map { String(format: "%02x", $0) }.joined()
    report(
      "[OBS] PTP_THUMB_DATA source=\(source) handle=0x\(String(format: "%08X", handle)) " +
      "rawBytes=\(data.count) normalizedBytes=\(normalized.count) rawHead=\(rawHead) normalizedHead=\(normalizedHead)"
    )
    return normalized
  }

  func object(handle: UInt32) throws -> Data {
    try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getObject), parameters: [handle])
  }

  func object(handle: UInt32, expectedSize: UInt32?) throws -> Data {
    do {
      if CameraVendorOriginalDownloadPolicy.shouldDownloadUsingPartialObjectFallback {
        return try downloadObjectByPartialObjectFallback(handle: handle, cachedExpectedSize: expectedSize)
      }

      guard CameraVendorOriginalDownloadPolicy.shouldAttemptStandardGetObjectDownload else {
        report(
          "[OBS] PTP_DOWNLOAD_STANDARD_GET_OBJECT_DISABLED " +
          "handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0)"
        )
        throw NSError(
          domain: "CameraVendorPtpSession",
          code: Int(CameraVendorPtpOperationCode.getObject),
          userInfo: [
            NSLocalizedDescriptionKey: "原图下载需要 ReferenceApp ReadImage 传输链，已暂时阻止标准 GetObject 以避免卡死"
          ]
        )
      }

      var shouldResetForceCompression = false
      defer {
        if shouldResetForceCompression {
          do {
            try setCameraVendorImageForceCompression(0, reason: "download-reset")
          } catch {
            report("[OBS] PTP_DOWNLOAD_RESET_FORCE_COMPRESSION_FAILED error=\(error.localizedDescription)")
          }
        }
      }
      if CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeStandardGetObject {
        try setCameraVendorImageForceCompression(2, reason: "download")
        shouldResetForceCompression = true
      } else {
        report("[OBS] PTP_DOWNLOAD_SKIP_FORCE_COMPRESSION_BEFORE_GET_OBJECT")
      }
      return try sendCommandForData(operationCode: UInt16(CameraVendorPtpOperationCode.getObject), parameters: [handle])
    } catch {
      report("[OBS] PTP_GET_OBJECT_FAILED handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0) error=\(error.localizedDescription)")
      throw error
    }
  }

  private func downloadObjectByPartialObjectFallback(
    handle: UInt32,
    cachedExpectedSize: UInt32?
  ) throws -> Data {
    report(
      "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_BEGIN " +
      "handle=0x\(String(format: "%08X", handle)) cachedExpectedSize=\(cachedExpectedSize ?? 0)"
    )
    var shouldResetRealInfo = false
    var shouldResetForceCompression = false
    defer {
      if shouldResetRealInfo {
        do {
          let resetResponse = try sendCommandWithData(
            operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
            parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
            data: CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: false)
          )
          report("[OBS] PTP_DOWNLOAD_RESET_REAL_INFO_ZERO response=0x\(String(format: "%04X", resetResponse.responseCode))")
        } catch {
          report("[OBS] PTP_DOWNLOAD_RESET_REAL_INFO_ZERO_FAILED error=\(error.localizedDescription)")
        }
      }
      if shouldResetForceCompression {
        do {
          try setCameraVendorImageForceCompression(0, reason: "download-partial-fallback-reset")
        } catch {
          report("[OBS] PTP_DOWNLOAD_RESET_FORCE_COMPRESSION_ZERO_FAILED error=\(error.localizedDescription)")
        }
      }
    }
    do {
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList before file download (0xD212)"
      )
      if CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        try setCameraVendorImageForceCompression(
          CameraVendorOriginalDownloadPolicy.referenceAppFileDownloadForceCompressionMode,
          reason: "download-partial-fallback-prepare"
        )
        shouldResetForceCompression = true
      }
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeFreshFileInfo(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
        )
      }
      if CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "UNKNOWN",
        cachedExpectedSize: cachedExpectedSize
      ) {
        let realInfoResponse = try sendCommandWithData(
          operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
          parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
          data: CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: true)
        )
        shouldResetRealInfo = true
        report("[OBS] PTP_DOWNLOAD_SET_REAL_INFO_ONE response=0x\(String(format: "%04X", realInfoResponse.responseCode))")
      } else {
        report("[OBS] PTP_DOWNLOAD_SKIP_REAL_INFO_ONE reason=reference-app-fast-start")
      }

      let freshInfo = try objectInfo(handle: handle)
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffAfterFreshFileInfo(
        formatLabel: freshInfo.formatLabel,
        cachedExpectedSize: cachedExpectedSize
      ) {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
        )
      }
      let expectedSize = freshInfo.compressedSize.nonzero ?? cachedExpectedSize
      report(
        "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_INFO " +
        "handle=0x\(String(format: "%08X", handle)) format=\(freshInfo.formatLabel) " +
        "filename=\(freshInfo.filename) expectedSize=\(expectedSize ?? 0)"
      )
      let data = try readObjectByPartialObjects(
        handle: handle,
        expectedSize: expectedSize,
        purpose: "download"
      )
      report(
        "[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) bytes=\(data.count)"
      )
      return CameraVendorImageDataNormalizer.imageData(from: data)
    } catch {
      report("[OBS] PTP_DOWNLOAD_PARTIAL_FALLBACK_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      throw error
    }
  }

  func objectData(
    handle: UInt32,
    expectedSize: UInt32?,
    formatLabel: String = "JPG",
    downloadMode: CameraVendorTransferDownloadMode = .original
  ) throws -> (data: Data, info: CameraVendorCameraObjectInfo?) {
    let cachedExpectedSize = expectedSize
    let startedAt = Date()
    var prepMs = 0
    var freshInfoMs = 0
    var readMs = 0
    var normalizeMs = 0
    var resetProperties: [CameraVendorDownloadModeProperty] = []
    defer {
      for resetProperty in resetProperties.reversed() {
        do {
          try setCameraVendorDownloadModeProperty(
            resetProperty,
            handle: handle,
            mode: downloadMode,
            reason: "download-data-reset"
          )
        } catch {
          report(
            "[OBS] PTP_DOWNLOAD_DATA_RESET_MODE_FAILED " +
            "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
            "prop=0x\(String(format: "%04X", resetProperty.code)) error=\(error.localizedDescription)"
          )
        }
      }
    }
    do {
      report(
        "[OBS] PTP_DOWNLOAD_DATA_PREPARE_BEGIN " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "cachedFormat=\(formatLabel) cachedExpectedSize=\(expectedSize ?? 0)"
      )
      let prepStartedAt = Date()
      if CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeDataDownload() {
        _ = try? readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
          name: "CameraVendor/ReferenceApp EventsList before data download (0xD212)"
        )
      } else {
        report("[OBS] PTP_DOWNLOAD_DATA_SKIP_D212_CONTEXT reason=data-download-uses-photo-path")
      }
      if CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeDataDownload() {
        _ = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.compressionCutOff,
          name: "CameraVendor CompressionCutOff/PartialSize before data download (0xD235)"
        )
      } else {
        report("[OBS] PTP_DOWNLOAD_DATA_SKIP_D235_CONTEXT reason=data-download-uses-object-info-size")
      }
      for prepareProperty in CameraVendorDownloadModePolicy.prepareProperties(mode: downloadMode) {
        try setCameraVendorDownloadModeProperty(
          prepareProperty,
          handle: handle,
          mode: downloadMode,
          reason: "download-data-prepare"
        )
        if let resetProperty = CameraVendorDownloadModePolicy.resetProperty(for: prepareProperty) {
          resetProperties.append(resetProperty)
        }
      }
      prepMs = Int(Date().timeIntervalSince(prepStartedAt) * 1000)
      let shouldUseCachedInfo = CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: formatLabel,
        cachedExpectedSize: cachedExpectedSize,
        mode: downloadMode
      )
      let info: CameraVendorCameraObjectInfo?
      let expectedSize: UInt32?
      let sizeSource: String
      if shouldUseCachedInfo {
        info = nil
        expectedSize = cachedExpectedSize
        sizeSource = "cached-object-info"
      } else {
        let freshInfoStartedAt = Date()
        let freshInfo = try objectInfo(handle: handle)
        freshInfoMs = Int(Date().timeIntervalSince(freshInfoStartedAt) * 1000)
        info = freshInfo
        let sizeResolution = CameraVendorDownloadSizeSourcePolicy.resolution(
          freshSize: freshInfo.compressedSize,
          cachedSize: cachedExpectedSize
        )
        expectedSize = sizeResolution.size
        sizeSource = sizeResolution.label
      }
      report(
        "[OBS] PTP_DOWNLOAD_DATA_INFO " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) format=\(info?.formatLabel ?? formatLabel) " +
        "filename=\(info?.filename ?? "cached") expectedSize=\(expectedSize ?? 0) cachedExpectedSize=\(cachedExpectedSize ?? 0) " +
        "freshSize=\(info?.compressedSize ?? 0) sizeSource=\(sizeSource) freshProbe=\(!shouldUseCachedInfo)"
      )
      let readStartedAt = Date()
      let data = try readObjectByPartialObjects(
        handle: handle,
        expectedSize: expectedSize,
        purpose: "download-data",
        usesFileDownloadChunks: true
      )
      readMs = Int(Date().timeIntervalSince(readStartedAt) * 1000)
      let normalizeStartedAt = Date()
      let normalizedData = CameraVendorImageDataNormalizer.imageData(from: data)
      normalizeMs = Int(Date().timeIntervalSince(normalizeStartedAt) * 1000)
      let totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
      report(
        "[OBS] PTP_DOWNLOAD_DATA_TIMING " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "bytes=\(normalizedData.count) prepMs=\(prepMs) freshInfoMs=\(freshInfoMs) " +
        "readMs=\(readMs) normalizeMs=\(normalizeMs) totalMs=\(totalMs) " +
        "sizeSource=\(sizeSource)"
      )
      report(
        "[OBS] PTP_DOWNLOAD_DATA_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) bytes=\(normalizedData.count) " +
        "elapsedMs=\(totalMs)"
      )
      return (normalizedData, info)
    } catch {
      throw error
    }
  }

  func objectFile(
    handle: UInt32,
    cachedInfo: CameraVendorCameraObjectInfo?,
    downloadMode: CameraVendorTransferDownloadMode = .original
  ) throws -> (
    fileURL: URL,
    info: CameraVendorCameraObjectInfo,
    timing: CameraVendorOriginalFileTransferTiming
  ) {
    let cancellationGeneration = activeDownloadCancellation.snapshot()
    let matchingCachedInfo = cachedInfo?.handle == Int(handle) ? cachedInfo : nil
    let cachedExpectedSize = matchingCachedInfo?.compressedSize.nonzero
    let cachedFilename = matchingCachedInfo?.filename ?? "CamTransfer-\(handle).bin"
    var temporaryFileURL: URL?
    let startedAt = Date()
    var prepareMs = 0
    do {
      report(
        "[OBS] PTP_DOWNLOAD_FILE_PREPARE_BEGIN " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "cachedExpectedSize=\(cachedExpectedSize ?? 0)"
      )
      let prepareStartedAt = Date()
      try throwIfActiveDownloadCancelled(since: cancellationGeneration)
      let didPrepareBatchMode = try prepareDownloadModeForPriorityBatch(
        downloadMode,
        handle: handle,
        reason: "download-batch-prepare"
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_BATCH_MODE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) " +
        "prepared=\(didPrepareBatchMode)"
      )
      let freshInfo = try objectInfo(handle: handle)
      let info = freshInfo.mergingMissingDownloadMetadata(from: matchingCachedInfo)
      let downloadFormatLabel = info.formatLabel
      let downloadFilename = info.filename
      let resolvedFilename = downloadFilename.isEmpty ? cachedFilename : downloadFilename
      let fileExtension = ((resolvedFilename as NSString).pathExtension.isEmpty
        ? "bin"
        : (resolvedFilename as NSString).pathExtension)
      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(fileExtension)
      temporaryFileURL = fileURL
      let sizeResolution = CameraVendorDownloadSizeSourcePolicy.resolution(
        freshSize: freshInfo.compressedSize,
        cachedSize: cachedExpectedSize
      )
      let expectedSize = sizeResolution.size
      let sizeSource = sizeResolution.label
      let compressionCutOffData = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.compressionCutOff,
        name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
      )
      let d235RawReadSize = CameraVendorOriginalReadImageExecutorPolicy.rawReadSize(from: compressionCutOffData)
      let d235NegotiatedReadSize = CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(from: compressionCutOffData)
      report(
        "[OBS] PTP_DOWNLOAD_D235_PROFILE " +
        "handle=0x\(String(format: "%08X", handle)) raw=\(d235RawReadSize ?? 0) " +
        "selected=\(d235NegotiatedReadSize ?? 0) " +
        "source=\(CameraVendorOriginalReadImageExecutorPolicy.profileSource(negotiatedReadSize: d235NegotiatedReadSize))"
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_INFO " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) format=\(downloadFormatLabel) " +
        "filename=\(downloadFilename) expectedSize=\(expectedSize ?? 0) cachedExpectedSize=\(cachedExpectedSize ?? 0) " +
        "freshSize=\(freshInfo.compressedSize) resolvedSize=\(info.compressedSize) " +
        "sizeSource=\(sizeSource) freshProbe=true"
      )
      prepareMs = Int(Date().timeIntervalSince(prepareStartedAt) * 1000)
      let readResult = try readObjectByPartialObjectsToFile(
        handle: handle,
        expectedSize: expectedSize,
        fileURL: fileURL,
        purpose: "download-file",
        formatLabel: downloadFormatLabel,
        downloadMode: downloadMode,
        cancellationGeneration: cancellationGeneration,
        negotiatedReadSize: CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(from: compressionCutOffData)
      )
      let transferMs = Int(Date().timeIntervalSince(startedAt) * 1000)
      let commandGapMs = max(
        0,
        readResult.elapsedMs - readResult.requestToFirstByteMs - readResult.socketReceiveMs - readResult.fileWriteMs
      )
      let timing = CameraVendorOriginalFileTransferTiming(
        byteCount: readResult.byteCount,
        prepareMs: prepareMs,
        requestToFirstByteMs: readResult.requestToFirstByteMs,
        socketReceiveMs: readResult.socketReceiveMs,
        fileWriteMs: readResult.fileWriteMs,
        commandGapMs: commandGapMs,
        transferMs: transferMs,
        executor: readResult.executor,
        d235ReadSize: d235NegotiatedReadSize,
        initialReadSize: readResult.initialReadSize,
        finalReadSize: readResult.finalReadSize,
        fallbackCount: readResult.fallbackCount
      )
      report(
        "[OBS] PTP_DOWNLOAD_FILE_COMPLETE " +
        "handle=0x\(String(format: "%08X", handle)) mode=\(downloadMode) bytes=\(readResult.byteCount) " +
        "prepareMs=\(prepareMs) elapsedMs=\(transferMs)"
      )
      return (fileURL, info, timing)
    } catch {
      if let temporaryFileURL {
        try? FileManager.default.removeItem(at: temporaryFileURL)
      }
      throw error
    }
  }

  private func withSerializedCommand<T>(_ body: () throws -> T) rethrows -> T {
    guard CameraVendorPtpCommandSerializationPolicy.shouldSerializeCommandSocketAccess else {
      return try body()
    }
    commandLock.lock()
    defer { commandLock.unlock() }
    return try body()
  }

  func disconnect() {
    if isConnected {
      _ = try? sendCommand(operationCode: UInt16(CameraVendorPtpOperationCode.closeSession))
    }
    commandSocket.close()
    eventSocket.close()
    isConnected = false
    didConfirmGalleryMode = false
    originalDownloadBatchModeState.resetForSessionEnd()
    diagnosticHandler = nil
  }

  func keepAlive(readTimeout: TimeInterval = 3) throws {
    guard isConnected else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorNotConnectedToInternet,
        userInfo: [NSLocalizedDescriptionKey: "PTP session is not connected"]
      )
    }
    _ = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppGalleryObjectContext],
      readTimeout: readTimeout
    )
  }

  private func sendCommand(operationCode: UInt16, parameters: [UInt32] = []) throws -> CameraVendorOperationResponse {
    let response = try sendCommandCapturingResponse(
      operationCode: operationCode,
      parameters: parameters
    )
    try CameraVendorPtpResponsePolicy.validateOK(
      responseCode: response.responseCode,
      operationName: "PTP command"
    )
    return response
  }

  private func sendCommandCapturingResponse(
    operationCode: UInt16,
    parameters: [UInt32] = []
  ) throws -> CameraVendorOperationResponse {
    try withSerializedCommand {
      transactionID += 1
      let packet: Data
      switch operationTransport {
      case .standardPtpIp:
        packet = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        packet = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      try commandSocket.write(packet)
      return try readCameraVendorOperationResponse(validatesOK: false)
    }
  }

  private func sendCommandWithData(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    data: Data
  ) throws -> CameraVendorOperationResponse {
    try withSerializedCommand {
      transactionID += 1
      switch operationTransport {
      case .standardPtpIp:
        // First packet: command with DataPhase = DataOut.
        try commandSocket.write(
          CameraVendorPtpPacketBuilder.buildOperationRequest(
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters,
            dataPhase: 2
          )
        )
        try commandSocket.write(
          CameraVendorPtpPacketBuilder.buildCameraVendorDataOutRequest(
            operationCode: operationCode,
            transactionID: transactionID,
            data: data
          )
        )
      case .cameraVendorLegacy:
        try commandSocket.write(
          CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
            operationCode: operationCode,
            transactionID: transactionID,
            parameters: parameters
          )
        )
        try commandSocket.write(
          CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
            operationCode: operationCode,
            transactionID: transactionID,
            data: data
          )
        )
      }
      return try readCameraVendorOperationResponse()
    }
  }

  private struct CameraVendorFileCommandResult {
    let byteCount: Int
    let prefix: Data
    let requestToFirstByteMs: Int
    let socketReceiveMs: Int
    let fileWriteMs: Int
  }

  private func sendOriginalReadImageRequest(
    transactionID: UInt32,
    handle: UInt32,
    offset: UInt64,
    size: UInt32
  ) throws {
    let parameters = CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
      handle: handle,
      offset: offset,
      size: size
    )
    let request: Data
    switch operationTransport {
    case .standardPtpIp:
      request = CameraVendorPtpPacketBuilder.buildOperationRequest(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        transactionID: transactionID,
        parameters: parameters
      )
    case .cameraVendorLegacy:
      request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        transactionID: transactionID,
        parameters: parameters
      )
    }
    try commandSocket.write(request)
  }

  private func receiveOriginalReadImagePayloadAndResponse(
    transactionID: UInt32,
    expectedMaximum: Int,
    fileHandle: FileHandle,
    readTimeout: TimeInterval
  ) throws -> CameraVendorOriginalReadImageTransactionResult {
    switch operationTransport {
    case .standardPtpIp:
      var totalBytes = 0
      var prefix = Data()
      while true {
        let packet = try readPacket(from: commandSocket, timeout: readTimeout)
        switch packet.type {
        case CameraVendorPtpPacketType.startDataPacket:
          continue
        case CameraVendorPtpPacketType.dataPacket:
          try fileHandle.write(contentsOf: packet.payload)
          totalBytes += packet.payload.count
          if prefix.count < 64 {
            prefix.append(packet.payload.prefix(64 - prefix.count))
          }
        case CameraVendorPtpPacketType.endDataPacket:
          let data = packet.payload.count > 4 ? Data(packet.payload.dropFirst(4)) : Data()
          try fileHandle.write(contentsOf: data)
          totalBytes += data.count
          if prefix.count < 64 {
            prefix.append(data.prefix(64 - prefix.count))
          }
        case CameraVendorPtpPacketType.operationResponse:
          guard totalBytes <= expectedMaximum else {
            throw NSError(
              domain: "CameraVendorPtpSession",
              code: 13,
              userInfo: [NSLocalizedDescriptionKey: "原图 ReadImage 返回超过请求上限的数据"]
            )
          }
          let response = try parseOperationResponsePayload(packet.payload)
          return CameraVendorOriginalReadImageTransactionResult(
            byteCount: totalBytes,
            prefix: prefix,
            requestToFirstByteMs: 0,
            socketReceiveMs: 0,
            fileWriteMs: 0,
            receiveCadence: CameraVendorPtpReceiveCadenceSummary(),
            responseCode: response.responseCode,
            responseTransactionID: response.transactionID
          )
        default:
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 收到未知 PTP 包类型 \(packet.type)",
          ])
        }
      }

    case .cameraVendorLegacy:
      var totalBytes = 0
      var prefix = Data()
      var requestToFirstByteMs = 0
      var socketReceiveMs = 0
      var fileWriteMs = 0
      var receiveCadence = CameraVendorPtpReceiveCadenceSummary()
      while true {
        let packet = try readCameraVendorLegacyFilePacket(
          from: commandSocket,
          fileHandle: fileHandle,
          timeout: readTimeout,
          prefixByteCount: max(0, 64 - prefix.count)
        )
        totalBytes += packet.byteCount
        if packet.byteCount > 0 {
          requestToFirstByteMs += packet.requestToFirstByteMs
          socketReceiveMs += packet.socketReceiveMs
          fileWriteMs += packet.fileWriteMs
          receiveCadence.merge(packet.receiveCadence)
        }
        if prefix.count < 64 {
          prefix.append(packet.prefix.prefix(64 - prefix.count))
        }
        guard let controlPacket = packet.controlPacket else { continue }
        guard controlPacket.type == CameraVendorPtpPacketType.operationResponse else {
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "原图 ReadImage 收到未知 CameraVendor PTP 包类型 \(controlPacket.type)",
          ])
        }
        guard totalBytes <= expectedMaximum else {
          throw NSError(
            domain: "CameraVendorPtpSession",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "原图 ReadImage 返回超过请求上限的数据"]
          )
        }
        let response = try parseOperationResponsePayload(controlPacket.payload)
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: totalBytes,
          prefix: prefix,
          requestToFirstByteMs: requestToFirstByteMs,
          socketReceiveMs: socketReceiveMs,
          fileWriteMs: fileWriteMs,
          receiveCadence: receiveCadence,
          responseCode: response.responseCode,
          responseTransactionID: response.transactionID
        )
      }
    }
  }

  private func sendCommandForFileData(
    operationCode: UInt16,
    parameters: [UInt32],
    fileHandle: FileHandle,
    readTimeout: TimeInterval
  ) throws -> CameraVendorFileCommandResult {
    try withSerializedCommand {
      transactionID += 1
      let request: Data
      switch operationTransport {
      case .standardPtpIp:
        request = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      try commandSocket.write(request)

      switch operationTransport {
      case .standardPtpIp:
        // Current Fujifilm transfer sessions use the legacy reader below. Keep
        // standard PTP/IP behavior intact until it has matching wire fixtures.
        var totalBytes = 0
        var prefix = Data()
        while true {
          let packet = try readPacket(from: commandSocket, timeout: readTimeout)
          switch packet.type {
          case CameraVendorPtpPacketType.startDataPacket:
            continue
          case CameraVendorPtpPacketType.dataPacket:
            try fileHandle.write(contentsOf: packet.payload)
            totalBytes += packet.payload.count
            if prefix.count < 64 {
              prefix.append(packet.payload.prefix(64 - prefix.count))
            }
          case CameraVendorPtpPacketType.endDataPacket:
            let data = packet.payload.count > 4 ? Data(packet.payload.dropFirst(4)) : Data()
            try fileHandle.write(contentsOf: data)
            totalBytes += data.count
            if prefix.count < 64 {
              prefix.append(data.prefix(64 - prefix.count))
            }
          case CameraVendorPtpPacketType.operationResponse:
            let response = try parseOperationResponsePayload(packet.payload)
            try CameraVendorPtpResponsePolicy.validateOK(
              responseCode: response.responseCode,
              operationName: String(format: "PTP operation 0x%04X", operationCode)
            )
            return CameraVendorFileCommandResult(
              byteCount: totalBytes,
              prefix: prefix,
              requestToFirstByteMs: 0,
              socketReceiveMs: 0,
              fileWriteMs: 0
            )
          default:
            throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
              NSLocalizedDescriptionKey: "读取文件数据时收到未知 PTP 包类型 \(packet.type)",
            ])
          }
        }

      case .cameraVendorLegacy:
        var totalBytes = 0
        var prefix = Data()
        var requestToFirstByteMs = 0
        var socketReceiveMs = 0
        var fileWriteMs = 0
        while true {
          let packet = try readCameraVendorLegacyFilePacket(
            from: commandSocket,
            fileHandle: fileHandle,
            timeout: readTimeout,
            prefixByteCount: max(0, 64 - prefix.count)
          )
          totalBytes += packet.byteCount
          if packet.byteCount > 0 {
            requestToFirstByteMs += packet.requestToFirstByteMs
            socketReceiveMs += packet.socketReceiveMs
            fileWriteMs += packet.fileWriteMs
          }
          if prefix.count < 64 {
            prefix.append(packet.prefix.prefix(64 - prefix.count))
          }
          guard let controlPacket = packet.controlPacket else { continue }
          switch controlPacket.type {
          case CameraVendorPtpPacketType.startDataPacket:
            continue
          case CameraVendorPtpPacketType.operationResponse:
            let response = try parseOperationResponsePayload(controlPacket.payload)
            try CameraVendorPtpResponsePolicy.validateOK(
              responseCode: response.responseCode,
              operationName: String(format: "PTP operation 0x%04X", operationCode)
            )
            return CameraVendorFileCommandResult(
              byteCount: totalBytes,
              prefix: prefix,
              requestToFirstByteMs: requestToFirstByteMs,
              socketReceiveMs: socketReceiveMs,
              fileWriteMs: fileWriteMs
            )
          default:
            throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
              NSLocalizedDescriptionKey: "读取文件数据时收到未知 PTP 包类型 \(controlPacket.type)",
            ])
          }
        }
      }
    }
  }

  private func sendCommandForData(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    readTimeout: TimeInterval = 15,
    timingHandler: ((CameraVendorDataCommandTiming, Int) -> Void)? = nil
  ) throws -> Data {
    try withSerializedCommand {
      let commandStartedAt = Date()
      var firstByteAt: Date?
      var dataCompleteAt: Date?
      let firstByteHandler = {
        if firstByteAt == nil {
          firstByteAt = Date()
        }
      }
      transactionID += 1
      let request: Data
      switch operationTransport {
      case .standardPtpIp:
        request = CameraVendorPtpPacketBuilder.buildOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      case .cameraVendorLegacy:
        request = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
          operationCode: operationCode,
          transactionID: transactionID,
          parameters: parameters
        )
      }
      try commandSocket.write(request)

      var received = Data()
      while true {
        let packet = try readOperationPacket(
          timeout: readTimeout,
          firstByteHandler: firstByteHandler
        )
        switch packet.type {
        case CameraVendorPtpPacketType.startDataPacket:
          report("收到 StartDataPacket (\(packet.payload.count) bytes)")
        case CameraVendorPtpPacketType.dataPacket:
          received.append(packet.payload)
          dataCompleteAt = Date()
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.endDataPacket:
          if packet.payload.count > 4 {
            received.append(packet.payload.dropFirst(4))
          }
          dataCompleteAt = Date()
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.operationResponse:
          let response = try parseOperationResponsePayload(packet.payload)
          report("操作响应: responseCode=0x\(String(response.responseCode, radix: 16)), 总数据大小=\(received.count)")
          try CameraVendorPtpResponsePolicy.validateOK(
            responseCode: response.responseCode,
            operationName: String(format: "PTP operation 0x%04X", operationCode)
          )
          let responseCompleteAt = Date()
          if let timingHandler {
            let firstByte = firstByteAt ?? responseCompleteAt
            let dataComplete = dataCompleteAt ?? responseCompleteAt
            timingHandler(
              CameraVendorDataCommandTiming(
                requestToFirstByteMs: Int(firstByte.timeIntervalSince(commandStartedAt) * 1000),
                dataCompleteMs: Int(dataComplete.timeIntervalSince(commandStartedAt) * 1000),
                responseCompleteMs: Int(responseCompleteAt.timeIntervalSince(commandStartedAt) * 1000),
                totalMs: Int(responseCompleteAt.timeIntervalSince(commandStartedAt) * 1000)
              ),
              received.count
            )
          }
          return received
        default:
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "读取数据时收到未知 PTP 包类型 \(packet.type)"
          ])
        }
      }
    }
  }

  private func sendCommandForDataWithTiming(
    operationCode: UInt16,
    parameters: [UInt32] = [],
    readTimeout: TimeInterval = 15
  ) throws -> (data: Data, timing: CameraVendorDataCommandTiming) {
    var capturedTiming: CameraVendorDataCommandTiming?
    let data = try sendCommandForData(
      operationCode: operationCode,
      parameters: parameters,
      readTimeout: readTimeout,
      timingHandler: { timing, _ in
        capturedTiming = timing
      }
    )
    guard let capturedTiming else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: NSURLErrorCannotParseResponse,
        userInfo: [NSLocalizedDescriptionKey: "未取得 CameraVendor 命令阶段计时"]
      )
    }
    return (data, capturedTiming)
  }

  private func readCameraVendorOperationResponse(
    validatesOK: Bool = true
  ) throws -> CameraVendorOperationResponse {
    let packet = try readOperationPacket(timeout: 15)
    guard packet.type == CameraVendorPtpPacketType.operationResponse else {
      throw NSError(domain: "CameraVendorPtpSession", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "收到未知 PTP 包类型 \(packet.type)，期望 OperationResponse"
      ])
    }
    let response = try parseOperationResponsePayload(packet.payload)
    report("CameraVendor 操作响应: responseCode=0x\(String(response.responseCode, radix: 16)) txnID=\(response.transactionID)")
    if validatesOK {
      try CameraVendorPtpResponsePolicy.validateOK(
        responseCode: response.responseCode,
        operationName: "PTP command"
      )
    }
    return response
  }

  private func readOperationPacket(
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    switch operationTransport {
    case .standardPtpIp:
      return try readPacket(
        from: commandSocket,
        timeout: timeout,
        firstByteHandler: firstByteHandler
      )
    case .cameraVendorLegacy:
      return try readCameraVendorLegacyPacket(
        from: commandSocket,
        timeout: timeout,
        firstByteHandler: firstByteHandler
      )
    }
  }

  private func parseOperationResponsePayload(_ payload: Data) throws -> CameraVendorOperationResponse {
    guard payload.count >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "CameraVendor 操作响应太短: \(payload.count) bytes"
      ])
    }
    let responseCode = payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    let txnID = payload.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let params = payload.count > 6 ? payload.subdata(in: 6..<payload.count) : Data()
    return CameraVendorOperationResponse(dataPhase: 0, responseCode: responseCode, transactionID: txnID, params: params)
  }

  /// Read a CameraVendor legacy packet with [4 length] followed by a 2-byte packet kind.
  private func readCameraVendorLegacyPacket(
    from socket: CameraVendorPtpSocket,
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    report("等待 CameraVendor legacy PTP 包头")
    let headerStartedAt = Date()
    let header = try socket.readExactly(
      4,
      timeout: timeout,
      firstByteHandler: firstByteHandler
    )
    let headerMs = Int(Date().timeIntervalSince(headerStartedAt) * 1000)
    guard header.count == 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包头读取失败"])
    }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包长度异常 \(length)"])
    }
    let payloadLength = Int(length) - 4
    let payloadStartedAt = Date()
    let progressEveryBytes = CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength)
      ? CameraVendorPtpSocketReadDiagnosticPolicy.progressIntervalBytes
      : nil
    let payload = try socket.readExactly(
      payloadLength,
      timeout: timeout,
      progressEveryBytes: progressEveryBytes,
      firstByteHandler: firstByteHandler
    ) { [weak self] bytesRead, totalBytes, elapsedMs in
      self?.report(
        "[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=legacy " +
        "bytesRead=\(bytesRead) totalBytes=\(totalBytes) payloadMs=\(elapsedMs)"
      )
    }
    let payloadMs = Int(Date().timeIntervalSince(payloadStartedAt) * 1000)
    guard payload.count >= 2 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包内容为空"])
    }
    let kind = payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    let body = payload.subdata(in: 2..<payload.count)
    report("收到 CameraVendor legacy PTP 包 kind=\(kind) length=\(length)")
    if CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength) {
      report(
        "[OBS] PTP_SOCKET_PACKET_READ transport=legacy kind=\(kind) " +
        "length=\(length) headerMs=\(headerMs) payloadMs=\(payloadMs)"
      )
    }
    switch CameraVendorLegacyPacketMapper.packetType(forKind: kind) {
    case CameraVendorPtpPacketType.dataPacket:
      guard body.count >= 6 else {
        throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy Data 包太短: \(body.count) bytes"])
      }
      return CameraVendorPtpPacket(type: CameraVendorPtpPacketType.dataPacket, payload: body.dropFirst(6))
    case CameraVendorPtpPacketType.operationResponse:
      return CameraVendorPtpPacket(
        type: CameraVendorPtpPacketType.operationResponse,
        payload: CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: kind, body: body)
      )
    default:
      return CameraVendorPtpPacket(type: Int(kind), payload: body)
    }
  }

  private func readCameraVendorLegacyFilePacket(
    from socket: CameraVendorPtpSocket,
    fileHandle: FileHandle,
    timeout: TimeInterval,
    prefixByteCount: Int
  ) throws -> (
    controlPacket: CameraVendorPtpPacket?,
    byteCount: Int,
    prefix: Data,
    requestToFirstByteMs: Int,
    socketReceiveMs: Int,
    fileWriteMs: Int,
    receiveCadence: CameraVendorPtpReceiveCadenceSummary
  ) {
    let requestWaitStartedAt = Date()
    let header = try socket.readExactly(4, timeout: timeout)
    guard header.count == 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包头读取失败"])
    }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包长度异常 \(length)"])
    }
    let payloadLength = Int(length) - 4
    let kindData = try socket.readExactly(2, timeout: timeout)
    let kind = kindData.withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }

    if CameraVendorLegacyPacketMapper.packetType(forKind: kind) == CameraVendorPtpPacketType.dataPacket {
      guard payloadLength >= 8 else {
        throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy Data 包太短: \(payloadLength)"])
      }
      _ = try socket.readExactly(6, timeout: timeout)
      let requestToFirstByteMs = Int(Date().timeIntervalSince(requestWaitStartedAt) * 1000)
      let result = try socket.readExactlyToFile(
        payloadLength - 8,
        fileHandle: fileHandle,
        timeout: timeout,
        prefixByteCount: prefixByteCount
      )
      return (
        nil,
        result.byteCount,
        result.prefix,
        requestToFirstByteMs,
        result.socketReceiveMs,
        result.fileWriteMs,
        result.receiveCadence
      )
    }

    let body = try socket.readExactly(
      payloadLength - 2,
      timeout: timeout
    )
    switch CameraVendorLegacyPacketMapper.packetType(forKind: kind) {
    case CameraVendorPtpPacketType.operationResponse:
      return (
        CameraVendorPtpPacket(
          type: CameraVendorPtpPacketType.operationResponse,
          payload: CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: kind, body: body)
        ),
        0,
        Data(),
        0,
        0,
        0,
        CameraVendorPtpReceiveCadenceSummary()
      )
    default:
      return (
        CameraVendorPtpPacket(type: Int(kind), payload: body),
        0,
        Data(),
        0,
        0,
        0,
        CameraVendorPtpReceiveCadenceSummary()
      )
    }
  }

  /// Read a standard PTP/IP packet with [4 length][4 type] header.
  private func readPacket(
    from socket: CameraVendorPtpSocket,
    timeout: TimeInterval = 10,
    firstByteHandler: (() -> Void)? = nil
  ) throws -> CameraVendorPtpPacket {
    report("等待 PTP 包头")
    let headerStartedAt = Date()
    let header = try socket.readExactly(
      8,
      timeout: timeout,
      firstByteHandler: firstByteHandler
    )
    let headerMs = Int(Date().timeIntervalSince(headerStartedAt) * 1000)
    guard header.count == 8 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "PTP 包头读取失败"])
    }
    let length = header.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let type = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let payloadLength = Int(length) - 8
    let payloadStartedAt = Date()
    let progressEveryBytes = CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength)
      ? CameraVendorPtpSocketReadDiagnosticPolicy.progressIntervalBytes
      : nil
    let payload = payloadLength > 0
      ? try socket.readExactly(
        payloadLength,
        timeout: timeout,
        progressEveryBytes: progressEveryBytes,
        firstByteHandler: firstByteHandler
      ) { [weak self] bytesRead, totalBytes, elapsedMs in
        self?.report(
          "[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=standard " +
          "bytesRead=\(bytesRead) totalBytes=\(totalBytes) payloadMs=\(elapsedMs)"
        )
      }
      : Data()
    let payloadMs = Int(Date().timeIntervalSince(payloadStartedAt) * 1000)
    report("收到 PTP 包 type=\(type) length=\(length)")
    if CameraVendorPtpSocketReadDiagnosticPolicy.shouldReportProgress(totalBytes: payloadLength) {
      report(
        "[OBS] PTP_SOCKET_PACKET_READ transport=standard type=\(type) " +
        "length=\(length) headerMs=\(headerMs) payloadMs=\(payloadMs)"
      )
    }
    return CameraVendorPtpPacket(type: Int(type), payload: payload)
  }

  private func report(_ message: String) {
    guard CameraVendorPtpDiagnosticLogPolicy.shouldEmit(message) else { return }
    CameraVendorGalleryDiagnostics.log(message)
    diagnosticHandler?(message)
  }
}

private enum CameraVendorCameraWifiConnector {
  static func currentAssociationSnapshot(
    diagnosticHandler: ((String) -> Void)? = nil
  ) async -> (currentSSID: String?, isCameraPtpReachable: Bool) {
    let currentSSID = await fetchCurrentSSID()
    let isCameraPtpReachable = await Task.detached(priority: .utility) {
      CameraVendorCameraPtpReachabilityProbe.isReachable()
    }.value
    diagnosticHandler?(
      "Wi-Fi 预检查: ssid=\(currentSSID ?? "<nil>"), ptpReachable=\(isCameraPtpReachable)"
    )
    return (currentSSID, isCameraPtpReachable)
  }

  static func join(
    configuration: CameraVendorWifiNetworkConfiguration,
    allowUnverifiedAssociationAfterRecoverableError: Bool = false,
    diagnosticHandler: ((String) -> Void)? = nil
  ) async throws {
    let report: (String) -> Void = { message in
      CameraVendorGalleryDiagnostics.log(message)
      diagnosticHandler?(message)
    }
    let hotspotConfiguration = NEHotspotConfiguration(
      ssid: configuration.ssid,
      passphrase: configuration.passphrase,
      isWEP: false
    )
    hotspotConfiguration.joinOnce = true
    hotspotConfiguration.hidden = configuration.isHidden

    report(
      "尝试连接 Wi-Fi: \(configuration.ssid) " +
      "(hidden=\(configuration.isHidden), passphraseLength=\(configuration.passphrase.count))"
    )
    report(
      "[OBS] WIFI_JOIN_START ssid=\(configuration.ssid) hidden=\(configuration.isHidden) " +
      "passphraseLength=\(configuration.passphrase.count)"
    )
    let locationStatus = await CameraVendorWifiLocationAuthorizer.shared.prepareForSSIDAccess(
      diagnosticHandler: report
    )
    if !CameraVendorWifiJoinDiagnostics.canReadCurrentSSID(with: locationStatus) {
      report("当前定位权限不足，iOS 可能无法返回当前 Wi-Fi 名称")
    }
    if CameraVendorWifiJoinDiagnostics.shouldRemoveExistingConfigurationBeforeJoin {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: configuration.ssid)
      report("已移除旧的 Wi-Fi 配置: \(configuration.ssid)")
    } else {
      report("[OBS] WIFI_REMOVE_EXISTING_SKIPPED ssid=\(configuration.ssid)")
    }

    let applyError: NSError? = await withCheckedContinuation { (continuation: CheckedContinuation<NSError?, Never>) in
      let gate = CameraVendorWifiApplyContinuationGate()
      let timeoutError = CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutError(
        ssid: configuration.ssid
      )
      DispatchQueue.main.asyncAfter(
        deadline: .now() + CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutSeconds
      ) {
        guard gate.resumeIfNeeded(continuation, returning: timeoutError) else {
          return
        }
        report(
          "[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) " +
          "error=\(CameraVendorWifiJoinDiagnostics.describeHotspotError(timeoutError)) source=timeout"
        )
      }
      CameraVendorMainThread.run {
        NEHotspotConfigurationManager.shared.apply(hotspotConfiguration) { error in
          if let nsError = error as NSError? {
            if nsError.domain == NEHotspotConfigurationErrorDomain,
               nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
              guard gate.resumeIfNeeded(continuation, returning: nil) else {
                return
              }
              report("Wi-Fi 已关联到 \(configuration.ssid)")
              report("[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) error=alreadyAssociated")
              return
            }
            guard gate.resumeIfNeeded(continuation, returning: nsError) else {
              return
            }
            report(
              "Wi-Fi 连接失败 \(configuration.ssid): " +
              CameraVendorWifiJoinDiagnostics.describeHotspotError(nsError)
            )
            report("[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) error=\(CameraVendorWifiJoinDiagnostics.describeHotspotError(nsError))")
            return
          }

          guard gate.resumeIfNeeded(continuation, returning: nil) else {
            return
          }
          report("Wi-Fi 连接请求已提交: \(configuration.ssid)")
          report("[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) error=nil")
        }
      }
    }

    if let applyError {
      guard CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: applyError) else {
        throw applyError
      }
      report("Wi-Fi 接口返回可恢复错误，继续确认当前是否已切换到 \(configuration.ssid)")
    }

    do {
      try await waitUntilAssociated(
        withSSID: configuration.ssid,
        timeout: CameraVendorWifiJoinDiagnostics.associationTimeout(after: applyError),
        diagnosticHandler: report
      )
    } catch {
      let currentSSID = await fetchCurrentSSID()
      if applyError != nil,
         CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
          requested: allowUnverifiedAssociationAfterRecoverableError,
          targetSSID: configuration.ssid,
          currentSSID: currentSSID
         ) {
        report("SSID 已确认匹配，允许在可恢复错误后继续进入图库连接验证")
        report("[OBS] WIFI_ASSOCIATION_UNVERIFIED_ALLOWED ssid=\(configuration.ssid) currentSSID=\(currentSSID ?? "nil")")
        return
      }
      report("[OBS] WIFI_ASSOCIATION_FAILED ssid=\(configuration.ssid) currentSSID=\(currentSSID ?? "nil") error=\(error.localizedDescription)")
      throw error
    }
  }

  private static func waitUntilAssociated(
    withSSID targetSSID: String,
    timeout: TimeInterval = 15,
    diagnosticHandler: ((String) -> Void)? = nil
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let currentSSID = await fetchCurrentSSID()
      diagnosticHandler?("当前 Wi-Fi: \(currentSSID ?? "<nil>")")

      if let currentSSID, currentSSID == targetSSID {
        diagnosticHandler?("Wi-Fi 已切换到相机热点: \(targetSSID)")
        diagnosticHandler?("[OBS] WIFI_ASSOCIATED ssid=\(targetSSID)")
        let stabilizationDelay = CameraVendorWifiHandoffStabilizationPolicy.delayAfterSSIDAssociationSeconds
        if stabilizationDelay > 0 {
          let nanoseconds = UInt64(stabilizationDelay * 1_000_000_000)
          try await Task.sleep(nanoseconds: nanoseconds)
        }
        return
      }
      if CameraVendorWifiAssociationReadiness.isReadyToProceed(
        targetSSID: targetSSID,
        currentSSID: currentSSID,
        isCameraPtpReachable: false
      ) {
        diagnosticHandler?("Wi-Fi 已确认可进入图库")
        return
      }
      try await Task.sleep(nanoseconds: 500_000_000)
    }

    // Do not probe the PTP port here. ReferenceApp goes from Wi-Fi handoff to the real
    // PTP session directly, and the camera may only tolerate one PTP connection.
    let currentSSID = await fetchCurrentSSID()
    if CameraVendorWifiAssociationReadiness.isReadyToProceed(
      targetSSID: targetSSID,
      currentSSID: currentSSID,
      isCameraPtpReachable: false
    ) {
      diagnosticHandler?("等待 Wi-Fi SSID 匹配超时前已确认相机网络")
      return
    }

    diagnosticHandler?("等待 Wi-Fi SSID 匹配超时，未执行 PTP 预探测")
    throw NSError(
      domain: "CameraVendorCameraWifiConnector",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "等待 Wi-Fi 切换到 \(targetSSID) 超时"
      ]
    )
  }

  static func fetchCurrentSSID() async -> String? {
    guard #available(iOS 14.0, *) else {
      return nil
    }

    return await withCheckedContinuation { continuation in
      NEHotspotNetwork.fetchCurrent { network in
        let ssid = network?.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.resume(returning: ssid?.isEmpty == false ? ssid : nil)
      }
    }
  }
}

private final class CameraVendorWifiApplyContinuationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false

  func resumeIfNeeded(
    _ continuation: CheckedContinuation<NSError?, Never>,
    returning value: NSError?
  ) -> Bool {
    lock.lock()
    if didResume {
      lock.unlock()
      return false
    }
    didResume = true
    lock.unlock()
    continuation.resume(returning: value)
    return true
  }
}

private enum CameraVendorCameraPtpReachabilityProbe {
  /// Lightweight TCP reachability check using a raw BSD socket.
  /// Uses non-blocking connect so the camera's PTP listener sees at most
  /// a brief SYN; the socket is closed immediately after the kernel
  /// reports the connection is possible, minimising the chance of
  /// occupying the camera's single PTP connection slot.
  static func isReachable(
    host: String = CameraVendorPtpConstants.defaultHost,
    port: Int = CameraVendorPtpConstants.commandPort,
    timeout: TimeInterval = 0.5
  ) -> Bool {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if connectResult == 0 {
      Darwin.close(fd)
      return true
    }

    guard errno == EINPROGRESS else {
      Darwin.close(fd)
      return false
    }

    // Poll to see if the connection completes within the timeout
    let timeoutMs = Int32(timeout * 1000)
    var pollFd = pollfd(fd: Int32(fd), events: Int16(POLLOUT), revents: 0)
    let pollResult = Darwin.poll(&pollFd, 1, timeoutMs)
    guard pollResult > 0 else {
      Darwin.close(fd)
      return false
    }

    var optError: Int32 = 0
    var optLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &optError, &optLen)
    Darwin.close(fd)
    return optError == 0
  }
}

@MainActor
private final class CameraVendorWifiLocationAuthorizer: NSObject, @preconcurrency CLLocationManagerDelegate {
  static let shared = CameraVendorWifiLocationAuthorizer()

  private let manager = CLLocationManager()
  private var continuation: CheckedContinuation<CLAuthorizationStatus, Never>?
  private var diagnosticHandler: ((String) -> Void)?

  private override init() {
    super.init()
    manager.delegate = self
  }

  func prepareForSSIDAccess(
    diagnosticHandler: ((String) -> Void)? = nil
  ) async -> CLAuthorizationStatus {
    self.diagnosticHandler = diagnosticHandler
    let currentStatus = manager.authorizationStatus
    diagnosticHandler?(
      "定位权限状态: \(CameraVendorWifiJoinDiagnostics.describeLocationAuthorizationStatus(currentStatus))"
    )

    guard CameraVendorWifiJoinDiagnostics.shouldRequestLocationAuthorization(for: currentStatus) else {
      return currentStatus
    }

    diagnosticHandler?("请求定位权限，以便确认当前 Wi-Fi SSID")
    manager.requestWhenInUseAuthorization()
    let updatedStatus = await withCheckedContinuation { (continuation: CheckedContinuation<CLAuthorizationStatus, Never>) in
      self.continuation = continuation
    }
    diagnosticHandler?(
      "定位权限更新为: \(CameraVendorWifiJoinDiagnostics.describeLocationAuthorizationStatus(updatedStatus))"
    )
    return updatedStatus
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard let continuation else {
      return
    }
    self.continuation = nil
    continuation.resume(returning: manager.authorizationStatus)
  }
}

private final class CameraVendorPtpSessionRuntime {
  private let session: CameraVendorPtpSession
  private let requestScheduler = CameraVendorGalleryRequestScheduler()
  private let stateLock = NSLock()
  private let diagnosticHandler: (String) -> Void
  private let communicationGeneration: () -> UInt64
  private var isExclusiveDownloadWindowActive = false
  private var activeThumbnailRequestCount = 0
  private var activeBackgroundMetadataRequestCount = 0
  private var visibleThumbnailBatchHandles = Set<Int>()
  private var lastThumbnailActivityAt: Date = .distantPast
  private var hasReportedExclusiveDownloadWindowReady = false

  init(
    session: CameraVendorPtpSession,
    diagnosticHandler: @escaping (String) -> Void,
    communicationGeneration: @escaping () -> UInt64
  ) {
    self.session = session
    self.diagnosticHandler = diagnosticHandler
    self.communicationGeneration = communicationGeneration
  }

  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async rethrows -> T {
    beginExclusiveDownloadWindow()
    defer {
      endExclusiveDownloadWindow()
    }
    await awaitExclusiveDownloadWindowReady()
    return try await operation()
  }

  func beginExclusiveDownloadWindow() {
    requestScheduler.beginPriorityDownloadBarrier()
    activateExclusiveDownloadWindow()
  }

  func awaitExclusiveDownloadWindowReady() async {
    await requestScheduler.waitUntilIdle()
  }

  func endExclusiveDownloadWindow() {
    deactivateExclusiveDownloadWindow()
    requestScheduler.endPriorityDownloadBarrier()
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    stateLock.lock()
    visibleThumbnailBatchHandles.formUnion(handles)
    lastThumbnailActivityAt = Date()
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_VISIBLE_BATCH_BEGIN count=\(handles.count) pending=\(pendingCount)")
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    stateLock.lock()
    visibleThumbnailBatchHandles.subtract(handles)
    lastThumbnailActivityAt = Date()
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_VISIBLE_BATCH_END count=\(handles.count) pending=\(pendingCount)")
  }

  func fetchThumbnailWithInfo(
    for handle: Int,
    expectedSize: UInt32?
  ) async throws -> (thumbnail: CameraVendorGalleryThumbnail, objectInfo: CameraVendorCameraObjectInfo?) {
    try await requestScheduler.run(priority: .visibleThumbnail) {
      try self.beginThumbnailRequest(handle: handle)
      defer { self.endThumbnailRequest(handle: handle) }
      let result = try self.session.thumbWithInfo(
        handle: UInt32(handle),
        expectedSize: expectedSize
      )
      let item = result.objectInfo.map { info in
        CameraVendorGalleryItem(
          handle: info.handle,
          filename: info.filename,
          formatLabel: info.galleryFormatLabel,
          captureDate: info.captureDate,
          byteSizeText: info.compressedSize > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
            : "",
          compressedSize: info.compressedSize.nonzero,
          orientation: info.orientation
        )
      }
      return (
        CameraVendorGalleryThumbnail(data: result.data, item: item),
        result.objectInfo
      )
    }
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await requestScheduler.run(priority: .previewImage) {
      try self.session.previewImage(handle: UInt32(handle))
    }
  }

  func fetchPreviewImageWithInfo(
    for handle: Int
  ) async throws -> CameraVendorPreviewImageFetchResult {
    try await requestScheduler.run(priority: .previewImage) {
      try self.session.previewImageWithInfo(handle: UInt32(handle))
    }
  }

  func performBackgroundKeepAlive() async throws {
    try await requestScheduler.run(priority: .backgroundMetadata) {
      let handle = Int(CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle)
      try self.beginBackgroundMetadataRequest(handle: handle)
      defer { self.endBackgroundMetadataRequest(handle: handle) }
      _ = try self.session.cameraVendorLatestObjectInfo(
        preferredHandle: CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle
      )
    }
    diagnosticHandler(
      "[OBS] GALLERY_BACKGROUND_READ_IMAGE_INFO_KEEP_ALIVE_OK " +
      "op=0x9054 handle=0x\(String(format: "%08X", CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle))"
    )
  }

  func downloadOriginal(for handle: Int, expectedSize: UInt32?) async throws -> Data {
    try await requestScheduler.run(priority: .downloadOriginal) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      return try self.session.object(handle: UInt32(handle), expectedSize: expectedSize)
    }
  }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode,
    cachedInfo: CameraVendorCameraObjectInfo?
  ) async throws -> (Data, CameraVendorCameraObjectInfo?) {
    try await requestScheduler.run(priority: .downloadOriginal) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      let info = try (cachedInfo ?? self.session.objectInfo(handle: UInt32(handle)).reliableDownloadMetadata)
      let formatLabel = info?.galleryFormatLabel ?? ""
      let expectedSize = info?.compressedSize.nonzero
      let objectData = try self.session.objectData(
        handle: UInt32(handle),
        expectedSize: expectedSize,
        formatLabel: formatLabel,
        downloadMode: mode
      )
      return (objectData.data, objectData.info ?? info)
    }
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode,
    cachedInfo: CameraVendorCameraObjectInfo?
  ) async throws -> (URL, CameraVendorCameraObjectInfo?, CameraVendorOriginalFileTransferTiming) {
    try await requestScheduler.run(priority: .downloadOriginal) {
      self.reportExclusiveDownloadWindowReadyIfNeeded()
      try self.session.ensureConnectedForPriorityDownload()
      let fileResult = try self.session.objectFile(
        handle: UInt32(handle),
        cachedInfo: cachedInfo,
        downloadMode: mode
      )
      let info = fileResult.info.reliableDownloadMetadata ?? cachedInfo
      return (fileResult.fileURL, info, fileResult.timing)
    }
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await requestScheduler.runExclusiveMutation {
      do {
        return try self.session.cameraVendorInitialCatalogSnapshot()
      } catch {
        guard CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: error) else {
          throw error
        }
        try self.session.recoverInitialCameraCatalogAfterStoreNotAvailable()
        return try self.session.cameraVendorInitialCatalogSnapshot()
      }
    }
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await requestScheduler.runExclusiveMutation {
      try self.session.cameraVendorCatalogSnapshot(query: query)
    }
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await requestScheduler.runExclusiveMutation {
      try self.session.cameraVendorCountSweepExperiment()
    }
  }

  func objectInfo(
    handle: UInt32,
    readTimeout: TimeInterval
  ) async throws -> CameraVendorCameraObjectInfo {
    try await requestScheduler.run(priority: .backgroundMetadata) {
      try self.beginBackgroundMetadataRequest(handle: Int(handle))
      defer { self.endBackgroundMetadataRequest(handle: Int(handle)) }
      return try self.session.objectInfo(handle: handle, readTimeout: readTimeout)
    }
  }

  private func beginThumbnailRequest(handle: Int) throws {
    stateLock.lock()
    if isExclusiveDownloadWindowActive {
      stateLock.unlock()
      diagnosticHandler("[OBS] THUMBNAIL_REQUEST_REJECTED_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: CameraVendorPriorityDownloadThumbnailGatePolicy.suspendedThumbnailErrorCode,
        userInfo: [NSLocalizedDescriptionKey: "下载期间暂停缩略图加载"]
      )
    }
    activeThumbnailRequestCount += 1
    lastThumbnailActivityAt = Date()
    let activeCount = activeThumbnailRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] THUMBNAIL_REQUEST_BEGIN handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }

  private func endThumbnailRequest(handle: Int) {
    stateLock.lock()
    activeThumbnailRequestCount = max(0, activeThumbnailRequestCount - 1)
    visibleThumbnailBatchHandles.remove(handle)
    lastThumbnailActivityAt = Date()
    let activeCount = activeThumbnailRequestCount
    let pendingCount = visibleThumbnailBatchHandles.count
    stateLock.unlock()
    diagnosticHandler(
      "[OBS] THUMBNAIL_REQUEST_END handle=0x\(String(format: "%08X", handle)) " +
      "active=\(activeCount) pending=\(pendingCount)"
    )
  }

  private func currentThumbnailLaneState() -> (activeCount: Int, pendingCount: Int, lastActivityAt: Date) {
    stateLock.lock()
    let state = (activeThumbnailRequestCount, visibleThumbnailBatchHandles.count, lastThumbnailActivityAt)
    stateLock.unlock()
    return state
  }

  func galleryRequestCounts() -> (
    activeThumbnailCount: Int,
    activeBackgroundMetadataCount: Int,
    pendingThumbnailCount: Int
  ) {
    stateLock.lock()
    let counts = (
      activeThumbnailRequestCount,
      activeBackgroundMetadataRequestCount,
      visibleThumbnailBatchHandles.count
    )
    stateLock.unlock()
    return counts
  }

  private func activateExclusiveDownloadWindow() {
    stateLock.lock()
    isExclusiveDownloadWindowActive = true
    hasReportedExclusiveDownloadWindowReady = false
    stateLock.unlock()
  }

  private func deactivateExclusiveDownloadWindow() {
    stateLock.lock()
    isExclusiveDownloadWindowActive = false
    stateLock.unlock()
  }

  private func reportExclusiveDownloadWindowReadyIfNeeded() {
    stateLock.lock()
    let shouldReport = isExclusiveDownloadWindowActive && !hasReportedExclusiveDownloadWindowReady
    if shouldReport {
      hasReportedExclusiveDownloadWindowReady = true
    }
    stateLock.unlock()
    if shouldReport {
      diagnosticHandler("[OBS] PTP_EXCLUSIVE_DOWNLOAD_WINDOW_READY")
    }
  }

  private func beginBackgroundMetadataRequest(handle: Int) throws {
    stateLock.lock()
    if isExclusiveDownloadWindowActive {
      stateLock.unlock()
      diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REJECTED_PRIORITY_DOWNLOAD handle=0x\(String(format: "%08X", handle))")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: NSURLErrorCancelled,
        userInfo: [NSLocalizedDescriptionKey: "下载期间暂停后台元数据加载"]
      )
    }
    activeBackgroundMetadataRequestCount += 1
    let activeCount = activeBackgroundMetadataRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REQUEST_BEGIN handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }

  private func endBackgroundMetadataRequest(handle: Int) {
    stateLock.lock()
    activeBackgroundMetadataRequestCount = max(0, activeBackgroundMetadataRequestCount - 1)
    let activeCount = activeBackgroundMetadataRequestCount
    stateLock.unlock()
    diagnosticHandler("[OBS] GALLERY_BACKGROUND_METADATA_REQUEST_END handle=0x\(String(format: "%08X", handle)) active=\(activeCount)")
  }
}

final class CameraVendorRealtimeGalleryService: CameraGallerySession, CameraVendorGalleryBackgroundKeepAlive, CameraVendorGalleryObjectInfoSource, CameraVendorExclusiveDownloadWindowControlling, CameraVendorActiveDownloadInterrupting, CameraVendorActiveDownloadCancellationRequesting, CameraVendorVisibleThumbnailLaneCoordinating {
  private let session = CameraVendorPtpSession()
  private lazy var ptpRuntime = CameraVendorPtpSessionRuntime(
    session: session,
    diagnosticHandler: { [weak self] message in
      self?.report(message)
    },
    communicationGeneration: { [weak self] in
      self?.currentCommunicationGeneration() ?? 0
    }
  )
  private var objectInfoCache = CameraVendorObjectInfoCache()
  var diagnosticHandler: ((String) -> Void)?
  private var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] = []
  private var verifiedConnectionSteps: [IOSCameraConnectionStep] = []
  private var ptpClientName = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
  private var prefersManualWifiRecovery = false
  private var manualWifiPromptBaselineIP: String?
  /// Re-entrancy guard: prevents parallel PTP connections that conflict with each other.
  private let fetchLock = NSLock()
  private var isFetching = false
  private var communicationTerminationGeneration: UInt64 = 0
  private var hasExclusiveDownloadLease = false
  private var hasStartedPriorityDownloadBatch = false

  func configure(connectionSummary: CameraVendorConnectionSummary) {
    terminateCameraCommunication(reason: "configure-gallery-connection")
    session.configureTransferProfile(cameraSerialNumber: connectionSummary.serialNumber)
    wifiConfigurations = connectionSummary.wifiConfigurations
    verifiedConnectionSteps = connectionSummary.verifiedConnectionSteps
    ptpClientName = connectionSummary.connectedDeviceName
    prefersManualWifiRecovery = false
    manualWifiPromptBaselineIP = nil
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary
  ) -> CameraVendorConnectionSummary {
    summary
  }

  func galleryReadyConnectionSummary(
    from summary: CameraVendorConnectionSummary,
    confirmedSteps: [IOSCameraConnectionStep]
  ) -> CameraVendorConnectionSummary {
    guard !confirmedSteps.isEmpty else {
      return summary
    }
    return summary.updatingVerifiedConnectionSteps(confirmedSteps)
  }

  func terminateCameraCommunication(reason: String) {
    report("[OBS] GALLERY_COMMUNICATION_TERMINATE_REQUESTED reason=\(reason)")
    endExclusiveDownloadWindow()
    objectInfoCache.resetForPhysicalSession()
    fetchLock.lock()
    communicationTerminationGeneration += 1
    isFetching = false
    fetchLock.unlock()
    session.disconnect()
  }

  private func currentCommunicationGeneration() -> UInt64 {
    fetchLock.lock()
    let generation = communicationTerminationGeneration
    fetchLock.unlock()
    return generation
  }

  private func ensureCommunicationGenerationIsCurrent(_ generation: UInt64) throws {
    guard currentCommunicationGeneration() == generation else {
      throw NSError(
        domain: NSURLErrorDomain,
        code: NSURLErrorCancelled,
        userInfo: [NSLocalizedDescriptionKey: "图库加载已取消"]
      )
    }
  }

  func withExclusiveDownloadWindow<T>(_ operation: () async throws -> T) async rethrows -> T {
    beginExclusiveDownloadWindow()
    defer {
      endExclusiveDownloadWindow()
    }
    await awaitExclusiveDownloadWindowReady()
    return try await operation()
  }

  func beginExclusiveDownloadWindow() {
    guard !hasExclusiveDownloadLease else { return }
    hasExclusiveDownloadLease = true
    hasStartedPriorityDownloadBatch = false
    report("[OBS] PTP_EXCLUSIVE_DOWNLOAD_WINDOW_BEGIN")
    ptpRuntime.beginExclusiveDownloadWindow()
  }

  func awaitExclusiveDownloadWindowReady() async {
    await ptpRuntime.awaitExclusiveDownloadWindowReady()
    guard hasExclusiveDownloadLease, !Task.isCancelled else { return }
    session.beginPriorityDownloadBatch(
      generation: currentCommunicationGeneration()
    )
    hasStartedPriorityDownloadBatch = true
    let counts = ptpRuntime.galleryRequestCounts()
    report(
      "[OBS] PTP_EXCLUSIVE_DOWNLOAD_ADMISSION_READY " +
        "active=\(counts.activeThumbnailCount + counts.activeBackgroundMetadataCount) " +
        "pendingNonDownload=0 schedulerIdle=true"
    )
  }

  func endExclusiveDownloadWindow() {
    guard hasExclusiveDownloadLease else { return }
    if hasStartedPriorityDownloadBatch {
      session.finishPriorityDownloadBatch()
    }
    ptpRuntime.endExclusiveDownloadWindow()
    hasStartedPriorityDownloadBatch = false
    hasExclusiveDownloadLease = false
    report("[OBS] PRIORITY_DOWNLOAD_FINISH")
  }

  func interruptActiveDownload(reason: String) {
    report("[OBS] PTP_ACTIVE_DOWNLOAD_INTERRUPT reason=\(reason)")
    session.invalidateInFlightOperationForPriorityDownload(reason: reason)
  }

  func requestActiveDownloadCancellation(reason: String) {
    report("[OBS] PTP_ACTIVE_DOWNLOAD_SOFT_CANCEL_REQUESTED reason=\(reason)")
    session.requestActiveDownloadCancellation(reason: reason)
  }

  func beginVisibleThumbnailBatch(handles: [Int]) {
    ptpRuntime.beginVisibleThumbnailBatch(handles: handles)
  }

  func finishVisibleThumbnailBatch(handles: [Int]) {
    ptpRuntime.finishVisibleThumbnailBatch(handles: handles)
  }

  func beginMainlineGalleryFetch() throws -> UInt64 {
    CameraVendorFileLogger.log(
      "beginMainlineGalleryFetch: wifiConfigs=\(wifiConfigurations.count) prefersManual=\(prefersManualWifiRecovery)"
    )
    report(
      "[OBS] GALLERY_FETCH_START wifiConfigs=\(wifiConfigurations.map(\.ssid).joined(separator: ",")) " +
      "clientName=\(ptpClientName)"
    )
    fetchLock.lock()
    if isFetching {
      fetchLock.unlock()
      report("[OBS] GALLERY_FETCH_REJECTED_CONCURRENT")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: CameraVendorGalleryFetchConcurrencyPolicy.concurrentFetchErrorCode,
        userInfo: [NSLocalizedDescriptionKey: "已有图库加载任务在进行，请等待当前连接完成"]
      )
    }
    isFetching = true
    let fetchGeneration = communicationTerminationGeneration
    fetchLock.unlock()
    return fetchGeneration
  }

  func finishMainlineGalleryFetch(generation: UInt64) {
    fetchLock.lock()
    if communicationTerminationGeneration == generation {
      isFetching = false
    }
    fetchLock.unlock()
  }

  func appendGalleryRuntimeMessage(_ message: String) {
    report(message)
  }

  func hasVerifiedConnectionStep(_ step: IOSCameraConnectionStep) -> Bool {
    CameraVendorIOSOfficialConnectionEvidencePolicy.hasVerifiedStep(
      step,
      in: verifiedConnectionSteps
    )
  }

  func hasExplicitGalleryModeEvidence() -> Bool {
    session.hasExplicitGalleryModeEvidence
  }

  func currentOfficialWifiCredential() -> IOSCameraWifiCredential? {
    guard let preferredWifi = wifiConfigurations.first else {
      return nil
    }
    return IOSCameraWifiCredential.official(
      ssid: preferredWifi.ssid,
      passphrase: preferredWifi.passphrase,
      bssid: preferredWifi.bssid,
      source: .bleHandshake
    )
  }

  func completeSuccessfulGalleryRouteSearch() {
    prefersManualWifiRecovery = false
  }

  func prepareGalleryRouteAttempt(
    _ route: CameraVendorGalleryRoute,
    didCompleteWifiHandoff: Bool,
    recorder: (String) -> Void
  ) {
    recorder("[ROUTE \(route.id.rawValue)] 开始读取相机图库")
    recorder(
      "[ROUTE \(route.id.rawValue)] handoff=\(didCompleteWifiHandoff), " +
      "launchPayload=\(route.launchRequestPayload.map { String(format: "%02x", $0) }.joined())"
    )
    recorder(
      "[OBS] PTP_ROUTE_START id=\(route.id.rawValue) handoff=\(didCompleteWifiHandoff) " +
      "launchPayload=\(route.launchRequestPayload.map { String(format: "%02x", $0) }.joined())"
    )
    let startupDelay = route.ptpStartupDelaySeconds
    if startupDelay > 0 {
      recorder("[ROUTE \(route.id.rawValue)] 等待 \(Int(startupDelay)) 秒让相机 PTP 服务就绪...")
      Thread.sleep(forTimeInterval: startupDelay)
    } else {
      recorder("[ROUTE \(route.id.rawValue)] 跳过额外 PTP 启动等待")
    }
  }

  func buildGalleryRouteFailure(
    didCompleteWifiHandoff: Bool,
    diagnostics: [String],
    error: Error
  ) -> NSError {
    session.disconnect()
    let message = CameraVendorGalleryDiagnostics.composeFailureMessage(
      baseMessage: CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
        errorDescription: error.localizedDescription,
        didCompleteWifiHandoff: didCompleteWifiHandoff
      ),
      diagnostics: diagnostics
    )
    return NSError(
      domain: "CameraVendorRealtimeGalleryService",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }

  func joinCameraWifi(
    context: IOSCameraConnectionContext,
    communicationGeneration: UInt64,
    route: CameraVendorGalleryRoute?
  ) async throws -> CameraVendorGalleryWifiHandoffResult {
    var lastWifiJoinError: Error?
    var didJoinWifiAutomatically = false
    var skippedAutoJoinBecauseManual = false

    let currentSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
    let currentWifiIP = getWifiIPv4Address()
    let ssidMatchesCamera = wifiConfigurations.contains { $0.ssid == currentSSID }
    let currentPtpReachable = CameraVendorPtpConstants.isCameraWifiIPv4Address(currentWifiIP)
    let hasConfirmedCameraNetwork = CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
      currentSSID: currentSSID,
      wifiConfigurations: wifiConfigurations,
      isCameraPtpReachable: currentPtpReachable
    )
    report("Wi-Fi 预检查: ssid=\(currentSSID ?? "<nil>"), ip=\(currentWifiIP ?? "<nil>"), matchesCamera=\(ssidMatchesCamera)")
    report(
      "[OBS] WIFI_PRECHECK currentSSID=\(currentSSID ?? "nil") " +
      "ip=\(currentWifiIP ?? "nil") matchesCamera=\(ssidMatchesCamera) " +
      "ptpReachable=\(currentPtpReachable) confirmedCameraNetwork=\(hasConfirmedCameraNetwork)"
    )

    if hasConfirmedCameraNetwork {
      report("检测到 iPhone 已连接相机网络，跳过自动切换 Wi‑Fi，继续等待相机 IP 确认")
      prefersManualWifiRecovery = false
    } else if CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
      hasWifiConfigurations: !wifiConfigurations.isEmpty,
      prefersManualWifiRecovery: prefersManualWifiRecovery
    ) {
      for (configurationIndex, configuration) in wifiConfigurations.enumerated() {
        do {
          try await CameraVendorCameraWifiConnector.join(
            configuration: configuration,
            allowUnverifiedAssociationAfterRecoverableError:
              route?.allowsUnverifiedWifiHandoffAfterRecoverableError ?? false,
            diagnosticHandler: diagnosticHandler
          )
          didJoinWifiAutomatically = true
          prefersManualWifiRecovery = false
          break
        } catch {
          lastWifiJoinError = error
          report("Wi-Fi 连接失败 \(configuration.ssid): \(error.localizedDescription)")
          if CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
            attemptedConfigurationIndex: configurationIndex
          ) {
            report("首选相机 Wi‑Fi 自动连接失败，立即转入手动连接以避免相机传图状态超时")
            break
          }
        }
      }

      if !didJoinWifiAutomatically, let preferredConfiguration = wifiConfigurations.first {
        prefersManualWifiRecovery = true
        manualWifiPromptBaselineIP = currentWifiIP
        if let nsError = lastWifiJoinError as NSError?,
           nsError.domain == NEHotspotConfigurationErrorDomain,
           nsError.code == NEHotspotConfigurationError.internal.rawValue {
          report("当前构建可能无法自动切换到相机 Wi-Fi，请先手动加入。")
        }
        for instruction in CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(for: preferredConfiguration) {
          report(instruction)
        }
      }
    } else if prefersManualWifiRecovery {
      skippedAutoJoinBecauseManual = true
      report("检测到你可能已手动加入相机 Wi-Fi，本次跳过自动切换，直接尝试连接相机。")
    } else if !wifiConfigurations.isEmpty {
      prefersManualWifiRecovery = true
      manualWifiPromptBaselineIP = currentWifiIP
      report("自动 Wi-Fi 连接已停用，避免干扰已手动连接的相机 Wi-Fi。")
      if let preferredConfiguration = wifiConfigurations.first {
        for instruction in CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(for: preferredConfiguration) {
          report(instruction)
        }
      }
    } else {
      report("没有可用的相机 Wi-Fi 名称候选，停止进入 PTP")
    }

    let postJoinSnapshot = await waitForManualCameraWifiIfNeeded(
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      wifiConfigurations: wifiConfigurations,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      report: report
    )
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let postJoinManualRecoveryEvidence = CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: postJoinSnapshot.ssid,
      currentIP: postJoinSnapshot.ip,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    )
    let readySnapshot = await waitForCameraIPv4AfterAssociationEvidenceIfNeeded(
      hasAssociationEvidence: didJoinWifiAutomatically
        || hasConfirmedCameraNetwork
        || postJoinManualRecoveryEvidence,
      initialSSID: postJoinSnapshot.ssid,
      initialIP: postJoinSnapshot.ip,
      report: report
    )
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let postJoinSSID = readySnapshot.ssid
    let postJoinWifiIP = readySnapshot.ip
    let postJoinSSIDMatchesCamera = postJoinSSID.map { ssid in
      wifiConfigurations.contains { $0.ssid == ssid }
    } ?? false
    let manualPtpReachable = CameraVendorPtpConstants.isCameraWifiIPv4Address(postJoinWifiIP)
    let postJoinConfirmedCameraNetwork = CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
      currentSSID: postJoinSSID,
      wifiConfigurations: wifiConfigurations,
      isCameraPtpReachable: manualPtpReachable
    )
    let manualRecoveryNetworkEvidence = CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: postJoinSSID,
      currentIP: postJoinWifiIP,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    )

    if CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
      didJoinWifiAutomatically: didJoinWifiAutomatically,
      prefersManualWifiRecovery: prefersManualWifiRecovery,
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      currentSSIDMatchesCamera: postJoinSSIDMatchesCamera,
      isCameraPtpReachable: manualPtpReachable,
      hasCurrentWifiConfigurations: !wifiConfigurations.isEmpty
    ) {
      CameraVendorFileLogger.log("shouldPause=true, 抛出手动WiFi提示")
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "请先手动加入相机 Wi-Fi，然后回到 CamTransfer 点“重新加载”。"
        ]
      )
    }

    let didCompleteWifiHandoff = CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
      hasConfirmedCameraNetwork: hasConfirmedCameraNetwork,
      postJoinConfirmedCameraNetwork: postJoinConfirmedCameraNetwork,
      didJoinWifiAutomatically: didJoinWifiAutomatically,
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      manualRecoveryNetworkEvidence: manualRecoveryNetworkEvidence,
      postJoinCameraPtpReachable: manualPtpReachable
    )
    report(
      "[OBS] WIFI_HANDOFF_RESULT didJoinAutomatically=\(didJoinWifiAutomatically) " +
      "skippedManual=\(skippedAutoJoinBecauseManual) didComplete=\(didCompleteWifiHandoff) " +
      "currentSSID=\(postJoinSSID ?? "nil") ip=\(postJoinWifiIP ?? "nil") " +
      "ptpReachable=\(manualPtpReachable) manualEvidence=\(manualRecoveryNetworkEvidence)"
    )
    guard CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
      didCompleteWifiHandoff: didCompleteWifiHandoff
    ) else {
      let message = CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
        errorDescription: "Wi-Fi handoff 未完成，未启动 PTP 相册路线",
        didCompleteWifiHandoff: false
      )
      throw NSError(
        domain: "CameraVendorRealtimeGalleryService",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
    let joinedSSID = postJoinSSID ?? wifiConfigurations.first?.ssid ?? context.wifiCredential?.ssid
    guard let joinedSSID,
          !joinedSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw IOSCameraConnectionIssue(
        step: .joinCameraWifi,
        reason: "未获得可确认的相机 Wi-Fi SSID，已停止进入 PTP"
      )
    }
    return CameraVendorGalleryWifiHandoffResult(
      joinedSSID: joinedSSID,
      didCompleteWifiHandoff: didCompleteWifiHandoff
    )
  }

  func connectGalleryPtp(
    communicationGeneration: UInt64,
    recorder: @escaping (String) -> Void
  ) throws -> IOSCameraPtpSessionEvidence {
    try ensureCommunicationGenerationIsCurrent(communicationGeneration)
    let connectStartedAt = Date()
    try connectWithRetry(recorder: recorder, communicationGeneration: communicationGeneration)
    recorder(
      "[OBS] GALLERY_TIMING_CONNECT seconds=" +
      String(format: "%.3f", Date().timeIntervalSince(connectStartedAt))
    )
    return IOSCameraPtpSessionEvidence(sessionID: "\(ptpClientName)-ptp")
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchCameraCatalog(query: query)
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    try await ptpRuntime.fetchInitialCameraCatalog()
  }

  func executeCountSweepExperiment() async throws -> CameraVendorCountSweepResult {
    try await ptpRuntime.executeCountSweepExperiment()
  }

  func prepareCameraVendorLegacyGalleryLoadIfNeeded() throws {
    try session.prepareCameraVendorLegacyGalleryLoadIfNeeded()
  }

  private func waitForManualCameraWifiIfNeeded(
    skippedAutoJoinBecauseManual: Bool,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration],
    manualPromptBaselineIP: String?,
    report: @escaping (String) -> Void
  ) async -> (ssid: String?, ip: String?) {
    let initialSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
    let initialIP = getWifiIPv4Address()
    guard skippedAutoJoinBecauseManual else {
      return (initialSSID, initialIP)
    }

    if CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
      currentSSID: initialSSID,
      currentIP: initialIP,
      manualPromptBaselineIP: manualPromptBaselineIP,
      wifiConfigurations: wifiConfigurations
    ) {
      return (initialSSID, initialIP)
    }

    report(
      "[OBS] WIFI_MANUAL_WAIT_START ssid=\(initialSSID ?? "nil") " +
      "ip=\(initialIP ?? "nil") maxSeconds=\(Int(CameraVendorManualWifiReadinessPolicy.maxWaitSeconds))"
    )

    let deadline = Date().addingTimeInterval(CameraVendorManualWifiReadinessPolicy.maxWaitSeconds)
    var latestSSID = initialSSID
    var latestIP = initialIP
    while Date() < deadline {
      let sleepNanoseconds = UInt64(CameraVendorManualWifiReadinessPolicy.pollIntervalSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: sleepNanoseconds)
      latestSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
      latestIP = getWifiIPv4Address()
      report("[OBS] WIFI_MANUAL_WAIT_SAMPLE ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
      if CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: latestSSID,
        currentIP: latestIP,
        manualPromptBaselineIP: manualPromptBaselineIP,
        wifiConfigurations: wifiConfigurations
      ) {
        report("[OBS] WIFI_MANUAL_WAIT_READY ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
        return (latestSSID, latestIP)
      }
    }

    report("[OBS] WIFI_MANUAL_WAIT_TIMEOUT ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
    return (latestSSID, latestIP)
  }

  private func waitForCameraIPv4AfterAssociationEvidenceIfNeeded(
    hasAssociationEvidence: Bool,
    initialSSID: String?,
    initialIP: String?,
    report: @escaping (String) -> Void
  ) async -> (ssid: String?, ip: String?) {
    guard CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
      didJoinWifiAutomatically: hasAssociationEvidence,
      currentWifiIP: initialIP
    ) else {
      return (initialSSID, initialIP)
    }

    report(
      "[OBS] WIFI_IPV4_WAIT_START ssid=\(initialSSID ?? "nil") " +
      "ip=\(initialIP ?? "nil") maxSeconds=\(Int(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds))"
    )
    let deadline = Date().addingTimeInterval(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds)
    var latestSSID = initialSSID
    var latestIP = initialIP
    while Date() < deadline {
      let sleepNanoseconds = UInt64(CameraVendorWifiAssociationReadinessPolicy.pollIntervalSeconds * 1_000_000_000)
      try? await Task.sleep(nanoseconds: sleepNanoseconds)
      latestSSID = await CameraVendorCameraWifiConnector.fetchCurrentSSID()
      latestIP = getWifiIPv4Address()
      report("[OBS] WIFI_IPV4_WAIT_SAMPLE ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
      if !CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: latestIP
      ) {
        report("[OBS] WIFI_IPV4_WAIT_READY ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
        return (latestSSID, latestIP)
      }
    }

    report("[OBS] WIFI_IPV4_WAIT_TIMEOUT ssid=\(latestSSID ?? "nil") ip=\(latestIP ?? "nil")")
    return (latestSSID, latestIP)
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    try await fetchThumbnailWithInfo(for: handle).data
  }

  func fetchObjectInfo(for handle: Int) async throws -> CameraVendorCameraObjectInfo {
    let info = try await ptpRuntime.objectInfo(
      handle: UInt32(handle),
      readTimeout: CameraVendorBackgroundMetadataRefreshPolicy.objectInfoReadTimeoutSeconds
    )
    cacheObjectInfos([info])
    return info
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    let result = try await ptpRuntime.fetchThumbnailWithInfo(for: handle, expectedSize: expectedSize)
    if let info = result.objectInfo {
      cacheObjectInfos([info])
    }
    return result.thumbnail
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    try await ptpRuntime.fetchPreviewImage(for: handle)
  }

  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    let result = try await ptpRuntime.fetchPreviewImageWithInfo(for: handle)
    let info = result.objectInfo
    cacheObjectInfos([info])
    return CameraVendorGalleryPreview(
      data: result.data,
      item: CameraVendorGalleryItem(
        handle: info.handle,
        filename: info.filename,
        formatLabel: info.galleryFormatLabel,
        captureDate: info.captureDate,
        byteSizeText: info.compressedSize > 0
          ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
          : "",
        compressedSize: info.compressedSize.nonzero,
        orientation: info.orientation
      )
    )
  }

  func performBackgroundKeepAlive() async throws {
    try await ptpRuntime.performBackgroundKeepAlive()
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    return try await ptpRuntime.downloadOriginal(for: handle, expectedSize: expectedSize)
  }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData {
    let cachedInfo = objectInfoCache[handle]?.reliableDownloadMetadata
    let result = try await ptpRuntime.downloadOriginalData(
      for: handle,
      mode: mode,
      cachedInfo: cachedInfo
    )
    if let info = result.1 {
      cacheObjectInfos([info])
    }
    return CameraVendorDownloadedPhotoData(
      data: result.0,
      filename: result.1?.filename ?? "CamTransfer-\(handle).jpg"
    )
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    try await downloadOriginalFile(for: handle, mode: .original)
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile {
    let cachedInfo = objectInfoCache[handle]?.reliableDownloadMetadata
    let result = try await ptpRuntime.downloadOriginalFile(
      for: handle,
      mode: mode,
      cachedInfo: cachedInfo
    )
    if let info = result.1 {
      cacheObjectInfos([info])
    }
    let filename = result.1?.filename ?? "CamTransfer-\(handle).bin"
    let item = CameraVendorGalleryItem(
      handle: handle,
      filename: filename,
      formatLabel: result.1?.galleryFormatLabel ?? "",
      captureDate: result.1?.captureDate ?? "",
      byteSizeText: ""
    )
    let mediaType = CameraVendorGalleryDownloadPolicy.mediaType(for: item)
    let fileURL = result.0
    return CameraVendorDownloadedFile(
      fileURL: fileURL,
      filename: filename,
      mediaType: mediaType,
      transferTiming: result.2
    )
  }

  func probeReservedReceive() async throws -> CameraVendorReservedReceiveDiagnosticResult {
    report("[OBS] RESERVED_RECEIVE_DIAGNOSTIC_START")
    let shouldDisconnectSession = fetchLock.withLock { () -> Bool in
      let wasFetching = isFetching
      isFetching = true
      return wasFetching
    }
    if shouldDisconnectSession {
      session.disconnect()
    }

    defer {
      fetchLock.withLock {
        isFetching = false
      }
    }

    let clientName = ptpClientName
    let result = try await Task.detached(priority: .userInitiated) {
      let diagnosticSession = CameraVendorPtpSession()
      defer {
        diagnosticSession.disconnect()
      }
      try diagnosticSession.connect(
        clientName: clientName,
        diagnosticHandler: { [weak self] message in
          self?.report(message)
        },
        purpose: .reservedReceiveDiagnostic
      )
      return try diagnosticSession.reservedReceiveDiagnosticObject()
    }.value
    report("[OBS] RESERVED_RECEIVE_DIAGNOSTIC_RESULT \(result.summary)")
    return result
  }

  private func cacheObjectInfos(_ infos: [CameraVendorCameraObjectInfo]) {
    for info in infos {
      objectInfoCache.store(info)
    }
  }

  private func galleryItem(
    from info: CameraVendorCameraObjectInfo,
    formatHints: Set<CameraVendorGalleryFormatHint> = []
  ) -> CameraVendorGalleryItem {
    CameraVendorGalleryItem(
      handle: info.handle,
      filename: info.filename,
      formatLabel: info.galleryFormatLabel,
      captureDate: info.captureDate,
      byteSizeText: info.compressedSize > 0
        ? ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
        : "",
      compressedSize: info.compressedSize.nonzero,
      orientation: info.orientation,
      formatHints: formatHints
    )
  }

  private func galleryItems(
    from infos: [CameraVendorCameraObjectInfo],
    formatHintsByHandle: [Int: Set<CameraVendorGalleryFormatHint>] = [:],
    preserveInputOrder: Bool = false
  ) -> [CameraVendorGalleryItem] {
    CameraVendorGalleryItemOrderingPolicy.galleryItems(
      from: infos,
      formatHintsByHandle: formatHintsByHandle,
      preserveInputOrder: preserveInputOrder
    )
  }

  private func connectWithRetry(
    maxAttempts: Int = CameraVendorPtpConnectionStartupPolicy.maxAttempts,
    recorder: ((String) -> Void)? = nil,
    communicationGeneration: UInt64
  ) throws {
    var lastError: Error?
    let startedAt = Date()
    for attempt in 1...maxAttempts {
      try ensureCommunicationGenerationIsCurrent(communicationGeneration)
      do {
        try session.connect(clientName: ptpClientName, diagnosticHandler: recorder)
        try ensureCommunicationGenerationIsCurrent(communicationGeneration)
        return
      } catch {
        session.disconnect()
        try ensureCommunicationGenerationIsCurrent(communicationGeneration)
        if CameraVendorPtpReconnectErrorPolicy.shouldRetry(error) == false {
          throw error
        }

        lastError = error
        let elapsed = Date().timeIntervalSince(startedAt)
        if attempt < maxAttempts {
          let delay = CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
          recorder?(
            "PTP 连接失败 (第 \(attempt) 次，已等待 \(String(format: "%.1f", elapsed))s/" +
            "最多 \(maxAttempts) 次)，\(String(format: "%.1f", delay))s 后重试: \(error.localizedDescription)"
          )
          Thread.sleep(forTimeInterval: delay)
        }
      }
    }
    throw lastError ?? NSError(
      domain: "CameraVendorRealtimeGalleryService",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "PTP 连接多次失败"]
    )
  }

  private func waitForPtpReachability(
    timeout: TimeInterval = 10,
    interval: TimeInterval = 0.5,
    recorder: ((String) -> Void)? = nil
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if CameraVendorCameraPtpReachabilityProbe.isReachable() {
        recorder?("相机 PTP 端口已就绪")
        return true
      }
      recorder?("相机 PTP 端口未就绪，\(String(format: "%.1f", deadline.timeIntervalSince(Date())))s 后重试")
      Thread.sleep(forTimeInterval: interval)
    }
    return false
  }

  private func report(_ message: String) {
    guard CameraVendorPtpDiagnosticLogPolicy.shouldEmit(message) else { return }
    CameraVendorGalleryDiagnostics.log(message)
    diagnosticHandler?(message)
  }
}

extension CameraVendorBluetoothService: CameraVendorBleBackgroundKeepAlive {
  func performBackgroundBleKeepAlive(reason: String) {
    guard let peripheral = selectedPeripheral, peripheral.state == .connected else {
      appendObservation("BLE_BACKGROUND_KEEP_ALIVE_SKIPPED reason=\(reason) state=not-connected")
      return
    }

    let readableCharacteristics = CameraVendorBleBackgroundKeepAlivePolicy
      .preferredReadableCharacteristicUUIDStrings
      .compactMap { uuidString -> CBCharacteristic? in
      let uuid = CBUUID(string: uuidString)
      guard let characteristic = discoveredCharacteristicsByUUID[uuid],
            characteristic.properties.contains(.read) else {
        return nil
      }
      return characteristic
    }

    guard !readableCharacteristics.isEmpty else {
      appendObservation("BLE_BACKGROUND_KEEP_ALIVE_SKIPPED reason=\(reason) state=no-readable-characteristic")
      return
    }

    appendObservation(
      "BLE_BACKGROUND_KEEP_ALIVE_BATCH_READ_BEGIN reason=\(reason) count=\(readableCharacteristics.count)"
    )
    let spacing = CameraVendorBleBackgroundKeepAlivePolicy.readSpacingSeconds
    for (index, characteristic) in readableCharacteristics.enumerated() {
      DispatchQueue.main.asyncAfter(deadline: .now() + spacing * Double(index)) { [weak self, weak peripheral] in
        guard let self, let peripheral, peripheral.state == .connected else { return }
        self.appendObservation(
          "BLE_BACKGROUND_KEEP_ALIVE_READ reason=\(reason) " +
          "index=\(index + 1)/\(readableCharacteristics.count) uuid=\(characteristic.uuid.uuidString)"
        )
        peripheral.readValue(for: characteristic)
      }
    }
  }
}

extension CameraVendorBluetoothService: CameraVendorBackgroundActivityObserving {
  func setBackgroundActivityObserver(_ observer: (() -> Void)?) {
    backgroundActivityObserver = observer
  }

  private func recordBackgroundHardwareActivity() {
    backgroundActivityObserver?()
  }
}

enum CameraVendorAppVariant: String, Codable, Equatable {
  case unknown = "Unknown"
  case legacyRemote = "Legacy Remote"
  case referenceApp = "ReferenceApp"
  case standby = "Standby"
}

struct CameraVendorDiscoveredCamera: Equatable {
  let id: UUID
  let name: String
  let rssi: Int
  let appVariant: CameraVendorAppVariant
  let pairingToken: Data?
  let matchDetails: String
}

struct CameraVendorAdvertisementMatch: Equatable {
  let resolvedName: String
  let appVariant: CameraVendorAppVariant
  let pairingToken: Data?
  let reasons: [String]
}

enum CameraVendorDeviceMatcher {
  static let legacyRemoteServiceUUIDString = "117C4142-EDD4-4C77-8696-DD18EEBB770A"
  static let referenceAppServiceUUIDString = "AF854C2E-B214-458E-97E2-912C4ECF2CB8"
  static let securePairServiceUUIDString = "123D8F06-62A1-4935-9322-833C531EE225"
  static let standbyServiceUUIDString = "A9D2B304-E8D6-4902-8336-352B772D7597"

  private static let knownServiceUUIDs: [String: CameraVendorAppVariant] = [
    legacyRemoteServiceUUIDString: .legacyRemote,
    referenceAppServiceUUIDString: .referenceApp,
    standbyServiceUUIDString: .standby,
  ]

  static func matchAdvertisement(
    name: String?,
    serviceUUIDs: [String],
    manufacturerData: Data?
  ) -> CameraVendorAdvertisementMatch? {
    let normalizedName = normalizedName(name)
    let normalizedServiceUUIDs = Set(serviceUUIDs.map(normalize(uuid:)))

    var reasons: [String] = []
    var appVariant: CameraVendorAppVariant = .unknown

    if let matchedName = normalizedName, isLikelyCameraVendorCameraName(matchedName) {
      reasons.append("name")
    }

    for uuid in normalizedServiceUUIDs {
      if let variant = knownServiceUUIDs[uuid] {
        reasons.append("service:\(variant.rawValue)")
        appVariant = preferredVariant(current: appVariant, candidate: variant)
      }
    }

    let token = pairingToken(from: manufacturerData)
    if token != nil {
      reasons.append("manufacturer-token")
    }

    let hasPositivePrimaryMatch = reasons.contains("name")
      || reasons.contains(where: { $0.hasPrefix("service:") })

    guard hasPositivePrimaryMatch else {
      return nil
    }

    let resolvedName = normalizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = resolvedName.flatMap { $0.isEmpty ? nil : $0 } ?? "CAMERA_VENDOR"

    return CameraVendorAdvertisementMatch(
      resolvedName: displayName,
      appVariant: appVariant,
      pairingToken: token,
      reasons: reasons
    )
  }

  static func pairingToken(from manufacturerData: Data?) -> Data? {
    guard let manufacturerData else {
      return nil
    }

    if manufacturerData.count >= 7,
       manufacturerData[0] == 0xD8,
       manufacturerData[1] == 0x04,
       manufacturerData[2] == 0x02 {
      return manufacturerData.subdata(in: 3..<7)
    }

    if manufacturerData.count >= 5, manufacturerData[0] == 0x02 {
      return manufacturerData.subdata(in: 1..<5)
    }

    return nil
  }

  static func isPairingReadyAdvertisement(
    serviceUUIDs: [String],
    manufacturerData: Data?
  ) -> Bool {
    let normalizedServiceUUIDs = Set(serviceUUIDs.map(normalize(uuid:)))
    if normalizedServiceUUIDs.contains(normalize(uuid: referenceAppServiceUUIDString)) {
      return true
    }
    if normalizedServiceUUIDs.contains(normalize(uuid: securePairServiceUUIDString)) {
      return true
    }

    guard let manufacturerData, manufacturerData.count >= 3 else {
      return false
    }

    return manufacturerData[0] == 0xD8
      && manufacturerData[1] == 0x04
      && manufacturerData[2] == 0x02
  }

  private static func normalizedName(_ name: String?) -> String? {
    name?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func isLikelyCameraVendorCameraName(_ name: String) -> Bool {
    guard !name.isEmpty else {
      return false
    }

    let uppercase = name.uppercased()
    return uppercase.contains("CAMERA_VENDOR")
      || uppercase.hasPrefix("CAMERA-")
      || isLikelyFujifilmModelName(uppercase)
  }

  private static func isLikelyFujifilmModelName(_ uppercaseName: String) -> Bool {
    uppercaseName == "X-T5"
      || uppercaseName.hasPrefix("X-T")
      || uppercaseName.hasPrefix("X-H")
      || uppercaseName.hasPrefix("X-S")
      || uppercaseName.hasPrefix("X-E")
      || uppercaseName.hasPrefix("X-PRO")
      || uppercaseName.hasPrefix("GFX")
      || uppercaseName.contains("FUJIFILM")
  }

  private static func normalize(uuid: String) -> String {
    uuid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private static func preferredVariant(
    current: CameraVendorAppVariant,
    candidate: CameraVendorAppVariant
  ) -> CameraVendorAppVariant {
    if current == .unknown {
      return candidate
    }
    return current
  }
}

enum CameraVendorSecureHandshakeCodec {
  static func pairingPayload(_ token: Data) -> Data {
    token
  }

  static func identifierPayload(_ identifier: String) -> Data {
    Data(identifier.utf8)
  }

  static func statusAckPayload(from status: Data) -> Data? {
    guard status.count == 4 else {
      return nil
    }

    return Data([status[0], status[1], status[2], 0x20])
  }
}

enum CameraVendorSecureIdentificationAckPolicy {
  static func shouldSkipIdentificationAck(isRememberedPairing _: Bool) -> Bool {
    false
  }
}

enum CameraVendorReferenceAppPairingCodec {
  private static let referenceAppIdentifierBit: UInt32 = 0x20000000

  static func identificationNumberPayload(from identificationNumber: Data) -> Data? {
    guard identificationNumber.count == 4 else {
      return nil
    }

    let value =
      UInt32(identificationNumber[0])
      | (UInt32(identificationNumber[1]) << 8)
      | (UInt32(identificationNumber[2]) << 16)
      | (UInt32(identificationNumber[3]) << 24)
    let payload = value | referenceAppIdentifierBit
    return withUnsafeBytes(of: payload.littleEndian) { Data($0) }
  }

  static func isAlreadyPairedIdentificationNumber(_ identificationNumber: Data) -> Bool {
    guard identificationNumber.count == 4 else {
      return false
    }

    return (identificationNumber[3] & 0x20) == 0x20
  }
}
enum CameraVendorHandshakeIdentityPolicy {
  static let fallbackConnectedDeviceName = "CamTransfer"
  // ReferenceApp 实际抓包看到的 PTP friendlyName 是 "iPhone-####"（保留前缀 i）。
  // 相机配对列表对中文/自定义设备名兼容性不稳定，所以配对名固定走这个格式。
  private static let referenceAppGenericPhonePrefix = "iPhone"

  static func currentConnectedDeviceName(fallbackAppName: String? = nil) -> String {
    connectedDeviceName(
      preferredDeviceName: UIDevice.current.name,
      fallbackAppName: fallbackAppName
    )
  }

  static func connectedDeviceName(
    preferredDeviceName: String?,
    fallbackAppName: String?
  ) -> String {
    referenceAppStyleGenericIPhoneName()
  }

  private static func referenceAppStyleGenericIPhoneName() -> String {
    let suffix = fallbackConnectedDeviceName.utf8.reduce(UInt32(0)) { partial, byte in
      (partial &* 31 &+ UInt32(byte)) % 10_000
    }
    return String(format: "\(referenceAppGenericPhonePrefix)-%04u", suffix)
  }

  static func normalizedStoredConnectedDeviceName(_ storedName: String) -> String {
    referenceAppStyleGenericIPhoneName()
  }
}

enum CameraVendorHandshakeMode {
  case undetermined
  case legacy
  case secure
}

enum CameraVendorSecureHandshakePhase {
  case idle
  case awaitingDeviceNameWrite
  case awaitingIdentificationNumberRead
  case awaitingIdentificationNumberWrite
  case completed
}

enum CameraVendorReferenceAppPairingStep: Equatable {
  case writeDeviceName
  case didWriteDeviceName
  case readIdentificationNumber
}

enum CameraVendorReferenceAppPairingPolicy {
  static let initialStep: CameraVendorReferenceAppPairingStep = .writeDeviceName

  static func nextStep(after step: CameraVendorReferenceAppPairingStep) -> CameraVendorReferenceAppPairingStep? {
    switch step {
    case .writeDeviceName:
      return .didWriteDeviceName
    case .didWriteDeviceName:
      return .readIdentificationNumber
    case .readIdentificationNumber:
      return nil
    }
  }
}

enum CameraVendorSecureHandshakeRecoveryPolicy {
  static func shouldReconnectAfterUnexpectedDisconnect(
    phase: CameraVendorSecureHandshakePhase,
    retryCount: Int
  ) -> Bool {
    guard retryCount == 0 else {
      return false
    }

    switch phase {
    case .awaitingIdentificationNumberWrite:
      return true
    case .idle, .awaitingDeviceNameWrite, .awaitingIdentificationNumberRead, .completed:
      return false
    }
  }
}

struct CameraVendorHandshakeCoordinator {
  private(set) var pendingCharacteristicServices: Set<String> = []
  private(set) var pendingMetadataCharacteristics: Set<String> = []
  private(set) var pendingNotificationSubscriptions: Set<String> = []
  private(set) var didStartHandshake = false

  mutating func registerServiceForCharacteristicDiscovery(_ uuid: String) {
    pendingCharacteristicServices.insert(uuid.uppercased())
  }

  mutating func completeCharacteristicDiscovery(for uuid: String) {
    pendingCharacteristicServices.remove(uuid.uppercased())
  }

  mutating func registerMetadataRead(_ uuid: String) {
    pendingMetadataCharacteristics.insert(uuid.uppercased())
  }

  mutating func completeMetadataRead(_ uuid: String) {
    pendingMetadataCharacteristics.remove(uuid.uppercased())
  }

  mutating func registerNotificationSubscription(_ uuid: String) {
    pendingNotificationSubscriptions.insert(uuid.uppercased())
  }

  mutating func completeNotificationSubscription(for uuid: String) {
    pendingNotificationSubscriptions.remove(uuid.uppercased())
  }

  mutating func markHandshakeStarted() {
    didStartHandshake = true
  }

  func canStartHandshake(hasIdentifierCharacteristic: Bool) -> Bool {
    hasIdentifierCharacteristic
      && pendingCharacteristicServices.isEmpty
      && pendingMetadataCharacteristics.isEmpty
      && pendingNotificationSubscriptions.isEmpty
      && !didStartHandshake
  }

  func canStartSecureHandshake(
    hasConnectedDeviceNameCharacteristic: Bool,
    hasConnectedDeviceIdentificationCharacteristic: Bool
  ) -> Bool {
    hasConnectedDeviceNameCharacteristic
      && hasConnectedDeviceIdentificationCharacteristic
      && pendingCharacteristicServices.isEmpty
      && pendingMetadataCharacteristics.isEmpty
      && pendingNotificationSubscriptions.isEmpty
      && !didStartHandshake
  }
}

struct CameraVendorEncryptionRecoveryPolicy {
  enum DisconnectAction: Equatable {
    case none
    case requireManualCameraPairingMode
  }

  private(set) var hasRetriedAfterEncryptionFailure = false
  private(set) var isAwaitingReconnect = false

  mutating func registerEncryptionFailureAndShouldRetry() -> Bool {
    guard !hasRetriedAfterEncryptionFailure else {
      return false
    }

    hasRetriedAfterEncryptionFailure = true
    isAwaitingReconnect = true
    return true
  }

  mutating func consumeReconnectRequest() -> Bool {
    guard isAwaitingReconnect else {
      return false
    }

    isAwaitingReconnect = false
    return true
  }

  mutating func consumeDisconnectAction() -> DisconnectAction {
    guard consumeReconnectRequest() else {
      return .none
    }

    return .requireManualCameraPairingMode
  }

  func shouldRequireSystemBluetoothCleanupAfterRetryExhausted() -> Bool {
    hasRetriedAfterEncryptionFailure
  }

  mutating func reset() {
    hasRetriedAfterEncryptionFailure = false
    isAwaitingReconnect = false
  }
}

final class CameraVendorLogStore {
  private let fileURL: URL
  private let fileManager: FileManager
  private var recentLines: [String] = []
  private let maxMemoryLineCount = 1500

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    fileURL = baseURL.appendingPathComponent("cameraVendor-fast-debug.log")
  }

  var currentContents: String {
    if !recentLines.isEmpty {
      return recentLines.joined(separator: "\n")
    }
    return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
  }

  var currentFileURL: URL {
    fileURL
  }

  func clear() {
    recentLines.removeAll()
    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    for index in 1...CameraVendorFileLogPolicy.maxArchiveLogCount {
      try? fileManager.removeItem(at: archivedFileURL(index: index))
    }
  }

  func append(_ line: String, writesToDisk: Bool = true) {
    recentLines.append(line)
    if recentLines.count > maxMemoryLineCount {
      recentLines.removeFirst(recentLines.count - maxMemoryLineCount)
    }
    guard writesToDisk else {
      return
    }
    let payload = "\(line)\n"
    trimAndRotateIfNeeded(addingBytes: payload.utf8.count)
    if fileManager.fileExists(atPath: fileURL.path),
       let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(payload.utf8))
      return
    }

    try? payload.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private func trimAndRotateIfNeeded(addingBytes: Int) {
    let currentSize = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
    guard currentSize + addingBytes > CameraVendorFileLogPolicy.maxPrimaryLogBytes else {
      return
    }

    try? fileManager.removeItem(
      at: archivedFileURL(index: CameraVendorFileLogPolicy.maxArchiveLogCount)
    )
    if CameraVendorFileLogPolicy.maxArchiveLogCount > 1 {
      for index in stride(
        from: CameraVendorFileLogPolicy.maxArchiveLogCount - 1,
        through: 1,
        by: -1
      ) {
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
    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
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

protocol CameraVendorBluetoothServiceDelegate: AnyObject {
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateStatus status: String,
    isBusy: Bool
  )
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didUpdateDiscoveredCameras cameras: [CameraVendorDiscoveredCamera]
  )
  func cameraVendorBluetoothService(_ service: CameraVendorBluetoothService, didAppendLog message: String)
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompletePairing summary: CameraVendorConnectionSummary
  )
  func cameraVendorBluetoothService(
    _ service: CameraVendorBluetoothService,
    didCompleteHandshake summary: CameraVendorConnectionSummary
  )
}

final class CameraVendorBluetoothService: NSObject {
  private let buildMarker = "BUILD_MARK_20260718_ORIGINAL_TRANSFER_WORKER"
  private let pairServiceUUID = CBUUID(string: "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8")
  private let pairingCharacteristicUUID = CBUUID(string: "ABA356EB-9633-4E60-B73F-F52516DBD671")
  private let connectedDeviceNameCharacteristicUUID = CBUUID(string: "85B9163E-62D1-49FF-A6F5-054B4630D4A1")
  private let securePairServiceUUID = CBUUID(string: "123D8F06-62A1-4935-9322-833C531EE225")
  private let connectedDeviceIdentificationCharacteristicUUID = CBUUID(string: "F557D96B-8284-4667-8793-B971C1DECA2A")
  private let notificationCharacteristicUUID = CBUUID(string: "4C0020FE-F3B6-40DE-ACC9-77D129067B14")
  private let indicationOneCharacteristicUUID = CBUUID(string: "A68E3F66-0FCC-4395-8D4C-AA980B5877FA")
  private let indicationTwoCharacteristicUUID = CBUUID(string: "BD17BA04-B76B-4892-A545-B73BA1F74DAE")
  private let indicationThreeCharacteristicUUID = CBUUID(string: "049EC406-EF75-4205-A390-08FE209C51F0")
  private let notificationOneCharacteristicUUID = CBUUID(string: "F9150137-5D40-4801-A8DC-F7FC5B01DA50")
  private let notificationThreeServiceUUID = CBUUID(string: "804DAA8E-FFEB-4AB3-8E75-6EDD7303208D")
  private let notificationThreeCharacteristicUUID = CBUUID(string: "7170FD5A-56D9-4C19-B043-7A7047D8E1A0")
  private let notificationXServiceUUID = CBUUID(string: "4E941240-D01D-46B9-A5EA-67636806830B")
  private let notificationFourCharacteristicUUID = CBUUID(string: "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4")
  private let notificationFiveCharacteristicUUID = CBUUID(string: "75823784-FBB7-4B71-ABAE-CD9A34072E3C")
  private let notificationSixCharacteristicUUID = CBUUID(string: "E6692C5C-B7CD-44F4-95FC-EDA07CE32560")
  private let notificationSevenCharacteristicUUID = CBUUID(string: "AAB609C4-94DD-4D89-BC60-665D5090B828")
  private let notificationEightCharacteristicUUID = CBUUID(string: "2A125640-706D-4DD1-B420-C0F4AB93C361")
  private let notificationNineCharacteristicUUID = CBUUID(string: "82A9F452-C5CE-4EF5-8203-3FC9A47F8171")
  private let notificationTenCharacteristicUUID = CBUUID(string: "DEEF7187-3F43-4364-9E22-11A8C8A15951")
  private let geotagUpdateCharacteristicUUID = CBUUID(string: "AD06C7B7-F41A-46F4-A29A-712055319122")
  private let geotagSyncIntervalCharacteristicUUID = CBUUID(string: "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B")
  private let deviceNameServiceUUID = CBUUID(string: "1800")
  private let deviceNameCharacteristicUUID = CBUUID(string: "2A00")
  private let deviceInformationServiceUUID = CBUUID(string: "180A")
  private let serialNumberCharacteristicUUID = CBUUID(string: "2A25")
  private let firmwareRevisionCharacteristicUUID = CBUUID(string: "2A26")
  private let cameraYNumberCharacteristicUUID = CBUUID(string: "27870478-94A9-4345-849B-EFA3BF37887F")
  private let cameraMacAddressCharacteristicUUID = CBUUID(string: "49A12959-DFAA-4EB2-89CE-62548AD948F3")
  private let cameraSerialCharacteristicUUID = CBUUID(string: "E8E40D50-A625-4F1D-96ED-8CEC034F5690")
  private let cameraSSIDCharacteristicUUID = CBUUID(string: "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4")
  private let cameraWifiPassphraseCharacteristicUUID = CBUUID(string: "E809256A-915C-4967-92E8-53B7D4CAD213")
  private let pairingStore: CameraVendorPairedCameraStore

  weak var delegate: CameraVendorBluetoothServiceDelegate?

  private lazy var central = CBCentralManager(delegate: self, queue: .main)
  private var shouldScanWhenPoweredOn = false
  private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
  private var discoveredCameras: [CameraVendorDiscoveredCamera] = []
  private var selectedPeripheral: CBPeripheral?
  private var backgroundActivityObserver: (() -> Void)?
  private var selectedCamera: CameraVendorDiscoveredCamera?
  private var pairingCharacteristic: CBCharacteristic?
  private var connectedDeviceNameCharacteristic: CBCharacteristic?
  private var connectedDeviceIdentificationCharacteristic: CBCharacteristic?
  private var discoveredCharacteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
  private var notifiableCharacteristics: [CBCharacteristic] = []
  private var probedCharacteristics: [CBUUID: CBCharacteristic] = [:]
  private var observedCharacteristicValues: [String: Data] = [:]
  private var unmatchedAdvertisementSampleKeys: Set<String> = []
  private var unmatchedAdvertisementSampleCount = 0
  private var scanTimeoutWorkItem: DispatchWorkItem?
  private var postHandshakeProbeTimeoutWorkItem: DispatchWorkItem?
  private var transferActivationTimeoutWorkItem: DispatchWorkItem?
  private var bleStateSamplingWorkItems: [DispatchWorkItem] = []
  private var bleStateSamplingCompletionWorkItem: DispatchWorkItem?
  private var reservedImageReceiveProbeWorkItems: [DispatchWorkItem] = []
  private var hasScheduledReservedImageReceiveProbe = false
  private var transferActivationTimeoutSetAt: CFAbsoluteTime = 0
  private var discoveredName: String?
  private var discoveredSerialNumber: String?
  private var handshakeCoordinator = CameraVendorHandshakeCoordinator()
  private var lastHandshakeWaitReason: String?
  private let logStore = CameraVendorLogStore()
  private var handshakeMode: CameraVendorHandshakeMode = .undetermined
  private var encryptionRecoveryPolicy = CameraVendorEncryptionRecoveryPolicy()
  private var awaitingPairingReadyRediscovery = false
  private var pendingHandshakeSummary: CameraVendorConnectionSummary?
  private var lastLoggedWifiConfiguration: CameraVendorWifiNetworkConfiguration?
  private var pendingPostHandshakeProbeReads: Set<String> = []
  private var isRunningPostHandshakeProbe = false
  private var pendingTransferActivationStrategies: [CameraVendorReferenceAppTransferActivationStrategy] = []
  private var pendingTransferActivationWrites: [CameraVendorBleWriteRequest] = []
  private var currentTransferActivationStrategy: CameraVendorReferenceAppTransferActivationStrategy?
  private var transferActivationWritePayloadsByUUID: [String: Data] = [:]
  private var isRunningTransferActivation = false
  private var hasAttemptedAutomaticTransferActivation = false
  private var hadAutomaticTransferActivationFeature = false
  private var transferActivationObservedChange = false
  private var transferActivationObservedWifiLaunch = false
  private var transferActivationCameraResponded = false
  private var isDelayingGalleryForBleStateSampling = false
  private var awaitingTransferActivationStateChange = false
  private var awaitingTransferActivationStateChangeSince: Date?
  private var awaitingBluetoothDisconnectForWifiHandoff = false
  private var bluetoothDisconnectHandoffTimeoutWorkItem: DispatchWorkItem?
  private var didCompletePairingCallback = false
  private var didCompleteHandshakeCallback = false
  private var hasWrittenPairingIdentifier = false
  private var hasQueuedPhonePairingConfirmation = false
  private var hasCompletedPairing = false
  private var hasUserInitiatedTransfer = false
  private var activeWirelessIntent: IOSCameraServiceWirelessIntent = .idle
  private var secureHandshakePhase: CameraVendorSecureHandshakePhase = .idle
  private var secureHandshakeReconnectCount = 0
  private var secureIdentificationNumberAlreadyPaired = false
  private var rememberedPairedCameras: [CameraVendorPairedCameraRecord]
  private var rememberedPairedCamera: CameraVendorPairedCameraRecord?
  private var autoReconnectTargetPeripheralID: UUID?
  private var shouldAutoReconnectRememberedCamera = false
  private var isNextRememberedCameraConnectionUserApproved = false

  init(pairingStore: CameraVendorPairedCameraStore = CameraVendorPairedCameraStore()) {
    self.pairingStore = pairingStore
    let savedRecords = pairingStore.loadAll()
    self.rememberedPairedCameras = savedRecords
    self.rememberedPairedCamera = savedRecords.first
    super.init()
    appendLog("=== CamTransfer 启动 ===")
    appendLog("运行构建标记: \(buildMarker)")
  }

  private var connectedDeviceNameToWrite: String {
    if let rememberedPairedCamera,
       rememberedPairedCamera.peripheralID == selectedPeripheral?.identifier,
       let storedName = rememberedPairedCamera.connectedDeviceName?.trimmingCharacters(
         in: .whitespacesAndNewlines
       ),
       !storedName.isEmpty {
      return CameraVendorHandshakeIdentityPolicy.normalizedStoredConnectedDeviceName(storedName)
    }

    let bundleName =
      (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
    return CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName(fallbackAppName: bundleName)
  }

  var currentLogText: String {
    logStore.currentContents
  }

  var logFileURL: URL {
    logStore.currentFileURL
  }

  var rememberedCameraSummary: CameraVendorConnectionSummary? {
    rememberedPairedCameras.first?.connectionSummary
  }

  var rememberedCameraSummaries: [CameraVendorConnectionSummary] {
    rememberedPairedCameras.map(\.connectionSummary)
  }

  var rememberedCameraRecords: [CameraVendorPairedCameraRecord] {
    rememberedPairedCameras
  }

  func isRememberedCamera(_ camera: CameraVendorDiscoveredCamera) -> Bool {
    rememberedPairedCameras.contains { $0.peripheralID == camera.id }
  }

  var rememberedCameraID: UUID? {
    rememberedPairedCamera?.peripheralID
  }

  func clearLogs() {
    logStore.clear()
  }

  @discardableResult
  func restoreLastPairedCameraIfAvailable() -> Bool {
    if publishSystemBluetoothCleanupBlockIfNeeded() {
      return false
    }
    rememberedPairedCameras = pairingStore.loadAll()
    rememberedPairedCamera = rememberedPairedCameras.first

    guard let record = rememberedPairedCameras.first else {
      _ = central.state
      return false
    }
    appendLog("已读取 \(rememberedPairedCameras.count) 台保存的配对相机，默认: \(record.deviceName) [\(record.peripheralID.uuidString)]")
    return true
  }

  @discardableResult
  func connectLastPairedCameraIfAvailable() -> Bool {
    rememberedPairedCameras = pairingStore.loadAll()
    guard let record = rememberedPairedCameras.first else {
      _ = central.state
      return false
    }
    return connectPairedCamera(peripheralID: record.peripheralID)
  }

  @discardableResult
  func connectPairedCamera(peripheralID: UUID) -> Bool {
    let cleanupBlocked = publishSystemBluetoothCleanupBlockIfNeeded()

    rememberedPairedCameras = pairingStore.loadAll()
    guard let record = rememberedPairedCameras.first(where: { $0.peripheralID == peripheralID }) else {
      _ = central.state
      return false
    }

    let entryDecision = IOSCameraRememberedConnectionFlowDriver.connectPairedCamera(
      record: makeCoreRememberedRecord(from: record),
      cleanupBlocked: cleanupBlocked,
      hasUserApproval: isNextRememberedCameraConnectionUserApproved,
      hasInFlightAttempt: selectedPeripheral != nil || autoReconnectTargetPeripheralID != nil || isRunningTransferActivation,
      hasOfficialWifiRecord: CameraVendorStoredPairingPolicy.canEnterGallery(record: record),
      centralPoweredOn: central.state == .poweredOn
    )

    switch entryDecision {
    case .blockedByCleanup:
      return false
    case .waitForUserApproval:
      appendLog("已配对相机连接未经过用户确认，已阻止自动重连")
      return true
    case .ignoreBecauseInFlight:
      isNextRememberedCameraConnectionUserApproved = false
      appendLog("已配对相机连接流程已在进行，忽略重复连接请求")
      return true
    case .failMissingOfficialWifiRecord:
      isNextRememberedCameraConnectionUserApproved = false
      appendLog("已配对记录缺少本次官方 Wi-Fi 配置，已阻止进入相册，请清除旧配对后重新配对")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
      return false
    case .proceed(let shouldAttemptAutoReconnect):
      isNextRememberedCameraConnectionUserApproved = false
      rememberedPairedCamera = record

      appendLog("检测到已保存配对相机: \(record.deviceName) [\(record.peripheralID.uuidString)]")
      updateStatus("准备连接已配对的相机", isBusy: true)
      shouldAutoReconnectRememberedCamera = true

      if shouldAttemptAutoReconnect {
        attemptAutoReconnect(using: record)
      }
      return true
    }
  }

  @discardableResult
  func startRememberedCameraConnection(peripheralID: UUID) -> Bool {
    let startDecision = IOSCameraRememberedConnectionFlowDriver.startRememberedConnection(
      cleanupBlocked: publishSystemBluetoothCleanupBlockIfNeeded(),
      order: IOSCameraConnectionStep.officialGalleryOrder
    )
    guard case .beginMainline(let orderDescription) = startDecision else {
      return false
    }
    appendLog("用户点击进入相机相册，按 Android 主链路编排执行: \(orderDescription)")
    updateStatus("准备进入相机相册", isBusy: true)
    resetWirelessCameraFlow()
    isNextRememberedCameraConnectionUserApproved = true
    activeWirelessIntent = .rememberedGallery
    return connectPairedCamera(peripheralID: peripheralID)
  }

  var requiresSystemBluetoothPairingCleanup: Bool {
    CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup()
  }

  @discardableResult
  func publishSystemBluetoothCleanupBlockIfNeeded() -> Bool {
    guard requiresSystemBluetoothPairingCleanup else {
      return false
    }
    cancelLocalPairingForSystemBluetoothCleanup()
    appendLog("检测到上次本地蓝牙旧配对/加密链路冲突未清理，已阻止相机操作")
    updateStatus(CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus, isBusy: false)
    return true
  }

  func acknowledgeSystemBluetoothPairingCleanupForFreshPairing() {
    CameraVendorSystemBluetoothPairingCleanupPolicy.clearCleanupRequired()
    appendLog("用户确认已删除本地蓝牙配对，允许重新进入配对扫描")
  }

  /// Tear down any half-finished BLE/handshake state so a fresh "Connect"
  /// tap from the home screen can run again. Without this, after a failed
  /// or aborted connection (e.g. PTP / Wi-Fi gave up), `selectedPeripheral`
  /// or `autoReconnectTargetPeripheralID` stays set and
  /// `connectLastPairedCameraIfAvailable()` would short-circuit forever
  /// until the app is killed.
  func resetForNewConnectionAttempt(force: Bool = false) {
    if CameraVendorConnectionResetPolicy.shouldSkipPassiveResetDuringTransferHandoff(
      force: force,
      didCompleteHandshakeCallback: didCompleteHandshakeCallback,
      hasCompletedPairing: hasCompletedPairing,
      hasUserInitiatedTransfer: hasUserInitiatedTransfer,
      hasPendingHandshakeSummary: pendingHandshakeSummary != nil,
      isRunningTransferActivation: isRunningTransferActivation,
      awaitingBluetoothDisconnectForWifiHandoff: awaitingBluetoothDisconnectForWifiHandoff,
      awaitingTransferActivationStateChange: awaitingTransferActivationStateChange
    ) {
      appendLog("首页出现时检测到传图交接正在进行，跳过被动状态重置")
      return
    }

    appendLog("重置上一次连接的残留状态，准备再次尝试")
    scanTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem = nil
    central.stopScan()

    if let peripheral = selectedPeripheral {
      central.cancelPeripheralConnection(peripheral)
    }
    selectedPeripheral = nil
    selectedCamera = nil
    autoReconnectTargetPeripheralID = nil
    isRunningTransferActivation = false
    awaitingPairingReadyRediscovery = false
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil
    awaitingBluetoothDisconnectForWifiHandoff = false
    bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
    bluetoothDisconnectHandoffTimeoutWorkItem = nil
    isDelayingGalleryForBleStateSampling = false
    cancelBleStateSampling()
    isRunningPostHandshakeProbe = false
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
    pendingHandshakeSummary = nil
    pendingPostHandshakeProbeReads = []
    pendingTransferActivationStrategies = []
    pendingTransferActivationWrites = []
    currentTransferActivationStrategy = nil
    didCompletePairingCallback = false
    didCompleteHandshakeCallback = false
    hasCompletedPairing = false
    hasQueuedPhonePairingConfirmation = false
    hasUserInitiatedTransfer = false
    activeWirelessIntent = .idle
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    handshakeMode = .undetermined
  }

  func forgetLastPairedCamera() {
    pairingStore.clear()
    rememberedPairedCameras = []
    rememberedPairedCamera = nil
    autoReconnectTargetPeripheralID = nil
    shouldAutoReconnectRememberedCamera = false
    isNextRememberedCameraConnectionUserApproved = false
    hasQueuedPhonePairingConfirmation = false
    activeWirelessIntent = .idle
    appendLog("已删除本地保存的配对相机记录")
    updateStatus("已删除配对记录，请连接新设备", isBusy: false)
  }

  private func cancelLocalPairingForSystemBluetoothCleanup(peripheral: CBPeripheral? = nil) {
    let hadLocalPairing = rememberedPairedCamera != nil
      || !rememberedPairedCameras.isEmpty
      || !pairingStore.loadAll().isEmpty
    let activePeripheral = peripheral ?? selectedPeripheral

    pairingStore.clear()
    rememberedPairedCameras = []
    rememberedPairedCamera = nil
    selectedPeripheral = nil
    selectedCamera = nil
    autoReconnectTargetPeripheralID = nil
    shouldAutoReconnectRememberedCamera = false
    isNextRememberedCameraConnectionUserApproved = false
    hasQueuedPhonePairingConfirmation = false
    activeWirelessIntent = .idle
    awaitingPairingReadyRediscovery = false
    isRunningTransferActivation = false
    pendingTransferActivationWrites = []
    pendingTransferActivationStrategies = []
    currentTransferActivationStrategy = nil
    transferActivationTimeoutWorkItem?.cancel()
    postHandshakeProbeTimeoutWorkItem?.cancel()
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    if let activePeripheral {
      central.cancelPeripheralConnection(activePeripheral)
    }

    if hadLocalPairing {
      appendLog("已取消 App 本地配对记录，请删除 iPhone 设置里的相机蓝牙记录后重新配对")
    }
  }

  private func requireSystemBluetoothPairingCleanup(reason: String, peripheral: CBPeripheral?) {
    appendLog("检测到本地蓝牙旧配对/加密链路冲突: \(reason)")
    CameraVendorSystemBluetoothPairingCleanupPolicy.markCleanupRequired(reason: reason)
    cancelLocalPairingForSystemBluetoothCleanup(peripheral: peripheral)
    updateStatus(CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus, isBusy: false)
  }

  func forgetPairedCamera(peripheralID: UUID) {
    pairingStore.remove(peripheralID: peripheralID)
    rememberedPairedCameras = pairingStore.loadAll()
    if rememberedPairedCamera?.peripheralID == peripheralID {
      rememberedPairedCamera = rememberedPairedCameras.first
    }
    if autoReconnectTargetPeripheralID == peripheralID {
      autoReconnectTargetPeripheralID = nil
      shouldAutoReconnectRememberedCamera = false
    }
    isNextRememberedCameraConnectionUserApproved = false
    hasQueuedPhonePairingConfirmation = false
    activeWirelessIntent = .idle
    appendLog("已删除本地保存的配对相机记录: \(peripheralID.uuidString)")
    updateStatus(
      rememberedPairedCameras.isEmpty ? "已删除配对记录，请连接新设备" : "已删除配对记录",
      isBusy: false
    )
  }

  func confirmCameraPairingSucceeded() {
    let decision = IOSCameraPairingConfirmationFlowDriver.confirmPairingSucceeded(
      hasWrittenIdentifier: hasWrittenPairingIdentifier,
      hasPendingHandshakeSummary: pendingHandshakeSummary != nil
    )
    switch decision {
    case .completeImmediately:
      hasQueuedPhonePairingConfirmation = false
      completePhonePairingConfirmation()
      return
    case .waitForCameraAck:
      hasQueuedPhonePairingConfirmation = true
      appendLog("已记录手机确认，等待相机 ACK 后自动完成配对")
      updateStatus("已确认，等待相机返回结果", isBusy: false)
      return
    case .rejectUntilReady:
      appendLog("相机端尚未到可确认阶段，忽略本次配对完成确认")
      updateStatus("请先完成当前配对流程", isBusy: false)
      return
    }
  }

  @discardableResult
  private func completeQueuedPhonePairingConfirmationIfReady() -> Bool {
    guard IOSCameraPairingConfirmationFlowDriver.canCompleteQueuedPhoneConfirmation(
      hasWrittenIdentifier: hasWrittenPairingIdentifier,
      hasPendingHandshakeSummary: pendingHandshakeSummary != nil,
      hasQueuedPhoneConfirmation: hasQueuedPhonePairingConfirmation
    ) else {
      return false
    }

    hasQueuedPhonePairingConfirmation = false
    appendLog("相机 ACK 已就绪，自动完成之前的手机确认")
    completePhonePairingConfirmation()
    return didCompletePairingCallback
  }

  private func completePhonePairingConfirmation() {
    let route = IOSCameraPairingConfirmationFlowDriver.routeAfterPhoneConfirmation(
      hasWrittenIdentifier: hasWrittenPairingIdentifier,
      hasPendingHandshakeSummary: pendingHandshakeSummary != nil,
      shouldBypassManualConfirmation: shouldBypassManualPairingConfirmation()
    )
    switch route {
    case .reconnectBeforeCompletion:
      if beginPhoneConfirmationReconnectIfNeeded() {
        return
      }
    case .completePairing:
      break
    }

    notifyPairingCompletedIfPossible()
  }

  private func beginPhoneConfirmationReconnectIfNeeded() -> Bool {
    guard let peripheral = selectedPeripheral,
          let camera = selectedCamera,
          savePendingPairingRecordIfPossible() else {
      return false
    }

    appendLog("手机确认后自动重新连接相机，回写已配对识别号完成相机端确认")
    updateStatus("正在向相机确认配对结果", isBusy: true)
    prepareConnectionAttempt(peripheral: peripheral, camera: camera)
    appendLog("开始连接 \(camera.name) [\(camera.appVariant.rawValue)]")
    if peripheral.state == .connected {
      appendLog("相机 BLE 已连接，直接重新发现服务完成配对确认")
      peripheral.delegate = self
      peripheral.discoverServices(nil)
      return true
    }
    central.connect(peripheral, options: nil)
    return true
  }

  private func waitForPhonePairingConfirmation() {
    appendLog("手机端握手已完成，等待用户确认相机端已显示配对成功")
    updateStatus(CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus, isBusy: false)
  }

  private func handleIdentifierWriteCompletion(on peripheral: CBPeripheral) {
    refreshPendingHandshakeSummary(using: peripheral)
    if completeQueuedPhonePairingConfirmationIfReady() {
      return
    }

    let shouldBypassConfirmation = shouldBypassManualPairingConfirmation()
    let route = IOSCameraPairingConfirmationFlowDriver.routeAfterIdentifierWrite(
      intent: activeWirelessIntent,
      shouldBypassManualConfirmation: shouldBypassConfirmation
    )

    switch route {
    case .waitForPhoneConfirmation:
      waitForPhonePairingConfirmation()
    case .completeFreshPairing:
      if shouldBypassConfirmation {
        appendLog("识别为已配对重连，跳过人工确认")
      }
      notifyPairingCompletedIfPossible()
    case .beginRememberedGalleryMainline:
      appendLog("识别为已配对相机，直接进入 Android 对齐的相册主链路")
      beginRememberedGalleryTransferIfPossible(on: peripheral)
    case .failRememberedGalleryRequiresRepair:
      appendLog("已配对相机未通过重连确认，已阻止进入相册。请清除旧配对后重新配对。")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
    }
  }

  private func beginRememberedGalleryTransferIfPossible(on peripheral: CBPeripheral) {
    guard savePendingPairingRecordIfPossible() else {
      appendLog("已配对相机主链路缺少有效握手信息，无法继续进入相册")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
      return
    }

    hasUserInitiatedTransfer = true
    hasCompletedPairing = true
    hasQueuedPhonePairingConfirmation = false
    appendLog("已确认已配对相机身份，按用户进入相册请求继续执行 Android 主链路")
    appendObservation(
      "REMEMBERED_GALLERY_TRANSFER_START paired=\(hasCompletedPairing) handshakeDone=\(didCompleteHandshakeCallback) " +
      "peripheralState=\(selectedPeripheral.map { String(describing: $0.state) } ?? "nil") " +
      "knownCharacteristics=\(discoveredCharacteristicsByUUID.count)"
    )

    let startDecision = IOSCameraTransferFlowDriver.startTransfer(
      hasCompletedPairing: hasCompletedPairing,
      didCompleteHandshake: didCompleteHandshakeCallback,
      peripheralState: selectedPeripheral.map { $0.state == .connected ? .connected : .disconnected }
    )

    switch startDecision {
    case .blockedNotPaired:
      appendLog("已配对相机主链路未拿到可复用配对结果，无法进入相册")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
      return
    case .alreadyReady:
      appendLog("相机已满足进入相册条件，无需重复启动传图主链路")
      return
    case .missingPeripheral:
      appendLog("当前没有可用的相机连接，无法继续进入相册")
      updateStatus("相机连接已断开，请重新连接", isBusy: false)
      return
    case .disconnectedPeripheral:
      appendLog("当前相机 BLE 已断开，无法继续进入相册")
      updateStatus("相机连接已断开，请重新连接", isBusy: false)
      return
    case .beginPreparation:
      break
    }

    appendLog("已配对相机 BLE 重连完成，开始让相机进入 Wi‑Fi 传图模式")
    updateStatus(CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus, isBusy: true)
    beginPostHandshakeProbeIfNeeded(on: peripheral)
  }

  func startScan() {
    if publishSystemBluetoothCleanupBlockIfNeeded() {
      return
    }
    CameraVendorGalleryDiagnostics.externalLogHandler = nil
    discoveredPeripherals.removeAll()
    discoveredCameras.removeAll()
    selectedPeripheral = nil
    selectedCamera = nil
    pairingCharacteristic = nil
    connectedDeviceNameCharacteristic = nil
    connectedDeviceIdentificationCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    encryptionRecoveryPolicy.reset()
    awaitingPairingReadyRediscovery = false
    pendingHandshakeSummary = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    pendingTransferActivationStrategies = []
    pendingTransferActivationWrites = []
    currentTransferActivationStrategy = nil
    isRunningTransferActivation = false
    hasAttemptedAutomaticTransferActivation = false
    hadAutomaticTransferActivationFeature = false
    transferActivationObservedChange = false
    transferActivationObservedWifiLaunch = false
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil
    isDelayingGalleryForBleStateSampling = false
    cancelBleStateSampling()
    awaitingBluetoothDisconnectForWifiHandoff = false
    bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
    bluetoothDisconnectHandoffTimeoutWorkItem = nil
    didCompletePairingCallback = false
    didCompleteHandshakeCallback = false
    hasWrittenPairingIdentifier = false
    hasQueuedPhonePairingConfirmation = false
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
    activeWirelessIntent = .idle
    secureHandshakePhase = .idle
    secureHandshakeReconnectCount = 0
    secureIdentificationNumberAlreadyPaired = false
    autoReconnectTargetPeripheralID = nil
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
    notifyDevicesChanged()

    shouldScanWhenPoweredOn = true
    appendLog("准备搜索相机")

    guard central.state == .poweredOn else {
      updateStatus("等待蓝牙可用", isBusy: true)
      return
    }

    beginScan()
  }

  func connect(to cameraID: UUID) {
    if publishSystemBluetoothCleanupBlockIfNeeded() {
      return
    }
    activeWirelessIntent = .freshPairing
    CameraVendorGalleryDiagnostics.externalLogHandler = nil
    guard let peripheral = discoveredPeripherals[cameraID] else {
      appendLog("未找到对应的蓝牙外设")
      return
    }

    guard let camera = discoveredCameras.first(where: { $0.id == cameraID }) else {
      appendLog("未找到对应的相机信息")
      return
    }

    prepareConnectionAttempt(peripheral: peripheral, camera: camera)
    appendLog("开始连接 \(camera.name) [\(camera.appVariant.rawValue)]")
    updateStatus("连接相机中", isBusy: true)
    central.connect(peripheral, options: nil)
  }

  func startFreshPairingConnection(cameraID: UUID) {
    connect(to: cameraID)
  }

  func confirmPendingPairing() {
    confirmCameraPairingSucceeded()
  }

  func resetWirelessCameraFlow(force: Bool = true) {
    resetForNewConnectionAttempt(force: force)
  }

  private func beginScan() {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    resetScanAdvertisementDiagnostics()
    updateStatus("搜索中", isBusy: true)
    appendLog("运行构建标记: \(buildMarker)")
    appendLog("开始 BLE 扫描（不过滤服务，直接分析 CameraVendor 广播）")
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      if self.discoveredCameras.isEmpty {
        self.appendLog("扫描结束，没有发现 相机，未匹配广播样本数 \(self.unmatchedAdvertisementSampleCount)")
        self.updateStatus("未发现相机", isBusy: false)
      } else {
        self.appendLog(
          "扫描结束，发现 \(self.discoveredCameras.count) 台 CameraVendor 设备，" +
          "未匹配广播样本数 \(self.unmatchedAdvertisementSampleCount)"
        )
        self.updateStatus("请选择相机", isBusy: false)
      }
    }
    scanTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  private func beginPairingReadyRescan() {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    resetScanAdvertisementDiagnostics()
    updateStatus("等待相机切换到可配对广播", isBusy: true)
    appendLog("开始重新扫描，等待 ReferenceApp / Secure Pair / type=0x02 广播")
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      self.awaitingPairingReadyRediscovery = false
      self.appendLog("重新扫描超时，仍未等到可配对广播")
      self.updateStatus("等待可配对广播超时", isBusy: false)
    }
    scanTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
  }

  private func notifyDevicesChanged() {
    delegate?.cameraVendorBluetoothService(self, didUpdateDiscoveredCameras: discoveredCameras)
  }

  private func prepareConnectionAttempt(
    peripheral: CBPeripheral,
    camera: CameraVendorDiscoveredCamera
  ) {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    selectedPeripheral = peripheral
    selectedCamera = camera
    pairingCharacteristic = nil
    connectedDeviceNameCharacteristic = nil
    connectedDeviceIdentificationCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    encryptionRecoveryPolicy.reset()
    awaitingPairingReadyRediscovery = false
    pendingHandshakeSummary = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    pendingTransferActivationStrategies = []
    pendingTransferActivationWrites = []
    currentTransferActivationStrategy = nil
    isRunningTransferActivation = false
    hasAttemptedAutomaticTransferActivation = false
    hadAutomaticTransferActivationFeature = false
    transferActivationObservedChange = false
    transferActivationObservedWifiLaunch = false
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil
    isDelayingGalleryForBleStateSampling = false
    cancelBleStateSampling()
    awaitingBluetoothDisconnectForWifiHandoff = false
    bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
    bluetoothDisconnectHandoffTimeoutWorkItem = nil
    didCompletePairingCallback = false
    didCompleteHandshakeCallback = false
    hasWrittenPairingIdentifier = false
    hasQueuedPhonePairingConfirmation = false
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
    secureHandshakePhase = .idle
    secureHandshakeReconnectCount = 0
    secureIdentificationNumberAlreadyPaired = false
    autoReconnectTargetPeripheralID = nil
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
  }

  private func attemptAutoReconnect(using record: CameraVendorPairedCameraRecord) {
    rememberedPairedCamera = record
    autoReconnectTargetPeripheralID = record.peripheralID
    shouldAutoReconnectRememberedCamera = false

    if CameraVendorRememberedReconnectPolicy.shouldTrySystemRetrievedPeripheralBeforeScanning {
      let peripherals = central.retrievePeripherals(withIdentifiers: [record.peripheralID])
      if let peripheral = peripherals.first {
        let camera = CameraVendorDiscoveredCamera(
          id: peripheral.identifier,
          name: record.deviceName,
          rssi: 0,
          appVariant: record.appVariant,
          pairingToken: nil,
          matchDetails: "remembered-system-retrieve"
        )
        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredCameras = [camera]
        notifyDevicesChanged()
        appendLog("系统已取回上次配对的相机外设，直接发起连接: \(record.deviceName) [\(record.peripheralID.uuidString)]")
        prepareConnectionAttempt(peripheral: peripheral, camera: camera)
        updateStatus("连接上次配对的相机", isBusy: true)
        central.connect(peripheral, options: nil)
        return
      }
      appendLog("系统未取回上次配对外设，改为扫描广播: \(record.peripheralID.uuidString)")
    }

    appendLog("开始扫描上次配对相机，等待广播后连接")
    beginAutoReconnectScan(for: record)
  }

  private func beginAutoReconnectScan(for record: CameraVendorPairedCameraRecord) {
    discoveredPeripherals.removeAll()
    discoveredCameras.removeAll()
    notifyDevicesChanged()

    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    resetScanAdvertisementDiagnostics()
    updateStatus("搜索上次配对的相机", isBusy: true)
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      self.autoReconnectTargetPeripheralID = nil
      guard CameraVendorRememberedReconnectPolicy.shouldStartNormalDiscoveryAfterTargetTimeout else {
        self.appendLog("未找到上次配对的相机，等待手动搜索")
        self.updateStatus("未找到上次配对的相机", isBusy: false)
        return
      }
      self.appendLog("未找到上次配对的相机，切换为普通自动搜索")
      self.beginScan()
    }
    scanTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  private func resetScanAdvertisementDiagnostics() {
    unmatchedAdvertisementSampleKeys.removeAll()
    unmatchedAdvertisementSampleCount = 0
  }

  private func shouldSkipManualPairingConfirmationForCurrentCamera() -> Bool {
    CameraVendorRememberedPairingPolicy.shouldSkipManualPairingConfirmation(
      rememberedPeripheralID: rememberedPairedCamera?.peripheralID,
      selectedPeripheralID: selectedPeripheral?.identifier
    )
  }

  private func shouldBypassManualPairingConfirmation() -> Bool {
    CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
      isRememberedPeripheral: shouldSkipManualPairingConfirmationForCurrentCamera(),
      isAlreadyPairedIdentificationNumber: secureIdentificationNumberAlreadyPaired
    )
  }

  private func resetHandshakeStateForReconnect() {
    pairingCharacteristic = nil
    connectedDeviceNameCharacteristic = nil
    connectedDeviceIdentificationCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    pendingHandshakeSummary = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    pendingTransferActivationStrategies = []
    pendingTransferActivationWrites = []
    currentTransferActivationStrategy = nil
    isRunningTransferActivation = false
    hasAttemptedAutomaticTransferActivation = false
    hadAutomaticTransferActivationFeature = false
    transferActivationObservedChange = false
    transferActivationObservedWifiLaunch = false
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil
    isDelayingGalleryForBleStateSampling = false
    cancelBleStateSampling()
    awaitingBluetoothDisconnectForWifiHandoff = false
    bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
    bluetoothDisconnectHandoffTimeoutWorkItem = nil
    didCompletePairingCallback = false
    didCompleteHandshakeCallback = false
    hasWrittenPairingIdentifier = false
    hasQueuedPhonePairingConfirmation = false
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
    secureHandshakePhase = .idle
    secureIdentificationNumberAlreadyPaired = false
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
  }

  private func makeCoreRememberedRecord(
    from record: CameraVendorPairedCameraRecord
  ) -> IOSCameraRememberedCameraRecord {
    IOSCameraRememberedCameraRecord(
      peripheralID: record.peripheralID,
      identity: IOSCameraIdentity(
        cameraID: cameraID(from: record),
        displayName: record.deviceName,
        serialNumber: record.serialNumber,
        bleEndpoint: IOSCameraBleEndpoint(
          identifier: record.peripheralID.uuidString.uppercased(),
          address: nil
        )
      ),
      wifiCredential: IOSCameraWifiCredential.official(
        ssid: record.preferredWifiNetwork?.ssid,
        passphrase: record.preferredWifiNetwork?.passphrase,
        bssid: record.preferredWifiNetwork?.bssid,
        source: .bleHandshake
      ),
      connectedDeviceName: record.connectedDeviceName,
      systemBluetoothPairingValidatedAt: record.systemBluetoothPairingValidatedAt
    )
  }

  private func cameraID(from record: CameraVendorPairedCameraRecord) -> String {
    let serial = normalizedIdentity(record.serialNumber)
    let name = normalizedIdentity(record.deviceName)
    if !serial.isEmpty, !name.isEmpty {
      return "\(serial)_\(name)"
    }
    return [
      serial,
      name,
      record.peripheralID.uuidString.uppercased(),
      normalizedIdentity(record.preferredWifiNetwork?.ssid),
    ].first(where: { !$0.isEmpty }) ?? ""
  }

  private func normalizedIdentity(_ value: String?) -> String {
    value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func reconnectAfterSecureHandshakeDisconnect(_ peripheral: CBPeripheral) {
    secureHandshakeReconnectCount += 1
    appendLog("ReferenceApp 配对在识别号写入阶段被中断，准备自动重连一次")
    updateStatus("安全配对中断，正在重连", isBusy: true)
    resetHandshakeStateForReconnect()

    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self else { return }
      guard self.selectedPeripheral?.identifier == peripheral.identifier else {
        return
      }
      self.appendLog("重新连接相机，继续 ReferenceApp 配对")
      self.central.connect(peripheral, options: nil)
    }
  }

  private func updateStatus(_ status: String, isBusy: Bool) {
    delegate?.cameraVendorBluetoothService(self, didUpdateStatus: status, isBusy: isBusy)
  }

  private static let debugLogURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("camtransfer_debug.log")
  }()

  private func appendLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let safeMessage = CamTransferDiagnosticLogRedactor.redacted(message)
    let line = "[\(formatter.string(from: Date()))] \(safeMessage)"
    NSLog("%@", line)
    let shouldWriteToDisk = CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(safeMessage)
    if shouldWriteToDisk {
      CameraVendorFileLogger.log(safeMessage)
    }
    logStore.append(line, writesToDisk: shouldWriteToDisk)
    delegate?.cameraVendorBluetoothService(self, didAppendLog: line)
  }

  private func appendObservation(_ message: String) {
    appendLog("[OBS] \(message)")
  }

  private func maybeStartPairing(on peripheral: CBPeripheral) {
    let canStartHandshake: Bool
    switch handshakeMode {
    case .secure:
      canStartHandshake = handshakeCoordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: connectedDeviceNameCharacteristic != nil,
        hasConnectedDeviceIdentificationCharacteristic: connectedDeviceIdentificationCharacteristic != nil
      )
    case .legacy, .undetermined:
      canStartHandshake = handshakeCoordinator.canStartHandshake(
        hasIdentifierCharacteristic: connectedDeviceNameCharacteristic != nil
      )
    }

    if canStartHandshake {
      handshakeCoordinator.markHandshakeStarted()
      lastHandshakeWaitReason = nil
      startPairingIfReady(on: peripheral)
      return
    }

    guard !handshakeCoordinator.didStartHandshake else {
      return
    }

    let waitReason: String
    if handshakeMode == .secure && connectedDeviceIdentificationCharacteristic == nil {
      waitReason = "等待已连接设备识别号特征"
    } else if handshakeMode == .secure && connectedDeviceNameCharacteristic == nil {
      waitReason = "等待已连接设备名称特征"
    } else if connectedDeviceNameCharacteristic == nil {
      waitReason = "等待已连接设备名称特征"
    } else if !handshakeCoordinator.pendingCharacteristicServices.isEmpty {
      let services = handshakeCoordinator.pendingCharacteristicServices.sorted().joined(separator: ", ")
      waitReason = "等待服务特征发现完成: \(services)"
    } else if !handshakeCoordinator.pendingMetadataCharacteristics.isEmpty {
      let metadata = handshakeCoordinator.pendingMetadataCharacteristics.sorted().joined(separator: ", ")
      waitReason = "等待基础信息读取完成: \(metadata)"
    } else if !handshakeCoordinator.pendingNotificationSubscriptions.isEmpty {
      let notifications = handshakeCoordinator.pendingNotificationSubscriptions.sorted().joined(separator: ", ")
      waitReason = "等待通知订阅完成: \(notifications)"
    } else {
      waitReason = "等待握手前置条件"
    }

    if lastHandshakeWaitReason != waitReason {
      lastHandshakeWaitReason = waitReason
      appendLog(waitReason)
    }
  }

  private func startPairingIfReady(on peripheral: CBPeripheral) {
    updateStatus("配对中", isBusy: true)

    switch handshakeMode {
    case .secure:
      guard let connectedDeviceNameCharacteristic else {
        appendLog("缺少已连接设备名称特征")
        updateStatus("握手失败", isBusy: false)
        return
      }

      let deviceName = connectedDeviceNameToWrite
      secureHandshakePhase = .awaitingDeviceNameWrite
      appendLog("按 ReferenceApp 顺序先写入已连接设备名称: \(deviceName)")
      let payload = CameraVendorSecureHandshakeCodec.identifierPayload(deviceName)
      peripheral.writeValue(payload, for: connectedDeviceNameCharacteristic, type: .withResponse)
    case .legacy, .undetermined:
      guard let connectedDeviceNameCharacteristic,
            let camera = selectedCamera else {
        return
      }

      if let pairingCharacteristic, let token = camera.pairingToken {
        let payload = CameraVendorSecureHandshakeCodec.pairingPayload(token)
        appendLog("写入配对 token: \(hexString(payload))")
        peripheral.writeValue(payload, for: pairingCharacteristic, type: .withResponse)
        return
      }

      let deviceName = connectedDeviceNameToWrite
      appendLog("未拿到配对 token，直接尝试写入已连接设备名称: \(deviceName)")
      let payload = CameraVendorSecureHandshakeCodec.identifierPayload(deviceName)
      peripheral.writeValue(payload, for: connectedDeviceNameCharacteristic, type: .withResponse)
    }
  }

  private func upsertCamera(
    peripheral: CBPeripheral,
    match: CameraVendorAdvertisementMatch,
    rssi: Int
  ) -> CameraVendorDiscoveredCamera {
    let camera = CameraVendorDiscoveredCamera(
      id: peripheral.identifier,
      name: match.resolvedName,
      rssi: rssi,
      appVariant: match.appVariant,
      pairingToken: match.pairingToken,
      matchDetails: match.reasons.joined(separator: ", ")
    )

    if let index = discoveredCameras.firstIndex(where: { $0.id == camera.id }) {
      discoveredCameras[index] = camera
    } else {
      discoveredCameras.append(camera)
    }

    discoveredCameras.sort { $0.rssi > $1.rssi }
    return camera
  }

  private func hexString(_ data: Data?) -> String {
    guard let data, !data.isEmpty else {
      return "-"
    }
    return data.map { String(format: "%02X", $0) }.joined()
  }

  private func propertyFlags(_ characteristic: CBCharacteristic) -> String {
    var flags: [String] = []
    let properties = characteristic.properties

    if properties.contains(.read) { flags.append("read") }
    if properties.contains(.write) { flags.append("write") }
    if properties.contains(.writeWithoutResponse) { flags.append("writeNoRsp") }
    if properties.contains(.notify) { flags.append("notify") }
    if properties.contains(.indicate) { flags.append("indicate") }
    if properties.contains(.authenticatedSignedWrites) { flags.append("signedWrite") }
    if properties.contains(.extendedProperties) { flags.append("extended") }
    if properties.contains(.notifyEncryptionRequired) { flags.append("notifyEnc") }
    if properties.contains(.indicateEncryptionRequired) { flags.append("indicateEnc") }

    return flags.isEmpty ? "-" : flags.joined(separator: ",")
  }

  private func isHandshakeMetadataCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
    characteristic.uuid == serialNumberCharacteristicUUID
      || characteristic.uuid == deviceNameCharacteristicUUID
      || characteristic.uuid == firmwareRevisionCharacteristicUUID
      || characteristic.uuid == cameraYNumberCharacteristicUUID
      || characteristic.uuid == cameraMacAddressCharacteristicUUID
      || characteristic.uuid == cameraSerialCharacteristicUUID
      || characteristic.uuid == cameraSSIDCharacteristicUUID
      || characteristic.uuid == cameraWifiPassphraseCharacteristicUUID
  }

  private func shouldProbeAfterHandshake(_ characteristic: CBCharacteristic) -> Bool {
    guard characteristic.properties.contains(.read) else {
      return false
    }

    let serviceUUID = characteristic.service?.uuid.uuidString.uppercased() ?? ""
    if serviceUUID == deviceNameServiceUUID.uuidString.uppercased()
      || serviceUUID == deviceInformationServiceUUID.uuidString.uppercased()
      || serviceUUID == pairServiceUUID.uuidString.uppercased()
      || serviceUUID == securePairServiceUUID.uuidString.uppercased() {
      return false
    }

    return true
  }

  private func beginPostHandshakeProbeIfNeeded(on _: CBPeripheral) {
    guard !didCompleteHandshakeCallback else {
      return
    }

    appendLog("按 ReferenceApp 正式流程跳过握手后诊断探测，直接触发传图模式")
    pendingPostHandshakeProbeReads.removeAll()
    isRunningPostHandshakeProbe = false
    finishHandshakeIfPossible()
  }

  private func notifyPairingCompletedIfPossible() {
    guard !didCompletePairingCallback,
          let summary = pendingHandshakeSummary else {
      return
    }

    savePendingPairingRecordIfPossible()

    didCompletePairingCallback = true
    hasCompletedPairing = true
    hasQueuedPhonePairingConfirmation = false
    appendLog("用户已在手机端确认相机显示配对成功，进入传输准备页")
    updateStatus("配对完成", isBusy: false)
    delegate?.cameraVendorBluetoothService(self, didCompletePairing: summary)
  }

  @discardableResult
  private func savePendingPairingRecordIfPossible() -> Bool {
    guard let summary = pendingHandshakeSummary,
          let peripheralID = selectedPeripheral?.identifier else {
      return false
    }

    let record = CameraVendorPairedCameraRecord(
      peripheralID: peripheralID,
      deviceName: summary.deviceName,
      serialNumber: summary.serialNumber,
      connectedDeviceName: summary.connectedDeviceName,
      appVariant: selectedCamera?.appVariant ?? rememberedPairedCamera?.appVariant ?? .unknown,
      preferredWifiNetwork: summary.preferredWifiNetwork,
      systemBluetoothPairingValidatedAt: Date()
    )
    pairingStore.save(record)
    CameraVendorSystemBluetoothPairingCleanupPolicy.clearCleanupRequired()
    rememberedPairedCameras = pairingStore.loadAll()
    rememberedPairedCamera = record
    appendLog("已保存配对相机: \(summary.deviceName) [\(peripheralID.uuidString)]")
    return true
  }

  private func finishHandshakeIfPossible() {
    let availableTransferStrategies = selectedPeripheral != nil
      ? CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
        forAvailableCharacteristicUUIDStrings: Set(
          discoveredCharacteristicsByUUID.keys.map { $0.uuidString.uppercased() }
        )
      ).map { IOSCameraTransferActivationStrategy(rawValue: $0.rawValue) }
      : []
    let handshakeAction = IOSCameraTransferFlowDriver.handshakeCompletionAction(
      context: IOSCameraHandshakeCompletionContext(
        didCompleteHandshake: didCompleteHandshakeCallback,
        isRunningPostHandshakeProbe: isRunningPostHandshakeProbe,
        isRunningTransferActivation: isRunningTransferActivation,
        hasCompletedPairing: hasCompletedPairing,
        hasUserInitiatedTransfer: hasUserInitiatedTransfer,
        hasPendingHandshakeSummary: pendingHandshakeSummary != nil,
        hasAttemptedAutomaticTransferActivation: hasAttemptedAutomaticTransferActivation,
        transferActivationObservedChange: transferActivationObservedChange,
        transferActivationObservedWifiLaunch: transferActivationObservedWifiLaunch,
        hadAutomaticTransferActivationFeature: hadAutomaticTransferActivationFeature,
        availableCharacteristicUUIDStrings: Set(
          discoveredCharacteristicsByUUID.keys.map { $0.uuidString.uppercased() }
        ),
        availableTransferStrategies: availableTransferStrategies,
        hasSelectedPeripheral: selectedPeripheral != nil
      )
    )
    guard let summary = pendingHandshakeSummary else {
      appendLog("finishHandshake guard 未通过: callback=\(didCompleteHandshakeCallback) probe=\(isRunningPostHandshakeProbe) paired=\(hasCompletedPairing) transfer=\(hasUserInitiatedTransfer) summary=\(pendingHandshakeSummary != nil)")
      return
    }

    switch handshakeAction {
    case .wait:
      appendLog("finishHandshake guard 未通过: callback=\(didCompleteHandshakeCallback) probe=\(isRunningPostHandshakeProbe) paired=\(hasCompletedPairing) transfer=\(hasUserInitiatedTransfer) summary=\(pendingHandshakeSummary != nil)")
      return
    case .beginTransferActivation(let strategies, let availableCharacteristicUUIDStrings):
      hasAttemptedAutomaticTransferActivation = true
      pendingTransferActivationStrategies = strategies.compactMap {
        CameraVendorReferenceAppTransferActivationStrategy(rawValue: $0.rawValue)
      }
      hadAutomaticTransferActivationFeature = !strategies.isEmpty

      if let peripheral = selectedPeripheral {
        appendObservation(
          "ACTIVATION_PLAN strategies=\(strategies.map(\.rawValue).joined(separator: ",")) " +
          "availableCharacteristics=\(availableCharacteristicUUIDStrings.joined(separator: ","))"
        )
        beginNextTransferActivationAttempt(on: peripheral)
        return
      }
      appendObservation("ACTIVATION_PLAN empty availableCharacteristics=\(availableCharacteristicUUIDStrings.joined(separator: ","))")
      appendLog("未发现 ReferenceApp 传图命令特征，停止传图激活流程")
      updateStatus("相机未提供传图启动特征，请重新连接后重试", isBusy: false)
      return
    case .failMissingActivationFeature(let availableCharacteristicUUIDStrings):
      appendObservation("ACTIVATION_PLAN empty availableCharacteristics=\(availableCharacteristicUUIDStrings.joined(separator: ","))")
      appendLog("未发现 ReferenceApp 传图命令特征，停止传图激活流程")
      updateStatus("相机未提供传图启动特征，请重新连接后重试", isBusy: false)
      return
    case .failActivationNotReady:
      appendObservation(
        "HANDSHAKE_BLOCKED activationAttempted=\(hasAttemptedAutomaticTransferActivation) " +
        "observedChange=\(transferActivationObservedChange) observedWifiLaunch=\(transferActivationObservedWifiLaunch) " +
        "hadFeature=\(hadAutomaticTransferActivationFeature)"
      )
      appendLog("传图激活未进入可连接状态，阻止进入图库")
      updateStatus("相机未进入传图模式，请重新连接后重试", isBusy: false)
      return
    case .complete(.gallery):
      completeHandshake(summary: summary, reason: "gallery")
      return
    }
  }

  private func completeHandshake(summary: CameraVendorConnectionSummary, reason: String) {
    if let rememberedPairedCamera,
       !CameraVendorStoredPairingPolicy.matchesRememberedIdentity(
        record: rememberedPairedCamera,
        summary: summary,
        peripheralID: selectedPeripheral?.identifier
       ) {
      appendObservation(
        "HANDSHAKE_BLOCKED_IDENTITY_MISMATCH " +
        "rememberedDevice=\(rememberedPairedCamera.deviceName) rememberedSerial=\(rememberedPairedCamera.serialNumber) " +
        "connectedDevice=\(summary.deviceName) connectedSerial=\(summary.serialNumber)"
      )
      appendLog("已配对记录和本次连接相机身份不一致，已阻止进入图库。请清除旧配对后重新配对。")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
      return
    }

    let verifiedSummary = CameraVendorConnectionSummary(
      deviceName: summary.deviceName,
      serialNumber: summary.serialNumber,
      connectedDeviceName: summary.connectedDeviceName,
      preferredWifiNetwork: summary.preferredWifiNetwork,
      preferCompressedDownloads: summary.preferCompressedDownloads,
      verifiedConnectionSteps: CameraVendorIOSOfficialConnectionEvidencePolicy.verifiedStepsBeforeWifiJoin(
        hasBleReconnect: selectedPeripheral != nil,
        hasTransferAuthorization: summary.preferredWifiNetwork != nil,
        hasActivationCommand: hasAttemptedAutomaticTransferActivation && hadAutomaticTransferActivationFeature,
        hasCameraWifiReady: transferActivationObservedChange
      )
    )

    didCompleteHandshakeCallback = true
    pendingHandshakeSummary = nil
    CameraVendorGalleryDiagnostics.externalLogHandler = { [weak self] message in
      self?.appendLog("图库: \(message)")
    }
    appendLog(
      "握手完成，设备名称 \(verifiedSummary.deviceName), " +
      "序列号 \(verifiedSummary.serialNumber)"
    )
    appendObservation(
      "HANDSHAKE_COMPLETE device=\(verifiedSummary.deviceName) serial=\(verifiedSummary.serialNumber) " +
      "connectedName=\(verifiedSummary.connectedDeviceName) wifi=\(verifiedSummary.preferredWifiNetwork?.ssid ?? "nil") " +
      "reason=\(reason) " +
      "observedChange=\(transferActivationObservedChange) observedWifiLaunch=\(transferActivationObservedWifiLaunch) " +
      "verifiedSteps=\(verifiedSummary.verifiedConnectionSteps.map(\.androidDisplayName).joined(separator: "->"))"
    )

    if CameraVendorHandshakeCompletionPolicy.shouldDisconnectBluetoothBeforeGallery(
      transferActivationObservedChange: transferActivationObservedChange
    ),
       let peripheral = selectedPeripheral,
       peripheral.state == .connected {
      appendLog("握手完成，主动断开 BLE 以释放相机 PTP 通道")
      central.cancelPeripheralConnection(peripheral)
      // Give the camera a moment to release the BLE connection
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        guard let self else { return }
        self.appendLog("BLE 已断开，通知 UI 进入图库")
        self.updateStatus("握手完成", isBusy: false)
        self.delegate?.cameraVendorBluetoothService(self, didCompleteHandshake: verifiedSummary)
      }
    } else {
      appendLog("握手完成，按 ReferenceApp 不再二次断开 BLE，直接通知 UI 进入图库")
      updateStatus("握手完成", isBusy: false)
      delegate?.cameraVendorBluetoothService(self, didCompleteHandshake: verifiedSummary)
    }
  }

  private func refreshPendingHandshakeSummary(using peripheral: CBPeripheral) {
    let preferredWifiNetwork = CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(
      from: observedCharacteristicValues
    )
    pendingHandshakeSummary = CameraVendorConnectionSummary(
      deviceName: discoveredName ?? selectedCamera?.name ?? peripheral.name ?? "CAMERA_VENDOR",
      serialNumber: discoveredSerialNumber ?? "-",
      connectedDeviceName: connectedDeviceNameToWrite,
      preferredWifiNetwork: preferredWifiNetwork,
      preferCompressedDownloads: CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
    )

    if let preferredWifiNetwork,
       preferredWifiNetwork != lastLoggedWifiConfiguration {
      lastLoggedWifiConfiguration = preferredWifiNetwork
      appendLog("已收到相机 Wi-Fi 配置")
      appendLog("SSID: \(preferredWifiNetwork.ssid)")
      appendLog("密码: \(preferredWifiNetwork.passphrase)")
      if preferredWifiNetwork.isHidden {
        appendLog("这是隐藏网络；如果列表里看不到，请在 Wi‑Fi 的“其他...”里手动输入。")
      }
    }
  }

  private func maybeFinishHandshakeAfterReceivingWifiConfiguration() {
    guard isRunningPostHandshakeProbe,
          CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(from: observedCharacteristicValues) != nil
    else {
      return
    }

    // Don't cut the probe short — let remaining BLE reads complete so they don't
    // get misinterpreted as activation state changes and congest the BLE stack.
    if pendingPostHandshakeProbeReads.isEmpty {
      appendLog("探测已全部完成，进入握手完成流程")
      postHandshakeProbeTimeoutWorkItem?.cancel()
      isRunningPostHandshakeProbe = false
      finishHandshakeIfPossible()
    } else {
      appendLog("等待剩余 \(pendingPostHandshakeProbeReads.count) 个探测读取完成后再开始传图激活")
    }
  }

  private func beginNextTransferActivationAttempt(on peripheral: CBPeripheral) {
    guard !isRunningTransferActivation else {
      return
    }

    guard !pendingTransferActivationStrategies.isEmpty else {
      finishHandshakeIfPossible()
      return
    }

    let strategy = pendingTransferActivationStrategies.removeFirst()
    currentTransferActivationStrategy = strategy
    pendingTransferActivationWrites = CameraVendorReferenceAppTransferActivationPlan.writes(for: strategy)
    transferActivationWritePayloadsByUUID.removeAll()
    isRunningTransferActivation = true
    transferActivationObservedChange = false
    transferActivationCameraResponded = false
    isDelayingGalleryForBleStateSampling = false
    cancelBleStateSampling()
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil

    appendLog("尝试触发相机进入传图模式: \(strategy.rawValue)")
    appendObservation(
      "ACTIVATION_START strategy=\(strategy.rawValue) " +
      "writes=\(pendingTransferActivationWrites.map { "\($0.characteristicUUIDString)=\(hexString($0.payload))" }.joined(separator: ","))"
    )
    writeNextTransferActivationStep(on: peripheral)
  }

  private func writeNextTransferActivationStep(on peripheral: CBPeripheral) {
    guard isRunningTransferActivation else {
      return
    }

    guard !pendingTransferActivationWrites.isEmpty else {
      appendLog("传图命令已写入，读取状态特征等待相机切换")

      let trackedStatusUUIDStrings = currentTransferActivationStrategy.map {
        CameraVendorReferenceAppTransferActivationPlan.trackedStatusCharacteristicUUIDStrings(for: $0)
      } ?? []

      for uuidString in trackedStatusUUIDStrings {
        let uuid = CBUUID(string: uuidString)
        guard let characteristic = discoveredCharacteristicsByUUID[uuid],
              characteristic.properties.contains(.read) else {
          continue
        }
        peripheral.readValue(for: characteristic)
      }

      scheduleBleStateSampling(on: peripheral)

      if let strategy = currentTransferActivationStrategy,
         CameraVendorTransferActivationCompletionPolicy.shouldFastHandoffAfterCommandWrites(for: strategy) {
        appendObservation("ACTIVATION_FAST_HANDOFF_AFTER_WRITES strategy=\(strategy.rawValue)")
        appendLog("传图命令已写入，跳过 BLE ready 等待，直接切换到 Wi‑Fi/PTP 流程")
        transferActivationObservedChange = true
        transferActivationObservedWifiLaunch = true
        completeCurrentTransferActivationAttempt(on: peripheral, source: "fast-handoff-after-writes")
        return
      }

      guard !transferActivationCameraResponded else {
        appendLog("相机已响应过状态变化，保留现有 15 秒超时")
        return
      }
      transferActivationTimeoutWorkItem?.cancel()
      transferActivationTimeoutSetAt = CFAbsoluteTimeGetCurrent()
      appendLog("[DIAG] 设置 8 秒超时 at \(String(format: "%.3f", transferActivationTimeoutSetAt))")
      let timeout = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - self.transferActivationTimeoutSetAt
        self.appendLog("[DIAG] 超时 DispatchWorkItem 触发, elapsed=\(String(format: "%.3f", elapsed))s")
        self.completeCurrentTransferActivationAttempt(on: peripheral, source: "12s-timeout")
      }
      transferActivationTimeoutWorkItem = timeout
      // Camera needs time to start WiFi AP after receiving activation command.
      // 2s was too short — DEVICE-A typically needs 5-10s to launch the AP.
      DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
      return
    }

    let request = pendingTransferActivationWrites.removeFirst()
    let uuid = CBUUID(string: request.characteristicUUIDString)
    guard let characteristic = discoveredCharacteristicsByUUID[uuid] else {
      appendLog("缺少传图命令特征 \(request.characteristicUUIDString)")
      isRunningTransferActivation = false
      beginNextTransferActivationAttempt(on: peripheral)
      return
    }

    appendLog("写入传图命令 \(request.characteristicUUIDString): \(hexString(request.payload))")
    appendObservation("BLE_WRITE_REQUEST uuid=\(request.characteristicUUIDString) payload=\(hexString(request.payload))")
    transferActivationWritePayloadsByUUID[request.characteristicUUIDString.uppercased()] = request.payload
    peripheral.writeValue(request.payload, for: characteristic, type: .withResponse)
  }

  private func scheduleBleStateSampling(on peripheral: CBPeripheral) {
    cancelBleStateSampling()
    guard !CameraVendorBleStateSamplingPlan.sampleDelaysSeconds.isEmpty else {
      return
    }
    appendObservation(
      "BLE_STATE_SAMPLING_START delays=\(CameraVendorBleStateSamplingPlan.sampleDelaysSeconds.map { String(format: "%.0f", $0) }.joined(separator: ","))"
    )

    for delay in CameraVendorBleStateSamplingPlan.sampleDelaysSeconds {
      let workItem = DispatchWorkItem { [weak self, weak peripheral] in
        guard let self, let peripheral else { return }
        self.sampleBleState(on: peripheral, delay: delay)
      }
      bleStateSamplingWorkItems.append(workItem)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }

  private func cancelBleStateSampling() {
    bleStateSamplingWorkItems.forEach { $0.cancel() }
    bleStateSamplingWorkItems.removeAll()
    bleStateSamplingCompletionWorkItem?.cancel()
    bleStateSamplingCompletionWorkItem = nil
    reservedImageReceiveProbeWorkItems.forEach { $0.cancel() }
    reservedImageReceiveProbeWorkItems.removeAll()
    hasScheduledReservedImageReceiveProbe = false
    isDelayingGalleryForBleStateSampling = false
  }

  private func scheduleReservedImageReceiveProbeIfNeeded(on peripheral: CBPeripheral) {
    guard !CameraVendorReservedImageReceiveStateProbePlan.writeRequests.isEmpty else {
      return
    }
    guard !hasScheduledReservedImageReceiveProbe else {
      return
    }
    hasScheduledReservedImageReceiveProbe = true

    for (index, request) in CameraVendorReservedImageReceiveStateProbePlan.writeRequests.enumerated() {
      let delay = TimeInterval(index) * CameraVendorReservedImageReceiveStateProbePlan.stagedWriteDelaySeconds
      let workItem = DispatchWorkItem { [weak self, weak peripheral] in
        guard let self, let peripheral else { return }
        self.writeReservedImageReceiveProbe(request, on: peripheral, stage: index + 1)
      }
      reservedImageReceiveProbeWorkItems.append(workItem)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
  }

  private func writeReservedImageReceiveProbe(
    _ request: CameraVendorBleWriteRequest,
    on peripheral: CBPeripheral,
    stage: Int
  ) {
    guard peripheral.state == .connected else {
      appendObservation("RESERVED_IMAGE_RECEIVE_PROBE stage=\(stage) skipped=peripheral-\(peripheral.state.rawValue)")
      return
    }

    let uuid = CBUUID(string: request.characteristicUUIDString)
    guard let characteristic = discoveredCharacteristicsByUUID[uuid] else {
      appendObservation("RESERVED_IMAGE_RECEIVE_PROBE stage=\(stage) skipped=missing uuid=\(request.characteristicUUIDString)")
      return
    }

    appendObservation(
      "RESERVED_IMAGE_RECEIVE_PROBE stage=\(stage) uuid=\(request.characteristicUUIDString) payload=\(hexString(request.payload))"
    )
    peripheral.writeValue(request.payload, for: characteristic, type: .withResponse)
  }

  private func sampleBleState(on peripheral: CBPeripheral, delay: TimeInterval) {
    guard peripheral.state == .connected else {
      appendObservation("BLE_STATE_SAMPLE delay=\(String(format: "%.0f", delay)) skipped=peripheral-\(peripheral.state.rawValue)")
      return
    }

    for uuidString in CameraVendorBleStateSamplingPlan.characteristicUUIDStrings {
      let uuid = CBUUID(string: uuidString)
      guard let characteristic = discoveredCharacteristicsByUUID[uuid],
            characteristic.properties.contains(.read) else {
        appendObservation("BLE_STATE_SAMPLE delay=\(String(format: "%.0f", delay)) uuid=\(uuidString) skipped=unreadable-or-missing")
        continue
      }
      appendObservation("BLE_STATE_SAMPLE delay=\(String(format: "%.0f", delay)) uuid=\(uuidString) read")
      peripheral.readValue(for: characteristic)
    }
  }

  private func completeCurrentTransferActivationAttempt(on peripheral: CBPeripheral, source: String = "unknown") {
    let elapsed = CFAbsoluteTimeGetCurrent() - transferActivationTimeoutSetAt
    appendLog("[DIAG] completeCurrentTransferActivationAttempt source=\(source), elapsed=\(String(format: "%.3f", elapsed))s, isRunning=\(isRunningTransferActivation)")
    guard isRunningTransferActivation else {
      return
    }
    transferActivationTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem = nil

    let strategy = currentTransferActivationStrategy
    let strategyName = strategy?.rawValue ?? "Unknown"
    currentTransferActivationStrategy = nil
    pendingTransferActivationWrites = []
    isRunningTransferActivation = false

    if transferActivationObservedChange {
      if let strategy,
         CameraVendorTransferActivationCompletionPolicy.shouldWaitForBluetoothDisconnect(
           afterObservedChangeFor: strategy
         ) {
        appendObservation("ACTIVATION_COMPLETE source=\(source) result=waitBluetoothDisconnect strategy=\(strategyName)")
        appendLog("传图模式 \(strategyName) 已观察到状态变化，等待相机断开 BLE 后再连接 Wi‑Fi")
        awaitingBluetoothDisconnectForWifiHandoff = true
        updateStatus("等待相机切换 Wi‑Fi", isBusy: true)

        // For strategies where the camera won't disconnect BLE on its own,
        // actively disconnect from the app side so PTP/IP can proceed.
        if CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(for: strategy),
           let peripheral = selectedPeripheral {
          appendLog("主动断开 BLE 连接以释放相机 PTP 通道 (策略: \(strategyName))")
          central.cancelPeripheralConnection(peripheral)
        }

        let timeout = DispatchWorkItem { [weak self] in
          guard let self else { return }
          guard self.awaitingBluetoothDisconnectForWifiHandoff else {
            return
          }
          self.awaitingBluetoothDisconnectForWifiHandoff = false
          self.appendLog("等待相机断开 BLE 超时，暂不进入图库")
          self.updateStatus("等待相机切换 Wi‑Fi 超时，请重试", isBusy: false)
        }
        bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
        bluetoothDisconnectHandoffTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        return
      }

      if let strategy,
         CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(for: strategy),
         let peripheral = selectedPeripheral {
        appendLog("传图模式 \(strategyName) 已观察到状态变化，主动断开 BLE 后进入图库")
        awaitingBluetoothDisconnectForWifiHandoff = true
        updateStatus("断开 BLE 准备连接 Wi‑Fi", isBusy: true)
        central.cancelPeripheralConnection(peripheral)
      } else {
        appendObservation("ACTIVATION_COMPLETE source=\(source) result=proceedToGallery strategy=\(strategyName)")
        appendLog("传图模式 \(strategyName) 已观察到状态变化，按 ReferenceApp 保持 BLE 并进入图库")
        pendingTransferActivationStrategies.removeAll()
        awaitingTransferActivationStateChange = false
        awaitingTransferActivationStateChangeSince = nil
        finishHandshakeIfPossible()
      }
      return
    }

    if CameraVendorTransferActivationCompletionPolicy.shouldTryNextStrategy(
      observedChange: transferActivationObservedChange,
      hasMoreStrategies: !pendingTransferActivationStrategies.isEmpty
    ) {
      if transferActivationCameraResponded {
        appendLog("传图模式 \(strategyName) 只启动了相机热点，未进入图库保留状态，尝试下一种模式")
      } else {
        appendLog("传图模式 \(strategyName) 未观察到状态变化，尝试下一种模式")
      }
      beginNextTransferActivationAttempt(on: peripheral)
      return
    }

    if transferActivationCameraResponded && !transferActivationObservedChange {
      if CameraVendorTransferActivationCompletionPolicy.shouldFallbackToWifiLaunchAfterCameraResponse(
        observedChange: transferActivationObservedChange,
        observedWifiLaunch: transferActivationObservedWifiLaunch
      ) {
        appendObservation("ACTIVATION_COMPLETE source=\(source) result=fallbackToWifiLaunch strategy=\(strategyName)")
        appendLog("传图模式 \(strategyName) 未进入保留状态，但热点已启动，回退到 Wi‑Fi/PTP 图库流程")
        if let strategy,
           CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(for: strategy),
           let peripheral = selectedPeripheral {
          awaitingBluetoothDisconnectForWifiHandoff = true
          updateStatus("断开 BLE 准备连接 Wi‑Fi", isBusy: true)
          central.cancelPeripheralConnection(peripheral)
        } else {
          pendingTransferActivationStrategies.removeAll()
          awaitingTransferActivationStateChange = false
          awaitingTransferActivationStateChangeSince = nil
          finishHandshakeIfPossible()
        }
        return
      }
      appendLog("相机已响应但未进入传图保留模式，暂不进入 Wi‑Fi/PTP")
      pendingTransferActivationStrategies.removeAll()
      awaitingTransferActivationStateChange = false
      awaitingTransferActivationStateChangeSince = nil
      updateStatus(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus, isBusy: false)
      return
    }

    if CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
      observedChange: transferActivationObservedChange,
      hasMoreStrategies: !pendingTransferActivationStrategies.isEmpty
    ) {
      appendLog("传图命令已完成，继续进入图库")
      finishHandshakeIfPossible()
      return
    }

    if !CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
      observedChange: transferActivationObservedChange,
      observedWifiLaunch: transferActivationObservedWifiLaunch
    ) {
      appendObservation("ACTIVATION_ABORT_NO_AP_READY strategy=\(strategyName)")
      appendLog("传图模式 \(strategyName) 未观察到 AP_STATE_READY，暂不进入 Wi‑Fi/PTP 图库流程")
      pendingTransferActivationStrategies.removeAll()
      awaitingTransferActivationStateChange = false
      awaitingTransferActivationStateChangeSince = nil
      updateStatus("相机未确认进入传图模式，请重试连接", isBusy: false)
      return
    }

    // All strategies exhausted after observing AP readiness.
    // Keep waiting briefly for late BLE notifications, then continue the Wi-Fi handoff.
    awaitingTransferActivationStateChange = true
    awaitingTransferActivationStateChangeSince = Date()
    appendLog("已观察到相机 AP ready，保持 BLE 并尝试进入图库。")
    if let strategy,
       CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(for: strategy),
       let peripheral = selectedPeripheral {
      awaitingBluetoothDisconnectForWifiHandoff = true
      updateStatus("断开 BLE 准备连接相机 Wi‑Fi", isBusy: true)
      central.cancelPeripheralConnection(peripheral)
    } else {
      finishHandshakeIfPossible()
    }
  }
}

extension CameraVendorBluetoothService: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let description: String
    switch central.state {
    case .unknown:
      description = "未知"
    case .resetting:
      description = "重置中"
    case .unsupported:
      description = "当前设备不支持蓝牙"
    case .unauthorized:
      description = "没有蓝牙权限"
    case .poweredOff:
      description = "蓝牙已关闭"
    case .poweredOn:
      description = "蓝牙已开启"
    @unknown default:
      description = "未识别状态"
    }

    appendLog("蓝牙状态: \(description)")

    guard central.state == .poweredOn else {
      updateStatus(description, isBusy: false)
      return
    }

    if shouldScanWhenPoweredOn {
      shouldScanWhenPoweredOn = false
      beginScan()
    } else if shouldAutoReconnectRememberedCamera,
              let rememberedPairedCamera,
              autoReconnectTargetPeripheralID == nil,
              selectedPeripheral == nil,
              !didCompletePairingCallback,
              !didCompleteHandshakeCallback {
      attemptAutoReconnect(using: rememberedPairedCamera)
    } else {
      updateStatus("就绪", isBusy: false)
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      .map(\.uuidString)
    let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

    let name = localName ?? peripheral.name
    guard let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: name,
      serviceUUIDs: serviceUUIDs,
      manufacturerData: manufacturerData
    ) else {
      logUnmatchedAdvertisementSample(
        peripheral: peripheral,
        name: name,
        serviceUUIDs: serviceUUIDs,
        manufacturerData: manufacturerData,
        rssi: RSSI.intValue
      )
      return
    }

    discoveredPeripherals[peripheral.identifier] = peripheral
    let camera = upsertCamera(peripheral: peripheral, match: match, rssi: RSSI.intValue)

    appendLog(
      "发现相机: \(camera.name) RSSI \(camera.rssi) | " +
      "variant \(camera.appVariant.rawValue) | " +
      "services \(serviceUUIDs.joined(separator: ",")) | " +
      "mfg \(hexString(manufacturerData)) | " +
      "match \(camera.matchDetails)"
    )

    updateStatus("已发现 \(discoveredCameras.count) 台相机", isBusy: false)
    notifyDevicesChanged()

    if let autoReconnectTargetPeripheralID,
       peripheral.identifier == autoReconnectTargetPeripheralID {
      scanTimeoutWorkItem?.cancel()
      central.stopScan()
      appendLog("已找到上次配对的相机，自动发起连接")
      prepareConnectionAttempt(peripheral: peripheral, camera: camera)
      updateStatus("连接上次配对的相机", isBusy: true)
      central.connect(peripheral, options: nil)
      return
    }

    if awaitingPairingReadyRediscovery,
       let selectedPeripheral,
       peripheral.identifier == selectedPeripheral.identifier,
       CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
         serviceUUIDs: serviceUUIDs,
         manufacturerData: manufacturerData
       ) {
      awaitingPairingReadyRediscovery = false
      scanTimeoutWorkItem?.cancel()
      central.stopScan()
      appendLog("已捕获可配对广播，自动重新连接 | services \(serviceUUIDs.joined(separator: ",")) | mfg \(hexString(manufacturerData))")
      updateStatus("重新连接相机中", isBusy: true)
      central.connect(peripheral, options: nil)
    }
  }

  private func logUnmatchedAdvertisementSample(
    peripheral: CBPeripheral,
    name: String?,
    serviceUUIDs: [String],
    manufacturerData: Data?,
    rssi: Int
  ) {
    let key = [
      peripheral.identifier.uuidString,
      name ?? "nil",
      serviceUUIDs.joined(separator: ","),
      hexString(manufacturerData),
    ].joined(separator: "|")
    guard !unmatchedAdvertisementSampleKeys.contains(key) else {
      return
    }

    unmatchedAdvertisementSampleKeys.insert(key)
    unmatchedAdvertisementSampleCount += 1
    guard CameraVendorBleScanDiagnosticsPolicy.shouldLogUnmatchedAdvertisement(
      sampleCount: unmatchedAdvertisementSampleCount
    ) else {
      return
    }

    appendLog(
      "忽略 BLE 广播样本 #\(unmatchedAdvertisementSampleCount): " +
      "name=\(name ?? "nil") peripheral=\(peripheral.name ?? "nil") " +
      "id=\(peripheral.identifier.uuidString.prefix(8)) rssi=\(rssi) " +
      "services=\(serviceUUIDs.joined(separator: ",").isEmpty ? "-" : serviceUUIDs.joined(separator: ",")) " +
      "mfg=\(hexString(manufacturerData))"
    )
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    recordBackgroundHardwareActivity()
    appendLog("蓝牙连接成功: \(peripheral.name ?? peripheral.identifier.uuidString)")
    appendObservation("BLE_CONNECTED name=\(peripheral.name ?? "nil") id=\(peripheral.identifier.uuidString)")
    updateStatus("读取相机服务中", isBusy: true)
    peripheral.delegate = self
    peripheral.discoverServices(nil)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    let errorDescription = error?.localizedDescription
    appendLog("连接失败: \(errorDescription ?? "unknown")")
    if CameraVendorBluetoothConnectFailurePolicy.requiresSystemBluetoothPairingCleanup(for: errorDescription) {
      requireSystemBluetoothPairingCleanup(reason: errorDescription ?? "didFailToConnect", peripheral: peripheral)
      return
    }
    updateStatus(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(
        for: errorDescription
      ),
      isBusy: false
    )
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    if let error {
      appendLog("连接断开: \(error.localizedDescription)")
      appendObservation("BLE_DISCONNECTED error=\(error.localizedDescription)")
    } else {
      appendLog("连接断开")
      appendObservation("BLE_DISCONNECTED error=nil")
    }

    if selectedPeripheral?.identifier == peripheral.identifier {
      if awaitingBluetoothDisconnectForWifiHandoff {
        awaitingBluetoothDisconnectForWifiHandoff = false
        bluetoothDisconnectHandoffTimeoutWorkItem?.cancel()
        bluetoothDisconnectHandoffTimeoutWorkItem = nil
        // Camera needs a few seconds after BLE disconnect to fully initialize
        // its WiFi AP and PTP/IP listener.
        let handoffDelay = CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true)
        appendLog("相机已断开 BLE，等待 \(String(format: "%.1f", handoffDelay)) 秒让相机 Wi‑Fi AP 和 PTP 服务就绪")
        updateStatus("等待相机 Wi‑Fi 就绪", isBusy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + handoffDelay) { [weak self] in
          guard let self else { return }
          self.appendLog("延迟结束，开始连接相机 Wi‑Fi")
          self.finishHandshakeIfPossible()
        }
        return
      }

      if isRunningTransferActivation {
        let didReachTransferReadyState = transferActivationObservedChange
        transferActivationTimeoutWorkItem?.cancel()
        transferActivationTimeoutWorkItem = nil
        isRunningTransferActivation = false
        pendingTransferActivationWrites = []
        pendingTransferActivationStrategies.removeAll()
        currentTransferActivationStrategy = nil
        if didReachTransferReadyState {
          appendLog("触发传图后 BLE 已断开，按相机切换 Wi‑Fi 继续流程")
          finishHandshakeIfPossible()
        } else {
          appendLog("触发传图期间 BLE 已断开，但尚未观察到传图保留模式，暂不进入 Wi‑Fi/PTP")
          updateStatus(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus, isBusy: false)
        }
        return
      }

      if awaitingTransferActivationStateChange {
        let elapsed = awaitingTransferActivationStateChangeSince.map { Date().timeIntervalSince($0) }
        if let elapsed,
           CameraVendorTransferActivationDisconnectPolicy.shouldTreatDisconnectAsWifiHandoff(
            elapsedSinceWaitingForConfirmation: elapsed
           ) {
          appendLog("等待相机确认期间 BLE 快速断开，按相机切换 Wi‑Fi 继续流程")
          awaitingTransferActivationStateChange = false
          awaitingTransferActivationStateChangeSince = nil
          transferActivationObservedChange = true
          finishHandshakeIfPossible()
          return
        }

        appendLog("等待相机确认期间 BLE 断开过晚，不视为 Wi‑Fi 切换成功")
        awaitingTransferActivationStateChange = false
        awaitingTransferActivationStateChangeSince = nil
        transferActivationObservedChange = false
        updateStatus("相机未确认传图，请重试", isBusy: false)
        return
      }

      if CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: secureHandshakePhase,
        retryCount: secureHandshakeReconnectCount
      ) {
        reconnectAfterSecureHandshakeDisconnect(peripheral)
        return
      }

      if secureHandshakePhase == .awaitingIdentificationNumberWrite {
        appendLog("ReferenceApp 配对在识别号写入阶段断开，当前不会继续进入 Wi‑Fi 流程")
      }

      switch encryptionRecoveryPolicy.consumeDisconnectAction() {
      case .requireManualCameraPairingMode:
        awaitingPairingReadyRediscovery = false
        appendLog("ReferenceApp 配对未完成，不能把这次断开当成已配对")
        appendLog("请在相机上进入 Bluetooth > PAIRING，再回到 App 重新搜索连接")
        updateStatus("请先让相机进入 PAIRING 模式", isBusy: false)
        return
      case .none:
        break
      }
    }

    updateStatus("连接已断开", isBusy: false)
  }
}

extension CameraVendorBluetoothService: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      appendLog("发现服务失败: \(error.localizedDescription)")
      updateStatus("读取服务失败", isBusy: false)
      return
    }

    appendLog("发现服务数量: \(peripheral.services?.count ?? 0)")
    for service in peripheral.services ?? [] {
      appendLog("服务 UUID: \(service.uuid.uuidString)")
      if service.uuid == pairServiceUUID {
        handshakeMode = .legacy
        appendLog("找到 CameraVendor 配对服务")
        handshakeCoordinator.registerServiceForCharacteristicDiscovery(service.uuid.uuidString)
      } else if service.uuid == securePairServiceUUID {
        handshakeMode = .secure
        appendLog("找到 CameraVendor Secure 配对服务")
        handshakeCoordinator.registerServiceForCharacteristicDiscovery(service.uuid.uuidString)
      } else if service.uuid == deviceNameServiceUUID {
        handshakeCoordinator.registerServiceForCharacteristicDiscovery(service.uuid.uuidString)
      } else if service.uuid == deviceInformationServiceUUID {
        handshakeCoordinator.registerServiceForCharacteristicDiscovery(service.uuid.uuidString)
      }

      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      appendLog("发现特征失败: \(error.localizedDescription)")
      updateStatus("读取特征失败", isBusy: false)
      return
    }

    for characteristic in service.characteristics ?? [] {
      discoveredCharacteristicsByUUID[characteristic.uuid] = characteristic
      appendLog(
        "特征 UUID: \(characteristic.uuid.uuidString) @ \(service.uuid.uuidString) | props \(propertyFlags(characteristic))"
      )
      if characteristic.uuid == pairingCharacteristicUUID {
        pairingCharacteristic = characteristic
      } else if characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID {
        connectedDeviceIdentificationCharacteristic = characteristic
      } else if characteristic.uuid == connectedDeviceNameCharacteristicUUID {
        connectedDeviceNameCharacteristic = characteristic
      } else if isHandshakeMetadataCharacteristic(characteristic) {
        handshakeCoordinator.registerMetadataRead(characteristic.uuid.uuidString)
        peripheral.readValue(for: characteristic)
      } else if shouldProbeAfterHandshake(characteristic) {
        probedCharacteristics[characteristic.uuid] = characteristic
      }

      if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
        notifiableCharacteristics.append(characteristic)
        handshakeCoordinator.registerNotificationSubscription(characteristic.uuid.uuidString)
        appendLog("订阅通知/指示: \(characteristic.uuid.uuidString)")
        peripheral.setNotifyValue(true, for: characteristic)
      }
    }

    handshakeCoordinator.completeCharacteristicDiscovery(for: service.uuid.uuidString)

    if service.uuid == pairServiceUUID, connectedDeviceNameCharacteristic == nil {
      appendLog("配对服务已发现，但已连接设备名称特征还没拿到")
    } else if service.uuid == securePairServiceUUID {
      appendLog("Secure 配对服务特征已加载，等待按 ReferenceApp 顺序执行")
    }

    maybeStartPairing(on: peripheral)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    let isMetadataCharacteristic = isHandshakeMetadataCharacteristic(characteristic)

    if let error {
      let characteristicKey = characteristic.uuid.uuidString.uppercased()
      if pendingPostHandshakeProbeReads.contains(characteristicKey) {
        pendingPostHandshakeProbeReads.remove(characteristicKey)
        appendLog("探测读取失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        if pendingPostHandshakeProbeReads.isEmpty {
          postHandshakeProbeTimeoutWorkItem?.cancel()
          isRunningPostHandshakeProbe = false
          appendLog("握手后 ReferenceApp 探测完成")
          finishHandshakeIfPossible()
        }
      }
      if isMetadataCharacteristic {
        handshakeCoordinator.completeMetadataRead(characteristic.uuid.uuidString)
      }
      if let error = error as NSError?,
         error.domain == CBATTErrorDomain,
         error.code == CBATTError.insufficientEncryption.rawValue {
        appendLog("读取需要加密链路，等待本地蓝牙配对完成")
        if encryptionRecoveryPolicy.registerEncryptionFailureAndShouldRetry() {
          appendLog("首次加密读取失败，等待断开后自动重连")
          updateStatus("等待加密配对完成后重连", isBusy: true)
          return
        }
        if encryptionRecoveryPolicy.shouldRequireSystemBluetoothCleanupAfterRetryExhausted() {
          requireSystemBluetoothPairingCleanup(reason: error.localizedDescription, peripheral: peripheral)
          return
        }
      }
      appendLog("读取特征值失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
      maybeStartPairing(on: peripheral)
      return
    }

    recordBackgroundHardwareActivity()

    if characteristic.uuid == serialNumberCharacteristicUUID,
       let data = characteristic.value,
       let serial = String(data: data, encoding: .utf8)?
       .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) {
      handshakeCoordinator.completeMetadataRead(characteristic.uuid.uuidString)
      discoveredSerialNumber = serial
      appendLog("相机序列号: \(serial)")
      maybeStartPairing(on: peripheral)
      return
    }

    if characteristic.uuid == deviceNameCharacteristicUUID,
       let data = characteristic.value,
       let name = String(data: data, encoding: .utf8)?
       .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) {
      handshakeCoordinator.completeMetadataRead(characteristic.uuid.uuidString)
      discoveredName = name
      appendLog("相机名称: \(name)")
      maybeStartPairing(on: peripheral)
      return
    }

    if characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID {
      if let data = characteristic.value {
        appendLog("读取到已连接设备识别号: \(hexString(data))")
        secureIdentificationNumberAlreadyPaired =
          CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(data)
        if secureIdentificationNumberAlreadyPaired {
          appendLog("识别号已带应用标记，按已配对重连处理")
        }
        if CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
          hasRememberedRecord: rememberedPairedCamera != nil,
          isAlreadyPairedIdentificationNumber: secureIdentificationNumberAlreadyPaired
        ) {
          requireSystemBluetoothPairingCleanup(
            reason: "相机端已存在 App 配对标记，但本地没有一致配对记录",
            peripheral: peripheral
          )
          return
        }
        guard let ackPayload = CameraVendorSecureHandshakeCodec.statusAckPayload(from: data) else {
          appendLog("已连接设备识别号长度异常")
          updateStatus("握手失败", isBusy: false)
          return
        }

        appendLog("回写识别号 ACK: \(hexString(ackPayload))")
        secureHandshakePhase = .awaitingIdentificationNumberWrite
        updateStatus("等待相机确认安全配对", isBusy: true)
        peripheral.writeValue(ackPayload, for: characteristic, type: .withResponse)
      } else {
        appendLog("已连接设备识别号为空")
        updateStatus("握手失败", isBusy: false)
      }
      return
    }

    if let data = characteristic.value {
      let characteristicKey = characteristic.uuid.uuidString.uppercased()
      let previousValue = observedCharacteristicValues[characteristicKey]
      observedCharacteristicValues[characteristic.uuid.uuidString.uppercased()] = data
      refreshPendingHandshakeSummary(using: peripheral)
      let readyForCurrentTransferActivation = currentTransferActivationStrategy.map {
        CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
          uuidString: characteristicKey,
          value: data,
          for: $0
        )
      } ?? false
      if isRunningTransferActivation,
         CameraVendorReferenceAppTransferActivationPlan.isTrackedStatusCharacteristic(
           uuidString: characteristicKey,
           for: currentTransferActivationStrategy
         ),
         CameraVendorTransferActivationStateUpdatePolicy.shouldHandleTrackedStatusUpdate(
           previousValue: previousValue,
           newValue: data,
           isReadyToJoinWifi: readyForCurrentTransferActivation
         ) {
        let statusDescription =
          CameraVendorReferenceAppTransferActivationPlan.debugStatusDescription(
            uuidString: characteristicKey,
            value: data
          )
        let isReadyToJoinWifi = readyForCurrentTransferActivation
        if characteristicKey == CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
           let apState = CameraVendorReferenceAppApState(data: data),
           apState.isReadyToJoinWifi {
          if !transferActivationObservedWifiLaunch {
            appendLog("已确认相机热点启动 \(characteristic.uuid.uuidString): \(apState.debugName)")
          }
          appendObservation("AP_STATE_READY uuid=\(characteristic.uuid.uuidString) value=\(hexString(data)) state=\(apState.debugName)")
          transferActivationObservedWifiLaunch = true
          if apState == .launched {
            scheduleReservedImageReceiveProbeIfNeeded(on: peripheral)
          }
        }

        if isReadyToJoinWifi {
          transferActivationObservedChange = true
          appendObservation(
            "ACTIVATION_STATE_READY uuid=\(characteristic.uuid.uuidString) " +
            "previous=\(hexString(previousValue)) value=\(hexString(data)) " +
            "description=\(statusDescription ?? "-")"
          )
          appendLog(
            "传图状态进入可连接阶段 \(characteristic.uuid.uuidString): " +
            "\(hexString(previousValue)) -> \(hexString(data))" +
            (statusDescription.map { " [\($0)]" } ?? "")
          )
          updateStatus(CameraVendorTransferActivationStatusTextPolicy.readyToEnterGalleryStatus, isBusy: true)
          // Complete immediately instead of waiting for timeout
          transferActivationTimeoutWorkItem?.cancel()
          transferActivationTimeoutWorkItem = nil
          if CameraVendorBleStateSamplingPlan.shouldDelayGalleryUntilSamplingCompletes,
             !isDelayingGalleryForBleStateSampling,
             let lastDelay = CameraVendorBleStateSamplingPlan.sampleDelaysSeconds.last {
            isDelayingGalleryForBleStateSampling = true
            appendObservation("ACTIVATION_READY_DELAY_FOR_BLE_SAMPLING seconds=\(String(format: "%.0f", lastDelay))")
            let completion = DispatchWorkItem { [weak self] in
              guard let self else { return }
              self.bleStateSamplingCompletionWorkItem = nil
              self.isDelayingGalleryForBleStateSampling = false
              self.completeCurrentTransferActivationAttempt(on: peripheral, source: "ble-state-sampling-complete")
            }
            bleStateSamplingCompletionWorkItem = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + lastDelay, execute: completion)
          } else if !isDelayingGalleryForBleStateSampling {
            completeCurrentTransferActivationAttempt(on: peripheral, source: "isReadyToJoinWifi")
          }
        } else {
          appendObservation(
            "ACTIVATION_STATE_CHANGE uuid=\(characteristic.uuid.uuidString) " +
            "previous=\(hexString(previousValue)) value=\(hexString(data)) " +
            "description=\(statusDescription ?? "-")"
          )
          appendLog(
            "传图状态变化 \(characteristic.uuid.uuidString): " +
            "\(hexString(previousValue)) -> \(hexString(data))" +
            (statusDescription.map { " [\($0)]" } ?? "") +
            "，继续等待图库保留状态"
          )
          // Camera acknowledged the activation command (e.g. NotLaunched).
          // Extend the timeout to give it time to transition to Launched.
          transferActivationTimeoutWorkItem?.cancel()
          let extendedTimeout = DispatchWorkItem { [weak self] in
            self?.completeCurrentTransferActivationAttempt(on: peripheral, source: "extended-timeout")
          }
          transferActivationTimeoutWorkItem = extendedTimeout
          DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: extendedTimeout)
          appendLog("相机已响应，延长等待至 15 秒")
          transferActivationCameraResponded = true
        }
      } else if awaitingTransferActivationStateChange,
                (
                  CameraVendorReferenceAppTransferActivationPlan.legacyTrackedStatusCharacteristicUUIDStrings.contains(characteristicKey)
                    || characteristicKey == CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString
                ),
                previousValue != data {
        let statusDescription =
          CameraVendorReferenceAppTransferActivationPlan.debugStatusDescription(
            uuidString: characteristicKey,
            value: data
          )
        let shouldFinishWaiting: Bool

        if characteristicKey == CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString {
          shouldFinishWaiting = CameraVendorReferenceAppApState(data: data)?.isReadyToJoinWifi ?? false
        } else {
          shouldFinishWaiting = true
        }

        if shouldFinishWaiting {
          awaitingTransferActivationStateChange = false
          awaitingTransferActivationStateChangeSince = nil
          transferActivationObservedChange = true
          appendLog(
            "传图等待阶段进入可连接状态 \(characteristic.uuid.uuidString): " +
            "\(hexString(previousValue)) -> \(hexString(data))" +
            (statusDescription.map { " [\($0)]" } ?? "")
          )
          finishHandshakeIfPossible()
        } else {
          appendLog(
            "传图等待阶段状态变化 \(characteristic.uuid.uuidString): " +
            "\(hexString(previousValue)) -> \(hexString(data))" +
            (statusDescription.map { " [\($0)]" } ?? "") +
            "，继续等待热点真正就绪"
          )
        }
      }
      if pendingPostHandshakeProbeReads.contains(characteristic.uuid.uuidString.uppercased()) {
        let serviceUUID = characteristic.service?.uuid.uuidString ?? "-"
        appendLog("探测返回 \(characteristic.uuid.uuidString) @ \(serviceUUID): \(hexString(data))")
      } else {
        appendLog("收到特征更新 \(characteristic.uuid.uuidString): \(hexString(data))")
      }
    } else if isMetadataCharacteristic {
      appendLog("元数据特征返回空值 \(characteristic.uuid.uuidString)")
    } else if pendingPostHandshakeProbeReads.contains(characteristic.uuid.uuidString.uppercased()) {
      appendLog("探测返回空值 \(characteristic.uuid.uuidString)")
    }

    if isMetadataCharacteristic {
      handshakeCoordinator.completeMetadataRead(characteristic.uuid.uuidString)
    }

    let characteristicKey = characteristic.uuid.uuidString.uppercased()
    if pendingPostHandshakeProbeReads.contains(characteristicKey) {
      pendingPostHandshakeProbeReads.remove(characteristicKey)
      if pendingPostHandshakeProbeReads.isEmpty {
        postHandshakeProbeTimeoutWorkItem?.cancel()
        isRunningPostHandshakeProbe = false
        appendLog("握手后 ReferenceApp 探测完成")
        finishHandshakeIfPossible()
      }
    }

    maybeFinishHandshakeAfterReceivingWifiConfiguration()

    maybeStartPairing(on: peripheral)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didWriteValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if let error = error as NSError? {
      if isRunningTransferActivation,
         CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
           uuidString: characteristic.uuid.uuidString
         ) {
        appendLog("传图命令写入失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        isRunningTransferActivation = false
        pendingTransferActivationWrites = []
        currentTransferActivationStrategy = nil
        transferActivationTimeoutWorkItem?.cancel()
        transferActivationTimeoutWorkItem = nil
        beginNextTransferActivationAttempt(on: peripheral)
        return
      }

      if error.domain == CBATTErrorDomain,
         error.code == CBATTError.insufficientEncryption.rawValue {
        appendLog("相机要求加密链路，需在系统弹窗中完成蓝牙配对")
        if encryptionRecoveryPolicy.registerEncryptionFailureAndShouldRetry() {
          appendLog("检测到首次加密失败，等待断开后自动重连")
          updateStatus("等待加密配对完成后重连", isBusy: true)
          return
        }
        if encryptionRecoveryPolicy.shouldRequireSystemBluetoothCleanupAfterRetryExhausted() {
          requireSystemBluetoothPairingCleanup(reason: error.localizedDescription, peripheral: peripheral)
          return
        }
      } else {
        appendLog("写入失败: \(error.localizedDescription)")
      }
      updateStatus("握手失败", isBusy: false)
      return
    }

    if isRunningTransferActivation,
       CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
         uuidString: characteristic.uuid.uuidString
       ) {
      appendLog("传图命令写入成功 \(characteristic.uuid.uuidString)")
      appendObservation("BLE_WRITE_ACK uuid=\(characteristic.uuid.uuidString) result=success")
      if characteristic.uuid.uuidString.uppercased()
          == CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString {
        let payload = transferActivationWritePayloadsByUUID[characteristic.uuid.uuidString.uppercased()]
          ?? CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
        appendObservation(
          "BLE_IMAGE_RESIZE_WRITE_ACK payload=\(hexString(payload)) " +
          "mode=\(payload == CameraVendorTransferActivationResizePolicy.resizeEnabledPayload ? "compressed" : "original")"
        )
        if characteristic.properties.contains(.read) {
          peripheral.readValue(for: characteristic)
        }
        DispatchQueue.main.asyncAfter(
          deadline: .now() + CameraVendorTransferActivationResizePolicy.postWriteDelaySeconds
        ) { [weak self, weak peripheral] in
          guard let self, let peripheral else { return }
          self.writeNextTransferActivationStep(on: peripheral)
        }
        return
      }
      writeNextTransferActivationStep(on: peripheral)
      return
    }

    if characteristic.uuid == pairingCharacteristicUUID {
      guard let connectedDeviceNameCharacteristic else {
        appendLog("缺少已连接设备名称特征")
        updateStatus("握手失败", isBusy: false)
        return
      }

      let deviceName = connectedDeviceNameToWrite
      let payload = CameraVendorSecureHandshakeCodec.identifierPayload(deviceName)
      appendLog("配对 token 写入成功，继续写入已连接设备名称: \(deviceName)")
      peripheral.writeValue(payload, for: connectedDeviceNameCharacteristic, type: .withResponse)
      return
    }

    if characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID,
       handshakeMode == .secure {
      appendLog("识别号 ACK 写入成功")
      hasWrittenPairingIdentifier = true
      secureHandshakePhase = .completed
      handleIdentifierWriteCompletion(on: peripheral)
      return
    }

    if characteristic.uuid == connectedDeviceNameCharacteristicUUID,
       handshakeMode == .secure {
      if CameraVendorSecureIdentificationAckPolicy.shouldSkipIdentificationAck(
        isRememberedPairing: shouldSkipManualPairingConfirmationForCurrentCamera()
      ) {
        appendLog("已连接设备名称写入成功；已记住配对，跳过识别号 ACK，直接进入传输准备")
        secureHandshakePhase = .completed
        hasWrittenPairingIdentifier = true
        handleIdentifierWriteCompletion(on: peripheral)
        return
      }

      guard let connectedDeviceIdentificationCharacteristic else {
        appendLog("缺少已连接设备识别号特征")
        updateStatus("握手失败", isBusy: false)
        return
      }

      appendLog("已连接设备名称写入成功，继续读取已连接设备识别号")
      secureHandshakePhase = .awaitingIdentificationNumberRead
      peripheral.readValue(for: connectedDeviceIdentificationCharacteristic)
      return
    }

    if characteristic.uuid == connectedDeviceNameCharacteristicUUID
        || characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID {
      appendLog("标识符写入成功")
      hasWrittenPairingIdentifier = true
      if handshakeMode == .secure {
        secureHandshakePhase = .completed
      }
      handleIdentifierWriteCompletion(on: peripheral)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    handshakeCoordinator.completeNotificationSubscription(for: characteristic.uuid.uuidString)
    if let error {
      appendLog("订阅失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
      maybeStartPairing(on: peripheral)
      return
    }

    appendLog("订阅状态 \(characteristic.uuid.uuidString): \(characteristic.isNotifying)")
    maybeStartPairing(on: peripheral)
  }
}
