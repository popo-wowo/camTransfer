import CoreBluetooth
import CryptoKit
import Darwin
import Foundation
import NetworkExtension
import UIKit
import os.log


struct CameraVendorConnectionSummary: Equatable {
  let deviceName: String
  let serialNumber: String
  let connectedDeviceName: String
  let preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?
  let preferCompressedDownloads: Bool
  let verifiedConnectionSteps: [IOSCameraConnectionStep]
  let compatibilityFacts: CameraCompatibilityFacts?

  init(
    deviceName: String,
    serialNumber: String,
    connectedDeviceName: String = CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName(),
    preferredWifiNetwork: CameraVendorWifiNetworkConfiguration? = nil,
    preferCompressedDownloads: Bool = false,
    verifiedConnectionSteps: [IOSCameraConnectionStep] = [],
    compatibilityFacts: CameraCompatibilityFacts? = nil
  ) {
    self.deviceName = deviceName
    self.serialNumber = serialNumber
    self.connectedDeviceName = connectedDeviceName
    self.preferredWifiNetwork = preferredWifiNetwork
    self.preferCompressedDownloads = preferCompressedDownloads
    self.verifiedConnectionSteps = verifiedConnectionSteps
    self.compatibilityFacts = compatibilityFacts
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
      verifiedConnectionSteps: steps,
      compatibilityFacts: compatibilityFacts
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

enum CameraVendorGattActivationResolutionError: Error, Equatable, LocalizedError {
  case alreadyAttempted
  case missingFacts
  case missingResolver
  case invalidDefinition(id: ActivationStrategyID, supportStatus: CameraSupportStatus)

  var errorDescription: String? {
    switch self {
    case .alreadyAttempted:
      return "GATT facts may resolve Activation Strategy only once"
    case .missingFacts:
      return "GATT discovery completed without typed compatibility facts"
    case .missingResolver:
      return "GATT discovery completed without an Activation Strategy resolver"
    case let .invalidDefinition(id, supportStatus):
      return "GATT facts selected invalid Activation Strategy \(id.rawValue) status=\(supportStatus.rawValue)"
    }
  }
}

final class CameraVendorGattActivationResolutionGate {
  private var hasAttemptedResolution = false

  func resolve(
    facts: CameraCompatibilityFacts?,
    using resolver: ((CameraCompatibilityFacts) throws -> ActivationStrategyDefinition)?
  ) throws -> ActivationStrategyDefinition {
    guard !hasAttemptedResolution else {
      throw CameraVendorGattActivationResolutionError.alreadyAttempted
    }
    hasAttemptedResolution = true
    guard let facts else {
      throw CameraVendorGattActivationResolutionError.missingFacts
    }
    guard let resolver else {
      throw CameraVendorGattActivationResolutionError.missingResolver
    }
    let definition = try resolver(facts)
    guard definition.supportStatus == .verified, definition.id != .unsupported else {
      throw CameraVendorGattActivationResolutionError.invalidDefinition(
        id: definition.id,
        supportStatus: definition.supportStatus
      )
    }
    return definition
  }
}

enum CameraVendorRememberedGalleryTerminalFailure: Equatable {
  case bleConnectFailed(reason: String)
  case bleConnectTimedOut
  case bleDisconnected
  case scanTimedOut
  case noAdvertisement
  case rememberedEndpointNotMatched
  case rememberedEndpointFoundNotReady
  case serviceDiscoveryFailed(reason: String)
  case gattCharacteristicDiscoveryFailed(reason: String)
  case identityReadFailed(reason: String)
  case identityMismatch
  case registrationRejected(reason: String)
  case activationDisconnected
  case activationNotReady
  case activationResolutionFailed(reason: String)
  case missingActivationFeature

  var issue: IOSCameraConnectionIssue {
    switch self {
    case let .bleConnectFailed(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "BLE 连接失败: \(reason)")
    case .bleConnectTimedOut:
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "BLE 连接超时（未收到系统连接回调）")
    case .bleDisconnected:
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "BLE 连接意外断开")
    case .scanTimedOut:
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "扫描已配对相机超时")
    case .noAdvertisement:
      return IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "未收到相机 BLE 广播，请确认相机已开机并进入传图状态后重试"
      )
    case .rememberedEndpointNotMatched:
      return IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "已收到相机 BLE 广播，但原有连接记录已失效，请重新建立蓝牙连接或重新配对"
      )
    case .rememberedEndpointFoundNotReady:
      return IOSCameraConnectionIssue(
        step: .reconnectPairedBle,
        reason: "已发现相机，但当前未进入可连接的传图状态，请唤醒相机并重试"
      )
    case let .serviceDiscoveryFailed(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "发现 BLE Service 失败: \(reason)")
    case let .gattCharacteristicDiscoveryFailed(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "发现 BLE 特征失败: \(reason)")
    case let .identityReadFailed(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "读取相机身份失败: \(reason)")
    case .identityMismatch:
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "已配对记录与当前相机身份不一致")
    case let .registrationRejected(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "相机拒绝应用注册: \(reason)")
    case .activationDisconnected:
      return IOSCameraConnectionIssue(step: .activateCameraWifi, reason: "传图激活完成前 BLE 断开")
    case .activationNotReady:
      return IOSCameraConnectionIssue(step: .activateCameraWifi, reason: "传图激活未进入可连接状态")
    case let .activationResolutionFailed(reason):
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: reason)
    case .missingActivationFeature:
      return IOSCameraConnectionIssue(step: .reconnectPairedBle, reason: "相机未提供可验证的传图激活特征")
    }
  }
}

enum CameraVendorRememberedReconnectTimeoutClassification: String, Equatable {
  case noAdvertisement
  case rememberedEndpointNotMatched
  case rememberedEndpointFoundNotReady

  static func classify(
    recognizedAdvertisementCount: Int,
    rememberedEndpointFoundNotReady: Bool
  ) -> Self {
    if rememberedEndpointFoundNotReady {
      return .rememberedEndpointFoundNotReady
    }
    return recognizedAdvertisementCount > 0 ? .rememberedEndpointNotMatched : .noAdvertisement
  }
}

final class CameraVendorRememberedGalleryTerminalOwner {
  private let targetPeripheralID: UUID
  private let onFailure: (IOSCameraConnectionIssue) -> Void
  private let lock = NSLock()
  private var storedTerminalFailure: CameraVendorRememberedGalleryTerminalFailure?

  var terminalFailure: CameraVendorRememberedGalleryTerminalFailure? {
    lock.lock()
    defer { lock.unlock() }
    return storedTerminalFailure
  }

  init(
    targetPeripheralID: UUID,
    onFailure: @escaping (IOSCameraConnectionIssue) -> Void
  ) {
    self.targetPeripheralID = targetPeripheralID
    self.onFailure = onFailure
  }

  func owns(callbackPeripheralID: UUID) -> Bool {
    callbackPeripheralID == targetPeripheralID
  }

  @discardableResult
  func fail(
    _ failure: CameraVendorRememberedGalleryTerminalFailure,
    intent: IOSCameraServiceWirelessIntent
  ) -> Bool {
    guard intent == .rememberedGallery else {
      return false
    }

    lock.lock()
    guard storedTerminalFailure == nil else {
      lock.unlock()
      return false
    }
    storedTerminalFailure = failure
    lock.unlock()

    onFailure(failure.issue)
    return true
  }
}

enum CameraVendorRememberedGalleryTerminalRouter {
  @discardableResult
  static func routeCharacteristicDiscoveryFailure(
    reason: String,
    callbackPeripheralID: UUID,
    intent: IOSCameraServiceWirelessIntent,
    owner: CameraVendorRememberedGalleryTerminalOwner?
  ) -> Bool {
    guard owner?.owns(callbackPeripheralID: callbackPeripheralID) == true else {
      return false
    }
    return owner?.fail(
      .gattCharacteristicDiscoveryFailed(reason: reason),
      intent: intent
    ) ?? false
  }

  @discardableResult
  static func routeUnexpectedBleDisconnect(
    callbackPeripheralID: UUID,
    intent: IOSCameraServiceWirelessIntent,
    didCompleteHandshake: Bool,
    isExpectedWifiHandoff: Bool,
    isRecoveryInProgress: Bool,
    owner: CameraVendorRememberedGalleryTerminalOwner?
  ) -> Bool {
    guard !didCompleteHandshake,
          !isExpectedWifiHandoff,
          !isRecoveryInProgress,
          owner?.owns(callbackPeripheralID: callbackPeripheralID) == true else {
      return false
    }
    return owner?.fail(.bleDisconnected, intent: intent) ?? false
  }
}

enum CameraVendorGalleryDiagnostics {
  static var externalLogHandler: ((String) -> Void)?

  static func log(_ message: String) {
    CameraDiagnosticPipeline.shared.emitLegacy(
      message,
      additionalObserver: externalLogHandler
    )
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
    initAttempts(
      packetVariants: [
        .vendorLegacyWithClientIPv4Guid,
        .vendorLegacyWithoutClientIPv4,
      ],
      clientName: clientName,
      clientIP: clientIP,
      timeout: initAckTimeoutSeconds
    )
  }

  static func initAttempts(
    packetVariants: [PtpInitPacketVariantID],
    clientName: String,
    clientIP: String?,
    timeout: TimeInterval
  ) -> [CameraVendorOfficialGalleryPtpInitAttempt] {
    packetVariants.map { packetVariant in
      let variant: CameraVendorOfficialGalleryPtpInitVariant
      switch packetVariant {
      case .vendorLegacyWithClientIPv4Guid:
        variant = CameraVendorOfficialGalleryPtpInitVariant(
          name: "CameraVendor legacy + client IP GUID",
          includesClientIP: true
        )
      case .vendorLegacyWithoutClientIPv4:
        variant = CameraVendorOfficialGalleryPtpInitVariant(
          name: "CameraVendor legacy",
          includesClientIP: false
        )
      }
      return CameraVendorOfficialGalleryPtpInitAttempt(
        name: variant.name,
        packet: CameraVendorPtpPacketBuilder.buildInitCommandRequest(
          friendlyName: clientName,
          clientIP: variant.includesClientIP ? clientIP : nil
        ),
        timeout: timeout
      )
    }
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
    if nsError.domain == "CameraConnectionExecutionState" {
      return false
    }
    if nsError.domain == "FujifilmProtocolEngine" {
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

enum CameraVendorJpegDataPolicy {
  static func hasEndMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[data.count - 2] == 0xFF && data[data.count - 1] == 0xD9
  }

  static func hasStartMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
  }
}

enum CameraVendorPreviewImageValidationPolicy {
  private static let minimumDecodeableIncompleteJpegBytes = 64 * 1_024
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
    guard isLikelyImageData(data) else { return false }
    return !shouldRejectIncompletePartialPreview(data) || data.count >= minimumDecodeableIncompleteJpegBytes
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

enum CameraVendorPtpSocketReadDiagnosticPolicy {
  static let progressIntervalBytes = 1 * 1_048_576

  static func shouldReportProgress(totalBytes: Int) -> Bool {
    totalBytes >= progressIntervalBytes
  }
}

extension UInt32 {
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
    "insufficient authentication",
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

enum CameraVendorBleConnectAttemptOutcome: Equatable {
  case connected
  case failed
  case timedOut
  case cancelled(reason: String)
  case superseded(reason: String)
}

enum CameraVendorBleConnectAttemptPolicy {
  static let timeoutSeconds: TimeInterval = 15
  static func outcome(
    didConnect: Bool,
    didFailToConnect: Bool,
    didTimeout: Bool,
    cancellationReason: String?
  ) -> CameraVendorBleConnectAttemptOutcome {
    if didConnect {
      return .connected
    }
    if didFailToConnect {
      return .failed
    }
    if didTimeout {
      return .timedOut
    }
    if let cancellationReason {
      if cancellationReason == "superseded" {
        return .superseded(reason: cancellationReason)
      }
      return .cancelled(reason: cancellationReason)
    }
    return .failed
  }

  static func shouldAttemptRestrictedReconnect(
    outcome: CameraVendorBleConnectAttemptOutcome,
    hasRememberedCamera: Bool
  ) -> Bool {
    hasRememberedCamera && outcome == .timedOut
  }

  static func shouldKeepPairingRegistration(
    outcome: CameraVendorBleConnectAttemptOutcome
  ) -> Bool {
    switch outcome {
    case .failed, .timedOut, .cancelled, .superseded:
      return true
    case .connected:
      return false
    }
  }
}

private enum CameraVendorBleConnectPurpose: String {
  case freshPairing
  case rememberedDirect
  case rememberedScan
  case phoneConfirmation
  case secureHandshakeRecovery
  case activationRecovery
}

enum CameraVendorActivationDisconnectDisposition: Equatable {
  case proceedToWifi
  case recoverPhase
  case activationDisconnected
}

enum CameraVendorActivationDisconnectPolicy {
  static func disposition(
    observedTransferReady: Bool,
    recoveryAttempts: Int,
    maxRecoveryAttempts: Int
  ) -> CameraVendorActivationDisconnectDisposition {
    if observedTransferReady {
      return .proceedToWifi
    }
    if recoveryAttempts < maxRecoveryAttempts {
      return .recoverPhase
    }
    return .activationDisconnected
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

enum CameraVendorActivationStrategyExecutor {
  static func execute(
    definition: ActivationStrategyDefinition,
    emit: (CameraVendorBleWriteRequest) -> Void
  ) {
    for step in definition.writeSteps {
      emit(
        CameraVendorBleWriteRequest(
          characteristicUUIDString: step.characteristicUUIDString,
          payload: step.payload
        )
      )
    }
  }

  static func isTrackedStatusCharacteristic(
    uuidString: String,
    definition: ActivationStrategyDefinition
  ) -> Bool {
    let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return definition.trackedStatusCharacteristicUUIDStrings.contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalized
    }
  }

  static func isComplete(
    definition: ActivationStrategyDefinition,
    uuidString: String,
    value: Data
  ) -> Bool {
    switch definition.completionPredicate {
    case .apStateReadyToJoinWifi:
      let normalized = uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      guard normalized
        == CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        let apState = CameraVendorReferenceAppApState(data: value)
      else {
        return false
      }
      return apState.isReadyToJoinWifi
    }
  }
}

enum CameraVendorActivationRetryDecision: Equatable {
  case retryInternally(nextAttempt: Int)
  case failClosed(owner: CameraConnectionRetryOwner)
  case attemptBudgetExhausted
}

enum CameraVendorActivationRetryExecutor {
  static func decision(
    retryTiming: ActivationRetryTimingPolicy,
    completedAttempts: Int
  ) -> CameraVendorActivationRetryDecision {
    guard completedAttempts < retryTiming.maxAttempts else {
      return .attemptBudgetExhausted
    }
    guard retryTiming.retryOwner == .activationStrategy else {
      return .failClosed(owner: retryTiming.retryOwner)
    }
    return .retryInternally(nextAttempt: completedAttempts + 1)
  }
}

enum CameraVendorActivationAttemptResponse: Equatable {
  case responded
  case noResponse
}

enum CameraVendorActivationAttemptDecision: Equatable {
  case proceedToGallery
  case retryInternally(nextAttempt: Int)
  case failClosed(owner: CameraConnectionRetryOwner)
  case terminateNotReady(response: CameraVendorActivationAttemptResponse)
}

enum CameraVendorActivationAttemptExecutor {
  static func decision(
    observedChange: Bool,
    cameraResponded: Bool,
    retryDecision: CameraVendorActivationRetryDecision
  ) -> CameraVendorActivationAttemptDecision {
    if observedChange {
      return .proceedToGallery
    }
    switch retryDecision {
    case .retryInternally(let nextAttempt):
      return .retryInternally(nextAttempt: nextAttempt)
    case .failClosed(let owner):
      return .failClosed(owner: owner)
    case .attemptBudgetExhausted:
      return .terminateNotReady(response: cameraResponded ? .responded : .noResponse)
    }
  }
}

struct CameraVendorActivationAttemptToken: Equatable {
  let peripheralID: UUID
  let generation: UInt64
}

struct CameraVendorBluetoothResetToken: Equatable {
  let peripheralID: UUID
  let peripheralIdentity: ObjectIdentifier
  let generation: UInt64
  let resetNonce: UUID
}

struct CameraVendorPairingProbeTeardownToken: Equatable {
  let peripheralID: UUID
  let peripheralIdentity: ObjectIdentifier
  let generation: UInt64
  let teardownNonce: UUID
}

final class CameraVendorPairingProbeTeardownGate {
  typealias TimeoutCancellation = () -> Void
  typealias TimeoutScheduler = (
    TimeInterval,
    @escaping () -> Void
  ) -> TimeoutCancellation

