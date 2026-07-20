import Foundation

struct IOSCameraDiscoveredCamera: Equatable {
  let id: UUID
  let displayName: String
  let rssi: Int
}

struct IOSCameraBleEndpoint: Equatable, Codable {
  let identifier: String
  let address: String?
}

struct IOSCameraIdentity: Equatable, Codable {
  let cameraID: String
  let displayName: String
  let serialNumber: String?
  let bleEndpoint: IOSCameraBleEndpoint
}

enum IOSCameraWifiCredentialSource: String, Codable {
  case bleHandshake
  case pairingRecord
  case guessed
}

struct IOSCameraWifiCredential: Equatable, Codable {
  let ssid: String
  let passphrase: String
  let bssid: String?
  let source: IOSCameraWifiCredentialSource

  static func official(
    ssid: String?,
    passphrase: String?,
    bssid: String?,
    source: IOSCameraWifiCredentialSource
  ) -> IOSCameraWifiCredential? {
    guard source == .bleHandshake else { return nil }
    guard let ssid = ssid?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty else {
      return nil
    }
    guard let passphrase = passphrase, !passphrase.isEmpty, passphrase != "00000000" else {
      return nil
    }
    return IOSCameraWifiCredential(ssid: ssid, passphrase: passphrase, bssid: bssid, source: source)
  }
}

struct IOSCameraPairingRecord: Equatable, Codable {
  let identity: IOSCameraIdentity
  let wifiCredential: IOSCameraWifiCredential
}

struct IOSCameraRememberedCameraRecord: Equatable, Codable {
  let peripheralID: UUID
  let identity: IOSCameraIdentity
  let wifiCredential: IOSCameraWifiCredential?
  let connectedDeviceName: String?
  let systemBluetoothPairingValidatedAt: Date?
}

struct IOSCameraGalleryPresentation: Equatable, Codable {
  let deviceName: String
  let serialNumber: String
  let connectedDeviceName: String
  let preferCompressedDownloads: Bool
}

struct IOSCameraObjectInfo: Equatable, Codable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: Date?
  let byteSize: Int64?
  let orientation: Int?
}

struct IOSCameraPtpSessionEvidence: Equatable {
  let sessionID: String
}

struct IOSCameraGalleryReadyEvidence: Equatable {
  let ptpSessionID: String

  var hasGalleryReadyEvidence: Bool {
    !ptpSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

struct IOSCameraHomeSnapshot: Equatable {
  let discoveredCameras: [IOSCameraDiscoveredCamera]
  let rememberedCameras: [IOSCameraRememberedCameraRecord]
  let status: String
  let isBusy: Bool
  let requiresSystemBluetoothPairingCleanup: Bool
}

struct IOSCameraTransferActivationStrategy: RawRepresentable, Equatable, Hashable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}
