import CoreLocation
import Darwin
import Foundation
import NetworkExtension

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

final class CameraVendorWifiApplyContinuationGate: @unchecked Sendable {
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

@MainActor
final class CameraVendorWifiLocationAuthorizer: NSObject, @preconcurrency CLLocationManagerDelegate {
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