  private final class PendingTeardown {
    let token: CameraVendorPairingProbeTeardownToken
    var continuation: CheckedContinuation<Bool, Never>?
    var cancelTimeout: TimeoutCancellation?

    init(
      token: CameraVendorPairingProbeTeardownToken,
      continuation: CheckedContinuation<Bool, Never>
    ) {
      self.token = token
      self.continuation = continuation
    }
  }

  private let lock = NSLock()
  private let timeoutScheduler: TimeoutScheduler
  private var unresolvedTeardown: PendingTeardown?

  init(
    timeoutScheduler: @escaping TimeoutScheduler = { timeoutSeconds, handler in
      let workItem = DispatchWorkItem(block: handler)
      DispatchQueue.main.asyncAfter(
        deadline: .now() + timeoutSeconds,
        execute: workItem
      )
      return { workItem.cancel() }
    }
  ) {
    self.timeoutScheduler = timeoutScheduler
  }

  var hasUnresolvedDisconnect: Bool {
    lock.withLock { unresolvedTeardown != nil }
  }

  func matchesUnresolvedDisconnect(
    peripheralID: UUID,
    peripheralIdentity: ObjectIdentifier
  ) -> Bool {
    lock.withLock {
      unresolvedTeardown?.token.peripheralID == peripheralID
        && unresolvedTeardown?.token.peripheralIdentity == peripheralIdentity
    }
  }

  func teardown(
    token: CameraVendorPairingProbeTeardownToken?,
    timeoutSeconds: TimeInterval,
    cancelConnection: @escaping () -> Void
  ) async -> Bool {
    guard let token else {
      return !hasUnresolvedDisconnect
    }

    return await withCheckedContinuation { continuation in
      let pending = PendingTeardown(token: token, continuation: continuation)
      let accepted: Bool
      lock.lock()
      if unresolvedTeardown == nil {
        unresolvedTeardown = pending
        accepted = true
      } else {
        accepted = false
      }
      lock.unlock()
      guard accepted else {
        continuation.resume(returning: false)
        return
      }

      let cancelTimeout = timeoutScheduler(timeoutSeconds) { [weak self] in
        self?.timeout(teardownNonce: pending.token.teardownNonce)
      }
      var shouldCancelTimeout = false
      lock.lock()
      if unresolvedTeardown === pending, pending.continuation != nil {
        pending.cancelTimeout = cancelTimeout
      } else {
        shouldCancelTimeout = true
      }
      lock.unlock()
      if shouldCancelTimeout {
        cancelTimeout()
      }

      cancelConnection()
    }
  }

  @discardableResult
  func completeDisconnect(
    peripheralID: UUID,
    peripheralIdentity: ObjectIdentifier
  ) -> CameraVendorPairingProbeTeardownToken? {
    let pending: PendingTeardown?
    lock.lock()
    if unresolvedTeardown?.token.peripheralID == peripheralID,
       unresolvedTeardown?.token.peripheralIdentity == peripheralIdentity {
      pending = unresolvedTeardown
      unresolvedTeardown = nil
    } else {
      pending = nil
    }
    lock.unlock()
    guard let pending else { return nil }
    pending.cancelTimeout?()
    pending.continuation?.resume(returning: true)
    pending.continuation = nil
    return pending.token
  }

  private func timeout(teardownNonce: UUID) {
    let continuation: CheckedContinuation<Bool, Never>?
    lock.lock()
    if unresolvedTeardown?.token.teardownNonce == teardownNonce {
      continuation = unresolvedTeardown?.continuation
      // The system may omit a late disconnect callback for a cancelled probe.
      // Release the probe-owned gate after the bounded wait so a user-initiated
      // mainline connection is never blocked indefinitely. Any later callback
      // is treated as an orphan by the mainline ownership checks.
      unresolvedTeardown = nil
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(returning: false)
  }
}

struct CameraVendorBluetoothConnectionToken: Equatable {
  let peripheralID: UUID
  let peripheralIdentity: ObjectIdentifier
  let generation: UInt64
}

enum CameraVendorBluetoothDisconnectRoute: Equatable {
  case activeMainline(generation: UInt64)
  case orphan
}

enum CameraVendorBluetoothDisconnectOwnershipPolicy {
  static func route(
    peripheralID: UUID,
    peripheralIdentity: ObjectIdentifier,
    activeMainlineToken: CameraVendorBluetoothConnectionToken?
  ) -> CameraVendorBluetoothDisconnectRoute {
    guard let activeMainlineToken,
          activeMainlineToken.peripheralID == peripheralID,
          activeMainlineToken.peripheralIdentity == peripheralIdentity else {
      return .orphan
    }
    return .activeMainline(generation: activeMainlineToken.generation)
  }
}

final class CameraVendorBluetoothFullResetGate {
  typealias TimeoutCancellation = () -> Void
  typealias TimeoutScheduler = (
    TimeInterval,
    @escaping () -> Void
  ) -> TimeoutCancellation

  private final class PendingReset {
    let token: CameraVendorBluetoothResetToken
    var continuation: CheckedContinuation<CameraCompatibilityLabResetResult, Never>?
    var cancelTimeout: TimeoutCancellation?

    init(
      token: CameraVendorBluetoothResetToken,
      continuation: CheckedContinuation<CameraCompatibilityLabResetResult, Never>
    ) {
      self.token = token
      self.continuation = continuation
    }
  }

  private let lock = NSLock()
  private let timeoutScheduler: TimeoutScheduler
  private var unresolvedReset: PendingReset?

  init(
    timeoutScheduler: @escaping TimeoutScheduler = { timeoutSeconds, handler in
      let workItem = DispatchWorkItem(block: handler)
      DispatchQueue.main.asyncAfter(
        deadline: .now() + timeoutSeconds,
        execute: workItem
      )
      return { workItem.cancel() }
    }
  ) {
    self.timeoutScheduler = timeoutScheduler
  }

  var hasUnresolvedDisconnect: Bool {
    lock.withLock { unresolvedReset != nil }
  }

  func reset(
    token: CameraVendorBluetoothResetToken?,
    timeoutSeconds: TimeInterval,
    cancelConnection: @escaping () -> Void
  ) async -> CameraCompatibilityLabResetResult {
    guard let token else {
      return hasUnresolvedDisconnect ? .failed : .succeeded
    }

    return await withCheckedContinuation { continuation in
      let pending = PendingReset(token: token, continuation: continuation)
      let accepted: Bool
      lock.lock()
      if unresolvedReset == nil {
        unresolvedReset = pending
        accepted = true
      } else {
        accepted = false
      }
      lock.unlock()
      guard accepted else {
        continuation.resume(returning: .failed)
        return
      }

      let cancelTimeout = timeoutScheduler(timeoutSeconds) { [weak self] in
        self?.timeout(resetNonce: pending.token.resetNonce)
      }
      var shouldCancelTimeout = false
      lock.lock()
      if unresolvedReset === pending, pending.continuation != nil {
        pending.cancelTimeout = cancelTimeout
      } else {
        shouldCancelTimeout = true
      }
      lock.unlock()
      if shouldCancelTimeout {
        cancelTimeout()
      }

      cancelConnection()
    }
  }

  @discardableResult
  func completeDisconnect(
    peripheralID: UUID,
    peripheralIdentity: ObjectIdentifier
  ) -> CameraVendorBluetoothResetToken? {
    let pending: PendingReset?
    lock.lock()
    if unresolvedReset?.token.peripheralID == peripheralID,
       unresolvedReset?.token.peripheralIdentity == peripheralIdentity {
      pending = unresolvedReset
      unresolvedReset = nil
    } else {
      pending = nil
    }
    lock.unlock()
    guard let pending else { return nil }
    pending.cancelTimeout?()
    pending.continuation?.resume(returning: .succeeded)
    pending.continuation = nil
    return pending.token
  }

  private func timeout(resetNonce: UUID) {
    let continuation: CheckedContinuation<CameraCompatibilityLabResetResult, Never>?
    lock.lock()
    if unresolvedReset?.token.resetNonce == resetNonce {
      continuation = unresolvedReset?.continuation
      unresolvedReset?.continuation = nil
      unresolvedReset?.cancelTimeout = nil
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(returning: .failed)
  }
}

struct CameraVendorActivationWriteToken: Equatable {
  let attempt: CameraVendorActivationAttemptToken
  let characteristicIdentity: ObjectIdentifier
}

enum CameraVendorActivationAttemptCallbackDecision: Equatable {
  case accept
  case ignoreMissingToken
  case ignoreMismatch
}

enum CameraVendorActivationAttemptCallbackGate {
  static func decision(
    callbackToken: CameraVendorActivationWriteToken?,
    activeToken: CameraVendorActivationAttemptToken?,
    callbackCharacteristicIdentity: ObjectIdentifier
  ) -> CameraVendorActivationAttemptCallbackDecision {
    guard let callbackToken else {
      return .ignoreMissingToken
    }
    guard callbackToken.attempt == activeToken,
          callbackToken.characteristicIdentity == callbackCharacteristicIdentity else {
      return .ignoreMismatch
    }
    return .accept
  }
}

struct CameraVendorActivationStepAcknowledgement: Equatable {
  let role: ActivationWriteStepRole
  let postWriteDelaySeconds: TimeInterval
}

struct CameraVendorActivationStepDriver {
  private let definition: ActivationStrategyDefinition
  private var currentStepIndex = 0

  init(definition: ActivationStrategyDefinition) {
    self.definition = definition
  }

  var currentWriteRequest: CameraVendorBleWriteRequest? {
    guard definition.writeSteps.indices.contains(currentStepIndex) else {
      return nil
    }
    let step = definition.writeSteps[currentStepIndex]
    return CameraVendorBleWriteRequest(
      characteristicUUIDString: step.characteristicUUIDString,
      payload: step.payload
    )
  }

  var acknowledgementTimeoutSeconds: TimeInterval {
    definition.retryTiming.acknowledgementTimeoutSeconds
  }

  var responseProgressTimeoutSeconds: TimeInterval {
    definition.retryTiming.responseProgressTimeoutSeconds
  }

  var maxAttempts: Int {
    definition.retryTiming.maxAttempts
  }

  var isComplete: Bool {
    currentStepIndex >= definition.writeSteps.count
  }

  func isCurrentWriteCharacteristic(uuidString: String) -> Bool {
    guard let currentWriteRequest else { return false }
    return currentWriteRequest.characteristicUUIDString.uppercased()
      == uuidString.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  mutating func acknowledgeCurrentWrite(
    characteristicUUIDString: String
  ) -> CameraVendorActivationStepAcknowledgement? {
    guard isCurrentWriteCharacteristic(uuidString: characteristicUUIDString),
          definition.writeSteps.indices.contains(currentStepIndex)
    else {
      return nil
    }
    let role = definition.writeSteps[currentStepIndex].role
    currentStepIndex += 1
    return CameraVendorActivationStepAcknowledgement(
      role: role,
      postWriteDelaySeconds: role == .imageResizeSetting
        ? CameraVendorTransferActivationResizePolicy.postWriteDelaySeconds
        : 0
    )
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

  static func writes(
    for strategy: CameraVendorReferenceAppTransferActivationStrategy,
    activationDefinition: ActivationStrategyDefinition
  ) -> [CameraVendorBleWriteRequest] {
    switch strategy {
    case .officialImportImage:
      var requests: [CameraVendorBleWriteRequest] = []
      CameraVendorActivationStrategyExecutor.execute(definition: activationDefinition) {
        requests.append($0)
      }
      return requests
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
        return false
      }
      return UserDefaults.standard.bool(forKey: preferenceKey)
    }
    set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
  }

  static var currentPayload: Data {
    preferCompressedDownloads ? resizeEnabledPayload : resizeDisabledPayload
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

typealias CameraVendorGalleryFormatHint = CameraGalleryFormatHint

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

typealias CameraVendorGalleryItem = CameraGalleryCatalogItem

enum CameraVendorCatalogPlaceholderPolicy {
  static func placeholderItems(
    from handles: [UInt32],
    dateGroups: [CameraVendorSpecifiedObjectDateGroup] = [],
    formatHintsByHandle: [Int: Set<CameraVendorGalleryFormatHint>] = [:]
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
        byteSizeText: "",
        formatHints: formatHintsByHandle[Int(handle), default: []]
      )
    }
  }

  static func expandedStillFormatHints(
    baselineHandles: [UInt32],
    expandedStillHandles: [UInt32]
  ) -> [Int: Set<CameraVendorGalleryFormatHint>] {
    let baseline = Set(baselineHandles)
    return Dictionary(uniqueKeysWithValues: expandedStillHandles.compactMap { handle in
      guard !baseline.contains(handle) else { return nil }
      return (Int(handle), Set([CameraVendorGalleryFormatHint.extendedStillCandidate]))
    })
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
    return CameraTransportFailureDispositionPolicy.disposition(
      for: error,
      context: .backgroundMetadata
    ) == .sessionTerminal
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
  func fetchInitialCameraCatalog(
    query: CameraVendorCatalogQuery?
  ) async throws -> CameraVendorCatalogSnapshot
  func fetchExpandedCameraCatalog() async throws -> CameraVendorCatalogSnapshot
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
  let objectInfo: CameraVendorCameraObjectInfo?

  init(
    data: Data,
    item: CameraVendorGalleryItem?,
    objectInfo: CameraVendorCameraObjectInfo? = nil
  ) {
    self.data = data
    self.item = item
    self.objectInfo = objectInfo
  }
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
  func fetchInitialCameraCatalog(
    query: CameraVendorCatalogQuery?
  ) async throws -> CameraVendorCatalogSnapshot {
    if let query {
      return try await fetchCameraCatalog(query: query)
    }
    return try await fetchInitialCameraCatalog()
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraVendorGalleryService",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持读取初始目录"]
    )
  }

