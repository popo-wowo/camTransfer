import Foundation

enum CameraVendorSpecifiedObjectSnapshotPolicy {
  static let shouldCompareBeforeAndAfterEmptySearchMode = false
}

enum CameraVendorInitialCatalogBootstrapRecoveryPolicy {
  static let storeNotAvailableResponseCode = 0x2013

  static func shouldRecover(after error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "CameraVendorPtpSession"
      && nsError.code == storeNotAvailableResponseCode
  }
}

typealias CameraVendorSpecifiedObjectDateGroup = CameraGalleryDateGroup

enum CameraVendorSearchModeAllCondition: Equatable {
  case uint16(propertyCode: UInt16, value: UInt16)
}

enum CameraVendorWirelessRealFileFormat {
  static let heif: UInt16 = 0x3812
}

enum CameraVendorCatalogMembershipPolicy: Equatable {
  case direct
  case countSweepThenApply
  /// D604=X returns a broad directory; subtract the baseline (ALL) handles
  /// to isolate the format-specific handles that are NOT in the initial catalog.
  case subtractBaseline
}

struct CameraVendorCatalogQuery: Equatable {
  let conditions: [CameraVendorSearchModeAllCondition]
  let label: String
  let membershipPolicy: CameraVendorCatalogMembershipPolicy

  init(
    conditions: [CameraVendorSearchModeAllCondition],
    label: String,
    membershipPolicy: CameraVendorCatalogMembershipPolicy = .direct
  ) {
    self.conditions = conditions
    self.label = label
    self.membershipPolicy = membershipPolicy
  }
}

struct CameraVendorCatalogSnapshot: Equatable {
  let dateGroups: [CameraVendorSpecifiedObjectDateGroup]
  let orderedHandles: [UInt32]
  let items: [CameraVendorGalleryItem]
}

struct CameraVendorCountSweepFormatCount {
  let label: String
  let mask: UInt16
  let count: UInt32?
}

struct CameraVendorCountSweepResult {
  let sweepCounts: [CameraVendorCountSweepFormatCount]
  let baselineHandleCount: Int
  let heifDeclaredCount: UInt32?
  let heifHandleCount: Int
  let heifHandles: [UInt32]
  let confirmReadback: Data

  var heifExact616: Bool {
    heifDeclaredCount == 616 && heifHandleCount == 616
  }

  var diagnosticSummary: String {
    let sweepSummary = sweepCounts.map { "\($0.label)=\($0.count.map(String.init) ?? "nil")" }.joined(separator: " ")
    return "[COUNT_SWEEP_RESULT] sweep=[\(sweepSummary)] " +
      "baseline=\(baselineHandleCount) " +
      "heif_declared=\(heifDeclaredCount.map(String.init) ?? "nil") " +
      "heif_handles=\(heifHandleCount) " +
      "exact_616=\(heifExact616) " +
      "readback_bytes=\(confirmReadback.count)"
  }
}

enum CameraVendorCatalogTransportEvidencePolicy {
  static func provesTransportLost(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "CameraVendorPtpSocket" {
      return true
    }
    if nsError.domain == NSURLErrorDomain {
      switch nsError.code {
      case NSURLErrorCannotConnectToHost,
           NSURLErrorNetworkConnectionLost,
           NSURLErrorNotConnectedToInternet,
           NSURLErrorTimedOut:
        return true
      default:
        break
      }
    }
    let message = nsError.localizedDescription.lowercased()
    return message.contains("socket 未建立") ||
      message.contains("connection reset") ||
      message.contains("broken pipe")
  }
}

enum CameraVendorCatalogTransactionExecutor {
  static func execute<Output>(
    backup: () throws -> Data,
    perform: () throws -> Output,
    restore: (Data) throws -> Void
  ) throws -> Output {
    let savedSearchMode: Data
    do {
      savedSearchMode = try backup()
    } catch {
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: error.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(error)
      )
    }

    let primaryResult: Result<Output, Error>
    do {
      primaryResult = .success(try perform())
    } catch {
      primaryResult = .failure(error)
    }

    let restorationError: Error?
    do {
      try restore(savedSearchMode)
      restorationError = nil
    } catch {
      restorationError = error
    }

    switch (primaryResult, restorationError) {
    case let (.success(result), nil):
      return result
    case let (.success, restorationError?):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: "目录读取已完成，但 SearchMode 恢复失败",
        restorationMessage: restorationError.localizedDescription,
        provesTransportLost: true
      )
    case let (.failure(primaryError), nil):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: primaryError.localizedDescription,
        restorationMessage: nil,
        provesTransportLost: CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(primaryError)
      )
    case let (.failure(primaryError), restorationError?):
      throw CameraGalleryCatalogTransactionFailure(
        primaryMessage: primaryError.localizedDescription,
        restorationMessage: restorationError.localizedDescription,
        provesTransportLost: true
      )
    }
  }
}

