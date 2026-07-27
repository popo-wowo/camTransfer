import Foundation

enum QuickDownloadResult: Equatable {
  case started(matchedCount: Int, handles: [UInt32])
  case noMatch(ruleSummary: String)
  case failed(reason: String)
}

@MainActor
final class QuickDownloadUseCase {
  private let runtime: CameraSessionRuntime

  init(runtime: CameraSessionRuntime) {
    self.runtime = runtime
  }

  func execute(rule: CameraAutoDownloadRule) async -> QuickDownloadResult {
    guard runtime.activeCameraIdentity != nil else {
      return .failed(reason: "自动下载失败：连接异常")
    }

    do {
      let resolution = try await runtime.resolveCatalog(
        rule: rule.filter,
        owner: .quickDownload(UUID())
      )
      try Task.checkCancellation()
      let handles = resolution.snapshot.items.map { UInt32($0.handle) }

      CameraVendorFileLogger.log(
        "[QUICK_DOWNLOAD] rule=\(rule.summaryText) matched=\(handles.count)"
      )

      guard !handles.isEmpty else {
        guard await runtime.routeQuickDownloadNoMatch(completionPolicy: rule.completionPolicy) else {
          return .failed(reason: "自动下载失败：连接异常")
        }
        return .noMatch(ruleSummary: rule.summaryText)
      }

      let submission = CameraDownloadSubmission(
        id: UUID(),
        requests: handles.map {
          CameraSessionQueuedDownload(handle: $0, mode: rule.downloadMode.transferMode)
        },
        origin: .quickDownload,
        completionPolicy: rule.completionPolicy
      )
      guard runtime.submitDownload(submission) else {
        _ = await runtime.routeQuickDownloadFailure(
          completionPolicy: rule.completionPolicy,
          reason: "quick-download-submit-rejected"
        )
        return .failed(reason: "自动下载失败：已有下载任务正在执行")
      }
      return .started(matchedCount: handles.count, handles: handles)
    } catch is CancellationError {
      return .failed(reason: "自动下载已取消")
    } catch {
      _ = await runtime.routeQuickDownloadFailure(
        completionPolicy: rule.completionPolicy,
        reason: "quick-download-query-failed"
      )
      return .failed(reason: "自动下载失败：相册加载失败")
    }
  }
}

enum DownloadEligibility {
  static func canSelect(state: CameraVendorDownloadState) -> Bool {
    switch state {
    case .idle, .failed, .saved:
      return true
    case .queued, .downloading:
      return false
    }
  }

  static func canStartDownload(state: CameraVendorDownloadState) -> Bool {
    canSelect(state: state)
  }
}
