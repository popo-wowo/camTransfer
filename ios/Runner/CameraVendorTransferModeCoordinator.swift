import Foundation

enum CameraVendorPhysicalTransferPurpose: Equatable {
  case reset
  case screenPreview
  case compressedDownload
  case originalDownload
  case unknown

  var label: String {
    switch self {
    case .reset: return "reset"
    case .screenPreview: return "screen-preview"
    case .compressedDownload: return "compressed-download"
    case .originalDownload: return "original-download"
    case .unknown: return "unknown"
    }
  }
}

enum CameraVendorTransferModeAction: Equatable {
  case setProperty(CameraVendorDownloadModeProperty)
}

struct CameraVendorTransferModeCoordinator {
  private(set) var currentPurpose: CameraVendorPhysicalTransferPurpose

  init(currentPurpose: CameraVendorPhysicalTransferPurpose = .unknown) {
    self.currentPurpose = currentPurpose
  }

  func actionsForPreparing(
    _ purpose: CameraVendorPhysicalTransferPurpose
  ) -> [CameraVendorTransferModeAction] {
    guard purpose != .reset, purpose != .unknown else { return [] }
    guard purpose != currentPurpose else { return [] }

    var properties: [CameraVendorDownloadModeProperty] = []
    if currentPurpose != .reset {
      properties.append(CameraVendorDownloadModePolicy.imageForceCompressionProperty(0))
    }
    switch purpose {
    case .screenPreview:
      properties.append(CameraVendorDownloadModePolicy.imageForceCompressionProperty(1))
    case .compressedDownload:
      properties.append(contentsOf: CameraVendorDownloadModePolicy.prepareProperties(mode: .compressed))
    case .originalDownload:
      properties.append(contentsOf: CameraVendorDownloadModePolicy.prepareProperties(mode: .original))
    case .reset, .unknown:
      break
    }
    return properties.map(CameraVendorTransferModeAction.setProperty)
  }

  func actionsForReset() -> [CameraVendorTransferModeAction] {
    guard currentPurpose != .reset else { return [] }
    return [
      .setProperty(CameraVendorDownloadModePolicy.imageForceCompressionProperty(0))
    ]
  }

  mutating func recordPreparationSucceeded(_ purpose: CameraVendorPhysicalTransferPurpose) {
    currentPurpose = purpose
  }

  mutating func recordPreparationFailed() {
    currentPurpose = .unknown
  }

  mutating func recordResetSucceeded() {
    currentPurpose = .reset
  }

  mutating func recordResetFailed() {
    currentPurpose = .unknown
  }

  mutating func invalidate() {
    currentPurpose = .unknown
  }
}
