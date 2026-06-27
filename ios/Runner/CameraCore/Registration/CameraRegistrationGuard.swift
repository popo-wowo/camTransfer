import Foundation

enum IOSCameraRegistrationIssue: Equatable {
  case pass
  case needsSystemBondCleanup(address: String)
  case needsRePairing(cameraID: String)
}

enum IOSCameraRegistrationGuard {
  static func evaluate(
    localRecord: IOSCameraPairingRecord?,
    scannedEndpoint: IOSCameraBleEndpoint?,
    bondedAddresses: Set<String>
  ) -> IOSCameraRegistrationIssue {
    guard let scannedAddress = scannedEndpoint?.address, !scannedAddress.isEmpty else {
      return localRecord == nil ? .pass : .pass
    }

    if let localRecord {
      let localAddress = localRecord.identity.bleEndpoint.address
      if localAddress == scannedAddress {
        return .pass
      }
      return .needsRePairing(cameraID: localRecord.identity.cameraID)
    }

    if bondedAddresses.contains(scannedAddress) {
      return .needsSystemBondCleanup(address: scannedAddress)
    }
    return .pass
  }

  static func evaluate(
    localRecord: IOSCameraPairingRecord?,
    scannedEndpoint: IOSCameraBleEndpoint?,
    bondedAddresses: [String]
  ) -> IOSCameraRegistrationIssue {
    evaluate(
      localRecord: localRecord,
      scannedEndpoint: scannedEndpoint,
      bondedAddresses: Set(bondedAddresses)
    )
  }
}