  func fetchExpandedCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    throw NSError(
      domain: "CameraVendorGalleryService",
      code: NSURLErrorUnsupportedURL,
      userInfo: [NSLocalizedDescriptionKey: "当前相机服务不支持读取普通全量目录"]
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
    CameraVendorGalleryThumbnail(data: try await fetchThumbnail(for: handle), item: nil, objectInfo: nil)
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



enum CameraVendorCameraWifiConnector {
  private static func interfaceSnapshot() -> (interface: String?, ipv4: String?, gateway: String?) {
    var interfaces: String?
    var ipv4: String?
    var fallbackInterface: String?
    var fallbackIPv4: String?
    var cursor: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&cursor) == 0 else { return (nil, nil, nil) }
    // `cursor` is advanced while walking the linked list. Keep the original
    // head for `freeifaddrs`; freeing the advanced pointer causes a real-device
    // SIGABRT (`pointer being freed was not allocated`) during Wi-Fi handoff.
    let listHead = cursor
    defer { freeifaddrs(listHead) }
    while let current = cursor {
      let flags = current.pointee.ifa_flags
      if (flags & UInt32(IFF_UP)) != 0,
         let namePointer = current.pointee.ifa_name,
         String(cString: namePointer) != "lo0",
         let address = current.pointee.ifa_addr,
         address.pointee.sa_family == UInt8(AF_INET) {
        let name = String(cString: namePointer)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var addressCopy = address.pointee
        getnameinfo(
          &addressCopy,
          socklen_t(address.pointee.sa_len),
          &host,
          socklen_t(host.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        let addressText = String(cString: host)
        // Wi-Fi handoff evidence must come from en0. On cellular devices
        // getifaddrs commonly lists pdp_ip0 first; treating it as the active
        // camera interface produces a false-positive network snapshot.
        if name == "en0" {
          interfaces = name
          ipv4 = addressText
          break
        }
        if !name.hasPrefix("pdp_") && fallbackInterface == nil {
          fallbackInterface = name
          fallbackIPv4 = addressText
        }
      }
      cursor = current.pointee.ifa_next
    }
    if interfaces == nil {
      interfaces = fallbackInterface
      ipv4 = fallbackIPv4
    }
    return (interfaces, ipv4, nil)
  }

  static func currentAssociationSnapshot(
    diagnosticHandler: ((String) -> Void)? = nil
  ) async -> (currentSSID: String?, isCameraPtpReachable: Bool) {
    let currentSSID = await fetchCurrentSSID()
    let isCameraPtpReachable = await Task.detached(priority: .utility) {
      CameraVendorCameraPtpReachabilityProbe.isReachable()
    }.value
    let network = interfaceSnapshot()
    diagnosticHandler?(
      "Wi-Fi 预检查: ssid=\(currentSSID ?? "<nil>"), interface=\(network.interface ?? "<nil>"), ipv4=\(network.ipv4 ?? "<nil>"), gateway=\(network.gateway ?? "<nil>"), routeToCamera=\(isCameraPtpReachable)"
    )
    diagnosticHandler?("[OBS] PTP_REACHABILITY_RESULT host=\(CameraVendorPtpConstants.defaultHost) port=\(CameraVendorPtpConstants.commandPort) interface=\(network.interface ?? "<nil>") ipv4=\(network.ipv4 ?? "<nil>") gateway=\(network.gateway ?? "<nil>") routeToCamera=\(isCameraPtpReachable)")
    return (currentSSID, isCameraPtpReachable)
  }

  static func join(
    configuration: CameraVendorWifiNetworkConfiguration,
    allowUnverifiedAssociationAfterRecoverableError: Bool = false,
    diagnosticHandler: ((String) -> Void)? = nil
  ) async throws {
    let report: (String) -> Void = { message in
      if let diagnosticHandler {
        diagnosticHandler(message)
      } else {
        CameraVendorGalleryDiagnostics.log(message)
      }
    }
    let hotspotConfiguration = NEHotspotConfiguration(
      ssid: configuration.ssid,
      passphrase: configuration.passphrase,
      isWEP: false
    )
    hotspotConfiguration.joinOnce = false
    hotspotConfiguration.hidden = configuration.isHidden

    report(
      "尝试连接 Wi-Fi: \(configuration.ssid) " +
      "(hidden=\(configuration.isHidden), passphraseLength=\(configuration.passphrase.count))"
    )
    report(
      "[OBS] WIFI_JOIN_START ssid=\(configuration.ssid) hidden=\(configuration.isHidden) " +
      "passphraseLength=\(configuration.passphrase.count)"
    )
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
      let network = interfaceSnapshot()
      diagnosticHandler?("当前 Wi-Fi: \(currentSSID ?? "<nil>") interface=\(network.interface ?? "<nil>") ipv4=\(network.ipv4 ?? "<nil>") gateway=\(network.gateway ?? "<nil>") routeToCamera=unknown")

      if let currentSSID, currentSSID == targetSSID {
        diagnosticHandler?("Wi-Fi 已切换到相机热点: \(targetSSID)")
        diagnosticHandler?("[OBS] WIFI_ASSOCIATED ssid=\(targetSSID) interface=\(network.interface ?? "<nil>") ipv4=\(network.ipv4 ?? "<nil>") gateway=\(network.gateway ?? "<nil>")")
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
    let network = interfaceSnapshot()
    if CameraVendorWifiAssociationReadiness.isReadyToProceed(
      targetSSID: targetSSID,
      currentSSID: currentSSID,
      isCameraPtpReachable: false
    ) {
      diagnosticHandler?("等待 Wi-Fi SSID 匹配超时前已确认相机网络")
      return
    }

    diagnosticHandler?("等待 Wi-Fi SSID 匹配超时，未执行 PTP 预探测 interface=\(network.interface ?? "<nil>") ipv4=\(network.ipv4 ?? "<nil>") gateway=\(network.gateway ?? "<nil>") routeToCamera=unknown")
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

enum CameraVendorCameraPtpReachabilityProbe {
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
  let admission: CameraVendorAdvertisementAdmission
  let advertisedServiceUUIDs: Set<String>

  init(
    id: UUID,
    name: String,
    rssi: Int,
    appVariant: CameraVendorAppVariant,
    pairingToken: Data?,
    matchDetails: String,
    admission: CameraVendorAdvertisementAdmission,
    advertisedServiceUUIDs: Set<String> = []
  ) {
    self.id = id
    self.name = name
    self.rssi = rssi
    self.appVariant = appVariant
    self.pairingToken = pairingToken
    self.matchDetails = matchDetails
    self.admission = admission
    self.advertisedServiceUUIDs = advertisedServiceUUIDs
  }
}

enum CameraVendorAdvertisementAdmission: Equatable {
  case generic
  case rememberedRedReconnect
}

struct CameraVendorAdvertisementMatch: Equatable {
  let resolvedName: String
  let appVariant: CameraVendorAppVariant
  let pairingToken: Data?
  let reasons: [String]
  let admission: CameraVendorAdvertisementAdmission
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

    let hasKnownServiceMatch = reasons.contains(where: { $0.hasPrefix("service:") })
    let hasVerifiedManufacturerFraming = manufacturerData.map {
      $0.count >= 7 && $0[0] == 0xD8 && $0[1] == 0x04 && $0[2] == 0x02
    } ?? false
    let hasPositivePrimaryMatch = hasKnownServiceMatch || hasVerifiedManufacturerFraming

    guard hasPositivePrimaryMatch else {
      return nil
    }

    let resolvedName = normalizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = resolvedName.flatMap { $0.isEmpty ? nil : $0 } ?? "CAMERA_VENDOR"

    return CameraVendorAdvertisementMatch(
      resolvedName: displayName,
      appVariant: appVariant,
      pairingToken: token,
      reasons: reasons,
      admission: .generic
    )
  }

  static func matchRememberedRedReconnectAdvertisement(
    name: String?,
    observedPeripheralID: UUID,
    rememberedPeripheralID: UUID?,
    rememberedAppVariant: CameraVendorAppVariant,
    serviceUUIDs: [String],
    manufacturerData: Data?
  ) -> CameraVendorAdvertisementMatch? {
    guard CameraVendorRememberedRedReconnectAdmissionPolicy.shouldAdmit(
      observedPeripheralID: observedPeripheralID,
      rememberedPeripheralID: rememberedPeripheralID,
      serviceUUIDs: serviceUUIDs
    ) else {
      return nil
    }

    let displayName = normalizedName(name).flatMap { $0.isEmpty ? nil : $0 } ?? "CAMERA_VENDOR"
    return CameraVendorAdvertisementMatch(
      resolvedName: displayName,
      appVariant: rememberedAppVariant,
      pairingToken: pairingToken(from: manufacturerData),
      reasons: ["remembered-endpoint", "service:ConnectedDeviceInformationRED"],
      admission: .rememberedRedReconnect
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

extension CameraDiagnosticPayloadSummary {
  static func manufacturerAdvertisement(_ manufacturerData: Data?) -> String {
    guard let manufacturerData else {
      return "family=absent length=0 redacted=true fingerprint=none"
    }

    let family: String
    if manufacturerData.count < 3 {
      family = "truncated"
    } else if manufacturerData[0] == 0xD8,
              manufacturerData[1] == 0x04,
              manufacturerData[2] == 0x02 {
      family = "fujifilm-pairing"
    } else if manufacturerData[0] == 0x02 {
      family = "legacy-pairing"
    } else if manufacturerData[0] == 0xD8,
              manufacturerData[1] == 0x04 {
      family = "fujifilm-other"
    } else {
      family = "unknown"
    }

    var fingerprintInput = Data("family=\(family)|length=\(manufacturerData.count)|".utf8)
    switch family {
    case "fujifilm-pairing":
      var structuralData = manufacturerData
      for index in 3..<min(7, structuralData.count) {
        structuralData[index] = 0
      }
      fingerprintInput.append(structuralData)
    case "legacy-pairing":
      var structuralData = manufacturerData
      for index in 1..<min(5, structuralData.count) {
        structuralData[index] = 0
      }
      fingerprintInput.append(structuralData)
    case "fujifilm-other":
      fingerprintInput.append(contentsOf: manufacturerData.prefix(3))
    case "truncated", "unknown":
      break
    default:
      break
    }

    let fingerprint = SHA256.hash(data: fingerprintInput)
      .prefix(8)
      .map { String(format: "%02x", $0) }
      .joined()
    return "family=\(family) length=\(manufacturerData.count) " +
      "redacted=true fingerprint=\(fingerprint)"
  }
}

final class CameraVendorLogStore {
  private let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var recentLines: [String] = []
  private let maxMemoryLineCount = 1500

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    fileURL = baseURL.appendingPathComponent("cameraVendor-fast-debug.log")
  }

  var currentContents: String {
    lock.lock()
    let lines = recentLines
    lock.unlock()
    if !lines.isEmpty {
      return lines.joined(separator: "\n")
    }
    return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
  }

  var currentFileURL: URL {
    fileURL
  }

  func clear() {
    lock.lock()
    recentLines.removeAll()
    lock.unlock()
    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    for index in 1...CameraVendorFileLogPolicy.maxArchiveLogCount {
      try? fileManager.removeItem(at: archivedFileURL(index: index))
    }
  }

  func append(_ line: String, writesToDisk: Bool = true) {
    lock.lock()
    recentLines.append(line)
    if recentLines.count > maxMemoryLineCount {
      recentLines.removeFirst(recentLines.count - maxMemoryLineCount)
    }
    lock.unlock()
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
  private let policyRevision = "xm5-connection-terminal-v1"
  private let pairServiceUUID = CBUUID(string: "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8")
  private let pairingCharacteristicUUID = CBUUID(string: "ABA356EB-9633-4E60-B73F-F52516DBD671")
  private let connectedDeviceNameCharacteristicUUID = CBUUID(string: "85B9163E-62D1-49FF-A6F5-054B4630D4A1")
  private let connectedApplicationInfoCharacteristicUUID = CBUUID(
    string: CameraVendorConnectedApplicationHandshakePolicy.characteristicUUIDString
  )
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
  private var connectedApplicationInfoCharacteristic: CBCharacteristic?
  private var discoveredCharacteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
  private var notifiableCharacteristics: [CBCharacteristic] = []
  private var probedCharacteristics: [CBUUID: CBCharacteristic] = [:]
  private var observedCharacteristicValues: [String: Data] = [:]
  private var unmatchedAdvertisementSampleKeys: Set<String> = []
  private var unmatchedAdvertisementSampleCount = 0
  private var recognizedRememberedAdvertisementCount = 0
  private var rememberedEndpointFoundNotReady = false
  private var scanTimeoutWorkItem: DispatchWorkItem?
  private var bleConnectTimeoutWorkItem: DispatchWorkItem?
  private var bleConnectAttemptGeneration: UInt64?
  private var bleConnectAttemptPeripheralID: UUID?
  private var bleConnectAttemptPeripheralIdentity: ObjectIdentifier?
  private var bleConnectAttemptStartedAt: CFAbsoluteTime?
  private var scanStartedAt: CFAbsoluteTime?
  private var postHandshakeProbeTimeoutWorkItem: DispatchWorkItem?
  private var connectedApplicationInfoTimeoutWorkItem: DispatchWorkItem?
  private var transferActivationTimeoutWorkItem: DispatchWorkItem?
  private var bleStateSamplingWorkItems: [DispatchWorkItem] = []
  private var bleStateSamplingCompletionWorkItem: DispatchWorkItem?
  private var reservedImageReceiveProbeWorkItems: [DispatchWorkItem] = []
  private var hasScheduledReservedImageReceiveProbe = false
  private var transferActivationTimeoutSetAt: CFAbsoluteTime = 0
  private var discoveredName: String?
  private var discoveredSerialNumber: String?
  private var discoveredFirmwareVersion: String?
  private var discoveredServiceUUIDStrings: Set<String> = []
  private var pendingRememberedRedReconnectIdentityRejectionReason:
    CameraVendorRememberedRedReconnectIdentityRejectionReason?
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
  private var transferActivationStepDriver: CameraVendorActivationStepDriver?
  private var currentTransferActivationStrategy: CameraVendorReferenceAppTransferActivationStrategy?
  private var activeActivationDefinition: ActivationStrategyDefinition?
  private var activeActivationResolver: (
    (CameraCompatibilityFacts) throws -> ActivationStrategyDefinition
  )?
  private var rememberedGalleryTerminalOwner: CameraVendorRememberedGalleryTerminalOwner?
  private var activationResolutionGate = CameraVendorGattActivationResolutionGate()
  private var transferActivationWritePayloadsByUUID: [String: Data] = [:]
  private var isRunningTransferActivation = false
  private var hasAttemptedAutomaticTransferActivation = false
  private var transferActivationAttemptCount = 0
  private var activationDisconnectRecoveryCount = 0
  private let maxActivationDisconnectRecoveryAttempts = 1
  private var activationAttemptGeneration: UInt64 = 0
  private var activeActivationAttemptToken: CameraVendorActivationAttemptToken?
  private var transferActivationWriteAttemptTokensByCharacteristicIdentity: [ObjectIdentifier: CameraVendorActivationWriteToken] = [:]
  private let fullResetGate = CameraVendorBluetoothFullResetGate()
  private let pairingProbeTeardownGate = CameraVendorPairingProbeTeardownGate()
  private var wirelessConnectionGeneration: UInt64 = 0
  private var bleWriteSequence: UInt64 = 0
  private var pendingBleWriteRequestIDsByCharacteristic: [ObjectIdentifier: String] = [:]
  private var activeBluetoothConnectionToken: CameraVendorBluetoothConnectionToken?
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
  private var connectedApplicationInfoWriteGeneration: UInt64?
  private var completedConnectedApplicationInfoGeneration: UInt64?
  private var rememberedPairedCameras: [CameraVendorPairedCameraRecord]
  private var rememberedPairedCamera: CameraVendorPairedCameraRecord?
  private var autoReconnectTargetPeripheralID: UUID?
  private var shouldAutoReconnectRememberedCamera = false
  private var isNextRememberedCameraConnectionUserApproved = false

  // MARK: - Pairing Probe (silent BLE validation on app launch)
  private var pairingProbeState: CameraVendorPairingProbeState = .idle
  private var pairingProbeContinuation: CheckedContinuation<CameraVendorPairingProbeResult, Never>?
  private var pairingProbeWaiters: [CheckedContinuation<CameraVendorPairingProbeResult, Never>] = []
  private var pairingProbePendingTeardownResult: CameraVendorPairingProbeResult?
  private var pairingProbeTimeoutWorkItem: DispatchWorkItem?
  private var pairingProbePeripheral: CBPeripheral?
  private var pairingProbeGeneration: UInt64 = 0

  init(pairingStore: CameraVendorPairedCameraStore = CameraVendorPairedCameraStore()) {
    self.pairingStore = pairingStore
    let savedRecords = pairingStore.loadAll()
    self.rememberedPairedCameras = savedRecords
    self.rememberedPairedCamera = savedRecords.first
    super.init()
    appendLog("=== CamTransfer 启动 ===")
    appendLog("运行构建标记: \(buildMarker)")
    appendObservation("CONNECTION_POLICY revision=\(policyRevision)")
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
    CameraVendorFileLogger.logFileURL
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
    CameraVendorGalleryDiagnostics.clearLogFile()
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

  // MARK: - Pairing Probe API

  /// Silently probe whether the remembered camera's BLE pairing is still valid.
  /// Returns the probe result. If successful (.online), the BLE connection is kept
  /// alive for fast gallery entry.
  func probePairing(peripheralID: UUID) async -> CameraVendorPairingProbeResult {
    // Don't probe if a connection flow is already active.
    guard selectedPeripheral == nil,
          autoReconnectTargetPeripheralID == nil,
          !isRunningTransferActivation else {
      return .offline
    }

    guard central.state == .poweredOn else {
      return .bluetoothOff
    }

    // Cancel any existing probe.
    guard await cancelPairingProbeAndWait(reason: "new-probe-requested") else {
      appendObservation("PAIRING_PROBE_BEGIN_BLOCKED unresolvedDisconnect=true")
      return .offline
    }

    appendObservation("PAIRING_PROBE_BEGIN peripheralID=\(peripheralID.uuidString)")
    pairingProbeGeneration &+= 1
    appendObservation(
      "BLE_SCAN_TARGET purpose=pairingProbe generation=\(pairingProbeGeneration) " +
      "targetPeripheralID=\(peripheralID.uuidString)"
    )

    return await withCheckedContinuation { continuation in
      pairingProbeContinuation = continuation
      pairingProbeState = .connecting(peripheralID: peripheralID)

      // Set timeout.
      let timeoutWork = DispatchWorkItem { [weak self] in
        self?.appendObservation(
          "PAIRING_PROBE_TIMEOUT generation=\(self?.pairingProbeGeneration ?? 0) " +
          "targetPeripheralID=\(peripheralID.uuidString)"
        )
        self?.completePairingProbe(result: .offline, reason: "timeout")
      }
      pairingProbeTimeoutWorkItem = timeoutWork
      DispatchQueue.main.asyncAfter(
        deadline: .now() + CameraVendorPairingProbePolicy.timeoutSeconds,
        execute: timeoutWork
      )

      // Try system retrieve first (faster than scanning).
      if CameraVendorPairingProbePolicy.shouldTrySystemRetrieveFirst {
        let peripherals = central.retrievePeripherals(withIdentifiers: [peripheralID])
        if let peripheral = peripherals.first {
          pairingProbePeripheral = peripheral
          peripheral.delegate = self
          central.connect(peripheral, options: nil)
          return
        }
      }

      // Fall back to scanning.
      pairingProbeState = .scanning(peripheralID: peripheralID)
      central.scanForPeripherals(
        withServices: nil,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
      )
    }
  }

  /// Whether the probe has successfully pre-connected and the BLE link is ready.
  var hasPreconnectedProbe: Bool {
    pairingProbeState.preconnectedPeripheralID != nil
  }

  /// Returns the pre-connected peripheral ID if probe succeeded.
  var preconnectedProbePeripheralID: UUID? {
    pairingProbeState.preconnectedPeripheralID
  }

  func waitForPairingProbeCompletion(peripheralID: UUID) async -> CameraVendorPairingProbeResult? {
    if pairingProbeState.preconnectedPeripheralID == peripheralID { return .online }
    guard pairingProbeState.targetPeripheralID == peripheralID,
          pairingProbeState.isActive else { return nil }
    return await withCheckedContinuation { continuation in
      pairingProbeWaiters.append(continuation)
    }
  }

  /// Consume the pre-connected state — transition probe back to idle.
  /// The BLE connection remains; caller takes ownership.
  func consumePreconnectedProbe() -> CBPeripheral? {
    guard case .preconnected = pairingProbeState,
          let peripheral = pairingProbePeripheral else {
      return nil
    }
    pairingProbeState = .idle
    pairingProbePeripheral = nil
    appendObservation("PAIRING_PROBE_CONSUMED peripheralID=\(peripheral.identifier.uuidString)")
    return peripheral
  }

  func adoptPreconnectedProbe(peripheralID: UUID) -> Bool {
    guard case .preconnected(let probeID) = pairingProbeState,
          probeID == peripheralID,
          let peripheral = pairingProbePeripheral,
          peripheral.identifier == peripheralID else { return false }
    let camera = discoveredCameras.first(where: { $0.id == peripheralID }) ?? CameraVendorDiscoveredCamera(
      id: peripheralID,
      name: rememberedPairedCameras.first(where: { $0.peripheralID == peripheralID })?.deviceName ?? "相机",
      rssi: 0,
      appVariant: rememberedPairedCameras.first(where: { $0.peripheralID == peripheralID })?.appVariant ?? .unknown,
      pairingToken: nil,
      matchDetails: "pairing-probe-adopted",
      admission: .generic
    )
    guard prepareConnectionAttempt(peripheral: peripheral, camera: camera) else { return false }
    pairingProbeState = .idle
    pairingProbePeripheral = nil
    peripheral.delegate = self
    appendObservation("PAIRING_PROBE_ADOPTED peripheralID=\(peripheralID.uuidString)")
    peripheral.discoverServices(nil)
    return true
  }

  /// Cancel any in-progress probe (e.g., when user taps connect).
  func cancelPairingProbe(reason: String) {
    Task { [weak self] in
      _ = await self?.cancelPairingProbeAndWait(reason: reason)
    }
  }

  func cancelPairingProbeAndWait(
    reason: String,
    timeoutSeconds: TimeInterval = 2
  ) async -> Bool {
    guard pairingProbeState.isActive || pairingProbeState.preconnectedPeripheralID != nil else {
      return !pairingProbeTeardownGate.hasUnresolvedDisconnect
    }
    pairingProbeTimeoutWorkItem?.cancel()
    pairingProbeTimeoutWorkItem = nil

    // If we were scanning for the probe, stop.
    if case .scanning = pairingProbeState {
      central.stopScan()
    }

    let previousState = pairingProbeState
    let peripheral = pairingProbePeripheral
    let teardownToken = peripheral.map {
      CameraVendorPairingProbeTeardownToken(
        peripheralID: $0.identifier,
        peripheralIdentity: ObjectIdentifier($0),
        generation: pairingProbeGeneration,
        teardownNonce: UUID()
      )
    }
    pairingProbeState = .idle
    pairingProbePeripheral = nil

    appendObservation("PAIRING_PROBE_CANCELLED reason=\(reason) previousState=\(previousState)")

    // Resume continuation if it's still pending.
    if let continuation = pairingProbeContinuation {
      pairingProbeContinuation = nil
      continuation.resume(returning: .offline)
    }
    let waiters = pairingProbeWaiters
    pairingProbeWaiters.removeAll()
    waiters.forEach { $0.resume(returning: .offline) }

    guard let peripheral, let teardownToken else {
      return true
    }
    let didComplete = await pairingProbeTeardownGate.teardown(
      token: teardownToken,
      timeoutSeconds: timeoutSeconds
    ) { [weak self] in
      self?.central.cancelPeripheralConnection(peripheral)
    }
    appendObservation(
      "PAIRING_PROBE_TEARDOWN_RESULT peripheralID=\(peripheral.identifier.uuidString) " +
      "generation=\(teardownToken.generation) completed=\(didComplete)"
    )
    return didComplete
  }

  private func completePairingProbe(result: CameraVendorPairingProbeResult, reason: String) {
    guard pairingProbeState.isActive else {
      appendObservation("PAIRING_PROBE_COMPLETE_IGNORED result=\(result) reason=\(reason) state=\(pairingProbeState)")
      return
    }
    pairingProbeTimeoutWorkItem?.cancel()
    pairingProbeTimeoutWorkItem = nil

    let hasPeripheralTeardown = pairingProbePeripheral != nil && pairingProbeState.isActive

    if case .scanning = pairingProbeState {
      central.stopScan()
    }

    switch result {
    case .online:
      pairingProbeState = .preconnected(peripheralID: pairingProbePeripheral?.identifier ?? UUID())
      // Keep the peripheral connected for fast gallery entry.
    case .pairingInvalid, .offline, .validationUnavailable, .bluetoothOff:
      if let peripheral = pairingProbePeripheral, pairingProbeState.isActive {
        pairingProbeState = .tearingDown(
          peripheralID: peripheral.identifier,
          result: result
        )
        central.cancelPeripheralConnection(peripheral)
      } else {
        pairingProbeState = .completed(result)
        pairingProbePeripheral = nil
      }
    }

    appendObservation("PAIRING_PROBE_COMPLETE result=\(result) reason=\(reason)")

    if let continuation = pairingProbeContinuation {
      pairingProbeContinuation = nil
      continuation.resume(returning: result)
    }
    if CameraVendorPairingProbeWaiterPolicy.shouldResumeImmediately(
      result: result,
      hasPeripheralTeardown: hasPeripheralTeardown
    ) {
      let waiters = pairingProbeWaiters
      pairingProbeWaiters.removeAll()
      waiters.forEach { $0.resume(returning: result) }
    } else {
      pairingProbePendingTeardownResult = result
    }
  }

  private func completePairingProbeTeardownWaitersIfNeeded() {
    guard let result = pairingProbePendingTeardownResult else { return }
    pairingProbePendingTeardownResult = nil
    let waiters = pairingProbeWaiters
    pairingProbeWaiters.removeAll()
    waiters.forEach { $0.resume(returning: result) }
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
  func startRememberedCameraConnection(
    peripheralID: UUID,
    activationResolver: @escaping (
      CameraCompatibilityFacts
    ) throws -> ActivationStrategyDefinition,
    onRememberedGalleryFailure: @escaping (IOSCameraConnectionIssue) -> Void
  ) -> Bool {
    let startDecision = IOSCameraRememberedConnectionFlowDriver.startRememberedConnection(
      cleanupBlocked: publishSystemBluetoothCleanupBlockIfNeeded(),
      order: IOSCameraConnectionStep.officialGalleryOrder
    )
    guard case .beginMainline(let orderDescription) = startDecision else {
      return false
    }
    appendLog("用户点击进入相机相册，按 Android 主链路编排执行: \(orderDescription)")
    updateStatus("准备进入相机相册", isBusy: true)
    let canAdoptPreconnectedProbe = pairingProbeState.preconnectedPeripheralID == peripheralID
    if !canAdoptPreconnectedProbe {
      resetWirelessCameraFlow()
    }
    activeActivationResolver = activationResolver
    rememberedGalleryTerminalOwner = CameraVendorRememberedGalleryTerminalOwner(
      targetPeripheralID: peripheralID,
      onFailure: onRememberedGalleryFailure
    )
    isNextRememberedCameraConnectionUserApproved = true
    activeWirelessIntent = .rememberedGallery
    if canAdoptPreconnectedProbe, adoptPreconnectedProbe(peripheralID: peripheralID) {
      return true
    }
    return connectPairedCamera(peripheralID: peripheralID)
  }

  func rememberedCompatibilityFacts(peripheralID: UUID) -> CameraCompatibilityFacts? {
    var record = rememberedPairedCameras.first(where: { $0.peripheralID == peripheralID })
    var recordSource = "memory"
    if record == nil {
      let persistedRecords = pairingStore.loadAll()
      rememberedPairedCameras = persistedRecords
      rememberedPairedCamera = persistedRecords.first
      record = persistedRecords.first(where: { $0.peripheralID == peripheralID })
      recordSource = "store-refresh"
    }
    guard let record else {
      appendObservation(
        "REMEMBERED_COMPATIBILITY_FACTS recordFound=false recordSource=\(recordSource) " +
        "bleEndpointEvidence=none"
      )
      return nil
    }
    let observedCamera = discoveredCameras.first(where: { $0.id == peripheralID })
    let observedServices = observedCamera?.advertisedServiceUUIDs ?? []
    let advertisedServices = Set(observedServices.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    })
    let family: CameraCompatibilityFamily?
    if advertisedServices.contains(FujifilmCompatibilityUUID.securePairService) {
      family = .red
    } else if advertisedServices.contains(FujifilmCompatibilityUUID.legacyPairService) {
      family = .legacy
    } else {
      family = nil
    }
    appendObservation(
      "REMEMBERED_COMPATIBILITY_FACTS recordFound=true recordSource=\(recordSource) " +
      "bleEndpointEvidence=rememberedPairedPeripheral " +
      "compatibilityFamily=\(family?.rawValue ?? "unknown") " +
      "advertisedServiceCount=\(advertisedServices.count)"
    )
    return CameraCompatibilityFacts(
      observedIdentity: CameraObservedIdentity(modelName: record.deviceName, firmwareVersion: nil),
      protocolFacts: CameraProtocolFacts(
        compatibilityFamily: family,
        advertisedServices: advertisedServices,
        discoveredCharacteristics: [],
        bleEndpointEvidence: .rememberedPairedPeripheral
      )
    )
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
    cancelBleConnectAttempt(reason: "reset")
    central.stopScan()

    if let peripheral = selectedPeripheral {
      central.cancelPeripheralConnection(peripheral)
    }
    selectedPeripheral = nil
    activeBluetoothConnectionToken = nil
    selectedCamera = nil
    autoReconnectTargetPeripheralID = nil
    connectedApplicationInfoCharacteristic = nil
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    completedConnectedApplicationInfoGeneration = nil
    isRunningTransferActivation = false
    activationDisconnectRecoveryCount = 0
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
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
    currentTransferActivationStrategy = nil
    activeActivationDefinition = nil
    activeActivationResolver = nil
    rememberedGalleryTerminalOwner = nil
    activationResolutionGate = CameraVendorGattActivationResolutionGate()
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
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
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
    guard prepareConnectionAttempt(peripheral: peripheral, camera: camera) else {
      return false
    }
    appendLog("开始连接 \(camera.name) [\(camera.appVariant.rawValue)]")
    if peripheral.state == .connected {
      cancelBleConnectAttempt(reason: "already-connected")
      appendLog("相机 BLE 已连接，直接重新发现服务完成配对确认")
      peripheral.delegate = self
      peripheral.discoverServices(nil)
      return true
    }
    startManagedBleConnect(peripheral, purpose: .phoneConfirmation)
    return true
  }

  private func waitForPhonePairingConfirmation() {
    appendLog("手机端握手已完成，等待用户确认相机端已显示配对成功")
    updateStatus(CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus, isBusy: false)
  }

  private func handleIdentifierWriteCompletion(on peripheral: CBPeripheral) {
    guard continueAfterConnectedApplicationInfoHandshakeIfNeeded(on: peripheral) else {
      return
    }
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

  private func continueAfterConnectedApplicationInfoHandshakeIfNeeded(
    on peripheral: CBPeripheral
  ) -> Bool {
    let availableCharacteristicUUIDs = Set(
      discoveredCharacteristicsByUUID.keys.map { $0.uuidString.uppercased() }
    )
    switch CameraVendorConnectedApplicationHandshakePolicy.action(
      availableCharacteristicUUIDStrings: availableCharacteristicUUIDs
    ) {
    case .completeIdentityHandshake:
      return true
    case .writeApplicationInfo(let payload):
      guard completedConnectedApplicationInfoGeneration != wirelessConnectionGeneration else {
        return true
      }
      guard connectedApplicationInfoWriteGeneration != wirelessConnectionGeneration else {
        appendObservation(
          "BLE_HANDSHAKE_GATE appInfo=required result=waiting generation=\(wirelessConnectionGeneration)"
        )
        return false
      }
      guard let characteristic = connectedApplicationInfoCharacteristic else {
        failConnectedApplicationInfoHandshake("缺少 Connected Application Information 特征")
        return false
      }

      connectedApplicationInfoWriteGeneration = wirelessConnectionGeneration
      secureHandshakePhase = .awaitingConnectedApplicationInfoWrite
      appendObservation(
        "BLE_APP_INFO_WRITE_REQUEST payload=\(hexString(payload)) generation=\(wirelessConnectionGeneration)"
      )
      appendObservation(
        "BLE_HANDSHAKE_GATE appInfo=required result=waiting generation=\(wirelessConnectionGeneration)"
      )
      writeBleControlValue(
        payload,
        to: characteristic,
        on: peripheral,
        kind: "connected-application-info"
      )
      scheduleConnectedApplicationInfoTimeout(
        for: characteristic,
        generation: wirelessConnectionGeneration
      )
      return false
    }
  }

  private func scheduleConnectedApplicationInfoTimeout(
    for characteristic: CBCharacteristic,
    generation: UInt64
  ) {
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak characteristic] in
      guard let self, let characteristic else { return }
      guard self.wirelessConnectionGeneration == generation,
            self.connectedApplicationInfoWriteGeneration == generation,
            self.connectedApplicationInfoCharacteristic === characteristic else {
        return
      }
      self.failConnectedApplicationInfoHandshake("等待 Connected Application Information 写入确认超时")
    }
    connectedApplicationInfoTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + CameraVendorConnectedApplicationHandshakePolicy.writeTimeoutSeconds,
      execute: timeout
    )
  }

  private func completeConnectedApplicationInfoWrite(on peripheral: CBPeripheral) {
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    completedConnectedApplicationInfoGeneration = wirelessConnectionGeneration
    secureHandshakePhase = .completed
    appendObservation(
      "BLE_APP_INFO_WRITE_ACK result=success generation=\(wirelessConnectionGeneration)"
    )
    appendObservation(
      "APP_REGISTRATION_RESULT result=accepted stage=connectedApplicationInfo " +
      "generation=\(wirelessConnectionGeneration) peripheralID=\(peripheral.identifier.uuidString)"
    )
    appendObservation("BLE_HANDSHAKE_GATE appInfo=required result=complete")
    handleIdentifierWriteCompletion(on: peripheral)
  }

  private func failConnectedApplicationInfoHandshake(_ reason: String) {
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    secureHandshakePhase = .idle
    appendObservation(
      "BLE_APP_INFO_WRITE_FAILED reason=\(reason) generation=\(wirelessConnectionGeneration)"
    )
    appendObservation(
      "APP_REGISTRATION_RESULT result=rejected stage=connectedApplicationInfo " +
      "generation=\(wirelessConnectionGeneration) reason=\(reason)"
    )
    appendObservation("BLE_HANDSHAKE_GATE appInfo=required result=failed")
    updateStatus("握手失败", isBusy: false)
    _ = terminateRememberedGallery(.activationResolutionFailed(reason: reason))
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
    connectedApplicationInfoCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    discoveredFirmwareVersion = nil
    discoveredServiceUUIDStrings = []
    pendingRememberedRedReconnectIdentityRejectionReason = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    encryptionRecoveryPolicy.reset()
    awaitingPairingReadyRediscovery = false
    pendingHandshakeSummary = nil
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    completedConnectedApplicationInfoGeneration = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
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

    guard prepareConnectionAttempt(peripheral: peripheral, camera: camera) else {
      return
    }
    appendLog("开始连接 \(camera.name) [\(camera.appVariant.rawValue)]")
    updateStatus("连接相机中", isBusy: true)
    startManagedBleConnect(peripheral, purpose: .freshPairing)
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

  func resetWirelessCameraFlowAndWait(
    timeoutSeconds: TimeInterval = 3
  ) async -> CameraCompatibilityLabResetResult {
    guard !fullResetGate.hasUnresolvedDisconnect else {
      appendObservation("BLE_FULL_RESET_BLOCKED unresolvedDisconnect=true")
      return .failed
    }
    guard let peripheral = selectedPeripheral,
          peripheral.state != .disconnected else {
      resetForNewConnectionAttempt(force: true)
      return .succeeded
    }

    let token = CameraVendorBluetoothResetToken(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral),
      generation: wirelessConnectionGeneration,
      resetNonce: UUID()
    )
    return await fullResetGate.reset(
      token: token,
      timeoutSeconds: timeoutSeconds,
      cancelConnection: { [weak self] in
        self?.resetForNewConnectionAttempt(force: true)
      }
    )
  }

  private func beginScan() {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    resetScanAdvertisementDiagnostics()
    updateStatus("搜索中", isBusy: true)
    scanStartedAt = CFAbsoluteTimeGetCurrent()
    appendObservation(
      "BLE_SCAN_TARGET purpose=general generation=\(wirelessConnectionGeneration) " +
      "targetPeripheralID=\(autoReconnectTargetPeripheralID?.uuidString ?? "none")"
    )
    appendLog("运行构建标记: \(buildMarker)")
    appendLog("开始 BLE 扫描（不过滤服务，直接分析 CameraVendor 广播）")
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      let elapsedMs = self.scanStartedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
      if self.discoveredCameras.isEmpty {
        self.appendLog("扫描结束，没有发现 相机，未匹配广播样本数 \(self.unmatchedAdvertisementSampleCount)")
        self.updateStatus("未发现相机", isBusy: false)
        self.appendObservation(
          "CONNECTION_TERMINAL barrier=generalScanTimeout elapsedMs=\(elapsedMs) " +
          "unmatchedSamples=\(self.unmatchedAdvertisementSampleCount)"
        )
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

  private func scheduleBleConnectTimeout(for peripheral: CBPeripheral, generation: UInt64) {
    bleConnectTimeoutWorkItem?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak peripheral] in
      guard let self, let peripheral else { return }
      guard self.bleConnectAttemptGeneration == generation,
            self.bleConnectAttemptPeripheralID == peripheral.identifier,
            self.bleConnectAttemptPeripheralIdentity == ObjectIdentifier(peripheral),
            self.activeBluetoothConnectionToken?.generation == generation else {
        return
      }
      let outcome = CameraVendorBleConnectAttemptPolicy.outcome(
        didConnect: false,
        didFailToConnect: false,
        didTimeout: true,
        cancellationReason: nil
      )
      self.appendObservation(
        "BLE_CONNECT_TIMEOUT generation=\(generation) " +
        "peripheralID=\(peripheral.identifier.uuidString) " +
        "elapsedMs=\(self.bleConnectAttemptStartedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1)"
      )
      self.bleConnectTimeoutWorkItem = nil
      self.bleConnectAttemptGeneration = nil
      self.bleConnectAttemptPeripheralID = nil
      self.bleConnectAttemptPeripheralIdentity = nil
      self.bleConnectAttemptStartedAt = nil
      self.activeBluetoothConnectionToken = nil
      self.selectedPeripheral = nil
      self.central.cancelPeripheralConnection(peripheral)
      self.terminateRememberedGallery(.bleConnectTimedOut)
      self.appendObservation(
        "CONNECTION_TERMINAL barrier=bleConnectTimeout " +
        "generation=\(generation) peripheralID=\(peripheral.identifier.uuidString)"
      )
      if CameraVendorBleConnectAttemptPolicy.shouldAttemptRestrictedReconnect(
        outcome: outcome,
        hasRememberedCamera: self.rememberedPairedCamera?.peripheralID == peripheral.identifier
      ) {
        self.appendObservation(
          "BLE_CONNECT_TIMEOUT_RECOVERY mode=restricted-scan " +
          "cameraID=\(peripheral.identifier.uuidString)"
        )
        self.autoReconnectTargetPeripheralID = peripheral.identifier
        self.updateStatus("连接超时，正在重新搜索相机", isBusy: true)
        self.beginScan()
      } else {
        self.updateStatus("连接相机超时，请重试", isBusy: false)
      }
    }
    bleConnectTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + CameraVendorBleConnectAttemptPolicy.timeoutSeconds,
      execute: timeout
    )
  }

  private func startManagedBleConnect(
    _ peripheral: CBPeripheral,
    purpose: CameraVendorBleConnectPurpose,
    generation: UInt64? = nil,
    delay: TimeInterval = 0
  ) {
    let expectedGeneration = generation ?? wirelessConnectionGeneration
    guard selectedPeripheral?.identifier == peripheral.identifier,
          activeBluetoothConnectionToken?.generation == expectedGeneration else {
      appendObservation(
        "BLE_CONNECT_START_REJECTED purpose=\(purpose.rawValue) " +
        "peripheralID=\(peripheral.identifier.uuidString) generation=\(expectedGeneration)"
      )
      return
    }
    bleConnectAttemptGeneration = expectedGeneration
    bleConnectAttemptPeripheralID = peripheral.identifier
    bleConnectAttemptPeripheralIdentity = ObjectIdentifier(peripheral)
    bleConnectAttemptStartedAt = CFAbsoluteTimeGetCurrent()
    scheduleBleConnectTimeout(for: peripheral, generation: expectedGeneration)
    appendObservation(
      "BLE_CONNECT_START purpose=\(purpose.rawValue) generation=\(expectedGeneration) " +
      "peripheralID=\(peripheral.identifier.uuidString)"
    )
    let connect = { [weak self, weak peripheral] in
      guard let self, let peripheral,
            self.selectedPeripheral?.identifier == peripheral.identifier,
            self.activeBluetoothConnectionToken?.generation == expectedGeneration else {
        return
      }
      self.central.connect(peripheral, options: nil)
    }
    if delay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: connect)
    } else {
      connect()
    }
  }

  private func cancelBleConnectAttempt(reason: String) {
    guard bleConnectAttemptGeneration != nil else {
      bleConnectTimeoutWorkItem?.cancel()
      bleConnectTimeoutWorkItem = nil
      return
    }
    appendObservation(
      "BLE_CONNECT_CANCEL_REQUESTED reason=\(reason) " +
      "generation=\(bleConnectAttemptGeneration ?? 0)"
    )
    bleConnectTimeoutWorkItem?.cancel()
    bleConnectTimeoutWorkItem = nil
    bleConnectAttemptGeneration = nil
    bleConnectAttemptPeripheralID = nil
    bleConnectAttemptPeripheralIdentity = nil
    bleConnectAttemptStartedAt = nil
    appendObservation("BLE_CONNECT_CANCEL_COMPLETED reason=\(reason)")
  }

  private func prepareConnectionAttempt(
    peripheral: CBPeripheral,
    camera: CameraVendorDiscoveredCamera
  ) -> Bool {
    guard !fullResetGate.hasUnresolvedDisconnect,
          !pairingProbeTeardownGate.hasUnresolvedDisconnect else {
      appendObservation(
        "BLE_CONNECTION_ATTEMPT_BLOCKED unresolvedDisconnect=true " +
        "peripheralID=\(peripheral.identifier.uuidString)"
      )
      updateStatus("等待上一条蓝牙连接完全断开", isBusy: false)
      return false
    }
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    cancelBleConnectAttempt(reason: "superseded")
    wirelessConnectionGeneration &+= 1
    selectedPeripheral = peripheral
    activeBluetoothConnectionToken = CameraVendorBluetoothConnectionToken(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral),
      generation: wirelessConnectionGeneration
    )
    selectedCamera = camera
    pairingCharacteristic = nil
    connectedDeviceNameCharacteristic = nil
    connectedDeviceIdentificationCharacteristic = nil
    connectedApplicationInfoCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    discoveredFirmwareVersion = nil
    discoveredServiceUUIDStrings = []
    pendingRememberedRedReconnectIdentityRejectionReason = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    encryptionRecoveryPolicy.reset()
    awaitingPairingReadyRediscovery = false
    pendingHandshakeSummary = nil
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    completedConnectedApplicationInfoGeneration = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
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
    bleConnectAttemptGeneration = wirelessConnectionGeneration
    bleConnectAttemptPeripheralID = peripheral.identifier
    bleConnectAttemptPeripheralIdentity = ObjectIdentifier(peripheral)
    scheduleBleConnectTimeout(for: peripheral, generation: wirelessConnectionGeneration)
    appendObservation(
      "BLE_CONNECT_START generation=\(wirelessConnectionGeneration) " +
      "peripheralID=\(peripheral.identifier.uuidString)"
    )
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
    secureHandshakePhase = .idle
    secureHandshakeReconnectCount = 0
    secureIdentificationNumberAlreadyPaired = false
    autoReconnectTargetPeripheralID = nil
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
    return true
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
          matchDetails: "remembered-system-retrieve",
          admission: .generic
        )
        discoveredPeripherals[peripheral.identifier] = peripheral
        discoveredCameras = [camera]
        notifyDevicesChanged()
        appendLog("系统已取回上次配对的相机外设，直接发起连接: \(record.deviceName) [\(record.peripheralID.uuidString)]")
        guard prepareConnectionAttempt(peripheral: peripheral, camera: camera) else {
          return
        }
        updateStatus("连接上次配对的相机", isBusy: true)
        startManagedBleConnect(peripheral, purpose: .rememberedDirect)
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
    scanStartedAt = CFAbsoluteTimeGetCurrent()
    appendObservation(
      "BLE_SCAN_TARGET purpose=rememberedReconnect generation=\(wirelessConnectionGeneration) " +
      "targetPeripheralID=\(record.peripheralID.uuidString) rememberedDevice=\(record.deviceName)"
    )
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      let elapsedMs = self.scanStartedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1
      self.autoReconnectTargetPeripheralID = nil
      let classification = CameraVendorRememberedReconnectTimeoutClassification.classify(
        recognizedAdvertisementCount: self.recognizedRememberedAdvertisementCount,
        rememberedEndpointFoundNotReady: self.rememberedEndpointFoundNotReady
      )
      let failure: CameraVendorRememberedGalleryTerminalFailure = {
        switch classification {
        case .noAdvertisement: return .noAdvertisement
        case .rememberedEndpointNotMatched: return .rememberedEndpointNotMatched
        case .rememberedEndpointFoundNotReady: return .rememberedEndpointFoundNotReady
        }
      }()
      if self.terminateRememberedGallery(failure) {
        self.appendObservation(
          "CONNECTION_TERMINAL barrier=rememberedCameraScanTimeout " +
          "classification=\(classification.rawValue) " +
          "targetPeripheralID=\(record.peripheralID.uuidString) elapsedMs=\(elapsedMs) " +
          "recognizedCandidates=\(self.recognizedRememberedAdvertisementCount) " +
          "unmatchedSamples=\(self.unmatchedAdvertisementSampleCount)"
        )
        self.appendLog(failure.issue.reason)
        self.updateStatus(
          {
            switch classification {
            case .noAdvertisement: return "未发现相机，请重启或唤醒相机后重试"
            case .rememberedEndpointFoundNotReady: return "已发现相机，但当前未进入传图状态，请唤醒相机后重试"
            case .rememberedEndpointNotMatched: return "发现新的相机连接入口，原有连接记录已失效，请重新配对"
            }
          }(),
          isBusy: false
        )
        return
      }
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
    recognizedRememberedAdvertisementCount = 0
    rememberedEndpointFoundNotReady = false
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
    connectedApplicationInfoCharacteristic = nil
    discoveredCharacteristicsByUUID = [:]
    notifiableCharacteristics = []
    probedCharacteristics = [:]
    observedCharacteristicValues = [:]
    discoveredName = nil
    discoveredSerialNumber = nil
    discoveredFirmwareVersion = nil
    discoveredServiceUUIDStrings = []
    pendingRememberedRedReconnectIdentityRejectionReason = nil
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    lastHandshakeWaitReason = nil
    handshakeMode = .undetermined
    pendingHandshakeSummary = nil
    pendingPostHandshakeProbeReads = []
    isRunningPostHandshakeProbe = false
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
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
    connectedApplicationInfoTimeoutWorkItem?.cancel()
    connectedApplicationInfoTimeoutWorkItem = nil
    connectedApplicationInfoWriteGeneration = nil
    completedConnectedApplicationInfoGeneration = nil
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
      self.startManagedBleConnect(peripheral, purpose: .secureHandshakeRecovery, delay: 0)
    }
  }

  private func recoverTransferActivationAfterDisconnect(_ peripheral: CBPeripheral) {
    activationDisconnectRecoveryCount += 1
    appendObservation(
      "ACTIVATION_DISCONNECT_RECOVERY attempt=\(activationDisconnectRecoveryCount)/" +
      "\(maxActivationDisconnectRecoveryAttempts) phase=activation"
    )
    guard selectedCamera != nil,
          selectedPeripheral?.identifier == peripheral.identifier,
          !fullResetGate.hasUnresolvedDisconnect,
          !pairingProbeTeardownGate.hasUnresolvedDisconnect else {
      appendObservation("ACTIVATION_DISCONNECT_RECOVERY_BLOCKED reason=prepare-failed")
      updateStatus("传图激活恢复失败，请重试连接", isBusy: false)
      terminateRememberedGallery(.activationDisconnected)
      return
    }
    wirelessConnectionGeneration &+= 1
    selectedPeripheral = peripheral
    activeBluetoothConnectionToken = CameraVendorBluetoothConnectionToken(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral),
      generation: wirelessConnectionGeneration
    )
    scheduleBleConnectTimeout(for: peripheral, generation: wirelessConnectionGeneration)
    appendObservation(
      "BLE_CONNECT_START generation=\(wirelessConnectionGeneration) " +
      "peripheralID=\(peripheral.identifier.uuidString) owner=activation-recovery"
    )
    updateStatus("传图激活中断，正在恢复连接", isBusy: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self,
            self.selectedPeripheral?.identifier == peripheral.identifier else {
        return
      }
      self.appendLog("传图激活阶段执行一次受限 BLE 恢复连接")
      self.startManagedBleConnect(peripheral, purpose: .activationRecovery, delay: 0)
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
    CameraDiagnosticPipeline.shared.emitLegacy(safeMessage)
    logStore.append(line, writesToDisk: false)
    delegate?.cameraVendorBluetoothService(self, didAppendLog: line)
  }

  private func appendObservedGalleryLog(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let safeMessage = CamTransferDiagnosticLogRedactor.redacted(message)
    let line = "[\(formatter.string(from: Date()))] \(safeMessage)"
    logStore.append(line, writesToDisk: false)
    delegate?.cameraVendorBluetoothService(self, didAppendLog: line)
  }

  private func writeBleControlValue(
    _ payload: Data,
    to characteristic: CBCharacteristic,
    on peripheral: CBPeripheral,
    kind: String
  ) {
    let payloadSummary = CameraDiagnosticSensitivityPolicy.isSensitiveBLEControl(
      kind: kind,
      characteristicUUID: characteristic.uuid.uuidString
    )
      ? CameraDiagnosticPayloadSummary.sensitiveControlSignal(
          name: "payload",
          direction: .appToCamera,
          data: payload
        )
      : CameraDiagnosticPayloadSummary.controlSignal(
          name: "payload",
          direction: .appToCamera,
          data: payload
        )
    bleWriteSequence &+= 1
    let requestID = "\(wirelessConnectionGeneration)-\(bleWriteSequence)"
    pendingBleWriteRequestIDsByCharacteristic[ObjectIdentifier(characteristic)] = requestID
    appendObservation(
      "BLE_WRITE_REQUEST requestID=\(requestID) generation=\(wirelessConnectionGeneration) direction=appToCamera kind=\(kind) " +
      "uuid=\(characteristic.uuid.uuidString) " +
      payloadSummary
    )
    peripheral.writeValue(payload, for: characteristic, type: .withResponse)
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
      let identityDecision = CameraVendorRememberedRedReconnectIdentityPolicy.decision(
        admission: selectedCamera?.admission ?? .generic,
        rememberedPeripheralID: rememberedPairedCamera?.peripheralID,
        connectedPeripheralID: peripheral.identifier,
        rememberedSerialNumber: rememberedPairedCamera?.serialNumber,
        connectedSerialNumber: discoveredSerialNumber
      )
      if case .rejected(let reason) = identityDecision {
        pendingRememberedRedReconnectIdentityRejectionReason = reason
        appendLog("已配对 RED 重连身份校验失败 reason=\(reason.rawValue)")
        updateStatus("相机身份校验失败，请重新配对", isBusy: false)
        central.cancelPeripheralConnection(peripheral)
        return
      }

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
      writeBleControlValue(payload, to: connectedDeviceNameCharacteristic, on: peripheral, kind: "device-name")
    case .legacy, .undetermined:
      guard let connectedDeviceNameCharacteristic,
            let camera = selectedCamera else {
        return
      }

      if let pairingCharacteristic, let token = camera.pairingToken {
        let payload = CameraVendorSecureHandshakeCodec.pairingPayload(token)
        appendLog("写入配对 token: payload-redacted bytes=\(payload.count)")
        writeBleControlValue(payload, to: pairingCharacteristic, on: peripheral, kind: "pairing-token")
        return
      }

      let deviceName = connectedDeviceNameToWrite
      appendLog("未拿到配对 token，直接尝试写入已连接设备名称: \(deviceName)")
      let payload = CameraVendorSecureHandshakeCodec.identifierPayload(deviceName)
      writeBleControlValue(payload, to: connectedDeviceNameCharacteristic, on: peripheral, kind: "device-name")
    }
  }

