import Foundation

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

enum CameraVendorRememberedRedReconnectAdmissionPolicy {
  static func shouldAdmit(
    observedPeripheralID: UUID,
    rememberedPeripheralID: UUID?,
    serviceUUIDs: [String]
  ) -> Bool {
    guard observedPeripheralID == rememberedPeripheralID else {
      return false
    }

    let connectedDeviceInformationRed =
      CameraVendorDeviceMatcher.securePairServiceUUIDString.uppercased()
    return serviceUUIDs.contains {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        == connectedDeviceInformationRed
    }
  }
}

enum CameraVendorRememberedRedReconnectIdentityRejectionReason: String, Equatable {
  case endpointMismatch = "endpoint-mismatch"
  case missingRememberedSerial = "missing-remembered-serial"
  case missingConnectedSerial = "missing-connected-serial"
  case serialMismatch = "serial-mismatch"
}

enum CameraVendorRememberedRedReconnectIdentityDecision: Equatable {
  case notRequired
  case accepted
  case rejected(reason: CameraVendorRememberedRedReconnectIdentityRejectionReason)
}

enum CameraVendorRememberedRedReconnectIdentityPolicy {
  static func decision(
    admission: CameraVendorAdvertisementAdmission,
    rememberedPeripheralID: UUID?,
    connectedPeripheralID: UUID?,
    rememberedSerialNumber: String?,
    connectedSerialNumber: String?
  ) -> CameraVendorRememberedRedReconnectIdentityDecision {
    guard admission == .rememberedRedReconnect else {
      return .notRequired
    }

    guard let rememberedPeripheralID,
          let connectedPeripheralID,
          rememberedPeripheralID == connectedPeripheralID else {
      return .rejected(reason: .endpointMismatch)
    }

    let rememberedSerial = normalizedSerial(rememberedSerialNumber)
    guard !rememberedSerial.isEmpty, rememberedSerial != "-" else {
      return .rejected(reason: .missingRememberedSerial)
    }

    let connectedSerial = normalizedSerial(connectedSerialNumber)
    guard !connectedSerial.isEmpty, connectedSerial != "-" else {
      return .rejected(reason: .missingConnectedSerial)
    }

    guard rememberedSerial == connectedSerial else {
      return .rejected(reason: .serialMismatch)
    }
    return .accepted
  }

  private static func normalizedSerial(_ value: String?) -> String {
    value?
      .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
