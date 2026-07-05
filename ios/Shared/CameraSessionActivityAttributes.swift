import Foundation

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct CameraSessionActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var phase: String
    var detail: String
    var itemCount: Int
    var isBackground: Bool
    var isDownloading: Bool
    var updatedAt: Date
  }

  var cameraName: String
}
#endif
