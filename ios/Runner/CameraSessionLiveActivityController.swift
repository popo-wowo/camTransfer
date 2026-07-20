import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

final class CameraSessionLiveActivityController {
  private var activity: Any?
  private var activityOperationTail: Task<Void, Never>?
  private var currentSessionID: String?
  private var cameraName = "Camera"
  private var galleryItemCount = 0
  private var isBackground = false
  private var isShowingDownloadProgress = false
  private var downloadCompletedCount = 0
  private var downloadTotalCount = 0

  var hasActiveDownloadSession: Bool {
    guard currentSessionID != nil else { return false }
    return downloadTotalCount > 0 && downloadCompletedCount < downloadTotalCount
  }

  func start(cameraName: String, itemCount: Int, reason: String) {
    self.cameraName = cameraName
    galleryItemCount = itemCount
    currentSessionID = nil
    isBackground = false
    isShowingDownloadProgress = false
    downloadCompletedCount = 0
    downloadTotalCount = 0
    CameraVendorFileLogger.log(
      "[LiveActivity] gallery-ready observed without active download reason=\(reason) camera=\(cameraName) items=\(itemCount)"
    )
  }

  func adoptOrStart(
    sessionID: UUID,
    cameraName: String,
    activitySnapshot: CameraSessionRuntimeActivitySnapshot
  ) {
    currentSessionID = sessionID.uuidString
    self.cameraName = cameraName
    galleryItemCount = activitySnapshot.galleryItemCount
    downloadCompletedCount = activitySnapshot.downloadCompletedCount
    downloadTotalCount = activitySnapshot.downloadTotalCount
    isBackground = activitySnapshot.isBackground
    isShowingDownloadProgress = activitySnapshot.isShowingDownloadProgress

    enqueueActivityOperation { [weak self] in
      guard let self else { return }
#if canImport(ActivityKit)
      guard #available(iOS 16.1, *) else {
        CameraVendorFileLogger.log("[LiveActivity] skip unsupported-ios reason=adopt sessionID=\(sessionID.uuidString)")
        return
      }
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        CameraVendorFileLogger.log("[LiveActivity] skip disabled reason=adopt sessionID=\(sessionID.uuidString)")
        return
      }
      let sessionKey = sessionID.uuidString
      for activity in Activity<CameraSessionActivityAttributes>.activities
      where activity.attributes.sessionID != sessionKey {
        await activity.end(
          using: CameraSessionActivityAttributes.ContentState(
            sessionID: activity.attributes.sessionID,
            galleryItemCount: 0,
            downloadCompletedCount: 0,
            downloadTotalCount: 0,
            isBackground: false,
            isShowingDownloadProgress: false,
            updatedAt: Date()
          ),
          dismissalPolicy: .immediate
        )
        CameraVendorFileLogger.log(
          "[LiveActivity] removed stale sessionID=\(activity.attributes.sessionID)"
        )
      }

      if let existing = Activity<CameraSessionActivityAttributes>.activities.first(where: {
        $0.attributes.sessionID == sessionKey
      }) {
        self.activity = existing
        await self.update(existing, activitySnapshot: activitySnapshot)
        CameraVendorFileLogger.log("[LiveActivity] adopted existing sessionID=\(sessionKey)")
        return
      }

