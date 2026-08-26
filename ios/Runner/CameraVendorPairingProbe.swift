import Foundation
import CoreBluetooth

/// Result of a silent BLE pairing validity probe performed on app launch.
enum CameraVendorPairingProbeResult: Equatable {
  /// BLE connected + encryption valid. Peripheral is kept connected for fast gallery entry.
  case online
  /// BLE connected but encryption failed — pairing record is stale.
  case pairingInvalid(reason: String)
  /// Camera not discovered within timeout. May be powered off or out of range.
  case offline
  /// BLE is reachable, but this camera does not expose the probe validation characteristic.
  case validationUnavailable(reason: String)
  /// iOS Bluetooth is not powered on.
  case bluetoothOff
}

/// Policy for the silent pairing probe on app launch.
enum CameraVendorPairingProbePolicy {
  /// Maximum seconds to wait for BLE connect + service discovery + characteristic read.
  static let timeoutSeconds: TimeInterval = 12

  /// Whether to use `retrievePeripherals` before scanning.
  /// This is faster (no scan needed) but only works if iOS still has the peripheral cached.
  static let shouldTrySystemRetrieveFirst = true

  /// The characteristic to read for encryption validation.
  /// Reading any encrypted characteristic will trigger iOS to verify the encryption link.
  /// Use the Device Information serial characteristic. The XM5 device logs
  /// prove that 180A/2A25 is exposed and readable on the remembered path;
  /// unlike the Generic Access service, it is visible through the camera's
  /// discovered GATT services on iOS and still exercises the protected link.
  static let validationServiceUUID = CBUUID(string: "180A")
  static let validationCharacteristicUUID = CBUUID(string: "2A25")

  static func isPairingInvalidError(_ error: Error) -> Bool {
    let nsError = error as NSError
    // CBATTError.insufficientEncryption = 0x0F
    if nsError.domain == CBATTErrorDomain, nsError.code == CBATTError.insufficientEncryption.rawValue {
      return true
    }
    // CBError.peerRemovedPairingInformation = 14
    if nsError.domain == CBErrorDomain, nsError.code == 14 {
      return true
    }
    // "Peer removed pairing information" in localizedDescription
    if nsError.localizedDescription.lowercased() == "peer removed pairing information" {
      return true
    }
    // CBATTError.insufficientAuthentication = 0x05
    if nsError.domain == CBATTErrorDomain, nsError.code == CBATTError.insufficientAuthentication.rawValue {
      return true
    }
    return false
  }

  static func isConnectionFailurePairingInvalid(_ error: Error?) -> Bool {
    guard let error else { return false }
    return isPairingInvalidError(error)
  }
}

/// Tracks the state of a silent pairing probe.
/// This is separate from the main connection flow to avoid interference.
enum CameraVendorPairingProbeState: Equatable {
  case idle
  case scanning(peripheralID: UUID)
  case connecting(peripheralID: UUID)
  case discoveringServices(peripheralID: UUID)
  case readingCharacteristic(peripheralID: UUID)
  case preconnected(peripheralID: UUID)
  case tearingDown(peripheralID: UUID, result: CameraVendorPairingProbeResult)
  case completed(CameraVendorPairingProbeResult)

  var isActive: Bool {
    switch self {
    case .idle, .preconnected, .completed: return false
    case .scanning, .connecting, .discoveringServices, .readingCharacteristic, .tearingDown:
      return true
    }
  }

  var preconnectedPeripheralID: UUID? {
    if case .preconnected(let id) = self { return id }
    return nil
  }

  var targetPeripheralID: UUID? {
    switch self {
    case .scanning(let id), .connecting(let id),
         .discoveringServices(let id), .readingCharacteristic(let id),
         .preconnected(let id), .tearingDown(let id, _):
      return id
    case .idle, .completed:
      return nil
    }
  }
}

enum CameraVendorPairingProbeUserActionDecision: Equatable {
  case waitForProbe
  case reusePreconnectedProbe
  case startNormalConnection

  static func resolve(
    hasProbeTask: Bool,
    hasPreconnectedProbe: Bool,
    preconnectedPeripheralID: UUID?,
    requestedPeripheralID: UUID
  ) -> Self {
    if hasPreconnectedProbe, preconnectedPeripheralID == requestedPeripheralID {
      return .reusePreconnectedProbe
    }
    if hasProbeTask {
      return .waitForProbe
    }
    return .startNormalConnection
  }
}

enum CameraVendorPairingProbeWaiterPolicy {
  static func shouldResumeImmediately(
    result: CameraVendorPairingProbeResult,
    hasPeripheralTeardown: Bool
  ) -> Bool {
    switch result {
    case .online:
      return true
    case .pairingInvalid, .offline, .validationUnavailable, .bluetoothOff:
      return !hasPeripheralTeardown
    }
  }
}
