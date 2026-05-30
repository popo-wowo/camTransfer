import CoreLocation
import CoreBluetooth
import Foundation
import NetworkExtension
import UIKit
import os.log

final class CameraVendorFileLogger {
  static let shared = CameraVendorFileLogger()
  private let fileURL: URL
  private let queue = DispatchQueue(label: "com.camtransfer.fileLogger")
  private init() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    fileURL = docs.appendingPathComponent("camtransfer_debug.log")
    // Append separator instead of overwriting — appendLog also writes to this file
    let separator = "\n=== CamTransfer Log \(Date()) ===\n"
    if let data = separator.data(using: .utf8),
       let h = try? FileHandle(forWritingTo: fileURL) {
      h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
      try? separator.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }
  static func log(_ message: String) {
    shared.queue.async {
      let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
      os_log("%{public}@", line)
      if let data = line.data(using: .utf8),
         let h = try? FileHandle(forWritingTo: shared.fileURL) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
      }
    }
  }
  static var logFileURL: URL { shared.fileURL }
}


struct CameraVendorWifiNetworkConfiguration: Codable, Equatable {
  let ssid: String
  let passphrase: String
  let isHidden: Bool
}

enum CameraVendorConnectionTransferMode: Equatable {
  case gallery
  case autoImageImport
}

struct CameraVendorConnectionSummary: Equatable {
  let deviceName: String
  let serialNumber: String
  let connectedDeviceName: String
  let preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?
  let transferMode: CameraVendorConnectionTransferMode

  init(
    deviceName: String,
    serialNumber: String,
    connectedDeviceName: String = CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName(),
    preferredWifiNetwork: CameraVendorWifiNetworkConfiguration? = nil,
    transferMode: CameraVendorConnectionTransferMode = .gallery
  ) {
    self.deviceName = deviceName
    self.serialNumber = serialNumber
    self.connectedDeviceName = connectedDeviceName
    self.preferredWifiNetwork = preferredWifiNetwork
    self.transferMode = transferMode
  }