enum CameraVendorSearchModeAllPayload {
  static let objectFormatPropertyCode: UInt16 = 0xD604
  static let jpegObjectFormatMask: UInt16 = 0x0001
  static let heifObjectFormatMask: UInt16 = 0x0002
  static let movObjectFormatMask: UInt16 = 0x0004
  static let mp4ObjectFormatMask: UInt16 = 0x0008
  static let rawObjectFormatMask: UInt16 = 0x0010

  static var stillImageObjectFormatMask: UInt16 {
    jpegObjectFormatMask | heifObjectFormatMask | rawObjectFormatMask
  }

  static var allObjectFormatMask: UInt16 {
    jpegObjectFormatMask | heifObjectFormatMask | movObjectFormatMask | mp4ObjectFormatMask | rawObjectFormatMask
  }

  static func objectFormatMaskPayload(_ mask: UInt16) -> Data {
    payload(for: [.uint16(propertyCode: objectFormatPropertyCode, value: mask)])
  }

  static func payload(for conditions: [CameraVendorSearchModeAllCondition]) -> Data {
    var data = Data()
    data.append(littleEndian(UInt32(conditions.count)))
    for condition in conditions {
      switch condition {
      case let .uint16(propertyCode, value):
        data.append(littleEndian(UInt32(8)))
        data.append(littleEndian(propertyCode))
        data.append(littleEndian(value))
      }
    }
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

enum CameraVendorSearchModeAllReadback {
  static func uint16Value(propertyCode: UInt16, from data: Data) -> UInt16? {
    guard data.count >= 4 else { return nil }
    let count = Int(readUInt32LE(data, at: 0))
    guard count >= 0, count <= 32 else { return nil }
    var offset = 4
    for _ in 0..<count {
      guard offset + 8 <= data.count else { return nil }
      let recordLength = Int(readUInt32LE(data, at: offset))
      guard recordLength >= 8,
            offset + recordLength <= data.count else { return nil }
      let recordProperty = readUInt16LE(data, at: offset + 4)
      if recordProperty == propertyCode {
        return readUInt16LE(data, at: offset + 6)
      }
      offset += recordLength
    }
    return nil
  }

  private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) |
      (UInt32(data[offset + 1]) << 8) |
      (UInt32(data[offset + 2]) << 16) |
      (UInt32(data[offset + 3]) << 24)
  }
}

enum CameraVendorCatalogSnapshotValidationPolicy {
  static func isPublishable(
    declaredCount: UInt32?,
    dateGroups: [CameraVendorSpecifiedObjectDateGroup],
    orderedHandles: [UInt32]
  ) -> Bool {
    guard declaredCount == UInt32(orderedHandles.count),
          dateGroups.reduce(UInt32(0), { $0 + $1.objectCount }) == UInt32(orderedHandles.count),
          Set(orderedHandles).count == orderedHandles.count else {
      return false
    }
    return true
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

enum CameraVendorCatalogWireRequestPolicy {
  static let shouldReadCurrentObjectHandleViaObjectPropList = false
  static let shouldReadCurrentObjectHandleBeforeSpecifiedList = false
  static let shouldRefreshGalleryContextBeforeSpecifiedList = true
  static let shouldReadCurrentObjectHandleBeforeLatestProbe = true
}

enum CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy {
  static let maxRetryCount = 1
  static let retryDelaySeconds: TimeInterval = 1.5

  static func shouldRetry(
    count: UInt32?,
    handles: [UInt32],
    retryCount: Int,
    isRequiredPrimaryList: Bool = true
  ) -> Bool {
    isRequiredPrimaryList && (count ?? 0) == 0 && handles.isEmpty && retryCount < maxRetryCount
  }
}

enum CameraVendorReferenceAppCurrentImageContextPolicy {
  static let currentImageHandle: UInt32 = 0x10000001
  static let shouldPrimeBeforeImageHandleList = true
  static let shouldPrimeThumbnailBeforeSearchDescription = true

  static func shouldAttemptCurrentImagePrime(galleryReadyMarker: UInt32?) -> Bool {
    return shouldPrimeBeforeImageHandleList
      && CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(
        marker: galleryReadyMarker
      )
  }

  static func shouldPrimeThumbnailAfterImageContextPrime(imagePrimeSucceeded: Bool) -> Bool {
    shouldPrimeThumbnailBeforeSearchDescription && imagePrimeSucceeded
  }
}