  private func upsertCamera(
    peripheral: CBPeripheral,
    match: CameraVendorAdvertisementMatch,
    serviceUUIDs: [String],
    rssi: Int
  ) -> CameraVendorDiscoveredCamera {
    let camera = CameraVendorDiscoveredCamera(
      id: peripheral.identifier,
      name: match.resolvedName,
      rssi: rssi,
      appVariant: match.appVariant,
      pairingToken: match.pairingToken,
      matchDetails: match.reasons.joined(separator: ", "),
      admission: match.admission,
      advertisedServiceUUIDs: Set(serviceUUIDs.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      })
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
      firmwareVersion: discoveredFirmwareVersion,
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
      do {
        activeActivationDefinition = try activationResolutionGate.resolve(
          facts: summary.compatibilityFacts,
          using: activeActivationResolver
        )
        self.activeActivationResolver = nil
      } catch {
        terminateRememberedGallery(
          .identityReadFailed(reason: error.localizedDescription)
        )
        return
      }
      hasAttemptedAutomaticTransferActivation = true
      transferActivationAttemptCount = 0
      let resolvedActivationStrategies = strategies.compactMap {
        CameraVendorReferenceAppTransferActivationStrategy(rawValue: $0.rawValue)
      }
      currentTransferActivationStrategy = resolvedActivationStrategies.first
      hadAutomaticTransferActivationFeature = currentTransferActivationStrategy != nil

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
      terminateRememberedGallery(.missingActivationFeature)
      return
    case .failMissingActivationFeature(let availableCharacteristicUUIDStrings):
      appendObservation("ACTIVATION_PLAN empty availableCharacteristics=\(availableCharacteristicUUIDStrings.joined(separator: ","))")
      appendLog("未发现 ReferenceApp 传图命令特征，停止传图激活流程")
      updateStatus("相机未提供传图启动特征，请重新连接后重试", isBusy: false)
      terminateRememberedGallery(.missingActivationFeature)
      return
    case .failActivationNotReady:
      appendObservation(
        "HANDSHAKE_BLOCKED activationAttempted=\(hasAttemptedAutomaticTransferActivation) " +
        "observedChange=\(transferActivationObservedChange) observedWifiLaunch=\(transferActivationObservedWifiLaunch) " +
        "hadFeature=\(hadAutomaticTransferActivationFeature)"
      )
      appendLog("传图激活未进入可连接状态，阻止进入图库")
      updateStatus("相机未进入传图模式，请重新连接后重试", isBusy: false)
      terminateRememberedGallery(.activationNotReady)
      return
    case .complete(.gallery):
      completeHandshake(summary: summary, reason: "gallery")
      return
    }
  }

