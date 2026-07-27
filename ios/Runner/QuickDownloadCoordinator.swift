import Foundation
import UIKit

// MARK: - Quick Download Result

enum QuickDownloadResult: Equatable {
  case started(matchedCount: Int, handles: [UInt32])
  case noMatch(ruleSummary: String)
  case failed(reason: String)
}

// MARK: - Quick Download Coordinator

/// Encapsulates the entire quick-download flow: session check → catalog wait
/// → rule filtering → download start. No UI logic — only orchestration.
///
/// Usage:
///   let coordinator = QuickDownloadCoordinator(runtime: runtime, rule: rule)
///   coordinator.execute { result in ... }
///   coordinator.cancel()
///
@MainActor
final class QuickDownloadCoordinator {
  private let runtime: CameraSessionRuntime
  private let rule: CameraAutoDownloadRule
  private var queryTask: Task<Void, Never>?
  private var completion: ((QuickDownloadResult) -> Void)?
  private var isCancelled = false

  init(runtime: CameraSessionRuntime, rule: CameraAutoDownloadRule) {
    self.runtime = runtime
    self.rule = rule
  }

  deinit {
    // Note: cancelObserver() is MainActor-isolated; if deinit runs on main
    // thread the observer is cleaned up by the coordinator's owner calling cancel().
  }

  /// Execute the quick-download flow. Calls completion exactly once.
  func execute(completion: @escaping (QuickDownloadResult) -> Void) {
    guard self.completion == nil else { return }
    self.completion = completion
    isCancelled = false

    guard runtime.galleryPresentationPayload != nil else {
      CameraVendorFileLogger.log("[QUICK_DOWNLOAD] no gallery payload, aborting")
      finish(.failed(reason: "自动下载失败：连接异常"))
      return
    }

    let ownerID = UUID()
    queryTask = Task { [weak self] in
      guard let self else { return }
      do {
        let resolution = try await runtime.resolveCatalog(
          rule: rule.filter,
          owner: .quickDownload(ownerID)
        )
        guard !Task.isCancelled, !isCancelled else { return }
        applyRuleAndFinish(handles: resolution.snapshot.items.map { UInt32($0.handle) })
      } catch is CancellationError {
        return
      } catch {
        finish(.failed(reason: "自动下载失败：相册加载失败"))
      }
    }
  }

  /// Cancel an in-progress quick-download evaluation.
  func cancel() {
    isCancelled = true
    queryTask?.cancel()
    queryTask = nil
    completion = nil
  }

  // MARK: - Private

  private func applyRuleAndFinish(handles matchedHandles: [UInt32]) {
    guard !isCancelled else { return }

    CameraVendorFileLogger.log(
      "[QUICK_DOWNLOAD] rule=\(rule.summaryText) " +
      "matched=\(matchedHandles.count)"
    )

    guard !matchedHandles.isEmpty else {
      finish(.noMatch(ruleSummary: rule.summaryText))
      return
    }

    guard runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: matchedHandles.map {
        CameraSessionQueuedDownload(handle: $0, mode: rule.downloadMode.transferMode)
      },
      origin: .quickDownload,
      completionPolicy: rule.disconnectAfterDownload ? .disconnectToHome : .returnToGallery
    )) else {
      finish(.failed(reason: "自动下载失败：已有下载任务正在执行"))
      return
    }
    finish(.started(matchedCount: matchedHandles.count, handles: matchedHandles))
  }

  private func finish(_ result: QuickDownloadResult) {
    guard let completion else { return }
    self.completion = nil
    queryTask = nil
    completion(result)
  }
}

// MARK: - Download Eligibility (Unified)

/// Single source of truth for whether a handle can be selected or downloaded.
/// Used by both gallery manual-download and quick-download.
enum DownloadEligibility {
  /// Whether the user can select this item (tap or drag-select).
  static func canSelect(state: CameraVendorDownloadState) -> Bool {
    switch state {
    case .idle, .failed, .saved:
      return true
    case .queued, .downloading:
      return false
    }
  }

  /// Whether this item can be submitted to the download queue.
  /// Same as canSelect — users expect "selected = downloadable".
  static func canStartDownload(state: CameraVendorDownloadState) -> Bool {
    switch state {
    case .idle, .failed, .saved:
      return true
    case .queued, .downloading:
      return false
    }
  }
}
