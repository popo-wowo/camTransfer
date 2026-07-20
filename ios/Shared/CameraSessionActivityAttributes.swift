import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct CameraSessionActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var sessionID: String
    var galleryItemCount: Int
    var downloadCompletedCount: Int
    var downloadTotalCount: Int
    var isBackground: Bool
    var isShowingDownloadProgress: Bool
    var updatedAt: Date

    var downloadRemainingCount: Int {
      max(downloadTotalCount - downloadCompletedCount, 0)
    }

    var downloadProgressFraction: Double {
      guard downloadTotalCount > 0 else { return 0 }
      let progress = Double(downloadCompletedCount) / Double(downloadTotalCount)
      return min(max(progress, 0), 1)
    }
  }

  var sessionID: String
  var cameraName: String
}
#endif