  @discardableResult
  private func terminateRememberedGallery(
    _ failure: CameraVendorRememberedGalleryTerminalFailure
  ) -> Bool {
    activeActivationResolver = nil
    let didTerminate = rememberedGalleryTerminalOwner?.fail(
      failure,
      intent: activeWirelessIntent
    ) ?? false
    if didTerminate {
      appendObservation("REMEMBERED_GALLERY_TERMINAL_FAILURE reason=\(failure.issue.reason)")
    }
    return didTerminate
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
      appendObservation(
        "APP_REGISTRATION_RESULT result=identity-mismatch stage=handshake " +
        "generation=\(wirelessConnectionGeneration)"
      )
      appendLog("已配对记录和本次连接相机身份不一致，已阻止进入图库。请清除旧配对后重新配对。")
      updateStatus("请清除旧配对后重新配对", isBusy: false)
      terminateRememberedGallery(.identityMismatch)
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
      ),
      compatibilityFacts: summary.compatibilityFacts
    )

    didCompleteHandshakeCallback = true
    pendingHandshakeSummary = nil
    rememberedGalleryTerminalOwner = nil
    CameraVendorGalleryDiagnostics.externalLogHandler = { [weak self] message in
      self?.appendObservedGalleryLog(message)
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
    appendObservation(
      "GATT_IDENTITY_RESULT stage=handshake result=verified generation=\(wirelessConnectionGeneration) " +
      "peripheralID=\(selectedPeripheral?.identifier.uuidString ?? "none")"
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
      preferCompressedDownloads: CameraVendorTransferActivationResizePolicy.preferCompressedDownloads,
      compatibilityFacts: currentCompatibilityFacts(
        modelName: discoveredName ?? selectedCamera?.name ?? peripheral.name
      )
    )

    if let preferredWifiNetwork,
       preferredWifiNetwork != lastLoggedWifiConfiguration {
      lastLoggedWifiConfiguration = preferredWifiNetwork
      appendLog("已收到相机 Wi-Fi 配置")
      appendLog("SSID: \(preferredWifiNetwork.ssid)")
      appendObservation(
        "APP_REGISTRATION_RESULT result=wifi-config-received ssidPresent=true " +
        "passphrasePresent=\(!preferredWifiNetwork.passphrase.isEmpty) " +
        "generation=\(wirelessConnectionGeneration)"
      )
      if preferredWifiNetwork.isHidden {
        appendLog("这是隐藏网络；如果列表里看不到，请在 Wi‑Fi 的“其他...”里手动输入。")
      }
    }
  }

