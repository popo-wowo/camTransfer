import Foundation

struct CameraPendingRememberedGalleryResume: Codable, Equatable {
  let peripheralID: UUID
  let reason: String
  let requestedAt: Date
}

struct CameraPendingRememberedCameraSession: Codable, Equatable {
  let peripheralID: UUID
  let reason: String
  let observedAt: Date
}

struct CameraDownloadSessionItem: Codable, Equatable {
  let handle: Int
  let mode: String

  init(handle: Int, mode: CameraVendorTransferDownloadMode) {
    self.handle = handle
    self.mode = mode == .compressed ? "compressed" : "original"
  }

  var downloadMode: CameraVendorTransferDownloadMode {
    mode == "compressed" ? .compressed : .original
  }
}

enum CameraDownloadSessionState: String, Codable, Equatable {
  case preparing
  case downloading
  case backgroundDownloading
  case interruptedRecoverable
  case interruptedTerminal
  case completed
  case cancelled
}

struct CameraDownloadSessionSnapshot: Codable, Equatable {
  let sessionID: UUID
  let peripheralID: UUID
  let cameraName: String
  let historyKey: String
  let state: CameraDownloadSessionState
  let recoveryIntent: String
  let presentationSurface: String
  let origin: CameraDownloadOrigin
  let completionPolicy: CameraDownloadCompletionPolicy
  let queue: [CameraDownloadSessionItem]
  let inFlightHandle: Int?
  let completedCount: Int
  let failedCount: Int
  let updatedAt: Date

  init(
    sessionID: UUID,
    peripheralID: UUID,
    cameraName: String,
    historyKey: String? = nil,
    state: CameraDownloadSessionState = .downloading,
    recoveryIntent: String = "download",
    presentationSurface: String = "gallery",
    origin: CameraDownloadOrigin = .recovery,
    completionPolicy: CameraDownloadCompletionPolicy = .returnToGallery,
    queue: [CameraDownloadSessionItem],
    inFlightHandle: Int?,
    completedCount: Int,
    failedCount: Int,
    updatedAt: Date
  ) {
    self.sessionID = sessionID
    self.peripheralID = peripheralID
    self.cameraName = cameraName
    self.historyKey = historyKey ?? cameraName
    self.state = state
    self.recoveryIntent = recoveryIntent
    self.presentationSurface = presentationSurface
    self.origin = origin
    self.completionPolicy = completionPolicy
    self.queue = queue
    self.inFlightHandle = inFlightHandle
    self.completedCount = completedCount
    self.failedCount = failedCount
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID
    case peripheralID
    case cameraName
    case historyKey
    case state
    case recoveryIntent
    case presentationSurface
    case origin
    case completionPolicy
    case queue
    case inFlightHandle
    case completedCount
    case failedCount
    case updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(UUID.self, forKey: .sessionID)
    peripheralID = try container.decode(UUID.self, forKey: .peripheralID)
    cameraName = try container.decode(String.self, forKey: .cameraName)
    historyKey = try container.decodeIfPresent(String.self, forKey: .historyKey) ?? cameraName
    let rawState = try container.decodeIfPresent(String.self, forKey: .state) ?? CameraDownloadSessionState.interruptedRecoverable.rawValue
    state = rawState == "backgroundActive" || rawState == "backgroundGrace"
      ? .backgroundDownloading
      : CameraDownloadSessionState(rawValue: rawState) ?? .interruptedRecoverable
    recoveryIntent = try container.decodeIfPresent(String.self, forKey: .recoveryIntent) ?? "download"
    presentationSurface = try container.decodeIfPresent(String.self, forKey: .presentationSurface) ?? "downloadCenter"
    let rawOrigin = try container.decodeIfPresent(String.self, forKey: .origin)
    origin = rawOrigin.flatMap(CameraDownloadOrigin.init(rawValue:)) ?? .recovery
    let rawCompletionPolicy = try container.decodeIfPresent(String.self, forKey: .completionPolicy)
    completionPolicy = rawCompletionPolicy.flatMap(CameraDownloadCompletionPolicy.init(rawValue:))
      ?? .returnToGallery
    queue = try container.decode([CameraDownloadSessionItem].self, forKey: .queue)
    inFlightHandle = try container.decodeIfPresent(Int.self, forKey: .inFlightHandle)
    completedCount = try container.decodeIfPresent(Int.self, forKey: .completedCount) ?? 0
    failedCount = try container.decodeIfPresent(Int.self, forKey: .failedCount) ?? 0
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  func replacing(
    state: CameraDownloadSessionState,
    recoveryIntent: String,
    queue: [CameraDownloadSessionItem]? = nil,
    completedCount: Int? = nil,
    failedCount: Int? = nil,
    updatedAt: Date? = nil
  ) -> CameraDownloadSessionSnapshot {
    CameraDownloadSessionSnapshot(
      sessionID: sessionID,
      peripheralID: peripheralID,
      cameraName: cameraName,
      historyKey: historyKey,
      state: state,
      recoveryIntent: recoveryIntent,
      presentationSurface: presentationSurface,
      origin: origin,
      completionPolicy: completionPolicy,
      queue: queue ?? self.queue,
      inFlightHandle: nil,
      completedCount: completedCount ?? self.completedCount,
      failedCount: failedCount ?? self.failedCount,
      updatedAt: updatedAt ?? self.updatedAt
    )
  }
}

final class CameraDownloadSessionStore {
  private let fileURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(fileURL: URL? = nil) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    self.fileURL = fileURL ?? docs.appendingPathComponent("camera-download-recovery.json")
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  func save(_ snapshot: CameraDownloadSessionSnapshot) throws {
    let data = try encoder.encode(snapshot)
    try data.write(to: fileURL, options: .atomic)
  }