  var navigationTitle: String { deviceName }
  var subtitle: String {
    switch transferMode {
    case .gallery:
      return "序列号 \(serialNumber)"
    case .autoImageImport:
      return "序列号 \(serialNumber) | HEIF/RAW 自动接收"
    }
  }
  var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] {
    var configurations: [CameraVendorWifiNetworkConfiguration] = []
    if let preferredWifiNetwork {
      if preferredWifiNetwork.isHidden {
        let visibleFallback = CameraVendorWifiNetworkConfiguration(
          ssid: preferredWifiNetwork.ssid,
          passphrase: preferredWifiNetwork.passphrase,
          isHidden: false
        )
        configurations.append(preferredWifiNetwork)
        configurations.append(visibleFallback)
      } else {
        configurations.append(preferredWifiNetwork)
      }
    }

    let cleanedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanedName.isEmpty {
      if let suffix = CameraVendorGalleryDiagnostics.cameraWifiSuffix(from: serialNumber) {
        let normalizedCleanedName = cleanedName.uppercased()
        let normalizedSuffix = "-\(suffix.uppercased())"
        let suffixedSSID = "\(cleanedName)-\(suffix)"
        let hasExistingSuffixedSSID = configurations.contains {
          $0.ssid.caseInsensitiveCompare(suffixedSSID) == .orderedSame
        }
        if !normalizedCleanedName.hasSuffix(normalizedSuffix), !hasExistingSuffixedSSID {
          configurations.append(
            CameraVendorWifiNetworkConfiguration(
              ssid: suffixedSSID,
              passphrase: "00000000",
              isHidden: false
            )
          )
        }
      }
      configurations.append(
        CameraVendorWifiNetworkConfiguration(
          ssid: cleanedName,
          passphrase: "00000000",
          isHidden: false
        )
      )
    }

    var seen: Set<String> = []
    var result: [CameraVendorWifiNetworkConfiguration] = []
    for configuration in configurations {
      let trimmedSSID = configuration.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
      let deduplicationKey = "\(trimmedSSID)|\(configuration.passphrase)|\(configuration.isHidden)"
      guard !trimmedSSID.isEmpty, !seen.contains(deduplicationKey) else {
        continue
      }
      seen.insert(deduplicationKey)
      result.append(
        CameraVendorWifiNetworkConfiguration(
          ssid: trimmedSSID,
          passphrase: configuration.passphrase,
          isHidden: configuration.isHidden
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

  private static let logFileURL: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("camtransfer_debug.log")
  }()

  static func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    let line = "[\(formatter.string(from: Date()))] \(message)"
    print("CamTransferGallery \(message)")
    NSLog("CamTransferGallery %@", message)
    appendToFile(line)
    externalLogHandler?(message)
  }

  static func observe(_ message: String) {
    log("[OBS] \(message)")
  }

  private static func appendToFile(_ line: String) {
    let data = (line + "\n").data(using: .utf8) ?? Data()
    if FileManager.default.fileExists(atPath: logFileURL.path) {
      if let handle = try? FileHandle(forWritingTo: logFileURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      }
    } else {
      try? data.write(to: logFileURL)
    }
  }

  static func readLogFile() -> String {
    (try? String(contentsOf: logFileURL)) ?? "(no log file)"
  }

  static func clearLogFile() {
    try? FileManager.default.removeItem(at: logFileURL)
  }

  static func composeFailureMessage(baseMessage: String, diagnostics: [String]) -> String {
    let lines = uniqueNonEmpty(diagnostics)
    guard !lines.isEmpty else {
      return baseMessage
    }
    return ([baseMessage, "诊断信息:"] + lines).joined(separator: "\n")
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
  static let automaticWifiJoinEnabled = false

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
    isCameraPtpReachable: Bool = false
  ) -> Bool {
    if currentSSIDMatchesCamera || isCameraPtpReachable {
      return false
    }
    // If the user explicitly returned from Settings and tapped reload, wait for
    // a concrete signal first; otherwise the PTP attempt never reaches camera.
    if skippedAutoJoinBecauseManual {
      return !currentSSIDMatchesCamera && !isCameraPtpReachable
    }
    return !didJoinWifiAutomatically && prefersManualWifiRecovery
  }

  static func shouldStopAutomaticWifiAttemptsAfterFailure(
    attemptedConfigurationIndex: Int
  ) -> Bool {
    attemptedConfigurationIndex == 0
  }
}

enum CameraVendorGalleryPtpStartupPolicy {
  static func startupDelaySeconds(didCompleteWifiHandoff: Bool) -> TimeInterval {
    3
  }
}

enum CameraVendorPtpConnectionStartupPolicy {
  static let commandConnectTimeoutSeconds: TimeInterval = 1.5

  static func retryDelaySeconds(afterFailedAttempt attempt: Int) -> TimeInterval {
    0.5
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

enum CameraVendorSearchModeAllPayload {
  static let objectFormatPropertyCode: UInt16 = 0xD604
  static let jpegObjectFormatMask: UInt16 = 0x0001
  static let heifObjectFormatMask: UInt16 = 0x0002
  static let rawObjectFormatMask: UInt16 = 0x0010

  static var stillImageObjectFormatMask: UInt16 {
    jpegObjectFormatMask | heifObjectFormatMask | rawObjectFormatMask
  }

  static func objectFormatMaskPayload(_ mask: UInt16) -> Data {
    var data = Data()
    data.append(littleEndian(UInt32(1)))
    data.append(littleEndian(UInt32(8)))
    data.append(littleEndian(objectFormatPropertyCode))
    data.append(littleEndian(mask))
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

enum CameraVendorPtpCommandSerializationPolicy {
  static let shouldSerializeCommandSocketAccess = true
}

enum CameraVendorThumbnailLoadPolicy {
  static let shouldLoadSequentially = true
}

enum CameraVendorPartialObjectRequestPolicy {
  /// Per-PartialObject chunk size. Was 1 MB which made big RAW transfers
  /// pay ~30 round-trips. Bumped to 4 MB so a 30-50 MB RAW now takes
  /// ~8-13 round-trips, shaving 10-15% off wall-clock time. Larger
  /// values (8MB+) start to risk camera-side buffer pressure on some
  /// firmware revisions, so 4 MB is the practical sweet spot.
  static let referenceAppInitialReadSize: UInt32 = 4 * 1_048_576
  static let maxReadBytesWithoutKnownObjectSize = 128 * 1_024 * 1_024

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

enum CameraVendorJpegDataPolicy {
  static func hasEndMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[data.count - 2] == 0xFF && data[data.count - 1] == 0xD9
  }

  static func hasStartMarker(_ data: Data) -> Bool {
    data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
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

enum CameraVendorReferenceAppGalleryReadyPollingPolicy {
  static let maxAttempts = 6
  static let delaySeconds: TimeInterval = 0.5

  static func shouldPoll(marker: UInt32?, attempt: Int) -> Bool {
    !CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: marker) && attempt < maxAttempts
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
    if ssidMatchesCamera(currentSSID, wifiConfigurations: wifiConfigurations) {
      return true
    }

    return isCameraPtpReachable
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

    guard CameraVendorPtpConstants.isCameraWifiIPv4Address(currentIP) else {
      return false
    }

    return true
  }

  static func shouldSkipAutomaticWifiJoin(
    currentSSID: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration],
    isCameraPtpReachable: Bool
  ) -> Bool {
    hasConfirmedCameraNetwork(
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
    baselineWifiIP: String?
  ) -> Bool {
    !isLoading
      && itemCount == 0
      && errorMessage?.isEmpty == false
      && CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: currentWifiIP,
        baselineWifiIP: baselineWifiIP,
        itemCount: itemCount,
        isLoading: isLoading
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

  init(
    peripheralID: UUID,
    deviceName: String,
    serialNumber: String,
    connectedDeviceName: String? = nil,
    appVariant: CameraVendorAppVariant,
    preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?
  ) {
    self.peripheralID = peripheralID
    self.deviceName = deviceName
    self.serialNumber = serialNumber
    self.connectedDeviceName = connectedDeviceName
    self.appVariant = appVariant
    self.preferredWifiNetwork = preferredWifiNetwork
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

final class CameraVendorPairedCameraStore {
  static let storageKey = "CamTransfer.LastPairedCamera"

  private let defaults: UserDefaults
  private let storageKey: String
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(
    defaults: UserDefaults = .standard,
    storageKey: String = CameraVendorPairedCameraStore.storageKey
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
  }

  func load() -> CameraVendorPairedCameraRecord? {
    guard let data = defaults.data(forKey: storageKey) else {
      return nil
    }

    guard let record = try? decoder.decode(CameraVendorPairedCameraRecord.self, from: data) else {
      defaults.removeObject(forKey: storageKey)
      return nil
    }

    return record
  }

  func save(_ record: CameraVendorPairedCameraRecord) {
    guard let data = try? encoder.encode(record) else {
      return
    }
    defaults.set(data, forKey: storageKey)
  }

  func clear() {
    defaults.removeObject(forKey: storageKey)
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
    isRememberedPeripheral || isAlreadyPairedIdentificationNumber
  }
}

enum CameraVendorGalleryLoadPolicy {
  static let shouldLoadAutomaticallyOnEntry = false
  static let shouldRetryAutomaticallyWhenAppBecomesActive = true

  static func shouldStartLoad(isLoading: Bool) -> Bool {
    !isLoading
  }

  static func shouldAllowManualReload(currentWifiIP: String?) -> Bool {
    CameraVendorPtpConstants.isCameraWifiIPv4Address(currentWifiIP)
  }

  static func shouldAutoLoadWhenCameraWifiReady(
    currentWifiIP: String?,
    baselineWifiIP: String?,
    itemCount: Int,
    isLoading: Bool
  ) -> Bool {
    shouldAllowManualReload(currentWifiIP: currentWifiIP)
      && itemCount == 0
      && !isLoading
  }
}

enum CameraVendorPostPairingTransferPolicy {
  static let shouldAutomaticallyPrepareTransferAfterPairing = true

  static func canStartTransfer(
    hasCompletedPairing: Bool,
    hasUserInitiatedTransfer: Bool
  ) -> Bool {
    hasCompletedPairing && (hasUserInitiatedTransfer || shouldAutomaticallyPrepareTransferAfterPairing)
  }
}

enum CameraVendorCameraPairingConfirmationPolicy {
  static func canFinishPairing(
    hasWrittenIdentifier: Bool,
    hasUserConfirmedCameraSuccess: Bool
  ) -> Bool {
    hasWrittenIdentifier && hasUserConfirmedCameraSuccess
  }
}

enum CameraVendorBluetoothConnectFailurePolicy {
  static func shouldClearRememberedPairing(for errorDescription: String?) -> Bool {
    normalized(errorDescription).contains("peer removed pairing information")
  }

  static func userFacingStatus(for errorDescription: String?) -> String {
    if shouldClearRememberedPairing(for: errorDescription) {
      return "请先在 iPhone 和相机里删除旧配对，再重新配对"
    }

    return "连接失败"
  }

  private static func normalized(_ errorDescription: String?) -> String {
    errorDescription?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
  }
}

enum CameraVendorWifiJoinDiagnostics {
  static let shouldRemoveExistingConfigurationBeforeJoin = false

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
    guard error.domain == NEHotspotConfigurationErrorDomain else {
      return false
    }

    return error.code == NEHotspotConfigurationError.internal.rawValue
      || error.code == NEHotspotConfigurationError.pending.rawValue
      || error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
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
      isHidden: true
    )
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
  // before handing over to Wi-Fi for camera image browsing.
  static let hiddenDiagnosticRoutes: [CameraVendorGalleryRoute] = [
    CameraVendorGalleryRoute(
      id: .strictReferenceApp,
      launchRequestPayload: Data([0x03, 0x00]),
      ptpStartupDelaySeconds: 3,
      allowsUnverifiedWifiHandoffAfterRecoverableError: true
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

enum CameraVendorReferenceAppAutoImageImportReadinessPolicy {
  static func isReady(apStateData: Data?, transferStateData: Data?) -> Bool {
    guard let apStateData,
          let transferStateData,
          CameraVendorReferenceAppApState(data: apStateData) == .launchedForReservedImageTransfer,
          CameraVendorReferenceAppTransferState(data: transferStateData) == .transferable else {
      return false
    }
    return true
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
          payload: CameraVendorTransferActivationResizePolicy.currentPayload
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
      return apState == .launched
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
    get { UserDefaults.standard.bool(forKey: preferenceKey) }
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
    !hadActivationFeature || !hasAttemptedActivation || observedChange || observedWifiLaunch
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
    strategy == .officialImportImage
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
    !transferActivationObservedChange
  }
}

struct CameraVendorGalleryItem: Equatable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: String
  let byteSizeText: String
  var thumbnailData: Data? = nil
}

enum CameraVendorDownloadedMediaType: Equatable {
  case photo
  case video
}

struct CameraVendorDownloadedFile {
  let fileURL: URL
  let filename: String
  let mediaType: CameraVendorDownloadedMediaType
}

enum CameraVendorGalleryDownloadPolicy {
  static func canDownloadOriginal(_ item: CameraVendorGalleryItem) -> Bool {
    item.formatLabel != "Video"
  }

  static func mediaType(for item: CameraVendorGalleryItem) -> CameraVendorDownloadedMediaType {
    item.formatLabel == "Video" ? .video : .photo
  }
}

enum CameraVendorDownloadState: Equatable {
  case idle
  case queued
  case downloading
  case saved
  case failed(String)
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

  mutating func enqueueDownloads(for handles: [Int]) {
    for handle in handles {
      guard downloadStates[handle] != .saved else { continue }
      downloadStates[handle] = .queued
      downloadProgress[handle] = nil
    }
    selectedHandles.subtract(handles)
  }

  mutating func markDownloadStarted(handle: Int) {
    downloadStates[handle] = .downloading
  }

  mutating func markDownloadStarted(handle: Int, position: Int, total: Int) {
    downloadStates[handle] = .downloading
    downloadProgress[handle] = CameraVendorDownloadProgress(position: position, total: total)
  }

  mutating func markDownloadFinished(handle: Int) {
    downloadStates[handle] = .saved
    downloadProgress[handle] = nil
  }

  mutating func markDownloadFailed(handle: Int, message: String) {
    downloadStates[handle] = .failed(message)
    downloadProgress[handle] = nil
  }

  mutating func updateThumbnail(handle: Int, data: Data) {
    guard let index = items.firstIndex(where: { $0.handle == handle }) else {
      return
    }
    items[index].thumbnailData = data
  }

  func downloadState(for handle: Int) -> CameraVendorDownloadState {
    downloadStates[handle] ?? .idle
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
    downloadStates
      .filter { $0.value == .queued }
      .map(\.key)
      .sorted()
  }

  func nextQueuedDownloadHandle() -> Int? {
    queuedDownloadHandles().first
  }

  func downloadProgressText(for handle: Int) -> String? {
    downloadProgress[handle]?.displayText
  }
}

protocol CameraVendorGalleryService {
  func fetchGallery() async throws -> [CameraVendorGalleryItem]
  func fetchThumbnail(for handle: Int) async throws -> Data
  func downloadOriginal(for handle: Int) async throws -> Data
  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile
}

/// A standalone PTP download worker that owns its own command socket so it
/// can run in parallel with the main `CameraVendorGalleryService` session. Created
/// via `CameraVendorParallelDownloadFactory.openWorker(...)`. Always call
/// `disconnect()` when finished so the camera frees the slot.
protocol CameraVendorParallelDownloadWorker: AnyObject {
  func downloadOriginal(for handle: Int) async throws -> Data
  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile
  func disconnect()
}

protocol CameraVendorParallelDownloadFactory: AnyObject {
  /// Opens a fresh PTP session that can serve `downloadOriginal` requests
  /// in parallel with other workers. Throws if the camera refuses an extra
  /// session (some CameraVendor bodies cap concurrent sessions at 1–2). The caller
  /// is responsible for calling `disconnect()` on the returned worker.
  func openParallelDownloadWorker() async throws -> CameraVendorParallelDownloadWorker
}

enum CameraVendorParallelDownloadPolicy {
  /// Hard cap on workers. Empirically the verified reference device accepts 2
  /// PTP sessions but reject the 3rd. Higher values usually saturate the
  /// camera Wi-Fi anyway, so 2 is the sweet spot.
  static let maxWorkers = 2

  static func desiredWorkerCount(for queueSize: Int) -> Int {
    if queueSize <= 1 { return 1 }
    return min(maxWorkers, max(1, queueSize))
  }
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
  func configureForDirectPTP()
}

struct CameraVendorGalleryStubService: CameraVendorGalleryService {
  func fetchGallery() async throws -> [CameraVendorGalleryItem] {
    [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "DSCF0001.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 16:58:12",
        byteSizeText: "4.2 MB"
      ),
      CameraVendorGalleryItem(
        handle: 2,
        filename: "DSCF0002.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 16:59:03",
        byteSizeText: "4.0 MB"
      ),
      CameraVendorGalleryItem(
        handle: 3,
        filename: "DSCF0003.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:41",
        byteSizeText: "4.1 MB"
      ),
    ]
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    try sampleJPEGData(seed: handle)
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    try sampleJPEGData(seed: handle)
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    let data = try sampleJPEGData(seed: handle)
    let filename = "CamTransfer-\(handle).jpg"
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("jpg")
    try data.write(to: fileURL, options: .atomic)
    return CameraVendorDownloadedFile(fileURL: fileURL, filename: filename, mediaType: .photo)
  }

  private func sampleJPEGData(seed: Int) throws -> Data {
    let variants: [String] = [
      "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAkGBxAQEBAQEA8QDw8PDw8PDw8PDw8QEA8QFREWFhURFRUYHSggGBolGxUVITEhJSkrLi4uFx8zODMsNygtLisBCgoKDg0OGxAQGy0mICYtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIAAEAAgMBIgACEQEDEQH/xAAXAAADAQAAAAAAAAAAAAAAAAAAAQID/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEAMQAAAB6A//xAAVEQEBAAAAAAAAAAAAAAAAAAAAEf/aAAgBAQABBQKf/8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAEP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAEP/aAAgBAQABPyF//9k=",
      "/9j/4AAQSkZJRgABAQAAAQABAAD/2wCEAAkGBxAQDw8QDw8PDw8PDw8PDw8PDw8PDw8PFREWFhURFRUYHSggGBolGxUVITEhJSkrLi4uFx8zODMsNygtLisBCgoKDg0OGxAQGy0mICUtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLf/AABEIAAEAAgMBIgACEQEDEQH/xAAXAAADAQAAAAAAAAAAAAAAAAAAAQID/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEAMQAAAB6B//xAAVEQEBAAAAAAAAAAAAAAAAAAAAEf/aAAgBAQABBQKf/8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAwEBPwF//8QAFBEBAAAAAAAAAAAAAAAAAAAAEP/aAAgBAgEBPwF//8QAFBABAAAAAAAAAAAAAAAAAAAAEP/aAAgBAQAGPwJ//8QAFBABAAAAAAAAAAAAAAAAAAAAEP/aAAgBAQABPyF//9k="
    ]
    let base64 = variants[abs(seed) % variants.count]
    guard let data = Data(base64Encoded: base64) else {
      throw NSError(domain: "CameraVendorGalleryStubService", code: -1)
    }
    return data
  }
}

struct CameraVendorOperationResponse {
  let dataPhase: UInt16
  let responseCode: UInt16
  let transactionID: UInt32
  let params: Data
}

enum CameraVendorPtpResponsePolicy {
  static let okResponseCode: UInt16 = 0x2001

  static func validateOK(responseCode: UInt16, operationName: String) throws {
    guard responseCode == okResponseCode else {
      throw NSError(domain: "CameraVendorPtpSession", code: Int(responseCode), userInfo: [
        NSLocalizedDescriptionKey:
          "\(operationName) 返回 PTP 响应码 0x\(String(format: "%04X", responseCode))"
      ])
    }
  }
}

enum CameraVendorPtpPacketType {
  static let initCommandRequest = 0x00000001
  static let initCommandAck = 0x00000002
  static let initEventRequest = 0x00000003
  static let initEventAck = 0x00000004
  static let initFail = 0x00000005
  static let operationRequest = 0x00000006
  static let operationResponse = 0x00000007
  static let startDataPacket = 0x00000009
  static let dataPacket = 0x0000000A
  static let endDataPacket = 0x0000000C
}

enum CameraVendorLegacyPacketMapper {
  static func packetType(forKind kind: UInt16) -> Int {
    switch kind {
    case 2, 21:
      return CameraVendorPtpPacketType.dataPacket
    case 3, 12:
      return CameraVendorPtpPacketType.operationResponse
    default:
      return Int(kind)
    }
  }

  static func operationResponsePayload(forKind kind: UInt16, body: Data) -> Data {
    guard kind == 12, body.count >= 6 else {
      return body
    }
    // CameraVendor legacy thumbnail/object streams finish with kind=12 whose first
    // word is not a standard PTP response code. Treat it as OK and preserve
    // the transaction bytes so the shared response parser can finish.
    var payload = Data([0x01, 0x20])
    payload.append(body.dropFirst(2).prefix(4))
    return payload
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

enum CameraVendorPtpOperationCode {
  static let openSession = 0x1002
  static let closeSession = 0x1003
  static let getStorageIDs = 0x1004
  static let getObjectHandles = 0x1007
  static let getObjectInfo = 0x1008
  static let getObject = 0x1009
  static let getThumb = 0x100A
  static let getDevicePropValue = 0x1015
  static let setDevicePropValue = 0x1016
  static let getPartialObject = 0x101B
  static let initiateOpenCapture = 0x101C
  static let mtpGetObjectPropList = 0x9805
  static let cameraVendorGetSearchModeDescAll = 0x9050
  static let cameraVendorSetSearchModeAll = 0x9051
  static let cameraVendorGetSearchModeAll = 0x9052
  static let cameraVendorGetSpecifiedObjectCountGroupByDate = 0x9053
  static let cameraVendorGetLatestObjectInfo = 0x9054
  static let cameraVendorGetExtensionThumb = 0x9055
  static let cameraVendorGetExtensionPartialObject = 0x9056
}

enum CameraVendorLegacyGalleryObjectInfoPolicy {
  static let shouldProbeStandardObjectHandlesWhenSpecifiedListIsSmall = true
  static let maxStandardObjectInfoProbeCount = 300
  static let shouldProbeDualSlotWhenSpecifiedListIsSmall = false
  static let shouldReadCurrentObjectHandleBeforeLatestProbe = true
  static let shouldReadCurrentObjectHandleViaObjectPropList = false
  static let shouldReadCurrentObjectHandleBeforeSpecifiedList = true
  static let shouldResetSearchModeBeforeFormatSearch = false
  static let shouldResetSearchModeDuringColdStart = false
  static let shouldReadSearchModeAllDuringColdStart = false
  static let shouldSetStillImageObjectFormatSearchMode = false
  static let shouldRefreshGalleryContextBeforeSpecifiedList = true

  static func shouldProbeStandardObjectInfos(
    afterSpecifiedInfos infos: [CameraVendorCameraObjectInfo]
  ) -> Bool {
    guard shouldProbeStandardObjectHandlesWhenSpecifiedListIsSmall else {
      return false
    }
    return !infos.contains { info in
      info.formatLabel == "HEIF" || info.formatLabel == "RAW"
    }
  }
}

enum CameraVendorReferenceAppCurrentImageContextPolicy {
  static let currentImageHandle: UInt32 = 0x10000001
  static let shouldPrimeBeforeImageHandleList = true
  static let shouldPrimeThumbnailBeforeSearchDescription = true
}

enum CameraVendorDualSlotProbePolicy {
  static let smallObjectCountThreshold = 2

  static func shouldProbeAlternateSlots(currentObjectCount: Int) -> Bool {
    currentObjectCount <= smallObjectCountThreshold
  }

  static func alternateSlotStatuses(for currentStatus: UInt8?) -> [UInt32] {
    switch currentStatus {
    case 1:
      return [2]
    case 2:
      return [1]
    default:
      return []
    }
  }
}

enum CameraVendorHiddenObjectHandleProbePolicy {
  static let maxGapRange: UInt32 = 120

  static func candidateHandles(from handles: [UInt32]) -> [UInt32] {
    let uniqueHandles = Set(handles)
    guard let minHandle = uniqueHandles.min(),
          let maxHandle = uniqueHandles.max(),
          maxHandle >= minHandle,
          maxHandle - minHandle <= maxGapRange else {
      return []
    }
    return (minHandle...maxHandle)
      .filter { !uniqueHandles.contains($0) }
      .sorted()
  }
}

enum CameraVendorOriginalDownloadPolicy {
  // ReferenceApp only sets this before its ReadImage transfer state machine. Pairing it
  // with plain GetObject leaves this camera waiting without a useful response.
  static let shouldSetForceCompressionBeforeStandardGetObject = false
  static let shouldAttemptStandardGetObjectDownload = false
  static let shouldDownloadUsingPartialObjectFallback = true

  static func correctFileSizePayload(enabled: Bool) -> Data {
    var value = UInt16(enabled ? 1 : 0).littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }
}

enum CameraVendorThumbnailFetchPolicy {
  static let shouldReadObjectInfoBeforeGetThumb = true
  static let shouldTryStandardGetThumbFirst = true
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

enum CameraVendorDevicePropCode {
  static let cameraState: UInt32 = 0xDF00
  static let initSequence: UInt32 = 0xDF01
  static let imageGetVersion: UInt32 = 0xDF21
  static let getObjectVersion: UInt32 = 0xDF22
  static let referenceAppImageHost: UInt32 = 0xDF28
  static let referenceAppReservedReceive: UInt32 = 0xDF29
  static let appVersion: UInt32 = 0xDF24
  static let remoteGetObjectVersion: UInt32 = 0xDF25
  static let referenceAppGalleryObjectContext: UInt32 = 0xD212
  static let referenceAppGalleryReadyMarker: UInt32 = 0xD222
  static let imageForceCompression: UInt32 = 0xD226
  static let imageCompressionRealInfo: UInt32 = 0xD227
  static let currentObjectHandle: UInt32 = 0xD22B
  static let compressionCutOff: UInt32 = 0xD235
  static let referenceAppGalleryAccessState: UInt32 = 0xD244
  static let dualSlotStatus: UInt32 = 0xD244
  static let specifiedObjectCount: UInt32 = 0xD620
  static let specifiedObjectHandles: UInt32 = 0xD621
}


enum CameraVendorPtpConstants {
  static let protocolVersion = 0x8F53E4F2
  static let standardPtpIpProtocolVersion = 0x00010000
  static let defaultHost = "192.168.0.1"
  static let commandPort = 55740
  static let eventPort = 55741
  static let allFormats = 0x00000000
  static let allHandles = 0xFFFFFFFF
  static let initGuidBaseWords: [UInt32] = [
    0x5D48A5AD,
    0x0B7FB287,
    0xD0DED5D3,
  ]
  static let initDeviceNameByteCount = 54

  /// Build GUID words. The fourth word is only filled when a caller has
  /// explicitly confirmed the current Wi-Fi IP.
  static func initGuidWords(clientIP: String? = nil) -> [UInt32] {
    var words = initGuidBaseWords
    var ipWord: UInt32 = 0
    if let ip = clientIP,
       isCameraWifiIPv4Address(ip) {
      var addr = in_addr()
      if inet_pton(AF_INET, ip, &addr) == 1 {
        ipWord = UInt32(bigEndian: addr.s_addr)
      }
    }
    words.append(ipWord)
    return words
  }

  static func isCameraWifiIPv4Address(_ ip: String?) -> Bool {
    ip?.hasPrefix("192.168.0.") == true
  }
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

struct CameraVendorPtpPacket {
  let type: Int
  let payload: Data
}

struct CameraVendorCameraObjectInfo: Equatable {
  let handle: Int
  let storageID: UInt32
  let formatCode: UInt16
  let compressedSize: UInt32
  let thumbCompressedSize: UInt32
  let filename: String
  let captureDate: String

  var formatLabel: String {
    switch formatCode {
    case 0x3801:
      return "JPG"
    case 0x3812:
      return "HEIF"
    case 0xB101, 0xB103:
      return "RAW"
    case 0x300B, 0x300D:
      return "Video"
    default:
      return String(format: "0x%04X", formatCode)
    }
  }

  static func placeholder(handle: UInt32) -> CameraVendorCameraObjectInfo {
    CameraVendorCameraObjectInfo(
      handle: Int(handle),
      storageID: 0,
      formatCode: 0x3801,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: String(format: "0x%08X.JPG", handle),
      captureDate: ""
    )
  }
}

enum CameraVendorPtpPacketBuilder {
  static func mtpObjectPropListParameters(
    objectHandle: UInt32,
    propertyCode: UInt32
  ) -> [UInt32] {
    [
      objectHandle,
      0,
      propertyCode,
      0,
      0,
    ]
  }

  static func buildInitCommandRequest(friendlyName: String, clientIP: String? = nil) -> Data {
    let guidWords = CameraVendorPtpConstants.initGuidWords(clientIP: clientIP)
    var payload = Data()
    payload.append(uint32LE(UInt32(CameraVendorPtpPacketType.initCommandRequest)))
    payload.append(uint32LE(UInt32(CameraVendorPtpConstants.protocolVersion)))
    for word in guidWords {
      payload.append(uint32LE(word))
    }
    payload.append(rawUtf16LEString(friendlyName, paddedTo: CameraVendorPtpConstants.initDeviceNameByteCount))
    // Prepend total length (including the 4-byte length field itself)
    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 4)))
    data.append(payload)
    return data
  }

  static func buildStandardInitCommandRequest(friendlyName: String, clientIP: String? = nil) -> Data {
    let guidWords = CameraVendorPtpConstants.initGuidWords(clientIP: clientIP)
    var payload = Data()
    payload.append(uint32LE(UInt32(CameraVendorPtpPacketType.initCommandRequest)))
    for word in guidWords {
      payload.append(uint32LE(word))
    }
    payload.append(ptpUnicodeString(friendlyName))
    payload.append(uint32LE(UInt32(CameraVendorPtpConstants.standardPtpIpProtocolVersion)))

    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 4)))
    data.append(payload)
    return data
  }

  static func buildInitEventRequest(connectionNumber: UInt32) -> Data {
    wrap(type: CameraVendorPtpPacketType.initEventRequest, payload: uint32LE(connectionNumber))
  }

  /// PTP/IP operation request.
  /// Wire format: [4 length][4 type=6][4 dataPhase][2 op][4 txn][4*N params]
  static func buildOperationRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    parameters: [UInt32] = [],
    dataPhase: UInt32 = 1
  ) -> Data {
    var payload = Data()
    payload.append(uint32LE(dataPhase))
    payload.append(uint16LE(operationCode))
    payload.append(uint32LE(transactionID))
    for parameter in parameters {
      payload.append(uint32LE(parameter))
    }
    return wrap(type: CameraVendorPtpPacketType.operationRequest, payload: payload)
  }

  /// CameraVendor legacy operation request observed from ReferenceApp after the legacy INIT:
  /// [4 length][2 dataPhase][2 op][4 txn][4*N params].
  static func buildCameraVendorLegacyOperationRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    parameters: [UInt32] = [],
    dataPhase: UInt16 = 1
  ) -> Data {
    var data = Data()
    let length = 4 + 2 + 2 + 4 + (parameters.count * 4)
    data.append(uint32LE(UInt32(length)))
    data.append(uint16LE(dataPhase))
    data.append(uint16LE(operationCode))
    data.append(uint32LE(transactionID))
    for parameter in parameters {
      data.append(uint32LE(parameter))
    }
    return data
  }

  static func buildCameraVendorDataOutRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    data: Data
  ) -> Data {
    buildEndDataPacket(transactionID: transactionID, data: data)
  }

  static func buildCameraVendorLegacyDataOutRequest(
    operationCode: UInt16,
    transactionID: UInt32,
    data: Data
  ) -> Data {
    var packet = Data()
    let length = 4 + 2 + 2 + 4 + data.count
    packet.append(uint32LE(UInt32(length)))
    packet.append(uint16LE(2))
    packet.append(uint16LE(operationCode))
    packet.append(uint32LE(transactionID))
    packet.append(data)
    return packet
  }

  /// CameraVendor data packets still use the standard [length][type] header format.
  static func buildStartDataPacket(transactionID: UInt32, totalLength: UInt32) -> Data {
    var payload = Data()
    payload.append(uint32LE(transactionID))
    payload.append(uint32LE(totalLength))
    return wrap(type: CameraVendorPtpPacketType.startDataPacket, payload: payload)
  }

  static func buildEndDataPacket(transactionID: UInt32, data: Data) -> Data {
    var payload = Data()
    payload.append(uint32LE(transactionID))
    payload.append(data)
    return wrap(type: CameraVendorPtpPacketType.endDataPacket, payload: payload)
  }

  private static func wrap(type: Int, payload: Data) -> Data {
    var data = Data()
    data.append(uint32LE(UInt32(payload.count + 8)))
    data.append(uint32LE(UInt32(type)))
    data.append(payload)
    return data
  }

  private static func ptpUnicodeString(_ string: String, paddedTo byteCount: Int? = nil) -> Data {
    var data = Data([UInt8(min(string.count + 1, 255))])
    for scalar in string.unicodeScalars {
      data.append(uint16LE(UInt16(scalar.value)))
    }
    data.append(uint16LE(0))
    if let byteCount {
      if data.count > byteCount {
        data = data.prefix(byteCount)
      } else if data.count < byteCount {
        data.append(Data(repeating: 0, count: byteCount - data.count))
      }
    }
    return data
  }

  private static func uint16LE(_ value: UInt16) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  private static func uint32LE(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }

  /// Raw UTF-16LE string without PTP length prefix, zero-padded to a fixed byte count.
  /// Used for CameraVendor init packets which expect plain UTF-16LE, not PTP string format.
  private static func rawUtf16LEString(_ string: String, paddedTo byteCount: Int) -> Data {
    var data = Data()
    for scalar in string.unicodeScalars {
      data.append(uint16LE(UInt16(scalar.value)))
    }
    // null terminator
    data.append(uint16LE(0))
    // pad or truncate to exact size
    if data.count > byteCount {
      data = data.prefix(byteCount)
    } else if data.count < byteCount {
      data.append(Data(repeating: 0, count: byteCount - data.count))
    }
    return data
  }
}

enum CameraVendorPtpDataParser {
  static func uint32Array(from data: Data) -> [UInt32] {
    guard data.count >= 4 else { return [] }
    let count = Int(uint32(from: data, offset: 0))
    var values: [UInt32] = []
    for index in 0..<count {
      let offset = 4 + (index * 4)
      guard offset + 4 <= data.count else { break }
      values.append(uint32(from: data, offset: offset))
    }
    return values
  }

  static func objectInfo(handle: Int, data: Data) -> CameraVendorCameraObjectInfo {
    let storageID = uint32(from: data, offset: 0)
    let formatCode = uint16(from: data, offset: 4)
    let compressedSize = uint32(from: data, offset: 8)
    let thumbCompressedSize = uint32(from: data, offset: 14)
    let filenameOffset = 52
    let filename = ptpString(from: data, offset: filenameOffset)
    let captureDateOffset = filenameOffset + ptpStringByteLength(from: data, offset: filenameOffset)
    let captureDate = ptpString(from: data, offset: captureDateOffset)
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID,
      formatCode: formatCode,
      compressedSize: compressedSize,
      thumbCompressedSize: thumbCompressedSize,
      filename: filename,
      captureDate: captureDate
    )
  }

  static func cameraVendorVendorObjectInfo(handle: Int, data: Data) -> CameraVendorCameraObjectInfo {
    let storageID = uint32(from: data, offset: 0)
    let formatCode = uint16(from: data, offset: 4)
    let compressedSize = uint32(from: data, offset: 8)
    let thumbCompressedSize = uint32(from: data, offset: 14)
    let filenameOffset = 54
    let filename = ptpString(from: data, offset: filenameOffset)
    let captureDateOffset = filenameOffset + ptpStringByteLength(from: data, offset: filenameOffset)
    let captureDate = ptpString(from: data, offset: captureDateOffset)
    return CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: storageID,
      formatCode: formatCode,
      compressedSize: compressedSize,
      thumbCompressedSize: thumbCompressedSize,
      filename: filename,
      captureDate: captureDate
    )
  }

  static func cameraVendorGalleryContextValue(for code: UInt32, in data: Data) -> UInt32? {
    guard data.count >= 10 else { return nil }
    for offset in 0...(data.count - 6) {
      let currentCode = UInt32(uint16(from: data, offset: offset))
      let valueOffset = offset + 2
      if currentCode == code {
        return uint32(from: data, offset: valueOffset)
      }
    }
    return nil
  }

  private static func ptpString(from data: Data, offset: Int) -> String {
    guard offset < data.count else { return "" }
    let charCount = Int(data[offset])
    guard charCount > 0 else { return "" }
    var scalars: [UnicodeScalar] = []
    var position = offset + 1
    for _ in 0..<charCount {
      guard position + 1 < data.count else { break }
      let codeUnit = uint16(from: data, offset: position)
      if codeUnit == 0 { break }
      if let scalar = UnicodeScalar(codeUnit) {
        scalars.append(scalar)
      }
      position += 2
    }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func ptpStringByteLength(from data: Data, offset: Int) -> Int {
    guard offset < data.count else { return 1 }
    return 1 + (Int(data[offset]) * 2)
  }

  private static func uint16(from data: Data, offset: Int) -> UInt16 {
    let low = UInt16(data[offset])
    let high = UInt16(data[offset + 1]) << 8
    return low | high
  }

  private static func uint32(from data: Data, offset: Int) -> UInt32 {
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1]) << 8
    let b2 = UInt32(data[offset + 2]) << 16
    let b3 = UInt32(data[offset + 3]) << 24
    return b0 | b1 | b2 | b3
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

private final class CameraVendorPtpSocket {
  private var fd: Int32 = -1

  func connect(
    host: String,
    port: Int,
    timeout: TimeInterval = 10,
    diagnosticHandler: ((String) -> Void)? = nil
  ) throws {
    CameraVendorFileLogger.log("CameraVendorPtpSocket.connect 开始: \(host):\(port)")
    diagnosticHandler?("PTP socket 连接 \(host):\(port)")

    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 socket"])
    }

    // Enable TCP_NODELAY (CameraVendor protocol requires low latency)
    var flag: Int32 = 1
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, socklen_t(MemoryLayout<Int32>.size))

    // Bump socket receive / send buffers from the iOS default (~256 KB)
    // to 2 MB. Speeds up bulk reads from the camera by giving the
    // TCP stack more room to absorb bursts without blocking the sender.
    var bufBytes: Int32 = 2 * 1024 * 1024
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))

    // Set non-blocking for connect with timeout
    let flags = fcntl(sock, F_GETFL, 0)
    fcntl(sock, F_SETFL, flags | O_NONBLOCK)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)

    let connectResult = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if connectResult < 0 && errno != EINPROGRESS {
      let err = String(cString: strerror(errno))
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: connect 失败: \(err)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "连接相机失败: \(err)"])
    }

    // Wait for connect to complete using poll()
    var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
    let timeoutMs = Int32(timeout * 1000)
    let pollResult = poll(&pfd, 1, timeoutMs)

    if pollResult <= 0 {
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接超时 \(host):\(port)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "连接相机超时"])
    }

    // Check for connect error
    var sockErr: Int32 = 0
    var sockErrLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &sockErrLen)
    if sockErr != 0 {
      let err = String(cString: strerror(sockErr))
      Darwin.close(sock)
      CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接错误: \(err)")
      throw NSError(domain: "CameraVendorPtpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "连接相机失败: \(err)"])
    }

    // Restore blocking mode for read/write
    fcntl(sock, F_SETFL, flags & ~O_NONBLOCK)

    fd = sock
    CameraVendorFileLogger.log("CameraVendorPtpSocket: 连接成功 \(host):\(port) fd=\(sock)")
    diagnosticHandler?("PTP socket 已连接 \(host):\(port)")
  }

  func write(_ data: Data) throws {
    guard fd >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "socket 未建立"])
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
      var written = 0
      while written < data.count {
        let count = Darwin.send(fd, baseAddress.advanced(by: written), data.count - written, 0)
        if count <= 0 {
          let err = String(cString: strerror(errno))
          throw NSError(domain: "CameraVendorPtpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "写入失败: \(err)"])
        }
        written += count
      }
    }
  }

  func readExactly(
    _ length: Int,
    timeout: TimeInterval = 10
  ) throws -> Data {
    guard fd >= 0 else {
      throw NSError(domain: "CameraVendorPtpSocket", code: 6, userInfo: [NSLocalizedDescriptionKey: "socket 未建立"])
    }
    var buffer = [UInt8](repeating: 0, count: length)
    var offset = 0
    let deadline = Date().addingTimeInterval(timeout)

    while offset < length {
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
      }

      // Use poll() to wait for data with timeout
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let pollMs = Int32(min(remaining * 1000, Double(Int32.max)))
      let pollResult = poll(&pfd, 1, pollMs)

      if pollResult < 0 {
        let err = String(cString: strerror(errno))
        throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
      }
      if pollResult == 0 {
        throw NSError(domain: "CameraVendorPtpSocket", code: 9, userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"])
      }

      // Check for errors, but allow reading if POLLIN is also set (data may arrive with HUP)
      if Int16(pfd.revents) & Int16(POLLERR | POLLNVAL) != 0 {
        throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机断开连接"])
      }

      let count = Darwin.recv(fd, &buffer[offset], length - offset, 0)
      if count < 0 {
        let err = String(cString: strerror(errno))
        throw NSError(domain: "CameraVendorPtpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "读取失败: \(err)"])
      }
      if count == 0 {
        throw NSError(domain: "CameraVendorPtpSocket", code: 8, userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 \(offset)/\(length) 字节)"])
      }
      offset += count
    }
    return Data(buffer)
  }

  func close() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }
}

