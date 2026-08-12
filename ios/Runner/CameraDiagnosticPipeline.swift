import Foundation

enum CameraDiagnosticDataClass {
  case controlSignal
  case catalogMetadata
  case mediaPayload
}

enum CameraDiagnosticLevel {
  case operational
  case detail
  case trace
  case error
}

enum CameraDiagnosticDirection: String {
  case appToCamera
  case cameraToApp
  case internalFlow
}

struct CameraDiagnosticEvent {
  let source: String
  let name: String
  let level: CameraDiagnosticLevel
  let dataClass: CameraDiagnosticDataClass
  let direction: CameraDiagnosticDirection
  let message: String
}

enum CameraDiagnosticRetentionPolicy {
  private static let photoDetailTokens = [
    "PTP_THUMB_DATA",
    "PTP_ORIGINAL_READ_IMAGE_HEAD",
    "PTP_DOWNLOAD_DATA_INFO",
    "PTP_DOWNLOAD_FILE_INFO",
    "PTP_DOWNLOAD_PARTIAL_FALLBACK_INFO",
    "PTP_RESERVED_RECEIVE_OBJECT_INFO ",
    "PTP_RESERVED_RECEIVE_READ_IMAGE_INFO_OK",
    "PTP_RAW_PREVIEW_COMPANION_",
    "PTP_RAW_PREVIEW_THUMB_FALLBACK",
    "[PHOTO_LIB_THUMB]",
    "rawHead=",
    "normalizedHead=",
  ]

  static func shouldPersist(
    dataClass: CameraDiagnosticDataClass,
    level: CameraDiagnosticLevel
  ) -> Bool {
    guard dataClass != .mediaPayload else { return false }
    return level != .trace
  }

  static func shouldPersistLegacy(_ message: String) -> Bool {
    if shouldDropPhotoDetail(message) {
      return false
    }
    return CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(message)
  }

  static func shouldObserveLegacy(_ message: String) -> Bool {
    !shouldDropPhotoDetail(message)
  }

  private static func shouldDropPhotoDetail(_ message: String) -> Bool {
    isPhotoObjectDetail(message) || photoDetailTokens.contains(where: message.contains)
  }

  private static func isPhotoObjectDetail(_ message: String) -> Bool {
    if message.hasPrefix("请求对象信息 handle ") {
      return true
    }
    return message.hasPrefix("对象 ") &&
      message.contains("thumbSize=") &&
      message.contains("captureDate=")
  }
}

enum CameraDiagnosticSensitivityPolicy {
  private static let sensitiveKinds: Set<String> = [
    "pairing-token",
    "identification-ack",
  ]
  private static let sensitiveCharacteristicUUIDs: Set<String> = [
    "ABA356EB-9633-4E60-B73F-F52516DBD671",
    "E809256A-915C-4967-92E8-53B7D4CAD213",
    "F557D96B-8284-4667-8793-B971C1DECA2A",
  ]

  static func isSensitiveBLEControl(
    kind: String?,
    characteristicUUID: String
  ) -> Bool {
    if let kind, sensitiveKinds.contains(kind.lowercased()) {
      return true
    }
    return sensitiveCharacteristicUUIDs.contains(characteristicUUID.uppercased())
  }
}

enum CameraDiagnosticPayloadSummary {
  private static let fullControlPayloadLimit = 256
  private static let boundedPayloadEdgeBytes = 16

  static func specifiedHandles(
    stage: String,
    rawData: Data,
    handles: [UInt32]
  ) -> String {
    let first = handles.prefix(3).map(hexHandle).joined(separator: ",")
    let last = handles.suffix(3).map(hexHandle).joined(separator: ",")
    return "[OBS] PTP_SPECIFIED_OBJECT_HANDLES " +
      "stage=\(stage) bytes=\(rawData.count) count=\(handles.count) " +
      "first=\(first.isEmpty ? "none" : first) " +
      "last=\(last.isEmpty ? "none" : last) hash=\(shortHash(rawData))"
  }

  static func controlSignal(
    name: String,
    direction: CameraDiagnosticDirection,
    data: Data
  ) -> String {
    let prefix = "\(name) direction=\(direction.rawValue) bytes=\(data.count)"
    if data.count <= fullControlPayloadLimit {
      return "\(prefix) hex=\(hex(data))"
    }
    let head = data.prefix(boundedPayloadEdgeBytes)
    let tail = data.suffix(boundedPayloadEdgeBytes)
    return "\(prefix) head=\(hex(head)) tail=\(hex(tail)) hash=\(shortHash(data))"
  }

  static func sensitiveControlSignal(
    name: String,
    direction: CameraDiagnosticDirection,
    data: Data
  ) -> String {
    "\(name) direction=\(direction.rawValue) bytes=\(data.count) " +
      "redacted=true"
  }

  private static func hexHandle(_ handle: UInt32) -> String {
    String(format: "0x%08X", handle)
  }

  private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func shortHash(_ data: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%08llx", hash & 0xFFFF_FFFF)
  }
}

final class CameraDiagnosticPipeline {
  typealias Handler = (String) -> Void

  static let shared = CameraDiagnosticPipeline(
    persist: { CameraVendorFileLogger.persist($0) },
    observe: nil
  )

  private let queue = DispatchQueue(label: "com.camtransfer.diagnosticPipeline")
  private let persist: Handler
  private let observe: Handler?

  init(
    persist: @escaping Handler,
    observe: Handler?
  ) {
    self.persist = persist
    self.observe = observe
  }

  func emit(
    _ event: CameraDiagnosticEvent,
    additionalObserver: Handler? = nil
  ) {
    let rendered = CamTransferDiagnosticLogRedactor.redacted(
      "[\(event.source)] \(event.name) direction=\(event.direction.rawValue) \(event.message)"
    )
    queue.sync {
      let shouldRetain = CameraDiagnosticRetentionPolicy.shouldPersist(
        dataClass: event.dataClass,
        level: event.level
      )
      if shouldRetain {
        persist(rendered)
        observe?(rendered)
        additionalObserver?(rendered)
      }
    }
  }

  func emitLegacy(
    _ message: String,
    additionalObserver: Handler? = nil
  ) {
    let safeMessage = CamTransferDiagnosticLogRedactor.redacted(message)
    queue.sync {
      if CameraDiagnosticRetentionPolicy.shouldPersistLegacy(safeMessage) {
        persist(safeMessage)
      }
      if CameraDiagnosticRetentionPolicy.shouldObserveLegacy(safeMessage) {
        observe?(safeMessage)
        additionalObserver?(safeMessage)
      }
    }
  }
}
