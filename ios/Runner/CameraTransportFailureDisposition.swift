import Darwin
import Foundation

/// Unified transport-failure classification shared by catalog, thumbnail, HD preview,
/// download, and background metadata pipelines.
///
/// The contract: every `catch` block that receives an `Error` from a PTP/network
/// operation classifies it through `CameraTransportFailureDispositionPolicy.disposition(for:)`
/// and acts on the result:
///
/// - `.sessionTerminal`: stop the pump/loop, invoke the session-level failure reporter once, return.
/// - `.retryableOperation`: use the existing bounded retry policy (handle-local budget).
/// - `.contentFailure`: mark the item as failed, continue to the next.
/// - `.cancelled`: do not publish failure UI, do not report session failure.
enum CameraTransportFailureDisposition: Equatable {
  case cancelled
  case retryableOperation
  case sessionTerminal
  case contentFailure
}

enum CameraTransportFailureContext {
  case childPipeline
  case catalog
  case download
  case backgroundMetadata
}

typealias TransportFailureReporter = @MainActor (Error) -> Void

enum CameraTransportFailureDispositionPolicy {
  /// Classify an error thrown by a PTP/network operation.
  ///
  /// Classification priority:
  /// 1. CancellationError → `.cancelled`
  /// 2. Stable NSError domain/code, checking underlying errors before wrappers
  /// 3. Known message patterns as a compatibility fallback
  /// 4. Unknown operation errors → `.retryableOperation` to preserve bounded retries
  static func disposition(
    for error: Error,
    context: CameraTransportFailureContext = .childPipeline
  ) -> CameraTransportFailureDisposition {
    if error is CancellationError {
      return .cancelled
    }

    let errors = errorChain(error as NSError)

    for nsError in errors.reversed() {
      if let disposition = structuredDisposition(for: nsError, context: context) {
        return disposition
      }
    }

    for nsError in errors.reversed() {
      if messageProvesTransportLoss(nsError.localizedDescription, context: context) {
        return .sessionTerminal
      }
      if messageProvesContentFailure(nsError.localizedDescription) {
        return .contentFailure
      }
    }

    if errors.reversed().contains(where: isGenericRetryableOperation) {
      return .retryableOperation
    }

    // Existing thumbnail callers retry untyped operation failures with a bounded budget.
    return .retryableOperation
  }

  private static func structuredDisposition(
    for nsError: NSError,
    context: CameraTransportFailureContext
  ) -> CameraTransportFailureDisposition? {
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return .cancelled
    }
    if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
      return .cancelled
    }
    switch context {
    case .childPipeline:
      if nsError.domain == "CameraVendorPtpSocket",
         (2...9).contains(nsError.code) {
        return .sessionTerminal
      }
      if nsError.domain == NSPOSIXErrorDomain,
         terminalChildPOSIXCodes.contains(nsError.code) {
        return .sessionTerminal
      }
      if nsError.domain == NSURLErrorDomain,
         terminalURLErrorCodes.contains(nsError.code) {
        return .sessionTerminal
      }
    case .catalog:
      if nsError.domain == "CameraVendorPtpSocket" {
        return .sessionTerminal
      }
      if nsError.domain == "CameraVendorPtpSession",
         nsError.code == 15 {
        return .sessionTerminal
      }
      if nsError.domain == NSURLErrorDomain,
         terminalURLErrorCodes.contains(nsError.code) {
        return .sessionTerminal
      }
    case .download:
      if nsError.domain == NSPOSIXErrorDomain ||
          (nsError.domain == "CameraVendorPtpSocket" && nsError.code == 9) {
        return .sessionTerminal
      }
    case .backgroundMetadata:
      if nsError.domain == "CameraVendorPtpSocket" {
        return .sessionTerminal
      }
    }
    if nsError.domain == "ImageDecoder" {
      return .contentFailure
    }
    return nil
  }

  private static func isGenericRetryableOperation(_ nsError: NSError) -> Bool {
    nsError.domain == "CameraVendorPtpSession"
  }

  private static func errorChain(_ error: NSError) -> [NSError] {
    var result: [NSError] = []
    var visited: Set<ObjectIdentifier> = []
    var current: NSError? = error
    while let nsError = current, visited.insert(ObjectIdentifier(nsError)).inserted {
      result.append(nsError)
      current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return result
  }

  private static let terminalChildPOSIXCodes: Set<Int> = [
    Int(EPIPE),
    Int(ECONNABORTED),
    Int(ECONNRESET),
    Int(ENOTCONN),
    Int(ESHUTDOWN),
    Int(ETIMEDOUT),
    Int(ECONNREFUSED),
    Int(ENETDOWN),
    Int(ENETRESET),
    Int(ENETUNREACH),
    Int(EHOSTDOWN),
    Int(EHOSTUNREACH),
  ]

  private static let terminalURLErrorCodes: Set<Int> = [
    NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost,
    NSURLErrorNotConnectedToInternet,
    NSURLErrorTimedOut,
  ]

  private static func messageProvesTransportLoss(
    _ description: String,
    context: CameraTransportFailureContext
  ) -> Bool {
    let message = description.lowercased()
    switch context {
    case .childPipeline:
      return message.contains("socket 未建立") ||
        message.contains("connection reset") ||
        message.contains("broken pipe") ||
        message.contains("not connected to camera") ||
        message.contains("socket is closed") ||
        message.contains("等待相机返回数据超时") ||
        message.contains("相机提前断开连接") ||
        message.contains("相机断开连接")
    case .catalog:
      return message.contains("socket 未建立") ||
        message.contains("connection reset") ||
        message.contains("broken pipe")
    case .download:
      return message.contains("not connected to camera") ||
        message.contains("socket is closed") ||
        message.contains("broken pipe") ||
        message.contains("connection reset") ||
        message.contains("等待相机返回数据超时")
    case .backgroundMetadata:
      return false
    }
  }

  private static func messageProvesContentFailure(_ description: String) -> Bool {
    let message = description.lowercased()
    return (message.contains("unsupported") && message.contains("format")) ||
      message.contains("decode failed") ||
      message.contains("decoding failed") ||
      message.contains("无法解码")
  }
}