private final class CameraVendorPtpSession {
  private let commandSocket = CameraVendorPtpSocket()
  private let eventSocket = CameraVendorPtpSocket()
  private let commandLock = NSLock()
  private var connectionNumber: UInt32 = 0
  private var transactionID: UInt32 = 0
  private var isConnected = false
  private var operationTransport: CameraVendorPtpOperationTransport = .standardPtpIp
  private var diagnosticHandler: ((String) -> Void)?
  private var cameraVendorSpecifiedObjectHandles: [UInt32] = []
  private var cameraVendorCurrentSlotStatus: UInt8?

  func connect(
    host: String = CameraVendorPtpConstants.defaultHost,
    clientName: String = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName,
    commandConnectTimeout: TimeInterval = CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
    diagnosticHandler: ((String) -> Void)? = nil,
    purpose: CameraVendorPtpSessionPurpose = .gallery
  ) throws {
    disconnect()
    transactionID = 0
    cameraVendorSpecifiedObjectHandles = []
    self.diagnosticHandler = diagnosticHandler

    report("准备连接 PTP 命令端口 \(host):\(CameraVendorPtpConstants.commandPort)")
    report("[OBS] PTP_CONNECT_START host=\(host) port=\(CameraVendorPtpConstants.commandPort) clientName=\(clientName)")
    try commandSocket.connect(
      host: host,
      port: CameraVendorPtpConstants.commandPort,
      timeout: commandConnectTimeout,
      diagnosticHandler: diagnosticHandler
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
      try performCameraVendorLegacyReferenceAppGalleryHandshake()
    case (.cameraVendorLegacy, .reservedReceiveDiagnostic):
      try performCameraVendorReservedReceiveDiagnosticHandshake()
    case (.standardPtpIp, .gallery):
      try performStandardGalleryHandshake()
    case (.standardPtpIp, .reservedReceiveDiagnostic):
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState),
        userInfo: [NSLocalizedDescriptionKey: "Reserved Receive 诊断需要 CameraVendor legacy PTP 连接"]
      )
    }

    isConnected = true
    report("PTP 连接完成，purpose=\(purpose)")
    report("[OBS] PTP_HANDSHAKE_OK purpose=\(purpose)")
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

  private func performCameraVendorLegacyReferenceAppGalleryHandshake() throws {
    // Match the successful ReferenceApp import-image sequence observed on DEVICE-A.
    report("执行 CameraVendor/ReferenceApp legacy 图库握手")

    let initialContext = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp 图库上下文 (0xD212)"
    )
    reportCameraVendorGalleryContextMarker(initialContext)

    _ = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.initSequence,
      name: "CameraVendor/ReferenceApp ClientState 当前值 (0xDF01)"
    )

    try setCameraVendorReferenceAppClientState(
      CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState,
      reason: "referenceApp-remote-image-viewer"
    )

    let imageHostVersion = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppImageHost,
      name: "CameraVendor/ReferenceApp ImageHost (0xDF28)"
    )

    let versionToWrite = CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: imageHostVersion)
    report("按 ReferenceApp 图库模式回写 CameraVendor/ReferenceApp ImageHost 版本 (0xDF28 = \(versionToWrite))")
    _ = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      parameters: [CameraVendorDevicePropCode.referenceAppImageHost],
      data: littleEndianData(versionToWrite)
    )

    probeCameraVendorReservedReceiveModeIfNeeded()

    _ = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryAccessState,
      name: "CameraVendor/ReferenceApp 图库访问状态 #1 (0xD244)"
    )

    _ = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
      name: "CameraVendor/ReferenceApp 图库上下文 #2 (0xD212)"
    )

    _ = try readCameraVendorDeviceProperty(
      code: CameraVendorDevicePropCode.referenceAppGalleryAccessState,
      name: "CameraVendor/ReferenceApp 图库访问状态 #2 (0xD244)"
    )

    primeCameraVendorCurrentImageContextIfNeeded(stage: "before-search-mode-desc")
    primeCameraVendorCurrentThumbnailContextIfNeeded(stage: "before-search-mode-desc")
    try requestCameraVendorSearchModeDescAll()
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadSearchModeAllDuringColdStart {
      try requestCameraVendorSearchModeAll()
    } else {
      report("[OBS] PTP_SEARCH_MODE_ALL_SKIPPED reason=pcap-cold-start")
    }
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeSpecifiedList {
      requestCameraVendorCurrentObjectHandleSnapshot(stage: "before-specified-list")
    }
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldSetStillImageObjectFormatSearchMode {
      if CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeBeforeFormatSearch {
        try resetCameraVendorSearchModeAll(stage: "before-still-format-search-mode")
        try requestCameraVendorSearchModeAll(stage: "after-reset-before-still-format-search-mode")
      }
      try setCameraVendorStillImageObjectFormatSearchMode()
      try requestCameraVendorSearchModeAll(stage: "after-still-format-search-mode")
    }
    try requestCameraVendorSpecifiedObjectSnapshot(stage: "referenceApp-cold-start")
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldResetSearchModeDuringColdStart {
      try resetCameraVendorSearchModeAll(stage: "cold-start-empty-search-mode")
      try requestCameraVendorSearchModeAll(stage: "after-empty-search-mode")
    } else {
      report("[OBS] PTP_SET_SEARCH_MODE_ALL_EMPTY_SKIPPED reason=pcap-cold-start")
    }

    report("CameraVendor/ReferenceApp legacy 图库握手完成")
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

  private func requestCameraVendorSearchModeAll(stage: String = "initial") throws {
    report("按 ReferenceApp 初始化链请求 SearchModeAll (0x9052) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll)
    )
    let preview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_SEARCH_MODE_ALL stage=\(stage) bytes=\(data.count) head=\(preview)")
  }

  private func waitForCameraVendorGalleryReadyMarker(stage: String) {
    for attempt in 1...CameraVendorReferenceAppGalleryReadyPollingPolicy.maxAttempts {
      do {
        let context = try readCameraVendorDeviceProperty(
          code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
          name: "CameraVendor/ReferenceApp 图库 ready 轮询 (0xD212)"
        )
        let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
          for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
          in: context
        )
        reportCameraVendorGalleryContextMarker(context)
        report(
          "[OBS] PTP_D222_READY_POLL stage=\(stage) attempt=\(attempt) " +
          "value=\(marker.map { String(format: "0x%04X", $0) } ?? "nil")"
        )
        guard CameraVendorReferenceAppGalleryReadyPollingPolicy.shouldPoll(marker: marker, attempt: attempt) else {
          return
        }
      } catch {
        report("[OBS] PTP_D222_READY_POLL_FAILED stage=\(stage) attempt=\(attempt) error=\(error.localizedDescription)")
      }
      Thread.sleep(forTimeInterval: CameraVendorReferenceAppGalleryReadyPollingPolicy.delaySeconds)
    }
  }

  private func primeCameraVendorCurrentImageContextIfNeeded(stage: String) {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList else {
      return
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前图上下文 (0x9054, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let data = try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
        parameters: [handle]
      )
      let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
      report(
        "[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME stage=\(stage) bytes=\(data.count) head=\(preview)"
      )
    } catch {
      report("[OBS] PTP_CURRENT_IMAGE_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
    }
  }

  private func primeCameraVendorCurrentThumbnailContextIfNeeded(stage: String) {
    guard CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription else {
      return
    }

    let handle = CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    report(
      "按 ReferenceApp 初始化链预热当前缩略图上下文 (0x9055, handle=0x\(String(format: "%08X", handle))) stage=\(stage)"
    )
    do {
      let data = try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb),
        parameters: [handle]
      )
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME stage=\(stage) bytes=\(data.count)")
    } catch {
      report("[OBS] PTP_CURRENT_THUMB_CONTEXT_PRIME_FAILED stage=\(stage) error=\(error.localizedDescription)")
    }
  }

  private func requestCameraVendorCurrentObjectHandleSnapshot(stage: String) {
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleViaObjectPropList,
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
    let payload = CameraVendorSearchModeAllPayload.objectFormatMaskPayload(mask)
    report(
      "[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT_BEGIN " +
      "property=0x\(String(format: "%04X", CameraVendorSearchModeAllPayload.objectFormatPropertyCode)) " +
      "mask=0x\(String(format: "%04X", mask)) payload=\(payload.map { String(format: "%02x", $0) }.joined())"
    )
    let response = try sendCommandWithData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      data: payload
    )
    report("[OBS] PTP_SET_SEARCH_MODE_OBJECT_FORMAT response=0x\(String(format: "%04X", response.responseCode))")
  }

  private func resetCameraVendorCompressionMode() throws {
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
      data: littleEndianData(mode)
    )
    report("[OBS] PTP_SET_IMAGE_FORCE_COMPRESSION mode=\(mode) reason=\(reason) response=0x\(String(format: "%04X", response.responseCode))")
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

  private func requestCameraVendorSpecifiedObjectSnapshot(stage: String) throws {
    report("[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_BEGIN stage=\(stage)")
    try requestCameraVendorSpecifiedObjectCountGroupByDate(stage: stage)
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldRefreshGalleryContextBeforeSpecifiedList {
      let context = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp 图库上下文 before specified list (0xD212)"
      )
      reportCameraVendorGalleryContextMarker(context)
      report("[OBS] PTP_D212_BEFORE_SPECIFIED_LIST stage=\(stage) bytes=\(context.map { String(format: "%02x", $0) }.joined(separator: ""))")
    }
    let count = try requestCameraVendorSpecifiedObjectCount(stage: stage)
    let handles = try requestCameraVendorSpecifiedObjectHandles(stage: stage)
    report(
      "[OBS] PTP_SPECIFIED_OBJECT_SNAPSHOT_END stage=\(stage) " +
      "count=\(count.map(String.init) ?? "nil") handles=\(handles.count)"
    )
  }

  private func requestCameraVendorSpecifiedObjectCountGroupByDate(stage: String = "default") throws {
    report("按 ReferenceApp 图片列表链请求 SpecifiedObjectCountGroupByDate (0x9053, offset=0, count=30000) stage=\(stage)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate),
      parameters: [0, 30000]
    )
    let preview = data.prefix(96).map { String(format: "%02x", $0) }.joined(separator: "")
    report("[OBS] PTP_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE stage=\(stage) bytes=\(data.count) head=\(preview)")
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

  private func readCameraVendorDeviceProperty(code: UInt32, name: String) throws -> Data {
    report("读取 \(name)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getDevicePropValue),
      parameters: [code]
    )
    report("\(name): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
    return data
  }

  private func validateCameraVendorGalleryReadyMarker(_ context: Data) throws {
    let marker = CameraVendorPtpDataParser.cameraVendorGalleryContextValue(
      for: CameraVendorDevicePropCode.referenceAppGalleryReadyMarker,
      in: context
    )
    guard CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: marker) else {
      let actual = marker.map { String(format: "0x%04X", $0) } ?? "nil"
      report("[OBS] PTP_D222_NOT_READY value=\(actual) expected=0x0992")
      if CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: marker) {
        report("CameraVendor/ReferenceApp 图库未 ready，探测模式继续发送 0x9054: D222=\(actual), expected=0x0992")
        return
      }
      report("CameraVendor/ReferenceApp 图库未 ready，停止本次严格路径: D222=\(actual), expected=0x0992")
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: 0xD222,
        userInfo: [
          NSLocalizedDescriptionKey: "相机图库状态未 ready: D222=\(actual)，不继续发送 0x9054"
        ]
      )
    }
    report("[OBS] PTP_D222_READY value=\(marker.map { String(format: "0x%04X", $0) } ?? "nil")")
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

  /// Poll CameraState (0xDF00) until camera grants access.
  /// On first connection, user may need to press OK on camera.
  private func waitForCameraAccess() throws {
    let maxPolls = 40  // 40 * 0.5s = 20 seconds max
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

    let attempts: [
      (name: String, packet: Data, timeout: TimeInterval, operationTransport: CameraVendorPtpOperationTransport)
    ] = [
      (
        "CameraVendor legacy + client IP GUID",
        CameraVendorPtpPacketBuilder.buildInitCommandRequest(
          friendlyName: clientName,
          clientIP: clientIP
        ),
        12,
        .cameraVendorLegacy
      ),
    ]

    var lastError: Error?
    for (index, attempt) in attempts.enumerated() {
      if index > 0 {
        report("重新建立 PTP socket，尝试 \(attempt.name) INIT")
        commandSocket.close()
        try commandSocket.connect(
          host: host,
          port: CameraVendorPtpConstants.commandPort,
          timeout: CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds,
          diagnosticHandler: diagnosticHandler
        )
      }

      do {
        let connectionNumber = try sendInitCommandRequest(
          packet: attempt.packet,
          variantName: attempt.name,
          timeout: attempt.timeout
        )
        return (connectionNumber, attempt.operationTransport)
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

  func objectInfo(handle: UInt32) throws -> CameraVendorCameraObjectInfo {
    report("请求对象信息 handle \(handle)")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getObjectInfo),
      parameters: [handle]
    )
    let info = CameraVendorPtpDataParser.objectInfo(handle: Int(handle), data: data)
    report("对象 \(handle): \(info.filename) \(info.formatLabel)")
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

  func galleryObjectInfos() throws -> [CameraVendorCameraObjectInfo] {
    switch operationTransport {
    case .standardPtpIp:
      let storageIDs = try storageIDs()
      var infos: [CameraVendorCameraObjectInfo] = []
      for storageID in storageIDs {
        let handles = try objectHandles(storageID: storageID)
        for handle in handles {
          infos.append(try objectInfo(handle: handle))
        }
      }
      return infos
    case .cameraVendorLegacy:
      if !cameraVendorSpecifiedObjectHandles.isEmpty {
        let specifiedInfos = try cameraVendorLegacySpecifiedObjectInfos(handles: cameraVendorSpecifiedObjectHandles)
        if CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectInfos(afterSpecifiedInfos: specifiedInfos) {
          let hiddenInfos = cameraVendorLegacyHiddenObjectInfos(
            specifiedHandles: cameraVendorSpecifiedObjectHandles,
            currentInfos: specifiedInfos
          )
          if hiddenInfos.contains(where: { $0.formatLabel == "HEIF" || $0.formatLabel == "RAW" }) {
            let merged = mergeObjectInfos(specifiedInfos + hiddenInfos)
            report(
              "[OBS] PTP_HIDDEN_OBJECT_INFOS_SELECTED " +
              "specified=\(specifiedInfos.count) hidden=\(hiddenInfos.count) merged=\(merged.count)"
            )
            return merged
          }
          do {
            let standardInfos = try cameraVendorLegacyStandardObjectInfos()
            let standardHasExtendedStill = standardInfos.contains { info in
              info.formatLabel == "HEIF" || info.formatLabel == "RAW"
            }
            if standardHasExtendedStill || standardInfos.count > specifiedInfos.count {
              report(
                "[OBS] PTP_LEGACY_STANDARD_OBJECT_INFOS_SELECTED " +
                "specified=\(specifiedInfos.count) standard=\(standardInfos.count) " +
                "hasExtendedStill=\(standardHasExtendedStill)"
              )
              return standardInfos
            }
            report(
              "[OBS] PTP_LEGACY_STANDARD_OBJECT_INFOS_NOT_SELECTED " +
              "specified=\(specifiedInfos.count) standard=\(standardInfos.count)"
            )
          } catch {
            report("[OBS] PTP_LEGACY_STANDARD_OBJECT_INFOS_PROBE_FAILED error=\(error.localizedDescription)")
          }
        }
        if CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeDualSlotWhenSpecifiedListIsSmall,
           CameraVendorDualSlotProbePolicy.shouldProbeAlternateSlots(currentObjectCount: specifiedInfos.count) {
          let mergedInfos = try cameraVendorLegacyObjectInfosByProbingAlternateSlots(currentInfos: specifiedInfos)
          if mergedInfos.count > specifiedInfos.count {
            report(
              "[OBS] PTP_DUAL_SLOT_OBJECT_INFOS_SELECTED " +
              "current=\(specifiedInfos.count) merged=\(mergedInfos.count)"
            )
            return mergedInfos
          }
        }
        return specifiedInfos
      }
      if CameraVendorLegacyGalleryObjectInfoPolicy.shouldProbeStandardObjectHandlesWhenSpecifiedListIsSmall,
         let infos = try? cameraVendorLegacyStandardObjectInfos(),
         !infos.isEmpty {
        return infos
      }
      return [try cameraVendorLatestObjectInfo()]
    }
  }

  private func cameraVendorLegacyStandardObjectInfos() throws -> [CameraVendorCameraObjectInfo] {
    report("尝试 CameraVendor legacy 包装的标准对象列表路径 (StorageIDs -> ObjectHandles -> ObjectInfo)")
    let storageIDs = try storageIDs()
    report("[OBS] PTP_LEGACY_STANDARD_STORAGE_IDS values=\(storageIDs.map { String(format: "0x%08X", $0) }.joined(separator: ","))")
    var infos: [CameraVendorCameraObjectInfo] = []
    for storageID in storageIDs {
      let handles = try objectHandles(storageID: storageID)
      report(
        "[OBS] PTP_LEGACY_STANDARD_HANDLES storageID=\(String(format: "0x%08X", storageID)) " +
        "count=\(handles.count) sample=\(handles.prefix(10).map { String(format: "0x%08X", $0) }.joined(separator: ","))"
      )
      for handle in handles.prefix(CameraVendorLegacyGalleryObjectInfoPolicy.maxStandardObjectInfoProbeCount) {
        do {
          infos.append(try objectInfo(handle: handle))
        } catch {
          report("[OBS] PTP_LEGACY_STANDARD_OBJECT_INFO_FAILED handle=\(String(format: "0x%08X", handle)) error=\(error.localizedDescription)")
        }
      }
    }
    report("[OBS] PTP_LEGACY_STANDARD_OBJECT_INFOS count=\(infos.count)")
    return infos
  }

  private func cameraVendorLegacyHiddenObjectInfos(
    specifiedHandles: [UInt32],
    currentInfos: [CameraVendorCameraObjectInfo]
  ) -> [CameraVendorCameraObjectInfo] {
    let candidates = CameraVendorHiddenObjectHandleProbePolicy.candidateHandles(from: specifiedHandles)
    guard !candidates.isEmpty else {
      report("[OBS] PTP_HIDDEN_OBJECT_PROBE_SKIPPED reason=no-gap-candidates")
      return []
    }

    report(
      "[OBS] PTP_HIDDEN_OBJECT_PROBE_BEGIN candidates=" +
      candidates.map { String(format: "0x%08X", $0) }.joined(separator: ",")
    )
    let existingHandles = Set(currentInfos.map { UInt32($0.handle) })
    var infos: [CameraVendorCameraObjectInfo] = []
    for handle in candidates where !existingHandles.contains(handle) {
      do {
        let info = try objectInfo(handle: handle)
        infos.append(info)
        report(
          "[OBS] PTP_HIDDEN_OBJECT_INFO handle=0x\(String(format: "%08X", handle)) " +
          "format=\(info.formatLabel) filename=\(info.filename)"
        )
      } catch {
        report("[OBS] PTP_HIDDEN_OBJECT_INFO_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }
    report("[OBS] PTP_HIDDEN_OBJECT_PROBE_END count=\(infos.count)")
    return infos
  }

  private func mergeObjectInfos(_ infos: [CameraVendorCameraObjectInfo]) -> [CameraVendorCameraObjectInfo] {
    var byHandle: [Int: CameraVendorCameraObjectInfo] = [:]
    for info in infos {
      byHandle[info.handle] = info
    }
    return byHandle.values.sorted { $0.handle > $1.handle }
  }

  private func cameraVendorLegacyObjectInfosByProbingAlternateSlots(
    currentInfos: [CameraVendorCameraObjectInfo]
  ) throws -> [CameraVendorCameraObjectInfo] {
    let originalSlotStatus = cameraVendorCurrentSlotStatus
    var infosByHandle = Dictionary(uniqueKeysWithValues: currentInfos.map { ($0.handle, $0) })
    let alternateStatuses = CameraVendorDualSlotProbePolicy.alternateSlotStatuses(for: originalSlotStatus)

    guard !alternateStatuses.isEmpty else {
      report("[OBS] PTP_DUAL_SLOT_PROBE_SKIPPED currentStatus=\(originalSlotStatus.map(String.init) ?? "nil")")
      return currentInfos
    }

    for slotStatus in alternateStatuses {
      do {
        try setCameraVendorCardSlotStatus(slotStatus)
        try requestCameraVendorSearchModeAll(stage: "slot-\(slotStatus)-before-list")
        try requestCameraVendorSpecifiedObjectSnapshot(stage: "slot-\(slotStatus)")
        let handles = cameraVendorSpecifiedObjectHandles
        report(
          "[OBS] PTP_DUAL_SLOT_HANDLES slotStatus=\(slotStatus) count=\(handles.count) " +
          "handles=\(handles.map { String(format: "0x%08X", $0) }.joined(separator: ","))"
        )
        let slotInfos = try cameraVendorLegacySpecifiedObjectInfos(handles: handles)
        for info in slotInfos {
          infosByHandle[info.handle] = info
        }
      } catch {
        report("[OBS] PTP_DUAL_SLOT_PROBE_FAILED slotStatus=\(slotStatus) error=\(error.localizedDescription)")
      }
    }

    if let originalSlotStatus {
      do {
        try setCameraVendorCardSlotStatus(UInt32(originalSlotStatus))
        try requestCameraVendorSpecifiedObjectSnapshot(stage: "slot-restore-\(originalSlotStatus)")
      } catch {
        report("[OBS] PTP_DUAL_SLOT_RESTORE_FAILED status=\(originalSlotStatus) error=\(error.localizedDescription)")
      }
    }

    return currentInfos + infosByHandle.values
      .filter { newInfo in !currentInfos.contains(where: { $0.handle == newInfo.handle }) }
      .sorted { $0.handle > $1.handle }
  }

  private func cameraVendorLegacySpecifiedObjectInfos(handles: [UInt32]) throws -> [CameraVendorCameraObjectInfo] {
    report(
      "使用 ReferenceApp SpecifiedObjectHandles 读取图库对象: " +
      handles.map { String(format: "0x%08X", $0) }.joined(separator: ",")
    )
    var infos: [CameraVendorCameraObjectInfo] = []
    for handle in handles {
      do {
        infos.append(try objectInfo(handle: handle))
      } catch {
        report("[OBS] PTP_SPECIFIED_OBJECT_INFO_FAILED handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
        infos.append(CameraVendorCameraObjectInfo.placeholder(handle: handle))
      }
    }
    report("[OBS] PTP_SPECIFIED_OBJECT_INFOS count=\(infos.count)")
    return infos
  }

  func cameraVendorLatestObjectInfo() throws -> CameraVendorCameraObjectInfo {
    try prepareCameraVendorVendorGalleryCommands()
    var handle = UInt32(0x10000001)
    if CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleBeforeLatestProbe {
      if CameraVendorLegacyGalleryObjectInfoPolicy.shouldReadCurrentObjectHandleViaObjectPropList,
         let currentHandle = try? readCameraVendorCurrentObjectHandleViaObjectPropList(),
         currentHandle != 0 {
        handle = currentHandle
      }
      do {
        if let currentHandle = try readCameraVendorCurrentObjectHandle(), currentHandle != 0 {
          handle = currentHandle
        }
      } catch {
        report("[OBS] PTP_CURRENT_OBJECT_HANDLE_FAILED error=\(error.localizedDescription)")
      }
    }
    report("请求 CameraVendor 专有图库首图信息 (0x9054, handle 0x\(String(format: "%08X", handle)))")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetLatestObjectInfo),
      parameters: [handle]
    )
    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: Int(handle), data: data)
    report("CameraVendor 专有图库首图: \(info.filename) \(info.formatLabel)")
    return info
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
      name: "CameraVendor/ReferenceApp 当前对象 handle (0xD22B)"
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
    if CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst {
      do {
        let data = try readStandardThumbnailObject(handle: handle)
        return normalizedThumbnailData(data, handle: handle, source: "standardGetThumb")
      } catch {
        report("[OBS] PTP_GET_THUMB_FALLBACK_TO_PARTIAL handle=0x\(String(format: "%08X", handle)) error=\(error.localizedDescription)")
      }
    }

    let data = try readPreviewObject(handle: handle)
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW_EXPECTED handle=0x\(String(format: "%08X", handle)) expectedSize=\(expectedSize ?? 0) bytes=\(data.count)")
    return normalizedThumbnailData(data, handle: handle, source: "standardPartialPreview")
  }

  private func readStandardThumbnailObject(handle: UInt32) throws -> Data {
    if CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb {
      _ = try objectInfo(handle: handle)
    }

    report("[OBS] PTP_GET_THUMB_REQUEST handle=0x\(String(format: "%08X", handle))")
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getThumb),
      parameters: [handle]
    )
    report("[OBS] PTP_GET_THUMB_DATA bytes=\(data.count) handle=0x\(String(format: "%08X", handle))")
    guard data.count >= CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes else {
      throw NSError(
        domain: "CameraVendorPtpSession",
        code: Int(CameraVendorPtpOperationCode.getThumb),
        userInfo: [
          NSLocalizedDescriptionKey: "GetThumb returned too few bytes: \(data.count)"
        ]
      )
    }
    return data
  }

  private func readPreviewObject(handle: UInt32) throws -> Data {
    report(
      "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=preview " +
      "handle=0x\(String(format: "%08X", handle)) offset=0 size=\(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize)"
    )
    let data = try sendCommandForData(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(handle: handle)
    )
    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_PREVIEW bytes=\(data.count) handle=0x\(String(format: "%08X", handle))")
    return data
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
    purpose: String
  ) throws -> Data {
    var received = Data()
    if let expected = expectedSize, expected > 0 {
      // Pre-allocate so chunk appends don't trigger O(n) reallocations.
      received.reserveCapacity(Int(expected))
    }
    var offset: UInt64 = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = max(
      expectedByteCount ?? 0,
      UInt64(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize)
    )
    var isJpegObject = false

    while offset < maxByteCount {
      let remaining = maxByteCount - offset
      let requestSize = UInt32(min(UInt64(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize), remaining))
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) expected=\(expectedSize ?? 0)"
      )
      let chunk = try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
          handle: handle,
          offset: offset,
          size: requestSize
        )
      )
      guard !chunk.isEmpty else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }

      received.append(chunk)
      if offset == 0 {
        isJpegObject = CameraVendorJpegDataPolicy.hasStartMarker(CameraVendorImageDataNormalizer.imageData(from: received))
      }
      offset += UInt64(chunk.count)
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(chunk.count) totalBytes=\(received.count) isJpeg=\(isJpegObject)"
      )

      let hasJpegEndMarker = CameraVendorJpegDataPolicy.hasEndMarker(received)
      if CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: received.count,
        expectedBytes: expectedByteCount,
        isJpegObject: isJpegObject,
        hasJpegEndMarker: hasJpegEndMarker
      ) {
        let reason = hasJpegEndMarker ? "jpeg-eoi" : "expected-size"
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=\(reason) handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count)")
        return received
      }
    }

    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=max-or-empty handle=0x\(String(format: "%08X", handle)) totalBytes=\(received.count)")
    return received
  }

  private func readObjectByPartialObjectsToFile(
    handle: UInt32,
    expectedSize: UInt32?,
    fileURL: URL,
    purpose: String
  ) throws -> Int {
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    let handleForWriting = try FileHandle(forWritingTo: fileURL)
    defer {
      try? handleForWriting.close()
    }

    var offset: UInt64 = 0
    var totalBytes = 0
    let expectedByteCount = expectedSize.map(UInt64.init)
    let maxByteCount = max(
      expectedByteCount ?? 0,
      UInt64(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize)
    )

    while offset < maxByteCount {
      let remaining = maxByteCount - offset
      let requestSize = UInt32(min(UInt64(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize), remaining))
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) offset=\(offset) size=\(requestSize) expected=\(expectedSize ?? 0)"
      )
      let chunk = try sendCommandForData(
        operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
        parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
          handle: handle,
          offset: offset,
          size: requestSize
        )
      )
      guard !chunk.isEmpty else {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_EMPTY handle=0x\(String(format: "%08X", handle)) offset=\(offset)")
        break
      }
      try handleForWriting.write(contentsOf: chunk)
      totalBytes += chunk.count
      offset += UInt64(chunk.count)
      report(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK purpose=\(purpose) " +
        "handle=0x\(String(format: "%08X", handle)) chunkBytes=\(chunk.count) totalBytes=\(totalBytes)"
      )
      if let expectedByteCount, UInt64(totalBytes) >= expectedByteCount {
        report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=expected-size handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes)")
        return totalBytes
      }
    }

    report("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_COMPLETE reason=max-or-empty handle=0x\(String(format: "%08X", handle)) totalBytes=\(totalBytes)")
    return totalBytes
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
    }
    do {
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.referenceAppGalleryObjectContext,
        name: "CameraVendor/ReferenceApp EventsList before file download (0xD212)"
      )
      _ = try readCameraVendorDeviceProperty(
        code: CameraVendorDevicePropCode.compressionCutOff,
        name: "CameraVendor CompressionCutOff/PartialSize (0xD235)"
      )

      let realInfoResponse = try sendCommandWithData(
        operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
        parameters: [CameraVendorDevicePropCode.imageCompressionRealInfo],
        data: CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: true)
      )
      shouldResetRealInfo = true
      report("[OBS] PTP_DOWNLOAD_SET_REAL_INFO_ONE response=0x\(String(format: "%04X", realInfoResponse.responseCode))")

      let freshInfo = try objectInfo(handle: handle)
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

  func objectFile(handle: UInt32, expectedSize: UInt32?, filename: String) throws -> URL {
    let fileExtension = ((filename as NSString).pathExtension.isEmpty ? "bin" : (filename as NSString).pathExtension)
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    do {
      let info = try objectInfo(handle: handle)
      let expectedSize = info.compressedSize.nonzero ?? expectedSize
      _ = try readObjectByPartialObjectsToFile(
        handle: handle,
        expectedSize: expectedSize,
        fileURL: fileURL,
        purpose: "download-file"
      )
      return fileURL
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
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
    diagnosticHandler = nil
  }

  private func sendCommand(operationCode: UInt16, parameters: [UInt32] = []) throws -> CameraVendorOperationResponse {
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
      return try readCameraVendorOperationResponse()
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

  private func sendCommandForData(operationCode: UInt16, parameters: [UInt32] = []) throws -> Data {
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

      var received = Data()
      while true {
        let packet = try readOperationPacket(timeout: 15)
        switch packet.type {
        case CameraVendorPtpPacketType.startDataPacket:
          report("收到 StartDataPacket (\(packet.payload.count) bytes)")
        case CameraVendorPtpPacketType.dataPacket:
          received.append(packet.payload)
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.endDataPacket:
          if packet.payload.count > 4 {
            received.append(packet.payload.dropFirst(4))
          }
          report("收到数据包 type=\(packet.type), 当前数据大小=\(received.count)")
        case CameraVendorPtpPacketType.operationResponse:
          let response = try parseOperationResponsePayload(packet.payload)
          report("操作响应: responseCode=0x\(String(response.responseCode, radix: 16)), 总数据大小=\(received.count)")
          try CameraVendorPtpResponsePolicy.validateOK(
            responseCode: response.responseCode,
            operationName: String(format: "PTP operation 0x%04X", operationCode)
          )
          return received
        default:
          throw NSError(domain: "CameraVendorPtpSession", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "读取数据时收到未知 PTP 包类型 \(packet.type)"
          ])
        }
      }
    }
  }

  private func readCameraVendorOperationResponse() throws -> CameraVendorOperationResponse {
    let packet = try readOperationPacket(timeout: 15)
    guard packet.type == CameraVendorPtpPacketType.operationResponse else {
      throw NSError(domain: "CameraVendorPtpSession", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "收到未知 PTP 包类型 \(packet.type)，期望 OperationResponse"
      ])
    }
    let response = try parseOperationResponsePayload(packet.payload)
    report("CameraVendor 操作响应: responseCode=0x\(String(response.responseCode, radix: 16)) txnID=\(response.transactionID)")
    try CameraVendorPtpResponsePolicy.validateOK(
      responseCode: response.responseCode,
      operationName: "PTP command"
    )
    return response
  }

  private func readOperationPacket(timeout: TimeInterval = 10) throws -> CameraVendorPtpPacket {
    switch operationTransport {
    case .standardPtpIp:
      return try readPacket(from: commandSocket, timeout: timeout)
    case .cameraVendorLegacy:
      return try readCameraVendorLegacyPacket(from: commandSocket, timeout: timeout)
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
    timeout: TimeInterval = 10
  ) throws -> CameraVendorPtpPacket {
    report("等待 CameraVendor legacy PTP 包头")
    let header = try socket.readExactly(4, timeout: timeout)
    guard header.count == 4 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包头读取失败"])
    }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length >= 6 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包长度异常 \(length)"])
    }
    let payload = try socket.readExactly(Int(length) - 4, timeout: timeout)
    guard payload.count >= 2 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "CameraVendor legacy PTP 包内容为空"])
    }
    let kind = payload.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    let body = payload.subdata(in: 2..<payload.count)
    report("收到 CameraVendor legacy PTP 包 kind=\(kind) length=\(length)")
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

  /// Read a standard PTP/IP packet with [4 length][4 type] header.
  private func readPacket(from socket: CameraVendorPtpSocket, timeout: TimeInterval = 10) throws -> CameraVendorPtpPacket {
    report("等待 PTP 包头")
    let header = try socket.readExactly(8, timeout: timeout)
    guard header.count == 8 else {
      throw NSError(domain: "CameraVendorPtpSession", code: 5, userInfo: [NSLocalizedDescriptionKey: "PTP 包头读取失败"])
    }
    let length = header.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let type = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    let payloadLength = Int(length) - 8
    let payload = payloadLength > 0 ? try socket.readExactly(payloadLength, timeout: timeout) : Data()
    report("收到 PTP 包 type=\(type) length=\(length)")
    return CameraVendorPtpPacket(type: Int(type), payload: payload)
  }

  private func report(_ message: String) {
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
      NEHotspotConfigurationManager.shared.apply(hotspotConfiguration) { error in
        if let nsError = error as NSError? {
          if nsError.domain == NEHotspotConfigurationErrorDomain,
             nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            report("Wi-Fi 已关联到 \(configuration.ssid)")
            continuation.resume(returning: nil)
            return
          }
          report(
            "Wi-Fi 连接失败 \(configuration.ssid): " +
            CameraVendorWifiJoinDiagnostics.describeHotspotError(nsError)
          )
          report("[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) error=\(CameraVendorWifiJoinDiagnostics.describeHotspotError(nsError))")
          continuation.resume(returning: nsError)
          return
        }

        report("Wi-Fi 连接请求已提交: \(configuration.ssid)")
        report("[OBS] WIFI_APPLY_RESULT ssid=\(configuration.ssid) error=nil")
        continuation.resume(returning: nil)
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
        // Brief stabilization delay — gives the camera's TCP listener
        // time to settle after the phone finishes WiFi association.
        try await Task.sleep(nanoseconds: 2_000_000_000)
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

final class CameraVendorPtpDownloadWorker: CameraVendorParallelDownloadWorker {
  private let session: CameraVendorPtpSession
  private let diagnosticHandler: ((String) -> Void)?
  private let objectInfoLookup: (Int) -> CameraVendorCameraObjectInfo?

  fileprivate init(
    session: CameraVendorPtpSession,
    diagnosticHandler: ((String) -> Void)?,
    objectInfoLookup: @escaping (Int) -> CameraVendorCameraObjectInfo?
  ) {
    self.session = session
    self.diagnosticHandler = diagnosticHandler
    self.objectInfoLookup = objectInfoLookup
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    let expectedSize = objectInfoLookup(handle)?.compressedSize.nonzero
    return try await Task.detached(priority: .userInitiated) {
      try self.session.object(handle: UInt32(handle), expectedSize: expectedSize)
    }.value
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    let info = objectInfoLookup(handle)
    let expectedSize = info?.compressedSize.nonzero
    let filename = info?.filename ?? "CamTransfer-\(handle).jpg"
    let formatLabel = info?.formatLabel ?? "JPG"
    let captureDate = info?.captureDate ?? ""
    let item = CameraVendorGalleryItem(
      handle: handle,
      filename: filename,
      formatLabel: formatLabel,
      captureDate: captureDate,
      byteSizeText: ""
    )
    let mediaType = CameraVendorGalleryDownloadPolicy.mediaType(for: item)
    let fileURL = try await Task.detached(priority: .userInitiated) {
      try self.session.objectFile(
        handle: UInt32(handle),
        expectedSize: expectedSize,
        filename: filename
      )
    }.value
    return CameraVendorDownloadedFile(fileURL: fileURL, filename: filename, mediaType: mediaType)
  }

  func disconnect() {
    session.disconnect()
  }
}

final class CameraVendorRealtimeGalleryService: CameraVendorGalleryService, CameraVendorGalleryDiagnosticReporting, CameraVendorGalleryConfigurable, CameraVendorReservedReceiveDiagnosticService, CameraVendorParallelDownloadFactory {
  private let session = CameraVendorPtpSession()
  private var objectInfoCache: [Int: CameraVendorCameraObjectInfo] = [:]
  var diagnosticHandler: ((String) -> Void)?
  private var wifiConfigurations: [CameraVendorWifiNetworkConfiguration] = []
  private var ptpClientName = CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
  private var prefersManualWifiRecovery = false
  private var manualWifiPromptBaselineIP: String?
  private var directPTPMode = false
  private var transferMode: CameraVendorConnectionTransferMode = .gallery
  /// Re-entrancy guard: prevents parallel PTP connections that conflict with each other.
  private let fetchLock = NSLock()
  private var isFetching = false

  func configure(connectionSummary: CameraVendorConnectionSummary) {
    wifiConfigurations = connectionSummary.wifiConfigurations
    ptpClientName = connectionSummary.connectedDeviceName
    prefersManualWifiRecovery = false
    manualWifiPromptBaselineIP = nil
    directPTPMode = false
    transferMode = connectionSummary.transferMode
  }

  func configureForDirectPTP() {
    wifiConfigurations = []
    ptpClientName = CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName()
    prefersManualWifiRecovery = false
    manualWifiPromptBaselineIP = nil
    directPTPMode = true
    transferMode = .gallery
  }

  func fetchGallery() async throws -> [CameraVendorGalleryItem] {
    CameraVendorFileLogger.log("fetchGallery: wifiConfigs=\(wifiConfigurations.count) prefersManual=\(prefersManualWifiRecovery) directPTP=\(directPTPMode)")
    report(
      "[OBS] GALLERY_FETCH_START wifiConfigs=\(wifiConfigurations.map(\.ssid).joined(separator: ",")) " +
      "clientName=\(ptpClientName) directPTP=\(directPTPMode) transferMode=\(transferMode)"
    )

    if transferMode == .autoImageImport {
      return try await fetchAutoImageImportGallery()
    }

    // Re-entrancy protection: the camera accepts only one PTP command connection.
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
    fetchLock.unlock()

    defer {
      fetchLock.lock()
      isFetching = false
      fetchLock.unlock()
    }

    if directPTPMode {
      report("直接 PTP 模式：跳过所有 Wi-Fi 检测，直接连接相机")
      return try fetchGallerySync(
        route: CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes[0],
        didCompleteWifiHandoff: true
      )
    }

    let diagnosticRoutes = CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes
    let wifiHandoffRoute = diagnosticRoutes.first
    var lastWifiJoinError: Error?
    var didJoinWifiAutomatically = false
    var skippedAutoJoinBecauseManual = false

    // Skip port probing here — it can exhaust the camera's single PTP
    // connection slot. Just check SSID if available.
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
      report("检测到 iPhone 已连接相机网络，跳过自动切换 Wi‑Fi，直接尝试 PTP")
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
              wifiHandoffRoute?.allowsUnverifiedWifiHandoffAfterRecoverableError ?? false,
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
      report("没有可用的相机 Wi-Fi 名称候选，继续直接尝试 PTP")
    }

    let postJoinSnapshot = await waitForManualCameraWifiIfNeeded(
      skippedAutoJoinBecauseManual: skippedAutoJoinBecauseManual,
      wifiConfigurations: wifiConfigurations,
      manualPromptBaselineIP: manualWifiPromptBaselineIP,
      report: report
    )
    let postJoinSSID = postJoinSnapshot.ssid
    let postJoinWifiIP = postJoinSnapshot.ip
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
      isCameraPtpReachable: skippedAutoJoinBecauseManual ? manualRecoveryNetworkEvidence : postJoinConfirmedCameraNetwork
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

    let didCompleteWifiHandoff =
      hasConfirmedCameraNetwork ||
      postJoinConfirmedCameraNetwork ||
      didJoinWifiAutomatically ||
      skippedAutoJoinBecauseManual
    report(
      "[OBS] WIFI_HANDOFF_RESULT didJoinAutomatically=\(didJoinWifiAutomatically) " +
      "skippedManual=\(skippedAutoJoinBecauseManual) didComplete=\(didCompleteWifiHandoff) " +
      "currentSSID=\(postJoinSSID ?? "nil") ip=\(postJoinWifiIP ?? "nil") " +
      "ptpReachable=\(manualPtpReachable) manualEvidence=\(manualRecoveryNetworkEvidence)"
    )
    var lastRouteError: Error?
    for (routeIndex, route) in diagnosticRoutes.enumerated() {
      do {
        CameraVendorFileLogger.log("进入 fetchGallerySync route=\(route.id.rawValue) (Task.detached)")
        report("[ROUTE \(routeIndex + 1)/\(diagnosticRoutes.count)] 开始 \(route.id.rawValue)")
        let items = try await Task.detached(priority: .userInitiated) {
          try self.fetchGallerySync(route: route, didCompleteWifiHandoff: didCompleteWifiHandoff)
        }.value
        if CameraVendorGalleryRoutePolicy.shouldStopRouteSearch(after: items) {
          report("[ROUTE \(route.id.rawValue)] 成功，停止路线探测")
          prefersManualWifiRecovery = false
          return items
        }
        report("[ROUTE \(route.id.rawValue)] 没有读取到对象，继续下一条路线")
      } catch {
        lastRouteError = error
        report("[ROUTE \(route.id.rawValue)] 失败: \(error.localizedDescription)")
        session.disconnect()
      }

      if routeIndex < diagnosticRoutes.count - 1 {
        try await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }

    throw lastRouteError ?? NSError(
      domain: "CameraVendorRealtimeGalleryService",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "所有 ReferenceApp 路线均未读取到图片"]
    )
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

  private func isCameraWifiReady(
    ssid: String?,
    ip: String?,
    wifiConfigurations: [CameraVendorWifiNetworkConfiguration]
  ) -> Bool {
    let ssidMatchesCamera = ssid.map { currentSSID in
      wifiConfigurations.contains { $0.ssid == currentSSID }
    } ?? false
    return ssidMatchesCamera || CameraVendorPtpConstants.isCameraWifiIPv4Address(ip)
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    return try await Task.detached(priority: .userInitiated) {
      try self.session.thumb(handle: UInt32(handle), expectedSize: expectedSize)
    }.value
  }

  func downloadOriginal(for handle: Int) async throws -> Data {
    let expectedSize = objectInfoCache[handle]?.compressedSize.nonzero
    return try await Task.detached(priority: .userInitiated) {
      try self.session.object(handle: UInt32(handle), expectedSize: expectedSize)
    }.value
  }

  func openParallelDownloadWorker() async throws -> CameraVendorParallelDownloadWorker {
    let clientName = ptpClientName
    let handler = diagnosticHandler
    let workerSession = CameraVendorPtpSession()
    let cacheSnapshot = objectInfoCache
    do {
      try await Task.detached(priority: .userInitiated) {
        try workerSession.connect(
          clientName: clientName + "-w2",
          diagnosticHandler: handler,
          purpose: .gallery
        )
      }.value
    } catch {
      workerSession.disconnect()
      throw error
    }
    return CameraVendorPtpDownloadWorker(
      session: workerSession,
      diagnosticHandler: handler,
      objectInfoLookup: { handle in cacheSnapshot[handle] }
    )
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    let info = objectInfoCache[handle]
    let expectedSize = info?.compressedSize.nonzero
    let filename = info?.filename ?? "CamTransfer-\(handle).jpg"
    let item = CameraVendorGalleryItem(
      handle: handle,
      filename: filename,
      formatLabel: info?.formatLabel ?? "JPG",
      captureDate: info?.captureDate ?? "",
      byteSizeText: ""
    )
    let mediaType = CameraVendorGalleryDownloadPolicy.mediaType(for: item)
    let fileURL = try await Task.detached(priority: .userInitiated) {
      try self.session.objectFile(
        handle: UInt32(handle),
        expectedSize: expectedSize,
        filename: filename
      )
    }.value
    return CameraVendorDownloadedFile(fileURL: fileURL, filename: filename, mediaType: mediaType)
  }

  private func fetchAutoImageImportGallery() async throws -> [CameraVendorGalleryItem] {
    report("[OBS] AUTO_IMAGE_IMPORT_FETCH_START")
    let clientName = ptpClientName
    let info = try await Task.detached(priority: .userInitiated) {
      let autoImportSession = CameraVendorPtpSession()
      defer {
        autoImportSession.disconnect()
      }
      try autoImportSession.connect(
        clientName: clientName,
        diagnosticHandler: { [weak self] message in
          self?.report(message)
        },
        purpose: .reservedReceiveDiagnostic
      )
      return try autoImportSession.reservedReceiveObjectInfo()
    }.value
    objectInfoCache[info.handle] = info
    report(
      "[OBS] AUTO_IMAGE_IMPORT_FETCH_INFO " +
      "handle=\(info.handle) format=\(info.formatLabel) filename=\(info.filename) size=\(info.compressedSize)"
    )
    return [
      CameraVendorGalleryItem(
        handle: info.handle,
        filename: info.filename,
        formatLabel: info.formatLabel,
        captureDate: info.captureDate,
        byteSizeText: ByteCountFormatter.string(fromByteCount: Int64(info.compressedSize), countStyle: .file)
      )
    ]
  }

  func probeReservedReceive() async throws -> CameraVendorReservedReceiveDiagnosticResult {
    report("[OBS] RESERVED_RECEIVE_DIAGNOSTIC_START directPTP=\(directPTPMode)")
    fetchLock.lock()
    if isFetching {
      session.disconnect()
    }
    isFetching = true
    fetchLock.unlock()

    defer {
      fetchLock.lock()
      isFetching = false
      fetchLock.unlock()
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

  private func fetchGallerySync(
    route: CameraVendorGalleryRoute,
    didCompleteWifiHandoff: Bool = false
  ) throws -> [CameraVendorGalleryItem] {
    var diagnostics: [String] = []
    let recorder: (String) -> Void = { [weak self] message in
      diagnostics.append(message)
      CameraVendorFileLogger.log(message)
      self?.report(message)
    }

    do {
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
      try connectWithRetry(recorder: recorder)
      let infos = try session.galleryObjectInfos()
      for info in infos {
        objectInfoCache[info.handle] = info
      }

      let items = infos
        .sorted { $0.captureDate > $1.captureDate }
        .map {
          CameraVendorGalleryItem(
            handle: $0.handle,
            filename: $0.filename,
            formatLabel: $0.formatLabel,
            captureDate: $0.captureDate,
            byteSizeText: ByteCountFormatter.string(fromByteCount: Int64($0.compressedSize), countStyle: .file)
          )
        }
      recorder("图库加载完成，共 \(items.count) 个对象")
      return items
    } catch {
      session.disconnect()
      let message = CameraVendorGalleryDiagnostics.composeFailureMessage(
        baseMessage: "无法读取相机图库。请先让 iPhone 连上相机 Wi‑Fi，再返回 App 重试。原始错误: \(error.localizedDescription)",
        diagnostics: diagnostics
      )
      throw NSError(domain: "CameraVendorRealtimeGalleryService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private func connectWithRetry(
    maxAttempts: Int = 5,
    recorder: ((String) -> Void)? = nil
  ) throws {
    var lastError: Error?
    for attempt in 1...maxAttempts {
      do {
        try session.connect(clientName: ptpClientName, diagnosticHandler: recorder)
        return
      } catch {
        session.disconnect()
        if CameraVendorPtpSessionErrorPolicy.shouldRetry(error) == false {
          throw error
        }

        lastError = error
        if attempt < maxAttempts {
          let delay = CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: attempt)
          recorder?("PTP 连接失败 (第 \(attempt) 次)，\(String(format: "%.1f", delay))s 后重试: \(error.localizedDescription)")
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

  enum CameraVendorPtpSessionErrorPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
      let nsError = error as NSError
      if nsError.domain == "CameraVendorPtpSession", nsError.code == 0xD222 {
        return false
      }
      return true
    }
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
    CameraVendorGalleryDiagnostics.log(message)
    diagnosticHandler?(message)
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
  private static let genericIPhoneName = "iPhone"
  // ReferenceApp 实际抓包看到的 PTP friendlyName 是 "iPhone-####"（保留前缀 i），
  // 之前误把前缀去掉变成 "Phone-####"，相机识别时和 ReferenceApp 不一致。
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
    let candidates = [preferredDeviceName, fallbackAppName, fallbackConnectedDeviceName]
    for candidate in candidates {
      let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty {
        if trimmed == genericIPhoneName {
          return referenceAppStyleGenericIPhoneName()
        }
        return trimmed
      }
    }
    return fallbackConnectedDeviceName
  }

  private static func referenceAppStyleGenericIPhoneName() -> String {
    let suffix = fallbackConnectedDeviceName.utf8.reduce(UInt32(0)) { partial, byte in
      (partial &* 31 &+ UInt32(byte)) % 10_000
    }
    return String(format: "\(referenceAppGenericPhonePrefix)-%04u", suffix)
  }

  static func normalizedStoredConnectedDeviceName(_ storedName: String) -> String {
    let trimmed = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("\(genericIPhoneName)-") {
      return referenceAppStyleGenericIPhoneName()
    }
    // 兼容 FIX27 之前 buggy 版本写过 "Phone-####"（少 i），
    // 这里强制升级为 "iPhone-####" 与 ReferenceApp 实抓的 friendlyName 对齐，
    // 否则 PTP InitCommand / 配对时写给相机的 ConnectedDeviceName 都还是错的。
    if trimmed.hasPrefix("Phone-") {
      return referenceAppStyleGenericIPhoneName()
    }
    return trimmed
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

  mutating func reset() {
    hasRetriedAfterEncryptionFailure = false
    isAwaitingReconnect = false
  }
}

final class CameraVendorLogStore {
  private let fileURL: URL

  init(fileManager: FileManager = .default) {
    let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    fileURL = baseURL.appendingPathComponent("cameraVendor-fast-debug.log")
  }

  var currentContents: String {
    (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
  }

  var currentFileURL: URL {
    fileURL
  }

  func clear() {
    try? "".write(to: fileURL, atomically: true, encoding: .utf8)
  }

  func append(_ line: String) {
    let payload = "\(line)\n"
    if FileManager.default.fileExists(atPath: fileURL.path),
       let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(payload.utf8))
      return
    }

    try? payload.write(to: fileURL, atomically: true, encoding: .utf8)
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
  private let buildMarker = "BUILD_MARK_20260504_FIX148_ACCEPT_CAMERA_SUBNET_FOR_PTP"
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
  private var selectedCamera: CameraVendorDiscoveredCamera?
  private var pairingCharacteristic: CBCharacteristic?
  private var connectedDeviceNameCharacteristic: CBCharacteristic?
  private var connectedDeviceIdentificationCharacteristic: CBCharacteristic?
  private var discoveredCharacteristicsByUUID: [CBUUID: CBCharacteristic] = [:]
  private var notifiableCharacteristics: [CBCharacteristic] = []
  private var probedCharacteristics: [CBUUID: CBCharacteristic] = [:]
  private var observedCharacteristicValues: [String: Data] = [:]
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
  private var isRunningTransferActivation = false
  private var detectedAutoImageImportReadiness = false
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
  private var hasCompletedPairing = false
  private var hasUserInitiatedTransfer = false
  private var secureHandshakePhase: CameraVendorSecureHandshakePhase = .idle
  private var secureHandshakeReconnectCount = 0
  private var secureIdentificationNumberAlreadyPaired = false
  private var rememberedPairedCamera: CameraVendorPairedCameraRecord?
  private var autoReconnectTargetPeripheralID: UUID?
  private var shouldAutoReconnectRememberedCamera = false
  private var isNextRememberedCameraConnectionUserApproved = false

  init(pairingStore: CameraVendorPairedCameraStore = CameraVendorPairedCameraStore()) {
    self.pairingStore = pairingStore
    self.rememberedPairedCamera = pairingStore.load()
    super.init()
    // Clear log file on each app launch so we get fresh logs
    try? FileManager.default.removeItem(at: Self.debugLogURL)
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
    rememberedPairedCamera?.connectionSummary
  }

  var rememberedCameraID: UUID? {
    rememberedPairedCamera?.peripheralID
  }

  func clearLogs() {
    logStore.clear()
  }

  @discardableResult
  func restoreLastPairedCameraIfAvailable() -> Bool {
    rememberedPairedCamera = pairingStore.load()

    guard let record = rememberedPairedCamera else {
      _ = central.state
      return false
    }

    appendLog("已读取保存的配对相机: \(record.deviceName) [\(record.peripheralID.uuidString)]")
    return true
  }

  @discardableResult
  func connectLastPairedCameraIfAvailable() -> Bool {
    guard isNextRememberedCameraConnectionUserApproved else {
      appendLog("已配对相机连接未经过用户确认，已阻止自动重连")
      return true
    }
    isNextRememberedCameraConnectionUserApproved = false

    if selectedPeripheral != nil || autoReconnectTargetPeripheralID != nil || isRunningTransferActivation {
      appendLog("已配对相机连接流程已在进行，忽略重复连接请求")
      return true
    }

    rememberedPairedCamera = pairingStore.load()

    guard let record = rememberedPairedCamera else {
      _ = central.state
      return false
    }

    appendLog("检测到已保存配对相机: \(record.deviceName) [\(record.peripheralID.uuidString)]")
    updateStatus("准备连接上次配对的相机", isBusy: true)
    shouldAutoReconnectRememberedCamera = true

    if central.state == .poweredOn {
      attemptAutoReconnect(using: record)
    }

    return true
  }

  func approveNextRememberedCameraConnection() {
    isNextRememberedCameraConnectionUserApproved = true
  }

  /// Tear down any half-finished BLE/handshake state so a fresh "Connect"
  /// tap from the home screen can run again. Without this, after a failed
  /// or aborted connection (e.g. PTP / Wi-Fi gave up), `selectedPeripheral`
  /// or `autoReconnectTargetPeripheralID` stays set and
  /// `connectLastPairedCameraIfAvailable()` would short-circuit forever
  /// until the app is killed.
  func resetForNewConnectionAttempt() {
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
    hasUserInitiatedTransfer = false
    handshakeCoordinator = CameraVendorHandshakeCoordinator()
    handshakeMode = .undetermined
  }

  func forgetLastPairedCamera() {
    pairingStore.clear()
    rememberedPairedCamera = nil
    autoReconnectTargetPeripheralID = nil
    shouldAutoReconnectRememberedCamera = false
    isNextRememberedCameraConnectionUserApproved = false
    appendLog("已删除本地保存的配对相机记录")
    updateStatus("已删除配对记录，请连接新设备", isBusy: false)
  }

  func confirmCameraPairingSucceeded() {
    guard CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
      hasWrittenIdentifier: hasWrittenPairingIdentifier,
      hasUserConfirmedCameraSuccess: true
    ) else {
      appendLog("相机端尚未到可确认阶段，忽略本次配对完成确认")
      updateStatus("请先完成当前配对流程", isBusy: false)
      return
    }

    notifyPairingCompletedIfPossible()
  }

  func startPhotoTransfer() {
    hasUserInitiatedTransfer = true
    appendObservation(
      "USER_TRANSFER_TAP paired=\(hasCompletedPairing) handshakeDone=\(didCompleteHandshakeCallback) " +
      "peripheralState=\(selectedPeripheral.map { String(describing: $0.state) } ?? "nil") " +
      "knownCharacteristics=\(discoveredCharacteristicsByUUID.count)"
    )

    guard CameraVendorPostPairingTransferPolicy.canStartTransfer(
      hasCompletedPairing: hasCompletedPairing,
      hasUserInitiatedTransfer: hasUserInitiatedTransfer
    ) else {
      appendLog("尚未完成配对，不能开始传输")
      updateStatus("请先完成配对", isBusy: false)
      return
    }

    guard !didCompleteHandshakeCallback else {
      appendLog("传输准备已完成，无需重复开始")
      return
    }

    guard let peripheral = selectedPeripheral else {
      appendLog("当前没有可用的相机连接，无法开始传输")
      updateStatus("相机连接已断开，请重新连接", isBusy: false)
      return
    }

    guard peripheral.state == .connected else {
      appendLog("当前相机 BLE 已断开，无法再次触发传图模式")
      updateStatus("相机连接已断开，请重新连接", isBusy: false)
      return
    }

    appendLog("用户点击“传输照片”，开始准备 Wi‑Fi 和图库连接")
    updateStatus("准备传输照片", isBusy: true)
    beginPostHandshakeProbeIfNeeded(on: peripheral)
  }

  func startScan() {
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
    detectedAutoImageImportReadiness = false
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
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
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

  private func beginScan() {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
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
        self.appendLog("扫描结束，没有发现 相机")
        self.updateStatus("未发现相机", isBusy: false)
      } else {
        self.appendLog("扫描结束，发现 \(self.discoveredCameras.count) 台 CameraVendor 设备")
        self.updateStatus("请选择相机", isBusy: false)
      }
    }
    scanTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  private func beginPairingReadyRescan() {
    scanTimeoutWorkItem?.cancel()
    central.stopScan()
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
    detectedAutoImageImportReadiness = false
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

    appendLog("开始扫描上次配对相机，等待广播后连接")
    beginAutoReconnectScan(for: record)
  }

  private func beginAutoReconnectScan(for record: CameraVendorPairedCameraRecord) {
    discoveredPeripherals.removeAll()
    discoveredCameras.removeAll()
    notifyDevicesChanged()

    scanTimeoutWorkItem?.cancel()
    central.stopScan()
    updateStatus("搜索上次配对的相机", isBusy: true)
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
    )

    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      self.autoReconnectTargetPeripheralID = nil
      self.appendLog("未找到上次配对的相机，等待手动搜索")
      self.updateStatus("未找到上次配对的相机", isBusy: false)
    }
    scanTimeoutWorkItem = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
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
    detectedAutoImageImportReadiness = false
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
    hasCompletedPairing = false
    hasUserInitiatedTransfer = false
    secureHandshakePhase = .idle
    secureIdentificationNumberAlreadyPaired = false
    postHandshakeProbeTimeoutWorkItem?.cancel()
    transferActivationTimeoutWorkItem?.cancel()
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
    let line = "[\(formatter.string(from: Date()))] \(message)"
    NSLog("%@", line)
    // Use CameraVendorFileLogger for thread-safe file writes (single serial queue)
    CameraVendorFileLogger.log(message)
    logStore.append(line)
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

    if let peripheralID = selectedPeripheral?.identifier {
      let record = CameraVendorPairedCameraRecord(
        peripheralID: peripheralID,
        deviceName: summary.deviceName,
        serialNumber: summary.serialNumber,
        connectedDeviceName: summary.connectedDeviceName,
        appVariant: selectedCamera?.appVariant ?? rememberedPairedCamera?.appVariant ?? .unknown,
        preferredWifiNetwork: summary.preferredWifiNetwork
      )
      pairingStore.save(record)
      rememberedPairedCamera = record
      appendLog("已保存配对相机: \(summary.deviceName) [\(peripheralID.uuidString)]")
    }

    didCompletePairingCallback = true
    hasCompletedPairing = true
    appendLog("用户已确认相机端显示配对成功，进入传输准备页")
    updateStatus("配对完成", isBusy: false)
    delegate?.cameraVendorBluetoothService(self, didCompletePairing: summary)

    guard CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing else {
      return
    }
    guard let peripheral = selectedPeripheral, peripheral.state == .connected else {
      appendLog("配对完成后 BLE 已断开，无法自动触发传图模式")
      return
    }

    hasUserInitiatedTransfer = true
    appendObservation(
      "AUTO_TRANSFER_AFTER_PAIRING paired=\(hasCompletedPairing) " +
      "peripheralState=\(peripheral.state) knownCharacteristics=\(discoveredCharacteristicsByUUID.count)"
    )
    appendLog("按 ReferenceApp 连接流程，配对完成后自动触发传图模式")
    updateStatus("准备传输照片", isBusy: true)
    beginPostHandshakeProbeIfNeeded(on: peripheral)
  }

  private func finishHandshakeIfPossible() {
    guard !didCompleteHandshakeCallback,
          !isRunningPostHandshakeProbe,
          CameraVendorPostPairingTransferPolicy.canStartTransfer(
            hasCompletedPairing: hasCompletedPairing,
            hasUserInitiatedTransfer: hasUserInitiatedTransfer
          ),
          let summary = pendingHandshakeSummary else {
      appendLog("finishHandshake guard 未通过: callback=\(didCompleteHandshakeCallback) probe=\(isRunningPostHandshakeProbe) paired=\(hasCompletedPairing) transfer=\(hasUserInitiatedTransfer) summary=\(pendingHandshakeSummary != nil)")
      return
    }

    if detectedAutoImageImportReadiness {
      appendObservation("AUTO_IMAGE_IMPORT_READY_SKIP_GALLERY_ACTIVATION")
      transferActivationObservedChange = true
      transferActivationObservedWifiLaunch = true
      completeHandshake(summary: summary, reason: "auto-image-import-ready")
      return
    }

    if !hasAttemptedAutomaticTransferActivation {
      hasAttemptedAutomaticTransferActivation = true
      let availableCharacteristicUUIDStrings = Set(
        discoveredCharacteristicsByUUID.keys.map { $0.uuidString.uppercased() }
      )

      if selectedPeripheral != nil {
        pendingTransferActivationStrategies = CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
          forAvailableCharacteristicUUIDStrings: availableCharacteristicUUIDStrings
        )
        hadAutomaticTransferActivationFeature = !pendingTransferActivationStrategies.isEmpty
      }

      if let peripheral = selectedPeripheral,
         !pendingTransferActivationStrategies.isEmpty {
        appendObservation(
          "ACTIVATION_PLAN strategies=\(pendingTransferActivationStrategies.map(\.rawValue).joined(separator: ",")) " +
          "availableCharacteristics=\(availableCharacteristicUUIDStrings.sorted().joined(separator: ","))"
        )
        beginNextTransferActivationAttempt(on: peripheral)
        return
      }

      appendObservation("ACTIVATION_PLAN empty availableCharacteristics=\(discoveredCharacteristicsByUUID.keys.map(\.uuidString).sorted().joined(separator: ","))")
      appendLog("未发现 ReferenceApp 传图命令特征，直接进入图库")
    }

    guard !isRunningTransferActivation else {
      return
    }

    guard CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
      hasAttemptedActivation: hasAttemptedAutomaticTransferActivation,
      observedChange: transferActivationObservedChange,
      observedWifiLaunch: transferActivationObservedWifiLaunch,
      hadActivationFeature: hadAutomaticTransferActivationFeature
    ) else {
      appendObservation(
        "HANDSHAKE_BLOCKED activationAttempted=\(hasAttemptedAutomaticTransferActivation) " +
        "observedChange=\(transferActivationObservedChange) observedWifiLaunch=\(transferActivationObservedWifiLaunch) " +
        "hadFeature=\(hadAutomaticTransferActivationFeature)"
      )
      appendLog("传图激活未进入可连接状态，阻止进入图库")
      updateStatus("相机未进入传图模式，请重新连接后重试", isBusy: false)
      return
    }

    completeHandshake(summary: summary, reason: "gallery")
  }

  private func completeHandshake(summary: CameraVendorConnectionSummary, reason: String) {
    didCompleteHandshakeCallback = true
    pendingHandshakeSummary = nil
    CameraVendorGalleryDiagnostics.externalLogHandler = { [weak self] message in
      self?.appendLog("图库: \(message)")
    }
    appendLog(
      "握手完成，设备名称 \(summary.deviceName), " +
      "序列号 \(summary.serialNumber)"
    )
    appendObservation(
      "HANDSHAKE_COMPLETE device=\(summary.deviceName) serial=\(summary.serialNumber) " +
      "connectedName=\(summary.connectedDeviceName) wifi=\(summary.preferredWifiNetwork?.ssid ?? "nil") " +
      "mode=\(summary.transferMode) reason=\(reason) " +
      "observedChange=\(transferActivationObservedChange) observedWifiLaunch=\(transferActivationObservedWifiLaunch)"
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
        self.delegate?.cameraVendorBluetoothService(self, didCompleteHandshake: summary)
      }
    } else {
      appendLog("握手完成，按 ReferenceApp 不再二次断开 BLE，直接通知 UI 进入图库")
      updateStatus("握手完成", isBusy: false)
      delegate?.cameraVendorBluetoothService(self, didCompleteHandshake: summary)
    }
  }

  private func refreshPendingHandshakeSummary(using peripheral: CBPeripheral) {
    let preferredWifiNetwork = CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(
      from: observedCharacteristicValues
    )
    let transferMode: CameraVendorConnectionTransferMode = detectedAutoImageImportReadiness
      ? .autoImageImport
      : .gallery
    pendingHandshakeSummary = CameraVendorConnectionSummary(
      deviceName: discoveredName ?? selectedCamera?.name ?? peripheral.name ?? "CAMERA_VENDOR",
      serialNumber: discoveredSerialNumber ?? "-",
      connectedDeviceName: connectedDeviceNameToWrite,
      preferredWifiNetwork: preferredWifiNetwork,
      transferMode: transferMode
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

  private func updateAutoImageImportReadinessIfNeeded() {
    let apStateData = observedCharacteristicValues[
      CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString
    ]
    let transferStateData = observedCharacteristicValues[
      CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString
    ]
    guard CameraVendorReferenceAppAutoImageImportReadinessPolicy.isReady(
      apStateData: apStateData,
      transferStateData: transferStateData
    ) else {
      return
    }

    if !detectedAutoImageImportReadiness {
      let apStateName = apStateData.flatMap { CameraVendorReferenceAppApState(data: $0)?.debugName } ?? "nil"
      let transferStateName = transferStateData.flatMap { CameraVendorReferenceAppTransferState(data: $0)?.debugName } ?? "nil"
      appendObservation(
        "AUTO_IMAGE_IMPORT_READY apState=\(apStateName) transferState=\(transferStateName)"
      )
      appendLog("检测到 ReferenceApp HEIF/RAW 自动接收状态: \(apStateName), \(transferStateName)")
    }
    detectedAutoImageImportReadiness = true
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
      if transferActivationObservedWifiLaunch {
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
      updateStatus("相机未进入传图模式，请清除旧配对后重试", isBusy: false)
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

    // All strategies exhausted without observed change.
    // Set awaitingTransferActivationStateChange so late BLE notifications can still be caught.
    // Then disconnect BLE and proceed — camera may already be ready for PTP.
    awaitingTransferActivationStateChange = true
    awaitingTransferActivationStateChangeSince = Date()
    appendLog("所有传图策略已尝试完毕，未观察到状态变化。主动断开 BLE 并尝试进入图库。")
    if let peripheral = selectedPeripheral {
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

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
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
    if CameraVendorBluetoothConnectFailurePolicy.shouldClearRememberedPairing(for: errorDescription) {
      pairingStore.clear()
      rememberedPairedCamera = nil
      autoReconnectTargetPeripheralID = nil
      appendLog("相机已删除配对信息，已清除本地保存的配对记录")
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
        // its WiFi AP and PTP/IP listener. Without this delay, WiFi join and
        // PTP INIT_COMMAND_REQUEST both fail silently.
        appendLog("相机已断开 BLE，等待 3 秒让相机 Wi‑Fi AP 和 PTP 服务就绪")
        updateStatus("等待相机 Wi‑Fi 就绪", isBusy: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
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
          updateStatus("相机未确认传图，请清除旧配对后重试", isBusy: false)
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
        appendLog("读取需要加密链路，等待系统蓝牙配对完成")
        if encryptionRecoveryPolicy.registerEncryptionFailureAndShouldRetry() {
          appendLog("首次加密读取失败，等待断开后自动重连")
          updateStatus("等待加密配对完成后重连", isBusy: true)
          return
        }
      }
      appendLog("读取特征值失败 \(characteristic.uuid.uuidString): \(error.localizedDescription)")
      maybeStartPairing(on: peripheral)
      return
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

    if characteristic.uuid == connectedDeviceIdentificationCharacteristicUUID {
      if let data = characteristic.value {
        appendLog("读取到已连接设备识别号: \(hexString(data))")
        secureIdentificationNumberAlreadyPaired =
          CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(data)
        if secureIdentificationNumberAlreadyPaired {
          appendLog("识别号已带应用标记，按已配对重连处理")
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
      updateAutoImageImportReadinessIfNeeded()
      refreshPendingHandshakeSummary(using: peripheral)
      if isRunningTransferActivation, detectedAutoImageImportReadiness {
        transferActivationTimeoutWorkItem?.cancel()
        transferActivationTimeoutWorkItem = nil
        transferActivationObservedChange = true
        transferActivationObservedWifiLaunch = true
        appendObservation("AUTO_IMAGE_IMPORT_READY_DURING_ACTIVATION uuid=\(characteristic.uuid.uuidString)")
        completeCurrentTransferActivationAttempt(on: peripheral, source: "auto-image-import-ready")
        return
      }
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
        appendObservation("BLE_IMAGE_RESIZE_DISABLED_WRITE_ACK")
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
      refreshPendingHandshakeSummary(using: peripheral)
      if shouldBypassManualPairingConfirmation() {
        appendLog("识别为已配对重连，跳过人工确认")
        notifyPairingCompletedIfPossible()
        if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
          hasUserInitiatedTransfer = true
          appendLog("自动传输模式：跳过手动确认，直接开始探测")
          beginPostHandshakeProbeIfNeeded(on: peripheral)
        }
        return
      }
      if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
        hasUserInitiatedTransfer = true
        appendLog("自动传输模式：设置传输标志，开始探测")
        beginPostHandshakeProbeIfNeeded(on: peripheral)
      } else {
        appendLog("手机端握手已完成，等待相机端显示配对成功")
        updateStatus("请先在相机上确认配对成功", isBusy: false)
      }
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
        refreshPendingHandshakeSummary(using: peripheral)
        notifyPairingCompletedIfPossible()
        if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
          hasUserInitiatedTransfer = true
          appendLog("自动传输模式：跳过识别号 ACK 后直接开始探测")
          beginPostHandshakeProbeIfNeeded(on: peripheral)
        }
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
      refreshPendingHandshakeSummary(using: peripheral)
      if shouldBypassManualPairingConfirmation() {
        appendLog("识别为已配对重连，跳过人工确认")
        notifyPairingCompletedIfPossible()
        if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
          hasUserInitiatedTransfer = true
          appendLog("自动传输模式：跳过手动确认，直接开始探测")
          beginPostHandshakeProbeIfNeeded(on: peripheral)
        }
        return
      }
      if CameraVendorPostPairingTransferPolicy.shouldAutomaticallyPrepareTransferAfterPairing {
        hasUserInitiatedTransfer = true
        notifyPairingCompletedIfPossible()
        appendLog("自动传输模式：设置传输标志，开始探测")
        beginPostHandshakeProbeIfNeeded(on: peripheral)
      } else {
        appendLog("手机端握手已完成，等待相机端显示配对成功")
        updateStatus("请先在相机上确认配对成功", isBusy: false)
      }
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