  private func currentCompatibilityFacts(modelName: String?) -> CameraCompatibilityFacts {
    let normalizedServices = Set(discoveredServiceUUIDStrings.map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    })
    let family: CameraCompatibilityFamily?
    if normalizedServices.contains(FujifilmCompatibilityUUID.securePairService) {
      family = .red
    } else if normalizedServices.contains(FujifilmCompatibilityUUID.legacyPairService) {
      family = .legacy
    } else {
      family = nil
    }
    return CameraCompatibilityFacts(
      observedIdentity: CameraObservedIdentity(
        modelName: modelName,
        firmwareVersion: discoveredFirmwareVersion
      ),
      protocolFacts: CameraProtocolFacts(
        compatibilityFamily: family,
        advertisedServices: normalizedServices,
        discoveredServices: Set(discoveredServiceUUIDStrings.map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }),
        discoveredCharacteristics: Set(discoveredCharacteristicsByUUID.keys.map {
          $0.uuidString.uppercased()
        })
      )
    )
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

    guard let activationDefinition = activeActivationDefinition else {
      terminateRememberedGallery(
        .activationResolutionFailed(reason: "No activation definition is bound to this attempt")
      )
      return
    }
    guard let strategy = currentTransferActivationStrategy else {
      finishHandshakeIfPossible()
      return
    }
    guard transferActivationAttemptCount < activationDefinition.retryTiming.maxAttempts else {
      finishHandshakeIfPossible()
      return
    }
    activationAttemptGeneration &+= 1
    activeActivationAttemptToken = CameraVendorActivationAttemptToken(
      peripheralID: peripheral.identifier,
      generation: activationAttemptGeneration
    )
    transferActivationAttemptCount += 1
    transferActivationStepDriver = CameraVendorActivationStepDriver(
      definition: activationDefinition
    )
    var activationWrites: [CameraVendorBleWriteRequest] = []
    CameraVendorActivationStrategyExecutor.execute(definition: activationDefinition) {
      activationWrites.append($0)
    }
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
      "attempt=\(transferActivationAttemptCount)/\(activationDefinition.retryTiming.maxAttempts) " +
      "retryOwner=\(activationDefinition.retryTiming.retryOwner.rawValue) " +
      "writes=\(activationWrites.map { "\($0.characteristicUUIDString)=\(hexString($0.payload))" }.joined(separator: ","))"
    )
    writeNextTransferActivationStep(on: peripheral)
  }

  private func writeNextTransferActivationStep(on peripheral: CBPeripheral) {
    guard isRunningTransferActivation else {
      return
    }
    guard let activationTiming = activeActivationDefinition?.retryTiming else {
      terminateRememberedGallery(
        .activationResolutionFailed(reason: "No activation timing is bound to this attempt")
      )
      return
    }

    guard let stepDriver = transferActivationStepDriver else {
      terminateRememberedGallery(
        .activationResolutionFailed(reason: "No activation step driver is bound to this attempt")
      )
      return
    }
    guard let request = stepDriver.currentWriteRequest else {
      appendLog("传图命令已写入，读取状态特征等待相机切换")

      let trackedStatusUUIDStrings = activeActivationDefinition?
        .trackedStatusCharacteristicUUIDStrings ?? []

      for uuidString in trackedStatusUUIDStrings {
        let uuid = CBUUID(string: uuidString)
        guard let characteristic = discoveredCharacteristicsByUUID[uuid],
              characteristic.properties.contains(.read) else {
          continue
        }
        peripheral.readValue(for: characteristic)
      }

      scheduleBleStateSampling(on: peripheral)

      guard !transferActivationCameraResponded else {
        appendLog(
          "相机已响应过状态变化，保留现有 " +
          "\(String(format: "%.0f", activationTiming.responseProgressTimeoutSeconds)) 秒超时"
        )
        return
      }
      transferActivationTimeoutWorkItem?.cancel()
      transferActivationTimeoutSetAt = CFAbsoluteTimeGetCurrent()
      appendLog(
        "[DIAG] 设置 \(String(format: "%.0f", activationTiming.acknowledgementTimeoutSeconds)) 秒超时 " +
        "at \(String(format: "%.3f", transferActivationTimeoutSetAt))"
      )
      let timeout = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - self.transferActivationTimeoutSetAt
        self.appendLog("[DIAG] 超时 DispatchWorkItem 触发, elapsed=\(String(format: "%.3f", elapsed))s")
        self.completeCurrentTransferActivationAttempt(
          on: peripheral,
          source: "activation-acknowledgement-timeout"
        )
      }
      transferActivationTimeoutWorkItem = timeout
      // Camera needs time to start WiFi AP after receiving activation command.
      // 2s was too short — DEVICE-A typically needs 5-10s to launch the AP.
      DispatchQueue.main.asyncAfter(
        deadline: .now() + activationTiming.acknowledgementTimeoutSeconds,
        execute: timeout
      )
      return
    }

    let uuid = CBUUID(string: request.characteristicUUIDString)
    guard let characteristic = discoveredCharacteristicsByUUID[uuid] else {
      appendLog("缺少传图命令特征 \(request.characteristicUUIDString)")
      isRunningTransferActivation = false
      transferActivationStepDriver = nil
      activeActivationAttemptToken = nil
      if !retryCurrentTransferActivationIfOwned(
        on: peripheral,
        source: "missing-write-characteristic"
      ) {
        finishHandshakeIfPossible()
      }
      return
    }
    guard let activationAttemptToken = activeActivationAttemptToken else {
      terminateRememberedGallery(
        .activationResolutionFailed(reason: "No activation attempt token is bound to this write")
      )
      return
    }

    appendLog("写入传图命令 \(request.characteristicUUIDString): \(hexString(request.payload))")
    transferActivationWritePayloadsByUUID[request.characteristicUUIDString.uppercased()] = request.payload
    transferActivationWriteAttemptTokensByCharacteristicIdentity[ObjectIdentifier(characteristic)] = CameraVendorActivationWriteToken(
      attempt: activationAttemptToken,
      characteristicIdentity: ObjectIdentifier(characteristic)
    )
    writeBleControlValue(request.payload, to: characteristic, on: peripheral, kind: "transfer-activation")
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
    writeBleControlValue(request.payload, to: characteristic, on: peripheral, kind: "reserved-image-receive-probe")
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

  private func terminateCurrentTransferActivationNotReady(
    response: CameraVendorActivationAttemptResponse
  ) {
    transferActivationTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem = nil
    cancelBleStateSampling()
    transferActivationStepDriver = nil
    currentTransferActivationStrategy = nil
    activeActivationDefinition = nil
    activeActivationAttemptToken = nil
    transferActivationWriteAttemptTokensByCharacteristicIdentity.removeAll()
    isRunningTransferActivation = false
    transferActivationAttemptCount = 0
    activationDisconnectRecoveryCount = 0
    transferActivationObservedChange = false
    transferActivationCameraResponded = false
    transferActivationObservedWifiLaunch = false
    awaitingTransferActivationStateChange = false
    awaitingTransferActivationStateChangeSince = nil
    transferActivationWritePayloadsByUUID.removeAll()

    switch response {
    case .responded:
      appendObservation("ACTIVATION_ABORT_NO_AP_READY response=responded")
      updateStatus(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus, isBusy: false)
    case .noResponse:
      appendObservation("ACTIVATION_ABORT_NO_AP_READY response=no-response")
      updateStatus("相机未确认进入传图模式，请重试连接", isBusy: false)
    }
    terminateRememberedGallery(.activationNotReady)
  }