      do {
        let requestedActivity: Activity<CameraSessionActivityAttributes> = try Activity.request(
          attributes: CameraSessionActivityAttributes(
            sessionID: sessionKey,
            cameraName: cameraName
          ),
          contentState: self.state(from: activitySnapshot),
          pushType: nil
        )
        self.activity = requestedActivity
        CameraVendorFileLogger.log(
          "[LiveActivity] started sessionID=\(sessionKey) camera=\(cameraName) queue=\(activitySnapshot.downloadTotalCount)"
        )
      } catch {
        CameraVendorFileLogger.log(
          "[LiveActivity] start failed sessionID=\(sessionKey) error=\(error.localizedDescription)"
        )
      }
#else
      CameraVendorFileLogger.log("[LiveActivity] skip ActivityKit unavailable reason=adopt")
#endif
    }
  }

  func updateForeground(reason: String) {
    isBackground = false
    update()
    CameraVendorFileLogger.log("[LiveActivity] foreground reason=\(reason)")
  }

  func updateBackground(reason: String) {
    isBackground = true
    update()
    CameraVendorFileLogger.log("[LiveActivity] background reason=\(reason)")
  }

  func updateDownloadStarted(completedCount: Int, totalCount: Int, reason: String) {
    updateDownloadProgress(
      completedCount: completedCount,
      totalCount: totalCount,
      reason: reason
    )
    CameraVendorFileLogger.log(
      "[LiveActivity] download-started reason=\(reason) completed=\(completedCount) total=\(totalCount)"
    )
  }

  func updateDownloadProgress(completedCount: Int, totalCount: Int, reason: String) {
    downloadTotalCount = max(totalCount, 0)
    downloadCompletedCount = min(max(completedCount, 0), downloadTotalCount)
    isShowingDownloadProgress = downloadTotalCount > 0 && downloadCompletedCount < downloadTotalCount
    update()
    CameraVendorFileLogger.log(
      "[LiveActivity] download-progress reason=\(reason) completed=\(downloadCompletedCount) " +
      "remaining=\(max(downloadTotalCount - downloadCompletedCount, 0)) total=\(downloadTotalCount)"
    )
  }

  func updateDownloadFinished(successCount: Int, failedCount: Int, reason: String) {
    downloadCompletedCount = max(successCount + failedCount, 0)
    downloadTotalCount = downloadCompletedCount
    isShowingDownloadProgress = false
    update()
    CameraVendorFileLogger.log(
      "[LiveActivity] download-finished reason=\(reason) success=\(successCount) failed=\(failedCount)"
    )
  }

  func end(reason: String) {
#if canImport(ActivityKit)
    guard #available(iOS 16.1, *) else { return }
    let endingSessionID = currentSessionID
    let finalState = state(
      galleryItemCount: galleryItemCount,
      completedCount: downloadCompletedCount,
      totalCount: downloadTotalCount,
      isBackground: false,
      isShowingDownloadProgress: false
    )
    currentSessionID = nil
    isShowingDownloadProgress = false
    self.activity = nil
    enqueueActivityOperation {
      let matchingActivity = Activity<CameraSessionActivityAttributes>.activities.first {
        endingSessionID == nil || $0.attributes.sessionID == endingSessionID
      }
      guard let matchingActivity else { return }
      await matchingActivity.end(using: finalState, dismissalPolicy: .immediate)
      CameraVendorFileLogger.log("[LiveActivity] ended reason=\(reason)")
    }
#else
    currentSessionID = nil
    isShowingDownloadProgress = false
#endif
  }

  func cleanupStaleActivities(reason: String) {
    currentSessionID = nil
    isShowingDownloadProgress = false
    activity = nil
#if canImport(ActivityKit)
    guard #available(iOS 16.1, *) else { return }
    enqueueActivityOperation {
      for activity in Activity<CameraSessionActivityAttributes>.activities {
        await activity.end(
          using: CameraSessionActivityAttributes.ContentState(
            sessionID: activity.attributes.sessionID,
            galleryItemCount: 0,
            downloadCompletedCount: 0,
            downloadTotalCount: 0,
            isBackground: false,
            isShowingDownloadProgress: false,
            updatedAt: Date()
          ),
          dismissalPolicy: .immediate
        )
      }
      CameraVendorFileLogger.log("[LiveActivity] cleaned stale activities reason=\(reason)")
    }
#endif
  }

  private func update() {
#if canImport(ActivityKit)
    guard #available(iOS 16.1, *) else { return }
    let nextState = state(
      galleryItemCount: galleryItemCount,
      completedCount: downloadCompletedCount,
      totalCount: downloadTotalCount,
      isBackground: isBackground,
      isShowingDownloadProgress: isShowingDownloadProgress
    )
    enqueueActivityOperation { [weak self] in
      guard let activity = self?.activity as? Activity<CameraSessionActivityAttributes> else { return }
      await activity.update(using: nextState)
    }
#endif
  }

  private func enqueueActivityOperation(_ operation: @escaping () async -> Void) {
    let previous = activityOperationTail
    activityOperationTail = Task {
      await previous?.value
      await operation()
    }
  }

#if canImport(ActivityKit)
  @available(iOS 16.1, *)
  private func update(
    _ activity: Activity<CameraSessionActivityAttributes>,
    activitySnapshot: CameraSessionRuntimeActivitySnapshot
  ) async {
    let nextState = state(from: activitySnapshot)
    await activity.update(using: nextState)
  }

  @available(iOS 16.1, *)
  private func state(
    galleryItemCount: Int,
    completedCount: Int,
    totalCount: Int,
    isBackground: Bool,
    isShowingDownloadProgress: Bool
  ) -> CameraSessionActivityAttributes.ContentState {
    CameraSessionActivityAttributes.ContentState(
      sessionID: currentSessionID ?? "",
      galleryItemCount: galleryItemCount,
      downloadCompletedCount: completedCount,
      downloadTotalCount: totalCount,
      isBackground: isBackground,
      isShowingDownloadProgress: isShowingDownloadProgress,
      updatedAt: Date()
    )
  }

  @available(iOS 16.1, *)
  private func state(from activitySnapshot: CameraSessionRuntimeActivitySnapshot) -> CameraSessionActivityAttributes.ContentState {
    CameraSessionActivityAttributes.ContentState(
      sessionID: activitySnapshot.sessionID.uuidString,
      galleryItemCount: activitySnapshot.galleryItemCount,
      downloadCompletedCount: activitySnapshot.downloadCompletedCount,
      downloadTotalCount: activitySnapshot.downloadTotalCount,
      isBackground: activitySnapshot.isBackground,
      isShowingDownloadProgress: activitySnapshot.isShowingDownloadProgress,
      updatedAt: Date()
    )
  }
#endif
}

extension CameraSessionLiveActivityController: CameraSessionRuntimeActivityReporting {
  func publish(_ snapshot: CameraSessionRuntimeActivitySnapshot, reason: String) {
    adoptOrStart(
      sessionID: snapshot.sessionID,
      cameraName: snapshot.cameraName,
      activitySnapshot: snapshot
    )
    CameraVendorFileLogger.log(
      "[LiveActivity] runtime-publish reason=\(reason) sessionID=\(snapshot.sessionID.uuidString)"
    )
  }

  func end(sessionID: UUID, reason: String) {
    guard currentSessionID == sessionID.uuidString else { return }
    end(reason: reason)
  }

  func cleanupStale(reason: String) {
    cleanupStaleActivities(reason: reason)
  }
}
