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
  private var catalogObserverID: UUID?
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

    evaluateCatalog()
  }

  /// Cancel an in-progress quick-download evaluation.
  func cancel() {
    isCancelled = true
    cancelObserver()
    completion = nil
  }

  // MARK: - Private

  private func evaluateCatalog() {
    let catalog = runtime.presentation.catalog
    CameraVendorFileLogger.log(
      "[QUICK_DOWNLOAD] evaluating rule=\(rule.summaryText) " +
      "catalogState=\(catalog.state) items=\(catalog.items.count)"
    )

    guard case .ready = catalog.state, !catalog.items.isEmpty else {
      CameraVendorFileLogger.log("[QUICK_DOWNLOAD] catalog not ready, waiting...")
      waitForCatalogReady()
      return
    }

    applyRuleAndFinish(items: catalog.items)
  }

  private func applyRuleAndFinish(items: [CameraVendorGalleryItem]) {
    guard !isCancelled else { return }

    let savedHandles = runtime.savedDownloadHandles()
    let matchedHandles = CameraAutoDownloadRuleFilter.matchingHandles(
      items: items,
      rule: rule,
      savedHandles: savedHandles
    )

    CameraVendorFileLogger.log(
      "[QUICK_DOWNLOAD] rule=\(rule.summaryText) " +
      "totalItems=\(items.count) matched=\(matchedHandles.count)"
    )

    guard !matchedHandles.isEmpty else {
      finish(.noMatch(ruleSummary: rule.summaryText))
      return
    }

    runtime.send(
      .startDownload(handles: matchedHandles, mode: rule.downloadMode.transferMode)
    )
    finish(.started(matchedCount: matchedHandles.count, handles: matchedHandles))
  }

  private func waitForCatalogReady() {
    cancelObserver()
    var hasSkippedInitialCallback = false
    catalogObserverID = runtime.observe { [weak self] presentation in
      guard let self, !self.isCancelled else { return }
      // Skip the immediate callback from observe() to avoid re-entry
      guard hasSkippedInitialCallback else {
        hasSkippedInitialCallback = true
        return
      }
      switch presentation.catalog.state {
      case .ready:
        guard !presentation.catalog.items.isEmpty else { return }
        self.cancelObserver()
        self.applyRuleAndFinish(items: presentation.catalog.items)
      case .failed, .transportLost, .unsupported:
        CameraVendorFileLogger.log("[QUICK_DOWNLOAD] catalog failed while waiting")
        self.cancelObserver()
        self.finish(.failed(reason: "自动下载失败：相册加载失败"))
      case .loading, .unavailable:
        break
      }
    }
  }

  private func cancelObserver() {
    if let id = catalogObserverID {
      runtime.removeObserver(id)
      catalogObserverID = nil
    }
  }

  private func finish(_ result: QuickDownloadResult) {
    guard let completion else { return }
    self.completion = nil
    cancelObserver()
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