  @discardableResult
  private func retryCurrentTransferActivationIfOwned(
    on peripheral: CBPeripheral,
    source: String
  ) -> Bool {
    guard let activationDefinition = activeActivationDefinition else {
      return false
    }

    switch CameraVendorActivationRetryExecutor.decision(
      retryTiming: activationDefinition.retryTiming,
      completedAttempts: transferActivationAttemptCount
    ) {
    case .retryInternally(let nextAttempt):
      appendObservation(
        "ACTIVATION_RETRY source=\(source) nextAttempt=\(nextAttempt)/" +
        "\(activationDefinition.retryTiming.maxAttempts) " +
        "retryOwner=\(activationDefinition.retryTiming.retryOwner.rawValue)"
      )
      beginNextTransferActivationAttempt(on: peripheral)
      return true
    case .failClosed(let owner):
      let reason = "Activation retry owner \(owner.rawValue) has no executor in BluetoothService"
      appendObservation(
        "ACTIVATION_RETRY_FAIL_CLOSED source=\(source) retryOwner=\(owner.rawValue) " +
        "reason=owner-executor-unavailable"
      )
      appendLog("传图激活重试归属 \(owner.rawValue)，BluetoothService 不得代为重试，终止当前连接")
      currentTransferActivationStrategy = nil
      awaitingTransferActivationStateChange = false
      awaitingTransferActivationStateChangeSince = nil
      updateStatus("传图激活重试执行器不可用，请重新连接后重试", isBusy: false)
      terminateRememberedGallery(.activationResolutionFailed(reason: reason))
      return true
    case .attemptBudgetExhausted:
      return false
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
    transferActivationStepDriver = nil
    activeActivationAttemptToken = nil
    isRunningTransferActivation = false

    let retryDecision = activeActivationDefinition.map {
      CameraVendorActivationRetryExecutor.decision(
        retryTiming: $0.retryTiming,
        completedAttempts: transferActivationAttemptCount
      )
    } ?? .attemptBudgetExhausted
    let attemptDecision = CameraVendorActivationAttemptExecutor.decision(
      observedChange: transferActivationObservedChange,
      cameraResponded: transferActivationCameraResponded,
      retryDecision: retryDecision
    )

    switch attemptDecision {
    case .proceedToGallery:
      let handoffPolicy = activeActivationDefinition?.wifiHandoffPolicy.rawValue ?? "unbound"
      appendObservation(
        "ACTIVATION_COMPLETE source=\(source) result=proceedToGallery " +
        "strategy=\(strategyName) wifiHandoffPolicy=\(handoffPolicy)"
      )
      appendLog("传图模式 \(strategyName) 已满足 Definition 完成谓词，保持 BLE 并进入图库")
      currentTransferActivationStrategy = nil
      awaitingTransferActivationStateChange = false
      awaitingTransferActivationStateChangeSince = nil
      finishHandshakeIfPossible()
      return
    case .retryInternally:
      if transferActivationCameraResponded {
        appendLog("传图模式 \(strategyName) 已响应但未满足完成谓词，重试当前 Definition")
      } else {
        appendLog("传图模式 \(strategyName) 未满足完成谓词，重试当前 Definition")
      }
      if retryCurrentTransferActivationIfOwned(on: peripheral, source: source) {
        return
      }
      terminateCurrentTransferActivationNotReady(
        response: transferActivationCameraResponded ? .responded : .noResponse
      )
      return
    case .failClosed:
      if retryCurrentTransferActivationIfOwned(on: peripheral, source: source) {
        return
      }
      terminateCurrentTransferActivationNotReady(
        response: transferActivationCameraResponded ? .responded : .noResponse
      )
      return
    case .terminateNotReady(let response):
      if response == .responded {
        appendLog("相机已响应但未进入传图保留模式，终止当前激活 attempt")
      } else {
        appendLog("传图模式 \(strategyName) 未满足 Definition 完成谓词，终止当前激活 attempt")
      }
      terminateCurrentTransferActivationNotReady(response: response)
      return
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
    let manufacturerSummary = CameraDiagnosticPayloadSummary.manufacturerAdvertisement(manufacturerData)

    let name = localName ?? peripheral.name
    appendObservation(
      "BLE_ADVERTISEMENT_CANDIDATE generation=\(wirelessConnectionGeneration) " +
      "purpose=\(autoReconnectTargetPeripheralID != nil ? "rememberedReconnect" : (pairingProbeState.isActive ? "pairingProbe" : "discovery")) " +
      "peripheralID=\(peripheral.identifier.uuidString) name=\(name ?? "nil") " +
      "services=\(serviceUUIDs.joined(separator: ",").isEmpty ? "-" : serviceUUIDs.joined(separator: ",")) " +
      "mfg=\(manufacturerSummary) rssi=\(RSSI.intValue)"
    )
    let rememberedRedReconnectMatch =
      CameraVendorDeviceMatcher.matchRememberedRedReconnectAdvertisement(
        name: name ?? rememberedPairedCamera?.deviceName,
        observedPeripheralID: peripheral.identifier,
        rememberedPeripheralID: autoReconnectTargetPeripheralID,
        rememberedAppVariant: rememberedPairedCamera?.appVariant ?? .unknown,
        serviceUUIDs: serviceUUIDs,
        manufacturerData: manufacturerData
      )
    let genericMatch = CameraVendorDeviceMatcher.matchAdvertisement(
      name: name,
      serviceUUIDs: serviceUUIDs,
      manufacturerData: manufacturerData
    )
    let isRecognizedCameraAdvertisement = genericMatch != nil
      || serviceUUIDs.contains(CameraVendorDeviceMatcher.securePairServiceUUIDString)
      || manufacturerData.map {
        $0.count >= 3 && $0[0] == 0xD8 && $0[1] == 0x04
      } == true
    if autoReconnectTargetPeripheralID != nil,
       rememberedRedReconnectMatch == nil,
       isRecognizedCameraAdvertisement {
      recognizedRememberedAdvertisementCount += 1
      if peripheral.identifier == autoReconnectTargetPeripheralID {
        rememberedEndpointFoundNotReady = true
      }
      appendObservation(
        "BLE_MATCH_DECISION result=rejected " +
        "peripheralID=\(peripheral.identifier.uuidString) " +
        "reason=\(peripheral.identifier == autoReconnectTargetPeripheralID ? "remembered-endpoint-found-not-ready" : "remembered-endpoint-mismatch") " +
        "rememberedTarget=\(autoReconnectTargetPeripheralID?.uuidString ?? "none")"
      )
    }
    guard let match = rememberedRedReconnectMatch ?? genericMatch else {
      appendObservation(
        "BLE_MATCH_DECISION result=rejected peripheralID=\(peripheral.identifier.uuidString) " +
        "reason=matcher-no-match rememberedTarget=\(autoReconnectTargetPeripheralID?.uuidString ?? "none")"
      )
      logUnmatchedAdvertisementSample(
        peripheral: peripheral,
        name: name,
        serviceUUIDs: serviceUUIDs,
        manufacturerSummary: manufacturerSummary,
        rssi: RSSI.intValue
      )
      return
    }

    appendObservation(
      "BLE_MATCH_DECISION result=accepted peripheralID=\(peripheral.identifier.uuidString) " +
      "variant=\(match.appVariant.rawValue) source=\(rememberedRedReconnectMatch != nil ? "remembered" : "generic") " +
      "details=\(match.reasons.joined(separator: ","))"
    )

    discoveredPeripherals[peripheral.identifier] = peripheral
    let camera = upsertCamera(
      peripheral: peripheral,
      match: match,
      serviceUUIDs: serviceUUIDs,
      rssi: RSSI.intValue
    )

    appendLog(
      "发现相机: \(camera.name) RSSI \(camera.rssi) | " +
      "variant \(camera.appVariant.rawValue) | " +
      "services \(serviceUUIDs.joined(separator: ",")) | " +
      "mfg \(manufacturerSummary) | " +
      "match \(camera.matchDetails)"
    )

    updateStatus("已发现 \(discoveredCameras.count) 台相机", isBusy: false)
    notifyDevicesChanged()

    // Pairing probe: if we're scanning for the probe target, connect it silently.
    if case .scanning(let probeTargetID) = pairingProbeState,
       peripheral.identifier == probeTargetID {
      central.stopScan()
      appendObservation(
        "BLE_MATCH_DECISION result=probe-target peripheralID=\(peripheral.identifier.uuidString) " +
        "target=\(probeTargetID.uuidString)"
      )
      pairingProbeState = .connecting(peripheralID: probeTargetID)
      pairingProbePeripheral = peripheral
      peripheral.delegate = self
      central.connect(peripheral, options: nil)
      return
    }

    if let autoReconnectTargetPeripheralID,
       peripheral.identifier == autoReconnectTargetPeripheralID {
      scanTimeoutWorkItem?.cancel()
      central.stopScan()
      appendLog("已找到上次配对的相机，自动发起连接")
      guard prepareConnectionAttempt(peripheral: peripheral, camera: camera) else {
        return
      }
      updateStatus("连接上次配对的相机", isBusy: true)
      startManagedBleConnect(peripheral, purpose: .rememberedScan)
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
      appendLog(
        "已捕获可配对广播，自动重新连接 | " +
        "services \(serviceUUIDs.joined(separator: ",")) | mfg \(manufacturerSummary)"
      )
      updateStatus("重新连接相机中", isBusy: true)
      startManagedBleConnect(peripheral, purpose: .freshPairing)
    }
  }

  private func logUnmatchedAdvertisementSample(
    peripheral: CBPeripheral,
    name: String?,
    serviceUUIDs: [String],
    manufacturerSummary: String,
    rssi: Int
  ) {
    let key = [
      peripheral.identifier.uuidString,
      name ?? "nil",
      serviceUUIDs.joined(separator: ","),
      manufacturerSummary,
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
      "mfg=\(manufacturerSummary)"
    )
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    // Pairing probe: if this is the probe peripheral, discover services silently.
    if case .connecting(let probeID) = pairingProbeState,
       peripheral.identifier == probeID {
      pairingProbeState = .discoveringServices(peripheralID: probeID)
      peripheral.delegate = self
      peripheral.discoverServices([CameraVendorPairingProbePolicy.validationServiceUUID])
      return
    }

    if pairingProbeTeardownGate.matchesUnresolvedDisconnect(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral)
    ) {
      appendObservation(
        "PAIRING_PROBE_LATE_CONNECT_CANCELLED peripheralID=\(peripheral.identifier.uuidString)"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }

    guard case .activeMainline = CameraVendorBluetoothDisconnectOwnershipPolicy.route(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral),
      activeMainlineToken: activeBluetoothConnectionToken
    ) else {
      appendObservation(
        "BLE_CONNECT_ORPHAN_IGNORED peripheralID=\(peripheral.identifier.uuidString)"
      )
      central.cancelPeripheralConnection(peripheral)
      return
    }

    let connectGeneration = bleConnectAttemptGeneration
    if bleConnectAttemptPeripheralID == peripheral.identifier,
       bleConnectAttemptPeripheralIdentity == ObjectIdentifier(peripheral) {
      cancelBleConnectAttempt(reason: "connected")
      appendObservation(
        "BLE_CONNECT_SUCCEEDED generation=\(connectGeneration ?? wirelessConnectionGeneration) " +
        "peripheralID=\(peripheral.identifier.uuidString)"
      )
    }
    recordBackgroundHardwareActivity()
    appendLog("蓝牙连接成功: \(peripheral.name ?? peripheral.identifier.uuidString)")
    appendObservation("BLE_CONNECTED name=\(peripheral.name ?? "nil") id=\(peripheral.identifier.uuidString)")
    appendObservation(
      "GATT_IDENTITY_RESULT stage=link result=connected generation=\(wirelessConnectionGeneration) " +
      "peripheralID=\(peripheral.identifier.uuidString)"
    )
    updateStatus("读取相机服务中", isBusy: true)
    peripheral.delegate = self
    peripheral.discoverServices(nil)
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    if case .tearingDown(let probeID, let result) = pairingProbeState,
       peripheral.identifier == probeID {
      pairingProbeState = .completed(result)
      pairingProbePeripheral = nil
      appendObservation(
        "PAIRING_PROBE_CONNECT_FAILURE_CONSUMED peripheralID=\(peripheral.identifier.uuidString) " +
        "state=tearingDown"
      )
      completePairingProbeTeardownWaitersIfNeeded()
      return
    }
    // Pairing probe: if the probe peripheral failed to connect, check if pairing is invalid.
    if pairingProbeState.targetPeripheralID == peripheral.identifier {
      if CameraVendorPairingProbePolicy.isConnectionFailurePairingInvalid(error) {
        completePairingProbe(result: .pairingInvalid(reason: error?.localizedDescription ?? "connect-failed"), reason: "didFailToConnect-pairing-invalid")
      } else {
        completePairingProbe(result: .offline, reason: "didFailToConnect")
      }
      return
    }

    if let teardownToken = pairingProbeTeardownGate.completeDisconnect(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral)
    ) {
      appendObservation(
        "PAIRING_PROBE_CONNECT_FAILURE_CONSUMED peripheralID=\(peripheral.identifier.uuidString) " +
        "generation=\(teardownToken.generation)"
      )
      return
    }

    guard case .activeMainline(let generation) =
      CameraVendorBluetoothDisconnectOwnershipPolicy.route(
        peripheralID: peripheral.identifier,
        peripheralIdentity: ObjectIdentifier(peripheral),
        activeMainlineToken: activeBluetoothConnectionToken
      ) else {
      appendObservation(
        "BLE_CONNECT_FAILURE_ORPHAN_IGNORED peripheralID=\(peripheral.identifier.uuidString)"
      )
      return
    }

    if bleConnectAttemptPeripheralID == peripheral.identifier,
       bleConnectAttemptPeripheralIdentity == ObjectIdentifier(peripheral) {
      cancelBleConnectAttempt(reason: "failed")
      appendObservation(
        "BLE_CONNECT_FAILED generation=\(generation) " +
        "peripheralID=\(peripheral.identifier.uuidString)"
      )
    }
    let errorDescription = error?.localizedDescription
    let nsError = error as NSError?
    appendObservation(
      "BLE_CONNECT_FAILURE_DETAIL generation=\(generation) peripheralID=\(peripheral.identifier.uuidString) " +
      "domain=\(nsError?.domain ?? "nil") code=\(nsError?.code ?? 0) " +
      "pairingInvalidEvidence=\(error.map { CameraVendorPairingProbePolicy.isPairingInvalidError($0) } ?? false) " +
      "elapsedMs=\(bleConnectAttemptStartedAt.map { Int((CFAbsoluteTimeGetCurrent() - $0) * 1000) } ?? -1)"
    )
    appendObservation("BLE_CONNECT_FAILURE_ACCEPTED generation=\(generation)")
    appendLog("连接失败: \(errorDescription ?? "unknown")")
    terminateRememberedGallery(
      .bleConnectFailed(reason: errorDescription ?? "unknown")
    )
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
    if let resetToken = fullResetGate.completeDisconnect(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral)
    ) {
      appendObservation(
        "BLE_FULL_RESET_DISCONNECT_CONSUMED peripheralID=\(peripheral.identifier.uuidString) " +
        "generation=\(resetToken.generation)"
      )
      return
    }
    guard !fullResetGate.hasUnresolvedDisconnect else {
      appendObservation(
        "BLE_FULL_RESET_DISCONNECT_UNPROVEN peripheralID=" +
        peripheral.identifier.uuidString
      )
      return
    }

    if case .tearingDown(let probeID, let result) = pairingProbeState,
       peripheral.identifier == probeID {
      pairingProbeState = .completed(result)
      pairingProbePeripheral = nil
      appendObservation(
        "PAIRING_PROBE_DISCONNECT_CONSUMED peripheralID=\(peripheral.identifier.uuidString) " +
        "state=tearingDown"
      )
      completePairingProbeTeardownWaitersIfNeeded()
      return
    }

    if let teardownToken = pairingProbeTeardownGate.completeDisconnect(
      peripheralID: peripheral.identifier,
      peripheralIdentity: ObjectIdentifier(peripheral)
    ) {
      appendObservation(
        "PAIRING_PROBE_DISCONNECT_CONSUMED peripheralID=\(peripheral.identifier.uuidString) " +
        "generation=\(teardownToken.generation)"
      )
      return
    }
    guard !pairingProbeTeardownGate.hasUnresolvedDisconnect else {
      appendObservation(
        "PAIRING_PROBE_DISCONNECT_UNPROVEN peripheralID=\(peripheral.identifier.uuidString)"
      )
      return
    }

    // Pairing probe: if the probe peripheral disconnected, the probe failed.
    if pairingProbeState.targetPeripheralID == peripheral.identifier {
      if let error, CameraVendorPairingProbePolicy.isPairingInvalidError(error) {
        completePairingProbe(result: .pairingInvalid(reason: error.localizedDescription), reason: "didDisconnect-pairing-invalid")
      } else {
        completePairingProbe(result: .offline, reason: "didDisconnect")
      }
      return
    }

    guard case .activeMainline(let generation) =
      CameraVendorBluetoothDisconnectOwnershipPolicy.route(
        peripheralID: peripheral.identifier,
        peripheralIdentity: ObjectIdentifier(peripheral),
        activeMainlineToken: activeBluetoothConnectionToken
      ) else {
      appendObservation(
        "BLE_DISCONNECT_ORPHAN_IGNORED peripheralID=\(peripheral.identifier.uuidString)"
      )
      return
    }
    if bleConnectAttemptPeripheralID == peripheral.identifier,
       bleConnectAttemptPeripheralIdentity == ObjectIdentifier(peripheral) {
      cancelBleConnectAttempt(reason: "disconnected")
    }
    appendObservation("BLE_DISCONNECT_ACCEPTED generation=\(generation)")

    if let error {
      appendLog("连接断开: \(error.localizedDescription)")
      let nsError = error as NSError
      appendObservation(
        "BLE_DISCONNECTED error=\(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code) " +
        "pairingInvalidEvidence=\(CameraVendorPairingProbePolicy.isPairingInvalidError(error))"
      )
    } else {
      appendLog("连接断开")
      appendObservation("BLE_DISCONNECTED error=nil")
    }

    let wasExpectedWifiHandoff = awaitingBluetoothDisconnectForWifiHandoff
    let wasRecoveryInProgress =
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: secureHandshakePhase,
        retryCount: secureHandshakeReconnectCount
      ) || encryptionRecoveryPolicy.isAwaitingReconnect