  func load() throws -> CameraDownloadSessionSnapshot? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    return try decoder.decode(CameraDownloadSessionSnapshot.self, from: Data(contentsOf: fileURL))
  }

  func clear() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}

enum CameraDownloadSessionRecoveryPolicy {
  static let automaticResumeTTL: TimeInterval = 30 * 60

  struct Resolution: Equatable {
    let requests: [CameraVendorQueuedDownloadRequest]
    let unavailableItems: [CameraDownloadSessionItem]
    let savedItemCount: Int
    let uniqueItemCount: Int

    var isFullySaved: Bool {
      uniqueItemCount > 0 && savedItemCount == uniqueItemCount
    }
  }

  static func canAutoResume(
    _ snapshot: CameraDownloadSessionSnapshot,
    now: Date = Date()
  ) -> Bool {
    guard shouldRetainForManualRecovery(snapshot) else { return false }
    switch snapshot.state {
    case .preparing, .downloading, .backgroundDownloading, .interruptedRecoverable:
      break
    case .interruptedTerminal, .completed, .cancelled:
      return false
    }
    return now.timeIntervalSince(snapshot.updatedAt) <= automaticResumeTTL
  }

  static func shouldRetainForManualRecovery(_ snapshot: CameraDownloadSessionSnapshot) -> Bool {
    guard !snapshot.queue.isEmpty else { return false }
    switch snapshot.state {
    case .completed, .cancelled:
      return false
    case .preparing, .downloading, .backgroundDownloading, .interruptedRecoverable, .interruptedTerminal:
      return true
    }
  }

  static func resolve(
    _ snapshot: CameraDownloadSessionSnapshot,
    availableHandles: Set<Int>,
    savedHandles: Set<Int>
  ) -> Resolution {
    var seenHandles = Set<Int>()
    var requests: [CameraVendorQueuedDownloadRequest] = []
    var unavailableItems: [CameraDownloadSessionItem] = []
    var savedItemCount = 0

    for item in snapshot.queue where seenHandles.insert(item.handle).inserted {
      if savedHandles.contains(item.handle) {
        savedItemCount += 1
      } else if availableHandles.contains(item.handle) {
        requests.append(
          CameraVendorQueuedDownloadRequest(handle: item.handle, mode: item.downloadMode)
        )
      } else {
        unavailableItems.append(item)
      }
    }

    return Resolution(
      requests: requests,
      unavailableItems: unavailableItems,
      savedItemCount: savedItemCount,
      uniqueItemCount: seenHandles.count
    )
  }
}

final class CameraGalleryResumeStore {
  static let shared = CameraGalleryResumeStore()

  private let resumeFileURL: URL
  private let sessionFileURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(fileURL: URL? = nil, sessionFileURL: URL? = nil) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    self.resumeFileURL = fileURL ?? docs.appendingPathComponent("camera-gallery-resume.json")
    self.sessionFileURL = sessionFileURL ?? docs.appendingPathComponent("camera-gallery-session.json")
    encoder.dateEncodingStrategy = .iso8601
    decoder.dateDecodingStrategy = .iso8601
  }

  func savePendingRememberedGalleryResume(_ resume: CameraPendingRememberedGalleryResume) {
    guard let data = try? encoder.encode(resume) else { return }
    try? data.write(to: resumeFileURL, options: .atomic)
  }

  func consumePendingRememberedGalleryResume() -> CameraPendingRememberedGalleryResume? {
    let resume = peekPendingRememberedGalleryResume()
    clearPendingRememberedGalleryResume()
    return resume
  }

  func peekPendingRememberedGalleryResume() -> CameraPendingRememberedGalleryResume? {
    guard let data = try? Data(contentsOf: resumeFileURL) else { return nil }
    return try? decoder.decode(CameraPendingRememberedGalleryResume.self, from: data)
  }

  func clearPendingRememberedGalleryResume() {
    try? FileManager.default.removeItem(at: resumeFileURL)
  }

  func savePendingRememberedCameraSession(_ session: CameraPendingRememberedCameraSession) {
    guard let data = try? encoder.encode(session) else { return }
    try? data.write(to: sessionFileURL, options: .atomic)
  }

  func peekPendingRememberedCameraSession() -> CameraPendingRememberedCameraSession? {
    guard let data = try? Data(contentsOf: sessionFileURL) else { return nil }
    return try? decoder.decode(CameraPendingRememberedCameraSession.self, from: data)
  }

  func clearPendingRememberedCameraSession() {
    try? FileManager.default.removeItem(at: sessionFileURL)
  }
}
