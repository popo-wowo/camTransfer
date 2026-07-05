import Foundation

struct IOSCameraDownloadHistoryRecord: Equatable, Codable {
  let cameraID: String
  let objectInfo: IOSCameraObjectInfo
  let thumbnailBytes: Data?
  let completedAt: Date
}

struct IOSCameraDownloadHistoryPayload: Equatable, Codable {
  let records: [IOSCameraDownloadHistoryRecord]
}