    if selectedPeripheral?.identifier == peripheral.identifier,
       let rejectionReason = pendingRememberedRedReconnectIdentityRejectionReason {
      pendingRememberedRedReconnectIdentityRejectionReason = nil
      appendLog("已配对 RED 重连身份校验拒绝后断开 reason=\(rejectionReason.rawValue)")
      updateStatus("相机身份校验失败，请重新配对", isBusy: false)
      terminateRememberedGallery(.identityMismatch)
      return
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
        let disposition = CameraVendorActivationDisconnectPolicy.disposition(
          observedTransferReady: didReachTransferReadyState,
          recoveryAttempts: activationDisconnectRecoveryCount,
          maxRecoveryAttempts: maxActivationDisconnectRecoveryAttempts
        )
        appendObservation(
          "ACTIVATION_DISCONNECT_DISPOSITION disposition=\(String(describing: disposition)) " +
          "observedTransferReady=\(didReachTransferReadyState) " +
          "recoveryAttempts=\(activationDisconnectRecoveryCount)"
        )
        switch disposition {
        case .proceedToWifi:
          isRunningTransferActivation = false
          transferActivationStepDriver = nil
          activeActivationAttemptToken = nil
          currentTransferActivationStrategy = nil
          appendLog("触发传图后 BLE 已断开，按相机切换 Wi‑Fi 继续流程")
          finishHandshakeIfPossible()
        case .recoverPhase:
          isRunningTransferActivation = false
          transferActivationStepDriver = nil
          activeActivationAttemptToken = nil
          recoverTransferActivationAfterDisconnect(peripheral)
        case .activationDisconnected:
          isRunningTransferActivation = false
          transferActivationStepDriver = nil
          activeActivationAttemptToken = nil
          currentTransferActivationStrategy = nil
          appendLog("触发传图期间 BLE 已断开，但尚未观察到传图保留模式，暂不进入 Wi‑Fi/PTP")
          updateStatus(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus, isBusy: false)
          terminateRememberedGallery(.activationDisconnected)
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
        terminateRememberedGallery(.activationDisconnected)
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

    let didTerminateRememberedGallery =
      CameraVendorRememberedGalleryTerminalRouter.routeUnexpectedBleDisconnect(
        callbackPeripheralID: peripheral.identifier,
        intent: activeWirelessIntent,
        didCompleteHandshake: didCompleteHandshakeCallback,
        isExpectedWifiHandoff: wasExpectedWifiHandoff,
        isRecoveryInProgress: wasRecoveryInProgress,
        owner: rememberedGalleryTerminalOwner
      )
    if didTerminateRememberedGallery {
      appendObservation(
        "REMEMBERED_GALLERY_TERMINAL_FAILURE reason=\(CameraVendorRememberedGalleryTerminalFailure.bleDisconnected.issue.reason)"
      )
    }
    updateStatus("连接已断开", isBusy: false)
  }
}

extension CameraVendorBluetoothService: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    // Pairing probe: only discover the validation service's characteristics.
    if case .discoveringServices(let probeID) = pairingProbeState,
       peripheral.identifier == probeID {
      if let error {
        completePairingProbe(
          result: CameraVendorPairingProbePolicy.isPairingInvalidError(error)
            ? .pairingInvalid(reason: error.localizedDescription)
            : .offline,
          reason: "didDiscoverServices-error"
        )
        return
      }
      guard let service = peripheral.services?.first(where: {
        $0.uuid == CameraVendorPairingProbePolicy.validationServiceUUID
      }) else {
        completePairingProbe(
          result: .validationUnavailable(reason: "validation-service-not-found"),
          reason: "validation-service-not-found"
        )
        return
      }
      pairingProbeState = .readingCharacteristic(peripheralID: probeID)
      peripheral.discoverCharacteristics(
        [CameraVendorPairingProbePolicy.validationCharacteristicUUID],
        for: service
      )
      return
    }

    if let error {
      appendLog("发现服务失败: \(error.localizedDescription)")
      updateStatus("读取服务失败", isBusy: false)
      terminateRememberedGallery(
        .serviceDiscoveryFailed(reason: error.localizedDescription)
      )
      return
    }

    appendLog("发现服务数量: \(peripheral.services?.count ?? 0)")
    appendObservation(
      "GATT_IDENTITY_RESULT stage=serviceDiscovery result=success generation=\(wirelessConnectionGeneration) " +
      "services=\(peripheral.services?.map { $0.uuid.uuidString }.joined(separator: ",") ?? "-")"
    )
    for service in peripheral.services ?? [] {
      discoveredServiceUUIDStrings.insert(service.uuid.uuidString.uppercased())
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
    // Pairing probe: read the validation characteristic to test encryption.
    if case .readingCharacteristic(let probeID) = pairingProbeState,
       peripheral.identifier == probeID {
      if let error {
        completePairingProbe(
          result: CameraVendorPairingProbePolicy.isPairingInvalidError(error)
            ? .pairingInvalid(reason: error.localizedDescription)
            : .offline,
          reason: "didDiscoverCharacteristics-error"
        )
        return
      }
      guard let characteristic = service.characteristics?.first(where: {
        $0.uuid == CameraVendorPairingProbePolicy.validationCharacteristicUUID
      }) else {
        completePairingProbe(
          result: .validationUnavailable(reason: "validation-characteristic-not-found"),
          reason: "validation-characteristic-not-found"
        )
        return
      }
      peripheral.readValue(for: characteristic)
      return
    }

    if let error {
      appendObservation(
        "GATT_IDENTITY_RESULT stage=characteristicDiscovery result=failed " +
        "generation=\(wirelessConnectionGeneration) service=\(service.uuid.uuidString) " +
        "reason=\(error.localizedDescription)"
      )
      appendLog("发现特征失败: \(error.localizedDescription)")
      updateStatus("读取特征失败", isBusy: false)
      let didTerminateRememberedGallery =
        CameraVendorRememberedGalleryTerminalRouter.routeCharacteristicDiscoveryFailure(
          reason: error.localizedDescription,
          callbackPeripheralID: peripheral.identifier,
          intent: activeWirelessIntent,
          owner: rememberedGalleryTerminalOwner
        )
      if didTerminateRememberedGallery {
        appendObservation(
          "REMEMBERED_GALLERY_TERMINAL_FAILURE " +
          "reason=\(CameraVendorRememberedGalleryTerminalFailure.gattCharacteristicDiscoveryFailed(reason: error.localizedDescription).issue.reason)"
        )
      }
      return
    }

    for characteristic in service.characteristics ?? [] {
      discoveredCharacteristicsByUUID[characteristic.uuid] = characteristic
      appendLog(
        "特征 UUID: \(characteristic.uuid.uuidString) @ \(service.uuid.uuidString) | props \(propertyFlags(characteristic))"
      )
      if characteristic.uuid == pairingCharacteristicUUID {
        pairingCharacteristic = characteristic
      } else if characteristic.uuid == connectedApplicationInfoCharacteristicUUID {
        connectedApplicationInfoCharacteristic = characteristic
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

    appendObservation(
      "GATT_IDENTITY_RESULT stage=characteristicDiscovery result=success " +
      "generation=\(wirelessConnectionGeneration) service=\(service.uuid.uuidString) " +
      "count=\(service.characteristics?.count ?? 0)"
    )

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
    // Pairing probe: characteristic read result determines pairing validity.
    if case .readingCharacteristic(let probeID) = pairingProbeState,
       peripheral.identifier == probeID,
       characteristic.uuid == CameraVendorPairingProbePolicy.validationCharacteristicUUID {
      if let error {
        if CameraVendorPairingProbePolicy.isPairingInvalidError(error) {
          completePairingProbe(result: .pairingInvalid(reason: error.localizedDescription), reason: "characteristic-read-pairing-invalid")
        } else {
          completePairingProbe(result: .offline, reason: "characteristic-read-error: \(error.localizedDescription)")
        }
      } else {
        // Read succeeded — encryption link is valid, pairing is good.
        completePairingProbe(result: .online, reason: "characteristic-read-success")
      }
      return
    }

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

    if let data = characteristic.value {
      let payloadSummary = CameraDiagnosticSensitivityPolicy.isSensitiveBLEControl(
        kind: nil,
        characteristicUUID: characteristic.uuid.uuidString
      )
        ? CameraDiagnosticPayloadSummary.sensitiveControlSignal(
            name: "payload",
            direction: .cameraToApp,
            data: data
          )
        : CameraDiagnosticPayloadSummary.controlSignal(
            name: "payload",
            direction: .cameraToApp,
            data: data
          )
      appendObservation(
        "BLE_VALUE_UPDATE direction=cameraToApp uuid=\(characteristic.uuid.uuidString) " +
        payloadSummary
      )
    }

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

    if characteristic.uuid == firmwareRevisionCharacteristicUUID,
       let data = characteristic.value,
       let firmware = String(data: data, encoding: .utf8)?
       .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) {
      handshakeCoordinator.completeMetadataRead(characteristic.uuid.uuidString)
      discoveredFirmwareVersion = firmware.trimmingCharacters(in: .whitespacesAndNewlines)
      appendLog("相机固件版本: \(discoveredFirmwareVersion ?? "-")")
      refreshPendingHandshakeSummary(using: peripheral)
      maybeStartPairing(on: peripheral)
      return
    }

    if characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID {
      if let data = characteristic.value {
        appendLog("读取到已连接设备识别号: payload-redacted bytes=\(data.count)")
        secureIdentificationNumberAlreadyPaired =
          CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(data)
        if secureIdentificationNumberAlreadyPaired {
          appendLog("识别号已带应用标记，按已配对重连处理")
          appendObservation(
            "APP_REGISTRATION_RESULT result=existing-marker stage=identificationRead " +
            "generation=\(wirelessConnectionGeneration)"
          )
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
          appendObservation(
            "APP_REGISTRATION_RESULT result=invalid stage=identificationRead " +
            "generation=\(wirelessConnectionGeneration) reason=invalid-payload"
          )
          appendLog("已连接设备识别号长度异常")
          updateStatus("握手失败", isBusy: false)
          return
        }

        appendLog("回写识别号 ACK: payload-redacted bytes=\(ackPayload.count)")
        appendObservation(
          "APP_REGISTRATION_RESULT result=ack-requested stage=identificationRead " +
          "generation=\(wirelessConnectionGeneration)"
        )
        secureHandshakePhase = .awaitingIdentificationNumberWrite
        updateStatus("等待相机确认安全配对", isBusy: true)
        writeBleControlValue(ackPayload, to: characteristic, on: peripheral, kind: "identification-ack")
      } else {
        appendObservation(
          "APP_REGISTRATION_RESULT result=empty stage=identificationRead " +
          "generation=\(wirelessConnectionGeneration)"
        )
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
      let readyForCurrentTransferActivation = activeActivationDefinition.map {
        CameraVendorActivationStrategyExecutor.isComplete(
          definition: $0,
          uuidString: characteristicKey,
          value: data
        )
      } ?? false
      if isRunningTransferActivation,
         activeActivationDefinition.map({
           CameraVendorActivationStrategyExecutor.isTrackedStatusCharacteristic(
             uuidString: characteristicKey,
             definition: $0
           )
         }) ?? false,
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
          let responseProgressTimeoutSeconds = activeActivationDefinition?
            .retryTiming.responseProgressTimeoutSeconds ?? 15
          DispatchQueue.main.asyncAfter(
            deadline: .now() + responseProgressTimeoutSeconds,
            execute: extendedTimeout
          )
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
        appendObservation(
          "BLE_PROBE_RESULT direction=cameraToApp uuid=\(characteristic.uuid.uuidString) " +
          "service=\(serviceUUID) bytes=\(data.count)"
        )
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
    let characteristicKey = characteristic.uuid.uuidString.uppercased()
    let isActivationWriteCallback = isRunningTransferActivation
      && activeActivationDefinition?.writeSteps.contains(where: {
        $0.characteristicUUIDString.uppercased() == characteristicKey
      }) == true
    if isActivationWriteCallback {
      let characteristicIdentity = ObjectIdentifier(characteristic)
      let callbackToken = transferActivationWriteAttemptTokensByCharacteristicIdentity
        .removeValue(forKey: characteristicIdentity)
      switch CameraVendorActivationAttemptCallbackGate.decision(
        callbackToken: callbackToken,
        activeToken: activeActivationAttemptToken,
        callbackCharacteristicIdentity: characteristicIdentity
      ) {
      case .accept:
        break
      case .ignoreMissingToken:
        appendObservation(
          "ACTIVATION_WRITE_CALLBACK_IGNORED reason=missing-token " +
          "uuid=\(characteristic.uuid.uuidString) " +
          "peripheral=\(peripheral.identifier.uuidString)"
        )
        return
      case .ignoreMismatch:
        appendObservation(
          "ACTIVATION_WRITE_CALLBACK_IGNORED reason=token-mismatch " +
          "uuid=\(characteristic.uuid.uuidString) " +
          "callbackPeripheral=\(callbackToken?.attempt.peripheralID.uuidString ?? "none") " +
          "callbackGeneration=\(callbackToken.map { String($0.attempt.generation) } ?? "none") " +
          "activePeripheral=\(activeActivationAttemptToken?.peripheralID.uuidString ?? "none") " +
          "activeGeneration=\(activeActivationAttemptToken.map { String($0.generation) } ?? "none")"
        )
        return
      }
    }

    if let error = error as NSError? {
      let requestID = pendingBleWriteRequestIDsByCharacteristic.removeValue(forKey: ObjectIdentifier(characteristic)) ?? "none"
      appendObservation(
        "BLE_WRITE_RESULT requestID=\(requestID) generation=\(wirelessConnectionGeneration) uuid=\(characteristic.uuid.uuidString) result=error domain=\(error.domain) code=\(error.code) elapsedMs=unknown"
      )
      if characteristic.uuid == connectedApplicationInfoCharacteristicUUID,
         secureHandshakePhase == .awaitingConnectedApplicationInfoWrite {
        guard selectedPeripheral === peripheral,
              CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
                pendingGeneration: connectedApplicationInfoWriteGeneration,
                currentGeneration: wirelessConnectionGeneration,
                isCurrentCharacteristic: connectedApplicationInfoCharacteristic === characteristic
              ) else {
          appendObservation(
            "BLE_APP_INFO_WRITE_ERROR_IGNORED reason=stale-callback " +
            "generation=\(wirelessConnectionGeneration)"
          )
          return
        }
        failConnectedApplicationInfoHandshake(error.localizedDescription)
        return
      }
      if isRunningTransferActivation,
         transferActivationStepDriver?.isCurrentWriteCharacteristic(
           uuidString: characteristic.uuid.uuidString
         ) == true {
        appendLog("传图命令写入失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
        isRunningTransferActivation = false
        transferActivationStepDriver = nil
        activeActivationAttemptToken = nil
        transferActivationTimeoutWorkItem?.cancel()
        transferActivationTimeoutWorkItem = nil
        if !retryCurrentTransferActivationIfOwned(
          on: peripheral,
          source: "write-error"
        ) {
          finishHandshakeIfPossible()
        }
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

    let requestID = pendingBleWriteRequestIDsByCharacteristic.removeValue(forKey: ObjectIdentifier(characteristic)) ?? "none"
    appendObservation(
      "BLE_WRITE_RESULT requestID=\(requestID) generation=\(wirelessConnectionGeneration) uuid=\(characteristic.uuid.uuidString) result=success callback=received elapsedMs=unknown"
    )

    if characteristic.uuid == connectedApplicationInfoCharacteristicUUID,
       secureHandshakePhase == .awaitingConnectedApplicationInfoWrite {
      guard selectedPeripheral === peripheral,
            CameraVendorConnectedApplicationHandshakePolicy.acceptsWriteCallback(
              pendingGeneration: connectedApplicationInfoWriteGeneration,
              currentGeneration: wirelessConnectionGeneration,
              isCurrentCharacteristic: connectedApplicationInfoCharacteristic === characteristic
            ) else {
        appendObservation(
          "BLE_APP_INFO_WRITE_ACK_IGNORED reason=stale-callback " +
          "generation=\(wirelessConnectionGeneration)"
        )
        return
      }
      completeConnectedApplicationInfoWrite(on: peripheral)
      return
    }

    if isRunningTransferActivation,
       var stepDriver = transferActivationStepDriver,
       let acknowledgement = stepDriver.acknowledgeCurrentWrite(
         characteristicUUIDString: characteristic.uuid.uuidString
       ) {
      transferActivationStepDriver = stepDriver
      appendLog("传图命令写入成功 \(characteristic.uuid.uuidString)")
      appendObservation("BLE_BUSINESS_CONFIRMATION requestID=\(requestID) uuid=\(characteristic.uuid.uuidString) expected=activation-write observed=didWriteValue result=accepted")
      if acknowledgement.role == .imageResizeSetting {
        let payload = transferActivationWritePayloadsByUUID[characteristic.uuid.uuidString.uppercased()]
          ?? CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
        appendObservation(
          "BLE_IMAGE_RESIZE_WRITE_ACK payload=\(hexString(payload)) " +
          "mode=\(payload == CameraVendorTransferActivationResizePolicy.resizeEnabledPayload ? "compressed" : "original")"
        )
        if characteristic.properties.contains(.read) {
          peripheral.readValue(for: characteristic)
        }
      }
      if acknowledgement.postWriteDelaySeconds > 0 {
        DispatchQueue.main.asyncAfter(
          deadline: .now() + acknowledgement.postWriteDelaySeconds
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
      writeBleControlValue(payload, to: connectedDeviceNameCharacteristic, on: peripheral, kind: "device-name")
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
