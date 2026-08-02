import UIKit

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

enum CameraVendorConnectedApplicationHandshakeAction: Equatable {
  case completeIdentityHandshake
  case writeApplicationInfo(Data)
}

enum CameraVendorConnectedApplicationHandshakePolicy {
  static let characteristicUUIDString = "8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7"
  static let applicationInfoPayload = Data([0x80, 0x01, 0x01])
  static let writeTimeoutSeconds: TimeInterval = 5

  static func action(
    availableCharacteristicUUIDStrings: Set<String>
  ) -> CameraVendorConnectedApplicationHandshakeAction {
    let normalizedUUIDs = Set(availableCharacteristicUUIDStrings.map { $0.uppercased() })
    guard normalizedUUIDs.contains(characteristicUUIDString) else {
      return .completeIdentityHandshake
    }
    return .writeApplicationInfo(applicationInfoPayload)
  }

  static func acceptsWriteCallback(
    pendingGeneration: UInt64?,
    currentGeneration: UInt64,
    isCurrentCharacteristic: Bool
  ) -> Bool {
    pendingGeneration == currentGeneration && isCurrentCharacteristic
  }

  static func shouldStartApplicationInfoWrite(
    attemptedGeneration: UInt64?,
    currentGeneration: UInt64
  ) -> Bool {
    attemptedGeneration != currentGeneration
  }

  static func acceptsIdentityWriteCallback(
    characteristicGeneration: UInt64?,
    currentGeneration: UInt64,
    isCurrentPeripheral: Bool,
    isCurrentCharacteristic: Bool
  ) -> Bool {
    characteristicGeneration == currentGeneration
      && isCurrentPeripheral
      && isCurrentCharacteristic
  }

  static func shouldCompleteIdentityHandshake(
    completedGeneration: UInt64?,
    currentGeneration: UInt64
  ) -> Bool {
    completedGeneration != currentGeneration
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
  case awaitingConnectedApplicationInfoWrite
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
    case .idle, .awaitingDeviceNameWrite, .awaitingIdentificationNumberRead,
         .awaitingConnectedApplicationInfoWrite, .completed:
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
