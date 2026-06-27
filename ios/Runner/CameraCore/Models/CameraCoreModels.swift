import Foundation

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

struct IOSCameraObjectInfo: Equatable, Codable {
  let handle: Int
  let filename: String
  let formatLabel: String
  let captureDate: Date?
  let byteSize: Int64?
  let orientation: Int?
}

