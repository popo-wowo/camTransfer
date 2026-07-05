import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

final class CameraSessionLiveActivityController {
  private var activity: Any?
  private var cameraName = "Camera"
  private var itemCount = 0

  func start(cameraName: String, itemCount: Int, reason: String) {
    self.cameraName = cameraName
    self.itemCount = itemCount

#if canImport(ActivityKit)
    guard #available(iOS 16.1, *) else {
      CameraVendorFileLogger.log("[LiveActivity] skip unsupported-ios reason=\(reason)")
      return
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      CameraVendorFileLogger.log("[LiveActivity] skip disabled reason=\(reason)")
      return
    }
    if let existingActivity = activity as? Activity<CameraSessionActivityAttributes> {
      update(
        existingActivity,
        phase: "Connected",
        detail: "\(itemCount) items ready",
        isBackground: false,
        isDownloading: false
      )
      CameraVendorFileLogger.log("[LiveActivity] updated existing reason=\(reason)")
      return
    }

    do {
      let requestedActivity: Activity<CameraSessionActivityAttributes> = try Activity.request(
        attributes: CameraSessionActivityAttributes(cameraName: cameraName),
        contentState: state(
          phase: "Connected",
          detail: "\(itemCount) items ready",
          isBackground: false,
          isDownloading: false
        ),
        pushType: nil
      )
      activity = requestedActivity
      CameraVendorFileLogger.log("[LiveActivity] started reason=\(reason) camera=\(cameraName) items=\(itemCount)")
    } catch {
      CameraVendorFileLogger.log("[LiveActivity] start failed reason=\(reason) error=\(error.localizedDescription)")
    }
#else
    CameraVendorFileLogger.log("[LiveActivity] skip ActivityKit unavailable reason=\(reason)")
#endif
  }

  func updateForeground(reason: String) {
    update(phase: "Connected", detail: "\(itemCount) items ready", isBackground: false, isDownloading: false)
    CameraVendorFileLogger.log("[LiveActivity] foreground reason=\(reason)")
  }

  func updateBackground(reason: String) {
    update(phase: "Keeping connection", detail: "\(itemCount) items ready", isBackground: true, isDownloading: false)
    CameraVendorFileLogger.log("[LiveActivity] background reason=\(reason)")
  }

  func updateDownloadStarted(totalCount: Int, reason: String) {
    update(phase: "Downloading", detail: "\(totalCount) items queued", isBackground: false, isDownloading: true)
    CameraVendorFileLogger.log("[LiveActivity] download-started reason=\(reason) total=\(totalCount)")
  }

  func updateDownloadFinished(successCount: Int, failedCount: Int, reason: String) {
    let detail = failedCount > 0 ? "\(successCount) saved, \(failedCount) failed" : "\(successCount) saved"
    update(phase: "Connected", detail: detail, isBackground: false, isDownloading: false)
    CameraVendorFileLogger.log(
      "[LiveActivity] download-finished reason=\(reason) success=\(successCount) failed=\(failedCount)"
    )
  }

  func end(reason: String) {
#if canImport(ActivityKit)
    guard #available(iOS 16.1, *),
          let activity = activity as? Activity<CameraSessionActivityAttributes> else { return }
    let finalState = state(
      phase: "Disconnected",
      detail: "Camera session ended",
      isBackground: false,
      isDownloading: false
    )
    self.activity = nil
    Task {
      await activity.end(using: finalState, dismissalPolicy: .immediate)
      CameraVendorFileLogger.log("[LiveActivity] ended reason=\(reason)")
    }
#endif
  }

  private func update(
    phase: String,
    detail: String,
    isBackground: Bool,
    isDownloading: Bool
  ) {
#if canImport(ActivityKit)
    guard #available(iOS 16.1, *),
          let activity = activity as? Activity<CameraSessionActivityAttributes> else { return }
    update(activity, phase: phase, detail: detail, isBackground: isBackground, isDownloading: isDownloading)
#endif
  }

#if canImport(ActivityKit)
  @available(iOS 16.1, *)
  private func update(
    _ activity: Activity<CameraSessionActivityAttributes>,
    phase: String,
    detail: String,
    isBackground: Bool,
    isDownloading: Bool
  ) {
    let nextState = state(
      phase: phase,
      detail: detail,
      isBackground: isBackground,
      isDownloading: isDownloading
    )
    Task {
      await activity.update(using: nextState)
    }
  }

  @available(iOS 16.1, *)
  private func state(
    phase: String,
    detail: String,
    isBackground: Bool,
    isDownloading: Bool
  ) -> CameraSessionActivityAttributes.ContentState {
    CameraSessionActivityAttributes.ContentState(
      phase: phase,
      detail: detail,
      itemCount: itemCount,
      isBackground: isBackground,
      isDownloading: isDownloading,
      updatedAt: Date()
    )
  }
#endif
}
