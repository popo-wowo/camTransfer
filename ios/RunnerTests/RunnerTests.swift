import Darwin
import ImageIO
import Network
import NetworkExtension
import UIKit
import XCTest
@testable import Runner

private actor AsyncTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen {
      return
    }
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        self.continuation = continuation
      }
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

final class RunnerTests: XCTestCase {
  func testWiredCameraImportPolicyAcceptsPhotosAndVideos() {
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0001.JPG", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0002.RAF", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "DSCF0003.MOV", uti: nil))
    XCTAssertTrue(WiredCameraImportPolicy.isSupportedMedia(filename: "image.heic", uti: "public.heic"))
    XCTAssertFalse(WiredCameraImportPolicy.isSupportedMedia(filename: "camera.db", uti: "public.data"))
  }

  func testWiredCameraImportStateSelectsOnlyImportableItems() {
    let first = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )
    let second = WiredCameraImportItem(
      id: "2",
      name: "README.TXT",
      uti: "public.text",
      fileSize: 512,
      createdAt: nil,
      thumbnail: nil,
      isImportable: false
    )

    var state = WiredCameraImportState()
    state.replaceItems([first, second])
    state.selectAllImportable()

    XCTAssertEqual(state.selectedItemIDs, ["1"])
    XCTAssertEqual(state.selectedImportableItems, [first])
  }

  func testWiredCameraImportStateDropsSelectionsWhenItemsRefresh() {
    let first = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )
    let next = WiredCameraImportItem(
      id: "2",
      name: "DSCF0002.JPG",
      uti: "public.jpeg",
      fileSize: 2048,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )

    var state = WiredCameraImportState()
    state.replaceItems([first])
    state.toggleSelection(for: first)
    state.replaceItems([next])

    XCTAssertTrue(state.selectedItemIDs.isEmpty)
  }

  func testWiredCameraDeletePolicyRequiresExactlyOneLiveSelectedPhoto() {
    let first = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )
    let second = WiredCameraImportItem(
      id: "2",
      name: "DSCF0002.JPG",
      uti: "public.jpeg",
      fileSize: 2048,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )

    var state = WiredCameraImportState()
    state.replaceItems([first, second])
    state.toggleSelection(for: first)

    XCTAssertEqual(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: false), first)

    state.toggleSelection(for: second)
    XCTAssertNil(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: false))
  }

  func testWiredCameraDeletePolicyRejectsCachedImportedAndBusySelections() {
    let item = WiredCameraImportItem(
      id: "1",
      name: "DSCF0001.JPG",
      uti: "public.jpeg",
      fileSize: 1024,
      createdAt: nil,
      thumbnail: nil,
      isImportable: true
    )

    var state = WiredCameraImportState()
    state.replaceItems([item], isLiveCatalog: false)
    state.selectedItemIDs = [item.id]
    XCTAssertNil(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: false))

    state.replaceItems([item])
    state.selectedItemIDs = [item.id]
    state.importedItemIDs = [item.id]
    XCTAssertNil(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: false))

    state.importedItemIDs.removeAll()
    XCTAssertNil(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: true))

    state.isImporting = true
    XCTAssertNil(WiredCameraDeletePolicy.selectedItem(from: state, isDeleting: false))
  }

  func testWiredCameraThumbnailQueueDoesNotStartWhileDeletionIsInFlight() {
    XCTAssertTrue(
      WiredCameraThumbnailQueuePolicy.shouldStartRequest(
        isDeleteInFlight: false,
        hasActiveThumbnailRequest: false
      )
    )
    XCTAssertFalse(
      WiredCameraThumbnailQueuePolicy.shouldStartRequest(
        isDeleteInFlight: true,
        hasActiveThumbnailRequest: false
      )
    )
    XCTAssertFalse(
      WiredCameraThumbnailQueuePolicy.shouldStartRequest(
        isDeleteInFlight: false,
        hasActiveThumbnailRequest: true
      )
    )
  }

  func testWiredCameraThumbnailQueueDoesNotStartWhileForegroundOperationIsInFlight() {
    XCTAssertFalse(
      WiredCameraThumbnailQueuePolicy.shouldStartRequest(
        isDeleteInFlight: false,
        isForegroundOperationInFlight: true,
        hasActiveThumbnailRequest: false
      )
    )
  }

  func testWiredCameraPreviewPolicyUsesLargerPreviewThanGrid() {
    XCTAssertEqual(WiredCameraPreviewPolicy.gridMaximumPixelSize, 320)
    XCTAssertEqual(WiredCameraPreviewPolicy.maximumPixelSize, 1_536)
    XCTAssertGreaterThan(
      WiredCameraPreviewPolicy.maximumPixelSize,
      WiredCameraPreviewPolicy.gridMaximumPixelSize
    )
  }

  func testWiredCameraImportSortPolicyUsesHandleAndNameToKeepNewestOrderStable() {
    let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let oldest = wiredImportItem(id: "oldest", name: "DSCF0001.JPG", createdAt: capturedAt.addingTimeInterval(-1))
    let lowerHandle = wiredImportItem(
      id: "lower-handle",
      name: "DSCF0003.JPG",
      createdAt: capturedAt,
      ptpObjectHandle: 19
    )
    let sameHandleLaterName = wiredImportItem(
      id: "later-name",
      name: "DSCF0004.JPG",
      createdAt: capturedAt,
      ptpObjectHandle: 20
    )
    let sameHandleEarlierName = wiredImportItem(
      id: "earlier-name",
      name: "DSCF0002.JPG",
      createdAt: capturedAt,
      ptpObjectHandle: 20
    )

    let ordered = WiredCameraImportSortPolicy.newestFirst([
      oldest,
      lowerHandle,
      sameHandleEarlierName,
      sameHandleLaterName,
    ])

    XCTAssertEqual(ordered.map(\.id), ["later-name", "earlier-name", "lower-handle", "oldest"])
  }

  func testWiredCameraThumbnailRequestWindowPrioritizesVisibleItemsBeforeNearbyRows() {
    let orderedIDs = (0..<12).map { "item-\($0)" }

    let requestedIDs = WiredCameraThumbnailRequestWindowPolicy.itemIDsToRequest(
      orderedItemIDs: orderedIDs,
      visibleItemIDs: ["item-5", "item-4"],
      columnCount: 3
    )

    XCTAssertEqual(requestedIDs.prefix(2), ["item-4", "item-5"])
    XCTAssertEqual(Set(requestedIDs), Set(orderedIDs.dropFirst()))
  }

  func testWiredCameraImportSectionPolicyGroupsNewestItemsByCaptureDay() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let sections = WiredCameraImportSectionPolicy.sections(
      from: [
        wiredImportItem(id: "today-new", name: "DSCF0003.JPG", createdAt: now),
        wiredImportItem(id: "today-old", name: "DSCF0002.JPG", createdAt: now.addingTimeInterval(-60)),
        wiredImportItem(id: "yesterday", name: "DSCF0001.JPG", createdAt: yesterday),
        wiredImportItem(id: "unknown", name: "DSCF0000.JPG", createdAt: nil),
      ],
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(sections.map(\.items).map { $0.map(\.id) }, [
      ["today-new", "today-old"],
      ["yesterday"],
      ["unknown"],
    ])
    XCTAssertEqual(sections.map(\.title), ["今天 · 2 张", "昨天 · 1 张", "未知日期 · 1 张"])
  }

  func testWiredCameraImportItemIdentityDoesNotUseTemporaryPtpHandleAlone() {
    let first = WiredCameraImportItemIdentity.make(
      ptpObjectHandle: 1,
      filename: "DSCF0001.JPG",
      fileSize: 1_024,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let second = WiredCameraImportItemIdentity.make(
      ptpObjectHandle: 1,
      filename: "DSCF0999.JPG",
      fileSize: 2_048,
      createdAt: Date(timeIntervalSince1970: 1_800_000_500)
    )

    XCTAssertNotEqual(first, "1")
    XCTAssertNotEqual(first, second)
  }

  func testNativeHomeRememberedGalleryResumePolicyRequiresExplicitPendingResume() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pendingSession = CameraPendingRememberedCameraSession(
      peripheralID: UUID(uuidString: "8ACA4503-C37D-9F59-1850-E247C3B83A7B")!,
      reason: "gallery",
      observedAt: now.addingTimeInterval(-30)
    )

    XCTAssertFalse(
      NativeHomeRememberedGalleryResumePolicy.shouldAutoResume(
        pendingSession: pendingSession,
        pendingResume: nil,
        hasRememberedCamera: true,
        isEnteringGalleryFromRememberedCamera: false,
        hasConnectFlowTask: false,
        isBlockedByPrompt: false,
        now: now
      )
    )
  }

  func testNativeHomeRememberedGalleryResumePolicyAutoResumesRecentPendingResume() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pendingSession = CameraPendingRememberedCameraSession(
      peripheralID: UUID(uuidString: "8ACA4503-C37D-9F59-1850-E247C3B83A7B")!,
      reason: "gallery",
      observedAt: now.addingTimeInterval(-30)
    )
    let pendingResume = CameraPendingRememberedGalleryResume(
      peripheralID: UUID(uuidString: "8ACA4503-C37D-9F59-1850-E247C3B83A7B")!,
      reason: "became-active",
      requestedAt: now.addingTimeInterval(-5)
    )

    XCTAssertTrue(
      NativeHomeRememberedGalleryResumePolicy.shouldAutoResume(
        pendingSession: pendingSession,
        pendingResume: pendingResume,
        hasRememberedCamera: true,
        isEnteringGalleryFromRememberedCamera: false,
        hasConnectFlowTask: false,
        isBlockedByPrompt: false,
        now: now
      )
    )
  }

  func testNativeHomeRememberedGalleryResumePolicyRejectsStalePendingSession() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let pendingSession = CameraPendingRememberedCameraSession(
      peripheralID: UUID(uuidString: "8ACA4503-C37D-9F59-1850-E247C3B83A7B")!,
      reason: "gallery",
      observedAt: now.addingTimeInterval(-1_200)
    )

    XCTAssertFalse(
      NativeHomeRememberedGalleryResumePolicy.shouldAutoResume(
        pendingSession: pendingSession,
        pendingResume: nil,
        hasRememberedCamera: true,
        isEnteringGalleryFromRememberedCamera: false,
        hasConnectFlowTask: false,
        isBlockedByPrompt: false,
        now: now
      )
    )
    XCTAssertTrue(
      NativeHomeRememberedGalleryResumePolicy.shouldClearStaleSession(
        pendingSession: pendingSession,
        pendingResume: nil,
        now: now
      )
    )
  }

  func testDownloadSessionStorePersistsRecoverableSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("camtransfer-download-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("camera-download-recovery.json")
    let store = CameraDownloadSessionStore(fileURL: fileURL)
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(uuidString: "41D2CA12-1B5D-4CAE-BD62-7B68FA3F4261")!,
      peripheralID: UUID(uuidString: "8ACA4503-C37D-9F59-1850-E247C3B83A7B")!,
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "downloadCenter",
      origin: .quickDownload,
      completionPolicy: .disconnectToHome,
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: 1845,
      completedCount: 3,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try store.save(snapshot)

    XCTAssertEqual(try store.load(), snapshot)
  }

  func testDownloadSessionSnapshotLegacyPayloadDefaultsToGalleryCompletionAndReplacingPreservesRouting() throws {
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "runtime",
      origin: .quickDownload,
      completionPolicy: .disconnectToHome,
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: 1845,
      completedCount: 0,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var legacyPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any]
    )
    legacyPayload.removeValue(forKey: "origin")
    legacyPayload.removeValue(forKey: "completionPolicy")

    let decoded = try JSONDecoder().decode(
      CameraDownloadSessionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: legacyPayload)
    )

    XCTAssertEqual(decoded.origin, .recovery)
    XCTAssertEqual(decoded.completionPolicy, .returnToGallery)
    let replaced = snapshot.replacing(
      state: .interruptedTerminal,
      recoveryIntent: "manual-recovery"
    )
    XCTAssertEqual(replaced.origin, .quickDownload)
    XCTAssertEqual(replaced.completionPolicy, .disconnectToHome)
  }

  func testDownloadSessionSnapshotUnknownRoutingValuesFallBackToRecoveryDefaults() throws {
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "runtime",
      origin: .quickDownload,
      completionPolicy: .disconnectToHome,
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: 1845,
      completedCount: 0,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any]
    )
    payload["origin"] = "futureDownloadOrigin"
    payload["completionPolicy"] = "futureCompletionPolicy"

    let decoded = try JSONDecoder().decode(
      CameraDownloadSessionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: payload)
    )

    XCTAssertEqual(decoded.origin, .recovery)
    XCTAssertEqual(decoded.completionPolicy, .returnToGallery)
  }

  @MainActor
  func testRuntimeRecoveryStoreClearsCorruptedSnapshotFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("camtransfer-corrupted-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("camera-download-recovery.json")
    try Data("not-json".utf8).write(to: fileURL)
    let runtimeStore = CameraDownloadSessionRuntimeRecoveryStore(
      store: CameraDownloadSessionStore(fileURL: fileURL)
    )

    XCTAssertNil(runtimeStore.loadInterruptedRecoverable())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }


  func testDownloadSessionSnapshotDecodesLegacyBackgroundGraceAsBackgroundDownloading() throws {
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .downloading,
      recoveryIntent: "download",
      presentationSurface: "gallery",
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: 1845,
      completedCount: 0,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as? [String: Any]
    )
    payload["state"] = "backgroundGrace"

    let decoded = try JSONDecoder().decode(
      CameraDownloadSessionSnapshot.self,
      from: JSONSerialization.data(withJSONObject: payload)
    )

    XCTAssertEqual(decoded.state, .backgroundDownloading)
  }




  func testDownloadRecoveryPolicyKeepsStaleSnapshotForManualRecovery() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "downloadCenter",
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: nil,
      completedCount: 3,
      failedCount: 0,
      updatedAt: now.addingTimeInterval(-3_600)
    )

    XCTAssertFalse(CameraDownloadSessionRecoveryPolicy.canAutoResume(snapshot, now: now))
    XCTAssertTrue(CameraDownloadSessionRecoveryPolicy.shouldRetainForManualRecovery(snapshot))
  }

  func testDownloadRecoveryPolicyNeverAutoResumesTerminalSnapshot() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedTerminal,
      recoveryIntent: "catalog-missing-items",
      presentationSurface: "downloadCenter",
      queue: [CameraDownloadSessionItem(handle: 1845, mode: .original)],
      inFlightHandle: nil,
      completedCount: 3,
      failedCount: 0,
      updatedAt: now
    )

    XCTAssertFalse(CameraDownloadSessionRecoveryPolicy.canAutoResume(snapshot, now: now))
    XCTAssertTrue(CameraDownloadSessionRecoveryPolicy.shouldRetainForManualRecovery(snapshot))
  }

  func testDownloadRecoveryResolutionKeepsUnavailableItemsInsteadOfCompletingSession() {
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "downloadCenter",
      queue: [
        CameraDownloadSessionItem(handle: 1845, mode: .original),
        CameraDownloadSessionItem(handle: 1846, mode: .compressed),
      ],
      inFlightHandle: nil,
      completedCount: 3,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let resolution = CameraDownloadSessionRecoveryPolicy.resolve(
      snapshot,
      availableHandles: [],
      savedHandles: [1845]
    )

    XCTAssertTrue(resolution.requests.isEmpty)
    XCTAssertEqual(resolution.unavailableItems, [CameraDownloadSessionItem(handle: 1846, mode: .compressed)])
    XCTAssertFalse(resolution.isFullySaved)
  }

  func testDownloadRecoveryResolutionCompletesOnlyWhenEveryQueuedItemWasSaved() {
    let snapshot = CameraDownloadSessionSnapshot(
      sessionID: UUID(),
      peripheralID: UUID(),
      cameraName: "X-T5",
      state: .interruptedRecoverable,
      recoveryIntent: "background-expired",
      presentationSurface: "downloadCenter",
      queue: [
        CameraDownloadSessionItem(handle: 1845, mode: .original),
        CameraDownloadSessionItem(handle: 1846, mode: .compressed),
      ],
      inFlightHandle: nil,
      completedCount: 3,
      failedCount: 0,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    let resolution = CameraDownloadSessionRecoveryPolicy.resolve(
      snapshot,
      availableHandles: [],
      savedHandles: [1845, 1846]
    )

    XCTAssertTrue(resolution.requests.isEmpty)
    XCTAssertTrue(resolution.unavailableItems.isEmpty)
    XCTAssertTrue(resolution.isFullySaved)
  }


  func testGalleryStatePendingDownloadRequestsKeepDownloadingBeforeQueued() {
    var state = CameraVendorGalleryState()
    let requests = [
      CameraVendorQueuedDownloadRequest(handle: 1, mode: .compressed),
      CameraVendorQueuedDownloadRequest(handle: 2, mode: .original),
    ]

    state.enqueueDownloads(requests)
    state.markDownloadStarted(handle: 1, position: 1, total: 2)

    XCTAssertEqual(state.pendingDownloadRequests(), requests)
  }

  func testCameraSessionLiveActivityAttributesCarrySessionIdentity() {
#if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      let attributes = CameraSessionActivityAttributes(
        sessionID: "session-1",
        cameraName: "X-T5"
      )
      let state = CameraSessionActivityAttributes.ContentState(
        sessionID: "session-1",
        galleryItemCount: 0,
        downloadCompletedCount: 4,
        downloadTotalCount: 9,
        isBackground: true,
        isShowingDownloadProgress: true,
        updatedAt: Date(timeIntervalSince1970: 1234)
      )

      XCTAssertEqual(attributes.sessionID, "session-1")
      XCTAssertEqual(state.sessionID, "session-1")
      XCTAssertEqual(state.downloadRemainingCount, 5)
    }
#endif
  }

  func testCameraSessionLiveActivityControllerCleansUpStaleActivitiesOnAdopt() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionLiveActivityController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("func adoptOrStart("))
    XCTAssertTrue(source.contains("Activity<CameraSessionActivityAttributes>.activities"))
    XCTAssertTrue(source.contains("activity.attributes.sessionID != sessionKey"))
    XCTAssertTrue(source.contains("await activity.end"))
  }

  func testCameraSessionLiveActivityUsesDownloadSessionCountsInsteadOfGalleryReadyItemCount() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionLiveActivityController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("state(from activitySnapshot: CameraSessionRuntimeActivitySnapshot)"))
    XCTAssertTrue(source.contains("downloadCompletedCount: activitySnapshot.downloadCompletedCount"))
    XCTAssertTrue(source.contains("downloadTotalCount: activitySnapshot.downloadTotalCount"))
  }

  func testLiveActivityControllerSerializesSystemActivityOperations() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionLiveActivityController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("private var activityOperationTail: Task<Void, Never>?"))
    XCTAssertTrue(source.contains("enqueueActivityOperation"))
  }

  func testDownloadDiagnosticLogPolicyDemotesChunkLogsToMemoryOnlyByDefault() throws {
    let source = try runnerSource(
      "CameraVendorDiagnostics.swift",
      "CameraVendorBluetoothService.swift"
    )

    XCTAssertTrue(source.contains("CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk"))
    XCTAssertTrue(source.contains("PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK"))
    XCTAssertTrue(source.contains("PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST"))
    XCTAssertTrue(source.contains("logStore.append(line, writesToDisk: shouldWriteToDisk)"))
  }

  func testCameraVendorFileLoggerUsesRollingFileLimits() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorDiagnostics.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("enum CameraVendorFileLogPolicy"))
    XCTAssertTrue(source.contains("maxPrimaryLogBytes"))
    XCTAssertTrue(source.contains("maxArchiveLogCount"))
    XCTAssertTrue(source.contains("trimAndRotateIfNeeded"))
  }

  func testCameraVendorFastLogStoreUsesRollingFileLimits() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let storeStart = try XCTUnwrap(source.range(of: "final class CameraVendorLogStore")?.lowerBound)
    let storeEnd = try XCTUnwrap(
      source.range(of: "protocol CameraVendorBluetoothServiceDelegate", range: storeStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[storeStart..<storeEnd])

    XCTAssertTrue(body.contains("trimAndRotateIfNeeded"))
    XCTAssertTrue(body.contains("CameraVendorFileLogPolicy.maxPrimaryLogBytes"))
    XCTAssertTrue(body.contains("CameraVendorFileLogPolicy.maxArchiveLogCount"))
  }

  func testFastDiagnosticLogPolicyDemotesKeepAliveNoiseToMemoryOnly() {
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] BLE_BACKGROUND_KEEP_ALIVE_READ reason=download index=1/2 uuid=1234"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] BLE_BACKGROUND_KEEP_ALIVE_READ " +
        "reason=download-thermal-experiment-once experimentBranch=bleOnce " +
        "physicalSession=session-1 generation=1 index=1/2 uuid=1234"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] GALLERY_BACKGROUND_READ_IMAGE_INFO_KEEP_ALIVE_OK op=0x9054 handle=0x00000001"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] GALLERY_BACKGROUND_METADATA_REQUEST_BEGIN handle=0x00000001 active=1"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "图库: [OBS] GALLERY_BACKGROUND_METADATA_REQUEST_END handle=0x00000001 active=0"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=download-data handle=0x00000065"
      )
    )
    XCTAssertFalse(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=download-data handle=0x00000065 chunkBytes=4194304"
      )
    )
    XCTAssertTrue(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_FAILED purpose=download-data error=connection-lost"
      )
    )
    XCTAssertTrue(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST_FAILED purpose=download-data error=connection-lost"
      )
    )
    XCTAssertTrue(
      CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk(
        "[OBS] BLE_BACKGROUND_KEEP_ALIVE_FAILED reason=download error=disconnected"
      )
    )
  }

  func testWiredCameraImportStateDropsImportedStatusForItemsNoLongerInLiveCatalog() {
    let stale = wiredImportItem(id: "stale", name: "DSCF0001.JPG")
    let current = wiredImportItem(id: "current", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([stale, current], isLiveCatalog: false)
    state.importedItemIDs = ["stale", "current", "missing"]

    state.replaceItems([current], isLiveCatalog: true)

    XCTAssertEqual(state.importedItemIDs, ["current"])
  }

  func testWiredCameraImportFilterPolicyCombinesDateFormatAndImportedStatus() {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let todayJpg = wiredImportItem(id: "today-jpg", name: "DSCF0001.JPG", createdAt: now)
    let todayRaw = wiredImportItem(id: "today-raw", name: "DSCF0002.RAF", uti: "com.fuji.raw-image", createdAt: now)
    let oldJpg = wiredImportItem(id: "old-jpg", name: "DSCF0003.JPG", createdAt: yesterday)

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      [todayJpg, todayRaw, oldJpg],
      state: WiredCameraImportFilterState(date: .today, format: .jpg, importedStatus: .notImported),
      importedItemIDs: ["today-raw"],
      now: now,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["today-jpg"])
  }

  func testWiredCameraImportFilterPolicyMatchesSpecificDay() {
    let calendar = Calendar(identifier: .gregorian)
    let target = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = calendar.date(byAdding: .day, value: -1, to: target)!
    let targetJpg = wiredImportItem(id: "target", name: "DSCF0001.JPG", createdAt: target)
    let previousJpg = wiredImportItem(id: "previous", name: "DSCF0002.JPG", createdAt: previous)

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      [previousJpg, targetJpg],
      state: WiredCameraImportFilterState(date: .specificDay(target), format: .all, importedStatus: .all),
      importedItemIDs: [],
      now: target,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["target"])
  }

  func testWiredCameraImportFilterPolicyMatchesInclusiveDateRange() {
    let calendar = Calendar(identifier: .gregorian)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let middle = calendar.date(byAdding: .day, value: 2, to: start)!
    let end = calendar.date(byAdding: .day, value: 4, to: start)!
    let before = calendar.date(byAdding: .day, value: -1, to: start)!
    let after = calendar.date(byAdding: .day, value: 1, to: end)!
    let items = [
      wiredImportItem(id: "before", name: "DSCF0001.JPG", createdAt: before),
      wiredImportItem(id: "start", name: "DSCF0002.JPG", createdAt: start),
      wiredImportItem(id: "middle", name: "DSCF0003.JPG", createdAt: middle),
      wiredImportItem(id: "end", name: "DSCF0004.JPG", createdAt: end),
      wiredImportItem(id: "after", name: "DSCF0005.JPG", createdAt: after),
    ]

    let filtered = WiredCameraImportFilterPolicy.filteredItems(
      items,
      state: WiredCameraImportFilterState(date: .range(end, start), format: .all, importedStatus: .all),
      importedItemIDs: [],
      now: start,
      calendar: calendar
    )

    XCTAssertEqual(filtered.map(\.id), ["start", "middle", "end"])
  }

  func testWiredCameraImportStateSelectsOnlyFilteredImportableItems() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let jpg = wiredImportItem(id: "jpg", name: "DSCF0001.JPG", createdAt: now)
    let raw = wiredImportItem(id: "raw", name: "DSCF0002.RAF", uti: "com.fuji.raw-image", createdAt: now)
    let unsupported = wiredImportItem(
      id: "txt",
      name: "README.TXT",
      uti: "public.text",
      createdAt: now,
      isImportable: false
    )

    var state = WiredCameraImportState()
    state.filterState = WiredCameraImportFilterState(format: .raw)
    state.replaceItems([jpg, raw, unsupported])
    state.selectAllFilteredImportable(now: now)

    XCTAssertEqual(state.filteredItems(now: now).map(\.id), ["raw"])
    XCTAssertEqual(state.selectedItemIDs, ["raw"])
    XCTAssertEqual(state.selectedFilteredImportableItems(now: now), [raw])
  }

  func testWiredCameraImportStateTracksImportedItemsAndFiltersThem() {
    let imported = wiredImportItem(id: "saved", name: "DSCF0001.JPG")
    let pending = wiredImportItem(id: "pending", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([imported, pending])
    state.markImported(itemID: imported.id)
    state.filterState = WiredCameraImportFilterState(importedStatus: .imported)

    XCTAssertEqual(state.filteredItems().map(\.id), ["saved"])
    XCTAssertFalse(state.selectedItemIDs.contains(imported.id))
  }

  func testWiredCameraImportStateKeepsProofingFavoritesSeparateFromImportSelectionAndImportedStatus() {
    let imported = wiredImportItem(id: "saved", name: "DSCF0001.JPG")
    let pending = wiredImportItem(id: "pending", name: "DSCF0002.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([imported, pending])
    state.markImported(itemID: imported.id)
    state.setProofingFavorite(true, itemID: imported.id)
    state.setProofingFavorite(true, itemID: pending.id)

    XCTAssertEqual(state.proofingFavoriteItemIDs, ["pending", "saved"])
    XCTAssertTrue(state.selectedItemIDs.isEmpty)

    state.filterState = WiredCameraImportFilterState(importedStatus: .proofingFavorite)
    XCTAssertEqual(state.filteredItems().map(\.id), ["saved", "pending"])

    state.setProofingFavorite(false, itemID: imported.id)
    XCTAssertEqual(state.proofingFavoriteItemIDs, ["pending"])
  }

  func testWiredCameraImportCacheSnapshotRoundTripsWithoutThumbnails() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = WiredCameraImportCacheStore(rootDirectory: tempDirectory)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }
    var item = wiredImportItem(id: "1", name: "DSCF0001.JPG")
    item.thumbnail = image
    let snapshot = WiredCameraImportCacheSnapshot(
      device: WiredCameraImportDevice(id: "camera/1", name: "X-T5", transportName: "USB"),
      items: [item],
      importedItemIDs: ["1"],
      cachedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    try store.save(snapshot)
    let restored = try store.load(deviceID: "camera/1")

    XCTAssertEqual(restored?.device.id, "camera/1")
    XCTAssertEqual(restored?.items.map(\.id), ["1"])
    XCTAssertNil(restored?.items.first?.thumbnail)
    XCTAssertEqual(restored?.importedItemIDs, ["1"])
  }

  func testWiredCameraImportStateDisablesSelectionBeforeLiveCatalogIsReady() {
    let item = wiredImportItem(id: "1", name: "DSCF0001.JPG")

    var state = WiredCameraImportState()
    state.replaceItems([item], isLiveCatalog: false)
    state.toggleSelection(for: item)

    XCTAssertTrue(state.selectedItemIDs.isEmpty)
    XCTAssertTrue(state.selectedImportableItems.isEmpty)
  }

  func testWiredCameraDownloadResolutionPolicyHandlesFileURLs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let downloaded = directory.appendingPathComponent("DSCF0001.JPG")
    FileManager.default.createFile(atPath: downloaded.path, contents: Data([1, 2, 3]))

    let resolved = WiredCameraDownloadResolutionPolicy.resolvedURL(
      savedFilename: downloaded.absoluteString,
      requestedFilename: "fallback.JPG",
      directory: directory
    )

    XCTAssertEqual(resolved, downloaded)
  }

  func testWiredCameraAutoImportPolicyRequiresExplicitOptIn() {
    let importable = wiredImportItem(id: "new", name: "DSCF0001.JPG")
    let imported = wiredImportItem(id: "saved", name: "DSCF0002.JPG")
    let unsupported = wiredImportItem(id: "txt", name: "README.TXT", uti: "public.text", isImportable: false)

    var state = WiredCameraImportState()
    state.replaceItems([importable, imported, unsupported], isLiveCatalog: true)
    state.importedItemIDs = ["saved"]

    XCTAssertTrue(WiredCameraAutoImportPolicy.itemsToImport(from: state).isEmpty)
    XCTAssertEqual(WiredCameraAutoImportPolicy.itemsToImport(from: state, isEnabled: true), [importable])

    state.replaceItems([importable], isLiveCatalog: false)
    XCTAssertTrue(WiredCameraAutoImportPolicy.itemsToImport(from: state, isEnabled: true).isEmpty)
  }

  func testWiredCameraImportNavigationPolicyBlocksLeavingWhileImporting() {
    XCTAssertFalse(WiredCameraImportNavigationPolicy.canLeaveImportScreen(isImporting: true))
    XCTAssertTrue(WiredCameraImportNavigationPolicy.canLeaveImportScreen(isImporting: false))
  }

  func testWiredCameraImportNavigationPolicyKeepsImportingOnFilterGrid() {
    XCTAssertFalse(WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: true))
    XCTAssertTrue(WiredCameraImportNavigationPolicy.canOpenPreview(isImporting: false))
  }

  func testNativePhotoPreviewRotationPolicyCyclesManualRotation() {
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(0), 90)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(90), 180)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(180), 270)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(270), 0)
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.nextManualRotationDegrees(-90), 0)
  }

  func testNativePhotoPreviewRotationPolicySwapsDisplaySizeForQuarterTurns() {
    let size = CGSize(width: 160, height: 120)

    XCTAssertEqual(NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 0), size)
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 90),
      CGSize(width: 120, height: 160)
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 270),
      CGSize(width: 120, height: 160)
    )
    XCTAssertEqual(NativePhotoPreviewRotationPolicy.displaySize(for: size, manualRotationDegrees: 180), size)
  }

  func testNativePhotoPreviewRotationPolicyUsesCameraVendorOrientationBeforeDimensionFallback() {
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 2,
        decodedWidth: 160,
        decodedHeight: 120,
        imageData: nil
      ),
      90
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 4,
        decodedWidth: 640,
        decodedHeight: 480,
        imageData: nil
      ),
      270
    )
  }

  func testNativePhotoPreviewRotationPolicyDoesNotDoubleRotateAlreadyAppliedObjectOrientationLikeAndroid() {
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 2,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: nil
      ),
      0
    )
    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: 4,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: nil
      ),
      0
    )
  }

  func testNativePhotoPreviewRotationPolicyFallsBackToJpegExifOrientation() throws {
    let data = try jpegDataWithExifOrientation(.right)

    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: nil,
        decodedWidth: 160,
        decodedHeight: 120,
        imageData: data
      ),
      90
    )
  }

  func testNativePhotoPreviewRotationPolicyDoesNotDoubleRotateAlreadyAppliedExifLikeAndroid() throws {
    let data = try jpegDataWithExifOrientation(.right)

    XCTAssertEqual(
      NativePhotoPreviewRotationPolicy.autoRotationDegrees(
        objectOrientation: nil,
        decodedWidth: 120,
        decodedHeight: 160,
        imageData: data
      ),
      0
    )
  }

  func testGalleryThumbnailRendererKeepsPixelsVisibleAfterObjectOrientationRotation() throws {
    let data = try jpegData(
      size: CGSize(width: 24, height: 12),
      fill: UIColor.red
    )

    let image = try XCTUnwrap(CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: 2))

    XCTAssertLessThan(image.size.width, image.size.height)
    XCTAssertGreaterThan(try dominantRedValue(in: image), 180)
  }

  func testGalleryThumbnailRendererUsesCameraVendorOrientationForPortraitDisplay() throws {
    let data = try jpegData(
      size: CGSize(width: 24, height: 12),
      fill: UIColor.red
    )

    let image = try XCTUnwrap(CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: 2))

    XCTAssertEqual(image.imageOrientation, .up)
    XCTAssertLessThan(image.size.width, image.size.height)
  }

  func testGalleryThumbnailRendererDoesNotDoubleRotateExifOrientedImageWhenPtpOrientationIsPresent() throws {
    let data = try jpegDataWithExifOrientation(.right)

    let image = try XCTUnwrap(CameraVendorGalleryThumbnailRenderer.decoded(from: data, objectOrientation: 2))

    XCTAssertEqual(image.imageOrientation, .up)
    XCTAssertLessThan(image.size.width, image.size.height)
  }

  func testLateObjectOrientationInvalidatesOnlyAffectedThumbnailDecode() {
    let existing = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:12 10:00:00",
      byteSizeText: "1 MB",
      orientation: nil,
      thumbnailData: Data([0xFF, 0xD8, 0xFF])
    )
    let orientationResolved = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:12 10:00:00",
      byteSizeText: "1 MB",
      orientation: 2
    )
    let unchanged = CameraVendorGalleryItem(
      handle: 8,
      filename: "DSCF0008.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:12 10:01:00",
      byteSizeText: "1 MB",
      orientation: nil
    )

    XCTAssertEqual(
      NativeGalleryOrientationRefreshPolicy.handlesNeedingThumbnailReDecode(
        existingItems: [existing, unchanged],
        resolvedItems: [orientationResolved, unchanged]
      ),
      Set([7])
    )
  }

  func testLateObjectOrientationRerendersPreviewFromAlreadyLoadedBytes() {
    XCTAssertTrue(
      NativePhotoPreviewOrientationRefreshPolicy.shouldRerender(
        previousObjectOrientation: nil,
        updatedObjectOrientation: 4,
        hasLoadedImageData: true
      )
    )
    XCTAssertFalse(
      NativePhotoPreviewOrientationRefreshPolicy.shouldRerender(
        previousObjectOrientation: 4,
        updatedObjectOrientation: 4,
        hasLoadedImageData: true
      )
    )
    XCTAssertFalse(
      NativePhotoPreviewOrientationRefreshPolicy.shouldRerender(
        previousObjectOrientation: nil,
        updatedObjectOrientation: 4,
        hasLoadedImageData: false
      )
    )
  }

  func testNativePhotoPreviewInitialImagePolicyUsesGridCachedThumbnailWhenItemDataIsMissing() {
    let cached = UIImage()
    let item = CameraVendorGalleryItem(
      handle: 11,
      filename: "DSCF0011.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:27 16:35:00",
      byteSizeText: "4 MB",
      thumbnailData: nil
    )

    XCTAssertTrue(NativePhotoPreviewInitialImagePolicy.initialImage(item: item, cachedThumbnailImage: cached) === cached)
  }

  func testNativeGalleryPreviewImageLoadPolicySupportsJpegHeifAndRawOnly() {
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(
        handle: 5,
        filename: "0x00000005",
        formatLabel: "",
        captureDate: "",
        byteSizeText: "",
        formatHints: [.heif]
      ),
      hasPreviewImage: false
    ))
    XCTAssertTrue(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "", byteSizeText: ""),
      hasPreviewImage: false
    ))
    XCTAssertFalse(NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
      item: CameraVendorGalleryItem(handle: 4, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: ""),
      hasPreviewImage: true
    ))
  }

  func testNativeGalleryHighDefinitionPreviewModeQueuesFromCurrentHandleLikeAndroid() {
    let controller = NativeGalleryHighDefinitionPreviewModeController()

    controller.begin(
      orderedHandles: [1, 2, 3, 4],
      currentHandle: 3,
      alreadyLoadedHandles: [4]
    )

    XCTAssertTrue(controller.isActive)
    XCTAssertEqual(controller.pendingHandles, [3, 1, 2])

    controller.markLoaded(3)
    XCTAssertEqual(controller.pendingHandles, [1, 2])

    controller.promoteCurrentHandle(2, alreadyLoadedHandles: [3, 4])
    XCTAssertEqual(controller.pendingHandles, [2, 1])
  }

  func testInitialCatalogMarksExpandedOnlyHandlesAsAndroidExtendedStillCandidates() {
    let hints = CameraVendorCatalogPlaceholderPolicy.expandedStillFormatHints(
      baselineHandles: [100, 101, 102],
      expandedStillHandles: [100, 101, 102, 103, 104]
    )

    XCTAssertNil(hints[100])
    XCTAssertEqual(hints[103], [.extendedStillCandidate])
    XCTAssertEqual(hints[104], [.extendedStillCandidate])
  }

  func testNativeGalleryHDProjectionPreservesSharedSectionsAndRepresentsEveryHandle() throws {
    let firstDay = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 24)
    ))
    let secondDay = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 23)
    ))
    let jpg = CameraVendorGalleryItem(
      handle: 102,
      filename: "DSCF0102.JPG",
      formatLabel: "JPG",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )
    let raw = CameraVendorGalleryItem(
      handle: 101,
      filename: "DSCF0102.RAF",
      formatLabel: "RAW",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )
    let rawOnly = CameraVendorGalleryItem(
      handle: 90,
      filename: "DSCF0090.RAF",
      formatLabel: "RAW",
      captureDate: "20260723T120000",
      byteSizeText: ""
    )
    let sharedSections = [
      NativeGalleryDaySection(day: firstDay, title: "7月24日 2 张", items: [jpg, raw]),
      NativeGalleryDaySection(day: secondDay, title: "7月23日 1 张", items: [rawOnly]),
    ]

    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: sharedSections)

    XCTAssertEqual(snapshot.sections.map(\.title), sharedSections.map(\.title))
    XCTAssertEqual(snapshot.sections.map(\.day), sharedSections.map(\.day))
    XCTAssertEqual(snapshot.sections[0].items.map(\.displayItem.handle), [102])
    XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.handle, 101)
    XCTAssertEqual(snapshot.sections[1].items.map(\.displayItem.handle), [90])
    XCTAssertEqual(snapshot.orderedRepresentedHandles, [102, 101, 90])
    XCTAssertEqual(snapshot.allRepresentedHandles, Set([102, 101, 90]))
    XCTAssertEqual(snapshot.loadableDisplayHandles, [102, 90])
  }

  @MainActor
  func testFormatSpecificCatalogPlaceholdersCarryRequestedFormatHints() async throws {
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [
      CameraVendorGalleryItem(
        handle: 7,
        filename: "0x00000007",
        formatLabel: "",
        captureDate: "20260802",
        byteSizeText: ""
      ),
    ]
    let source = CameraSessionGalleryCatalogRuntimeSource(transport: transport)

    let jpg = try await source.loadExactCatalog(for: .jpg)
    let raw = try await source.loadExactCatalog(for: .raw)
    let heif = try await source.loadSubtractBaselineCatalog(for: .heif)

    XCTAssertEqual(jpg.items.first?.formatHints, [.jpg])
    XCTAssertEqual(raw.items.first?.formatHints, [.raw])
    XCTAssertEqual(heif.items.first?.formatHints, [.heif])
  }

  func testNativeGalleryHDProjectionNeverPairsRawAcrossDateSections() throws {
    let firstDay = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 24)
    ))
    let secondDay = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 23)
    ))
    let jpg = CameraVendorGalleryItem(
      handle: 102,
      filename: "DSCF0102.JPG",
      formatLabel: "JPG",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )
    let sameStemRawOnAnotherDay = CameraVendorGalleryItem(
      handle: 101,
      filename: "DSCF0102.RAF",
      formatLabel: "RAW",
      captureDate: "20260723T120000",
      byteSizeText: ""
    )

    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
      NativeGalleryDaySection(day: firstDay, title: "7月24日 1 张", items: [jpg]),
      NativeGalleryDaySection(day: secondDay, title: "7月23日 1 张", items: [sameStemRawOnAnotherDay]),
    ])

    XCTAssertNil(snapshot.sections[0].items.first?.rawSidecar)
    XCTAssertEqual(snapshot.sections[1].items.first?.displayItem.handle, 101)
    XCTAssertEqual(snapshot.allRepresentedHandles, Set([102, 101]))
  }

  func testNativeGalleryHDProjectionDoesNotAttachUnmatchedRawInsideOneSection() throws {
    let day = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 24)
    ))
    let jpg = CameraVendorGalleryItem(
      handle: 102,
      filename: "DSCF0102.JPG",
      formatLabel: "JPG",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )
    let unrelatedRaw = CameraVendorGalleryItem(
      handle: 101,
      filename: "DSCF9999.RAF",
      formatLabel: "RAW",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )

    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
      NativeGalleryDaySection(day: day, title: "7月24日 2 张", items: [jpg, unrelatedRaw]),
    ])

    XCTAssertNil(snapshot.sections[0].items[0].rawSidecar)
    XCTAssertEqual(snapshot.sections[0].items[1].displayItem.handle, 101)
    XCTAssertEqual(snapshot.orderedRepresentedHandles, [102, 101])
  }

  func testNativeGalleryHDProjectionPairsExtendedStillPlaceholdersInsideOneSection() throws {
    let day = try XCTUnwrap(Calendar.current.date(
      from: DateComponents(year: 2026, month: 7, day: 11)
    ))
    let rawPlaceholder = CameraVendorGalleryItem(
      handle: 100,
      filename: "0x00000064",
      formatLabel: "",
      captureDate: "20260711",
      byteSizeText: "",
      formatHints: [.extendedStillCandidate]
    )
    let previewPlaceholder = CameraVendorGalleryItem(
      handle: 101,
      filename: "0x00000065",
      formatLabel: "",
      captureDate: "20260711",
      byteSizeText: "",
      formatHints: [.extendedStillCandidate]
    )

    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
      NativeGalleryDaySection(
        day: day,
        title: "7月11日 2 张",
        items: [previewPlaceholder, rawPlaceholder]
      ),
    ])

    XCTAssertEqual(snapshot.sections[0].items.map(\.displayItem.handle), [101])
    XCTAssertEqual(snapshot.sections[0].items.first?.displayItem.formatHints, [.heif])
    XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.handle, 100)
    XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.formatHints, [.raw])
  }

  func testNativeGalleryHDWindowIsVisibleThenBelowThenNearestAboveAndLimitedToThirty() {
    let window = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
      orderedHandles: Array(1...40),
      visibleHandles: [35, 36],
      limit: 30
    )

    XCTAssertEqual(Array(window.prefix(2)), [35, 36])
    XCTAssertEqual(Array(window.dropFirst(2).prefix(4)), [37, 38, 39, 40])
    XCTAssertEqual(Array(window.dropFirst(6).prefix(4)), [34, 33, 32, 31])
    XCTAssertEqual(window.count, 30)
    XCTAssertEqual(Set(window).count, 30)
  }

  func testNativeGalleryHDWindowCrossesDateSectionsWithoutResetting() {
    let snapshot = NativeGalleryHDPreviewSnapshot.fixture(
      sectionHandles: [[1, 2], [3, 4]]
    )

    let window = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
      orderedHandles: snapshot.loadableDisplayHandles,
      visibleHandles: [2],
      limit: 30
    )

    XCTAssertEqual(snapshot.loadableDisplayHandles, [1, 2, 3, 4])
    XCTAssertEqual(window, [2, 3, 4, 1])
  }

  func testNativeGalleryHDFullScreenPriorityUsesCurrentNextPrevious() {
    XCTAssertEqual(
      NativeGalleryHDPreviewSessionPolicy.fullScreenPriority(
        orderedHandles: [10, 20, 30, 40],
        currentHandle: 30
      ),
      [30, 40, 20]
    )
    XCTAssertEqual(
      NativeGalleryHDPreviewSessionPolicy.fullScreenPriority(
        orderedHandles: [10, 20, 30, 40],
        currentHandle: 10
      ),
      [10, 20]
    )
    XCTAssertEqual(
      NativeGalleryHDPreviewSessionPolicy.fullScreenPriority(
        orderedHandles: [10, 20, 30, 40],
        currentHandle: 40
      ),
      [40, 30]
    )
  }

  func testNativeGalleryHDPreviewAdvancesPriorityWindowWhileScrolling() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let methodStart = try XCTUnwrap(
      source.range(of: "func scrollViewDidScroll(_ scrollView: UIScrollView)")?.lowerBound
    )
    let methodEnd = try XCTUnwrap(
      source.range(of: "\n  }", range: methodStart..<source.endIndex)?.upperBound
    )
    let body = String(source[methodStart..<methodEnd])

    XCTAssertTrue(body.contains("scrollView === hdCollectionView"))
    XCTAssertTrue(body.contains("runtime.updateGalleryHDPreviewVisibleHandles(visibleHandles)"))
  }

  func testNativeGalleryHDPreviewDecodesOffMainThreadWithoutGlobalLayoutInvalidation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let applyStart = try XCTUnwrap(source.range(of: "private func applyHDPreviewState")?.lowerBound)
    let applyEnd = try XCTUnwrap(
      source.range(of: "\n  private func refreshHDCell", range: applyStart..<source.endIndex)?.lowerBound
    )
    let applyBody = String(source[applyStart..<applyEnd])
    XCTAssertFalse(applyBody.contains("invalidateLayout()"))

    let loadStart = try XCTUnwrap(source.range(of: "private func hdLoadState")?.lowerBound)
    let loadEnd = try XCTUnwrap(
      source.range(of: "\n  private func configureHDCell", range: loadStart..<source.endIndex)?.lowerBound
    )
    let loadBody = String(source[loadStart..<loadEnd])
    XCTAssertFalse(loadBody.contains("CameraVendorGalleryThumbnailRenderer.decoded"))
    let decodeStart = try XCTUnwrap(
      source.range(of: "private func scheduleHDPreviewDecode(for handle: Int)")?.lowerBound
    )
    let decodeEnd = try XCTUnwrap(
      source.range(of: "\n  private func", range: source.index(after: decodeStart)..<source.endIndex)?.lowerBound
    )
    let decodeBody = String(source[decodeStart..<decodeEnd])
    XCTAssertTrue(decodeBody.contains("NativeGalleryHDTargetDecoder.decodedImage"))
    XCTAssertTrue(decodeBody.contains("target: target"))
    XCTAssertFalse(decodeBody.contains("UIImage(data:"))

    let decoderURL = sourceURL
      .deletingLastPathComponent()
      .appendingPathComponent("NativeGalleryHDTargetDecoder.swift")
    let decoderSource = try String(contentsOf: decoderURL, encoding: .utf8)
    XCTAssertTrue(decoderSource.contains("CGImageSourceCreateThumbnailAtIndex"))
    XCTAssertTrue(decoderSource.contains("kCGImageSourceThumbnailMaxPixelSize"))
    XCTAssertTrue(decoderSource.contains("maxConcurrentOperationCount = maxConcurrentDecodeCount"))

    let sizeStart = try XCTUnwrap(
      source.range(of: "func collectionView(\n    _ collectionView: UICollectionView,\n    layout collectionViewLayout: UICollectionViewLayout,\n    sizeForItemAt indexPath: IndexPath")?.lowerBound
    )
    let sizeEnd = try XCTUnwrap(
      source.range(
        of: "\n  func collectionView(\n    _ collectionView: UICollectionView,\n    layout collectionViewLayout: UICollectionViewLayout,\n    insetForSectionAt section: Int",
        range: sizeStart..<source.endIndex
      )?.lowerBound
    )
    let sizeBody = String(source[sizeStart..<sizeEnd])
    XCTAssertFalse(sizeBody.contains("UIImage(data:"))
  }

  func testNativeGalleryHDTargetDecodeSizingBoundsVerticalAndFullScreenPixels() {
    XCTAssertEqual(
      NativeGalleryHDDecodeSizingPolicy.verticalCardMaxPixelSize(
        renderedWidth: 390,
        displayScale: 3
      ),
      1404
    )
    XCTAssertEqual(
      NativeGalleryHDDecodeSizingPolicy.fullScreenFitMaxPixelSize(
        viewport: CGSize(width: 390, height: 844),
        displayScale: 3
      ),
      2532
    )
    XCTAssertEqual(NativeGalleryHDTargetDecoder.maxConcurrentDecodeCount, 2)
  }

  func testHDFullScreenDecodeUsesFitBeforeNativeAndDowngradesAdjacentPages() {
    let viewport = CGSize(width: 390, height: 844)
    let fit = NativeGalleryHDDecodeTarget.fullScreenFit(maxPixelSize: 2532)

    XCTAssertEqual(
      NativeGalleryHDFullScreenDecodePolicy.nextTarget(
        isDisplayedPage: true,
        renderedTarget: nil,
        viewport: viewport,
        displayScale: 3,
        allowsNativeDecode: true
      ),
      fit
    )
    XCTAssertEqual(
      NativeGalleryHDFullScreenDecodePolicy.nextTarget(
        isDisplayedPage: true,
        renderedTarget: fit,
        viewport: viewport,
        displayScale: 3,
        allowsNativeDecode: true
      ),
      .fullScreenNative
    )
    XCTAssertEqual(
      NativeGalleryHDFullScreenDecodePolicy.nextTarget(
        isDisplayedPage: false,
        renderedTarget: .fullScreenNative,
        viewport: viewport,
        displayScale: 3,
        allowsNativeDecode: true
      ),
      fit
    )
    XCTAssertNil(
      NativeGalleryHDFullScreenDecodePolicy.nextTarget(
        isDisplayedPage: true,
        renderedTarget: fit,
        viewport: viewport,
        displayScale: 3,
        allowsNativeDecode: false
      )
    )
  }

  func testHDDecodeCancellationTokenSkipsQueuedStaleDecodeWork() {
    let token = NativeGalleryHDDecodeCancellationToken()
    var didDecode = false
    token.cancel()

    let result = token.performIfActive {
      didDecode = true
      return 1
    }

    XCTAssertNil(result)
    XCTAssertFalse(didDecode)
  }

  func testNativeGalleryHDCoordinatorCountsOnlySnapshotLoadedHandles() {
    let snapshot = NativeGalleryHDPreviewSnapshot.fixture(handles: [1, 2])
    let state = NativeGalleryHDPreviewState(snapshot: snapshot, loadedHandles: [1, 99])

    XCTAssertEqual(state.loadedCount, 1)
    XCTAssertEqual(state.totalCount, 2)
  }

  func testNativeGalleryHDCoordinatorKeepsRawOnlyPendingUntilPreviewLoads() {
    let raw = CameraVendorGalleryItem(
      handle: 90,
      filename: "DSCF0090.RAF",
      formatLabel: "RAW",
      captureDate: "20260723T120000",
      byteSizeText: "",
      formatHints: [.raw]
    )
    let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
      NativeGalleryDaySection(day: nil, title: "RAW", items: [raw]),
    ])
    let state = NativeGalleryHDPreviewState(snapshot: snapshot, loadedHandles: [])

    XCTAssertEqual(state.loadedCount, 0)
    XCTAssertEqual(state.totalCount, 1)
  }

  func testNativeGalleryHDCoordinatorCancellationDoesNotMarkHandleFailed() {
    let state = NativeGalleryHDPreviewLoadReducer.reduce(
      state: NativeGalleryHDPreviewLoadState(),
      event: .started(handle: 7)
    )
    let cancelled = NativeGalleryHDPreviewLoadReducer.reduce(state: state, event: .cancelled(handle: 7))

    XCTAssertFalse(cancelled.loadingHandles.contains(7))
    XCTAssertFalse(cancelled.failedHandles.contains(7))
  }

  func testNativeGalleryHDChromeKeepsGalleryBackground() {
    XCTAssertTrue(NativeGalleryHDChromePolicy.usesGalleryBackground)
  }

  func testNativeGalleryHDPreviewFailureLogIncludesHandleAndError() {
    XCTAssertEqual(
      NativeGalleryHDPreviewFailureLogPolicy.message(
        handle: 0x123,
        errorDescription: "preview too large"
      ),
      "[OBS] HD_PREVIEW_IMAGE_FAILED handle=0x00000123 error=preview too large"
    )
  }

  func testCameraSessionRuntimeAcceptsMixedDisplayAndRawDownloadModes() {
    let requests = NativeGalleryHDDownloadRequestPolicy.requests(
      displayItems: [CameraVendorGalleryItem(
        handle: 20,
        filename: "DSCF0020.JPG",
        formatLabel: "JPG",
        captureDate: "",
        byteSizeText: ""
      )],
      rawHandles: [19],
      preferCompressedDisplay: true
    )

    XCTAssertEqual(requests.map(\.handle), [20, 19])
    XCTAssertEqual(requests.map(\.mode), [.compressed, .original])
  }

  func testNativeGalleryHDDownloadRequestsDeduplicateHandles() {
    let display = CameraVendorGalleryItem(
      handle: 20,
      filename: "DSCF0020.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: ""
    )
    let requests = NativeGalleryHDDownloadRequestPolicy.requests(
      displayItems: [display, display],
      rawHandles: [19, 19],
      preferCompressedDisplay: false
    )

    XCTAssertEqual(requests.map(\.handle), [20, 19])
    XCTAssertEqual(requests.map(\.mode), [.original, .original])
  }

  func testNativeGalleryHDRawOnlyDisplayAlwaysDownloadsOriginal() {
    let requests = NativeGalleryHDDownloadRequestPolicy.requests(
      displayItems: [CameraVendorGalleryItem(
        handle: 20,
        filename: "DSCF0020.RAF",
        formatLabel: "RAW",
        captureDate: "",
        byteSizeText: "",
        formatHints: [.raw]
      )],
      rawHandles: [],
      preferCompressedDisplay: true
    )

    XCTAssertEqual(requests.map(\.handle), [20])
    XCTAssertEqual(requests.map(\.mode), [.original])
  }

  func testNativeGalleryAndroidParityChromeUsesOneToolRow() {
    XCTAssertEqual(NativeGalleryAndroidParityChromePolicy.toolRowHeight, 42)
    XCTAssertEqual(NativeGalleryAndroidParityChromePolicy.toolSurfaceCount, 3)
    XCTAssertFalse(NativeGalleryAndroidParityChromePolicy.usesSeparateModeRow)
  }

  func testNativeGalleryToolRowMatchesApprovedAndroidReferenceChrome() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("final class NativeGalleryModeControl: UIControl"))
    XCTAssertTrue(source.contains("circle.grid.2x2.fill"))
    XCTAssertTrue(source.contains("title: \"高清\""))
    XCTAssertTrue(source.contains("selectedBackgroundColor = NativeLuxuryTheme.ink"))
    XCTAssertTrue(source.contains("systemName: \"slider.horizontal.3\""))
    XCTAssertTrue(source.contains("systemName: \"square.stack.3d.up\""))
    XCTAssertTrue(source.contains("configuration.baseBackgroundColor = .clear"))
    XCTAssertTrue(source.contains("galleryFilterButton.widthAnchor.constraint(equalToConstant: 74)"))
    XCTAssertTrue(source.contains("browseModeControl.heightAnchor.constraint(equalToConstant: 38)"))
    XCTAssertTrue(source.contains("galleryToolsButton.widthAnchor.constraint(equalToConstant: 74)"))
    XCTAssertTrue(source.contains("UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)"))
    XCTAssertTrue(source.contains("UIFont.systemFont(ofSize: 14, weight: .black)"))
    XCTAssertTrue(source.contains("UIFont.systemFont(ofSize: 15, weight: .semibold)"))
    XCTAssertTrue(source.contains("galleryHeaderCountLabel"))
    XCTAssertTrue(source.contains("galleryHeaderTitleStack"))
  }

  func testNativeGallerySectionHeaderMatchesApprovedDateCountAndActionLayout() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("private let countLabel: UILabel"))
    XCTAssertTrue(source.contains("private let sortButton: UIButton"))
    XCTAssertTrue(source.contains("dateTitle: String"))
    XCTAssertTrue(source.contains("countTitle: String"))
    XCTAssertTrue(source.contains("sortTitle: String"))
    XCTAssertTrue(source.contains("header.onSortTapped"))
    XCTAssertTrue(source.contains("UIFont.systemFont(ofSize: 15, weight: .black)"))
    XCTAssertTrue(source.contains("UIFont.systemFont(ofSize: 13, weight: .medium)"))
    XCTAssertTrue(source.contains("selectionButton.heightAnchor.constraint(equalToConstant: 28)"))
    XCTAssertTrue(source.contains("sortButton.heightAnchor.constraint(equalToConstant: 28)"))
  }

  func testNativeGalleryFilterPanelCanExpandInBothBrowseModes() {
    XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.showsFilterSurface(mode: .thumbnail))
    XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.showsFilterSurface(mode: .highDefinition))
    XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.canExpandFilters(mode: .thumbnail))
    XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.canExpandFilters(mode: .highDefinition))
  }

  func testNativeGalleryHDModeHasNoIndependentDateOwnerOrPicker() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("hdActiveDate"))
    XCTAssertFalse(source.contains("hdDateButton"))
    XCTAssertFalse(source.contains("selectHDDateTapped"))
    XCTAssertFalse(source.contains("preferredHDActiveDate"))
    XCTAssertTrue(source.contains("NativeGalleryHDPreviewSessionPolicy.snapshot(\n      sections: gallerySections"))
  }

  func testNativeGalleryHDCollectionUsesSnapshotSectionsAndSharedHeaders() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("hdPresentationState?.snapshot.sections.count"))
    XCTAssertTrue(source.contains("snapshot.item(at: indexPath)"))
    XCTAssertTrue(source.contains("configureGalleryHeader(header, at: indexPath)"))
    XCTAssertTrue(source.contains("guard catalogIdentity == self.runtime.galleryCatalogIdentity else { return }"))
    XCTAssertTrue(source.contains("guard mediaIdentity.catalog == self.runtime.galleryCatalogIdentity else { return }"))
    XCTAssertFalse(source.contains("if collectionView === hdCollectionView { return 1 }"))
    XCTAssertFalse(source.contains("browseMode != .thumbnail || !NativeGalleryEmptyStatePolicy.shouldShow"))
  }

  func testNativeGalleryUsesOneFilterSubmissionIndependentOfBrowseMode() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let switchStart = try XCTUnwrap(
      source.range(of: "private func switchBrowseMode(_ mode: NativeGalleryBrowseMode)")?.lowerBound
    )
    let switchEnd = try XCTUnwrap(
      source.range(of: "private func startHDPreviewLoading()", range: switchStart..<source.endIndex)?.lowerBound
    )
    let switchBody = String(source[switchStart..<switchEnd])

    XCTAssertEqual(source.components(separatedBy: "private var filterState").count - 1, 1)
    XCTAssertFalse(switchBody.contains("submitGalleryIntent()"))
    XCTAssertTrue(source.contains("rule: filterState.rule"))
    XCTAssertTrue(source.contains("sort: filterState.sortIntent"))
    XCTAssertTrue(source.contains("NativeGalleryHDPreviewSessionPolicy.snapshot(\n      sections: gallerySections"))
  }

  func testCameraGallerySessionFullScreenPreviewSuspendsBothContentLoaders() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGallerySession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("func suspendContentWorkForFullScreenPreview() async"))
    XCTAssertTrue(source.contains("await hdPreviewPipeline.suspend()"))
    XCTAssertTrue(source.contains("await catalogRuntime.suspendChildWorkForHighDefinitionPreview()"))
    XCTAssertTrue(source.contains("func resumeContentWorkAfterFullScreenPreview() async"))
    XCTAssertTrue(source.contains("await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()"))
    XCTAssertTrue(source.contains("hdPreviewPipeline.resume()"))
  }

  func testNativePhotoPreviewOnlyLoadsHighDefinitionForDisplayedPage() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativePhotoPreviewViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("private var isDisplayedPage = false"))
    XCTAssertTrue(source.contains("func setDisplayedPage(_ isDisplayed: Bool)"))
    XCTAssertTrue(source.contains("guard isDisplayedPage else { return }"))
    XCTAssertTrue(source.contains("initialPage.setDisplayedPage(true)"))
    XCTAssertTrue(source.contains("previousViewControllers.forEach"))
    XCTAssertTrue(source.contains("page.setDisplayedPage(true)"))
  }

  func testThumbnailFullScreenUsesReadOnlyHDCacheAndReturnsSettledHandle() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativePhotoPreviewViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let controllerStart = try XCTUnwrap(
      source.range(of: "final class NativePhotoPreviewViewController")?.lowerBound
    )
    let pageStart = try XCTUnwrap(
      source.range(of: "final class NativePhotoPreviewPageController", range: controllerStart..<source.endIndex)?.lowerBound
    )
    let controllerBody = String(source[controllerStart..<pageStart])

    XCTAssertTrue(controllerBody.contains("readOnlyLoadedPreview"))
    XCTAssertFalse(controllerBody.contains("restoreLoadedPreview"))
    XCTAssertFalse(controllerBody.contains("previewImageCache.store"))
    XCTAssertTrue(controllerBody.contains("onPreviewClosed(items[currentIndex].handle, previewCatalogIdentity)"))
    let transitionStart = try XCTUnwrap(
      controllerBody.range(of: "willTransitionTo pendingViewControllers")?.lowerBound
    )
    let transitionEnd = try XCTUnwrap(
      controllerBody.range(of: "didFinishAnimating finished", range: transitionStart..<controllerBody.endIndex)?.lowerBound
    )
    XCTAssertFalse(String(controllerBody[transitionStart..<transitionEnd]).contains("currentIndex = page.index"))
  }

  func testLinkedHDFullScreenUsesExistingPipelineAndNeverFetchesPTPDirectly() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let controller = try String(
      contentsOf: root.appendingPathComponent("Runner/NativeGalleryHDFullScreenViewController.swift"),
      encoding: .utf8
    )
    let gallery = try String(
      contentsOf: root.appendingPathComponent("Runner/NativeGalleryViewController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(controller.contains("runtime.focusGalleryHDFullScreen(handle: currentHandle)"))
    XCTAssertTrue(controller.contains("runtime.observeGalleryPreview"))
    XCTAssertFalse(controller.contains("requestPreviewImageWithInfo"))
    XCTAssertFalse(controller.contains("fetchPreviewImageWithInfo"))
    XCTAssertTrue(controller.contains("onClosed(currentHandle, context.catalogIdentity)"))
    XCTAssertTrue(gallery.contains("case .highDefinition:"))
    XCTAssertTrue(gallery.contains("NativeGalleryHDFullScreenViewController"))
  }

  func testHDFullScreenReturnPositionRequiresMatchingCatalogAndCurrentHandle() {
    let openingCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let replacementCatalog = CameraGalleryCatalogIdentity.fixture(generation: 2)
    let snapshot = NativeGalleryHDPreviewSnapshot.fixture(handles: [10, 20, 30])

    XCTAssertEqual(
      NativeGalleryHDFullScreenReturnPolicy.indexPath(
        handle: 20,
        openingCatalogIdentity: openingCatalog,
        currentCatalogIdentity: openingCatalog,
        snapshot: snapshot
      ),
      IndexPath(item: 1, section: 0)
    )
    XCTAssertNil(
      NativeGalleryHDFullScreenReturnPolicy.indexPath(
        handle: 20,
        openingCatalogIdentity: openingCatalog,
        currentCatalogIdentity: replacementCatalog,
        snapshot: snapshot
      )
    )
    XCTAssertNil(
      NativeGalleryHDFullScreenReturnPolicy.indexPath(
        handle: 99,
        openingCatalogIdentity: openingCatalog,
        currentCatalogIdentity: openingCatalog,
        snapshot: snapshot
      )
    )
  }

  func testFullScreenPreviewUsesCatalogIdentityBoundRequestAndBalancedAdmission() throws {
    let runtimeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionRuntime.swift")
    let galleryURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let runtimeSource = try String(contentsOf: runtimeURL, encoding: .utf8)
    let gallerySource = try String(contentsOf: galleryURL, encoding: .utf8)

    XCTAssertTrue(runtimeSource.contains("func requestPreviewImageWithInfo(\n    for identity: CameraGalleryMediaIdentity"))
    XCTAssertTrue(runtimeSource.contains("guard identity.variant == .hdPreview"))
    XCTAssertTrue(runtimeSource.contains("galleryCatalogIdentity == identity.catalog"))
    XCTAssertTrue(gallerySource.contains("await self.runtime.suspendGalleryContentWorkForFullScreenPreview()"))
    XCTAssertTrue(gallerySource.contains("await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()"))
    XCTAssertTrue(gallerySource.contains("scheduleVisibleThumbnailRefresh(after: 0)"))
  }

  func testCameraGallerySessionStopsOldHDWorkBeforeSubmittingAnotherFilter() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGallerySession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let submitStart = try XCTUnwrap(
      source.range(of: "func submitFilter(_ intent: CameraGalleryFilterIntent) async")?.lowerBound
    )
    let submitEnd = try XCTUnwrap(
      source.range(of: "\n  }", range: submitStart..<source.endIndex)?.upperBound
    )
    let submitBody = String(source[submitStart..<submitEnd])

    let hdCancel = try XCTUnwrap(submitBody.range(of: "await hdPreviewPipeline.prepareForCatalogChange()"))
    let catalogSubmit = try XCTUnwrap(submitBody.range(of: "await catalogRuntime.submit("))
    XCTAssertLessThan(hdCancel.lowerBound, catalogSubmit.lowerBound)
    XCTAssertTrue(submitBody.contains("pendingCatalogSubmissionID = submissionID"))
    XCTAssertTrue(source.contains("guard !isCatalogSubmissionPending else { return }"))
    XCTAssertTrue(source.contains("submissionID == pendingCatalogSubmissionID"))
    XCTAssertTrue(source.contains("publishSubmissionPresentation:"))
    XCTAssertFalse(source.contains("if !presentation.isLoading {\n      isCatalogSubmissionPending = false"))
  }

  func testSwitchingBackToThumbnailClearsViewportIdentityAndResubmitsVisibleWindow() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let switchStart = try XCTUnwrap(
      source.range(of: "private func switchBrowseMode(_ mode: NativeGalleryBrowseMode)")?.lowerBound
    )
    let switchEnd = try XCTUnwrap(
      source.range(of: "private func startHDPreviewLoading()", range: switchStart..<source.endIndex)?.lowerBound
    )
    let switchBody = String(source[switchStart..<switchEnd])

    XCTAssertTrue(switchBody.contains("await self?.runtime.switchGalleryPreviewMode(.thumbnail)"))
    XCTAssertTrue(switchBody.contains("self?.lastSubmittedThumbnailViewportIdentity = nil"))
    XCTAssertTrue(switchBody.contains("self?.scheduleVisibleThumbnailRefresh(after: 0)"))
  }

  func testNativeGalleryHDCardRequiresLoadedPreviewBeforeQueueing() {
    XCTAssertEqual(
      NativeGalleryHDCardActionPolicy.displayTitle(hasImage: false, state: .idle),
      "加载后加入"
    )
    XCTAssertFalse(NativeGalleryHDCardActionPolicy.canQueue(hasImage: false, state: .idle))
    XCTAssertTrue(NativeGalleryHDCardActionPolicy.canQueue(
      hasImage: false,
      allowsQueueWithoutImage: true,
      state: .idle
    ))
    XCTAssertEqual(
      NativeGalleryHDCardActionPolicy.displayTitle(
        hasImage: false,
        allowsQueueWithoutImage: true,
        state: .idle
      ),
      "加入原片"
    )
    XCTAssertEqual(
      NativeGalleryHDCardActionPolicy.rawTitle(hasImage: true, state: .queued),
      "RAW 已加入"
    )
  }

  func testNativeGalleryHDBottomBarCountsOnlyActiveSnapshotQueuedHandles() {
    let presentation = NativeGalleryHDBottomBarPolicy.presentation(
      snapshotDownloadHandles: [10, 11, 12],
      queuedHandles: [11, 99]
    )

    XCTAssertEqual(presentation.queuedCount, 1)
    XCTAssertEqual(presentation.totalCount, 3)
    XCTAssertEqual(presentation.title, "已加入 1 张")
  }

  func testNativeGalleryThumbnailLayoutMatchesAndroidGridSpacing() {
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.androidGridSpacing, 2)
    XCTAssertEqual(NativeGalleryAndroidParityGridPolicy.horizontalInset, 0)
    XCTAssertEqual(NativeGalleryAndroidParityGridPolicy.sectionHeaderHeight, 40)
  }

  func testNativeGalleryContentUpdatesDoNotReloadWholeCollection() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let observerStart = try XCTUnwrap(
      source.range(of: "runtime.observeIncrementalCatalogUpdates")?.lowerBound
    )
    let observerEnd = try XCTUnwrap(
      source.range(
        of: "NotificationCenter.default.addObserver",
        range: observerStart..<source.endIndex
      )?.lowerBound
    )
    let observerBody = String(source[observerStart..<observerEnd])
    let structuralStart = try XCTUnwrap(observerBody.range(of: "if delta.requiresStructuralRefresh")?.lowerBound)
    let contentStart = try XCTUnwrap(observerBody.range(of: "// Decode new thumbnail data")?.lowerBound)
    let structuralBody = String(observerBody[structuralStart..<contentStart])
    let contentBody = String(observerBody[contentStart...])

    XCTAssertTrue(structuralBody.contains("collectionView.reloadData()"))
    XCTAssertFalse(contentBody.contains("collectionView.reloadData()"))
    XCTAssertTrue(observerBody.contains("refreshVisibleCells"))
  }

  func testNativeGalleryHighDefinitionPreviewCacheEvictsWholeLeastRecentlyUsedEntry() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-lru-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(
      maxEntries: 2,
      directory: directory
    )
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let first = CameraGalleryMediaIdentity(catalog: catalog, handle: 1, variant: .hdPreview)
    let second = CameraGalleryMediaIdentity(catalog: catalog, handle: 2, variant: .hdPreview)
    let third = CameraGalleryMediaIdentity(catalog: catalog, handle: 3, variant: .hdPreview)

    cache.store(Data([1]), for: first, objectOrientation: 2)
    cache.store(Data([2]), for: second, objectOrientation: 4)
    XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.objectOrientation, 2)
    cache.store(Data([3]), for: third, objectOrientation: 6)

    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 3]))
    XCTAssertNil(cache.memoryData(for: second))
    XCTAssertNil(cache.restoreLoadedPreview(for: second))
    XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.data, Data([1]))
    XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.objectOrientation, 2)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
      2
    )
  }

  func testNativeGalleryHighDefinitionPreviewCacheTouchesVisibleLoadedHandlesInPriorityOrder() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-touch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identities = [1, 2, 3].map {
      CameraGalleryMediaIdentity(catalog: catalog, handle: $0, variant: .hdPreview)
    }

    cache.store(Data([1]), for: identities[0])
    cache.store(Data([2]), for: identities[1])
    cache.touchLoadedHandles([2, 1], for: catalog)
    cache.store(Data([3]), for: identities[2])

    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 3]))
    XCTAssertNil(cache.restoreLoadedData(for: identities[1]))
  }

  func testNativeGalleryHighDefinitionPreviewCacheClearsUnusableFilesWhenRecreated() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-recreated-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let firstCache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
    firstCache.store(
      Data([1]),
      for: CameraGalleryMediaIdentity(catalog: firstCatalog, handle: 1, variant: .hdPreview)
    )
    firstCache.store(
      Data([2]),
      for: CameraGalleryMediaIdentity(catalog: firstCatalog, handle: 2, variant: .hdPreview)
    )

    let nextCatalog = CameraGalleryCatalogIdentity.fixture(generation: 2)
    let nextCache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
    nextCache.store(
      Data([3]),
      for: CameraGalleryMediaIdentity(catalog: nextCatalog, handle: 3, variant: .hdPreview)
    )
    nextCache.store(
      Data([4]),
      for: CameraGalleryMediaIdentity(catalog: nextCatalog, handle: 4, variant: .hdPreview)
    )

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
      2
    )
  }

  func testNativeGalleryHighDefinitionPreviewCachePeekDoesNotChangeLRUOrder() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-peek-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identities = [1, 2, 3].map {
      CameraGalleryMediaIdentity(catalog: catalog, handle: $0, variant: .hdPreview)
    }
    cache.store(Data([1]), for: identities[0])
    cache.store(Data([2]), for: identities[1])

    XCTAssertEqual(cache.peekLoadedPreview(for: identities[0])?.data, Data([1]))
    cache.store(Data([3]), for: identities[2])

    XCTAssertNil(cache.restoreLoadedPreview(for: identities[0]))
    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([2, 3]))
  }

  func testNativeGalleryHighDefinitionPreviewCacheReadOnlyDiskHitDoesNotChangeLRUOrder() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-read-only-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identities = [1, 2, 3].map {
      CameraGalleryMediaIdentity(catalog: catalog, handle: $0, variant: .hdPreview)
    }
    cache.store(Data([1]), for: identities[0], objectOrientation: 2)
    cache.store(Data([2]), for: identities[1], objectOrientation: 4)
    cache.releaseMemoryData(for: identities[0])

    XCTAssertEqual(cache.readOnlyLoadedPreview(for: identities[0])?.data, Data([1]))
    XCTAssertEqual(cache.readOnlyLoadedPreview(for: identities[0])?.objectOrientation, 2)
    cache.store(Data([3]), for: identities[2])

    XCTAssertNil(cache.readOnlyLoadedPreview(for: identities[0]))
    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([2, 3]))
  }

  func testNativeGalleryHighDefinitionPreviewCacheDoesNotEvictPinnedFullScreenHandles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-pinned-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 3, directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identities = [1, 2, 3, 4].map {
      CameraGalleryMediaIdentity(catalog: catalog, handle: $0, variant: .hdPreview)
    }
    identities.prefix(3).enumerated().forEach { index, identity in
      cache.store(Data([UInt8(index + 1)]), for: identity)
    }
    cache.setPinnedHandles([1, 2, 3], for: catalog)
    cache.store(Data([4]), for: identities[3])

    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 2, 3]))
    XCTAssertNil(cache.readOnlyLoadedPreview(for: identities[3]))
  }

  func testHDPreviewCacheUsesSessionEpochHandleAndVariantIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-identity-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let firstCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let nextSessionCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let firstIdentity = CameraGalleryMediaIdentity(
      catalog: firstCatalog,
      handle: 7,
      variant: .hdPreview
    )
    let nextSessionIdentity = CameraGalleryMediaIdentity(
      catalog: nextSessionCatalog,
      handle: 7,
      variant: .hdPreview
    )

    cache.store(Data([7]), for: firstIdentity)

    XCTAssertEqual(cache.restoreLoadedData(for: firstIdentity), Data([7]))
    XCTAssertNil(cache.restoreLoadedData(for: nextSessionIdentity))
    XCTAssertNotEqual(
      CameraGalleryMediaCacheKey(mediaIdentity: firstIdentity),
      CameraGalleryMediaCacheKey(mediaIdentity: nextSessionIdentity)
    )
  }

  func testThumbnailAndHDPreviewCachesNeverShareEntries() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-variant-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let hdIdentity = CameraGalleryMediaIdentity(catalog: catalog, handle: 9, variant: .hdPreview)
    let thumbnailIdentity = CameraGalleryMediaIdentity(catalog: catalog, handle: 9, variant: .thumbnail)

    cache.store(Data([9]), for: hdIdentity)

    XCTAssertEqual(cache.restoreLoadedData(for: hdIdentity), Data([9]))
    XCTAssertNil(cache.restoreLoadedData(for: thumbnailIdentity))
    XCTAssertNotEqual(
      CameraGalleryMediaCacheKey(mediaIdentity: hdIdentity),
      CameraGalleryMediaCacheKey(mediaIdentity: thumbnailIdentity)
    )
  }

  @MainActor
  func testHDPreviewRetryInvalidatesLoadedCacheEntryAndRefetches() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-retry-bad-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identity = CameraGalleryMediaIdentity(
      catalog: catalog,
      handle: 7,
      variant: .hdPreview
    )
    cache.store(Data([0]), for: identity)
    var fetchedHandles: [Int] = []
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        return CameraGalleryPreviewResult(data: Data([7]), objectOrientation: 2)
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [7]),
      visibleHandles: [7]
    )
    await pipeline.waitUntilIdle()
    XCTAssertTrue(fetchedHandles.isEmpty)

    pipeline.retry(handle: 7)
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [7])
    XCTAssertEqual(cache.restoreLoadedPreview(for: identity)?.data, Data([7]))
    XCTAssertEqual(cache.restoreLoadedPreview(for: identity)?.objectOrientation, 2)
  }

  @MainActor
  func testHDPreviewPipelineRejectsAnOldCatalogPublication() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-old-publication-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let oldCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let currentCatalog = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: oldCatalog.sessionEpoch,
      generation: 2
    )
    let snapshot = NativeGalleryHDPreviewSnapshot.fixture(handles: [7])
    var firstFetchContinuation: CheckedContinuation<Void, Never>?
    var fetchCount = 0
    var previewPublications: [CameraGalleryMediaIdentity] = []
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchCount += 1
        if fetchCount == 1 {
          await withCheckedContinuation { continuation in
            firstFetchContinuation = continuation
          }
        }
        return CameraGalleryPreviewResult(data: Data([7]), objectOrientation: nil)
      },
      publish: { publication in
        if case .preview(let identity, _) = publication {
          previewPublications.append(identity)
        }
      }
    )

    await pipeline.activate(
      catalogIdentity: oldCatalog,
      snapshot: snapshot,
      visibleHandles: [7]
    )
    for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }
    let installCurrent = Task { @MainActor in
      await pipeline.activate(
        catalogIdentity: currentCatalog,
        snapshot: snapshot,
        visibleHandles: [7]
      )
    }
    for _ in 0..<20 { await Task.yield() }
    firstFetchContinuation?.resume()
    await installCurrent.value
    await pipeline.waitUntilIdle()

    XCTAssertFalse(previewPublications.contains { $0.catalog == oldCatalog })
    XCTAssertEqual(previewPublications.map(\.catalog), [currentCatalog])
  }

  @MainActor
  func testHDPreviewPipelineFinishesInflightRequestThenUsesLatestViewport() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-latest-viewport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    var firstFetchContinuation: CheckedContinuation<Void, Never>?
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        if fetchedHandles.count == 1 {
          await withCheckedContinuation { continuation in
            firstFetchContinuation = continuation
          }
        }
        return CameraGalleryPreviewResult(
          data: Data([UInt8(identity.handle)]),
          objectOrientation: nil
        )
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [1, 2, 3, 4]),
      visibleHandles: [1]
    )
    for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }

    pipeline.updateVisibleHandles([4])
    firstFetchContinuation?.resume()
    for _ in 0..<100 where fetchedHandles.count < 2 { await Task.yield() }
    await pipeline.suspend()

    XCTAssertEqual(Array(fetchedHandles.prefix(2)), [1, 4])
  }

  @MainActor
  func testHDPreviewPipelineSameCatalogSnapshotUpdateStartsNewlyLoadableHandle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-snapshot-refresh-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let unresolvedItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260802",
      byteSizeText: ""
    )
    let resolvedItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.HEIC",
      formatLabel: "HEIF",
      captureDate: "20260802",
      byteSizeText: "4 MB"
    )
    let unresolved = NativeGalleryHDPreviewSnapshot(sections: [
      NativeGalleryHDPreviewSection(
        day: nil,
        title: "8月2日",
        orderedRepresentedHandles: [7],
        items: [NativeGalleryHDPreviewItem(displayItem: unresolvedItem, rawSidecar: nil)]
      ),
    ])
    let resolved = NativeGalleryHDPreviewSnapshot(sections: [
      NativeGalleryHDPreviewSection(
        day: nil,
        title: "8月2日",
        orderedRepresentedHandles: [7],
        items: [NativeGalleryHDPreviewItem(displayItem: resolvedItem, rawSidecar: nil)]
      ),
    ])
    var fetchedHandles: [Int] = []
    var suspendCount = 0
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: { suspendCount += 1 },
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        return CameraGalleryPreviewResult(data: Data([7]), objectOrientation: nil)
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: unresolved,
      visibleHandles: [7]
    )
    await pipeline.waitUntilIdle()
    XCTAssertTrue(fetchedHandles.isEmpty)

    await pipeline.updateSnapshot(
      catalogIdentity: catalog,
      snapshot: resolved
    )
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [7])
    XCTAssertEqual(pipeline.state?.snapshot, resolved)
    XCTAssertEqual(suspendCount, 1)
  }

  @MainActor
  func testHDPreviewPipelineFullScreenFocusUsesCurrentNextPrevious() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-fullscreen-focus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    var firstFetchContinuation: CheckedContinuation<Void, Never>?
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        if fetchedHandles.count == 1 {
          await withCheckedContinuation { continuation in
            firstFetchContinuation = continuation
          }
        }
        return CameraGalleryPreviewResult(
          data: Data([UInt8(identity.handle)]),
          objectOrientation: nil
        )
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [1, 2, 3, 4]),
      visibleHandles: [1]
    )
    for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }
    pipeline.focusFullScreen(on: 3)
    firstFetchContinuation?.resume()
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [1, 3, 4, 2])
    XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 2, 3, 4]))
  }

  @MainActor
  func testHDPreviewPipelineFallsBackToListFocusWhenSnapshotRemovesFullScreenHandle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-fullscreen-refresh-fallback-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        return CameraGalleryPreviewResult(
          data: Data([UInt8(identity.handle)]),
          objectOrientation: nil
        )
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [3]),
      visibleHandles: [1]
    )
    await pipeline.waitUntilIdle()
    pipeline.focusFullScreen(on: 3)

    await pipeline.updateSnapshot(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [1, 2, 4])
    )
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [3, 1, 2, 4])
  }

  @MainActor
  func testHDPreviewPipelineDoesNotStartReplacementWorkerWhileCancellingAndJoining() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-cancel-join-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    var firstFetchContinuation: CheckedContinuation<Void, Never>?
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        if fetchedHandles.count == 1 {
          await withCheckedContinuation { continuation in
            firstFetchContinuation = continuation
          }
        }
        return CameraGalleryPreviewResult(
          data: Data([UInt8(identity.handle)]),
          objectOrientation: nil
        )
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [1, 2]),
      visibleHandles: [1]
    )
    for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }

    let prepare = Task { @MainActor in
      await pipeline.prepareForCatalogChange()
    }
    for _ in 0..<20 { await Task.yield() }
    pipeline.updateVisibleHandles([2])
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(fetchedHandles, [1])
    firstFetchContinuation?.resume()
    await prepare.value
    XCTAssertEqual(fetchedHandles, [1])
  }

  @MainActor
  func testHDPreviewPipelineSerializesCatalogPreparationBeforeNextActivation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-lifecycle-order-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let oldCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let nextCatalog = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: oldCatalog.sessionEpoch,
      generation: 2
    )
    var fetchedHandles: [Int] = []
    var firstFetchContinuation: CheckedContinuation<Void, Never>?
    var publications: [(CameraGalleryCatalogIdentity, Bool)] = []
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        if fetchedHandles.count == 1 {
          await withCheckedContinuation { continuation in
            firstFetchContinuation = continuation
          }
        }
        return CameraGalleryPreviewResult(
          data: Data([UInt8(identity.handle)]),
          objectOrientation: nil
        )
      },
      publish: { publication in
        if case .state(let catalogIdentity, let state) = publication {
          publications.append((catalogIdentity, state != nil))
        }
      }
    )

    await pipeline.activate(
      catalogIdentity: oldCatalog,
      snapshot: .fixture(handles: [1]),
      visibleHandles: [1]
    )
    for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }

    let prepare = Task { @MainActor in
      await pipeline.prepareForCatalogChange()
    }
    for _ in 0..<20 { await Task.yield() }
    let activateNext = Task { @MainActor in
      await pipeline.activate(
        catalogIdentity: nextCatalog,
        snapshot: .fixture(handles: [2]),
        visibleHandles: [2]
      )
    }
    firstFetchContinuation?.resume()
    await prepare.value
    await activateNext.value
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [1, 2])
    XCTAssertEqual(pipeline.state?.snapshot.displayHandles, [2])
    XCTAssertEqual(publications.last?.0, nextCatalog)
    XCTAssertEqual(publications.last?.1, true)
  }

  @MainActor
  func testHDPreviewPipelineKeepsCacheWhenReturningToThumbnailMode() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-mode-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identity = CameraGalleryMediaIdentity(catalog: catalog, handle: 8, variant: .hdPreview)
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { _ in CameraGalleryPreviewResult(data: Data([8]), objectOrientation: nil) },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [8]),
      visibleHandles: [8]
    )
    await pipeline.waitUntilIdle()
    await pipeline.deactivate(resumeThumbnailPipeline: true)

    XCTAssertEqual(cache.restoreLoadedData(for: identity), Data([8]))
  }

  @MainActor
  func testHDPreviewPipelineRepeatedActivationBalancesThumbnailSuspensionOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-balanced-suspension-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var suspendCount = 0
    var resumeCount = 0
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: { suspendCount += 1 },
      resumeThumbnailPipeline: { resumeCount += 1 },
      fetchPreview: { _ in throw CancellationError() },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [8]),
      visibleHandles: [8]
    )
    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [8]),
      visibleHandles: [8]
    )
    await pipeline.deactivate(resumeThumbnailPipeline: true)

    XCTAssertEqual(suspendCount, 1)
    XCTAssertEqual(resumeCount, 1)
  }

  @MainActor
  func testHDPreviewPipelineRepeatedActivationStaysPausedDuringDownload() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-download-suspension-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        return CameraGalleryPreviewResult(data: Data([UInt8(identity.handle)]), objectOrientation: nil)
      },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [8]),
      visibleHandles: [8]
    )
    await pipeline.waitUntilIdle()
    await pipeline.pauseForDownload()
    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [9]),
      visibleHandles: [9]
    )
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(fetchedHandles, [8])

    await pipeline.resumeAfterDownload()
    await pipeline.waitUntilIdle()
    XCTAssertEqual(fetchedHandles, [8, 9])
  }

  @MainActor
  func testHDPreviewPipelineClearsCacheAfterCameraDisconnect() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-disconnect-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let identity = CameraGalleryMediaIdentity(catalog: catalog, handle: 10, variant: .hdPreview)
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { _ in CameraGalleryPreviewResult(data: Data([10]), objectOrientation: nil) },
      publish: { _ in }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [10]),
      visibleHandles: [10]
    )
    await pipeline.waitUntilIdle()
    await pipeline.invalidateSession()

    XCTAssertNil(cache.restoreLoadedData(for: identity))
  }

  func testNativePhotoPreviewImageSourcePolicySkipsCameraFetchWhenPreviewCacheIsLoaded() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: ""
    )

    XCTAssertFalse(
      NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
        item: item,
        hasPreviewImage: false,
        hasLoadedPreviewData: true
      )
    )
    XCTAssertTrue(
      NativePhotoPreviewImageSourcePolicy.shouldFetchPreviewImage(
        item: item,
        hasPreviewImage: false,
        hasLoadedPreviewData: false
      )
    )
  }

  func testWiredCameraImportStateSetsSelectionForDragOnlyWhenLiveImportableUnsaved() {
    let importable = wiredImportItem(id: "new", name: "DSCF0001.JPG")
    let imported = wiredImportItem(id: "saved", name: "DSCF0002.JPG")
    let unsupported = wiredImportItem(id: "txt", name: "README.TXT", uti: "public.text", isImportable: false)

    var state = WiredCameraImportState()
    state.replaceItems([importable, imported, unsupported], isLiveCatalog: true)
    state.markImported(itemID: imported.id)

    state.setSelection(true, for: importable)
    state.setSelection(true, for: imported)
    state.setSelection(true, for: unsupported)

    XCTAssertEqual(state.selectedItemIDs, ["new"])

    state.setSelection(false, for: importable)
    XCTAssertTrue(state.selectedItemIDs.isEmpty)

    state.replaceItems([importable], isLiveCatalog: false)
    state.setSelection(true, for: importable)
    XCTAssertTrue(state.selectedItemIDs.isEmpty)
  }

  func testLocalProofingWebRendererSerializesPhotosWithFavoriteState() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: true
    )

    let data = try LocalProofingWebRenderer.photosJSON(
      photos: [photo],
      favoriteIDs: ["photo-1"]
    )
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let photos = object?["photos"] as? [[String: Any]]

    XCTAssertEqual(photos?.first?["id"] as? String, "photo-1")
    XCTAssertEqual(photos?.first?["favorite"] as? Bool, true)
    XCTAssertEqual(photos?.first?["previewURL"] as? String, "/preview/photo-1.jpg")
  }

  func testLocalProofingGalleryHTMLSupportsTapToPreviewLargePhoto() throws {
    let html = String(
      data: LocalProofingWebRenderer.galleryHTML(sessionToken: "ABC123"),
      encoding: .utf8
    )

    XCTAssertTrue(html?.contains(#"id="viewer""#) == true)
    XCTAssertTrue(html?.contains("openViewer(photo)") == true)
    XCTAssertTrue(html?.contains("viewerImage") == true)
  }

  func testLocalProofingFavoriteUpdateDecodesJSONBody() throws {
    let body = Data(#"{"id":"photo-1","favorite":true}"#.utf8)

    let update = try LocalProofingWebRenderer.favoriteUpdate(from: body)

    XCTAssertEqual(update, LocalProofingFavoriteUpdate(id: "photo-1", favorite: true))
  }

  func testLocalProofingRouterServesGalleryPhotosPreviewAndFavoriteUpdate() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: true
    )
    var favoriteUpdates: [LocalProofingFavoriteUpdate] = []
    let router = LocalProofingRequestRouter(
      sessionToken: "ABC123",
      photosProvider: { [photo] },
      favoriteIDsProvider: { [] },
      previewProvider: { id in id == "photo-1" ? Data([1, 2, 3]) : nil },
      favoriteHandler: { favoriteUpdates.append($0) }
    )

    let html = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/s/ABC123", body: Data()))
    XCTAssertEqual(html.statusCode, 200)
    XCTAssertTrue(String(data: html.body, encoding: .utf8)?.contains("/api/photos") == true)

    let photos = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/api/photos", body: Data()))
    XCTAssertEqual(photos.contentType, "application/json")
    XCTAssertTrue(String(data: photos.body, encoding: .utf8)?.contains("DSCF0001.JPG") == true)

    let preview = router.response(for: LocalProofingHTTPRequest(method: "GET", path: "/preview/photo-1.jpg", body: Data()))
    XCTAssertEqual(preview.contentType, "image/jpeg")
    XCTAssertEqual(preview.body, Data([1, 2, 3]))

    let favorite = router.response(for: LocalProofingHTTPRequest(
      method: "POST",
      path: "/api/favorite",
      body: Data(#"{"id":"photo-1","favorite":true}"#.utf8)
    ))
    XCTAssertEqual(favorite.statusCode, 200)
    XCTAssertEqual(favoriteUpdates, [LocalProofingFavoriteUpdate(id: "photo-1", favorite: true)])
  }

  func testLocalProofingServerHandlesSplitBrowserRequest() throws {
    let photo = LocalProofingPhoto(
      id: "photo-1",
      filename: "DSCF0001.JPG",
      detail: "JPG · 2 MB",
      formatLabel: "JPG",
      hasPreview: false
    )
    let router = LocalProofingRequestRouter(
      sessionToken: "ABC123",
      photosProvider: { [photo] },
      favoriteIDsProvider: { [] },
      previewProvider: { _ in nil },
      favoriteHandler: { _ in }
    )
    let server = LocalProofingServer(router: router)
    let url = try server.start(
      preferredPort: 18080,
      advertisedInterface: LocalProofingNetworkInterface(name: "lo0", address: "127.0.0.1")
    )
    defer { server.stop() }

    let responseExpectation = expectation(description: "server responds to split request")
    let connection = NWConnection(
      host: NWEndpoint.Host(url.host ?? "127.0.0.1"),
      port: NWEndpoint.Port(rawValue: UInt16(url.port ?? 0))!,
      using: .tcp
    )
    var response = Data()
    connection.stateUpdateHandler = { state in
      guard case .ready = state else { return }
      connection.send(
        content: Data("GET /s/ABC123 HTTP/1.1\r\nHost:".utf8),
        completion: .contentProcessed { _ in
          connection.send(
            content: Data("127.0.0.1\r\n\r\n".utf8),
            completion: .contentProcessed { _ in }
          )
        }
      )
    }
    func receiveNext() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, _ in
        if let data {
          response.append(data)
        }
        if isComplete || String(data: response, encoding: .utf8)?.contains("</html>") == true {
          responseExpectation.fulfill()
          connection.cancel()
        } else {
          receiveNext()
        }
      }
    }
    receiveNext()
    connection.start(queue: .global())

    wait(for: [responseExpectation], timeout: 3)
    let responseText = try XCTUnwrap(String(data: response, encoding: .utf8))
    XCTAssertTrue(responseText.hasPrefix("HTTP/1.1 200 OK"), responseText)
    XCTAssertTrue(responseText.contains("现场选片"), responseText)
  }

  func testLocalProofingHTTPRequestParsesMethodPathAndBody() throws {
    let raw = Data("""
    POST /api/favorite?cache=0 HTTP/1.1\r
    Host: 192.168.2.2\r
    Content-Type: application/json\r
    \r
    {"id":"photo-1","favorite":false}
    """.utf8)

    let request = try XCTUnwrap(LocalProofingHTTPRequest.parse(raw))

    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/api/favorite")
    XCTAssertEqual(String(data: request.body, encoding: .utf8), #"{"id":"photo-1","favorite":false}"#)
  }

  func testLocalProofingSessionTokenAndQRCodeAreShareable() throws {
    let token = LocalProofingSessionToken.make()

    XCTAssertEqual(token.count, 6)
    XCTAssertNotNil(token.range(of: #"^[A-Z2-9]+$"#, options: .regularExpression))
    XCTAssertNotNil(LocalProofingQRCode.image(for: "http://192.168.2.2:8080/s/\(token)"))
  }

  func testLocalProofingNetworkPrefersWifiThenHotspotAndNeverCellular() {
    let interfaces = [
      LocalProofingNetworkInterface(name: "pdp_ip0", address: "10.12.0.8"),
      LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      LocalProofingNetworkInterface(name: "bridge100", address: "172.20.10.1"),
    ]

    XCTAssertEqual(LocalProofingNetwork.preferredAddress(from: interfaces)?.address, "192.168.1.22")
    XCTAssertEqual(LocalProofingNetwork.preferredAddress(from: Array(interfaces.prefix(2)))?.address, "192.168.1.22")
    XCTAssertNil(LocalProofingNetwork.preferredAddress(from: [interfaces[0]]))
  }

  func testLocalProofingNetworkBuildsSeparateWifiAndHotspotShareEndpoints() {
    let endpoints = LocalProofingNetwork.shareEndpoints(
      port: 8080,
      token: "ABC123",
      interfaces: [
        LocalProofingNetworkInterface(name: "pdp_ip0", address: "10.12.0.8"),
        LocalProofingNetworkInterface(name: "bridge100", address: "172.20.10.1"),
        LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      ]
    )

    XCTAssertEqual(endpoints.map(\.label), ["同一 Wi-Fi", "iPhone 热点"])
    XCTAssertEqual(endpoints.map { $0.url.absoluteString }, [
      "http://192.168.1.22:8080/s/ABC123",
      "http://172.20.10.1:8080/s/ABC123",
    ])
  }

  func testLocalProofingNetworkDoesNotInventHotspotFallback() {
    let token = "ABC123"

    let missingURL = LocalProofingNetwork.url(interface: nil, port: 8080, token: token)
    let wifiURL = LocalProofingNetwork.url(
      interface: LocalProofingNetworkInterface(name: "en0", address: "192.168.1.22"),
      port: 8080,
      token: token
    )

    XCTAssertNil(missingURL)
    XCTAssertEqual(wifiURL?.absoluteString, "http://192.168.1.22:8080/s/ABC123")
  }

  func testLocalProofingPhotoMapperUsesWiredImportMetadataAndPreviewState() {
    let item = wiredImportItem(
      id: "photo-1",
      name: "DSCF0001.JPG",
      fileSize: 1_200_000,
      thumbnail: UIImage(systemName: "photo")
    )

    let photo = LocalProofingPhotoMapper.photo(from: item)

    XCTAssertEqual(photo.id, "photo-1")
    XCTAssertEqual(photo.filename, "DSCF0001.JPG")
    XCTAssertEqual(photo.formatLabel, "JPG")
    XCTAssertTrue(photo.detail.contains("JPG"))
    XCTAssertTrue(photo.detail.contains("MB"))
    XCTAssertTrue(photo.hasPreview)
  }

  private func wiredImportItem(
    id: String,
    name: String,
    uti: String? = "public.jpeg",
    fileSize: Int64 = 1024,
    createdAt: Date? = nil,
    thumbnail: UIImage? = nil,
    isImportable: Bool = true,
    ptpObjectHandle: UInt32 = 0
  ) -> WiredCameraImportItem {
    WiredCameraImportItem(
      id: id,
      ptpObjectHandle: ptpObjectHandle,
      name: name,
      uti: uti,
      fileSize: fileSize,
      createdAt: createdAt,
      thumbnail: thumbnail,
      isImportable: isImportable
    )
  }

  func testCameraGalleryTransportSessionProtocolMatchesCurrentGalleryServiceContract() {
    let session: CameraGalleryTransportSession = CameraVendorRealtimeGalleryService()

    XCTAssertTrue(session is CameraVendorRealtimeGalleryService)
  }

  func testCameraAdapterDescriptorCanDescribeFujifilmWithoutUiBrandClaims() {
    let descriptor = CameraAdapterDescriptor(
      id: "fujifilm-x-series",
      displayName: "FUJIFILM X Series",
      legalDisclaimer: "FUJIFILM is a trademark of FUJIFILM Corporation. This app is not affiliated with or endorsed by FUJIFILM Corporation."
    )

    XCTAssertEqual(descriptor.id, "fujifilm-x-series")
    XCTAssertTrue(descriptor.displayName.contains("FUJIFILM"))
    XCTAssertTrue(descriptor.legalDisclaimer?.contains("not affiliated") == true)
  }

  func testFujifilmXSeriesProfilePreservesCurrentXt5ConnectionAndDownloadPolicies() {
    let profile = FujifilmXSeriesProfile.xt5Current

    XCTAssertEqual(profile.id, "fujifilm-x-series-xt5-current")
    XCTAssertEqual(
      profile.ptpStartupDelaySeconds,
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true)
    )
    XCTAssertEqual(profile.fileDownloadReadSize, CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize)
    XCTAssertEqual(
      profile.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize
    )
  }

  func testFujifilmXSeriesProfilePreservesCurrentObjectSizePolicy() {
    let profile = FujifilmXSeriesProfile.xt5Current

    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: 100))
    XCTAssertTrue(profile.shouldSkipFreshFileInfoProbe(formatLabel: "RAW", cachedExpectedSize: 100))
    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "JPG", cachedExpectedSize: 100))
    XCTAssertFalse(profile.shouldSkipFreshFileInfoProbe(formatLabel: "HEIF", cachedExpectedSize: nil))
  }

  func testThumbnailFallbackStopsAfterPriorityDownloadInterruption() {
    XCTAssertFalse(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: true,
        isConnected: true
      )
    )
    XCTAssertTrue(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: false,
        isConnected: true
      )
    )
    XCTAssertFalse(
      CameraVendorThumbnailPriorityDownloadPolicy.shouldContinueToPartialPreviewFallback(
        afterPriorityDownloadInterruption: false,
        isConnected: false
      )
    )
  }

  func testFujifilmCameraAdapterCreatesCurrentGallerySession() {
    let adapter = FujifilmCameraAdapter(profile: .xt5Current)
    let session = adapter.makeGallerySession()

    XCTAssertEqual(adapter.descriptor.id, "fujifilm-x-series")
    XCTAssertTrue(session is CameraVendorRealtimeGalleryService)
  }

  func testFujifilmCameraAdapterExposesCurrentProfileForDiagnostics() {
    let adapter = FujifilmCameraAdapter(profile: .xt5Current)

    XCTAssertEqual(adapter.profile.id, FujifilmXSeriesProfile.xt5Current.id)
  }

  func testNativeConnectUsesDefaultFujifilmAdapterDescriptor() {
    let descriptor = NativeCameraAdapterRegistry.defaultAdapterDescriptor

    XCTAssertEqual(descriptor.id, "fujifilm-x-series")
  }

  func testCameraVendorAdvertisementMatcherAcceptsCameraVendorName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "CAMERA-DEVICE-A",
      serviceUUIDs: [],
      manufacturerData: nil
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .unknown)
    XCTAssertNil(match?.pairingToken)
  }

  func testCameraVendorAdvertisementMatcherAcceptsFujifilmXSeriesModelName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "X-T5",
      serviceUUIDs: [],
      manufacturerData: nil
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.resolvedName, "X-T5")
    XCTAssertEqual(match?.appVariant, .unknown)
  }

  func testCameraVendorAdvertisementMatcherAcceptsCameraRemoteUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.legacyRemoteServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .legacyRemote)
    XCTAssertEqual(match?.pairingToken, Data([0x11, 0x22, 0x33, 0x44]))
  }

  func testCameraVendorAdvertisementMatcherAcceptsReferenceAppUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.referenceAppServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0xAA, 0xBB, 0xCC, 0xDD])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .referenceApp)
    XCTAssertEqual(match?.pairingToken, Data([0xAA, 0xBB, 0xCC, 0xDD]))
  }

  func testCameraVendorAdvertisementMatcherAcceptsStandbyUuidWithoutName() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: nil,
      serviceUUIDs: [CameraVendorDeviceMatcher.standbyServiceUUIDString],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x01, 0x02, 0x03, 0x04])
    )

    XCTAssertNotNil(match)
    XCTAssertEqual(match?.appVariant, .standby)
    XCTAssertEqual(match?.pairingToken, Data([0x01, 0x02, 0x03, 0x04]))
  }

  func testRememberedRedReconnectAcceptsExactEndpointWith123D() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    XCTAssertTrue(
      CameraVendorRememberedRedReconnectAdmissionPolicy.shouldAdmit(
        observedPeripheralID: peripheralID,
        rememberedPeripheralID: peripheralID,
        serviceUUIDs: [CameraVendorDeviceMatcher.securePairServiceUUIDString]
      )
    )
  }

  func testRememberedRedReconnectRejectsWrongEndpoint() {
    let rememberedID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!
    let observedID = UUID(uuidString: "A3DD810A-E306-8298-E4A0-D94124300FD7")!

    XCTAssertFalse(
      CameraVendorRememberedRedReconnectAdmissionPolicy.shouldAdmit(
        observedPeripheralID: observedID,
        rememberedPeripheralID: rememberedID,
        serviceUUIDs: [CameraVendorDeviceMatcher.securePairServiceUUIDString]
      )
    )
  }

  func testRememberedRedReconnectRejectsWrongService() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    XCTAssertFalse(
      CameraVendorRememberedRedReconnectAdmissionPolicy.shouldAdmit(
        observedPeripheralID: peripheralID,
        rememberedPeripheralID: peripheralID,
        serviceUUIDs: [CameraVendorDeviceMatcher.standbyServiceUUIDString]
      )
    )
  }

  func testRememberedRedReconnectBuildsTypedMatchWithoutModelFallback() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!
    let services = [CameraVendorDeviceMatcher.securePairServiceUUIDString]
    let manufacturerData = Data([0xD8, 0x04, 0x01, 0x31, 0x41, 0x44, 0x36, 0x33])

    XCTAssertNil(
      CameraVendorDeviceMatcher.matchAdvertisement(
        name: "X-M5",
        serviceUUIDs: services,
        manufacturerData: manufacturerData
      )
    )

    let match = CameraVendorDeviceMatcher.matchRememberedRedReconnectAdvertisement(
      name: "X-M5",
      observedPeripheralID: peripheralID,
      rememberedPeripheralID: peripheralID,
      rememberedAppVariant: .standby,
      serviceUUIDs: services,
      manufacturerData: manufacturerData
    )

    XCTAssertEqual(match?.resolvedName, "X-M5")
    XCTAssertEqual(match?.appVariant, .standby)
    XCTAssertEqual(match?.admission, .rememberedRedReconnect)
    XCTAssertTrue(match?.reasons.contains("remembered-endpoint") == true)
    XCTAssertTrue(match?.reasons.contains("service:ConnectedDeviceInformationRED") == true)
  }

  func testRememberedRedReconnectAdmissionRunsBeforeGenericAdvertisementMatcher() throws {
    let source = try runnerSource("CameraVendorBluetoothService.swift")
    let methodStart = try XCTUnwrap(
      source.range(of: "func centralManager(\n    _ central: CBCentralManager,\n    didDiscover peripheral: CBPeripheral")?.lowerBound
    )
    let methodEnd = try XCTUnwrap(
      source.range(of: "private func logUnmatchedAdvertisementSample", range: methodStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[methodStart..<methodEnd])
    let rememberedAdmission = try XCTUnwrap(
      body.range(of: "matchRememberedRedReconnectAdvertisement")?.lowerBound
    )
    let genericAdmission = try XCTUnwrap(
      body.range(of: "matchAdvertisement", range: rememberedAdmission..<body.endIndex)?.lowerBound
    )

    XCTAssertLessThan(rememberedAdmission, genericAdmission)
  }

  func testRememberedRedReconnectIdentityAcceptsExactEndpointAndFullSerial() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    XCTAssertEqual(
      CameraVendorRememberedRedReconnectIdentityPolicy.decision(
        admission: .rememberedRedReconnect,
        rememberedPeripheralID: peripheralID,
        connectedPeripheralID: peripheralID,
        rememberedSerialNumber: "AD63001234",
        connectedSerialNumber: "AD63001234"
      ),
      .accepted
    )
  }

  func testRememberedRedReconnectIdentityRejectsMissingStoredSerial() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    for missingSerial in [nil, "", "  ", "-"] as [String?] {
      XCTAssertEqual(
        CameraVendorRememberedRedReconnectIdentityPolicy.decision(
          admission: .rememberedRedReconnect,
          rememberedPeripheralID: peripheralID,
          connectedPeripheralID: peripheralID,
          rememberedSerialNumber: missingSerial,
          connectedSerialNumber: "AD63001234"
        ),
        .rejected(reason: .missingRememberedSerial)
      )
    }
  }

  func testRememberedRedReconnectIdentityRejectsMissingObservedSerial() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    for missingSerial in [nil, "", "  ", "-"] as [String?] {
      XCTAssertEqual(
        CameraVendorRememberedRedReconnectIdentityPolicy.decision(
          admission: .rememberedRedReconnect,
          rememberedPeripheralID: peripheralID,
          connectedPeripheralID: peripheralID,
          rememberedSerialNumber: "AD63001234",
          connectedSerialNumber: missingSerial
        ),
        .rejected(reason: .missingConnectedSerial)
      )
    }
  }

  func testRememberedRedReconnectIdentityRejectsSerialMismatch() {
    let peripheralID = UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90")!

    XCTAssertEqual(
      CameraVendorRememberedRedReconnectIdentityPolicy.decision(
        admission: .rememberedRedReconnect,
        rememberedPeripheralID: peripheralID,
        connectedPeripheralID: peripheralID,
        rememberedSerialNumber: "AD63001234",
        connectedSerialNumber: "AD63005678"
      ),
      .rejected(reason: .serialMismatch)
    )
  }

  func testRememberedRedReconnectIdentityRejectsEndpointMismatch() {
    XCTAssertEqual(
      CameraVendorRememberedRedReconnectIdentityPolicy.decision(
        admission: .rememberedRedReconnect,
        rememberedPeripheralID: UUID(uuidString: "42D39012-FB38-3F92-C07A-53625FCCAB90"),
        connectedPeripheralID: UUID(uuidString: "A3DD810A-E306-8298-E4A0-D94124300FD7"),
        rememberedSerialNumber: "AD63001234",
        connectedSerialNumber: "AD63001234"
      ),
      .rejected(reason: .endpointMismatch)
    )
  }

  func testGenericAdvertisementDoesNotRequireRememberedRedIdentityGate() {
    XCTAssertEqual(
      CameraVendorRememberedRedReconnectIdentityPolicy.decision(
        admission: .generic,
        rememberedPeripheralID: nil,
        connectedPeripheralID: nil,
        rememberedSerialNumber: nil,
        connectedSerialNumber: nil
      ),
      .notRequired
    )
  }

  func testRememberedRedReconnectIdentityGateRunsBeforeHandshakeMutation() throws {
    let source = try runnerSource("CameraVendorBluetoothService.swift")
    let methodStart = try XCTUnwrap(
      source.range(of: "private func maybeStartPairing(on peripheral: CBPeripheral)")?.lowerBound
    )
    let methodEnd = try XCTUnwrap(
      source.range(of: "private func startPairingIfReady", range: methodStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[methodStart..<methodEnd])
    let identityGate = try XCTUnwrap(
      body.range(of: "CameraVendorRememberedRedReconnectIdentityPolicy.decision")?.lowerBound
    )
    let handshakeMutation = try XCTUnwrap(
      body.range(of: "handshakeCoordinator.markHandshakeStarted()")?.lowerBound
    )

    XCTAssertLessThan(identityGate, handshakeMutation)
    XCTAssertTrue(body.contains("central.cancelPeripheralConnection(peripheral)"))
  }

  func testRememberedRedReconnectIdentityRejectionStatusSurvivesDisconnectCallback() throws {
    let source = try runnerSource("CameraVendorBluetoothService.swift")
    let gateStart = try XCTUnwrap(
      source.range(of: "private func maybeStartPairing(on peripheral: CBPeripheral)")?.lowerBound
    )
    let gateEnd = try XCTUnwrap(
      source.range(of: "private func startPairingIfReady", range: gateStart..<source.endIndex)?.lowerBound
    )
    let gateBody = String(source[gateStart..<gateEnd])
    let rejectionState = try XCTUnwrap(
      gateBody.range(of: "pendingRememberedRedReconnectIdentityRejectionReason = reason")?.lowerBound
    )
    let cancellation = try XCTUnwrap(
      gateBody.range(of: "central.cancelPeripheralConnection(peripheral)")?.lowerBound
    )
    XCTAssertLessThan(rejectionState, cancellation)

    let disconnectStart = try XCTUnwrap(
      source.range(of: "didDisconnectPeripheral peripheral: CBPeripheral")?.lowerBound
    )
    let disconnectEnd = try XCTUnwrap(
      source.range(of: "extension CameraVendorBluetoothService: CBPeripheralDelegate", range: disconnectStart..<source.endIndex)?.lowerBound
    )
    let disconnectBody = String(source[disconnectStart..<disconnectEnd])
    let preservedStatus = try XCTUnwrap(
      disconnectBody.range(of: "pendingRememberedRedReconnectIdentityRejectionReason")?.lowerBound
    )
    let genericStatus = try XCTUnwrap(
      disconnectBody.range(of: "updateStatus(\"连接已断开\"")?.lowerBound
    )

    XCTAssertLessThan(preservedStatus, genericStatus)
    XCTAssertTrue(disconnectBody.contains("相机身份校验失败，请重新配对"))
  }

  func testCameraVendorAdvertisementMatcherRejectsUnrelatedAdvertisement() {
    let match = CameraVendorDeviceMatcher.matchAdvertisement(
      name: "Unrelated Camera",
      serviceUUIDs: [],
      manufacturerData: Data([0xD8, 0x04, 0x02, 0x10, 0x20, 0x30, 0x40])
    )

    XCTAssertNil(match)
  }

  func testPairingTokenExtractsFromManufacturerDataWithCompanyPrefix() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertEqual(token, Data([0x11, 0x22, 0x33, 0x44]))
  }

  func testPairingTokenExtractsFromFiveBytePayload() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0x02, 0x99, 0x88, 0x77, 0x66])
    )

    XCTAssertEqual(token, Data([0x99, 0x88, 0x77, 0x66]))
  }

  func testPairingTokenRejectsWrongManufacturerType() {
    let token = CameraVendorDeviceMatcher.pairingToken(
      from: Data([0xD8, 0x04, 0x01, 0x11, 0x22, 0x33, 0x44])
    )

    XCTAssertNil(token)
  }

  func testPairingPayloadUsesTokenBytesUnchanged() {
    let payload = CameraVendorSecureHandshakeCodec.pairingPayload(Data([0x01, 0x02, 0x03, 0x04]))

    XCTAssertEqual(payload, Data([0x01, 0x02, 0x03, 0x04]))
  }

  func testIdentifierPayloadUsesUtf8Encoding() {
    let payload = CameraVendorSecureHandshakeCodec.identifierPayload("CamTransfer Native")

    XCTAssertEqual(payload, Data("CamTransfer Native".utf8))
  }

  func testHandshakeIdentityPolicyUsesStableIPhoneStyleNameForCameraPairing() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "Gold 的 iPhone",
        fallbackAppName: "CamTransfer"
      ),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyAddsStableSuffixForGenericIPhoneName() {
    let name = CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
      preferredDeviceName: "iPhone",
      fallbackAppName: "CamTransfer"
    )

    XCTAssertEqual(name, "iPhone-6970")
  }

  func testHandshakeIdentityPolicyNormalizesStoredGenericIPhoneName() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.normalizedStoredConnectedDeviceName("iPhone-0426"),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyMigratesLegacyPhonePrefixedStoredName() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.normalizedStoredConnectedDeviceName("Phone-0426"),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyStillUsesStableIPhoneStyleNameWhenInputsAreEmpty() {
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: "   ",
        fallbackAppName: "CamTransfer Native"
      ),
      "iPhone-6970"
    )
    XCTAssertEqual(
      CameraVendorHandshakeIdentityPolicy.connectedDeviceName(
        preferredDeviceName: nil,
        fallbackAppName: nil
      ),
      "iPhone-6970"
    )
  }

  func testHandshakeIdentityPolicyMatchesFallbackIdentifierEncoding() {
    XCTAssertEqual(CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName, "CamTransfer")
    XCTAssertEqual(
      CameraVendorSecureHandshakeCodec.identifierPayload(
        CameraVendorHandshakeIdentityPolicy.fallbackConnectedDeviceName
      ),
      Data("CamTransfer".utf8)
    )
  }

  func testStandbyUuidMatchesCurrentCameraVendorDocumentation() {
    XCTAssertEqual(
      CameraVendorDeviceMatcher.standbyServiceUUIDString,
      "A9D2B304-E8D6-4902-8336-352B772D7597"
    )
  }

  func testSecureHandshakeStatusAckReplacesFourthByteWith20() {
    let payload = CameraVendorSecureHandshakeCodec.statusAckPayload(
      from: Data([0x07, 0x96, 0x00, 0x00])
    )

    XCTAssertEqual(payload, Data([0x07, 0x96, 0x00, 0x20]))
  }

  func testSecureHandshakeStatusAckRequiresFourBytes() {
    XCTAssertNil(CameraVendorSecureHandshakeCodec.statusAckPayload(from: Data([0x01, 0x02, 0x03])))
  }

  func testSecureIdentificationAckPolicyDoesNotSkipAckForRememberedPairing() {
    XCTAssertFalse(
      CameraVendorSecureIdentificationAckPolicy.shouldSkipIdentificationAck(
        isRememberedPairing: true
      )
    )
    XCTAssertFalse(
      CameraVendorSecureIdentificationAckPolicy.shouldSkipIdentificationAck(
        isRememberedPairing: false
      )
    )
  }

  func testReferenceAppPairingCodecSetsApplicationIdentifierBit() {
    let payload = CameraVendorReferenceAppPairingCodec.identificationNumberPayload(
      from: Data([0x2B, 0xA1, 0x26, 0x00])
    )

    XCTAssertEqual(payload, Data([0x2B, 0xA1, 0x26, 0x20]))
  }

  func testReferenceAppPairingCodecRejectsNonFourByteIdentificationNumber() {
    XCTAssertNil(
      CameraVendorReferenceAppPairingCodec.identificationNumberPayload(
        from: Data([0x01, 0x02, 0x03])
      )
    )
  }

  func testReferenceAppPairingCodecRecognizesAlreadyPairedIdentificationNumber() {
    XCTAssertTrue(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26, 0x20])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26, 0x00])
      )
    )
    XCTAssertFalse(
      CameraVendorReferenceAppPairingCodec.isAlreadyPairedIdentificationNumber(
        Data([0x91, 0xAA, 0x26])
      )
    )
  }

  func testReferenceAppPairingPolicyStartsByWritingDeviceName() {
    XCTAssertEqual(
      CameraVendorReferenceAppPairingPolicy.initialStep,
      .writeDeviceName
    )
  }

  func testReferenceAppPairingPolicyReadsIdentificationNumberAfterDeviceNameWrite() {
    XCTAssertEqual(
      CameraVendorReferenceAppPairingPolicy.nextStep(after: .didWriteDeviceName),
      .readIdentificationNumber
    )
  }

  func testHandshakeWaitsForMetadataReadToFinish() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.registerServiceForCharacteristicDiscovery("180A")

    coordinator.completeCharacteristicDiscovery(for: "91F1")
    coordinator.registerMetadataRead("2A25")

    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.completeCharacteristicDiscovery(for: "180A")
    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.completeMetadataRead("2A25")
    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeCanStartImmediatelyWhenOnlyPairServiceIsNeeded() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.completeCharacteristicDiscovery(for: "91F1")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeDoesNotRestartAfterBeginning() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("91F1")
    coordinator.completeCharacteristicDiscovery(for: "91F1")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))

    coordinator.markHandshakeStarted()
    XCTAssertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testHandshakeCanStartWhenSecureIdentifierIsPresent() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("123D")
    coordinator.completeCharacteristicDiscovery(for: "123D")

    XCTAssertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic: true))
  }

  func testSecureHandshakeWaitsForAllServicesBeforeWritingConnectedDeviceName() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerServiceForCharacteristicDiscovery("123D8F06-62A1-4935-9322-833C531EE225")
    coordinator.registerServiceForCharacteristicDiscovery("4E941240-D01D-46B9-A5EA-67636806830B")

    coordinator.completeCharacteristicDiscovery(for: "123D8F06-62A1-4935-9322-833C531EE225")

    XCTAssertFalse(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )

    coordinator.completeCharacteristicDiscovery(for: "4E941240-D01D-46B9-A5EA-67636806830B")

    XCTAssertTrue(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )
  }

  func testSecureHandshakeWaitsForNotificationSubscriptionsBeforeWritingConnectedDeviceName() {
    var coordinator = CameraVendorHandshakeCoordinator()
    coordinator.registerNotificationSubscription("A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

    XCTAssertFalse(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )

    coordinator.completeNotificationSubscription(for: "A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

    XCTAssertTrue(
      coordinator.canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: true,
        hasConnectedDeviceIdentificationCharacteristic: true
      )
    )
  }

  func testEncryptionRecoveryRetriesOnlyOnce() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    XCTAssertTrue(policy.registerEncryptionFailureAndShouldRetry())
    XCTAssertFalse(policy.registerEncryptionFailureAndShouldRetry())
  }

  func testEncryptionRecoveryRequiresSystemBluetoothCleanupAfterRetryIsUsed() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()

    XCTAssertTrue(policy.shouldRequireSystemBluetoothCleanupAfterRetryExhausted())
  }

  func testEncryptionRecoveryResetAllowsFutureRetry() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()
    policy.reset()

    XCTAssertTrue(policy.registerEncryptionFailureAndShouldRetry())
  }

  func testEncryptionRecoveryGuidesUserToCameraPairingModeAfterDisconnect() {
    var policy = CameraVendorEncryptionRecoveryPolicy()

    _ = policy.registerEncryptionFailureAndShouldRetry()

    XCTAssertEqual(
      policy.consumeDisconnectAction(),
      .requireManualCameraPairingMode
    )
  }

  func testPairingReadyAdvertisementRequiresNonStandbySignal() {
    XCTAssertFalse(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: [CameraVendorDeviceMatcher.standbyServiceUUIDString],
        manufacturerData: Data([0xD8, 0x04, 0x01, 0x31, 0x30, 0x30, 0x33, 0x42])
      )
    )

    XCTAssertTrue(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: [CameraVendorDeviceMatcher.referenceAppServiceUUIDString],
        manufacturerData: Data([0xD8, 0x04, 0x02, 0x11, 0x22, 0x33, 0x44])
      )
    )
  }

  func testPairingReadyAdvertisementAcceptsSecurePairServiceUuid() {
    XCTAssertTrue(
      CameraVendorDeviceMatcher.isPairingReadyAdvertisement(
        serviceUUIDs: ["123D8F06-62A1-4935-9322-833C531EE225"],
        manufacturerData: Data([0xD8, 0x04, 0x01, 0x31, 0x30, 0x30, 0x33, 0x42])
      )
    )
  }

  func testWifiJoinDiagnosticsIncludesNamedHotspotError() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "internal error."]
    )

    XCTAssertEqual(
      CameraVendorWifiJoinDiagnostics.describeHotspotError(error),
      "\(NEHotspotConfigurationErrorDomain) code=8 internal error. | hotspot=internal"
    )
  }

  func testWifiJoinDiagnosticsLeavesUnknownDomainsUntouched() {
    let error = NSError(
      domain: "ExampleDomain",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "boom"]
    )

    XCTAssertEqual(
      CameraVendorWifiJoinDiagnostics.describeHotspotError(error),
      "ExampleDomain code=42 boom"
    )
  }

  func testWifiJoinDiagnosticsTreatsInternalHotspotErrorAsRecoverable() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue,
      userInfo: [NSLocalizedDescriptionKey: "internal error."]
    )

    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
  }

  func testWifiJoinDiagnosticsTreatsMissingApplyCallbackAsRecoverableForEvidenceCheck() {
    let error = CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutError(
      ssid: "FUJIFILM-X-T5-003B"
    )

    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.isApplyCallbackTimeout(error))
    XCTAssertTrue(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.applyCallbackTimeoutSeconds, 8)
    XCTAssertTrue(
      CameraVendorWifiJoinDiagnostics
        .describeHotspotError(error)
        .contains("等待系统 Wi-Fi 连接回调超时")
    )
  }

  func testWifiJoinDiagnosticsDoesNotTreatUnrelatedErrorAsRecoverable() {
    let error = NSError(
      domain: "ExampleDomain",
      code: 42,
      userInfo: [NSLocalizedDescriptionKey: "boom"]
    )

    XCTAssertFalse(CameraVendorWifiJoinDiagnostics.shouldContinueAssociationCheck(after: error))
  }

  func testWifiJoinDoesNotRequestLocationAuthorization() throws {
    let source = try runnerSource(
      "CameraVendorBluetoothService.swift",
      "CameraVendorWifiPolicy.swift"
    )

    XCTAssertFalse(source.contains("CameraVendorWifiLocationAuthorizer"))
    XCTAssertFalse(source.contains("CLLocationManager"))
    XCTAssertFalse(source.contains("requestWhenInUseAuthorization()"))
  }

  func testWifiAssociationReadinessDoesNotUsePtpProbeBeforeGallerySession() {
    XCTAssertFalse(
      CameraVendorWifiAssociationReadiness.isReadyToProceed(
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil,
        isCameraPtpReachable: true
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadiness.isReadyToProceed(
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil,
        isCameraPtpReachable: false
      )
    )
  }

  func testHiddenGalleryRoutePolicyOnlyRunsStrictReferenceAppAfterBleHandoff() {
    let routes = CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes

    XCTAssertEqual(
      routes.map(\.id),
      [.strictReferenceApp]
    )
    XCTAssertEqual(routes.count, 1)
    XCTAssertEqual(routes[0].launchRequestPayload, Data([0x03, 0x00]))
    XCTAssertEqual(routes[0].ptpStartupDelaySeconds, 0)
  }

  func testHiddenGalleryRoutePolicyStopsAfterSuccessfulItems() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:04:30 14:00:00",
      byteSizeText: "1 MB"
    )

    XCTAssertTrue(CameraVendorGalleryRoutePolicy.shouldStopRouteSearch(after: [item]))
    XCTAssertFalse(CameraVendorGalleryRoutePolicy.shouldStopRouteSearch(after: []))
  }

  func testBluetoothConnectFailurePolicyRecognizesRemovedPairingInformation() {
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(
        for: "Peer removed pairing information"
      ),
      CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    )
    XCTAssertTrue(CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus.contains("删除本地蓝牙配对"))
  }

  func testSystemBluetoothCleanupPolicyPersistsHardBlockUntilUserConfirmsCleanup() throws {
    let suiteName = "CameraVendorSystemBluetoothPairingCleanupPolicyTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    XCTAssertFalse(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))

    CameraVendorSystemBluetoothPairingCleanupPolicy.markCleanupRequired(
      reason: "Peer removed pairing information",
      defaults: defaults
    )
    XCTAssertTrue(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))

    CameraVendorSystemBluetoothPairingCleanupPolicy.clearCleanupRequired(defaults: defaults)
    XCTAssertFalse(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))
  }

  func testSystemBluetoothCleanupPolicyClearsLegacyUnverifiedRecordMisclassification() throws {
    let suiteName = "CameraVendorSystemBluetoothPairingCleanupPolicyLegacyReasonTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    CameraVendorSystemBluetoothPairingCleanupPolicy.markCleanupRequired(
      reason: "已配对记录缺少系统蓝牙有效性校验: restore remembered camera",
      defaults: defaults
    )
    XCTAssertFalse(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))

    CameraVendorSystemBluetoothPairingCleanupPolicy.markCleanupRequired(
      reason: "CBATTErrorDomain Code=15 insufficient encryption",
      defaults: defaults
    )
    XCTAssertTrue(CameraVendorSystemBluetoothPairingCleanupPolicy.requiresCleanup(defaults: defaults))
  }

  func testBluetoothConnectFailurePolicyTreatsEncryptionErrorsAsSystemPairingCleanupRequired() {
    XCTAssertTrue(
      CameraVendorBluetoothConnectFailurePolicy.requiresSystemBluetoothPairingCleanup(
        for: "CBATTErrorDomain Code=15 insufficient encryption"
      )
    )
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(
        for: "Insufficient Encryption"
      ),
      CameraVendorSystemBluetoothPairingCleanupPolicy.requiredCleanupStatus
    )
  }

  func testBluetoothConnectFailurePolicyClearsRememberedPairingWhenPeerRemovedPairingInformation() {
    XCTAssertTrue(
      CameraVendorBluetoothConnectFailurePolicy.shouldClearRememberedPairing(
        for: "Peer removed pairing information"
      )
    )
  }

  func testBluetoothConnectFailurePolicyFallsBackToGenericFailure() {
    XCTAssertEqual(
      CameraVendorBluetoothConnectFailurePolicy.userFacingStatus(for: "timeout"),
      "连接失败"
    )
  }

  func testTransferActivationFailureStatusDoesNotAskForBluetoothCleanup() {
    XCTAssertFalse(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("清除旧配对"))
    XCTAssertFalse(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("删除本地蓝牙"))
    XCTAssertTrue(CameraVendorTransferActivationFailureStatusPolicy.activationFailedStatus.contains("传图模式"))
  }

  func testGalleryPreparationSkipsAutomaticWifiJoinAfterManualRecoveryWasSuggested() {
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
        hasWifiConfigurations: true,
        prefersManualWifiRecovery: true
      )
    )
  }

  func testGalleryPreparationAttemptsAutomaticWifiJoinWhenCameraCredentialsAreAvailable() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldAttemptAutomaticWifiJoin(
        hasWifiConfigurations: true,
        prefersManualWifiRecovery: false
      )
    )
  }

  func testGalleryPreparationStopsAfterPreferredWifiConfigurationFails() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
        attemptedConfigurationIndex: 0
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldStopAutomaticWifiAttemptsAfterFailure(
        attemptedConfigurationIndex: 1
      )
    )
  }

  func testWifiJoinDiagnosticsWaitsForSSIDAfterRecoverableApplyFailure() {
    let error = NSError(
      domain: NEHotspotConfigurationErrorDomain,
      code: NEHotspotConfigurationError.internal.rawValue
    )

    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.associationTimeout(after: error), 15)
    XCTAssertEqual(CameraVendorWifiJoinDiagnostics.associationTimeout(after: nil), 15)
  }

  func testWifiJoinDiagnosticsDoesNotAllowUnverifiedAssociationWithoutSSIDMatch() {
    XCTAssertFalse(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: nil
      )
    )
    XCTAssertFalse(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: "YangBaby"
      )
    )
    XCTAssertTrue(
      CameraVendorWifiJoinDiagnostics.shouldAllowUnverifiedAssociation(
        requested: true,
        targetSSID: "CAMERA-DEVICE-A-003B",
        currentSSID: "CAMERA-DEVICE-A-003B"
      )
    )
  }

  func testWifiJoinDiagnosticsDoesNotRemoveExistingConfigurationBeforeJoin() {
    XCTAssertFalse(CameraVendorWifiJoinDiagnostics.shouldRemoveExistingConfigurationBeforeJoin)
  }

  func testWifiAssociationReadinessWaitsAfterManualRecoverySsidEvidence() {
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: true,
        currentWifiIP: nil
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: true,
        currentWifiIP: "192.168.0.130"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        hasConfirmedCameraNetwork: false,
        hasManualRecoveryNetworkEvidence: false,
        currentWifiIP: nil
      )
    )
  }

  func testPtpStartupPolicyAttemptsImmediatelyAfterWifiHandoffLikeAndroid() {
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: true),
      0
    )
    XCTAssertEqual(
      CameraVendorGalleryPtpStartupPolicy.startupDelaySeconds(didCompleteWifiHandoff: false),
      0
    )
  }

  func testWifiHandoffDoesNotAddExtraStabilizationDelayAfterSSIDMatchLikeAndroid() {
    XCTAssertEqual(CameraVendorWifiHandoffStabilizationPolicy.delayAfterSSIDAssociationSeconds, 0)
  }

  func testPtpConnectionStartupPolicyMatchesAndroidBoundedRetryWindow() {
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.commandConnectTimeoutSeconds, 1.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.maxAttempts, 5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 1), 0.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 2), 1.0)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 3), 1.5)
    XCTAssertEqual(CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: 4), 2.0)
    XCTAssertTrue(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 1))
    XCTAssertTrue(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 4))
    XCTAssertFalse(CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: 5))
  }

  func testPriorityDownloadReconnectUsesSameBoundedRetryWindowAsMainPtpConnect() throws {
    let source = try runnerSource("CameraVendorPtpSession.swift")
    let methodStart = try XCTUnwrap(source.range(of: "func ensureConnectedForPriorityDownload() throws")?.lowerBound)
    let methodEnd = try XCTUnwrap(
      source.range(of: "private func performStandardGalleryHandshake() throws", range: methodStart..<source.endIndex)?.lowerBound
    )
    let methodBody = String(source[methodStart..<methodEnd])

    XCTAssertTrue(methodBody.contains("CameraVendorPtpConnectionStartupPolicy.maxAttempts"))
    XCTAssertTrue(methodBody.contains("CameraVendorPtpConnectionStartupPolicy.retryDelaySeconds(afterFailedAttempt: attempt)"))
    XCTAssertTrue(methodBody.contains("CameraVendorPtpConnectionStartupPolicy.shouldRetry(afterFailedAttempt: attempt)"))
    XCTAssertTrue(methodBody.contains("PTP_PRIORITY_DOWNLOAD_RECONNECT_RETRY"))
    XCTAssertTrue(methodBody.contains("Thread.sleep(forTimeInterval: delay)"))
  }

  func testSearchModeDescRetryPolicyOnlyRetriesBusyResponse() {
    let busy = NSError(domain: "CameraVendorPtpSession", code: 0x2019)
    let unsupported = NSError(domain: "CameraVendorPtpSession", code: 0x2005)
    let otherDomain = NSError(domain: "Other", code: 0x2019)

    XCTAssertTrue(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: busy))
    XCTAssertFalse(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: unsupported))
    XCTAssertFalse(CameraVendorSearchModeDescRetryPolicy.shouldRetry(error: otherDomain))
    XCTAssertEqual(CameraVendorSearchModeDescRetryPolicy.maxAttempts, 3)
    XCTAssertEqual(CameraVendorSearchModeDescRetryPolicy.retryDelaySeconds(afterFailedAttempt: 2), 1.0)
  }

  func testInitialCatalogBootstrapRecoveryIsLimitedToStoreNotAvailable() {
    let storeNotAvailable = NSError(domain: "CameraVendorPtpSession", code: 0x2013)
    let busy = NSError(domain: "CameraVendorPtpSession", code: 0x2019)
    let socketFailure = NSError(domain: "CameraVendorPtpSocket", code: 8)

    XCTAssertTrue(CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: storeNotAvailable))
    XCTAssertFalse(CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: busy))
    XCTAssertFalse(CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: socketFailure))
  }

  func testSpecifiedObjectSnapshotPolicyDoesNotResetSearchModeOnColdStart() {
    XCTAssertFalse(CameraVendorSpecifiedObjectSnapshotPolicy.shouldCompareBeforeAndAfterEmptySearchMode)
  }

  func testTerminalProductionDoesNotContainHEIFExperimentHarness() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let productionFiles = [
      "Runner/CameraCore/Gallery/CameraVendorCatalogExperimentMatrix.swift",
      "Runner/CameraCore/Gallery/CameraVendorCatalogExperimentRunner.swift",
      "Runner/CameraCore/Gallery/CameraVendorCatalogExperimentDebugEntryPoint.swift",
    ]
    for relativePath in productionFiles {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path),
        relativePath
      )
    }
    let project = try String(
      contentsOf: root.appendingPathComponent("Runner.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    XCTAssertFalse(project.contains("CameraVendorCatalogExperiment"))
  }

  func testTerminalProductionDoesNotContainDownloadExperimentHarnesses() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let vendor = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let background = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraSessionBackgroundSupervisor.swift"),
      encoding: .utf8
    )
    let runtime = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraSessionRuntime.swift"),
      encoding: .utf8
    )

    for token in [
      "CameraVendorOriginalDownloadExecutorExperiment",
      "--camtransfer-original-download-executor=",
      "PTP_DOWNLOAD_EXECUTOR_EXPERIMENT_",
    ] {
      XCTAssertFalse(vendor.contains(token), token)
    }
    for token in [
      "CameraVendorDownloadTransferStateExperiment",
      "CameraSessionRuntimeDownloadAdmissionExperimentRunning",
      "PTP_DOWNLOAD_TRANSFER_STATE_EXPERIMENT_",
      "download-transfer-state-experiment",
    ] {
      XCTAssertFalse(background.contains(token), token)
    }
    XCTAssertFalse(runtime.contains("runDownloadAdmissionExperimentIfEnabled"))
  }

  func testOriginalDownloadProductionSurfaceContainsNoExperimentEntryPoints() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let relativeFiles = [
      "Runner/CameraVendorBluetoothService.swift",
      "Runner/CameraVendorGalleryMainlineSessionLoader.swift",
      "Runner/CameraVendorOriginalTransferWorker.swift",
      "Runner/CameraVendorPtpSession.swift",
      "Runner/CameraVendorPtpSocket.swift",
      "Runner/CameraVendorRealtimeGalleryService.swift",
      "Runner/CameraSessionTransferExecutor.swift",
      "Runner/CameraSessionRuntime.swift",
      "Runner/CameraSessionBackgroundSupervisor.swift",
    ]
    let sources = try relativeFiles.reduce(into: [String: String]()) { result, relativePath in
      result[relativePath] = try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
      )
    }
    let forbiddenTokens = [
      "--camtransfer-debug-raw-probe=",
      "--camtransfer-debug-format-speed-probe=",
      "--camtransfer-debug-readimage-admission=",
      "--camtransfer-debug-readimage-receive=",
      "--camtransfer-original-transfer-state-matrix=",
      "--camtransfer-download-thermal-experiment=",
      "CameraVendorDownloadThermalExperiment",
      "CameraVendorOriginalTransferStateMatrix",
      "runDebugFormatSpeedProbeIfEnabled",
      "runDebugRawBulkProbeIfEnabled",
      "performDebugReadImageAdmission",
      "startOriginalTransferStateMatrixIfEnabled",
      "notifyOriginalTransferStateMatrixLifecycleEvent",
    ]
    for (relativePath, source) in sources {
      for token in forbiddenTokens {
        XCTAssertFalse(source.contains(token), "\(relativePath) still contains \(token)")
      }
    }

    let productionSource = sources.values.joined(separator: "\n")
    XCTAssertTrue(productionSource.contains("PTP_PRIORITY_DOWNLOAD_BATCH_BEGIN"))
    XCTAssertTrue(productionSource.contains("PTP_DOWNLOAD_D235_PROFILE"))
    XCTAssertTrue(productionSource.contains("executor=original-read-image"))
    XCTAssertTrue(productionSource.contains("withExclusiveDownloadWindow"))
  }

  func testDebugPtpNetworkServicePolicyDefaultsToCurrentWithoutArgument() {
    XCTAssertEqual(
      CameraVendorDebugPtpNetworkServicePolicy.resolve(
        arguments: [],
        debugBuild: true
      ),
      .current
    )
  }

  func testDebugPtpNetworkServicePolicyIgnoresArgumentOutsideDebugBuild() {
    XCTAssertEqual(
      CameraVendorDebugPtpNetworkServicePolicy.resolve(
        arguments: ["--camtransfer-debug-ptp-network-service=responsive-data"],
        debugBuild: false
      ),
      .current
    )
  }

  func testDebugPtpNetworkServicePolicyEnablesResponsiveDataOnlyForExactArgument() {
    XCTAssertEqual(
      CameraVendorDebugPtpNetworkServicePolicy.resolve(
        arguments: ["--camtransfer-debug-ptp-network-service=responsive-data"],
        debugBuild: true
      ),
      .responsiveData
    )
    XCTAssertEqual(
      CameraVendorDebugPtpNetworkServicePolicy.resolve(
        arguments: ["--camtransfer-debug-ptp-network-service=unknown"],
        debugBuild: true
      ),
      .current
    )
  }

  func testPtpResponsiveDataProfileIsIsolatedAndAppliedBeforeConnect() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift", "CameraVendorPtpSession.swift")
    XCTAssertTrue(source.contains("CameraVendorDebugPtpNetworkServicePolicy"))
    XCTAssertTrue(source.contains("--camtransfer-debug-ptp-network-service=responsive-data"))
    XCTAssertTrue(source.contains("SO_NET_SERVICE_TYPE"))
    XCTAssertTrue(source.contains("NET_SERVICE_TYPE_RD"))
    XCTAssertTrue(source.contains("PTP_NETWORK_SERVICE_PROFILE"))
    XCTAssertTrue(source.contains("guard networkServiceProfile == .responsiveData else { return }"))

    let socketStart = try XCTUnwrap(source.range(of: "final class CameraVendorPtpSocket")?.lowerBound)
    let socketEnd = try XCTUnwrap(source.range(of: "final class CameraVendorPtpDownloadCancellation")?.lowerBound)
    let socketSource = String(source[socketStart..<socketEnd])
    let profileApply = try XCTUnwrap(socketSource.range(of: "try applyNetworkServiceProfile")?.lowerBound)
    let tcpConnect = try XCTUnwrap(socketSource.range(of: "Darwin.connect")?.lowerBound)
    XCTAssertLessThan(profileApply, tcpConnect)

    let sessionConnectStart = try XCTUnwrap(source.range(of: "func connect(\n    host: String = CameraVendorPtpConstants.defaultHost")?.lowerBound)
    let sessionConnectEnd = try XCTUnwrap(source.range(of: "private func performInitHandshake", range: sessionConnectStart..<source.endIndex)?.lowerBound)
    let sessionConnectSource = String(source[sessionConnectStart..<sessionConnectEnd])
    XCTAssertTrue(sessionConnectSource.contains("networkServiceProfile: networkServiceProfile"))

    let initStart = sessionConnectEnd
    let initEnd = try XCTUnwrap(source.range(of: "private func sendInitCommandRequest", range: initStart..<source.endIndex)?.lowerBound)
    let initSource = String(source[initStart..<initEnd])
    XCTAssertTrue(initSource.contains("networkServiceProfile: networkServiceProfile"))
  }

  // MARK: - Socket Buffer Profile Experiment Tests

  func testSocketBufferPolicyDefaultsToKernelAutotuningWithoutArgument() {
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: [],
        debugBuild: true
      ),
      .kernelAutotuning
    )
  }

  func testSocketBufferPolicyIgnoresArgumentOutsideDebugBuild() {
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=production"],
        debugBuild: false
      ),
      .kernelAutotuning
    )
  }

  func testSocketBufferPolicyResolvesAllValidProfiles() {
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=kernel-autotuning"],
        debugBuild: true
      ),
      .kernelAutotuning
    )
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=xapp-window-match"],
        debugBuild: true
      ),
      .xappWindowMatch
    )
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=minimal"],
        debugBuild: true
      ),
      .minimal
    )
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=production"],
        debugBuild: true
      ),
      .production
    )
  }

  func testSocketBufferPolicyFallsBackToKernelAutotuningForUnknownValue() {
    XCTAssertEqual(
      CameraVendorDebugPtpSocketBufferPolicy.resolve(
        arguments: ["--camtransfer-debug-socket-buffer=unknown-value"],
        debugBuild: true
      ),
      .kernelAutotuning
    )
  }

  func testSocketBufferProfileReturnsCorrectBufferValues() {
    // production: 2 MiB
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.production.receiveBufferBytes, 2 * 1024 * 1024)
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.production.sendBufferBytes, 2 * 1024 * 1024)

    // kernelAutotuning: nil (skip setsockopt)
    XCTAssertNil(CameraVendorPtpSocketBufferProfile.kernelAutotuning.receiveBufferBytes)
    XCTAssertNil(CameraVendorPtpSocketBufferProfile.kernelAutotuning.sendBufferBytes)

    // xappWindowMatch: only the receive window changes; request traffic keeps
    // the production 2 MiB send buffer so the experiment remains single-variable.
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.xappWindowMatch.receiveBufferBytes, 256 * 1024)
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.xappWindowMatch.sendBufferBytes, 2 * 1024 * 1024)

    // minimal: 64 KiB
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.minimal.receiveBufferBytes, 64 * 1024)
    XCTAssertEqual(CameraVendorPtpSocketBufferProfile.minimal.sendBufferBytes, 64 * 1024)
  }

  func testSocketBufferProfileIsPassedToSocketConnect() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift", "CameraVendorPtpSession.swift")

    // Verify the socket buffer profile is declared and resolved in the session.
    XCTAssertTrue(source.contains("CameraVendorDebugPtpSocketBufferPolicy"))
    XCTAssertTrue(source.contains("--camtransfer-debug-socket-buffer="))
    XCTAssertTrue(source.contains("PTP_SOCKET_BUFFER_PROFILE"))

    // Verify the socket connect method accepts the buffer profile parameter.
    let socketStart = try XCTUnwrap(source.range(of: "final class CameraVendorPtpSocket")?.lowerBound)
    let socketEnd = try XCTUnwrap(source.range(of: "final class CameraVendorPtpDownloadCancellation")?.lowerBound)
    let socketSource = String(source[socketStart..<socketEnd])
    XCTAssertTrue(socketSource.contains("socketBufferProfile: CameraVendorPtpSocketBufferProfile"))
    XCTAssertTrue(socketSource.contains("socketBufferProfile.receiveBufferBytes"))
    XCTAssertTrue(socketSource.contains("socketBufferProfile.sendBufferBytes"))
    XCTAssertTrue(socketSource.contains("actualRcv="))
    XCTAssertTrue(socketSource.contains("actualSnd="))

    // Verify the session connect passes the profile through.
    let sessionConnectStart = try XCTUnwrap(source.range(of: "func connect(\n    host: String = CameraVendorPtpConstants.defaultHost")?.lowerBound)
    let sessionConnectEnd = try XCTUnwrap(source.range(of: "private func performInitHandshake", range: sessionConnectStart..<source.endIndex)?.lowerBound)
    let sessionConnectSource = String(source[sessionConnectStart..<sessionConnectEnd])
    XCTAssertTrue(sessionConnectSource.contains("socketBufferProfile: socketBufferProfile"))
  }

  func testMainlineHasOneCatalogOwnerAndNoBorrowedSession() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let catalogRuntimeSource = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift"),
      encoding: .utf8
    )
    XCTAssertFalse(source.contains("borrowed:"))
    XCTAssertFalse(source.contains("runActiveHEIFExperiment"))
    XCTAssertFalse(source.contains("runActiveCatalogExperiment"))
    XCTAssertTrue(catalogRuntimeSource.contains("actor CameraGalleryCatalogRuntime"))
  }

  func testPhysicalSessionEvidenceAllowsZeroConnectionNumber() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(source.range(of: "var physicalSessionID: String?")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "func configureTransferProfile", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("guard isConnected"))
    XCTAssertFalse(body.contains("connectionNumber > 0"))
  }

  func testProductionGalleryHandshakeDeclaresCapturedXAppD212Order() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let orderedMarkers = [
      "PTP_FACTORY_D212_1",
      "referenceApp-remote-image-viewer",
      "PTP_FACTORY_D212_2",
      "PTP_GALLERY_BOOTSTRAP_9054",
      "PTP_GALLERY_BOOTSTRAP_9055",
      "PTP_GALLERY_BOOTSTRAP_9050",
      "PTP_GALLERY_BOOTSTRAP_D22B",
      "PTP_FACTORY_D212_3",
      "PTP_INITIAL_CAMERA_CATALOG_9053",
      "PTP_FACTORY_D212_4",
      "PTP_INITIAL_CAMERA_CATALOG_D620",
      "PTP_INITIAL_CAMERA_CATALOG_D621",
    ]
    var searchStart = source.startIndex
    for marker in orderedMarkers {
      let range = try XCTUnwrap(source.range(of: marker, range: searchStart..<source.endIndex), marker)
      searchStart = range.upperBound
    }
  }

  func testOriginalFilePreparationMatchesXAppD226ObjectInfoD235OrderAndDoesNotSilenceD235() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(source.range(of: "func objectFile(")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "private func withSerializedCommand", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])
    let d226 = try XCTUnwrap(body.range(of: "prepareDownloadModeForPriorityBatch"))
    let objectInfo = try XCTUnwrap(
      body.range(of: "let freshInfo = try objectInfo(", range: d226.upperBound..<body.endIndex)
    )
    _ = try XCTUnwrap(
      body.range(of: "mergingMissingDownloadMetadata", range: objectInfo.upperBound..<body.endIndex)
    )
    let d235 = try XCTUnwrap(
      body.range(of: "CameraVendorDevicePropCode.compressionCutOff", range: objectInfo.upperBound..<body.endIndex)
    )
    _ = try XCTUnwrap(body.range(of: "readObjectByPartialObjectsToFile", range: d235.upperBound..<body.endIndex))
    XCTAssertFalse(body.contains("EventsList before file download"))
    XCTAssertFalse(body.contains("try? readCameraVendorDeviceProperty"))
  }

  func testOriginalDownloadFetchesObjectInfoOnceInsideTheD226PreparationBoundary() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let runtimeSource = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift"),
      encoding: .utf8
    )
    let sessionSource = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )

    let runtimeStart = try XCTUnwrap(
      runtimeSource.range(
        of: "func downloadOriginalFile(\n    for handle: Int,\n    mode: CameraVendorTransferDownloadMode,\n    cachedInfo: CameraVendorCameraObjectInfo?"
      )?.lowerBound
    )
    let runtimeEnd = try XCTUnwrap(
      runtimeSource.range(
        of: "func fetchInitialCameraCatalog()",
        range: runtimeStart..<runtimeSource.endIndex
      )?.lowerBound
    )
    let runtimeBody = String(runtimeSource[runtimeStart..<runtimeEnd])
    XCTAssertFalse(
      runtimeBody.contains("self.session.objectInfo"),
      "the outer runtime must not issue a second ObjectInfo before objectFile"
    )
    XCTAssertTrue(runtimeBody.contains("fileResult.info"))

    let objectStart = try XCTUnwrap(sessionSource.range(of: "func objectFile(")?.lowerBound)
    let objectEnd = try XCTUnwrap(
      sessionSource.range(
        of: "private func withSerializedCommand",
        range: objectStart..<sessionSource.endIndex
      )?.lowerBound
    )
    let objectBody = String(sessionSource[objectStart..<objectEnd])
    XCTAssertEqual(
      objectBody.components(separatedBy: "let freshInfo = try objectInfo(").count - 1,
      1,
      "one fresh ObjectInfo must sit between D226 preparation and D235"
    )
  }

  func testOriginalDownloadMergesFreshObjectInfoWithCachedFieldsBeforeCreatingTheFile() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("mergingMissingDownloadMetadata"))
    XCTAssertTrue(source.contains("cachedInfo: CameraVendorCameraObjectInfo?"))
  }

  func testDownloadMetadataMergeKeepsFreshFieldsAndFillsMissingCachedFields() {
    let cached = CameraVendorCameraObjectInfo(
      handle: 7,
      storageID: 1,
      formatCode: 0xB101,
      compressedSize: 88,
      thumbCompressedSize: 4,
      filename: "DSCF0007.RAF",
      captureDate: "2026:07:19 10:00:00"
    )
    let fresh = CameraVendorCameraObjectInfo(
      handle: 7,
      storageID: 0,
      formatCode: CameraVendorCameraObjectInfo.undefinedFormatCode,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: "0x00000007",
      captureDate: ""
    )

    let merged = fresh.mergingMissingDownloadMetadata(from: cached)

    XCTAssertEqual(merged.filename, cached.filename)
    XCTAssertEqual(merged.formatCode, cached.formatCode)
    XCTAssertEqual(merged.compressedSize, cached.compressedSize)
    XCTAssertEqual(merged.captureDate, cached.captureDate)

    let resolvedFresh = CameraVendorCameraObjectInfo(
      handle: 7,
      storageID: 2,
      formatCode: 0x3801,
      compressedSize: 44,
      thumbCompressedSize: 2,
      filename: "DSCF0007.JPG",
      captureDate: "2026:07:19 11:00:00",
      orientation: 6
    )
    XCTAssertEqual(
      resolvedFresh.mergingMissingDownloadMetadata(from: cached),
      resolvedFresh
    )

    let mismatchedCached = CameraVendorCameraObjectInfo(
      handle: 8,
      storageID: 9,
      formatCode: 0xB101,
      compressedSize: 999,
      thumbCompressedSize: 9,
      filename: "OTHER.RAF",
      captureDate: "2026:07:19 12:00:00"
    )
    XCTAssertEqual(
      fresh.mergingMissingDownloadMetadata(from: mismatchedCached),
      fresh
    )
  }

  func testObjectInfoCacheResetPreventsSameHandleReuseAcrossPhysicalSessions() {
    var cache = CameraVendorObjectInfoCache()
    let previousSessionInfo = CameraVendorCameraObjectInfo(
      handle: 42,
      storageID: 1,
      formatCode: 0xB101,
      compressedSize: 42,
      thumbCompressedSize: 4,
      filename: "OLD.RAF",
      captureDate: "2026:07:18 10:00:00"
    )

    cache.store(previousSessionInfo)
    XCTAssertEqual(cache[42]?.filename, "OLD.RAF")

    cache.resetForPhysicalSession()

    XCTAssertNil(cache[42], "a handle is not a stable identity across physical PTP sessions")
  }

  func testRealtimeGalleryClearsObjectInfoCacheAtCommunicationBoundary() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift"),
      encoding: .utf8
    )
    let serviceStart = try XCTUnwrap(
      source.range(of: "final class CameraVendorRealtimeGalleryService")?.lowerBound
    )
    let serviceEnd = try XCTUnwrap(
      source.range(of: "private func currentCommunicationGeneration()", range: serviceStart..<source.endIndex)?.lowerBound
    )
    let serviceBody = String(source[serviceStart..<serviceEnd])
    let terminationStart = try XCTUnwrap(
      serviceBody.range(of: "func terminateCameraCommunication(reason: String)")?.lowerBound
    )
    let terminationBody = String(serviceBody[terminationStart...])

    XCTAssertTrue(
      terminationBody.contains("objectInfoCache.resetForPhysicalSession()"),
      "cache must be invalidated before a new physical PTP session can reuse handles"
    )
  }

  func testDownloadSizeSourceDistinguishesUnknownFreshSizeFromCachedFallback() {
    let fresh = CameraVendorDownloadSizeSourcePolicy.resolution(freshSize: 10, cachedSize: 20)
    XCTAssertEqual(fresh.size, 10)
    XCTAssertEqual(fresh.label, "fresh-object-info")

    let cached = CameraVendorDownloadSizeSourcePolicy.resolution(freshSize: 0, cachedSize: 20)
    XCTAssertEqual(cached.size, 20)
    XCTAssertEqual(cached.label, "cached-after-empty-fresh")

    let unknown = CameraVendorDownloadSizeSourcePolicy.resolution(
      freshSize: 0,
      cachedSize: Optional<UInt32>.none
    )
    XCTAssertNil(unknown.size)
    XCTAssertEqual(unknown.label, "unknown-after-empty-fresh")
  }

  func testGalleryCatalogWireRefreshesD212BeforeSpecifiedList() {
    XCTAssertTrue(CameraVendorCatalogWireRequestPolicy.shouldRefreshGalleryContextBeforeSpecifiedList)
  }


  func testCameraVendorPartialObjectRequestPolicyUsesAndroidReferenceReadSizes() {
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize, 1 * 1_024 * 1_024)
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize, 4 * 1_024 * 1_024)
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.fileDownloadReadTimeoutSeconds, 60)
  }

  func testCameraVendorPartialObjectRequestPolicyUsesEffectiveFileChunksWithSafeFallback() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
      4 * 1_024 * 1_024
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadFallbackReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(remaining: 20 * 1_024 * 1_024),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(remaining: 3 * 1_024 * 1_024),
      3 * 1_024 * 1_024
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.fileDownloadRequestSize(
        remaining: 20 * 1_024 * 1_024,
        useFallback: true
      ),
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
  }

  func testAdaptiveDownloadChunkPolicyIsDisabledForAndroidParity() {
    XCTAssertFalse(CameraVendorAdaptiveDownloadChunkPolicy.isEnabled)
    XCTAssertEqual(CameraVendorAdaptiveDownloadChunkPolicy.strategyName, "android-fixed-4mb")
  }

  func testAdaptiveDownloadChunkPolicyKeepsStableEffectiveFileChunks() {
    var state = CameraVendorAdaptiveDownloadChunkState()

    XCTAssertEqual(
      CameraVendorAdaptiveDownloadChunkPolicy.requestSize(remaining: 3 * 1_024 * 1_024, state: state),
      3 * 1_024 * 1_024
    )

    XCTAssertEqual(
      CameraVendorAdaptiveDownloadChunkPolicy.requestSize(remaining: 20 * 1_024 * 1_024, state: state),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )

    CameraVendorAdaptiveDownloadChunkPolicy.recordChunk(
      byteCount: 4 * 1_024 * 1_024,
      elapsedMs: 12_000,
      state: &state
    )

    XCTAssertEqual(state.readSize, CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize)
  }

  func testUnscopedTransferChunkProfileRetainsObservedMaximum() {
    for format in ["RAW", "JPEG", "HEIF"] {
      XCTAssertEqual(
        CameraVendorTransferChunkProfile.preferredReadSize(cachedReadSize: nil),
        0x00BFFFE0,
        "Expected 12 MiB maximum for \(format) original transfer"
      )
    }
    XCTAssertEqual(
      CameraVendorTransferChunkProfile.preferredReadSize(
        cachedReadSize: 4 * 1_024 * 1_024
      ),
      4 * 1_024 * 1_024
    )
    XCTAssertEqual(
      CameraVendorTransferChunkProfile.requestSize(
        remaining: 4_634_423,
        selectedReadSize: 0x00BFFFE0
      ),
      4_634_423
    )
    XCTAssertEqual(
      CameraVendorTransferChunkProfile.fallbackReadSize(after: 0x00BFFFE0),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )
    XCTAssertEqual(
      CameraVendorTransferChunkProfile.fallbackReadSize(
        after: CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
      ),
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertNil(
      CameraVendorTransferChunkProfile.fallbackReadSize(
        after: CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
      )
    )
  }

  func testOriginalReadImageExecutorFallsBackToFourMegabytesWhenD235IsUnavailable() {
    XCTAssertEqual(
      CameraVendorOriginalReadImageExecutorPolicy.initialReadSize(
        cachedReadSize: CameraVendorTransferChunkProfile.maximumReadSize,
        negotiatedReadSize: nil
      ),
      CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize
    )
  }

  func testOriginalReadImageExecutorUsesNegotiatedD235BeforeCachedProfile() throws {
    let source = try runnerSource(
      "CameraVendorOriginalTransferWorker.swift",
      "CameraVendorPtpSession.swift"
    )

    XCTAssertTrue(source.contains("static func negotiatedReadSize(from data: Data) -> UInt32?"))
    XCTAssertTrue(source.contains("let compressionCutOffData = try readCameraVendorDeviceProperty"))
    XCTAssertTrue(source.contains("negotiatedReadSize: CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize"))
    XCTAssertTrue(source.contains("PTP_DOWNLOAD_REQUEST_PROFILE"))
    XCTAssertTrue(source.contains("dedicatedProfileSource"))
  }

  func testD235ReadSizePolicyAcceptsOnlyEvidenceBackedProfiles() {
    XCTAssertEqual(
      CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(
        from: Data([0xE0, 0xFF, 0xBF, 0x00])
      ),
      0x00BFFFE0
    )
    XCTAssertEqual(
      CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(
        from: Data([0x00, 0x00, 0x40, 0x00])
      ),
      0x00400000
    )
    XCTAssertEqual(
      CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(
        from: Data([0x00, 0x00, 0x10, 0x00])
      ),
      0x00100000
    )
    XCTAssertNil(
      CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(
        from: Data([0x00, 0x00, 0x80, 0x00])
      )
    )
    XCTAssertNil(
      CameraVendorOriginalReadImageExecutorPolicy.negotiatedReadSize(
        from: Data([0xE0, 0xFF, 0xBF])
      )
    )
    XCTAssertEqual(
      CameraVendorOriginalReadImageExecutorPolicy.initialReadSize(
        cachedReadSize: CameraVendorPartialObjectRequestPolicy.fileDownloadReadSize,
        negotiatedReadSize: CameraVendorTransferChunkProfile.maximumReadSize
      ),
      CameraVendorTransferChunkProfile.maximumReadSize
    )
  }

  func testCurrentBuildHasOriginalTransferWorkerFingerprint() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("BUILD_MARK_20260718_ORIGINAL_TRANSFER_WORKER"))
    XCTAssertFalse(source.contains("BUILD_MARK_20260718_D212_ONCE_DOWNLOAD_EXPERIMENT"))
    XCTAssertFalse(source.contains("BUILD_MARK_20260718_D235_BLE_READ_ONCE_EXPERIMENT"))
    XCTAssertFalse(source.contains("BUILD_MARK_20260718_D235_NEGOTIATED_PROFILE"))
    XCTAssertFalse(source.contains("BUILD_MARK_20260623_IOS_ANDROID_PARITY_UI"))
  }

  func testOriginalTransferCapabilityStorePersistsVerifiedLowerMaximumForSerial() {
    let suiteName = "CameraVendorOriginalTransferCapabilityTests"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CameraVendorOriginalTransferCapabilityStore(defaults: defaults)

    XCTAssertNil(store.readSize(serialNumber: "221019F1932011003B"))
    store.persist(
      readSize: 4 * 1_024 * 1_024,
      serialNumber: "221019F1932011003B"
    )

    XCTAssertEqual(
      store.readSize(serialNumber: "221019F1932011003B"),
      4 * 1_024 * 1_024
    )
    XCTAssertNil(store.readSize(serialNumber: ""))
    XCTAssertNil(store.readSize(serialNumber: "other-camera"))
  }

  func testOriginalTransferFallbackOnlyAcceptsLivePtpResponseErrors() {
    let responseError = NSError(domain: "CameraVendorPtpSession", code: 0x2019)
    let socketError = NSError(domain: "CameraVendorPtpSocket", code: 8)

    XCTAssertTrue(
      CameraVendorTransferChunkProfile.shouldFallback(
        after: responseError,
        sessionIsConnected: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferChunkProfile.shouldFallback(
        after: socketError,
        sessionIsConnected: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferChunkProfile.shouldFallback(
        after: responseError,
        sessionIsConnected: false
      )
    )
  }

  func testOriginalTransferCapabilityPersistenceRequiresCompleteFile() {
    XCTAssertTrue(
      CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: 12_582_880,
        expectedBytes: 12_582_880,
        hasJpegEndMarker: false
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: 4_634_423,
        expectedBytes: nil,
        hasJpegEndMarker: true
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: 4_194_304,
        expectedBytes: 12_582_880,
        hasJpegEndMarker: false
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalTransferCompletionPolicy.shouldPersistCapability(
        totalBytes: 0,
        expectedBytes: 12_582_880,
        hasJpegEndMarker: false
      )
    )
  }

  func testPartialObjectRequestPolicyUsesExpectedSizeAsReadLimit() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(expectedSize: 625_558),
      625_558
    )
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.maximumReadableByteCount(expectedSize: nil),
      UInt64(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize)
    )
  }

  func testDownloadDataDiagnosticPolicyReportsHeadAndHeifFtypOffset() {
    let heifLikeHead = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8)

    XCTAssertEqual(
      CameraVendorDownloadDataDiagnosticPolicy.headHex(from: heifLikeHead, byteCount: 8),
      "0000001866747970"
    )
    XCTAssertEqual(CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: heifLikeHead), 4)
    XCTAssertNil(CameraVendorDownloadDataDiagnosticPolicy.firstFtypOffset(in: Data([0xFF, 0xD8, 0xFF])))
  }

  func testDiagnosticLogRedactorMasksPasswordsAndPassphrases() {
    let raw = """
    SSID: FUJIFILM-X-T5-003B
    密码: 12345678
    passphrase=87654321
    password: camera-secret
    """

    let redacted = CamTransferDiagnosticLogRedactor.redacted(raw)

    XCTAssertTrue(redacted.contains("SSID: FUJIFILM-X-T5-003B"))
    XCTAssertTrue(redacted.contains("密码: ********"))
    XCTAssertTrue(redacted.contains("passphrase=********"))
    XCTAssertTrue(redacted.contains("password: ********"))
    XCTAssertFalse(redacted.contains("12345678"))
    XCTAssertFalse(redacted.contains("87654321"))
    XCTAssertFalse(redacted.contains("camera-secret"))
  }

  func testDiagnosticExportPayloadIncludesMetadataAndRedactedLog() {
    let payload = CamTransferDiagnosticExportPayload.compose(
      appVersion: "1.2.3",
      buildNumber: "45",
      deviceModel: "iPhone15,3",
      systemVersion: "iOS 18.5",
      generatedAt: "2026-05-30T12:00:00Z",
      logText: "密码: 12345678\n连接失败: timeout"
    )

    XCTAssertTrue(payload.contains("CamTransfer Diagnostic Log"))
    XCTAssertTrue(payload.contains("App Version: 1.2.3 (45)"))
    XCTAssertTrue(payload.contains("Device: iPhone15,3"))
    XCTAssertTrue(payload.contains("System: iOS 18.5"))
    XCTAssertTrue(payload.contains("Generated At: 2026-05-30T12:00:00Z"))
    XCTAssertTrue(payload.contains("密码: ********"))
    XCTAssertTrue(payload.contains("连接失败: timeout"))
    XCTAssertFalse(payload.contains("12345678"))
  }

  func testCameraVendorOriginalDownloadPolicyUsesFreshHeifSizeForOriginalDownloads() {
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.expectedDownloadSize(
        formatLabel: "HEIF",
        freshCompressedSize: 16_560_640,
        cachedExpectedSize: 688_423
      ),
      16_560_640
    )
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.expectedDownloadSize(
        formatLabel: "RAW",
        freshCompressedSize: 16_560_640,
        cachedExpectedSize: 688_423
      ),
      688_423
    )
  }

  func testCameraVendorOriginalDownloadPolicyPreparesHeifTransferAndReadsFreshInfo() {
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldPrepareTransferStateBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseReferenceAppFastStartPreparation(
        formatLabel: "HEIF"
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSkipFreshFileInfoProbe(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeFreshFileInfo(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffAfterFreshFileInfo(
        formatLabel: "HEIF",
        cachedExpectedSize: 688_423
      )
    )
  }

  func testCameraVendorDownloadModePolicyMatchesAndroidOriginalAndCompressedProperties() {
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.prepareProperties(mode: .original),
      [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 2,
          width: .uint16
        )
      ]
    )
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.prepareProperties(mode: .compressed),
      [
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: 1,
          width: .uint16
        ),
        CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 1,
          width: .uint16
        )
      ]
    )
    XCTAssertEqual(
      CameraVendorDownloadModePolicy.resetProperty(
        for: CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 2,
          width: .uint16
        )
      ),
      CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 0,
        width: .uint16
      )
    )
    XCTAssertNil(
      CameraVendorDownloadModePolicy.resetProperty(
        for: CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: 1,
          width: .uint16
        )
      )
    )
  }

  func testCameraVendorThumbnailFallbackUsesSmallPreviewReadSize() {
    XCTAssertLessThan(
      CameraVendorThumbnailFetchPolicy.partialPreviewReadSize,
      CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
    )
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.partialPreviewReadSize, 256 * 1_024)
  }

  func testCameraVendorPartialObjectRequestPolicyBuildsExtensionParameters() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.extensionPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0x00000001_00000020,
        size: 0x00100000
      ),
      [
        0x000003CA,
        0x00000020,
        0x00100000,
        0x00000001,
      ]
    )
  }

  func testCameraVendorPartialObjectRequestPolicyBuildsStandardParameters() {
    XCTAssertEqual(
      CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: 0x00100000
      ),
      [
        0x000003CA,
        0x00000000,
        0x00100000,
      ]
    )
  }

  func testCameraVendorPartialObjectRequestPolicyHasFiniteUnknownSizeLimit() {
    XCTAssertEqual(CameraVendorPartialObjectRequestPolicy.maxReadBytesWithoutKnownObjectSize, 128 * 1_024 * 1_024)
  }

  func testCameraVendorJpegDataPolicyRecognizesEndMarker() {
    XCTAssertTrue(CameraVendorJpegDataPolicy.hasEndMarker(Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])))
    XCTAssertFalse(CameraVendorJpegDataPolicy.hasEndMarker(Data([0xFF, 0xD8, 0x01])))
  }

  func testCameraVendorJpegDataPolicyRecognizesStartMarker() {
    XCTAssertTrue(CameraVendorJpegDataPolicy.hasStartMarker(Data([0xFF, 0xD8, 0xFF, 0xE1])))
    XCTAssertFalse(CameraVendorJpegDataPolicy.hasStartMarker(Data([0x00, 0x00, 0xFF, 0xD8])))
  }

  func testCameraVendorPreviewImageValidationRejectsIncompleteJpegLikeAndroid() {
    let completeJpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
    let incompleteJpeg = Data([0xFF, 0xD8, 0x01, 0x02])
    let largeDecodeableIncompleteJpeg = Data([0xFF, 0xD8]) + Data(repeating: 0x01, count: 64 * 1_024)

    XCTAssertTrue(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(completeJpeg))
    XCTAssertFalse(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(incompleteJpeg))
    XCTAssertTrue(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(largeDecodeableIncompleteJpeg))
    XCTAssertTrue(CameraVendorPreviewImageValidationPolicy.shouldRejectIncompletePartialPreview(incompleteJpeg))
  }

  func testCameraVendorPreviewImageValidationRejectsUnknownHeifBrandLikeAndroid() {
    let unknownBrand = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypzzzz".utf8) + Data([0x00, 0x00])

    XCTAssertFalse(CameraVendorPreviewImageValidationPolicy.isValidPreviewImageData(unknownBrand))
  }

  func testCameraVendorPreviewImageReadPolicyMatchesAndroidChunkingAndLimit() {
    XCTAssertEqual(CameraVendorPreviewImageReadPolicy.maximumScreenPreviewBytes, 12 * 1_048_576)
    XCTAssertEqual(CameraVendorPreviewImageReadPolicy.initialReadSize, 4 * 1_048_576)
    XCTAssertEqual(CameraVendorPreviewImageReadPolicy.fallbackReadSize, 1 * 1_048_576)
    XCTAssertEqual(
      CameraVendorPreviewImageReadPolicy.requestSize(
        remaining: UInt64(10 * 1_048_576),
        selectedReadSize: CameraVendorPreviewImageReadPolicy.initialReadSize
      ),
      4 * 1_048_576
    )
    XCTAssertEqual(
      CameraVendorPreviewImageReadPolicy.requestSize(
        remaining: UInt64(512 * 1_024),
        selectedReadSize: CameraVendorPreviewImageReadPolicy.initialReadSize
      ),
      512 * 1_024
    )
    XCTAssertEqual(
      CameraVendorPreviewImageReadPolicy.fallbackReadSize(
        after: CameraVendorPreviewImageReadPolicy.initialReadSize
      ),
      CameraVendorPreviewImageReadPolicy.fallbackReadSize
    )
    XCTAssertNil(
      CameraVendorPreviewImageReadPolicy.fallbackReadSize(
        after: CameraVendorPreviewImageReadPolicy.fallbackReadSize
      )
    )
  }

  func testRawPreviewSourceUsesAdjacentSameStemHEIFCompanion() {
    let raw = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1861,
      formatCode: 0xB101,
      compressedSize: 84_304_384,
      filename: "DSCF7854.RAF"
    )
    let heif = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1862,
      formatCode: CameraVendorWirelessRealFileFormat.heif,
      compressedSize: 529_920,
      filename: "DSCF7854.HEIC"
    )

    XCTAssertEqual(
      CameraVendorPreviewImageSourcePolicy.companionCandidateHandle(for: raw),
      1862
    )
    XCTAssertEqual(
      CameraVendorPreviewImageSourcePolicy.source(
        originalInfo: raw,
        companionInfo: heif
      ),
      .compressedObject(handle: 1862, size: 529_920)
    )
  }

  func testRawPreviewSourceRejectsMismatchedCompanionMetadata() {
    let raw = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1861,
      formatCode: 0xB101,
      compressedSize: 84_304_384,
      filename: "DSCF7854.RAF"
    )
    let wrongStem = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1862,
      formatCode: CameraVendorWirelessRealFileFormat.heif,
      compressedSize: 529_920,
      filename: "DSCF7855.HEIC"
    )
    let wrongFormat = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1862,
      formatCode: 0xB103,
      compressedSize: 529_920,
      filename: "DSCF7854.RAF"
    )
    let wrongDate = CameraVendorCameraObjectInfo.previewFixture(
      handle: 1862,
      formatCode: CameraVendorWirelessRealFileFormat.heif,
      compressedSize: 529_920,
      filename: "DSCF7854.HEIC",
      captureDate: "20260802T120001"
    )

    for companion in [wrongStem, wrongFormat, wrongDate] {
      XCTAssertEqual(
        CameraVendorPreviewImageSourcePolicy.source(
          originalInfo: raw,
          companionInfo: companion
        ),
        .standardThumbnail(handle: 1861)
      )
    }
  }

  func testRawOnlyPreviewUsesStandardThumbnailWithoutReadingRawObject() {
    let raw = CameraVendorCameraObjectInfo.previewFixture(
      handle: 2416,
      formatCode: 0xB101,
      compressedSize: 86_911_488,
      filename: "DSCF8100.RAF"
    )
    let terminalRaw = CameraVendorCameraObjectInfo.previewFixture(
      handle: Int(UInt32.max),
      formatCode: 0xB101,
      compressedSize: 86_911_488,
      filename: "DSCF9999.RAF"
    )

    XCTAssertEqual(
      CameraVendorPreviewImageSourcePolicy.source(
        originalInfo: raw,
        companionInfo: nil
      ),
      .standardThumbnail(handle: 2416)
    )
    XCTAssertNil(
      CameraVendorPreviewImageSourcePolicy.companionCandidateHandle(for: terminalRaw)
    )
  }

  func testImageDataNormalizerStripsCameraVendorPrefixBeforeJpegHeader() {
    let data = Data([0x15, 0x00, 0x10, 0x00, 0xFF, 0xD8, 0xFF, 0xE1, 0x01])

    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: data), Data([0xFF, 0xD8, 0xFF, 0xE1, 0x01]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.imageData(from: data), Data([0xFF, 0xD8, 0xFF, 0xE1, 0x01]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: Data([0xFF, 0xD8, 0xAA])), Data([0xFF, 0xD8, 0xAA]))
    XCTAssertEqual(CameraVendorImageDataNormalizer.jpegData(from: Data([0x00, 0x01, 0x02])), Data([0x00, 0x01, 0x02]))
  }

  func testImageDataNormalizerStripsCameraVendorPrefixBeforeHeifFtypBox() {
    let heif = Data([
      0xAA, 0xBB, 0xCC,
      0x00, 0x00, 0x00, 0x18,
      0x66, 0x74, 0x79, 0x70,
      0x68, 0x65, 0x69, 0x63,
      0x00, 0x00,
    ])

    XCTAssertEqual(
      CameraVendorImageDataNormalizer.imageData(from: heif),
      Data([
        0x00, 0x00, 0x00, 0x18,
        0x66, 0x74, 0x79, 0x70,
        0x68, 0x65, 0x69, 0x63,
        0x00, 0x00,
      ])
    )
  }

  func testImageDataNormalizerRecognizesAndroidVerifiedHeifBrands() {
    for brand in ["heic", "heix", "hevc", "hevx", "heis", "hevm", "heif", "mif1", "msf1"] {
      let prefixedHeif = Data([0xAA, 0xBB, 0xCC]) +
        Data([0x00, 0x00, 0x00, 0x18]) +
        Data("ftyp".utf8) +
        Data(brand.utf8) +
        Data([0x00, 0x00])

      XCTAssertEqual(
        CameraVendorImageDataNormalizer.imageData(from: prefixedHeif),
        prefixedHeif.dropFirst(3),
        "brand \(brand) should strip CameraVendor prefix before HEIF ftyp box"
      )
    }
  }

  func testGalleryPreparationPausesBeforePtpWhileWaitingForManualWifiJoin() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: false
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: true,
        isCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: true,
        prefersManualWifiRecovery: false,
        currentSSIDMatchesCamera: true,
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryPreparationPausesBeforePtpWithoutCurrentOfficialWifiCredentials() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: false,
        skippedAutoJoinBecauseManual: false,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true,
        hasCurrentWifiConfigurations: false
      )
    )
  }

  func testGalleryPreparationPausesExplicitManualRetryWithoutNetworkEvidence() {
    XCTAssertTrue(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryPreparationAllowsManualRecoveryFromCameraSubnetEvidence() {
    XCTAssertFalse(
      CameraVendorGalleryPreparationPolicy.shouldPauseBeforeStartingPTP(
        didJoinWifiAutomatically: false,
        prefersManualWifiRecovery: true,
        skippedAutoJoinBecauseManual: true,
        currentSSIDMatchesCamera: false,
        isCameraPtpReachable: true
      )
    )
  }

  func testTransferFlowRequiresExplicitUserInitiationAfterPairing() {
    XCTAssertFalse(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: false
      )
    )
    XCTAssertTrue(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true
      )
    )
  }

  func testBluetoothServiceDoesNotExposePostPairingAutoTransferPolicy() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("shouldAutomaticallyPrepareTransferAfterPairing"))
    XCTAssertFalse(source.contains("shouldStartAutoTransferBeforePhoneConfirmation"))
  }

  func testPairingCompletionDoesNotAutoPrepareTransferInsideBluetoothService() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "  private func notifyPairingCompletedIfPossible()")?.lowerBound
    )
    let end = try XCTUnwrap(
      source.range(of: "  @discardableResult\n  private func savePendingPairingRecordIfPossible()", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertFalse(body.contains("AUTO_TRANSFER_AFTER_PAIRING"))
    XCTAssertFalse(body.contains("beginPostHandshakeProbeIfNeeded"))
    XCTAssertFalse(body.contains("CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus"))
  }

  func testPairingCompletionWaitsForExplicitCameraConfirmation() {
    XCTAssertFalse(
      IOSCameraPairingConfirmationFlowDriver.canFinishPairing(
        hasWrittenIdentifier: true,
        hasUserConfirmedCameraSuccess: false
      )
    )
    XCTAssertTrue(
      IOSCameraPairingConfirmationFlowDriver.canFinishPairing(
        hasWrittenIdentifier: true,
        hasUserConfirmedCameraSuccess: true
      )
    )
  }

  func testPairingCompletionRequiresPhoneConfirmationBeforeProceeding() {
    XCTAssertTrue(
      IOSCameraPairingConfirmationFlowDriver.routeAfterIdentifierWrite(
        intent: .freshPairing,
        shouldBypassManualConfirmation: false
      ) == .waitForPhoneConfirmation
    )
  }

  func testPhonePairingConfirmationCanBeQueuedUntilCameraAckIsReady() {
    XCTAssertTrue(
      IOSCameraPairingConfirmationFlowDriver.confirmPairingSucceeded(
        hasWrittenIdentifier: false,
        hasPendingHandshakeSummary: false
      ) == .waitForCameraAck
    )
    XCTAssertFalse(
      IOSCameraPairingConfirmationFlowDriver.canCompleteQueuedPhoneConfirmation(
        hasWrittenIdentifier: false,
        hasPendingHandshakeSummary: false,
        hasQueuedPhoneConfirmation: true
      )
    )
    XCTAssertTrue(
      IOSCameraPairingConfirmationFlowDriver.canCompleteQueuedPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        hasQueuedPhoneConfirmation: true
      )
    )
  }

  func testPhonePairingConfirmationReconnectsBeforeCompletingNewPairing() {
    XCTAssertTrue(
      IOSCameraPairingConfirmationFlowDriver.routeAfterPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        shouldBypassManualConfirmation: false
      ) == .reconnectBeforeCompletion
    )
    XCTAssertFalse(
      IOSCameraPairingConfirmationFlowDriver.routeAfterPhoneConfirmation(
        hasWrittenIdentifier: true,
        hasPendingHandshakeSummary: true,
        shouldBypassManualConfirmation: true
      ) == .reconnectBeforeCompletion
    )
  }

  func testHomeScreenWaitsForExplicitPairingWhenNoRememberedCamera() {
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldStartScanningOnLaunch(
        hasRememberedCamera: false
      )
    )
  }

  func testHomeScreenValidatesRememberedCameraOnLaunchWhileKeepingCardVisible() {
    XCTAssertTrue(
      NativeCameraSearchStartupPolicy.shouldStartScanningOnLaunch(
        hasRememberedCamera: true
      )
    )
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldHideRememberedCameraWhileScanning(
        hasRememberedCamera: true
      )
    )
  }

  func testHomeScreenShowsInlineDiscoveredCamerasAndRemovesManualAddButton() {
    XCTAssertTrue(
      NativeCameraSearchStartupPolicy.shouldShowInlineDiscoveredCameraList(
        discoveredCameraCount: 1
      )
    )
    XCTAssertFalse(
      NativeCameraSearchStartupPolicy.shouldShowInlineDiscoveredCameraList(
        discoveredCameraCount: 0
      )
    )
    XCTAssertFalse(NativeCameraSearchStartupPolicy.shouldShowManualAddCameraButton)
  }

  func testHomeScreenRestartsDiscoveryAfterDeletingRememberedCamera() {
    XCTAssertTrue(NativeCameraSearchStartupPolicy.shouldRestartScanningAfterRememberedCameraDeletion)
  }

  func testRememberedReconnectPolicyStopsAtReconnectPairedBleWhenTargetIsNotFound() {
    XCTAssertFalse(CameraVendorRememberedReconnectPolicy.shouldStartNormalDiscoveryAfterTargetTimeout)
  }

  func testRememberedReconnectPolicyDoesNotTrustSystemRetrievedPeripheralBeforeScanning() {
    XCTAssertFalse(CameraVendorRememberedReconnectPolicy.shouldTrySystemRetrievedPeripheralBeforeScanning)
  }

  func testPairingConfirmationStatusRequiresVisiblePrompt() {
    XCTAssertTrue(
      NativePairingConfirmationPresentationPolicy.shouldPresentPhoneConfirmationPrompt(
        status: CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus,
        isBusy: false
      )
    )
    XCTAssertFalse(
      NativePairingConfirmationPresentationPolicy.shouldPresentPhoneConfirmationPrompt(
        status: CameraVendorCameraPairingConfirmationPolicy.waitingForPhoneConfirmationStatus,
        isBusy: true
      )
    )
  }

  func testPairingSuccessCleanupDismissesPairingUiAfterSuccessCallbacks() {
    XCTAssertTrue(
      NativePairingSuccessCleanupPolicy.shouldDismissPairingUI(
        event: .didCompletePairing
      )
    )
    XCTAssertTrue(
      NativePairingSuccessCleanupPolicy.shouldDismissPairingUI(
        event: .didCompleteHandshake
      )
    )
  }

  func testTransferFlowRequiresExplicitGalleryEntryAfterPairing() {
    XCTAssertFalse(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: false,
        hasUserInitiatedTransfer: true
      )
    )
    XCTAssertFalse(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: false
      )
    )
    XCTAssertTrue(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true
      )
    )
  }

  func testTransferActivationEntryStatusDoesNotClaimWifiIsStillOpening() {
    XCTAssertEqual(CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus, "正在进入相机相册")
    XCTAssertFalse(CameraVendorTransferActivationStatusTextPolicy.enteringGalleryStatus.contains("打开相机 Wi"))
  }

  func testGalleryEntryNavigationWaitsForPreloadBeforeEnteringAlbumPage() {
    XCTAssertTrue(
      NativeGalleryEntryNavigationPolicy.shouldEnterGalleryAfterPreload(fetchSucceeded: true)
    )
    XCTAssertFalse(
      NativeGalleryEntryNavigationPolicy.shouldEnterGalleryAfterPreload(fetchSucceeded: false)
    )
    XCTAssertFalse(NativeGalleryEntryNavigationPolicy.preloadingStatus.contains("等待相机 Wi-Fi"))
    XCTAssertFalse(NativeGalleryEntryNavigationPolicy.waitingForWifiStatus.contains("Wi-Fi"))
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.waitingForWifiStatus.contains("相册"))
  }

  func testGalleryEntryNavigationPushesGalleryBeforeCleanupToAvoidHomeFlash() {
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.shouldPushGalleryBeforeDismissingPairingUI)
    XCTAssertTrue(NativeGalleryEntryNavigationPolicy.shouldHideConnectingOverlayAfterGalleryPush)
  }

  func testGalleryEntryCoordinatorAcceptsEstablishedPTPSessionBeforeCatalogLoads() async throws {
    let coordinator = IOSCameraGalleryEntryCoordinator()
    let session = try coordinator.validate(
      IOSCameraGallerySession(
        cameraID: "stub",
        ptpSessionID: "stub-ptp"
      )
    )

    XCTAssertEqual(session.ptpSessionID, "stub-ptp")
  }

  func testGalleryEntryCoordinatorLivesInCameraCoreOrchestrationModule() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let bluetoothServiceSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let coordinatorSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraCore/Orchestration/CameraGalleryEntryCoordinator.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(bluetoothServiceSource.contains("final class IOSCameraGalleryEntryCoordinator"))
    XCTAssertTrue(coordinatorSource.contains("final class IOSCameraGalleryEntryCoordinator"))
  }

  func testGalleryPageDoesNotRestartGalleryStartupProtocolAfterEntry() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])

    XCTAssertFalse(galleryPage.contains("CameraVendorGalleryStartupCoordinator"))
    XCTAssertFalse(galleryPage.contains("loadGalleryReadyEvidence("))
    XCTAssertFalse(galleryPage.contains(".fetchGallery("))
  }

  func testNativeTransferSizeSettingPolicyMapsHomeChipSelection() {
    XCTAssertEqual(
      NativeTransferSizeSettingPolicy.selectedID(preferCompressedDownloads: false),
      NativeTransferSizeSettingPolicy.originalID
    )
    XCTAssertEqual(
      NativeTransferSizeSettingPolicy.selectedID(preferCompressedDownloads: true),
      NativeTransferSizeSettingPolicy.compressedID
    )
    XCTAssertFalse(
      NativeTransferSizeSettingPolicy.preferCompressedDownloads(
        for: NativeTransferSizeSettingPolicy.originalID
      )
    )
    XCTAssertTrue(
      NativeTransferSizeSettingPolicy.preferCompressedDownloads(
        for: NativeTransferSizeSettingPolicy.compressedID
      )
    )
  }

  func testNativeTransferSizeSettingPolicyMapsSwitchState() {
    XCTAssertFalse(NativeTransferSizeSettingPolicy.switchIsOn(preferCompressedDownloads: false))
    XCTAssertTrue(NativeTransferSizeSettingPolicy.switchIsOn(preferCompressedDownloads: true))
    XCTAssertFalse(NativeTransferSizeSettingPolicy.preferCompressedDownloads(forSwitchIsOn: false))
    XCTAssertTrue(NativeTransferSizeSettingPolicy.preferCompressedDownloads(forSwitchIsOn: true))
  }

  func testNativeTransferSizeSettingPolicyUsesCompactSwitchLabels() {
    XCTAssertEqual(NativeTransferSizeSettingPolicy.originalLabelText, "原图")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.compressedLabelText, "压缩")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.originalSymbolName, "photo")
    XCTAssertEqual(NativeTransferSizeSettingPolicy.compressedSymbolName, "bolt.fill")
  }

  func testNativeTransferSizeSettingPolicyUsesCompactSwitchMetrics() {
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchWidth, 104)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchHeight, 40)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchLabelFontSize, 9.5)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchSymbolPointSize, 11)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchImagePlacement, .top)
    XCTAssertEqual(NativeTransferSizeSettingPolicy.switchImagePadding, 1)
  }

  func testNativeGalleryUsesCurrentBottomDownloadModeForQueuedDownloads() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
      .appendingPathComponent("NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])
    let startDownloadStart = try XCTUnwrap(galleryPage.range(of: "private func openDownloadCenter(for handles: [Int])")?.lowerBound)
    let startDownloadEnd = try XCTUnwrap(galleryPage.range(of: "\n}\nextension NativeGalleryViewController", range: startDownloadStart..<galleryPage.endIndex)?.lowerBound)
    let startDownloadBody = String(galleryPage[startDownloadStart..<startDownloadEnd])

    XCTAssertTrue(startDownloadBody.contains("currentTransferDownloadMode"))
    XCTAssertFalse(startDownloadBody.contains("summary.activeTransferDownloadMode"))
  }

  func testNativeDownloadListBackLetsRuntimeOwnGalleryNavigationAfterStop() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
      .appendingPathComponent("NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let controllerStart = try XCTUnwrap(
      source.range(of: "final class NativeDownloadListViewController")?.lowerBound
    )
    let controllerBody = String(source[controllerStart...])
    let backStart = try XCTUnwrap(
      controllerBody.range(of: "@objc private func backTapped()")?.lowerBound
    )
    let backEnd = try XCTUnwrap(
      controllerBody.range(
        of: "\n  @objc private func clearRecordsTapped()",
        range: backStart..<controllerBody.endIndex
      )?.lowerBound
    )
    let backBody = String(controllerBody[backStart..<backEnd])
    let confirmStart = try XCTUnwrap(
      backBody.range(of: "NativeDownloadCenterChrome.terminateAlertConfirmTitle")?.lowerBound
    )
    let confirmBody = String(backBody[confirmStart...])
    XCTAssertNotNil(confirmBody.range(of: "await runtime.stopDownloadAndWait()"))
    XCTAssertFalse(confirmBody.contains("navigationController?.popViewController"))
    XCTAssertTrue(backBody.contains("isStoppingForExit"))
    XCTAssertFalse(confirmBody.contains("onTerminateDownload()"))
  }

  @MainActor
  func testNativeDownloadListDisablesInteractivePopGestureWhileVisible() throws {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    let controller = NativeDownloadListViewController(
      runtime: runtime,
      itemsProvider: { [] },
      stateProvider: { _ in .idle },
      progressProvider: { _ in nil },
      isTransferActiveProvider: { false },
      onClearDownloadCache: { _ in }
    )
    let navigationController = UINavigationController(rootViewController: UIViewController())
    navigationController.pushViewController(controller, animated: false)
    controller.loadViewIfNeeded()
    let popGesture = try XCTUnwrap(navigationController.interactivePopGestureRecognizer)
    popGesture.isEnabled = true

    controller.beginAppearanceTransition(true, animated: false)
    controller.endAppearanceTransition()
    XCTAssertFalse(popGesture.isEnabled)

    controller.beginAppearanceTransition(false, animated: false)
    controller.endAppearanceTransition()
    XCTAssertTrue(popGesture.isEnabled)
  }

  func testGalleryReloadPolicyDoesNotRetryFromGalleryPageAfterFailure() {
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.3.28",
        baselineWifiIP: "192.168.3.28"
      )
    )
  }

  func testGalleryReloadPolicyDoesNotRetryWhileAlreadyLoadingOrWhenGalleryExists() {
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 0,
        isLoading: true,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28"
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryReloadPolicy.shouldRetryWhenAppBecomesActive(
        itemCount: 3,
        isLoading: false,
        errorMessage: "无法读取相机图库",
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28"
      )
    )
  }

  func testGalleryLoadPolicyBlocksConcurrentLoads() {
    XCTAssertTrue(CameraVendorGalleryLoadPolicy.shouldStartLoad(isLoading: false))
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldStartLoad(isLoading: true))
  }

  func testGalleryLoadPolicyRequiresVerifiedConnectionHandoffForManualReload() {
    XCTAssertTrue(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.0.122",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.0.122",
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: "192.168.3.28",
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAllowManualReload(
        currentWifiIP: nil,
        hasVerifiedConnectionHandoff: true
      )
    )
  }

  func testGalleryLoadPolicyDoesNotStartFromGalleryIpAlone() {
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldLoadAutomaticallyOnEntry)
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldRetryAutomaticallyWhenAppBecomesActive)
    XCTAssertFalse(CameraVendorGalleryLoadPolicy.shouldLoadOnEntry(hasVerifiedConnectionHandoff: true))
  }

  func testGalleryLoadPolicyNeverAutoLoadsFromGalleryPageLifecycle() {
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: false
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.3.28",
        baselineWifiIP: "192.168.3.28",
        itemCount: 0,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorGalleryLoadPolicy.shouldAutoLoadWhenCameraWifiReady(
        currentWifiIP: "192.168.0.122",
        baselineWifiIP: "192.168.3.28",
        itemCount: 2,
        isLoading: false,
        hasVerifiedConnectionHandoff: true
      )
    )
  }

  func testGalleryPtpReadinessWaitsForCameraIPv4AfterAutomaticWifiJoin() {
    XCTAssertEqual(CameraVendorWifiAssociationReadinessPolicy.maxWaitSeconds, 8)
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: nil
      )
    )
    XCTAssertTrue(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: "192.168.3.28"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: true,
        currentWifiIP: "192.168.0.28"
      )
    )
    XCTAssertFalse(
      CameraVendorWifiAssociationReadinessPolicy.shouldWaitForCameraIPv4Address(
        didJoinWifiAutomatically: false,
        currentWifiIP: nil
      )
    )
  }

  func testGalleryMainLoadLifecycleTerminatesCameraCommunicationWhenLeavingGallery() {
    XCTAssertTrue(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: true,
        hasActiveGalleryLoadTask: true
      )
    )
    XCTAssertFalse(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: false,
        hasActiveGalleryLoadTask: true
      )
    )
    XCTAssertFalse(
      NativeGalleryMainLoadLifecyclePolicy.shouldTerminateCameraCommunication(
        isLeavingGallery: true,
        hasActiveGalleryLoadTask: false
      )
    )
  }

  func testGalleryExitPolicyRequiresConfirmationBeforeTerminatingCameraCommunication() {
    XCTAssertTrue(
      NativeGalleryExitPolicy.shouldConfirmBeforeLeaving(
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryExitPolicy.shouldConfirmBeforeLeaving(
        hasActiveCameraCommunication: false
      )
    )
    XCTAssertFalse(
      NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
        hasActiveCameraCommunication: true,
        userConfirmedExit: false
      )
    )
    XCTAssertTrue(
      NativeGalleryExitPolicy.shouldTerminateCameraCommunication(
        hasActiveCameraCommunication: true,
        userConfirmedExit: true
      )
    )
  }

  func testGalleryRuntimeOwnershipDoesNotReleaseActiveDownloadForGalleryTeardown() {
    XCTAssertFalse(
      NativeGalleryRuntimeOwnershipPolicy.shouldReleaseRuntimeForGalleryTeardown(
        hasDurableActiveDownloadSession: true
      )
    )
    XCTAssertTrue(
      NativeGalleryRuntimeOwnershipPolicy.shouldReleaseRuntimeForGalleryTeardown(
        hasDurableActiveDownloadSession: false
      )
    )
  }

  func testCameraVendorGalleryDiagnosticsUsesFilteredRollingWriterOnly() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "enum CameraVendorGalleryDiagnostics")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "enum CameraVendorGalleryPreparationPolicy", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("CameraVendorFastDiagnosticLogPolicy.shouldWriteToDisk"))
    XCTAssertTrue(body.contains("CameraVendorFileLogger.log"))
    XCTAssertFalse(body.contains("appendToFile"))
  }

  func testGalleryUIDiagnosticsUseSingleFastDeviceLogWriter() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let appendStart = try XCTUnwrap(source.range(of: "private func appendDiagnostic(")?.lowerBound)
    let appActiveStart = try XCTUnwrap(
      source.range(of: "@objc private func appDidBecomeActive()", range: appendStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[appendStart..<appActiveStart])

    XCTAssertTrue(body.contains("CameraVendorFileLogger.log(\"UI: \\(message)\""))
    XCTAssertFalse(body.contains("CameraVendorGalleryDiagnostics.log(\"UI: \\(message)\""))
    XCTAssertTrue(body.contains("NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(message)"))
  }

  func testNativeGalleryDownloadDiagnosticLogPolicyKeepsDownloadPerformanceSummaries() {
    XCTAssertTrue(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(
        "[主通道] 下载传输完成 handle=1844 source=data-fast-path bytes=16799232 transferMs=3200 speedMBps=5.0，加入保存队列"
      )
    )
    XCTAssertTrue(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile(
        "[保存] 完成 handle=1844 source=data-fast-path transferMs=3200 saveQueueDelayMs=0 saveMs=900 totalMs=4100 speedMBps=5.0"
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadDiagnosticLogPolicy.shouldWriteToFile("下载进行中，暂停缩略图加载 handle=1844")
    )
  }

  func testOriginalDownloadTimingSummaryContainsEveryRequiredBoundary() {
    let timing = CameraVendorOriginalFileTransferTiming(
      byteCount: 86_801_408,
      prepareMs: 310,
      requestToFirstByteMs: 221,
      socketReceiveMs: 17_704,
      fileWriteMs: 218,
      commandGapMs: 48,
      transferMs: 18_501
    )

    let message = CameraVendorOriginalDownloadTimingLogPolicy.completedMessage(
      handle: 0x95A,
      filename: "DSCF8121.RAF",
      mode: .original,
      timing: timing,
      photoSaveMs: 900,
      totalMs: 19_401
    )

    XCTAssertTrue(message.hasPrefix("[OBS] ORIGINAL_DOWNLOAD_TIMING"))
    XCTAssertTrue(message.contains("prepareMs=310"))
    XCTAssertTrue(message.contains("requestToFirstByteMs=221"))
    XCTAssertTrue(message.contains("socketReceiveMs=17704"))
    XCTAssertTrue(message.contains("fileWriteMs=218"))
    XCTAssertTrue(message.contains("commandGapMs=48"))
    XCTAssertTrue(message.contains("photoSaveMs=900"))
    XCTAssertTrue(message.contains("totalMs=19401"))
    XCTAssertTrue(message.contains("bytes=86801408"))
    XCTAssertTrue(message.contains("speedMBps=4.47"))
  }

  func testOriginalReadImageExecutorOwnsOneSerializedLeaseForTheWholeFile() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }

    var nextTransactionID: UInt32 = 0
    var requests: [(UInt32, UInt64, UInt32)] = []
    var leaseCount = 0
    let executor = CameraVendorOriginalReadImageExecutor(
      nextTransactionID: {
        nextTransactionID += 1
        return nextTransactionID
      },
      sendRequest: { transactionID, handle, offset, size in
        XCTAssertEqual(handle, 0x95A)
        requests.append((transactionID, offset, size))
      },
      receivePayloadAndResponse: { transactionID, _, sink in
        let payload = transactionID == 1 ? Data([0x01, 0x02, 0x03]) : Data([0x04, 0x05, 0x06])
        try sink.write(contentsOf: payload)
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: payload.count,
          prefix: payload,
          requestToFirstByteMs: 1,
          socketReceiveMs: 2,
          fileWriteMs: 0,
          responseCode: CameraVendorPtpResponsePolicy.okResponseCode,
          responseTransactionID: transactionID
        )
      },
      cancellationCheck: {},
      report: { _ in }
    )

    _ = try executor.execute(
      handle: 0x95A,
      expectedByteCount: 6,
      maximumByteCount: 6,
      initialReadSize: 3,
      fileHandle: fileHandle,
      withSerializedLease: { body in
        leaseCount += 1
        return try body()
      }
    )

    XCTAssertEqual(leaseCount, 1)
    XCTAssertEqual(requests.map(\.0), [1, 2])
    XCTAssertEqual(requests.map(\.1), [0, 3])
  }

  func testOriginalReadImageExecutorStreamsEveryPayloadDirectlyToOneFile() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }

    let executor = CameraVendorOriginalReadImageExecutor(
      nextTransactionID: { 7 },
      sendRequest: { _, _, _, _ in },
      receivePayloadAndResponse: { transactionID, _, sink in
        let payload = Data([0x10, 0x11, 0x12, 0x13])
        try sink.write(contentsOf: payload)
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: payload.count,
          prefix: payload,
          requestToFirstByteMs: 0,
          socketReceiveMs: 1,
          fileWriteMs: 1,
          responseCode: CameraVendorPtpResponsePolicy.okResponseCode,
          responseTransactionID: transactionID
        )
      },
      cancellationCheck: {},
      report: { _ in }
    )

    _ = try executor.execute(
      handle: 1,
      expectedByteCount: 4,
      maximumByteCount: 4,
      initialReadSize: 4,
      fileHandle: fileHandle,
      withSerializedLease: { try $0() }
    )
    try fileHandle.synchronize()

    let reader = try FileHandle(forReadingFrom: fileURL)
    defer { try? reader.close() }
    XCTAssertEqual(try reader.readToEnd(), Data([0x10, 0x11, 0x12, 0x13]))
  }

  func testOriginalReadImageExecutorValidatesEveryTransactionResponse() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }
    var requests = 0
    let executor = CameraVendorOriginalReadImageExecutor(
      nextTransactionID: { UInt32(requests + 1) },
      sendRequest: { _, _, _, _ in requests += 1 },
      receivePayloadAndResponse: { transactionID, _, _ in
        CameraVendorOriginalReadImageTransactionResult(
          byteCount: 0,
          prefix: Data(),
          requestToFirstByteMs: 0,
          socketReceiveMs: 0,
          fileWriteMs: 0,
          responseCode: 0x2002,
          responseTransactionID: transactionID
        )
      },
      cancellationCheck: {},
      report: { _ in }
    )

    XCTAssertThrowsError(
      try executor.execute(
        handle: 1,
        expectedByteCount: 1,
        maximumByteCount: 1,
        initialReadSize: 1,
        fileHandle: fileHandle,
        withSerializedLease: { try $0() }
      )
    )
    XCTAssertEqual(requests, 1)
  }

  func testOriginalReadImageExecutorRejectsShortFileBeforeExpectedSize() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }
    var transactionID: UInt32 = 0
    let executor = CameraVendorOriginalReadImageExecutor(
      nextTransactionID: {
        transactionID += 1
        return transactionID
      },
      sendRequest: { _, _, _, _ in },
      receivePayloadAndResponse: { currentTransactionID, _, sink in
        let payload = currentTransactionID == 1 ? Data([0x31, 0x32]) : Data()
        if !payload.isEmpty {
          try sink.write(contentsOf: payload)
        }
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: payload.count,
          prefix: payload,
          requestToFirstByteMs: 0,
          socketReceiveMs: 0,
          fileWriteMs: 0,
          responseCode: CameraVendorPtpResponsePolicy.okResponseCode,
          responseTransactionID: currentTransactionID
        )
      },
      cancellationCheck: {},
      report: { _ in }
    )

    XCTAssertThrowsError(
      try executor.execute(
        handle: 1,
        expectedByteCount: 4,
        maximumByteCount: 4,
        initialReadSize: 2,
        fileHandle: fileHandle,
        withSerializedLease: { try $0() }
      )
    )
  }

  func testOriginalReadImageExecutorStopsOnlyAtAChunkBoundaryWhenCancelled() throws {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }
    var cancelled = false
    var requests = 0
    let executor = CameraVendorOriginalReadImageExecutor(
      nextTransactionID: { 1 },
      sendRequest: { _, _, _, _ in requests += 1 },
      receivePayloadAndResponse: { transactionID, _, sink in
        let payload = Data([0x21, 0x22])
        try sink.write(contentsOf: payload)
        cancelled = true
        return CameraVendorOriginalReadImageTransactionResult(
          byteCount: payload.count,
          prefix: payload,
          requestToFirstByteMs: 0,
          socketReceiveMs: 1,
          fileWriteMs: 1,
          responseCode: CameraVendorPtpResponsePolicy.okResponseCode,
          responseTransactionID: transactionID
        )
      },
      cancellationCheck: {
        if cancelled { throw CancellationError() }
      },
      report: { _ in }
    )

    XCTAssertThrowsError(
      try executor.execute(
        handle: 1,
        expectedByteCount: 4,
        maximumByteCount: 4,
        initialReadSize: 2,
        fileHandle: fileHandle,
        withSerializedLease: { try $0() }
      )
    )
    XCTAssertEqual(requests, 1)
  }

  func testOriginalReadImageExecutorDoesNotServePreviewThumbnailOrCatalogCalls() {
    XCTAssertTrue(
      CameraVendorOriginalReadImageExecutorPolicy.shouldUse(
        downloadMode: .original,
        purpose: "download-file"
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalReadImageExecutorPolicy.shouldUse(
        downloadMode: .compressed,
        purpose: "download-file"
      )
    )
    for purpose in ["preview", "thumbnail", "catalog", "object-info"] {
      XCTAssertFalse(
        CameraVendorOriginalReadImageExecutorPolicy.shouldUse(
          downloadMode: .original,
          purpose: purpose
        )
      )
    }
  }

  func testOriginalFileDownloadRoutesAroundGenericCommandDataPath() throws {
    let source = try runnerSource("CameraVendorOriginalTransferWorker.swift", "CameraVendorPtpSession.swift")
    let branchStart = try XCTUnwrap(
      source.range(of: "if CameraVendorOriginalReadImageExecutorPolicy.shouldUse(")?.lowerBound
    )
    let genericLoopStart = try XCTUnwrap(
      source.range(of: "    while offset < maxByteCount {", range: branchStart..<source.endIndex)?.lowerBound
    )
    let originalBranch = String(source[branchStart..<genericLoopStart])

    XCTAssertTrue(originalBranch.contains("CameraVendorOriginalReadImageExecutor("))
    XCTAssertTrue(originalBranch.contains("sendOriginalReadImageRequest"))
    XCTAssertTrue(originalBranch.contains("receiveOriginalReadImagePayloadAndResponse"))
    XCTAssertTrue(originalBranch.contains("withSerializedCommand"))
    XCTAssertFalse(originalBranch.contains("sendCommandForFileData("))
  }

  func testOriginalReadImageRunsOnDedicatedTransferWorkerInsideSerializedLease() throws {
    let source = try runnerSource("CameraVendorOriginalTransferWorker.swift", "CameraVendorPtpSession.swift")
    let branchStart = try XCTUnwrap(
      source.range(of: "if CameraVendorOriginalReadImageExecutorPolicy.shouldUse(")?.lowerBound
    )
    let genericLoopStart = try XCTUnwrap(
      source.range(of: "    while offset < maxByteCount {", range: branchStart..<source.endIndex)?.lowerBound
    )
    let originalBranch = String(source[branchStart..<genericLoopStart])

    XCTAssertTrue(source.contains("final class CameraVendorOriginalTransferWorker"))
    let workerCall = try XCTUnwrap(originalBranch.range(of: "originalTransferWorker.execute"))
    let executorCall = try XCTUnwrap(
      originalBranch.range(of: "executor.execute(", range: workerCall.upperBound..<originalBranch.endIndex)
    )
    _ = try XCTUnwrap(
      originalBranch.range(of: "withSerializedCommand", range: executorCall.upperBound..<originalBranch.endIndex)
    )
    XCTAssertTrue(originalBranch.contains("PTP_ORIGINAL_TRANSFER_WORKER_BEGIN"))
    XCTAssertTrue(originalBranch.contains("PTP_ORIGINAL_TRANSFER_WORKER_END"))
    XCTAssertFalse(originalBranch.contains("Task.detached"))
  }

  func testOriginalReadImageLogsEveryBlockingTransactionStage() throws {
    let source = try runnerSource("CameraVendorOriginalTransferWorker.swift", "CameraVendorPtpSession.swift")

    for marker in [
      "PTP_ORIGINAL_COMMAND_LOCK_WAIT",
      "PTP_ORIGINAL_COMMAND_LOCK_ACQUIRED",
      "PTP_ORIGINAL_COMMAND_LOCK_RELEASED",
      "PTP_ORIGINAL_REQUEST_SEND_BEGIN",
      "PTP_ORIGINAL_REQUEST_SEND_END",
      "PTP_ORIGINAL_RECEIVE_BEGIN",
      "PTP_ORIGINAL_LEGACY_HEADER_WAIT",
      "PTP_ORIGINAL_LEGACY_HEADER_RECEIVED",
      "PTP_ORIGINAL_LEGACY_PAYLOAD_BEGIN",
      "PTP_ORIGINAL_LEGACY_PAYLOAD_END",
      "PTP_ORIGINAL_RESPONSE_RECEIVED",
      "PTP_ACTIVE_DOWNLOAD_SOFT_CANCELLATION_REQUESTED",
      "PTP_ACTIVE_DOWNLOAD_SOFT_CANCELLED_AT_CHUNK_BOUNDARY",
    ] {
      XCTAssertTrue(source.contains(marker), "Missing transaction-stage marker: \(marker)")
    }
  }

  func testOriginalTransferWorkerExecutesOnDedicatedThread() throws {
    let worker = CameraVendorOriginalTransferWorker()
    let callerThread = pthread_mach_thread_np(pthread_self())

    let transferThread = try worker.execute {
      pthread_mach_thread_np(pthread_self())
    }

    XCTAssertNotEqual(transferThread, callerThread)
  }

  func testOriginalReadImageReceiveUsesTheBaselineSocketReader() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift", "CameraVendorPtpSession.swift")

    let originalStart = try XCTUnwrap(
      source.range(of: "private func receiveOriginalReadImagePayloadAndResponse(")?.lowerBound
    )
    let genericStart = try XCTUnwrap(
      source.range(of: "private func sendCommandForFileData(", range: originalStart..<source.endIndex)?.lowerBound
    )
    let originalBody = String(source[originalStart..<genericStart])
    XCTAssertTrue(originalBody.contains("readCameraVendorLegacyFilePacket"))
    XCTAssertFalse(originalBody.contains("receiveMode:"))

    let genericEnd = try XCTUnwrap(
      source.range(of: "private func sendCommandForData(", range: genericStart..<source.endIndex)?.lowerBound
    )
    let genericBody = String(source[genericStart..<genericEnd])
    XCTAssertTrue(genericBody.contains("readCameraVendorLegacyFilePacket"))
    XCTAssertFalse(genericBody.contains("receiveMode:"))

    let legacyReaderStart = try XCTUnwrap(
      source.range(of: "private func readCameraVendorLegacyFilePacket(")?.lowerBound
    )
    let legacyReaderEnd = try XCTUnwrap(
      source.range(
        of: "/// Read a standard PTP/IP packet",
        range: legacyReaderStart..<source.endIndex
      )?.lowerBound
    )
    let legacyReaderBody = String(source[legacyReaderStart..<legacyReaderEnd])
    XCTAssertTrue(legacyReaderBody.contains("readExactlyToFile"))
    XCTAssertTrue(source.contains("Darwin.recv"))
    XCTAssertTrue(source.contains("poll(&pfd"))
  }

  func testFalsifiedReadImageReceiveExperimentIsRemovedFromProductionPath() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("CameraVendorDebugReadImageReceivePolicy"))
    XCTAssertFalse(source.contains("CameraVendorReadImageReceiveMode"))
    XCTAssertFalse(source.contains("android-blocking"))
    XCTAssertFalse(source.contains("SO_RCVTIMEO"))
    XCTAssertFalse(source.contains("PTP_ORIGINAL_READIMAGE_RECEIVE_EXPERIMENT"))
  }

  func testNativeConnectFlowResultLogPolicySummarizesGalleryReadyWithoutItems() {
    let peripheralID = UUID()
    let state = IOSCameraConnectFlowState.galleryReady(
      IOSCameraGallerySession(
        cameraID: "221019F1932011003B_X-T5",
        rememberedPeripheralID: peripheralID,
        ptpSessionID: "x-t5-ptp"
      )
    )

    let message = NativeConnectFlowResultLogPolicy.message(
      state: state,
      peripheralID: peripheralID
    )

    XCTAssertTrue(message.contains("[BEGIN_USER_GALLERY_FLOW_RESULT] state=galleryReady"))
    XCTAssertTrue(message.contains("cameraID=221019F1932011003B_X-T5"))
    XCTAssertTrue(message.contains("ptpSessionID=x-t5-ptp"))
    XCTAssertTrue(message.contains("peripheralID=\(peripheralID.uuidString)"))
    XCTAssertFalse(message.contains("itemCount="))
    XCTAssertFalse(message.contains("initialItems"))
  }

  func testPtpSocketReadExactlyReadsDirectlyIntoData() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift")
    let start = try XCTUnwrap(source.range(of: "func readExactly(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func close()", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("var data = Data(count: length)"))
    XCTAssertFalse(body.contains("var buffer = [UInt8](repeating: 0, count: length)"))
    XCTAssertFalse(body.contains("return Data(buffer)"))
  }

  func testFileDownloadStreamsPtpPayloadDirectlyFromSocketToTemporaryFile() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift", "CameraVendorPtpSession.swift")
    let readStart = try XCTUnwrap(
      source.range(of: "private func readObjectByPartialObjectsToFile(")?.lowerBound
    )
    let readEnd = try XCTUnwrap(
      source.range(of: "private func persistOriginalTransferCapability(", range: readStart..<source.endIndex)?.lowerBound
    )
    let readBody = String(source[readStart..<readEnd])
    let streamStart = try XCTUnwrap(
      source.range(of: "private func sendCommandForFileData(")?.lowerBound
    )
    let streamEnd = try XCTUnwrap(
      source.range(of: "private func sendCommandForData(", range: streamStart..<source.endIndex)?.lowerBound
    )
    let streamBody = String(source[streamStart..<streamEnd])
    let legacyReaderStart = try XCTUnwrap(
      source.range(of: "private func readCameraVendorLegacyFilePacket(")?.lowerBound
    )
    let legacyReaderEnd = try XCTUnwrap(
      source.range(of: "/// Read a standard PTP/IP packet", range: legacyReaderStart..<source.endIndex)?.lowerBound
    )
    let legacyReaderBody = String(source[legacyReaderStart..<legacyReaderEnd])

    XCTAssertTrue(readBody.contains("sendCommandForFileData("))
    XCTAssertFalse(readBody.contains("chunk = try sendCommandForData("))
    XCTAssertTrue(streamBody.contains("readCameraVendorLegacyFilePacket"))
    XCTAssertTrue(legacyReaderBody.contains("readExactlyToFile"))
  }

  func testIOSProjectDeclaresLiveActivitySupportForOfficialStyleBackgroundSession() throws {
    let iosDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let projectYAML = try String(
      contentsOf: iosDirectory.appendingPathComponent("project.yml"),
      encoding: .utf8
    )
    let infoPlist = NSDictionary(
      contentsOf: iosDirectory.appendingPathComponent("Runner/Info.plist")
    )

    XCTAssertEqual(infoPlist?["NSSupportsLiveActivities"] as? Bool, true)
    XCTAssertTrue(projectYAML.contains("CameraSessionActivityWidget:"))
    XCTAssertTrue(projectYAML.contains("type: app-extension"))
    XCTAssertTrue(projectYAML.contains("embed: true"))
  }

  func testIOSProjectAndGeneratorKeepBuildNumberAtOrAbovePublishedBaseline() throws {
    let iosDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let project = try String(
      contentsOf: iosDirectory.appendingPathComponent("Runner.xcodeproj/project.pbxproj"),
      encoding: .utf8
    )
    let projectYAML = try String(
      contentsOf: iosDirectory.appendingPathComponent("project.yml"),
      encoding: .utf8
    )

    let projectVersions = project
      .components(separatedBy: "CURRENT_PROJECT_VERSION = ")
      .dropFirst()
      .compactMap { Int($0.prefix { $0.isNumber }) }
    let generatorVersions = projectYAML
      .components(separatedBy: "CURRENT_PROJECT_VERSION: ")
      .dropFirst()
      .compactMap { Int($0.prefix { $0.isNumber }) }

    XCTAssertFalse(projectVersions.isEmpty)
    XCTAssertFalse(generatorVersions.isEmpty)
    XCTAssertTrue(projectVersions.allSatisfy { $0 >= 6 })
    XCTAssertTrue(generatorVersions.allSatisfy { $0 >= 6 })
    XCTAssertEqual(Set(projectVersions), Set(generatorVersions))
  }

  func testCameraSessionLiveActivityDoesNotStartGalleryProtocol() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionLiveActivityController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("Activity<CameraSessionActivityAttributes>"))
    XCTAssertTrue(source.contains("Activity.request"))
    XCTAssertTrue(source.contains(".update("))
    XCTAssertTrue(source.contains(".end("))
    XCTAssertFalse(source.contains("loadGallery("))
    XCTAssertFalse(source.contains("startPhotoTransfer("))
    XCTAssertFalse(source.contains("beginUserInitiatedGalleryFlow("))
  }

  func testCameraSessionActivityAttributesTrackDownloadCountsInsteadOfGenericPhaseDetail() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Shared/CameraSessionActivityAttributes.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("var downloadCompletedCount: Int"))
    XCTAssertTrue(source.contains("var downloadTotalCount: Int"))
    XCTAssertTrue(source.contains("var isShowingDownloadProgress: Bool"))
    XCTAssertTrue(source.contains("var downloadRemainingCount: Int"))
    XCTAssertTrue(source.contains("var downloadProgressFraction: Double"))
    XCTAssertFalse(source.contains("var phase: String"))
    XCTAssertFalse(source.contains("var detail: String"))
  }

  func testCameraSessionLiveActivityControllerPublishesCountBasedDownloadProgress() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionLiveActivityController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("func updateDownloadProgress(completedCount: Int, totalCount: Int, reason: String)"))
    XCTAssertTrue(source.contains("func updateDownloadStarted(completedCount: Int, totalCount: Int, reason: String)"))
    XCTAssertTrue(source.contains("completedCount: completedCount"))
    XCTAssertTrue(source.contains("downloadCompletedCount: completedCount"))
    XCTAssertTrue(source.contains("downloadTotalCount: totalCount"))
    XCTAssertFalse(source.contains("phase: \"Downloading\""))
    XCTAssertFalse(source.contains("detail: \"\\(totalCount) items queued\""))
  }

  func testCameraSessionActivityWidgetShowsRemainingCountAndProgressBar() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("CameraSessionActivityWidget/CameraSessionActivityWidget.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("Text(\"还剩 \\(context.state.downloadRemainingCount) 张\")"))
    XCTAssertTrue(source.contains("ProgressView(value: context.state.downloadProgressFraction)"))
    XCTAssertTrue(source.contains("Text(\"\\(context.state.downloadRemainingCount)\")"))
    XCTAssertFalse(source.contains("\"Downloading\""))
    XCTAssertFalse(source.contains("\"Connected\""))
  }

  func testCameraSessionActivityWidgetMinimalViewShowsRemainingDownloadCount() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("CameraSessionActivityWidget/CameraSessionActivityWidget.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let minimalStart = try XCTUnwrap(source.range(of: "} minimal: {")?.upperBound)
    let minimalEnd = try XCTUnwrap(
      source.range(
        of: "\n      }\n    }\n  }\n}",
        range: minimalStart..<source.endIndex
      )?.lowerBound
    )
    let minimalSource = String(source[minimalStart..<minimalEnd])

    XCTAssertTrue(minimalSource.contains("if context.state.isShowingDownloadProgress"))
    XCTAssertTrue(minimalSource.contains("Text(\"\\(context.state.downloadRemainingCount)\")"))
    XCTAssertTrue(minimalSource.contains(".monospacedDigit()"))
    XCTAssertTrue(minimalSource.contains(".minimumScaleFactor("))
  }

  func testIOSRuntimeGalleryEntryUsesDedicatedRememberedCameraConnectionBoundary() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let beginStart = try XCTUnwrap(source.range(of: "func startRememberedCameraConnection(peripheralID: UUID) -> Bool")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "var requiresSystemBluetoothPairingCleanup: Bool", range: beginStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[beginStart..<nextFunction])

    XCTAssertTrue(body.contains("resetWirelessCameraFlow()"))
    XCTAssertTrue(body.contains("connectPairedCamera(peripheralID: peripheralID)"))
    XCTAssertFalse(source.contains("func beginUserInitiatedGalleryFlow(peripheralID: UUID)"))
    XCTAssertFalse(source.contains("func approveNextRememberedCameraConnection()"))
    XCTAssertFalse(source.contains("startOfficialGalleryMainline(peripheralID: peripheralID)"))
  }

  func testConnectFlowRuntimeUsesEnvironmentRegistrationGuardInsteadOfPassStub() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Orchestration/CameraConnectFlowRuntime.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("registrationGuard: { .pass }"))
    XCTAssertTrue(source.contains("evaluateRegistrationIssue"))
  }

  func testConnectFlowBridgeLivesOutsideNativeConnectViewController() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("private final class CameraVendorConnectFlowBridge"))
    XCTAssertFalse(source.contains("extension CameraVendorConnectFlowBridge: CameraVendorBluetoothServiceDelegate"))
  }

  func testNativeConnectGallerySessionUsesGalleryReadySummaryResolver() throws {
    let bridgeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorConnectFlowBridge.swift")
    let loaderURL = bridgeURL
      .deletingLastPathComponent()
      .appendingPathComponent("CameraVendorGalleryMainlineSessionLoader.swift")
    let bridgeSource = try String(contentsOf: bridgeURL, encoding: .utf8)
    let loaderSource = try String(contentsOf: loaderURL, encoding: .utf8)
    let start = try XCTUnwrap(
      bridgeSource.range(
        of: "func loadGallerySession(\n    from context: IOSCameraConnectionContext,\n    publishStep: @escaping (IOSCameraConnectionStep) -> Void\n  ) async throws -> IOSCameraGallerySession {"
      )?.lowerBound
    )
    let end = try XCTUnwrap(bridgeSource.range(of: "  func cancelActiveFlow()", range: start..<bridgeSource.endIndex)?.lowerBound)
    let body = String(bridgeSource[start..<end])

    XCTAssertTrue(body.contains("galleryReadyConnectionSummary"))
    XCTAssertTrue(body.contains("activeGalleryDestinationByPeripheralID"))
    XCTAssertTrue(body.contains("gallerySessionLoader.loadGallerySession"))
    XCTAssertTrue(body.contains("ptpSessionID: galleryLoadResult.ptpSessionID"))
    XCTAssertTrue(loaderSource.contains("IOSCameraGalleryConnectionCoordinator"))
    XCTAssertTrue(loaderSource.contains("CameraVendorGalleryRoutePolicy.hiddenDiagnosticRoutes"))
    XCTAssertTrue(loaderSource.contains("galleryReadyPTPSessionID = ptpSessionID"))
  }

  func testConnectionSummaryUpdatingVerifiedStepsPreservesOtherFields() {
    let wifi = CameraVendorWifiNetworkConfiguration(
      ssid: "FUJIFILM-X-T5-003B",
      passphrase: "camera-secret",
      isHidden: false,
      bssid: "30:34:2d:37:42:2d"
    )
    let original = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-6970",
      preferredWifiNetwork: wifi,
      preferCompressedDownloads: false,
      verifiedConnectionSteps: [.reconnectPairedBle, .transferAuthorization]
    )

    let updated = original.updatingVerifiedConnectionSteps(IOSCameraConnectionStep.officialGalleryOrder)

    XCTAssertEqual(updated.deviceName, original.deviceName)
    XCTAssertEqual(updated.serialNumber, original.serialNumber)
    XCTAssertEqual(updated.connectedDeviceName, original.connectedDeviceName)
    XCTAssertEqual(updated.preferredWifiNetwork, original.preferredWifiNetwork)
    XCTAssertEqual(updated.preferCompressedDownloads, original.preferCompressedDownloads)
    XCTAssertEqual(updated.verifiedConnectionSteps, IOSCameraConnectionStep.officialGalleryOrder)
  }

  func testNativeConnectRemovesLegacyTransferReadyBridge() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("NativeTransferReadyViewController"))
    XCTAssertFalse(source.contains("service.startPhotoTransfer()"))
  }

  func testNativeConnectHandshakeDelegateNoLongerNavigatesGalleryDirectly() throws {
    let vcSourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let bridgeSourceURL = vcSourceURL
      .deletingLastPathComponent()
      .appendingPathComponent("CameraVendorConnectFlowBridge.swift")
    let vcSource = try String(contentsOf: vcSourceURL, encoding: .utf8)
    let bridgeSource = try String(contentsOf: bridgeSourceURL, encoding: .utf8)
    XCTAssertFalse(vcSource.contains("extension NativeConnectViewController: CameraVendorBluetoothServiceDelegate"))
    XCTAssertTrue(bridgeSource.contains("extension CameraVendorConnectFlowBridge: CameraVendorBluetoothServiceDelegate"))
    XCTAssertTrue(bridgeSource.contains("nonisolated func cameraVendorBluetoothService"))
    XCTAssertTrue(bridgeSource.contains("didCompleteHandshake summary: CameraVendorConnectionSummary"))
    XCTAssertFalse(vcSource.contains("preloadGalleryThenEnter(summary: summary)"))
  }

  func testLegacyPtpConfirmGalleryModeUsesPreviouslyProvenFastConnectionRule() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let confirmStart = try XCTUnwrap(
      source.range(of: "private func confirmCameraVendorLegacyReferenceAppGalleryMode()")?.lowerBound
    )
    let loadBoundary = try XCTUnwrap(
      source.range(of: "private func prepareCameraVendorLegacyGalleryLoad()", range: confirmStart..<source.endIndex)?.lowerBound
    )
    let confirmBody = String(source[confirmStart..<loadBoundary])

    let factoryD212 = try XCTUnwrap(
      confirmBody.range(of: "CameraVendor/ReferenceApp factory D212 #1")
    )

    let clientState = try XCTUnwrap(
      confirmBody.range(of: "try setCameraVendorReferenceAppClientState(")
    )
    let imageHost = try XCTUnwrap(
      confirmBody.range(
        of: "CameraVendorDevicePropCode.referenceAppImageHost",
        range: clientState.upperBound..<confirmBody.endIndex
      )
    )
    _ = try XCTUnwrap(
      confirmBody.range(
        of: "try requestCameraVendorCardSlotStatus()",
        range: imageHost.upperBound..<confirmBody.endIndex
      )
    )

    XCTAssertEqual(confirmBody.components(separatedBy: "try requestCameraVendorCardSlotStatus()").count - 1, 1)
    XCTAssertTrue(factoryD212.lowerBound < clientState.lowerBound)
    XCTAssertTrue(confirmBody.contains("PTP_FACTORY_D212_1"))
    XCTAssertFalse(confirmBody.contains("primeCameraVendorCurrentImageContextIfNeeded("))
    XCTAssertFalse(confirmBody.contains("primeCameraVendorCurrentThumbnailContextIfNeeded("))
    XCTAssertFalse(confirmBody.contains("try requestCameraVendorSearchModeDescAll()"))
    XCTAssertFalse(confirmBody.contains("try readCameraVendorCurrentObjectHandle()"))
    XCTAssertFalse(confirmBody.contains("requestCameraVendorSpecifiedObject"))
  }

  func testLegacyPtpLoadGalleryBootstrapHasOneOwnerBeforeCatalogRuntime() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let sessionSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let loaderSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorGalleryMainlineSessionLoader.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(sessionSource.contains("private func prepareCameraVendorLegacyGalleryLoad()"))
    XCTAssertTrue(sessionSource.contains("func prepareCameraVendorLegacyGalleryLoadIfNeeded()"))

    let loadStart = try XCTUnwrap(loaderSource.range(of: "func executeLoadGalleryStep(")?.lowerBound)
    let loadBody = String(loaderSource[loadStart...])
    XCTAssertFalse(loadBody.contains("galleryService.prepareCameraVendorLegacyGalleryLoadIfNeeded()"))

    let realtimeServiceSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorRealtimeGalleryService.swift"),
      encoding: .utf8
    )
    let initialFetchStart = try XCTUnwrap(
      realtimeServiceSource.range(
        of: "func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {\n    try await commandLane.runExclusiveSessionMutation"
      )?.lowerBound
    )
    let initialFetchEnd = try XCTUnwrap(
      realtimeServiceSource.range(
        of: "func fetchCameraCatalog(query:",
        range: initialFetchStart..<realtimeServiceSource.endIndex
      )?.lowerBound
    )
    let initialFetchBody = String(realtimeServiceSource[initialFetchStart..<initialFetchEnd])
    let initialCatalog = try XCTUnwrap(
      initialFetchBody.range(of: "self.session.cameraVendorInitialCatalogSnapshot()")
    )
    let bootstrap = try XCTUnwrap(
      initialFetchBody.range(of: "self.session.recoverInitialCameraCatalogAfterStoreNotAvailable()")
    )
    XCTAssertLessThan(initialCatalog.lowerBound, bootstrap.lowerBound)
    XCTAssertTrue(initialFetchBody.contains("CameraVendorInitialCatalogBootstrapRecoveryPolicy.shouldRecover(after: error)"))

    let serviceConfirmStart = try XCTUnwrap(
      sessionSource.range(of: "private func confirmCameraVendorLegacyReferenceAppGalleryMode()")?.lowerBound
    )
    let confirmEnd = try XCTUnwrap(
      sessionSource.range(
        of: "private func prepareCameraVendorLegacyGalleryLoad()",
        range: serviceConfirmStart..<sessionSource.endIndex
      )?.lowerBound
    )
    let serviceConfirmBody = String(sessionSource[serviceConfirmStart..<confirmEnd])
    XCTAssertFalse(serviceConfirmBody.contains("prepareCameraVendorLegacyGalleryLoad"))
  }

  func testRealtimeGalleryServiceConfirmGalleryModeRunnerDoesNotStartLoadGallery() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorGalleryMainlineSessionLoader.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let confirmStart = try XCTUnwrap(
      source.range(of: "func executeConfirmGalleryModeStep(")?.lowerBound
    )
    let loadStart = try XCTUnwrap(
      source.range(of: "func executeLoadGalleryStep(", range: confirmStart..<source.endIndex)?.lowerBound
    )
    let confirmBody = String(source[confirmStart..<loadStart])

    XCTAssertFalse(confirmBody.contains("prepareCameraVendorLegacyGalleryLoadIfNeeded"))
    XCTAssertTrue(confirmBody.contains("evidence: .galleryModeConfirmed"))
  }

  func testRealtimeGalleryServicePersistsGalleryReadyConfirmedStepsIntoResolvedSummary() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorConnectFlowBridge.swift")
    let bridgeSource = try String(contentsOf: sourceURL, encoding: .utf8)
    let loaderSource = try String(
      contentsOf: sourceURL
        .deletingLastPathComponent()
        .appendingPathComponent("CameraVendorGalleryMainlineSessionLoader.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(bridgeSource.contains("confirmedSteps: galleryLoadResult.confirmedSteps"))
    XCTAssertTrue(loaderSource.contains("galleryReadyConfirmedSteps = routeCoordinator.confirmedSteps()"))
  }

  func testRealtimeGalleryServiceHasNoLegacyGalleryItemLoader() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertFalse(source.contains("func loadGalleryItems("))
    XCTAssertFalse(source.contains("func fetchGallery() async throws"))
    XCTAssertFalse(source.contains("fastInitialGalleryObjectInfos"))
  }

  func testRunnerAppInstallsGlobalLifecycleDiagnostics() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("RunnerApp.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("AppLifecycleDiagnostics.install()"))
    XCTAssertTrue(source.contains("UIApplication.didEnterBackgroundNotification"))
    XCTAssertTrue(source.contains("UIApplication.willEnterForegroundNotification"))
    XCTAssertTrue(source.contains("APP_LIFECYCLE"))
  }

  func testHomeViewDidAppearRefreshesRememberedCardBeforePassiveSearch() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let appearStart = try XCTUnwrap(source.range(of: "override func viewDidAppear(_ animated: Bool)")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "@discardableResult", range: appearStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[appearStart..<nextFunction])

    let refreshCard = try XCTUnwrap(body.range(of: "updateRememberedCameraCard()")?.lowerBound)
    let passiveSearch = try XCTUnwrap(body.range(of: "startInitialCameraSearchIfNeeded()")?.lowerBound)
    XCTAssertFalse(body.contains("resumePendingRememberedGalleryIfNeeded()"))
    XCTAssertLessThan(refreshCard, passiveSearch)
  }

  func testGalleryBackgroundDoesNotPersistPendingRememberedGalleryResumeIntent() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeGalleryViewController.swift"),
      encoding: .utf8
    )
    let backgroundStart = try XCTUnwrap(source.range(of: "@objc private func appDidEnterBackground()")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "private var applicationStateDescription", range: backgroundStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[backgroundStart..<nextFunction])

    XCTAssertFalse(body.contains("persistPendingRememberedGalleryResume(reason: reason)"))
  }

  func testBluetoothServiceInitDoesNotDeleteDocumentDiagnosticLogFile() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let initStart = try XCTUnwrap(source.range(of: "init(pairingStore: CameraVendorPairedCameraStore = CameraVendorPairedCameraStore())")?.lowerBound)
    let nextProperty = try XCTUnwrap(
      source.range(of: "private var connectedDeviceNameToWrite", range: initStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[initStart..<nextProperty])

    XCTAssertFalse(body.contains("removeItem(at: Self.debugLogURL)"))
    XCTAssertTrue(body.contains("appendLog(\"=== CamTransfer 启动 ===\")"))
  }

  func testGalleryResumeStoreProvidesSaveConsumeAndClearHooks() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraGalleryResumeStore.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("struct CameraPendingRememberedGalleryResume"))
    XCTAssertTrue(source.contains("func savePendingRememberedGalleryResume"))
    XCTAssertTrue(source.contains("func consumePendingRememberedGalleryResume"))
    XCTAssertTrue(source.contains("func clearPendingRememberedGalleryResume"))
    XCTAssertTrue(source.contains("struct CameraPendingRememberedCameraSession"))
    XCTAssertTrue(source.contains("func savePendingRememberedCameraSession"))
    XCTAssertTrue(source.contains("func peekPendingRememberedCameraSession"))
    XCTAssertTrue(source.contains("func clearPendingRememberedCameraSession"))
  }

  func testHomeStartupPublishesBluetoothCleanupBlockBeforeAnyLaunchAction() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let viewDidAppear = try XCTUnwrap(source.range(of: "override func viewDidAppear")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "private func showDebugStubDownloadsIfRequested", range: viewDidAppear..<source.endIndex)?.lowerBound
    )
    let body = String(source[viewDidAppear..<nextFunction])

    let cleanupBlock = try XCTUnwrap(body.range(of: "presentStartupSystemBluetoothCleanupBlockIfNeeded()")?.lowerBound)
    let debugDownloads = try XCTUnwrap(body.range(of: "showDebugStubDownloadsIfRequested()")?.lowerBound)
    let initialSearch = try XCTUnwrap(body.range(of: "startInitialCameraSearchIfNeeded()")?.lowerBound)
    XCTAssertLessThan(cleanupBlock, debugDownloads)
    XCTAssertLessThan(cleanupBlock, initialSearch)
  }

  func testBluetoothConnectToCameraHasCleanupGuardAtServiceBoundary() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let connectStart = try XCTUnwrap(source.range(of: "func connect(to cameraID: UUID)")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "private func beginScan", range: connectStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[connectStart..<nextFunction])

    let cleanupGuard = try XCTUnwrap(body.range(of: "publishSystemBluetoothCleanupBlockIfNeeded()")?.lowerBound)
    let diagnosticsReset = try XCTUnwrap(body.range(of: "CameraVendorGalleryDiagnostics.externalLogHandler = nil")?.lowerBound)
    let prepareConnection = try XCTUnwrap(body.range(of: "prepareConnectionAttempt")?.lowerBound)
    XCTAssertLessThan(cleanupGuard, diagnosticsReset)
    XCTAssertLessThan(cleanupGuard, prepareConnection)
  }

  func testRememberedGalleryMainlineHasCleanupGuardBeforeStart() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let beginStart = try XCTUnwrap(source.range(of: "func startRememberedCameraConnection(peripheralID: UUID) -> Bool")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "var requiresSystemBluetoothPairingCleanup: Bool", range: beginStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[beginStart..<nextFunction])

    let cleanupGuard = try XCTUnwrap(body.range(of: "publishSystemBluetoothCleanupBlockIfNeeded()")?.lowerBound)
    let flowStartLog = try XCTUnwrap(body.range(of: "用户点击进入相机相册")?.lowerBound)
    let resetStart = try XCTUnwrap(body.range(of: "resetWirelessCameraFlow()")?.lowerBound)
    let mainlineStart = try XCTUnwrap(body.range(of: "connectPairedCamera(peripheralID: peripheralID)")?.lowerBound)
    XCTAssertLessThan(cleanupGuard, flowStartLog)
    XCTAssertLessThan(cleanupGuard, resetStart)
    XCTAssertLessThan(cleanupGuard, mainlineStart)
  }

  func testBluetoothCleanupPublishCancelsLocalPairingBeforeStatus() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let publishStart = try XCTUnwrap(source.range(of: "func publishSystemBluetoothCleanupBlockIfNeeded")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "func acknowledgeSystemBluetoothPairingCleanupForFreshPairing", range: publishStart..<source.endIndex)?.lowerBound
    )
    let publishBody = String(source[publishStart..<nextFunction])

    let cancelLocalPairing = try XCTUnwrap(
      publishBody.range(of: "cancelLocalPairingForSystemBluetoothCleanup()")?.lowerBound
    )
    let statusUpdate = try XCTUnwrap(publishBody.range(of: "updateStatus")?.lowerBound)
    XCTAssertLessThan(cancelLocalPairing, statusUpdate)

    let cancelStart = try XCTUnwrap(source.range(of: "private func cancelLocalPairingForSystemBluetoothCleanup")?.lowerBound)
    let cancelEnd = try XCTUnwrap(
      source.range(of: "private func requireSystemBluetoothPairingCleanup", range: cancelStart..<source.endIndex)?.lowerBound
    )
    let cancelBody = String(source[cancelStart..<cancelEnd])

    XCTAssertTrue(cancelBody.contains("pairingStore.clear()"))
    XCTAssertTrue(cancelBody.contains("rememberedPairedCameras = []"))
    XCTAssertTrue(cancelBody.contains("rememberedPairedCamera = nil"))
    XCTAssertTrue(cancelBody.contains("central.stopScan()"))
    XCTAssertTrue(cancelBody.contains("central.cancelPeripheralConnection(activePeripheral)"))
  }

  func testBluetoothCleanupPromptRequiresCheckedDeletionBeforeRepair() throws {
    let source = try runnerSource(
      "NativeConnectViewController.swift",
      "NativeScanViewController.swift"
    )
    let promptStart = try XCTUnwrap(
      source.range(of: "private func presentSystemBluetoothPairingCleanupPromptIfNeeded")?.lowerBound
    )
    let nextFunction = try XCTUnwrap(
      source.range(of: "private func presentNotice", range: promptStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[promptStart..<nextFunction])

    XCTAssertTrue(body.contains("presentBluetoothCleanupConfirmationPrompt"))
    XCTAssertTrue(body.contains("completeSystemBluetoothCleanupForRepair()"))
    XCTAssertTrue(source.contains("final class NativeBluetoothCleanupConfirmationViewController"))
    XCTAssertTrue(source.contains("checkboxButton"))
    XCTAssertTrue(source.contains("checkboxButton.addTarget(self, action: #selector(toggleCheckbox), for: .touchUpInside)"))
    XCTAssertTrue(source.contains("confirmButton.isEnabled = isChecked"))
    XCTAssertFalse(body.contains("continueAction()"))
    XCTAssertFalse(body.contains("service.connect("))

    let repairStart = try XCTUnwrap(source.range(of: "private func completeSystemBluetoothCleanupForRepair")?.lowerBound)
    let repairEnd = try XCTUnwrap(
      source.range(of: "@objc private func copyLogsTapped", range: repairStart..<source.endIndex)?.lowerBound
    )
    let repairBody = String(source[repairStart..<repairEnd])

    XCTAssertTrue(repairBody.contains("confirmDeletedBluetoothAndStartFreshPairing()"))
  }

  func testBluetoothCleanupPromptWaitsForHomeViewWindowBeforePresenting() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let promptStart = try XCTUnwrap(
      source.range(of: "private func presentBluetoothCleanupConfirmationPrompt")?.lowerBound
    )
    let promptEnd = try XCTUnwrap(
      source.range(of: "private func confirmDeletedBluetoothAndStartFreshPairing", range: promptStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[promptStart..<promptEnd])

    XCTAssertTrue(body.contains("view.window != nil"))
    XCTAssertTrue(body.contains("DispatchQueue.main.asyncAfter"))
    XCTAssertTrue(body.contains("presentBluetoothCleanupConfirmationPrompt("))
  }

  func testNativeConnectHomeRemovesDirectPtpShortcutFlow() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("@objc private func manualConnectTapped"))
    XCTAssertFalse(source.contains("galleryService.configureForDirectPTP()"))
    XCTAssertFalse(source.contains("private let onDirectTransfer: () -> Void"))
    XCTAssertFalse(source.contains("directTransferButton"))
    XCTAssertFalse(source.contains("已连接相机 Wi-Fi，直接传图"))
  }

  func testGalleryPresentationLifecyclePausesThumbnailRequestsWhileBackgrounded() {
    XCTAssertTrue(
      NativeGalleryPresentationLifecyclePolicy.shouldPauseThumbnailRequests(
        applicationState: .background,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryPresentationLifecyclePolicy.shouldPauseThumbnailRequests(
        applicationState: .active,
        hasActiveCameraCommunication: true
      )
    )
    XCTAssertFalse(
      NativeGalleryPresentationLifecyclePolicy.shouldPauseThumbnailRequests(
        applicationState: .background,
        hasActiveCameraCommunication: false
      )
    )
  }

  func testBackgroundReadImageInfoKeepAliveUsesOfficialCurrentImageInfoHandle() throws {
    XCTAssertEqual(
      CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveIntervalSeconds,
      6.0
    )
    XCTAssertEqual(
      CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoKeepAliveHandle,
      CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle
    )
    XCTAssertFalse(CameraVendorBackgroundMetadataRefreshPolicy.shouldCacheReadImageInfoKeepAliveResult())

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let runtimeMethodStart = try XCTUnwrap(
      source.range(of: "func performBackgroundKeepAlive() async throws")?.lowerBound
    )
    let runtimeNextMethodStart = try XCTUnwrap(
      source.range(of: "func downloadOriginal(for handle: Int, expectedSize: UInt32?) async throws -> Data {", range: runtimeMethodStart..<source.endIndex)?.lowerBound
    )
    let runtimeBody = String(source[runtimeMethodStart..<runtimeNextMethodStart])
    XCTAssertTrue(runtimeBody.contains("commandLane.run(priority: .keepAlive)"))
    XCTAssertTrue(runtimeBody.contains("cameraVendorLatestObjectInfo("))
    XCTAssertTrue(runtimeBody.contains("readImageInfoKeepAliveHandle"))
    XCTAssertTrue(runtimeBody.contains("readTimeout: CameraVendorBackgroundMetadataRefreshPolicy.readImageInfoTimeoutSeconds"))
    XCTAssertFalse(runtimeBody.contains("nextKeepAliveHandle"))
    XCTAssertFalse(runtimeBody.contains("session.objectInfo("))
    XCTAssertFalse(runtimeBody.contains("objectInfoCache.keys"))

    let serviceStart = try XCTUnwrap(source.range(of: "final class CameraVendorRealtimeGalleryService")?.lowerBound)
    let serviceMethodStart = try XCTUnwrap(
      source.range(of: "func performBackgroundKeepAlive() async throws {\n    try await ptpRuntime.performBackgroundKeepAlive()\n  }", range: serviceStart..<source.endIndex)?.lowerBound
    )
    XCTAssertNotNil(serviceMethodStart)
  }

  func testBackgroundPtpKeepAliveWaitsOneIntervalBeforeFirstCameraRequest() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionBackgroundSupervisor.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let methodStart = try XCTUnwrap(
      source.range(of: "private func startPtpKeepAliveLoopIfNeeded()")?.lowerBound
    )
    let methodEnd = try XCTUnwrap(
      source.range(of: "\n  }\n}", range: methodStart..<source.endIndex)?.upperBound
    )
    let body = String(source[methodStart..<methodEnd])
    let sleep = try XCTUnwrap(body.range(of: "try await Task.sleep(")?.lowerBound)
    let request = try XCTUnwrap(body.range(of: "try await galleryKeepAlive.performBackgroundKeepAlive()")?.lowerBound)

    XCTAssertLessThan(sleep, request)
  }

  func testBleBackgroundKeepAliveIsReadOnlyAndDoesNotWriteCameraState() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorBluetoothService.swift"),
      encoding: .utf8
    )
    let start = try XCTUnwrap(source.range(of: "func performBackgroundBleKeepAlive(reason: String)")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "enum CameraVendorAppVariant", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("peripheral.readValue(for: characteristic)"))
    XCTAssertFalse(body.contains("writeValue"))
  }

  func testBleBackgroundKeepAlivePrefersTransferStateBeforeApStateAndDeviceInfo() {
    let candidates = CameraVendorBleBackgroundKeepAlivePolicy.preferredReadableCharacteristicUUIDStrings
      .map { $0.uppercased() }
    let apState = CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString.uppercased()
    let transferState = CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString.uppercased()
    let imageTransferSetting = CameraVendorReferenceAppTransferActivationPlan
      .imageTransferSettingCharacteristicUUIDString
      .uppercased()
    let serialNumber = "00002A25-0000-1000-8000-00805F9B34FB"
    let officialSettingProbeCandidates = [
      "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4",
      "BD45F887-A6BE-4CB7-8565-390DF38BF5BF",
      "AAB609C4-94DD-4D89-BC60-665D5090B828",
      "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B",
      "75823784-FBB7-4B71-ABAE-CD9A34072E3C",
    ]

    XCTAssertEqual(candidates.prefix(3), [transferState, imageTransferSetting, CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString.uppercased()])
    XCTAssertEqual(CameraVendorBleBackgroundKeepAlivePolicy.readSpacingSeconds, 0.08)
    for uuid in officialSettingProbeCandidates {
      XCTAssertTrue(candidates.contains(uuid))
      XCTAssertLessThan(
        try XCTUnwrap(candidates.firstIndex(of: uuid)),
        try XCTUnwrap(candidates.firstIndex(of: apState))
      )
    }
    XCTAssertLessThan(
      try XCTUnwrap(candidates.firstIndex(of: transferState)),
      try XCTUnwrap(candidates.firstIndex(of: apState))
    )
    XCTAssertLessThan(
      try XCTUnwrap(candidates.firstIndex(of: apState)),
      try XCTUnwrap(candidates.firstIndex(of: serialNumber))
    )
  }

  func testConnectFlowBridgeDoesNotBindPairingCompletionToFirstRememberedRecord() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorConnectFlowBridge.swift"),
      encoding: .utf8
    )
    let functionStart = try XCTUnwrap(
      source.range(of: "didCompletePairing summary: CameraVendorConnectionSummary")?.lowerBound
    )
    let nextFunction = try XCTUnwrap(
      source.range(of: "didCompleteHandshake summary: CameraVendorConnectionSummary", range: functionStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[functionStart..<nextFunction])

    XCTAssertFalse(body.contains("service.rememberedCameraRecords.first"))
    XCTAssertTrue(body.contains("pendingPairingPeripheralID"))
    XCTAssertTrue(body.contains("first(where: { $0.peripheralID == pendingPairingPeripheralID })"))
  }

  func testConnectFlowBridgeDoesNotBindHandshakeCompletionToFirstRememberedRecord() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorConnectFlowBridge.swift"),
      encoding: .utf8
    )
    let functionStart = try XCTUnwrap(
      source.range(of: "didCompleteHandshake summary: CameraVendorConnectionSummary")?.lowerBound
    )
    let nextFunction = try XCTUnwrap(
      source.range(of: "}\n}", range: functionStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[functionStart..<nextFunction])

    XCTAssertFalse(body.contains("service.rememberedCameraRecords.first"))
    XCTAssertTrue(body.contains("pendingGalleryPeripheralID"))
    XCTAssertTrue(body.contains("first(where: { $0.peripheralID == pendingGalleryPeripheralID })"))
    XCTAssertTrue(body.contains("activeHandshakeSummaryByPeripheralID"))
  }

  func testWarmGalleryResumeDoesNotPopBackToHomeBeforeReconnect() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let functionStart = try XCTUnwrap(source.range(of: "private func requestRememberedGalleryResume(peripheralID: UUID, reason: String)")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "@discardableResult", range: functionStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[functionStart..<nextFunction])

    XCTAssertTrue(body.contains("currentTopGalleryController()"))
    XCTAssertTrue(body.contains("if currentTopGalleryController() == nil"))
  }

  func testWarmGalleryResumeReplacesVisibleGalleryInsteadOfPushingDuplicate() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let functionStart = try XCTUnwrap(source.range(of: "private func finishRememberedGalleryEntryIfPossible()")?.lowerBound)
    let nextFunction = try XCTUnwrap(
      source.range(of: "private func handleConnectFlowFailure(", range: functionStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[functionStart..<nextFunction])

    XCTAssertTrue(body.contains("replaceVisibleGalleryControllerIfNeeded"))
    XCTAssertTrue(body.contains("navigationController?.pushViewController(controller, animated: true)"))
  }

  func testGalleryReadyEntryEnablesIdleTimerProtectionBeforeAutoLock() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "final class NativeGalleryViewController")?.lowerBound)
    let galleryPage = String(source[galleryStart...])
    let viewDidAppearStart = try XCTUnwrap(galleryPage.range(of: "override func viewDidAppear(_ animated: Bool)")?.lowerBound)
    let viewWillDisappearStart = try XCTUnwrap(galleryPage.range(of: "override func viewWillDisappear(_ animated: Bool)")?.lowerBound)
    let viewDidAppearBody = String(galleryPage[viewDidAppearStart..<viewWillDisappearStart])

    XCTAssertTrue(viewDidAppearBody.contains("updateIdleTimerProtection()"))
    XCTAssertFalse(galleryPage.contains("if let initialItems {"))
  }

  func testNativeGalleryExitCopyMatchesAndroidDisconnectDialog() {
    XCTAssertEqual(NativeGalleryExitCopy.title, "确认断开相机连接？")
    XCTAssertEqual(NativeGalleryExitCopy.confirmTitle, "确认断开")
    XCTAssertEqual(NativeGalleryExitCopy.cancelTitle, "继续停留")
    XCTAssertTrue(NativeGalleryExitCopy.message.contains("保持在照片筛选页面"))
  }

  func testTransferActivationCompletionPolicyProceedsAfterObservedChange() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: true,
        hasMoreStrategies: false
      )
    )
  }

  func testOfficialImportImageKeepsBluetoothAvailableForBackgroundActivityAfterApReady() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldWaitForBluetoothDisconnect(
        afterObservedChangeFor: .officialImportImage
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldActivelyDisconnectBluetooth(
        for: .officialImportImage
      )
    )
  }

  func testOfficialImportImageWaitsForApReadyAfterActivationWrites() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFastHandoffAfterCommandWrites(
        for: .officialImportImage
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFastHandoffAfterCommandWrites(
        for: .compatibleRemoteImageView
      )
    )
  }

  func testDebugLaunchPolicyAutoConnectsRememberedCameraOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldAutoConnectRememberedCamera(
        arguments: ["Runner", "--camtransfer-autoconnect-remembered"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldAutoConnectRememberedCamera(
        arguments: ["Runner"]
      )
    )
  }

  func testDebugLaunchPolicyShowsStubGalleryOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldShowStubGallery(
        arguments: ["Runner", "--camtransfer-show-stub-gallery"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldShowStubGallery(
        arguments: ["Runner"]
      )
    )
  }

  func testDebugLaunchPolicyShowsStubDownloadsOnlyWithExplicitArgument() {
    XCTAssertTrue(
      NativeCameraDebugLaunchPolicy.shouldShowStubDownloads(
        arguments: ["Runner", "--camtransfer-show-stub-downloads"]
      )
    )
    XCTAssertFalse(
      NativeCameraDebugLaunchPolicy.shouldShowStubDownloads(
        arguments: ["Runner"]
      )
    )
  }

  func testPassiveConnectionResetSkipsActiveTransferHandoff() {
    XCTAssertTrue(
      CameraVendorConnectionResetPolicy.shouldSkipPassiveResetDuringTransferHandoff(
        force: false,
        didCompleteHandshakeCallback: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        isRunningTransferActivation: false,
        awaitingBluetoothDisconnectForWifiHandoff: false,
        awaitingTransferActivationStateChange: false
      )
    )
    XCTAssertFalse(
      CameraVendorConnectionResetPolicy.shouldSkipPassiveResetDuringTransferHandoff(
        force: true,
        didCompleteHandshakeCallback: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        isRunningTransferActivation: false,
        awaitingBluetoothDisconnectForWifiHandoff: false,
        awaitingTransferActivationStateChange: false
      )
    )
  }

  func testHomeViewWillAppearDoesNotResetWhileRememberedGalleryFlowIsActive() {
    XCTAssertFalse(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: true,
        isEnteringGalleryFromRememberedCamera: true
      )
    )
    XCTAssertTrue(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: true,
        isEnteringGalleryFromRememberedCamera: false
      )
    )
    XCTAssertFalse(
      NativeHomePassiveConnectionResetPolicy.shouldResetOnViewWillAppear(
        isRootHome: false,
        isEnteringGalleryFromRememberedCamera: false
      )
    )
  }

  func testHomePairingProbeDoesNotRestartAfterReturningFromCameraSession() {
    XCTAssertTrue(
      NativeHomePairingProbePolicy.shouldBegin(
        hasRememberedCamera: true,
        isConnectionWorkerActive: false,
        hasPairingProbeTask: false,
        hasReturnedFromCameraSession: false
      )
    )
    XCTAssertFalse(
      NativeHomePairingProbePolicy.shouldBegin(
        hasRememberedCamera: true,
        isConnectionWorkerActive: false,
        hasPairingProbeTask: false,
        hasReturnedFromCameraSession: true
      )
    )
  }

  func testSpecifiedObjectEmptySnapshotRecoveryRetriesOnlyEmptyFirstSnapshot() {
    XCTAssertTrue(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: 0,
        isRequiredPrimaryList: true
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: 0,
        isRequiredPrimaryList: false
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 0,
        handles: [],
        retryCount: CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.maxRetryCount,
        isRequiredPrimaryList: true
      )
    )
    XCTAssertFalse(
      CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy.shouldRetry(
        count: 2,
        handles: [1, 2],
        retryCount: 0,
        isRequiredPrimaryList: true
      )
    )
  }

  func testHandshakeCompletionKeepsBluetoothWhenTransferActivationObservedChange() {
    XCTAssertFalse(
      CameraVendorHandshakeCompletionPolicy.shouldDisconnectBluetoothBeforeGallery(
        transferActivationObservedChange: true
      )
    )
  }

  func testTransferActivationCompletionPolicyWaitsWhenNoStrategyWorked() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: false,
        hasMoreStrategies: false
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotProceedJustBecauseFallbackStrategiesRemain() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldProceedToGallery(
        observedChange: false,
        hasMoreStrategies: true
      )
    )
  }

  func testTransferActivationCompletionPolicyTriesFallbackWhenCurrentStrategyIsNotGalleryReady() {
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldTryNextStrategy(
        observedChange: false,
        hasMoreStrategies: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldTryNextStrategy(
        observedChange: true,
        hasMoreStrategies: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotAttemptWifiHandoffWithoutApReady() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: false,
        observedWifiLaunch: false
      )
    )
    XCTAssertTrue(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: true,
        observedWifiLaunch: false
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAttemptWifiHandoffAfterExhaustedStrategies(
        observedChange: false,
        observedWifiLaunch: true
      )
    )
  }

  func testTransferActivationCompletionPolicyBlocksHandshakeAfterFailedActivationFeature() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: false,
        hadActivationFeature: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotAllowHandshakeAfterWifiLaunchWithoutReadyChange() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: true,
        hadActivationFeature: true
      )
    )
  }

  func testTransferActivationCompletionPolicyDoesNotFallbackToWifiLaunchWithoutReadyChange() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldFallbackToWifiLaunchAfterCameraResponse(
        observedChange: false,
        observedWifiLaunch: true
      )
    )
  }

  func testTransferActivationCompletionPolicyBlocksHandshakeWithoutActivationFeature() {
    XCTAssertFalse(
      CameraVendorTransferActivationCompletionPolicy.shouldAllowHandshakeCompletion(
        hasAttemptedActivation: true,
        observedChange: false,
        observedWifiLaunch: false,
        hadActivationFeature: false
      )
    )
  }

  func testHandshakeDoesNotCompleteAfterEmptyActivationPlan() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let emptyPlanStart = try XCTUnwrap(source.range(of: "case .failMissingActivationFeature")?.lowerBound)
    let guardStart = try XCTUnwrap(
      source.range(
        of: "case .failActivationNotReady:",
        range: emptyPlanStart..<source.endIndex
      )?.lowerBound
    )
    let emptyPlanRegion = String(source[emptyPlanStart..<guardStart])

    XCTAssertFalse(emptyPlanRegion.contains("直接进入图库"))
    XCTAssertFalse(emptyPlanRegion.contains("completeHandshake("))
  }

  func testGalleryFetchConcurrencyPolicyRejectsDuplicateFetches() {
    XCTAssertTrue(CameraVendorGalleryFetchConcurrencyPolicy.shouldRejectConcurrentFetch)
    XCTAssertEqual(CameraVendorGalleryFetchConcurrencyPolicy.concurrentFetchErrorCode, 7)
  }

  func testGalleryDownloadPolicyBlocksVideoUntilStreamingIsStable() {
    let video = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.MOV",
      formatLabel: "Video",
      captureDate: "",
      byteSizeText: "1 GB"
    )
    let jpeg = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: "1 MB"
    )
    let raw = CameraVendorGalleryItem(
      handle: 3,
      filename: "DSCF0003.RAF",
      formatLabel: "RAW",
      captureDate: "",
      byteSizeText: "83 MB"
    )

    XCTAssertFalse(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(video))
    XCTAssertTrue(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(jpeg))
    XCTAssertTrue(CameraVendorGalleryDownloadPolicy.canDownloadOriginal(raw))
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: video), .video)
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: jpeg), .photo)
    XCTAssertEqual(CameraVendorGalleryDownloadPolicy.mediaType(for: raw), .raw)
  }

  func testPhotoDownloadsUseProductionFilePathForOriginalDownloadPipeline() {
    XCTAssertFalse(CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadsFromTemporaryFile)
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: nil
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: 30 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .photo,
        compressedSize: 64 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .video,
        compressedSize: 30 * 1_024 * 1_024
      )
    )
    XCTAssertFalse(
      CameraVendorDownloadPipelinePolicy.shouldUseDataFastPath(
        mediaType: .raw,
        compressedSize: 83 * 1_024 * 1_024
      )
    )
  }

  func testTemporaryDownloadABDiagnosticsAreRemovedFromProductionPath() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("TEMP_DOWNLOAD_AB_20260705"))
    XCTAssertFalse(source.contains("CameraVendorTemporaryDownloadDiagnosticsPolicy"))
    XCTAssertFalse(source.contains("fileDownloadReadSizeOverrideBytes"))
    XCTAssertFalse(source.contains("effectiveFileDownloadReadSize"))
    XCTAssertFalse(source.contains("socketPacket transport="))
  }

  func testDownloadExecutionRoutePolicyKeepsPathChoiceOutOfGalleryUI() {
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .photo,
        compressedSize: 30 * 1_024 * 1_024
      ),
      .file
    )
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .raw,
        compressedSize: 83 * 1_024 * 1_024
      ),
      .file
    )
    XCTAssertEqual(
      CameraVendorDownloadExecutionRoutePolicy.route(
        mediaType: .video,
        compressedSize: 30 * 1_024 * 1_024
      ),
      .file
    )
  }

  func testPhotoLibrarySavePolicyNormalizesHeifDownloadsBeforeSaving() {
    XCTAssertTrue(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIC",
        mediaType: .photo
      )
    )
    XCTAssertTrue(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIF",
        mediaType: .photo
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.JPG",
        mediaType: .photo
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.HEIC",
        mediaType: .video
      )
    )
    XCTAssertFalse(
      CameraVendorPhotoLibrarySaveInputPolicy.shouldSavePhotoDownloadFromData(
        filename: "DSCF0001.RAF",
        mediaType: .raw
      )
    )
  }

  func testTransferActivationWaitsAfterDisablingResize() {
    XCTAssertEqual(CameraVendorTransferActivationResizePolicy.resizeDisabledPayload, Data([0x00]))
    XCTAssertEqual(CameraVendorTransferActivationResizePolicy.postWriteDelaySeconds, 0.5)
  }

  func testTransferActivationDefaultsToOriginalWhenNoPreferenceWasSaved() {
    let defaults = UserDefaults.standard
    let key = "camtransfer.downloadCompressionEnabled"
    let previousValue = defaults.object(forKey: key)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }

    defaults.removeObject(forKey: key)

    XCTAssertFalse(CameraVendorTransferActivationResizePolicy.preferCompressedDownloads)
    XCTAssertEqual(
      CameraVendorTransferActivationResizePolicy.currentPayload,
      CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
    )
  }

  func testTransferActivationDisconnectPolicyAcceptsPromptDisconnectAfterWaitingForCameraConfirmation() {
    XCTAssertTrue(
      CameraVendorTransferActivationDisconnectPolicy.shouldTreatDisconnectAsWifiHandoff(
        elapsedSinceWaitingForConfirmation: 4
      )
    )
  }

  func testTransferActivationDisconnectPolicyRejectsLateDisconnectAfterWaitingForCameraConfirmation() {
    XCTAssertFalse(
      CameraVendorTransferActivationDisconnectPolicy.shouldTreatDisconnectAsWifiHandoff(
        elapsedSinceWaitingForConfirmation: 35
      )
    )
  }

  func testSecureHandshakeRecoveryRetriesWhenDisconnectHappensDuringIdentificationWrite() {
    XCTAssertTrue(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .awaitingIdentificationNumberWrite,
        retryCount: 0
      )
    )
  }

  func testSecureHandshakeRecoveryStopsRetryingAfterFirstReconnect() {
    XCTAssertFalse(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .awaitingIdentificationNumberWrite,
        retryCount: 1
      )
    )

    XCTAssertFalse(
      CameraVendorSecureHandshakeRecoveryPolicy.shouldReconnectAfterUnexpectedDisconnect(
        phase: .completed,
        retryCount: 0
      )
    )
  }

  func testConnectionSummaryKeepsHiddenPreferredWifiAsSingleOfficialCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true,
        bssid: "AA-BB-CC-DD-EE-FF"
      )
    )

    let configurations = summary.wifiConfigurations
    XCTAssertEqual(configurations.count, 1)
    XCTAssertEqual(configurations[0].ssid, "CAMERA-DEVICE-A-003B")
    XCTAssertTrue(configurations[0].isHidden)
    XCTAssertEqual(configurations[0].bssid, "aa:bb:cc:dd:ee:ff")
  }

  func testRunnerInfoPlistExcludesLocationUsageDescriptions() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let plistURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))

    XCTAssertNil(plist["NSLocationWhenInUseUsageDescription"])
    XCTAssertNil(plist["NSLocationAlwaysAndWhenInUseUsageDescription"])
    XCTAssertNotNil(plist["NSLocalNetworkUsageDescription"] as? String)
    let appTransportSecurity = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])
    XCTAssertEqual(appTransportSecurity["NSAllowsLocalNetworking"] as? Bool, true)
  }

  func testRunnerInfoPlistIncludesPhotoLibraryReadWriteAndAddOnlyUsageDescriptions() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let plistURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))

    XCTAssertNotNil(plist["NSPhotoLibraryUsageDescription"] as? String)
    XCTAssertNotNil(plist["NSPhotoLibraryAddUsageDescription"] as? String)
  }

  func testRunnerInfoPlistDeclaresBackgroundModesForCameraKeepAlive() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let plistURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
    let backgroundModes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String])

    XCTAssertTrue(backgroundModes.contains("bluetooth-central"))
    XCTAssertFalse(backgroundModes.contains("location"))
  }

  func testRunnerTargetSignsWithWifiEntitlements() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
    let iosDirectory = testsDirectory.deletingLastPathComponent()
    let entitlementsURL = iosDirectory.appendingPathComponent("Runner/Runner.entitlements")
    let entitlements = try XCTUnwrap(NSDictionary(contentsOf: entitlementsURL))

    XCTAssertEqual(entitlements["com.apple.developer.networking.HotspotConfiguration"] as? Bool, true)
    XCTAssertEqual(entitlements["com.apple.developer.networking.wifi-info"] as? Bool, true)

    let projectURL = iosDirectory.appendingPathComponent("Runner.xcodeproj/project.pbxproj")
    let project = try String(contentsOf: projectURL, encoding: .utf8)
    let expectedSetting = "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;"

    XCTAssertEqual(project.components(separatedBy: expectedSetting).count - 1, 2)
    XCTAssertTrue(project.contains("com.apple.AccessWiFi"))
    XCTAssertTrue(project.contains("com.apple.HotspotConfiguration"))
  }

  func testManualWifiJoinInstructionsIncludeHiddenNetworkHint() {
    let instructions = CameraVendorGalleryDiagnostics.manualWifiJoinInstructions(
      for: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "abc12345",
        isHidden: true
      )
    )

    XCTAssertEqual(
      instructions,
      [
        "自动连接失败，请到系统设置手动加入相机 Wi-Fi。",
        "SSID: CAMERA-DEVICE-A-003B",
        "密码: abc12345",
        "这是隐藏网络；如果列表里看不到，请在 Wi‑Fi 的“其他...”里手动输入。",
        "连上后回到 CamTransfer，点“重新加载”。",
      ]
    )
  }

  func testGallerySelectionToggleAndSelectAllFlow() {
    let items = [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 2,
        filename: "B.RAF",
        formatLabel: "RAW",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "20 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.toggleSelection(handle: 1)
    XCTAssertEqual(state.selectedHandles, [1])

    state.selectAll()
    XCTAssertEqual(state.selectedHandles, [1, 2])

    state.clearSelection()
    XCTAssertTrue(state.selectedHandles.isEmpty)
  }

  func testNativeGalleryDragSelectionPolicySelectsUnselectedHandles() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [1, 2, 3, 9])
  }

  func testNativeGalleryDragSelectionPolicyKeepsModeAcrossAlreadySelectedHandles() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [2, 9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [1, 2, 3, 9])
  }

  func testNativeGalleryDragSelectionPolicyDeselectsWhenStartingOnSelectedHandle() {
    let mode = NativeGalleryDragSelectionPolicy.mode(startHandle: 1, selectedHandles: [1, 2, 3, 9])

    let selected = NativeGalleryDragSelectionPolicy.updatedSelection(
      selectedHandles: [1, 2, 3, 9],
      visiting: [1, 2, 3],
      mode: mode
    )

    XCTAssertEqual(selected, [9])
  }

  func testNativeGalleryDragSelectionPolicyUsesAndroidHorizontalTouchSlop() {
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 8,
        deltaY: 0,
        touchSlop: 10
      )
    )
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 12,
        deltaY: 10,
        touchSlop: 10
      )
    )
    XCTAssertTrue(
      NativeGalleryDragSelectionPolicy.shouldStartDragSelection(
        deltaX: 24,
        deltaY: 6,
        touchSlop: 10
      )
    )
  }

  func testNativeGalleryDragSelectionPolicyCommitsOnlyAfterMovingToAnotherSelectableHandle() {
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 2,
        canSelectEndHandle: true
      )
    )
    XCTAssertFalse(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 3,
        canSelectEndHandle: false
      )
    )
    XCTAssertTrue(
      NativeGalleryDragSelectionPolicy.shouldCommitDragSelection(
        startHandle: 2,
        endHandle: 3,
        canSelectEndHandle: true
      )
    )
  }

  func testNativeGalleryDragSelectionPolicySelectsContinuousRangeLikeAndroid() {
    let selected = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
      selectedHandles: [9],
      orderedHandles: [1, 2, 3, 4, 5, 6],
      startHandle: 2,
      endHandle: 5,
      selectableHandles: [1, 2, 3, 5, 6],
      mode: .selecting
    )

    XCTAssertEqual(selected, [2, 3, 5, 9])
  }

  func testNativeGalleryDragSelectionPolicyDeselectsContinuousRangeLikeAndroid() {
    let selected = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
      selectedHandles: [1, 2, 3, 4, 5, 9],
      orderedHandles: [1, 2, 3, 4, 5, 6],
      startHandle: 5,
      endHandle: 2,
      selectableHandles: [1, 2, 3, 5, 6],
      mode: .deselecting
    )

    XCTAssertEqual(selected, [1, 4, 9])
  }

  func testNativeGalleryUIInvalidationPolicyRefreshesOnlyChangedSelectionHandles() {
    XCTAssertEqual(
      NativeGalleryUIInvalidationPolicy.changedHandles(before: [1, 2, 9], after: [2, 3, 9]),
      [1, 3]
    )
  }

  func testNativeGallerySelectionRefreshPolicyUsesSelectionOnlyCellUpdates() {
    XCTAssertFalse(NativeGallerySelectionRefreshPolicy.shouldReconfigureImageDuringSelectionChange)
    XCTAssertTrue(NativeGallerySelectionRefreshPolicy.shouldPauseThumbnailLoadingDuringSelectionGesture)
  }

  func testNativeGalleryInteractionPriorityPolicyDoesNotWaitForThumbnailDrainBeforeBack() {
    XCTAssertTrue(NativeGalleryInteractionPriorityPolicy.shouldCancelThumbnailQueueBeforeExitTap)
    XCTAssertTrue(NativeGalleryInteractionPriorityPolicy.shouldSuppressThumbnailRetryAfterInteractionCancel)
    XCTAssertEqual(NativeGalleryInteractionPriorityPolicy.thumbnailResumeDelayAfterSelectionSeconds, 0.2)
  }

  func testNativeGalleryDragSelectionPolicyAutoScrollsNearEdgesLikeAndroid() {
    XCTAssertEqual(
      NativeGalleryDragSelectionPolicy.autoScrollDelta(
        pointerY: 10,
        viewportStart: 0,
        viewportEnd: 600,
        edgeSize: 100,
        maxDelta: 40
      ),
      -36,
      accuracy: 0.001
    )
    XCTAssertEqual(
      NativeGalleryDragSelectionPolicy.autoScrollDelta(
        pointerY: 575,
        viewportStart: 0,
        viewportEnd: 600,
        edgeSize: 100,
        maxDelta: 40
      ),
      30,
      accuracy: 0.001
    )
  }

  func testNativeGallerySelectionSummaryCountsOnlySelectableFilteredItemsLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)
    state.setSelection(handles: [1, 2, 3, 99])
    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 3)

    let summary = NativeGallerySelectionSummaryPolicy.summary(items: state.items, state: state)

    XCTAssertEqual(summary.selectedCount, 1)
    XCTAssertEqual(summary.totalSelectableCount, 1)
    XCTAssertEqual(summary.text, "已选 1 / 共 1 张")
  }

  func testGalleryQueueStartsRequestedDownloadsOnly() {
    let items = [
      CameraVendorGalleryItem(
        handle: 11,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 22,
        filename: "B.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "1 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [11, 22])

    XCTAssertEqual(state.downloadState(for: 11), .queued)
    XCTAssertEqual(state.downloadState(for: 22), .queued)
  }

  func testGalleryDownloadQueuePreservesEnqueueOrderLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1267, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1268, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1265, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1267, 1268, 1265])

    XCTAssertEqual(state.queuedDownloadHandles(), [1267, 1268, 1265])
    XCTAssertEqual(state.nextQueuedDownloadHandle(), 1267)

    state.markDownloadStarted(handle: 1267)
    state.markDownloadFailed(handle: 1267, message: "worker fallback")
    state.enqueueDownloads(for: [1267])

    XCTAssertEqual(state.queuedDownloadHandles(), [1268, 1265, 1267])
  }

  func testGalleryDownloadPauseClearsOnlyPendingQueue() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1, 2, 3], mode: .compressed)
    state.markDownloadStarted(handle: 1)
    let pausedHandles = state.pauseQueuedDownloads()

    XCTAssertEqual(pausedHandles, [2, 3])
    XCTAssertEqual(state.queuedDownloadHandles(), [])
    XCTAssertEqual(state.downloadState(for: 1), .downloading)
    XCTAssertEqual(state.downloadState(for: 2), .idle)
    XCTAssertEqual(state.downloadState(for: 3), .idle)
    XCTAssertEqual(state.downloadableHandles(from: [1, 2, 3]), [2, 3])
  }

  func testGalleryInterruptedDownloadRequeuesActiveHandleAtFront() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1, 2, 3], mode: .compressed)
    state.markDownloadStarted(handle: 1)
    state.requeueInterruptedDownload(handle: 1, mode: .compressed)

    XCTAssertEqual(state.queuedDownloadHandles(), [1, 2, 3])
    XCTAssertEqual(state.downloadState(for: 1), .queued)
    XCTAssertEqual(state.downloadMode(for: 1), .compressed)
  }

  func testGalleryQueueCarriesDownloadModeCapturedAtSelectionTime() {
    let items = [
      CameraVendorGalleryItem(handle: 11, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 22, filename: "B.HEIF", formatLabel: "HEIF", captureDate: "", byteSizeText: "8 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [11], mode: .compressed)
    state.enqueueDownloads(for: [22], mode: .original)

    XCTAssertEqual(state.downloadMode(for: 11), .compressed)
    XCTAssertEqual(state.downloadMode(for: 22), .original)
  }

  func testGalleryQueueClearsSelectionForQueuedDownloads() {
    let items = [
      CameraVendorGalleryItem(handle: 11, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 22, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.setSelection(handles: [11, 22])
    state.enqueueDownloads(for: [11])

    XCTAssertEqual(state.selectedHandles, [22])
  }

  func testGalleryDownloadLifecycleTracksProgressAndFailure() {
    let items = [
      CameraVendorGalleryItem(
        handle: 5,
        filename: "C.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:02:00",
        byteSizeText: "2 MB"
      )
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [5])
    state.markDownloadStarted(handle: 5)
    XCTAssertEqual(state.downloadState(for: 5), .downloading)

    state.markDownloadFinished(handle: 5)
    XCTAssertEqual(state.downloadState(for: 5), .saved)

    state.markDownloadFailed(handle: 5, message: "network")
    XCTAssertEqual(state.downloadState(for: 5), .failed("network"))
  }

  func testGalleryCanClearSavedDownloadCacheForRetry() {
    let item = CameraVendorGalleryItem(
      handle: 5,
      filename: "C.JPG",
      formatLabel: "JPG",
      captureDate: "2026:04:26 17:02:00",
      byteSizeText: "2 MB"
    )
    var state = CameraVendorGalleryState(items: [item])

    state.markDownloadFinished(handle: 5)
    state.clearSavedDownloadCache(handle: 5)

    XCTAssertEqual(state.downloadState(for: 5), .idle)
    XCTAssertEqual(state.downloadableHandles(from: [5]), [5])
  }

  func testGalleryCanClearAllSavedDownloadCacheForRetry() {
    let items = [
      CameraVendorGalleryItem(handle: 5, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 6, filename: "D.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
      CameraVendorGalleryItem(handle: 7, filename: "E.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "4 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.markDownloadFinished(handle: 5)
    state.markDownloadFinished(handle: 6)
    state.enqueueDownloads(for: [7])
    state.clearAllSavedDownloadCache()

    XCTAssertEqual(state.downloadState(for: 5), .idle)
    XCTAssertEqual(state.downloadState(for: 6), .idle)
    XCTAssertEqual(state.downloadState(for: 7), .queued)
    XCTAssertEqual(state.downloadableHandles(from: [5, 6, 7]), [5, 6])
  }

  func testDownloadHistoryStoreClearsSingleSavedHandle() {
    let cameraID = "unit-test-camera-\(UUID().uuidString)"

    CameraVendorDownloadHistoryStore.markSaved(handle: 11, for: cameraID)
    CameraVendorDownloadHistoryStore.markSaved(handle: 22, for: cameraID)
    CameraVendorDownloadHistoryStore.removeSaved(handle: 11, for: cameraID)

    XCTAssertEqual(CameraVendorDownloadHistoryStore.savedHandles(for: cameraID), [22])
    CameraVendorDownloadHistoryStore.clear(for: cameraID)
  }

  func testDownloadHistoryStorePersistsGalleryItemAndThumbnailLikeAndroid() {
    let cameraID = "unit-test-camera-\(UUID().uuidString)"
    let item = CameraVendorGalleryItem(
      handle: 31,
      filename: "DSCF0031.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:05:04 10:31:00",
      byteSizeText: "8 MB",
      orientation: 4,
      thumbnailData: Data([0xFF, 0xD8, 0xFF])
    )

    CameraVendorDownloadHistoryStore.markSaved(item: item, for: cameraID)

    XCTAssertEqual(CameraVendorDownloadHistoryStore.savedHandles(for: cameraID), [31])
    XCTAssertEqual(CameraVendorDownloadHistoryStore.historyItems(for: cameraID), [item])
    CameraVendorDownloadHistoryStore.clear(for: cameraID)
  }

  func testDownloadTimingFormatterComputesMegabytesPerSecond() {
    XCTAssertEqual(
      CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 3 * 1_048_576, elapsedMs: 1500),
      "2.00"
    )
    XCTAssertEqual(CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 0, elapsedMs: 1500), "0.00")
    XCTAssertEqual(CameraVendorDownloadTimingFormatter.megabytesPerSecond(byteCount: 1024, elapsedMs: 0), "0.00")
  }

  func testGalleryDownloadStateSurvivesFilteringItems() {
    let originalItems = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
    ]
    var state = CameraVendorGalleryState(items: originalItems)

    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 2)
    state.replaceItems([originalItems[0]])

    XCTAssertEqual(state.downloadState(for: 2), .saved)
  }

  func testGalleryDownloadableHandlesSkipAlreadySavedQueuedAndDownloadingItems() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [2])
    state.markDownloadFinished(handle: 2)
    state.enqueueDownloads(for: [3])
    state.markDownloadStarted(handle: 3)

    XCTAssertEqual(state.downloadableHandles(from: [1, 2, 3]), [1])
  }

  func testGalleryDownloadableHandlesAllowFailedItemsToRetry() {
    let item = CameraVendorGalleryItem(handle: 4, filename: "D.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "4 MB")
    var state = CameraVendorGalleryState(items: [item])

    state.enqueueDownloads(for: [4])
    state.markDownloadFailed(handle: 4, message: "network")

    XCTAssertEqual(state.downloadableHandles(from: [4]), [4])
  }

  func testGalleryDownloadFatalConnectionFailureStopsPendingQueueLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)
    state.enqueueDownloads(for: [1, 2, 3])
    state.markDownloadStarted(handle: 1)
    let error = NSError(
      domain: NSPOSIXErrorDomain,
      code: 54,
      userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))

    state.markDownloadFailed(handle: 1, message: error.localizedDescription)
    state.markPendingDownloadsFailedAfterFatalFailure(
      message: NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage
    )

    XCTAssertEqual(state.downloadState(for: 1), .failed("Connection reset by peer"))
    XCTAssertEqual(
      state.downloadState(for: 2),
      .failed(NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage)
    )
    XCTAssertEqual(
      state.downloadState(for: 3),
      .failed(NativeGalleryDownloadFailurePolicy.connectionLostQueueStopMessage)
    )
    XCTAssertTrue(state.queuedDownloadHandles().isEmpty)
  }

  func testGalleryDownloadPtpSocketReadTimeoutStopsPendingQueue() {
    let error = NSError(
      domain: "CameraVendorPtpSocket",
      code: 9,
      userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))
  }

  func testGalleryDownloadLocalizedPtpReadTimeoutStopsPendingQueue() {
    let error = NSError(
      domain: "CameraVendorPtpSession",
      code: 5,
      userInfo: [NSLocalizedDescriptionKey: "读取数据失败: 等待相机返回数据超时"]
    )

    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(error))
  }

  func testGalleryDownloadSelectionPolicyDisablesItemsAlreadyInDownloadList() {
    XCTAssertTrue(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .idle))
    XCTAssertTrue(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .failed("network")))
    XCTAssertFalse(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .queued))
    XCTAssertFalse(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .downloading))
    XCTAssertTrue(NativeGalleryDownloadSelectionPolicy.canSelect(downloadState: .saved))
  }

  func testNativeGalleryNavigationPolicyBlocksLeavingWhileDownloading() {
    XCTAssertFalse(NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canLeaveGallery(isDownloading: false))
  }

  func testNativeGalleryNavigationPolicyLocksPreviewWhileDownloading() {
    XCTAssertFalse(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canDismissPreview(isDownloading: false))

    XCTAssertFalse(NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: true))
    XCTAssertTrue(NativeGalleryNavigationPolicy.canOpenPreview(isDownloading: false))
  }

  func testNativeGalleryDownloadBarPolicyBlocksGalleryActionsWhileDownloading() {
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 3, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 2, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 0, isDownloading: true))
    XCTAssertFalse(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 0, isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadBarPolicy.canToggleSelectAll(totalSelectableCount: 3, isDownloading: false))
    XCTAssertTrue(NativeGalleryDownloadBarPolicy.canStartDownload(selectedCount: 2, isDownloading: false))
  }

  func testNativeGalleryDownloadModePresentationPolicyBlocksOtherOperationsDuringTransfer() {
    XCTAssertFalse(NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.canInteractWithGallery(isDownloading: false))
    XCTAssertFalse(NativeGalleryDownloadModePresentationPolicy.shouldScheduleThumbnailRefresh(isDownloading: true))
    XCTAssertTrue(NativeGalleryDownloadModePresentationPolicy.shouldScheduleThumbnailRefresh(isDownloading: false))
  }

  func testNativeGalleryStartsTransferBeforePushingDownloadCenterWithoutSecondStartAction() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let galleryStart = try XCTUnwrap(source.range(of: "final class NativeGalleryViewController")?.lowerBound)
    let galleryEnd = try XCTUnwrap(source.range(of: "final class NativeDownloadListViewController")?.lowerBound)
    let galleryBody = String(source[galleryStart..<galleryEnd])
    let entryStart = try XCTUnwrap(galleryBody.range(of: "private func openDownloadCenter(for handles: [Int])")?.lowerBound)
    let entryEnd = galleryBody.endIndex
    let entryBody = String(galleryBody[entryStart..<entryEnd])

    let startCommand = try XCTUnwrap(entryBody.range(of: "runtime.submitDownload(CameraDownloadSubmission("))
    let push = try XCTUnwrap(entryBody.range(of: "navigationController?.pushViewController"))
    XCTAssertLessThan(startCommand.lowerBound, push.lowerBound)
    XCTAssertFalse(entryBody.contains("onStartDownload"))
    XCTAssertFalse(galleryBody.contains("private func startDownloadFromDownloadCenter"))
    XCTAssertFalse(source.contains("startDownloadButton"))
    XCTAssertFalse(source.contains("@objc private func startDownloadTapped()"))
  }

  func testNativeGalleryImmediateDownloadButtonUsesDownloadCopy() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let buttonStart = try XCTUnwrap(source.range(of: "private let bottomDownloadButton: UIButton")?.lowerBound)
    let buttonEnd = try XCTUnwrap(source.range(of: "private let reservedReceiveProbeButton", range: buttonStart..<source.endIndex)?.lowerBound)
    let buttonBody = String(source[buttonStart..<buttonEnd])

    XCTAssertTrue(buttonBody.contains("config.title = \"下载\""))
    XCTAssertTrue(buttonBody.contains("AttributedString(\"下载\""))
    XCTAssertFalse(buttonBody.contains("前往下载"))
  }

  func testNativeGalleryDownloadModePresentationPolicyKeepsGallerySessionOwnedWhileDownloadCenterIsVisible() {
    XCTAssertTrue(
      NativeGalleryDownloadModePresentationPolicy.shouldKeepForegroundGallerySession(
        surface: .gallery
      )
    )
    XCTAssertTrue(
      NativeGalleryDownloadModePresentationPolicy.shouldKeepForegroundGallerySession(
        surface: .downloadCenter
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.shouldKeepForegroundGallerySession(
        surface: .other
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.shouldDelegateForegroundRecoveryToHome(
        surface: .gallery
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.shouldDelegateForegroundRecoveryToHome(
        surface: .downloadCenter
      )
    )
    XCTAssertTrue(
      NativeGalleryDownloadModePresentationPolicy.shouldDelegateForegroundRecoveryToHome(
        surface: .other
      )
    )
  }

  func testNativeGalleryDownloadModePresentationPolicyReturnsToGalleryAfterDownloadCompletion() {
    XCTAssertTrue(
      NativeGalleryDownloadModePresentationPolicy.shouldAutoReturnToGalleryAfterDownloadCompletion(
        surface: .downloadCenter
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.shouldAutoReturnToGalleryAfterDownloadCompletion(
        surface: .gallery
      )
    )
    XCTAssertFalse(
      NativeGalleryDownloadModePresentationPolicy.shouldAutoReturnToGalleryAfterDownloadCompletion(
        surface: .other
      )
    )
  }

  func testNativeGalleryPostDownloadSelectionPolicyClearsSelectionLikeAndroid() {
    XCTAssertTrue(
      NativeGalleryPostDownloadSelectionPolicy.selectionAfterStartingDownload(selectedHandles: [1, 2, 3]).isEmpty
    )
  }

  func testHomeRememberedCameraPresenceDetectsOnlineCameraFromScanResults() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [rememberedID],
        status: "已发现 1 台相机",
        isBusy: false,
        hasActiveRememberedCameraSession: false
      ),
      .online
    )
  }

  func testHomeRememberedCameraPresenceGuidesWhileScanningAndOfflineAfterMiss() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [],
        status: "搜索中",
        isBusy: true,
        hasActiveRememberedCameraSession: false
      ),
      .scanning
    )
    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [],
        status: "未发现相机",
        isBusy: false,
        hasActiveRememberedCameraSession: false
      ),
      .offline
    )
  }

  func testHomeRememberedCameraPresencePrefersCommunicatingWhenActiveSessionExists() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertEqual(
      NativeHomeRememberedCameraPresencePolicy.presence(
        rememberedPeripheralID: rememberedID,
        discoveredCameraIDs: [],
        status: "已返回首页",
        isBusy: false,
        hasActiveRememberedCameraSession: true
      ),
      .communicating
    )
  }

  func testHomeRememberedCameraCopyUsesPairingAndTransferLanguage() {
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.unpairedDetailText(rssi: -54, shortID: "12345678"),
      "未配对 · 信号 -54 dB · 12345678"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .online),
      "已配对 · 在线"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .scanning),
      "已配对 · 正在搜索"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .offline),
      "已配对 · 未在线"
    )
    XCTAssertEqual(
      NativeHomeCameraCardCopyPolicy.pairedDetailText(for: .communicating),
      "已配对 · 通讯中"
    )
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.pairedActionTitle, "进入相册")
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.unpairedActionTitle, "配对")
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.resumeActionTitle, "继续相册")
    XCTAssertEqual(NativeHomeCameraCardCopyPolicy.disconnectActionTitle, "断开相机")
  }

  func testHomeCameraSearchActionUsesRefreshLanguageAfterAutoScan() {
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.symbolName, "arrow.clockwise")
    XCTAssertEqual(NativeHomeCameraSearchActionPolicy.accessibilityLabel, "刷新搜索附近相机")
  }

  func testNativeHomeAndroidParityCopyMatchesConnectScreen() {
    XCTAssertEqual(NativeHomeAndroidParityCopy.brandTitle, "CAMTRANSFER")
    XCTAssertEqual(NativeHomeAndroidParityCopy.screenTitle, "连接相机")
    XCTAssertEqual(NativeHomeAndroidParityCopy.idleModeLabel, "蓝牙配对")
    XCTAssertEqual(NativeHomeAndroidParityCopy.pairedModeLabel, "已配对")
    XCTAssertEqual(NativeHomeAndroidParityCopy.savedCameraLabel, "已保存相机")
    XCTAssertEqual(NativeHomeAndroidParityCopy.pairingPreparationTitles, ["进入配对注册界面", "取消旧的蓝牙配对"])
    XCTAssertEqual(NativeHomeAndroidParityCopy.wiredAccessLabel, "有线接入")
    XCTAssertEqual(NativeHomeAndroidParityCopy.auxiliaryActionLabels, ["诊断日志", "使用须知"])
  }

  func testFreshPairingRequiresSystemBluetoothForgetPromptLikeAndroidRegistrationGuard() {
    XCTAssertFalse(NativeFreshPairingSystemBluetoothCleanupPrompt.shouldRequireBeforeFreshPairing())
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.title, "先删除本地蓝牙配对")
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.openBluetoothTitle, "打开本地蓝牙设置")
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.confirmTitle, "确认已删除，重新配对")
    XCTAssertEqual(NativeFreshPairingSystemBluetoothCleanupPrompt.checkboxTitle, "我已在 iPhone 蓝牙里忽略/删除这台相机")
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("删除本地蓝牙配对"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("设置 > 蓝牙"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("忽略此设备"))
    XCTAssertTrue(NativeFreshPairingSystemBluetoothCleanupPrompt.message.contains("Wi-Fi/PTP"))
  }

  func testNativeHomePairingPreparationUsesCompactRows() {
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.usesCompactRows)
    XCTAssertLessThanOrEqual(NativeHomePairingPreparationLayoutPolicy.rowMinimumHeight, 72)
    XCTAssertFalse(NativeHomePairingPreparationLayoutPolicy.showsLongInstructionBody)
    XCTAssertFalse(NativeHomePairingPreparationLayoutPolicy.showsInlineDisclaimerText)
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.hidesSystemNavigationBar)
    XCTAssertTrue(NativeHomePairingPreparationLayoutPolicy.usesInlineBluetoothAction)
  }

  func testNativeHomeHeaderTemporarilyHidesProEntry() {
    XCTAssertFalse(NativeHomeHeaderLayoutPolicy.showsProEntry)
  }

  func testNativeHomePairedCameraCardCentersGalleryAction() {
    XCTAssertTrue(NativeHomePairedCameraCardLayoutPolicy.centersPrimaryGalleryAction)
    XCTAssertGreaterThanOrEqual(NativeHomePairedCameraCardLayoutPolicy.primaryGalleryActionMinimumWidth, 150)
    XCTAssertLessThanOrEqual(NativeHomePairedCameraCardLayoutPolicy.cardMinimumHeight, 170)
    XCTAssertFalse(NativeHomePairedCameraCardLayoutPolicy.showsDecorativeProfileHeader)
    XCTAssertFalse(NativeHomePairedCameraCardLayoutPolicy.showsStatusPanelFrame)
  }

  func testNativeHomeQuickDownloadRequiresParametersOnlyBeforeFirstSavedRule() {
    XCTAssertEqual(NativeHomeQuickDownloadEntryPolicy.action(ruleIsEnabled: false), .configure)
    XCTAssertEqual(NativeHomeQuickDownloadEntryPolicy.action(ruleIsEnabled: true), .start)
  }

  func testSavingQuickDownloadSettingsAlwaysMarksRuleEnabled() {
    var rule = CameraAutoDownloadRule()
    rule.isEnabled = false

    XCTAssertTrue(
      NativeAutoDownloadSettingsSavePolicy.resolvedRule(
        rule,
        forcesEnabled: false
      ).isEnabled
    )
    XCTAssertTrue(
      NativeAutoDownloadSettingsSavePolicy.resolvedRule(
        rule,
        forcesEnabled: true
      ).isEnabled
    )
    XCTAssertFalse(rule.isEnabled)
  }

  func testMediaFormatSelectionMakesAllExclusiveFromSpecificFormats() {
    let specific = CameraMediaFormatSelection.normalized([.jpg, .raw])

    XCTAssertEqual(specific.selectingAll(), .all)
    XCTAssertEqual(CameraMediaFormatSelection.normalized([]), .all)
  }

  func testMediaFormatSelectionCodableNormalizesEmptySpecificSelectionToAll() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let emptySelection = CameraMediaFormatSelection.selected([])
    let encodedEmptySelection = try encoder.encode(emptySelection)
    let encodedAll = try encoder.encode(CameraMediaFormatSelection.all)
    let legacyEmptySelection = Data(#"{"selected":{"_0":[]}}"#.utf8)

    XCTAssertEqual(encodedEmptySelection, encodedAll)
    XCTAssertEqual(
      try decoder.decode(CameraMediaFormatSelection.self, from: legacyEmptySelection),
      .all
    )
  }

  func testMediaFormatSelectionAllowsJpgRawAndHeifMultiSelection() {
    let selection = CameraMediaFormatSelection.normalized([.jpg, .raw, .heif])

    XCTAssertEqual(selection, .selected([.jpg, .raw, .heif]))
  }

  func testGalleryDefaultFilterIsAllFormatsAllDatesAllDownloads() {
    XCTAssertEqual(
      CameraMediaFilterRule.galleryDefault,
      CameraMediaFilterRule(formats: .all, date: .all, downloadScope: .all)
    )
  }

  func testQuickDownloadDefaultFilterIsJpgAllDatesNotDownloaded() {
    XCTAssertEqual(
      CameraMediaFilterRule.quickDownloadDefault,
      CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .all,
        downloadScope: .notDownloaded
      )
    )
  }

  func testFilterPlannerUsesExactQueriesForJpgAndRaw() {
    XCTAssertEqual(
      CameraFilterEngine.plan(for: .selected([.jpg])),
      .exactFormats([.jpg])
    )
    XCTAssertEqual(
      CameraFilterEngine.plan(for: .selected([.jpg, .raw])),
      .exactFormats([.jpg, .raw])
    )
  }

  func testFilterPlannerUsesSubtractBaselineWheneverHeifIsSelected() {
    XCTAssertEqual(
      CameraFilterEngine.plan(for: .selected([.heif])),
      .subtractBaseline([.heif])
    )
    XCTAssertEqual(
      CameraFilterEngine.plan(for: .selected([.jpg, .heif])),
      .subtractBaseline([.jpg, .heif])
    )
  }

  func testGalleryFilterCameraMembershipOnlyDependsOnFormats() {
    let base = CameraGalleryFilterIntent(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .all,
        downloadScope: .all
      ),
      sort: .newest
    )
    let localProjection = CameraGalleryFilterIntent(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .today,
        downloadScope: .notDownloaded
      ),
      sort: .oldest
    )
    let differentFormat = CameraGalleryFilterIntent(
      rule: CameraMediaFilterRule(
        formats: .selected([.raw]),
        date: .today,
        downloadScope: .notDownloaded
      ),
      sort: .oldest
    )

    XCTAssertTrue(base.hasSameCameraMembership(as: localProjection))
    XCTAssertFalse(base.hasSameCameraMembership(as: differentFormat))
  }

  func testFilterProjectionAppliesDateAndDownloadScopeOnce() {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 12))!
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    let candidates = [
      CameraMediaFilterCandidate(handle: 1, captureDate: today),
      CameraMediaFilterCandidate(handle: 2, captureDate: today),
      CameraMediaFilterCandidate(handle: 3, captureDate: yesterday),
    ]
    let rule = CameraMediaFilterRule(
      formats: .all,
      date: .today,
      downloadScope: .notDownloaded
    )

    let projected = CameraFilterEngine.project(
      candidates,
      rule: rule,
      downloadedHandles: [2],
      now: today,
      calendar: calendar
    )

    XCTAssertEqual(projected.map(\.handle), [1])
  }

  func testCatalogIdentityRejectsAnotherCameraSessionEpoch() {
    let generation = CameraGalleryGenerationID(rawValue: 7)
    let snapshotID = CameraGallerySnapshotID()
    let current = CameraGalleryCatalogIdentity(
      cameraID: "camera-a",
      sessionEpoch: UUID(),
      generation: generation,
      snapshotID: snapshotID
    )
    let previous = CameraGalleryCatalogIdentity(
      cameraID: current.cameraID,
      sessionEpoch: UUID(),
      generation: generation,
      snapshotID: snapshotID
    )

    XCTAssertNotEqual(current, previous)
    XCTAssertNotEqual(
      CameraGalleryMediaIdentity(catalog: current, handle: 9, variant: .thumbnail),
      CameraGalleryMediaIdentity(catalog: previous, handle: 9, variant: .thumbnail)
    )
  }

  func testCatalogAccessGateAllowsOnlyOneLogicalOwnerUntilRelease() async throws {
    let gate = CameraCatalogAccessGate()
    let firstOwner = CameraCatalogAccessOwner.gallery(UUID())
    let secondOwner = CameraCatalogAccessOwner.quickDownload(UUID())
    let firstLease = try await gate.acquire(owner: firstOwner)
    let secondDidAcquire = CatalogLeaseAcquisitionFlag()
    let secondTask = Task {
      let lease = try await gate.acquire(owner: secondOwner)
      await secondDidAcquire.markAcquired()
      return lease
    }

    for _ in 0..<20 { await Task.yield() }
    let acquiredBeforeRelease = await secondDidAcquire.value
    XCTAssertFalse(acquiredBeforeRelease)

    await firstLease.release()
    await firstLease.release()
    let secondLease = try await secondTask.value
    let acquiredAfterRelease = await secondDidAcquire.value
    XCTAssertTrue(acquiredAfterRelease)
    await secondLease.release()
  }

  func testCatalogAccessGateCancelsAQueuedOwnerWithoutWaitingForTheActiveLease() async throws {
    let gate = CameraCatalogAccessGate()
    let firstLease = try await gate.acquire(owner: .gallery(UUID()))
    let cancelled = expectation(description: "queued catalog owner cancelled")
    let secondTask = Task {
      do {
        let lease = try await gate.acquire(owner: .quickDownload(UUID()))
        await lease.release()
        XCTFail("A cancelled catalog owner must not acquire the lease")
      } catch is CancellationError {
        cancelled.fulfill()
      } catch {
        XCTFail("Unexpected catalog gate error: \(error)")
      }
    }

    secondTask.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
    await firstLease.release()
    await secondTask.value
  }

  @MainActor
  func testCatalogQueryEngineReturnsExactJpgAndRawUnionWithoutMutatingGalleryState() async throws {
    let source = CameraCatalogQuerySourceSpy(
      exactSnapshots: [
        .jpg: .fixture(handles: [5, 3]),
        .raw: .fixture(handles: [4, 3]),
      ]
    )
    let engine = CameraCatalogQueryEngine(source: source)
    let repository = CameraGalleryRepository()

    let resolution = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg, .raw]),
        date: .all,
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(source.exactRequests, [.jpg, .raw])
    XCTAssertEqual(source.expandedRequestCount, 0)
    XCTAssertEqual(resolution.snapshot.items.map(\.handle), [5, 4, 3])
    XCTAssertNil(repository.generation)
    XCTAssertNil(repository.snapshotID)
  }

  @MainActor
  func testCatalogQueryEngineReusesSameSessionMembershipBeforeCatalogGate() async throws {
    let source = CameraCatalogQuerySourceSpy(
      expandedSnapshot: .fixture(handles: [3, 2, 1])
    )
    let engine = CameraCatalogQueryEngine(source: source)

    let initial = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .all,
        date: .all,
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )
    var cachedProgress: [CameraCatalogQueryProgress] = []
    let projected = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .all,
        date: .all,
        downloadScope: .notDownloaded
      ),
      owner: .quickDownload(UUID()),
      downloadedHandles: [2],
      onProgress: { cachedProgress.append($0) }
    )

    XCTAssertEqual(initial.snapshot.items.map(\.handle), [3, 2, 1])
    XCTAssertEqual(projected.snapshot.items.map(\.handle), [3, 1])
    XCTAssertEqual(source.expandedRequestCount, 1)
    XCTAssertEqual(cachedProgress, [])
  }

  @MainActor
  func testCatalogQueryEngineDoesNotReuseMembershipAcrossFormatPlans() async throws {
    let source = CameraCatalogQuerySourceSpy(
      exactSnapshots: [
        .jpg: .fixture(handles: [5, 3]),
        .raw: .fixture(handles: [4, 2]),
      ]
    )
    let engine = CameraCatalogQueryEngine(source: source)

    _ = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .all,
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )
    let raw = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.raw]),
        date: .all,
        downloadScope: .all
      ),
      owner: .quickDownload(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(source.exactRequests, [.jpg, .raw])
    XCTAssertEqual(raw.snapshot.items.map(\.handle), [4, 2])
  }

  @MainActor
  func testCatalogQueryEngineFallsBackToHandleOrderWhenAnyUnionItemHasNoCaptureDate() async throws {
    func snapshot(_ items: [CameraGalleryCatalogItem]) -> CameraGalleryCatalogSnapshot {
      CameraGalleryCatalogSnapshot(
        snapshotID: CameraGallerySnapshotID(),
        dateGroups: [],
        orderedHandles: items.map { UInt32($0.handle) },
        items: items
      )
    }
    let source = CameraCatalogQuerySourceSpy(
      exactSnapshots: [
        .jpg: snapshot([
          CameraGalleryCatalogItem(
            handle: 3,
            filename: "DSCF0003.JPG",
            formatLabel: "JPG",
            captureDate: "20260726T120000",
            byteSizeText: ""
          ),
          CameraGalleryCatalogItem(
            handle: 1,
            filename: "DSCF0001.JPG",
            formatLabel: "JPG",
            captureDate: "20260728T120000",
            byteSizeText: ""
          ),
        ]),
        .raw: snapshot([
          CameraGalleryCatalogItem(
            handle: 2,
            filename: "DSCF0002.RAF",
            formatLabel: "RAW",
            captureDate: "",
            byteSizeText: ""
          ),
        ]),
      ]
    )
    let engine = CameraCatalogQueryEngine(source: source)

    let resolution = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg, .raw]),
        date: .all,
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(resolution.snapshot.items.map(\.handle), [3, 2, 1])
  }

  @MainActor
  func testCatalogQueryEngineUsesSubtractBaselineWhenHeifIsSelected() async throws {
    let source = CameraCatalogQuerySourceSpy(
      subtractBaselineSnapshots: [.heif: .fixture(handles: [3])]
    )
    let engine = CameraCatalogQueryEngine(source: source)

    let resolution = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.heif]),
        date: .all,
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(source.expandedRequestCount, 0)
    XCTAssertEqual(source.exactRequests, [])
    XCTAssertEqual(source.subtractBaselineRequests, [.heif])
    XCTAssertEqual(resolution.snapshot.items.map(\.handle), [3])
  }

  @MainActor
  func testCatalogQueryEnginePublishesHeifCatalogProgress() async throws {
    let source = CameraCatalogQuerySourceSpy(
      subtractBaselineSnapshots: [.heif: .fixture(handles: [3])]
    )
    let engine = CameraCatalogQueryEngine(source: source)
    var progress: [CameraCatalogQueryProgress] = []

    _ = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .selected([.heif]),
        date: .all,
        downloadScope: .all
      ),
      owner: .quickDownload(UUID()),
      downloadedHandles: [],
      onProgress: { progress.append($0) }
    )

    XCTAssertEqual(progress, [.queryingCatalog])
  }

  @MainActor
  func testCatalogQueryEngineInvalidationRejectsLateHeifSubtractBaselineResult() async {
    let source = CameraCatalogQuerySourceSpy(
      subtractBaselineSnapshots: [.heif: .fixture(handles: [3])]
    )
    source.suspendsSubtractBaselineRequests = true
    let engine = CameraCatalogQueryEngine(source: source)
    let resolutionTask = Task {
      try await engine.resolve(
        rule: CameraMediaFilterRule(
          formats: .selected([.heif]),
          date: .all,
          downloadScope: .all
        ),
        owner: .quickDownload(UUID()),
        downloadedHandles: []
      )
    }

    await source.waitForSubtractBaselineRequestCount(1)
    await engine.invalidate()
    source.releaseSubtractBaselineRequests()

    do {
      _ = try await resolutionTask.value
      XCTFail("Invalidated HEIF query must reject its late result")
    } catch is CancellationError {
      XCTAssertEqual(source.subtractBaselineRequests, [.heif])
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testQuickDownloadHeifSubtractBaselineExposesProgressToConnectingOverlay() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let queryEngine = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraCatalogQueryEngine.swift")
    )
    let quickDownload = try String(
      contentsOf: runner.appendingPathComponent("QuickDownloadUseCase.swift")
    )
    let home = try String(
      contentsOf: runner.appendingPathComponent("NativeConnectViewController.swift")
    )

    XCTAssertTrue(queryEngine.contains("enum CameraCatalogQueryProgress"))
    XCTAssertTrue(queryEngine.contains("loadSubtractBaselineCatalog(for: .heif)"))
    XCTAssertFalse(queryEngine.contains("loadObjectInfo(handle:"))
    XCTAssertTrue(quickDownload.contains("onProgress: @escaping"))
    XCTAssertTrue(home.contains("正在筛选相机照片"))
  }

  func testConnectingOverlayCancellationDisconnectsAnActiveCameraSession() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/NativeConnectViewController.swift")
    )
    let overlayStart = try XCTUnwrap(source.range(of: "overlay.onCancel =")?.lowerBound)
    let hideStart = try XCTUnwrap(
      source.range(of: "private func hideConnectingOverlay", range: overlayStart..<source.endIndex)?.lowerBound
    )
    let cancellationBody = String(source[overlayStart..<hideStart])

    XCTAssertTrue(cancellationBody.contains("cancelConnectFlow("))
    XCTAssertTrue(cancellationBody.contains("cameraSessionRuntime.exitGalleryAndDisconnect("))
    XCTAssertTrue(cancellationBody.contains("overlay?.onCancel = nil"))
    XCTAssertTrue(cancellationBody.contains("expectedBinding:"))
    XCTAssertFalse(cancellationBody.contains("Task { @MainActor"))
  }

  @MainActor
  func testCatalogQueryEngineFailsWholeResolutionWhenHeifSubtractBaselineFails() async {
    let source = CameraCatalogQuerySourceSpy(
      subtractBaselineErrors: [
        .heif: NSError(domain: "CameraCatalogQuerySourceSpy", code: 2),
      ]
    )
    let engine = CameraCatalogQueryEngine(source: source)

    do {
      _ = try await engine.resolve(
        rule: CameraMediaFilterRule(
          formats: .selected([.heif]),
          date: .all,
          downloadScope: .all
        ),
        owner: .gallery(UUID()),
        downloadedHandles: []
      )
      XCTFail("Failed HEIF subtraction must fail the whole resolution")
    } catch {
      XCTAssertEqual(source.subtractBaselineRequests, [.heif])
    }
  }

  func testGalleryFilterStatePassesSharedRuleAndKeepsSortSeparate() {
    let state = NativeGalleryFilterState(
      formats: .selected([.jpg, .raw, .heif]),
      date: .today,
      downloadScope: .notDownloaded,
      sort: .oldest
    )

    XCTAssertEqual(
      state.catalogIntent.rule,
      CameraMediaFilterRule(
        formats: .selected([.jpg, .raw, .heif]),
        date: .today,
        downloadScope: .notDownloaded
      )
    )
    XCTAssertEqual(state.catalogIntent.sort, .oldest)
  }

  func testQuickDownloadUseCaseDoesNotObserveGalleryPresentation() throws {
    let source = try quickDownloadUseCaseSource()

    XCTAssertTrue(source.contains("runtime.activeCameraIdentity"))
    XCTAssertFalse(source.contains("runtime.observe"))
    XCTAssertFalse(source.contains("runtime.presentation"))
    XCTAssertFalse(source.contains("galleryPresentationPayload"))
  }

  func testQuickDownloadUseCaseDoesNotMutateGalleryCatalog() throws {
    let source = try quickDownloadUseCaseSource()

    XCTAssertFalse(source.contains("submitGalleryFilter"))
    XCTAssertFalse(source.contains("CameraGallerySession"))
    XCTAssertFalse(source.contains("CameraGalleryFilterStateStore"))
    XCTAssertFalse(source.contains("CameraAutoDownloadRuleStore"))
  }

  func testQuickDownloadUseCaseUsesSharedFilterEngine() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try quickDownloadUseCaseSource()
    let queryEngine = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraCatalogQueryEngine.swift")
    )

    XCTAssertTrue(source.contains("runtime.resolveCatalog("))
    XCTAssertTrue(source.contains("rule: rule.filter"))
    XCTAssertTrue(source.contains("owner: .quickDownload"))
    XCTAssertTrue(queryEngine.contains("CameraFilterEngine.project("))
    XCTAssertFalse(source.contains("CameraFilterEngine.project("))
  }

  func testQuickDownloadUseCaseSubmitsRuntimeBatchWithConfiguredCompletionPolicy() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try quickDownloadUseCaseSource()
    let ruleSource = try String(
      contentsOf: runner.appendingPathComponent("CameraAutoDownloadRule.swift")
    )

    XCTAssertTrue(source.contains("CameraDownloadSubmission("))
    XCTAssertTrue(source.contains("runtime.submitDownload("))
    XCTAssertTrue(source.contains("origin: .quickDownload"))
    XCTAssertTrue(source.contains("completionPolicy: rule.completionPolicy"))
    XCTAssertTrue(ruleSource.contains("var completionPolicy: CameraDownloadCompletionPolicy"))
    XCTAssertTrue(ruleSource.contains("disconnectAfterDownload ? .disconnectToHome : .returnToGallery"))
  }

  private func quickDownloadUseCaseSource() throws -> String {
    try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/QuickDownloadUseCase.swift")
    )
  }

  private func runnerSource(_ relativePaths: String...) throws -> String {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    return try relativePaths.map { relativePath in
      try String(
        contentsOf: runnerDirectory.appendingPathComponent(relativePath),
        encoding: .utf8
      )
    }.joined(separator: "\n")
  }

  func testCatalogProjectionStaysInsideQueryEngineAndGalleryRuntime() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let runtime = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraGalleryCatalogRuntime.swift")
    )
    let galleryPolicy = try String(
      contentsOf: runner.appendingPathComponent("NativeGalleryPolicies.swift")
    )
    let quick = try quickDownloadUseCaseSource()

    let queryEngine = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraCatalogQueryEngine.swift")
    )

    XCTAssertTrue(queryEngine.contains("CameraFilterEngine.project("))
    XCTAssertTrue(runtime.contains("CameraFilterEngine.project("))
    XCTAssertFalse(galleryPolicy.contains("CameraFilterEngine.project("))
    XCTAssertFalse(quick.contains("CameraFilterEngine.project("))
  }

  func testLegacyIOSGalleryFilterPolicyIsRemovedFromProduction() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryModule.swift")
    )

    XCTAssertFalse(source.contains("IOSCameraGalleryDateFilter"))
    XCTAssertFalse(source.contains("IOSCameraGalleryFormatFilter"))
    XCTAssertFalse(source.contains("IOSCameraGallerySortMode"))
    XCTAssertFalse(source.contains("IOSCameraGalleryFilterState"))
    XCTAssertFalse(source.contains("IOSCameraGalleryPolicy"))
    XCTAssertFalse(source.contains("matchesFormat(_ formatLabel"))
  }

  func testQuickSettingsUsesSharedFourFormatMultiSelectionWithoutPresetsOrVideo() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/NativeAutoDownloadSettingsViewController.swift")
    )

    XCTAssertTrue(source.contains("[\"all\", \"jpg\", \"raw\", \"heif\"]"))
    XCTAssertTrue(source.contains("allowsMultipleSelection = true"))
    XCTAssertTrue(source.contains("exclusiveSelectionID = \"all\""))
    XCTAssertFalse(source.contains("JPG + RAW"))
    XCTAssertFalse(source.contains("JPG + HEIF"))
    XCTAssertFalse(source.contains("视频"))
  }

  func testGalleryFormatUIUsesSharedMultiSelectionAndKeepsSortSeparate() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )

    XCTAssertTrue(source.contains("formatChips.allowsMultipleSelection = true"))
    XCTAssertTrue(source.contains("formatChips.exclusiveSelectionID = \"all\""))
    XCTAssertFalse(source.contains(".init(id: \"video\", title: \"视频\")"))
    XCTAssertTrue(source.contains("rule: filterState.rule"))
    XCTAssertTrue(source.contains("sort: filterState.sortIntent"))
    XCTAssertTrue(source.contains("NativeGalleryFilterState(sort: filterState.sort)"))
  }

  func testGalleryDatePickerOnlyOpensFromTheDateControl() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )

    XCTAssertTrue(source.contains("dateChips.onSelected = { [weak self] selectedID in self?.dateChipSelected(selectedID) }"))
    XCTAssertTrue(source.contains("sortChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }"))
    XCTAssertTrue(source.contains("formatChips.onSelectionChanged = { [weak self] _ in self?.chipFilterChanged() }"))
    XCTAssertTrue(source.contains("downloadScopeChips.onSelected = { [weak self] _ in self?.chipFilterChanged() }"))

    let sharedStart = try XCTUnwrap(
      source.range(of: "@objc private func chipFilterChanged()")?.lowerBound
    )
    let sharedEnd = try XCTUnwrap(
      source.range(of: "private func configureGalleryToolsMenu()", range: sharedStart..<source.endIndex)?.lowerBound
    )
    let sharedBody = String(source[sharedStart..<sharedEnd])
    XCTAssertFalse(sharedBody.contains("presentDatePicker()"))
    XCTAssertFalse(sharedBody.contains("switch dateChips.selectedID"))
  }

  func testNativePairedCameraCardShowsQuickDownloadAndGalleryAsEqualPrimaryActions() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let cardSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeScanViewController.swift"),
      encoding: .utf8
    )
    let homeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(cardSource.contains("quickDownloadControl"))
    XCTAssertTrue(cardSource.contains("quickDownloadColumn"))
    XCTAssertTrue(cardSource.contains("quickDownloadButton"))
    XCTAssertTrue(cardSource.contains("quickDownloadSettingsButton"))
    XCTAssertTrue(cardSource.contains("quickDownloadSummary"))
    XCTAssertTrue(
      cardSource.contains(
        "let quickDownloadColumn = UIStackView(arrangedSubviews: [quickDownloadButton, quickDownloadSettingsButton])"
      )
    )
    XCTAssertTrue(
      cardSource.contains(
        "let primaryActionStack = UIStackView(arrangedSubviews: [quickDownloadColumn, connectButton])"
      )
    )
    XCTAssertTrue(cardSource.contains("primaryActionStack.axis = .horizontal"))
    XCTAssertTrue(cardSource.contains("primaryActionStack.alignment = .top"))
    XCTAssertTrue(cardSource.contains("primaryActionStack.distribution = .fillEqually"))
    XCTAssertTrue(cardSource.contains("onQuickDownload"))
    XCTAssertTrue(cardSource.contains("onQuickDownloadSettings"))
    XCTAssertTrue(cardSource.contains("quickDownloadButton.heightAnchor.constraint(equalToConstant: 44)"))
    XCTAssertTrue(cardSource.contains("connectButton.heightAnchor.constraint(equalToConstant: 44)"))
    XCTAssertTrue(cardSource.contains("quickDownloadSettingsButton.configuration?.title = quickDownloadSummary"))
    XCTAssertTrue(cardSource.contains("UIFont.systemFont(ofSize: 12, weight: .semibold)"))
    XCTAssertTrue(cardSource.contains("quickDownloadSettingsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)"))
    XCTAssertFalse(homeSource.contains("let autoDownloadButton = UIButton(type: .system)"))
    XCTAssertTrue(
      homeSource.contains(
        "quickDownloadSummary: autoDownloadRule.isEnabled ? autoDownloadRule.summaryText : \"首次需设置参数\""
      )
    )
    XCTAssertTrue(homeSource.contains("onQuickDownloadSettings:"))
    XCTAssertFalse(homeSource.contains("makeAutoDownloadRuleRow()"))
  }

  func testNativeHomeQuickDownloadFirstSaveStartsExistingPendingDownloadFlow() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let homeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift"),
      encoding: .utf8
    )
    let settingsSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeAutoDownloadSettingsViewController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(homeSource.contains("private func quickDownloadTapped(record:"))
    XCTAssertTrue(homeSource.contains("NativeHomeQuickDownloadEntryPolicy.action(ruleIsEnabled: autoDownloadRule.isEnabled)"))
    XCTAssertTrue(homeSource.contains("saveButtonTitle: \"开始下载\""))
    XCTAssertTrue(homeSource.contains("forcesEnabledOnSave: true"))
    XCTAssertTrue(homeSource.contains("connectRememberedCamera(record, purpose: .quickDownload)"))
    XCTAssertFalse(homeSource.contains("isAutoDownloadPending"))
    XCTAssertTrue(settingsSource.contains("saveButtonTitle: String = \"保存\""))
    XCTAssertTrue(settingsSource.contains("forcesEnabledOnSave: Bool = false"))
    XCTAssertTrue(
      settingsSource.contains(
        "title = forcesEnabledOnSave ? \"快速下载参数\" : \"自动下载规则\""
      )
    )
    XCTAssertFalse(settingsSource.contains("启用自动下载"))
    XCTAssertFalse(settingsSource.contains("enableSwitch"))
    XCTAssertFalse(settingsSource.contains("enableChanged"))
    XCTAssertTrue(settingsSource.contains("点击快速下载后，将按此规则筛选并开始下载。"))
    XCTAssertFalse(settingsSource.contains("连接相机后将自动按此规则筛选并开始下载"))
    XCTAssertTrue(
      settingsSource.contains(
        "NativeAutoDownloadSettingsSavePolicy.resolvedRule(rule, forcesEnabled: forcesEnabledOnSave)"
      )
    )
  }

  func testNativeWiredImportEntryPolicyRequiresDetectedDevice() {
    XCTAssertFalse(NativeWiredImportEntryPolicy.canOpenImport(deviceCount: 0))
    XCTAssertTrue(NativeWiredImportEntryPolicy.canOpenImport(deviceCount: 1))
    XCTAssertEqual(NativeWiredImportEntryPolicy.noDeviceTitle, "需要有线连接")
    XCTAssertEqual(
      NativeWiredImportEntryPolicy.noDeviceMessage,
      "请先用数据线连接相机，并在相机上开启 USB 传输或读卡模式。"
    )
  }

  func testGallerySelectAllSkipsItemsAlreadyInDownloadList() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "2 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "3 MB"),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [2, 3])
    state.markDownloadStarted(handle: 3)
    state.selectAll()

    XCTAssertEqual(state.selectedHandles, [1])
  }

  func testNativeGalleryFilterPolicyDoesNotReapplyRuntimeFormatProjection() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 4, filename: "0x00000004", formatLabel: "", captureDate: "", byteSizeText: ""),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.heif])),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [4, 3, 2, 1])
  }

  func testNativeGalleryFilterStateKeepsExactlyOneFormat() {
    let state = NativeGalleryFilterState(formats: .selected([.raw]))

    XCTAssertEqual(state.formats, .selected([.raw]))
    XCTAssertFalse(state.isAllFormats)
  }

  func testGalleryFilterRefreshPublishesOnlyRuntimeCatalogPresentation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let applyStart = try XCTUnwrap(
      source.range(of: "private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation)")?.lowerBound
    )
    let applyEnd = try XCTUnwrap(
      source.range(of: "private func invalidateThumbnailDecodes", range: applyStart..<source.endIndex)?.lowerBound
    )
    let applyBody = String(source[applyStart..<applyEnd])

    XCTAssertTrue(applyBody.contains("galleryRenderState.replacingPresentation(presentation)"))
    XCTAssertFalse(applyBody.contains("galleryState.replaceItems(presentation.items)"))
    XCTAssertTrue(applyBody.contains("selectedHandles.formIntersection(presentation.items.map(\\.handle))"))
    XCTAssertFalse(source.contains("completeGalleryCatalogTask"))
    XCTAssertFalse(source.contains("allGalleryItems"))
    XCTAssertFalse(source.contains("runtime.requestCameraCatalog(query:"))
  }

  func testNativeGalleryApplyCatalogPresentationInstallsAtomicRenderStateWithoutLegacyCopies() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let applyStart = try XCTUnwrap(
      source.range(of: "private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation)")?.lowerBound
    )
    let applyEnd = try XCTUnwrap(
      source.range(of: "private func invalidateThumbnailDecodes", range: applyStart..<source.endIndex)?.lowerBound
    )
    let applyBody = String(source[applyStart..<applyEnd])

    XCTAssertTrue(applyBody.contains("galleryRenderState.replacingPresentation(presentation)"))
    XCTAssertTrue(applyBody.contains("galleryRenderState = nextRenderState"))
    XCTAssertFalse(applyBody.contains("catalogPresentation = presentation"))
    XCTAssertFalse(applyBody.contains("refreshGallerySections()"))
  }

  func testNativeGalleryViewDidAppearResubmitsTheCurrentVisibleThumbnailWindow() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let appearStart = try XCTUnwrap(
      source.range(of: "override func viewDidAppear(_ animated: Bool)")?.lowerBound
    )
    let disappearStart = try XCTUnwrap(
      source.range(of: "override func viewWillDisappear(_ animated: Bool)", range: appearStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[appearStart..<disappearStart])

    XCTAssertTrue(body.contains("scheduleVisibleThumbnailRefresh(after: 0)"))
  }

  func testNativeGalleryViewWillDisappearAllowsTheSameViewportToBeResubmitted() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let disappearStart = try XCTUnwrap(
      source.range(of: "override func viewWillDisappear(_ animated: Bool)")?.lowerBound
    )
    let preferredStyleStart = try XCTUnwrap(
      source.range(of: "override var preferredStatusBarStyle", range: disappearStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[disappearStart..<preferredStyleStart])

    XCTAssertTrue(body.contains("visibleThumbnailRefreshWorkItem?.cancel()"))
    XCTAssertTrue(body.contains("lastSubmittedThumbnailViewportIdentity = nil"))
  }

  func testNativeGalleryCatalogReplacementSettlesAtTheTopBeforeSchedulingThumbnails() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let applyStart = try XCTUnwrap(
      source.range(of: "private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation)")?.lowerBound
    )
    let applyEnd = try XCTUnwrap(
      source.range(of: "private func invalidateThumbnailDecodes", range: applyStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[applyStart..<applyEnd])

    XCTAssertTrue(body.contains("lastSubmittedThumbnailViewportIdentity = nil"))
    XCTAssertTrue(body.contains("collectionView.setContentOffset"))
    XCTAssertTrue(body.contains("scheduleVisibleThumbnailRefresh(after: 0)"))
    XCTAssertFalse(body.contains("loadVisibleThumbnails()"))
  }

  func testNativeGalleryOrientationRefreshKeepsThePreviousDecodedImageUntilReplacementIsReady() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let invalidateStart = try XCTUnwrap(
      source.range(of: "private func invalidateThumbnailDecodes(forHandles handles: Set<Int>)")?.lowerBound
    )
    let cacheKeyStart = try XCTUnwrap(
      source.range(of: "private func decodedThumbnailCacheKey", range: invalidateStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[invalidateStart..<cacheKeyStart])

    XCTAssertFalse(body.contains("thumbnailImageCache.removeObject"))
    XCTAssertFalse(body.contains("thumbnailCacheKeysByHandle.removeValue"))
  }

  func testCameraSessionRuntimeStampsViewportRequestsBeforeAsyncSubmission() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionRuntime.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let requestStart = try XCTUnwrap(
      source.range(of: "func requestVisibleGalleryThumbnails(handles: [Int])")?.lowerBound
    )
    let requestEnd = try XCTUnwrap(
      source.range(of: "func cancelActiveThumbnailWork", range: requestStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[requestStart..<requestEnd])

    XCTAssertTrue(body.contains("galleryThumbnailViewportRevision &+= 1"))
    XCTAssertTrue(body.contains("submissionID:"))
    XCTAssertTrue(body.contains("expectedCatalogIdentity:"))
  }

  func testNativeGalleryVisibleThumbnailLoaderSubmitsOnlyChangedViewportIdentity() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let loadStart = try XCTUnwrap(
      source.range(of: "private func loadVisibleThumbnails()")?.lowerBound
    )
    let loadEnd = try XCTUnwrap(
      source.range(of: "private func rehydrateCachedThumbnailImages", range: loadStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[loadStart..<loadEnd])

    XCTAssertTrue(body.contains("NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit("))
    XCTAssertTrue(body.contains("orderedHandles: requestedHandles"))
    XCTAssertTrue(body.contains("retryableFailedHandles:"))
    XCTAssertTrue(body.contains("lastSubmittedThumbnailViewportIdentity = nextViewportIdentity"))
    XCTAssertTrue(body.contains("expectedCatalogIdentity: nextViewportIdentity.catalogIdentity"))

    let duplicateGuard = try XCTUnwrap(
      body.range(of: "NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(")
    )
    let submittedLog = try XCTUnwrap(body.range(of: "THUMBNAIL_VIEWPORT_SUBMIT"))
    XCTAssertLessThan(
      duplicateGuard.lowerBound,
      submittedLog.lowerBound,
      "A SUBMIT event must only be emitted after the duplicate viewport guard accepts the handoff"
    )
  }

  func testNativeGalleryIncrementalUpdateResubmitsRetryableThumbnailFailureOnce() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let observerStart = try XCTUnwrap(
      source.range(of: "incrementalCatalogObserverID = runtime.observeIncrementalCatalogUpdates")?.lowerBound
    )
    let observerEnd = try XCTUnwrap(
      source.range(of: "galleryPreviewObserverID = runtime.observeGalleryPreview", range: observerStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[observerStart..<observerEnd])

    XCTAssertTrue(body.contains("retryableFailedHandles"))
    XCTAssertTrue(body.contains("scheduleVisibleThumbnailRefresh(after:"))
  }

  func testThumbnailOrientationDiagnosticIncludesCameraObjectInfoForUIKitOrientedImages() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let branchStart = try XCTUnwrap(
      source.range(of: "if cropped.imageOrientation != .up")?.lowerBound
    )
    let branchEnd = try XCTUnwrap(
      source.range(of: "let decision = NativePhotoPreviewRotationPolicy.rotationDecision(", range: branchStart..<source.endIndex)?.lowerBound
    )
    let branch = String(source[branchStart..<branchEnd])

    XCTAssertTrue(branch.contains("object=\\(objectOrientation.map(String.init) ?? \"unknown\")"))
  }

  func testNativeGallerySelectionButtonKeepsVisualSizeAndExpandsHitTarget() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("private let selectionButton: UIButton"))
    XCTAssertTrue(source.contains("selectionButton.addTarget(self, action: #selector(selectionTapped)"))
    XCTAssertTrue(source.contains("selectionButton.widthAnchor.constraint(equalToConstant: 26)"))
    XCTAssertTrue(source.contains("selectionButton.heightAnchor.constraint(equalToConstant: 26)"))
  }

  func testNativeGalleryIncrementalObserverReloadsOnlyForStructuralDeltaAndDoesNotStartCameraWork() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let applyStart = try XCTUnwrap(
      source.range(of: "incrementalCatalogObserverID = runtime.observeIncrementalCatalogUpdates")?.lowerBound
    )
    let applyEnd = try XCTUnwrap(
      source.range(of: "galleryPreviewObserverID = runtime.observeGalleryPreview", range: applyStart..<source.endIndex)?.lowerBound
    )
    let applyBody = String(source[applyStart..<applyEnd])

    XCTAssertTrue(applyBody.contains("galleryRenderState.applyingIncremental("))
    XCTAssertTrue(applyBody.contains("if delta.requiresStructuralRefresh"))
    XCTAssertTrue(applyBody.contains("collectionView.reloadData()"))
    XCTAssertFalse(applyBody.contains("loadVisibleThumbnails()"))
    XCTAssertFalse(applyBody.contains("requestVisibleGalleryThumbnails"))
  }

  func testNativeGalleryIncrementalObserverRefreshesActiveHDSnapshot() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let observerStart = try XCTUnwrap(
      source.range(of: "incrementalCatalogObserverID = runtime.observeIncrementalCatalogUpdates")?.lowerBound
    )
    let observerEnd = try XCTUnwrap(
      source.range(of: "galleryPreviewObserverID = runtime.observeGalleryPreview", range: observerStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[observerStart..<observerEnd])

    XCTAssertTrue(body.contains("if self.browseMode == .highDefinition"))
    XCTAssertTrue(body.contains("scheduleHDPreviewSnapshotRefresh("))
    XCTAssertTrue(source.contains("NativeGalleryHDPreviewSessionPolicy.snapshot("))
    XCTAssertTrue(source.contains("runtime.updateGalleryHDPreviewSnapshot("))
  }

  func testGalleryFormatSelectionUsesTheRuntimeCameraCatalogTransaction() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let gallerySource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )

    let chipStart = try XCTUnwrap(gallerySource.range(of: "@objc private func chipFilterChanged()")?.lowerBound)
    let chipEnd = try XCTUnwrap(
      gallerySource.range(
        of: "private func submitGalleryIntent()",
        range: chipStart..<gallerySource.endIndex
      )?.lowerBound
    )
    let chipBody = String(gallerySource[chipStart..<chipEnd])

    XCTAssertTrue(chipBody.contains("filterState.formats = CameraMediaFormatSelection.normalized(selectedFormats)"))
    XCTAssertTrue(chipBody.contains("submitGalleryIntent()"))
  }

  func testGalleryFilterRefreshUsesCameraCatalogInsteadOfObjectInfoOrThumbnailIndex() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let gallerySource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )

    XCTAssertTrue(gallerySource.contains("private func submitGalleryIntent()"))
    XCTAssertFalse(gallerySource.contains("catalogSubmission"))
    XCTAssertTrue(gallerySource.contains("runtime.submitGalleryFilter("))
    XCTAssertTrue(gallerySource.contains("rule: filterState.rule"))
    XCTAssertTrue(gallerySource.contains("sort: filterState.sortIntent"))
    XCTAssertFalse(gallerySource.contains("submitUnsupportedGalleryFilter"))
    XCTAssertTrue(gallerySource.contains("private func applyCatalogPresentation(_ presentation: CameraGalleryPresentation)"))
    XCTAssertFalse(gallerySource.contains("runtime.requestCameraCatalog(query:"))
    XCTAssertFalse(gallerySource.contains("runtime.requestCompleteGalleryCatalog()"))
    XCTAssertFalse(gallerySource.contains("NativeGalleryFormatIndex"))
    XCTAssertFalse(gallerySource.contains("presentationState.format = .all"))
  }

  func testNativeGalleryFilterPolicyDoesNotUseFormatHintsForMembership() {
    let items = [
      CameraVendorGalleryItem(
        handle: 9,
        filename: "0x00000009",
        formatLabel: "",
        captureDate: "20260624",
        byteSizeText: "",
        formatHints: [.heif, .raw]
      ),
    ]

    let heifFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.heif])),
      now: Date(timeIntervalSince1970: 0)
    )
    let rawFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.raw])),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(heifFiltered.map(\.handle), [9])
    XCTAssertEqual(rawFiltered.map(\.handle), [9])
  }

  func testNativeGalleryFilterPolicyDoesNotUseResolvedFormatLabelForMembership() {
    let items = [
      CameraVendorGalleryItem(
        handle: 11,
        filename: "DSCF0011.HEIC",
        formatLabel: "HEIF",
        captureDate: "20260624",
        byteSizeText: "8 MB",
        formatHints: [.heif, .raw]
      ),
      CameraVendorGalleryItem(
        handle: 12,
        filename: "DSCF0012.RAF",
        formatLabel: "RAW",
        captureDate: "20260624",
        byteSizeText: "42 MB",
        formatHints: [.heif, .raw]
      ),
    ]

    let rawFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.raw])),
      now: Date(timeIntervalSince1970: 0)
    )
    let heifFiltered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.heif])),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(rawFiltered.map(\.handle), [12, 11])
    XCTAssertEqual(heifFiltered.map(\.handle), [12, 11])
  }

  func testNativeGalleryFilterPerformancePolicyCachesCaptureDatesDuringFilter() {
    XCTAssertTrue(NativeGalleryFilterPerformancePolicy.shouldBuildCaptureDateIndex)
    XCTAssertTrue(NativeGalleryFilterPerformancePolicy.shouldDisableReloadAnimation)
  }

  func testNativeGalleryFilterPolicyLeavesMembershipToCatalogRuntime() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "0x3000", captureDate: "", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 3, filename: "A.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.jpg])),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [3, 2, 1])
  }

  func testNativeGalleryFormatDisplayPolicyHidesUnresolvedPlaceholderFormat() {
    let unresolvedEmpty = CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "", byteSizeText: "")
    let unresolvedHex = CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "0x3000", captureDate: "", byteSizeText: "")
    let heif = CameraVendorGalleryItem(handle: 3, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "", byteSizeText: "2 MB")

    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: unresolvedEmpty))
    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: unresolvedHex))
    XCTAssertEqual(NativeGalleryFormatDisplayPolicy.badgeText(for: heif), " HEIF ")
    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.previewSubtitle(index: 0, total: 3, item: unresolvedEmpty),
      "1 / 3"
    )
  }

  func testNativeGalleryFormatDisplayPolicyPrefersStableFilenameExtensionOverAmbiguousHints() {
    let stableJpg = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "",
      captureDate: "",
      byteSizeText: "4 MB",
      formatHints: [.heif, .raw]
    )

    XCTAssertEqual(NativeGalleryFormatDisplayPolicy.badgeText(for: stableJpg), " JPG ")
    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.previewSubtitle(index: 0, total: 1, item: stableJpg),
      "1 / 1 · JPG · 4 MB"
    )
  }

  func testNativeGalleryFormatDisplayPolicyPrefersRepositoryViewStateOverLegacyHints() {
    let hintedPlaceholder = CameraVendorGalleryItem(
      handle: 8,
      filename: "0x00000008",
      formatLabel: "",
      captureDate: "",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let resolvedViewState = CameraGalleryEntryViewState(
      summary: CameraGalleryEntrySummary(
        handle: 8,
        filename: .confirmed("DSCF0008.RAF"),
        format: .confirmed(.raw),
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(8)
      ),
      thumbnail: CameraGalleryEntryThumbnail(handle: 8, state: .loaded, imageData: nil),
      details: CameraGalleryEntryDetails(
        handle: 8,
        orientation: .confirmed(1),
        refinedFormat: .confirmed(.raw),
        notes: []
      )
    )

    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.badgeText(
        for: hintedPlaceholder,
        viewState: resolvedViewState
      ),
      " RAW "
    )
    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.previewSubtitle(
        index: 0,
        total: 1,
        item: hintedPlaceholder,
        viewState: resolvedViewState
      ),
      "1 / 1 · RAW"
    )
  }

  func testNativeGalleryFormatDisplayPolicyHidesFormatUntilRepositoryStateResolves() {
    let hintedPlaceholder = CameraVendorGalleryItem(
      handle: 9,
      filename: "0x00000009",
      formatLabel: "",
      captureDate: "",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let unresolvedViewState = CameraGalleryEntryViewState(
      summary: CameraGalleryEntrySummary(
        handle: 9,
        filename: .confirmed("DSCF0009.HEIC"),
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(9)
      ),
      thumbnail: CameraGalleryEntryThumbnail(handle: 9, state: .loaded, imageData: nil),
      details: CameraGalleryEntryDetails(
        handle: 9,
        orientation: .unknown,
        refinedFormat: .unknown,
        notes: []
      )
    )

    XCTAssertNil(
      NativeGalleryFormatDisplayPolicy.badgeText(
        for: hintedPlaceholder,
        viewState: unresolvedViewState
      )
    )
    XCTAssertEqual(
      NativeGalleryFormatDisplayPolicy.previewSubtitle(
        index: 0,
        total: 1,
        item: hintedPlaceholder,
        viewState: unresolvedViewState
      ),
      "1 / 1"
    )
  }

  func testNativeGalleryFilterStateDefaultsToAllDatesAndFormat() {
    let state = NativeGalleryFilterState()

    XCTAssertEqual(state.date, .all)
    XCTAssertEqual(state.formats, .all)
    XCTAssertEqual(state.sort, .newest)
  }

  func testNativeGalleryRenderStateUpdatesSectionContentWithoutStructuralRebuild() throws {
    let generation = CameraGalleryGenerationID(rawValue: 1)
    let snapshotID = CameraGallerySnapshotID()
    let initialItem = CameraGalleryCatalogItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:29 10:30:00",
      byteSizeText: "1 MB"
    )
    let initialPresentation = CameraGalleryPresentation(
      state: .ready(generation: generation, snapshotID: snapshotID),
      intent: .all,
      items: [initialItem],
      entries: []
    )
    let state = NativeGalleryRenderState(presentation: initialPresentation)
    var updatedItem = initialItem
    updatedItem.thumbnailData = Data([7, 7, 7])
    let updatedPresentation = CameraGalleryPresentation(
      state: .ready(generation: generation, snapshotID: snapshotID),
      intent: .all,
      items: [updatedItem],
      entries: []
    )
    let delta = CameraGalleryIncrementalDelta(
      changedHandles: [7],
      orientationChangedHandles: [],
      requiresStructuralRefresh: false
    )

    let updatedState = state.applyingIncremental(
      presentation: updatedPresentation,
      delta: delta
    )

    XCTAssertEqual(updatedState.sections.map(\.title), state.sections.map(\.title))
    XCTAssertEqual(updatedState.sections.map(\.day), state.sections.map(\.day))
    XCTAssertEqual(try XCTUnwrap(updatedState.sections.first?.items.first).thumbnailData, Data([7, 7, 7]))
    XCTAssertEqual(updatedState.presentation, updatedPresentation)
  }

  func testNativeGalleryRenderStateSkipsIdenticalFullPresentation() {
    let presentation = CameraGalleryPresentation.unavailable
    let state = NativeGalleryRenderState(presentation: presentation)

    XCTAssertNil(state.replacingPresentation(presentation))
  }

  func testNativeGalleryFilterPolicySortsNewestAndOldestLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let newest = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .newest),
      now: Date(timeIntervalSince1970: 0)
    )
    let oldest = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .oldest),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(newest.map(\.handle), [3, 2, 1])
    XCTAssertEqual(oldest.map(\.handle), [1, 2, 3])
  }

  func testNativeGalleryFilterPolicySortsNotDownloadedFirstLikeAndroid() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:34:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:33:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(sort: .notDownloaded),
      downloadedHandles: [1],
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(filtered.map(\.handle), [2, 3, 1])
  }

  func testNativeGallerySectionPolicyGroupsFilesByCaptureDateLikeAndroid() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 3, filename: "C.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 1, filename: "A.RAF", formatLabel: "RAW", captureDate: "2026:05:03 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 9, filename: "Z.JPG", formatLabel: "JPG", captureDate: "", byteSizeText: "1 MB"),
    ]

    let sections = NativeGallerySectionPolicy.sections(from: items, now: now, calendar: calendar)

    XCTAssertEqual(sections.map(\.title), ["今天 5月4日 2 张", "5月3日 1 张", "未知日期 1 张"])
    XCTAssertEqual(sections.map { $0.items.map(\.handle) }, [[3, 2], [1], [9]])
  }

  func testNativeGalleryThumbnailRequestWindowPrioritizesVisibleHandlesLikeAndroid() {
    let handles = Array(1...30)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [10, 11, 12],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 11, 12])
    XCTAssertEqual(request, [10, 11, 12, 13, 14, 15, 16, 17, 18, 7, 8, 9])
  }

  func testNativeGalleryThumbnailRequestWindowSortsUnorderedVisibleHandlesByGalleryOrder() {
    let handles = Array(1...30)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [12, 10, 11],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 11, 12])
    XCTAssertEqual(request, [10, 11, 12, 13, 14, 15, 16, 17, 18, 7, 8, 9])
  }

  func testNativeGalleryThumbnailRequestWindowDoesNotBridgeSparseVisibleHandles() {
    let handles = Array(1...1_600)

    let request = NativeGalleryThumbnailRequestWindowPolicy.handlesToRequest(
      orderedHandles: handles,
      visibleHandles: [10, 1_498, 1_499],
      columnCount: 3
    )

    XCTAssertEqual(Array(request.prefix(3)), [10, 1_498, 1_499])
    XCTAssertLessThanOrEqual(request.count, 18)
    XCTAssertFalse(request.contains(800))
  }

  func testNativeGalleryThumbnailViewportSubmissionOnlyChangesForCatalogOrOrderedWindow() {
    let firstCatalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let secondCatalog = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: firstCatalog.sessionEpoch,
      generation: 2
    )
    let first = NativeGalleryThumbnailViewportIdentity(
      catalogIdentity: firstCatalog,
      orderedHandles: [10, 11, 12]
    )

    XCTAssertTrue(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: nil,
        next: first
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: first,
        next: first
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: first,
        next: NativeGalleryThumbnailViewportIdentity(
          catalogIdentity: firstCatalog,
          orderedHandles: [11, 12, 13]
        )
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: first,
        next: NativeGalleryThumbnailViewportIdentity(
          catalogIdentity: secondCatalog,
          orderedHandles: [10, 11, 12]
        )
      )
    )

    let retryableFailure = NativeGalleryThumbnailViewportIdentity(
      catalogIdentity: firstCatalog,
      orderedHandles: [10, 11, 12],
      retryableFailedHandles: [10]
    )
    XCTAssertTrue(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: first,
        next: retryableFailure
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailViewportSubmissionPolicy.shouldSubmit(
        previous: retryableFailure,
        next: retryableFailure
      )
    )
  }

  func testNativeGalleryFilterPolicyOnlySortsRuntimeProjectedItems() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "2026:05:04 10:32:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.heif]), date: .today),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [3, 2, 1])
  }

  func testNativeGalleryFilterPolicyDoesNotReapplyDateProjection() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.JPG", formatLabel: "JPG", captureDate: "2026:05:03 10:30:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(date: .today),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [1, 2])
  }

  func testNativeGalleryFilterPolicyDoesNotCombineDuplicateMembershipFilters() {
    let calendar = Calendar(identifier: .gregorian)
    let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4, hour: 12))!
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "2026:05:04 10:30:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "2026:05:04 10:31:00", byteSizeText: "1 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.HEIC", formatLabel: "HEIF", captureDate: "2026:04:20 10:31:00", byteSizeText: "1 MB"),
    ]

    let filtered = NativeGalleryFilterPolicy.filteredItems(
      items,
      state: NativeGalleryFilterState(formats: .selected([.heif]), date: .today),
      now: now
    )

    XCTAssertEqual(filtered.map(\.handle), [2, 1, 3])
  }

  func testHandshakeCompletionSummaryContainsDeviceAndSerial() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "1234",
      preferredWifiNetwork: nil
    )

    XCTAssertEqual(summary.navigationTitle, "DEVICE-A")
    XCTAssertTrue(summary.subtitle.contains("1234"))
  }

  func testPairedCameraStoreRoundTripsSavedCamera() throws {
    let suiteName = "RunnerTests.PairedCameraStore.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "abc12345",
        isHidden: true
      )
    )

    store.save(record)

    XCTAssertEqual(store.load(), record)
    XCTAssertEqual(store.load()?.connectionSummary.connectedDeviceName, "iPhone-0426")
  }

  func testPairedCameraStoreKeepsMultipleSavedCameras() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Multiple.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let first = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: nil
    )
    let second = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "87654321-4321-4321-4321-BA0987654321")!,
      deviceName: "CAMERA DEVICE-B",
      serialNumber: "221019F1932011003C",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-B-003C",
        passphrase: "abc12345",
        isHidden: false
      )
    )

    store.save(first)
    store.save(second)

    XCTAssertEqual(store.loadAll(), [second, first])
  }

  func testStoredPairingPolicyRequiresOfficialWifiConfigurationBeforeGallery() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: nil
    )

    XCTAssertFalse(CameraVendorStoredPairingPolicy.canEnterGallery(record: record))
  }

  func testStoredPairingPolicyAllowsLegacyRecordUntilExplicitBluetoothFailure() {
    let legacyRecord = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
    let validatedRecord = CameraVendorPairedCameraRecord(
      peripheralID: legacyRecord.peripheralID,
      deviceName: legacyRecord.deviceName,
      serialNumber: legacyRecord.serialNumber,
      connectedDeviceName: legacyRecord.connectedDeviceName,
      appVariant: legacyRecord.appVariant,
      preferredWifiNetwork: legacyRecord.preferredWifiNetwork,
      systemBluetoothPairingValidatedAt: Date(timeIntervalSince1970: 1_788_000_000)
    )

    XCTAssertTrue(CameraVendorStoredPairingPolicy.canEnterGallery(record: legacyRecord))
    XCTAssertFalse(CameraVendorStoredPairingPolicy.shouldRequireSystemBluetoothCleanupForUnverifiedRecord(legacyRecord))
    XCTAssertTrue(CameraVendorStoredPairingPolicy.canEnterGallery(record: validatedRecord))
  }

  func testStoredPairingPolicyRejectsRememberedRecordWhenHandshakeIdentityMismatches() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "CAMERA DEVICE-A",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
    let mismatchedSummary = CameraVendorConnectionSummary(
      deviceName: "CAMERA DEVICE-B",
      serialNumber: "221019F1932011003C",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-B-003C",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:00"
      )
    )

    XCTAssertFalse(
      CameraVendorStoredPairingPolicy.matchesRememberedIdentity(
        record: record,
        summary: mismatchedSummary,
        peripheralID: record.peripheralID
      )
    )
  }

  func testStoredPairingPolicyMatchesAndroidStableCameraIdentityBeforePeripheralID() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
    let sameCameraSummary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )

    XCTAssertTrue(
      CameraVendorStoredPairingPolicy.matchesRememberedIdentity(
        record: record,
        summary: sameCameraSummary,
        peripheralID: UUID(uuidString: "87654321-4321-4321-4321-BA0987654321")!
      )
    )
  }

  func testIOSRememberedGalleryEntryGateRequiresUserApprovalBeforeReconnect() {
    XCTAssertEqual(
      IOSCameraRememberedGalleryEntryGate.evaluate(
        hasSystemCleanupBlock: false,
        hasUserApproval: false,
        hasInFlightAttempt: false,
        hasOfficialWifiRecord: true
      ),
      .ignoreUntilUserApproval
    )
  }

  func testIOSRememberedGalleryEntryGateFailsWhenOfficialWifiRecordMissing() {
    XCTAssertEqual(
      IOSCameraRememberedGalleryEntryGate.evaluate(
        hasSystemCleanupBlock: false,
        hasUserApproval: true,
        hasInFlightAttempt: false,
        hasOfficialWifiRecord: false
      ),
      .failMissingOfficialWifiRecord
    )
  }

  func testIOSHandshakeCompletionGateWaitsUntilPairingAndTransferAreReady() {
    XCTAssertEqual(
      IOSCameraHandshakeCompletionGate.evaluate(
        didCompleteHandshake: false,
        isRunningPostHandshakeProbe: false,
        isRunningTransferActivation: false,
        hasCompletedPairing: false,
        hasUserInitiatedTransfer: false,
        hasPendingHandshakeSummary: true,
        hasAttemptedAutomaticTransferActivation: false,
        transferActivationObservedChange: false,
        transferActivationObservedWifiLaunch: false,
        hadAutomaticTransferActivationFeature: false
      ),
      .wait
    )
  }

  func testIOSHandshakeCompletionGateFailsWhenActivationNeverReachedReady() {
    XCTAssertEqual(
      IOSCameraHandshakeCompletionGate.evaluate(
        didCompleteHandshake: false,
        isRunningPostHandshakeProbe: false,
        isRunningTransferActivation: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        hasAttemptedAutomaticTransferActivation: true,
        transferActivationObservedChange: false,
        transferActivationObservedWifiLaunch: false,
        hadAutomaticTransferActivationFeature: true
      ),
      .failActivationNotReady
    )
  }

  func testRememberedGalleryServiceUsesCameraCoreGateForEntryDecision() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func connectPairedCamera(peripheralID: UUID) -> Bool")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "  @discardableResult\n  func startRememberedCameraConnection(peripheralID: UUID) -> Bool", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("IOSCameraRememberedConnectionFlowDriver.connectPairedCamera"))
  }

  func testHandshakeServiceUsesCameraCoreGateForCompletionDecision() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private func finishHandshakeIfPossible()")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "  private func completeHandshake(summary: CameraVendorConnectionSummary, reason: String)", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("IOSCameraTransferFlowDriver.handshakeCompletionAction"))
  }

  func testPairingConfirmationServiceUsesCameraCoreFlowDriver() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func confirmCameraPairingSucceeded()")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "  @discardableResult\n  private func completeQueuedPhonePairingConfirmationIfReady() -> Bool", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("IOSCameraPairingConfirmationFlowDriver.confirmPairingSucceeded"))
  }

  func testPairingConfirmationFlowDriverOwnsConfirmationRules() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Pairing/CameraPairingConfirmationFlowDriver.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation"))
    XCTAssertFalse(source.contains("CameraVendorCameraPairingConfirmationPolicy.shouldQueuePhoneConfirmation"))
    XCTAssertFalse(source.contains("CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation"))
    XCTAssertFalse(source.contains("CameraVendorCameraPairingConfirmationPolicy.shouldWaitForPhoneConfirmationAfterIdentifierWrite"))
  }

  func testIdentifierWriteServiceUsesCameraCoreIdentifierRouteDriver() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private func handleIdentifierWriteCompletion(on peripheral: CBPeripheral)")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "  private func beginRememberedGalleryTransferIfPossible(on peripheral: CBPeripheral)", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("IOSCameraPairingConfirmationFlowDriver.routeAfterIdentifierWrite"))
    XCTAssertTrue(body.contains("beginRememberedGalleryTransferIfPossible"))
    XCTAssertFalse(body.contains("CameraVendorCameraPairingConfirmationPolicy.shouldStartAutoTransferBeforePhoneConfirmation"))
  }

  func testTransferFlowDriverOwnsRememberedGalleryEntryRules() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Connection")
    let transferSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraTransferFlowDriver.swift"),
      encoding: .utf8
    )
    let guardSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraConnectionFlowGuards.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(transferSource.contains("CameraVendorPostPairingTransferPolicy"))
    XCTAssertFalse(guardSource.contains("CameraVendorPostPairingTransferPolicy"))
  }

  func testRememberedConnectionFlowDriverProceedsWhenWifiRecordAndApprovalExist() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "X-T5",
      serialNumber: "221019F1932011003B",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false
      )
    )

    let decision = IOSCameraRememberedConnectionFlowDriver.connectPairedCamera(
      record: IOSCameraRememberedCameraRecord(
        peripheralID: record.peripheralID,
        identity: IOSCameraIdentity(
          cameraID: "221019F1932011003B_X-T5",
          displayName: record.deviceName,
          serialNumber: record.serialNumber,
          bleEndpoint: IOSCameraBleEndpoint(
            identifier: record.peripheralID.uuidString.uppercased(),
            address: nil
          )
        ),
        wifiCredential: IOSCameraWifiCredential.official(
          ssid: record.preferredWifiNetwork?.ssid,
          passphrase: record.preferredWifiNetwork?.passphrase,
          bssid: record.preferredWifiNetwork?.bssid,
          source: .bleHandshake
        ),
        connectedDeviceName: record.connectedDeviceName,
        systemBluetoothPairingValidatedAt: record.systemBluetoothPairingValidatedAt
      ),
      cleanupBlocked: false,
      hasUserApproval: true,
      hasInFlightAttempt: false,
      hasOfficialWifiRecord: true,
      centralPoweredOn: true
    )

    guard case .proceed(let shouldAttemptAutoReconnect) = decision else {
      return XCTFail("Expected proceed decision")
    }
    XCTAssertTrue(shouldAttemptAutoReconnect)
  }

  func testPairingConfirmationFlowDriverQueuesUntilCameraAck() {
    XCTAssertEqual(
      IOSCameraPairingConfirmationFlowDriver.confirmPairingSucceeded(
        hasWrittenIdentifier: false,
        hasPendingHandshakeSummary: true
      ),
      .waitForCameraAck
    )
  }

  func testPairingConfirmationFlowDriverRoutesRememberedGalleryIdentifierWriteToMainline() {
    XCTAssertEqual(
      IOSCameraPairingConfirmationFlowDriver.routeAfterIdentifierWrite(
        intent: .rememberedGallery,
        shouldBypassManualConfirmation: true
      ),
      .beginRememberedGalleryMainline
    )
    XCTAssertEqual(
      IOSCameraPairingConfirmationFlowDriver.routeAfterIdentifierWrite(
        intent: .rememberedGallery,
        shouldBypassManualConfirmation: false
      ),
      .failRememberedGalleryRequiresRepair
    )
  }

  func testTransferFlowDriverRequiresConnectedPeripheral() {
    XCTAssertEqual(
      IOSCameraTransferFlowDriver.startTransfer(
        hasCompletedPairing: true,
        didCompleteHandshake: false,
        peripheralState: nil
      ),
      .missingPeripheral
    )
    XCTAssertEqual(
      IOSCameraTransferFlowDriver.startTransfer(
        hasCompletedPairing: true,
        didCompleteHandshake: false,
        peripheralState: .disconnected
      ),
      .disconnectedPeripheral
    )
  }

  func testTransferFlowDriverBuildsActivationActionFromAvailableCharacteristics() {
    let action = IOSCameraTransferFlowDriver.handshakeCompletionAction(
      context: IOSCameraHandshakeCompletionContext(
        didCompleteHandshake: false,
        isRunningPostHandshakeProbe: false,
        isRunningTransferActivation: false,
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: true,
        hasPendingHandshakeSummary: true,
        hasAttemptedAutomaticTransferActivation: false,
        transferActivationObservedChange: false,
        transferActivationObservedWifiLaunch: false,
        hadAutomaticTransferActivationFeature: false,
        availableCharacteristicUUIDStrings: [
          CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
          CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
          CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
          CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
          CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        ],
        availableTransferStrategies: CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
          forAvailableCharacteristicUUIDStrings: [
            CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
            CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
            CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
            CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
            CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
          ]
        ).map { IOSCameraTransferActivationStrategy(rawValue: $0.rawValue) },
        hasSelectedPeripheral: true
      )
    )

    guard case .beginTransferActivation(let strategies, _) = action else {
      return XCTFail("Expected transfer activation action")
    }
    XCTAssertFalse(strategies.isEmpty)
  }

  func testPairedCameraStoreDropsInvalidPayload() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Invalid.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.set(Data("not-json".utf8), forKey: CameraVendorPairedCameraStore.storageKey)

    let store = CameraVendorPairedCameraStore(defaults: defaults)

    XCTAssertNil(store.load())
    XCTAssertNil(defaults.data(forKey: CameraVendorPairedCameraStore.storageKey))
  }

  func testPairedCameraStoreLoadsLegacyRecordWithoutSavedConnectedDeviceName() throws {
    let suiteName = "RunnerTests.PairedCameraStore.Legacy.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("expected isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    let legacyPayload = Data("""
    {
      "peripheralID":"12345678-1234-1234-1234-1234567890AB",
      "deviceName":"CAMERA DEVICE-A",
      "serialNumber":"221019F1932011003B",
      "appVariant":"ReferenceApp",
      "preferredWifiNetwork":null
    }
    """.utf8)
    defaults.set(legacyPayload, forKey: CameraVendorPairedCameraStore.storageKey)

    let store = CameraVendorPairedCameraStore(defaults: defaults)
    let record = try XCTUnwrap(store.load())

    XCTAssertNil(record.connectedDeviceName)
    XCTAssertEqual(
      record.connectionSummary.connectedDeviceName,
      CameraVendorHandshakeIdentityPolicy.currentConnectedDeviceName()
    )
  }

  func testRememberedPairingPolicySkipsManualConfirmationForSamePeripheral() {
    let rememberedID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldSkipManualPairingConfirmation(
        rememberedPeripheralID: rememberedID,
        selectedPeripheralID: rememberedID
      )
    )

    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldSkipManualPairingConfirmation(
        rememberedPeripheralID: rememberedID,
        selectedPeripheralID: UUID()
      )
    )
  }

  func testRememberedPairingPolicyBypassesConfirmationForSavedCameraAfterAck() {
    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: true,
        isAlreadyPairedIdentificationNumber: false
      )
    )
    XCTAssertTrue(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: true,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: false,
        isAlreadyPairedIdentificationNumber: false
      )
    )
  }

  func testRememberedPairingPolicyDoesNotBypassForReferenceAppIdentificationAlone() {
    XCTAssertFalse(
      CameraVendorRememberedPairingPolicy.shouldBypassManualConfirmation(
        isRememberedPeripheral: false,
        isAlreadyPairedIdentificationNumber: true
      )
    )
  }

  func testRememberedPairingConsistencyAllowsSamePeripheral() {
    let peripheralID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
    let record = CameraVendorPairedCameraRecord(
      peripheralID: peripheralID,
      deviceName: "X100VI",
      serialNumber: "ABCD1234",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X100VI-1234",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false
      )
    )
    let camera = CameraVendorDiscoveredCamera(
      id: peripheralID,
      name: "X100VI",
      rssi: -48,
      appVariant: .referenceApp,
      pairingToken: nil,
      matchDetails: "service:ReferenceApp",
      admission: .generic
    )

    XCTAssertFalse(
      CameraVendorRememberedPairingConsistencyPolicy
        .isStalePairingCandidate(record: record, camera: camera)
    )
  }

  func testRememberedPairingConsistencyRequiresCleanupForSameNamedPairingCandidateWithDifferentPeripheral() {
    let record = CameraVendorPairedCameraRecord(
      peripheralID: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!,
      deviceName: "X100VI",
      serialNumber: "ABCD1234",
      connectedDeviceName: "iPhone-0426",
      appVariant: .referenceApp,
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X100VI-1234",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false
      )
    )
    let camera = CameraVendorDiscoveredCamera(
      id: UUID(uuidString: "87654321-4321-4321-4321-BA0987654321")!,
      name: "X100VI",
      rssi: -48,
      appVariant: .referenceApp,
      pairingToken: nil,
      matchDetails: "service:ReferenceApp",
      admission: .generic
    )

    XCTAssertTrue(
      CameraVendorRememberedPairingConsistencyPolicy
        .isStalePairingCandidate(record: record, camera: camera)
    )
  }

  func testFreshPairingRegistrationPolicyBlocksAlreadyPairedIdentificationWithoutRememberedRecord() {
    XCTAssertTrue(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: false,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: true,
        isAlreadyPairedIdentificationNumber: true
      )
    )
    XCTAssertFalse(
      CameraVendorFreshPairingRegistrationPolicy.shouldRequireSystemBluetoothCleanup(
        hasRememberedRecord: false,
        isAlreadyPairedIdentificationNumber: false
      )
    )
  }

  func testQueuedBatchDownloadKeepsUnselectedHandlesIdle() {
    let items = [
      CameraVendorGalleryItem(
        handle: 1,
        filename: "A.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:00:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 2,
        filename: "B.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:01:00",
        byteSizeText: "1 MB"
      ),
      CameraVendorGalleryItem(
        handle: 3,
        filename: "C.JPG",
        formatLabel: "JPG",
        captureDate: "2026:04:26 17:02:00",
        byteSizeText: "1 MB"
      ),
    ]
    var state = CameraVendorGalleryState(items: items)

    state.enqueueDownloads(for: [1, 3])

    XCTAssertEqual(state.downloadState(for: 1), .queued)
    XCTAssertEqual(state.downloadState(for: 2), .idle)
    XCTAssertEqual(state.downloadState(for: 3), .queued)
  }

  func testGalleryDownloadProgressTextIncludesPositionAndSize() {
    let item = CameraVendorGalleryItem(
      handle: 7,
      filename: "A.RAF",
      formatLabel: "RAW",
      captureDate: "",
      byteSizeText: "52 MB"
    )
    var state = CameraVendorGalleryState(items: [item])

    state.enqueueDownloads(for: [7])
    state.markDownloadStarted(handle: 7, position: 2, total: 5)

    XCTAssertEqual(state.downloadProgressText(for: 7), "2/5")
  }

  func testPtpOperationPacketEncodingMatchesExpectedLayout() {
    let data = CameraVendorPtpPacketBuilder.buildOperationRequest(
      operationCode: 0x1002,
      transactionID: 7,
      parameters: [1]
    )

    XCTAssertEqual(data.count, 22)
    XCTAssertEqual(Array(data.prefix(8)), [22, 0, 0, 0, 6, 0, 0, 0])
    XCTAssertEqual(Array(data.suffix(14)), [1, 0, 0, 0, 0x02, 0x10, 7, 0, 0, 0, 1, 0, 0, 0])
  }

  func testCameraVendorLegacyOperationPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x1002,
      transactionID: 1,
      parameters: [1]
    )

    XCTAssertEqual(data.count, 16)
    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x02, 0x10,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorVendorGalleryPreflightPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x1015,
      transactionID: 7,
      parameters: [0xD212]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x15, 0x10,
        0x07, 0x00, 0x00, 0x00,
        0x12, 0xD2, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorLegacyDataOutPacketCanUseReferenceAppTwoByteInitSequencePayload() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: 0x1016,
      transactionID: 3,
      data: Data([0x14, 0x00])
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0E, 0x00, 0x00, 0x00,
        0x02, 0x00,
        0x16, 0x10,
        0x03, 0x00, 0x00, 0x00,
        0x14, 0x00,
      ]
    )
  }

  func testCameraVendorVendorLatestObjectInfoPacketEncodingMatchesReferenceAppLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: 0x9054,
      transactionID: 9,
      parameters: [0x10000001]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x54, 0x90,
        0x09, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x10,
      ]
    )
  }

  func testCameraVendorCurrentImageContextPolicyMatchesOfficialGalleryBootstrap() {
    XCTAssertEqual(CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle, 0x10000001)
    XCTAssertTrue(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeBeforeImageHandleList)
    XCTAssertTrue(CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailBeforeSearchDescription)
  }

  func testCameraVendorCurrentImageContextPolicySkipsThumbnailPrimeAfterImagePrimeFailure() {
    XCTAssertFalse(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailAfterImageContextPrime(
        imagePrimeSucceeded: false
      )
    )
    XCTAssertTrue(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldPrimeThumbnailAfterImageContextPrime(
        imagePrimeSucceeded: true
      )
    )
  }

  func testCameraVendorCurrentImageContextPolicyPrimesOfficialGalleryBootstrapMarkers() {
    XCTAssertTrue(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x0992
      )
    )
    XCTAssertTrue(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x0993
      )
    )
    XCTAssertTrue(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: nil
      )
    )
    XCTAssertTrue(
      CameraVendorReferenceAppCurrentImageContextPolicy.shouldAttemptCurrentImagePrime(
        galleryReadyMarker: 0x05F4
      )
    )
  }

  func testCameraVendorCurrentObjectHandleDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.currentObjectHandle, 0xD22B)
  }

  func testCameraVendorCompressionDevicePropertiesMatchReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.imageForceCompression, 0xD226)
    XCTAssertEqual(CameraVendorDevicePropCode.imageCompressionRealInfo, 0xD227)
  }

  func testCameraVendorOriginalDownloadPolicyDoesNotPairForceCompressionWithGetObject() {
    XCTAssertFalse(CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeStandardGetObject)
    XCTAssertFalse(CameraVendorOriginalDownloadPolicy.shouldAttemptStandardGetObjectDownload)
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldDownloadUsingPartialObjectFallback)
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldPreparePartialObjectFileDownload)
  }

  func testCameraVendorPtpReceiveCadenceSummarySeparatesPollWaitsFromImmediateReads() {
    var summary = CameraVendorPtpReceiveCadenceSummary()

    summary.recordPoll(waitMs: 0)
    summary.recordRecv()
    summary.recordPoll(waitMs: 125)
    summary.recordRecv()
    summary.recordPoll(waitMs: -3)
    var nextChunk = CameraVendorPtpReceiveCadenceSummary()
    nextChunk.recordPoll(waitMs: 80)
    nextChunk.recordRecv()
    summary.merge(nextChunk)

    XCTAssertEqual(summary.pollWaitMs, 205)
    XCTAssertEqual(summary.maxPollWaitMs, 125)
    XCTAssertEqual(summary.pollWaitCount, 2)
    XCTAssertEqual(summary.immediatePollCount, 2)
    XCTAssertEqual(summary.recvCallCount, 3)
  }

  func testOriginalDownloadTracksReceiveCadenceWithoutPerRecvOrPollTimingLogging() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift", "CameraVendorPtpSession.swift")
    let readStart = try XCTUnwrap(source.range(of: "func readExactlyToFile(")?.lowerBound)
    let readEnd = try XCTUnwrap(
      source.range(of: "func close()", range: readStart..<source.endIndex)?.lowerBound
    )
    let readBody = String(source[readStart..<readEnd])

    XCTAssertTrue(readBody.contains("var cadence = CameraVendorPtpReceiveCadenceSummary()"))
    XCTAssertTrue(readBody.contains("mach_absolute_time()"))
    XCTAssertFalse(readBody.contains("cadence.recordPoll(waitMs:"))
    XCTAssertTrue(readBody.contains("cadence.recordRecv()"))
    XCTAssertFalse(readBody.contains("CameraVendorFileLogger.log"))
    XCTAssertTrue(source.contains("[OBS] PTP_ORIGINAL_RECEIVE_CADENCE"))
  }

  func testPtpSocketReceiveLoopsCannotBlockPastTheirPollDeadline() throws {
    let source = try runnerSource("CameraVendorPtpSocket.swift")
    let readStart = try XCTUnwrap(source.range(of: "func readExactly(")?.lowerBound)
    let fileReadStart = try XCTUnwrap(
      source.range(of: "func readExactlyToFile(", range: readStart..<source.endIndex)?.lowerBound
    )
    let closeStart = try XCTUnwrap(
      source.range(of: "func close()", range: fileReadStart..<source.endIndex)?.lowerBound
    )
    let readBody = String(source[readStart..<fileReadStart])
    let fileReadBody = String(source[fileReadStart..<closeStart])

    for body in [readBody, fileReadBody] {
      XCTAssertTrue(body.contains("MSG_DONTWAIT"))
      XCTAssertTrue(body.contains("errno == EAGAIN || errno == EWOULDBLOCK"))
    }
  }

  func testPtpFilePayloadReaderRetriesEagainAfterPoll() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    let readerDescriptor = descriptors[0]
    let writerDescriptor = descriptors[1]
    defer { Darwin.close(writerDescriptor) }

    let payload = Data("camera-payload".utf8)
    let written = payload.withUnsafeBytes { buffer in
      Darwin.send(writerDescriptor, buffer.baseAddress, buffer.count, 0)
    }
    XCTAssertEqual(written, payload.count)

    var injectedEagain = false
    let socket = CameraVendorPtpSocket(
      connectedFileDescriptor: readerDescriptor,
      receiveFunction: { descriptor, buffer, length, flags in
        if !injectedEagain {
          injectedEagain = true
          errno = EAGAIN
          return -1
        }
        return Darwin.recv(descriptor, buffer, length, flags)
      }
    )
    defer { socket.close() }

    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ptp-eagain-\(UUID().uuidString).bin")
    XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let fileHandle = try FileHandle(forWritingTo: fileURL)
    defer { try? fileHandle.close() }

    let result = try socket.readExactlyToFile(
      payload.count,
      fileHandle: fileHandle,
      timeout: 1,
      prefixByteCount: payload.count
    )

    XCTAssertTrue(injectedEagain)
    XCTAssertEqual(result.byteCount, payload.count)
    XCTAssertEqual(result.prefix, payload)
    XCTAssertEqual(try Data(contentsOf: fileURL), payload)
  }

  func testPtpSocketInterruptionUnblocksPendingReadAsCancellation() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    let readerDescriptor = descriptors[0]
    let writerDescriptor = descriptors[1]
    defer { Darwin.close(writerDescriptor) }

    let socket = CameraVendorPtpSocket(connectedFileDescriptor: readerDescriptor)
    let readFinished = expectation(description: "blocked PTP read is interrupted")
    let resultLock = NSLock()
    var readError: NSError?
    DispatchQueue.global(qos: .userInitiated).async {
      defer { readFinished.fulfill() }
      do {
        _ = try socket.readExactly(4, timeout: 60)
      } catch {
        resultLock.lock()
        readError = error as NSError
        resultLock.unlock()
      }
    }

    usleep(50_000)
    socket.interrupt(reason: "user-cancelled-download")

    wait(for: [readFinished], timeout: 1)
    resultLock.lock()
    let capturedError = readError
    resultLock.unlock()
    XCTAssertEqual(capturedError?.domain, NSURLErrorDomain)
    XCTAssertEqual(capturedError?.code, NSURLErrorCancelled)
    socket.close()
  }

  func testPtpUserCancellationKeepsSharedSocketsConnectedUntilChunkBoundary() throws {
    let source = try runnerSource("CameraVendorPtpSession.swift")
    let start = try XCTUnwrap(
      source.range(of: "func requestActiveDownloadCancellation(reason: String)")?.lowerBound
    )
    let end = try XCTUnwrap(
      source.range(
        of: "\n  private func throwIfActiveDownloadCancelled",
        range: start..<source.endIndex
      )?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("activeDownloadCancellation.request()"))
    XCTAssertFalse(body.contains("commandSocket.interrupt"))
    XCTAssertFalse(body.contains("eventSocket.interrupt"))
    XCTAssertFalse(body.contains("isConnected = false"))
  }

  func testCameraVendorOriginalDownloadPolicyUsesUInt16PayloadForCorrectFileSize() {
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: true),
      Data([0x01, 0x00])
    )
    XCTAssertEqual(
      CameraVendorOriginalDownloadPolicy.correctFileSizePayload(enabled: false),
      Data([0x00, 0x00])
    )
  }

  func testCameraVendorOriginalDownloadPolicyPrefersReferenceAppFastStartPreparation() {
    XCTAssertTrue(CameraVendorOriginalDownloadPolicy.shouldPreferReferenceAppPreparationForFileDownload)
    XCTAssertEqual(CameraVendorOriginalDownloadPolicy.referenceAppFileDownloadForceCompressionMode, 2)
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldUseReferenceAppFastStartPreparation(
        formatLabel: "RAW"
      )
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldSetForceCompressionBeforeFileDownload(
        formatLabel: "RAW",
        cachedExpectedSize: 87_718_912
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldSetCorrectFileSizeBeforeFileDownload(
        formatLabel: "RAW",
        cachedExpectedSize: 87_718_912
      )
    )
  }

  func testCameraVendorPhotoDataDownloadUsesReferenceAppPreparationCommands() throws {
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadReferenceAppContextBeforeDataDownload()
    )
    XCTAssertTrue(
      CameraVendorOriginalDownloadPolicy.shouldReadCompressionCutOffBeforeDataDownload()
    )

    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func objectData(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func objectFile(", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("EventsList before data download"))
    XCTAssertTrue(body.contains("CompressionCutOff/PartialSize"))
  }

  func testCameraVendorPhotoDataDownloadLogsInternalTimingSummary() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func objectData(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func objectFile(", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("[OBS] PTP_DOWNLOAD_DATA_TIMING"))
    XCTAssertTrue(body.contains("prepMs="))
    XCTAssertTrue(body.contains("freshInfoMs="))
    XCTAssertTrue(body.contains("readMs="))
    XCTAssertTrue(body.contains("normalizeMs="))
    XCTAssertTrue(body.contains("totalMs="))
  }

  func testCameraVendorOriginalPhotoDataDownloadDoesNotUseCachedObjectInfoForJpegAndHeif() {
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "JPG",
        cachedExpectedSize: 167_936,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 813_192,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: nil,
        mode: .original
      )
    )
    XCTAssertFalse(
      CameraVendorOriginalDownloadPolicy.shouldUseCachedObjectInfoForDataDownload(
        formatLabel: "HEIF",
        cachedExpectedSize: 813_192,
        mode: .compressed
      )
    )
  }

  func testCameraVendorThumbnailPolicyPrimesObjectContextBeforeStandardGetThumb() {
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldReadObjectInfoBeforeGetThumb)
    XCTAssertTrue(CameraVendorThumbnailFetchPolicy.shouldTryStandardGetThumbFirst)
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.standardGetThumbReadTimeoutSeconds, 3)
    XCTAssertEqual(CameraVendorThumbnailFetchPolicy.minimumUsefulThumbnailBytes, 100)
    XCTAssertFalse(CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback)
  }

  func testCameraVendorThumbnailPathRecoversObjectInfoAfterGetThumbBeforeReturningResult() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let fetchStart = try XCTUnwrap(
      source.range(of: "private func readStandardThumbnailObjectWithInfo")?.lowerBound
    )
    let fetchEnd = try XCTUnwrap(
      source.range(of: "private func readPreviewObject", range: fetchStart..<source.endIndex)?.lowerBound
    )
    let body = String(source[fetchStart..<fetchEnd])

    XCTAssertTrue(
      body.contains("readTimeout: CameraVendorThumbnailFetchPolicy.objectInfoReadTimeoutSeconds")
    )
    XCTAssertTrue(
      body.contains("primedObjectInfo ?? recoverThumbnailObjectInfoAfterGetThumb(handle: handle)")
    )
    XCTAssertTrue(
      body.contains("readTimeout: CameraVendorThumbnailFetchPolicy.postGetThumbObjectInfoReadTimeoutSeconds")
    )
  }

  func testThumbnailResultCarriesPrimedObjectInfoOrientationToGallery() throws {
    let primedInfo = CameraVendorCameraObjectInfo(
      handle: 0x10000001,
      storageID: 0x10000001,
      formatCode: 0x3801,
      compressedSize: 1024,
      thumbCompressedSize: 128,
      filename: "DSCF0001.JPG",
      captureDate: "2026:07:12 22:00:00",
      orientation: 2
    )

    let result = try CameraVendorThumbnailResultPolicy.result(
      data: Data([0xFF, 0xD8]),
      primedObjectInfo: primedInfo
    )

    XCTAssertEqual(result.objectInfo?.handle, primedInfo.handle)
    XCTAssertEqual(result.objectInfo?.orientation, 2)
  }

  func testThumbnailResultRejectsPublicationWithoutObjectInfo() {
    XCTAssertThrowsError(
      try CameraVendorThumbnailResultPolicy.result(
        data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
        primedObjectInfo: nil
      )
    )
  }

  func testGalleryThumbnailAdapterPreservesExactPrimedObjectInfo() {
    let primedInfo = CameraVendorCameraObjectInfo(
      handle: 0x10000001,
      storageID: 0x10000001,
      formatCode: 0x3812,
      compressedSize: 1024,
      thumbCompressedSize: 128,
      filename: "DSCF0001.HEIF",
      captureDate: "20260712T220000",
      orientation: 4
    )
    let thumbnail = CameraVendorGalleryThumbnail(
      data: Data([0xFF, 0xD8]),
      item: nil,
      objectInfo: primedInfo
    )

    let result = CameraGalleryRepositoryAdapter.thumbnailResult(from: thumbnail)

    XCTAssertEqual(result.objectInfo?.formatCode, 0x3812)
    XCTAssertEqual(result.objectInfo?.metadata.orientation, 4)
    XCTAssertTrue(result.objectInfo?.hasResolvedFormat == true)
  }

  func testGalleryPreviewResultCarriesObjectInfoOrientationToRenderer() {
    let item = CameraVendorGalleryItem(
      handle: 0x10000002,
      filename: "DSCF0002.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:12 22:00:00",
      byteSizeText: "1 KB",
      orientation: 4
    )

    let preview = CameraVendorGalleryPreview(data: Data([0xFF, 0xD8]), item: item)

    XCTAssertEqual(preview.item?.handle, item.handle)
    XCTAssertEqual(preview.item?.orientation, 4)
  }

  @MainActor
  func testRuntimePreviewTransportDynamicallyDispatchesCameraOrientation() async throws {
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    galleryService.previewItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:07:13 10:00:00",
      byteSizeText: "1 MB",
      orientation: 2
    )
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: CameraSessionRuntimeFileSaverSpy()
    )

    let preview = try await transport.fetchPreviewImageWithInfo(for: 7)

    XCTAssertEqual(preview.item?.orientation, 2)
  }

  func testGalleryEntrySummaryUsesConfirmedOrUnknownOnly() {
    let summary = CameraGalleryEntrySummary(
      handle: 7,
      filename: .unknown,
      format: .unknown,
      captureDate: .unknown,
      size: .unknown,
      sortKey: .handleDescending(7)
    )

    XCTAssertEqual(summary.handle, 7)
    XCTAssertEqual(summary.filename, .unknown)
    XCTAssertEqual(summary.format, .unknown)
  }

  func testRepositoryDoesNotLetThumbnailOverwriteConfirmedSummaryFormat() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 7,
        filename: .confirmed("DSCF0007.RAF"),
        format: .confirmed(.raw),
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(7)
      )
    ])

    repository.applyThumbnailUpdate(
      handle: 7,
      thumbnail: CameraGalleryEntryThumbnail(
        handle: 7,
        state: .loaded,
        imageData: Data([0xFF, 0xD8, 0xFF])
      )
    )

    XCTAssertEqual(repository.entries[0].summary.format, .confirmed(.raw))
  }

  func testRepositoryThumbnailResultDoesNotMutateCatalogTruthOrSectionIdentity() {
    let catalogItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB",
      compressedSize: 4_000_000,
      orientation: 1
    )
    var repository = CameraGalleryRepository()
    let snapshot = CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: [],
      orderedHandles: [7],
      items: [catalogItem]
    )
    let generation = CameraGalleryGenerationID(rawValue: 1)
    repository.install(snapshot, generation: generation)
    let identity = CameraGalleryChildIdentity(
      generation: generation,
      snapshotID: snapshot.snapshotID,
      handle: 7
    )

    let didApply = repository.applyThumbnail(
      CameraGalleryThumbnailResult(data: Data([0xFF, 0xD8, 0xFF]), resolvedMetadata: nil),
      identity: identity
    )

    XCTAssertTrue(didApply)

    XCTAssertEqual(repository.items[0].filename, catalogItem.filename)
    XCTAssertEqual(repository.items[0].formatLabel, catalogItem.formatLabel)
    XCTAssertEqual(repository.items[0].captureDate, catalogItem.captureDate)
    XCTAssertEqual(repository.items[0].compressedSize, catalogItem.compressedSize)
    XCTAssertEqual(repository.items[0].orientation, catalogItem.orientation)
    XCTAssertEqual(repository.items[0].thumbnailData, Data([0xFF, 0xD8, 0xFF]))
    XCTAssertEqual(repository.entries[0].summary.handle, 7)
  }

  func testRepositoryAppliesThumbnailAndResolvedDetailsToKnownIdentity() {
    let item = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )
    var repository = CameraGalleryRepository()
    let snapshot = CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: [],
      orderedHandles: [7],
      items: [item]
    )
    let generation = CameraGalleryGenerationID(rawValue: 1)
    repository.install(snapshot, generation: generation)
    let identity = CameraGalleryChildIdentity(
      generation: generation,
      snapshotID: snapshot.snapshotID,
      handle: 7
    )

    let thumbnail = CameraGalleryThumbnailResult(data: Data([1, 2, 3]), resolvedMetadata: nil)
    XCTAssertTrue(repository.applyThumbnail(thumbnail, identity: identity))
    XCTAssertEqual(repository.items[0].thumbnailData, Data([1, 2, 3]))

    let details = CameraGalleryDetailsSourceResult(
      handle: 7,
      orientation: .confirmed(4),
      refinedFormat: .confirmed(.heif),
      notes: ["resolved"],
      resolvedMetadata: CameraGalleryResolvedItemMetadata(
        handle: 7,
        filename: "DSCF0007.HEIC",
        formatLabel: "HEIF",
        captureDate: "20250615T150640",
        byteSizeText: "8 MB",
        compressedSize: 8_000_000,
        orientation: 4,
        formatHints: []
      )
    )
    XCTAssertTrue(repository.applyDetails(details, identity: identity))
    XCTAssertEqual(repository.items[0].filename, "DSCF0007.HEIC")
    XCTAssertEqual(repository.items[0].orientation, 4)
  }

  func testGalleryRepositoryPreservesEnrichedContentForSharedHandlesAcrossInstall() {
    var repository = CameraGalleryRepository()
    let firstSnapshot = CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: [],
      orderedHandles: [7],
      items: [CameraVendorGalleryItem(
        handle: 7,
        filename: "0x00000007",
        formatLabel: "",
        captureDate: "20260730",
        byteSizeText: ""
      )]
    )
    let firstGeneration = CameraGalleryGenerationID(rawValue: 1)
    repository.install(firstSnapshot, generation: firstGeneration)
    let firstIdentity = CameraGalleryChildIdentity(
      generation: firstGeneration,
      snapshotID: firstSnapshot.snapshotID,
      handle: 7
    )
    XCTAssertTrue(repository.applyThumbnail(
      CameraGalleryThumbnailResult(
        data: Data([1, 2, 3]),
        resolvedMetadata: CameraGalleryResolvedItemMetadata(
          handle: 7,
          filename: "DSCF0007.HEIC",
          formatLabel: "HEIF",
          captureDate: "20260730T120000",
          byteSizeText: "8 MB",
          compressedSize: 8_000_000,
          orientation: 4,
          formatHints: []
        )
      ),
      identity: firstIdentity
    ))

    let nextSnapshot = CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: [],
      orderedHandles: [7, 8],
      items: [
        CameraVendorGalleryItem(
          handle: 7,
          filename: "0x00000007",
          formatLabel: "",
          captureDate: "20260730",
          byteSizeText: ""
        ),
        CameraVendorGalleryItem(
          handle: 8,
          filename: "0x00000008",
          formatLabel: "",
          captureDate: "20260730",
          byteSizeText: ""
        ),
      ]
    )
    repository.install(nextSnapshot, generation: CameraGalleryGenerationID(rawValue: 2))

    XCTAssertEqual(repository.items.map(\.handle), [7, 8])
    XCTAssertEqual(repository.items[0].thumbnailData, Data([1, 2, 3]))
    XCTAssertEqual(repository.items[0].filename, "DSCF0007.HEIC")
    XCTAssertEqual(repository.items[0].formatLabel, "HEIF")
    XCTAssertEqual(repository.items[0].orientation, 4)
    XCTAssertEqual(repository.entries[0].thumbnail.state, .loaded)
    XCTAssertEqual(repository.entries[0].thumbnail.imageData, Data([1, 2, 3]))
    XCTAssertNil(repository.items[1].thumbnailData)
  }

  func testGalleryLiveDiagnosticsCoverCatalogViewportHDAndOrientationBoundaries() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let catalogRuntime = try String(
      contentsOf: runnerDirectory.appendingPathComponent(
        "CameraCore/Gallery/CameraGalleryCatalogRuntime.swift"
      ),
      encoding: .utf8
    )
    let thumbnailPipeline = try String(
      contentsOf: runnerDirectory.appendingPathComponent(
        "CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift"
      ),
      encoding: .utf8
    )
    let hdPipeline = try String(
      contentsOf: runnerDirectory.appendingPathComponent(
        "CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift"
      ),
      encoding: .utf8
    )
    let galleryController = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeGalleryViewController.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(catalogRuntime.contains("CATALOG_QUERY_RESOLVED"))
    XCTAssertTrue(catalogRuntime.contains("CATALOG_REPOSITORY_INSTALL_END"))
    XCTAssertTrue(catalogRuntime.contains("CATALOG_PRESENTATION_PUBLISH_END"))
    XCTAssertTrue(thumbnailPipeline.contains("THUMBNAIL_PIPELINE_INSTALL_END"))
    XCTAssertTrue(thumbnailPipeline.contains("THUMBNAIL_VIEWPORT_CLASSIFIED"))
    XCTAssertTrue(galleryController.contains("THUMBNAIL_VIEWPORT_SUBMIT"))
    XCTAssertTrue(galleryController.contains("HD_PREVIEW_DECODE_FAILED"))
    XCTAssertTrue(hdPipeline.contains("HD_PREVIEW_PRIORITY_PLAN"))
    XCTAssertTrue(hdPipeline.contains("HD_PREVIEW_REQUEST_END"))
    XCTAssertTrue(hdPipeline.contains("HD_PREVIEW_REQUEST_FAILED"))
    XCTAssertTrue(galleryController.contains("ORIENTATION_DECISION"))
  }

  func testGalleryIncrementalDeltaTreatsSameDayObjectInfoRefinementAsContentOnly() {
    let previous = CameraGalleryPresentation(
      state: .ready(
        generation: CameraGalleryGenerationID(rawValue: 1),
        snapshotID: CameraGallerySnapshotID()
      ),
      intent: .all,
      items: [CameraVendorGalleryItem(
        handle: 7,
        filename: "0x00000007",
        formatLabel: "",
        captureDate: "20260729",
        byteSizeText: ""
      )],
      entries: []
    )
    let current = CameraGalleryPresentation(
      state: previous.state,
      intent: .all,
      items: [CameraVendorGalleryItem(
        handle: 7,
        filename: "DSCF0007.JPG",
        formatLabel: "JPG",
        captureDate: "20260729T120000",
        byteSizeText: "1 KB",
        orientation: 4,
        thumbnailData: Data([1, 2, 3])
      )],
      entries: []
    )

    let delta = CameraGalleryIncrementalDelta.between(
      previous: previous,
      current: current,
      changedHandles: [7]
    )

    XCTAssertEqual(delta.changedHandles, [7])
    XCTAssertEqual(delta.orientationChangedHandles, [])
    XCTAssertFalse(delta.requiresStructuralRefresh)
  }

  func testGalleryIncrementalDeltaMarksDifferentDayAndLateOrientationAsStructuralEffects() {
    let thumbnailData = Data([1, 2, 3])
    let previous = CameraGalleryPresentation(
      state: .ready(
        generation: CameraGalleryGenerationID(rawValue: 1),
        snapshotID: CameraGallerySnapshotID()
      ),
      intent: .all,
      items: [CameraVendorGalleryItem(
        handle: 7,
        filename: "DSCF0007.JPG",
        formatLabel: "JPG",
        captureDate: "20260728T120000",
        byteSizeText: "1 KB",
        orientation: 1,
        thumbnailData: thumbnailData
      )],
      entries: []
    )
    let current = CameraGalleryPresentation(
      state: previous.state,
      intent: .all,
      items: [CameraVendorGalleryItem(
        handle: 7,
        filename: "DSCF0007.JPG",
        formatLabel: "JPG",
        captureDate: "20260729T120000",
        byteSizeText: "1 KB",
        orientation: 4,
        thumbnailData: thumbnailData
      )],
      entries: []
    )

    let delta = CameraGalleryIncrementalDelta.between(
      previous: previous,
      current: current,
      changedHandles: [7]
    )

    XCTAssertEqual(delta.orientationChangedHandles, [7])
    XCTAssertTrue(delta.requiresStructuralRefresh)
  }

  func testDecodedThumbnailCacheKeySeparatesSessionAndOrientation() {
    let firstSession = UUID()
    let secondSession = UUID()

    XCTAssertNotEqual(
      NativeGalleryDecodedThumbnailCacheKey(
        sessionEpoch: firstSession,
        handle: 7,
        orientation: 1
      ),
      NativeGalleryDecodedThumbnailCacheKey(
        sessionEpoch: secondSession,
        handle: 7,
        orientation: 1
      )
    )
    XCTAssertNotEqual(
      NativeGalleryDecodedThumbnailCacheKey(
        sessionEpoch: firstSession,
        handle: 7,
        orientation: 1
      ),
      NativeGalleryDecodedThumbnailCacheKey(
        sessionEpoch: firstSession,
        handle: 7,
        orientation: 4
      )
    )
  }

  func testRepositoryAllowsDetailsToFillUnknownFormatWithoutReorderingSummary() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 9,
        filename: .unknown,
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(9)
      ),
      CameraGalleryEntrySummary(
        handle: 7,
        filename: .unknown,
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(7)
      )
    ])

    repository.applyDetailsUpdate(
      handle: 7,
      details: CameraGalleryEntryDetails(
        handle: 7,
        orientation: .confirmed(1),
        refinedFormat: .confirmed(.heif),
        notes: []
      )
    )

    XCTAssertEqual(repository.entries.map(\.summary.handle), [9, 7])
    XCTAssertEqual(repository.entries[1].summary.format, .confirmed(.heif))
  }

  func testRepositoryDetailsRemainMonotonicAfterConfirmedValuesAreKnown() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 7,
        filename: .unknown,
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(7)
      )
    ])

    repository.applyDetailsUpdate(
      handle: 7,
      details: CameraGalleryEntryDetails(
        handle: 7,
        orientation: .confirmed(4),
        refinedFormat: .confirmed(.raw),
        notes: ["first"]
      )
    )
    repository.applyDetailsUpdate(
      handle: 7,
      details: CameraGalleryEntryDetails(
        handle: 7,
        orientation: .unknown,
        refinedFormat: .confirmed(.jpg),
        notes: []
      )
    )

    XCTAssertEqual(repository.entries[0].details.orientation, .confirmed(4))
    XCTAssertEqual(repository.entries[0].details.refinedFormat, .confirmed(.raw))
    XCTAssertEqual(repository.entries[0].details.notes, ["first"])
    XCTAssertEqual(repository.entries[0].summary.format, .confirmed(.raw))
  }

  func testGalleryCatalogAdapterMapsPlaceholderItemToUnknownSummary() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )

    let summary = Runner.CameraGalleryRepositoryAdapter.summary(from: item)

    XCTAssertEqual(summary.filename, Runner.CameraGalleryConfirmedValue<String>.unknown)
    XCTAssertEqual(summary.format, Runner.CameraGalleryConfirmedValue<Runner.CameraGalleryFormat>.unknown)
  }

  func testGalleryCatalogAdapterMapsStableFilenameExtensionWhenFormatLabelMissing() {
    let item = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )

    let summary = Runner.CameraGalleryRepositoryAdapter.summary(from: item)

    XCTAssertEqual(summary.filename, Runner.CameraGalleryConfirmedValue<String>.confirmed("DSCF0007.JPG"))
    XCTAssertEqual(summary.format, Runner.CameraGalleryConfirmedValue<Runner.CameraGalleryFormat>.confirmed(.jpg))
  }

  func testGalleryCatalogAdapterPreservesConfirmedCatalogDateAndSize() {
    let item = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB",
      compressedSize: 4_000_000
    )

    let summary = Runner.CameraGalleryRepositoryAdapter.summary(from: item)

    guard case .confirmed = summary.captureDate else {
      return XCTFail("catalog capture date must remain confirmed when supplied")
    }
    XCTAssertEqual(summary.size, .confirmed(4_000_000))
  }

  func testGalleryDetailsAdapterMapsResolvedObjectInfoToConfirmedDetails() {
    let info = CameraVendorCameraObjectInfo(
      handle: 5,
      storageID: 1,
      formatCode: 0x3812,
      compressedSize: 4_000_000,
      thumbCompressedSize: 80_000,
      filename: "DSCF0005.HEIC",
      captureDate: "2026:06:24 10:11:12",
      orientation: 4
    )

    let details = Runner.CameraGalleryRepositoryAdapter.details(from: info)

    XCTAssertEqual(details.handle, 5)
    XCTAssertEqual(details.orientation, .confirmed(4))
    XCTAssertEqual(details.refinedFormat, .confirmed(.heif))
  }

  func testGalleryDetailsResultAdapterMapsResolvedObjectInfoToExplicitSourceResult() {
    let info = CameraVendorCameraObjectInfo(
      handle: 6,
      storageID: 1,
      formatCode: 0x3811,
      compressedSize: 9_000_000,
      thumbCompressedSize: 80_000,
      filename: "DSCF0006.RAF",
      captureDate: "2026:06:24 10:11:12",
      orientation: 1
    )

    let result = Runner.CameraGalleryRepositoryAdapter.detailsResult(from: info)

    XCTAssertEqual(result.handle, 6)
    XCTAssertEqual(result.orientation, .confirmed(1))
    XCTAssertEqual(result.refinedFormat, .confirmed(.raw))
  }

  func testGalleryDetailsAdapterKeepsUndefinedFormatUnknown() {
    let info = CameraVendorCameraObjectInfo.placeholder(handle: 9)

    let details = Runner.CameraGalleryRepositoryAdapter.details(from: info)

    XCTAssertEqual(details.handle, 9)
    XCTAssertEqual(details.orientation, .unknown)
    XCTAssertEqual(details.refinedFormat, .unknown)
  }

  func testGalleryFormatDisplayPolicyDoesNotInventBadgeForUnresolvedGalleryItem() {
    let item = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )

    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: item))
  }

  func testThumbnailUpdateOnViewStateDoesNotChangeConfirmedSummaryFilename() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 2,
        filename: .confirmed("DSCF0002.RAF"),
        format: .confirmed(.raw),
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(2)
      )
    ])

    repository.applyThumbnailUpdate(
      handle: 2,
      thumbnail: CameraGalleryEntryThumbnail(handle: 2, state: .loaded, imageData: Data([0xFF, 0xD8]))
    )

    XCTAssertEqual(repository.entries[0].summary.filename, .confirmed("DSCF0002.RAF"))
  }

  func testRepositoryReplaceSummaryPagePreservesThumbnailStateForMatchingHandle() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 4,
        filename: .unknown,
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(4)
      )
    ])
    repository.applyThumbnailUpdate(
      handle: 4,
      thumbnail: CameraGalleryEntryThumbnail(
        handle: 4,
        state: .loaded,
        imageData: Data([0xFF, 0xD8, 0xFF])
      )
    )

    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 4,
        filename: .confirmed("DSCF0004.JPG"),
        format: .confirmed(.jpg),
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(4)
      )
    ])

    XCTAssertEqual(repository.entries[0].thumbnail.state, .loaded)
    XCTAssertEqual(repository.entries[0].thumbnail.imageData, Data([0xFF, 0xD8, 0xFF]))
    XCTAssertEqual(repository.entries[0].summary.filename, .confirmed("DSCF0004.JPG"))
  }

  func testRepositoryKeepsSummaryUnknownUntilDetailsResultRefinesFormat() {
    var repository = CameraGalleryRepository()
    repository.replaceSummaryPage([
      CameraGalleryEntrySummary(
        handle: 12,
        filename: .unknown,
        format: .unknown,
        captureDate: .unknown,
        size: .unknown,
        sortKey: .handleDescending(12)
      )
    ])

    repository.applyThumbnailUpdate(
      handle: 12,
      thumbnail: CameraGalleryEntryThumbnail(
        handle: 12,
        state: .loaded,
        imageData: Data([0xFF, 0xD8, 0xFF])
      )
    )
    XCTAssertEqual(repository.entries[0].summary.format, .unknown)

    repository.applyDetailsResult(
      Runner.CameraGalleryDetailsSourceResult(
        handle: 12,
        orientation: .confirmed(1),
        refinedFormat: .confirmed(.heif),
        notes: []
      )
    )

    XCTAssertEqual(repository.entries[0].summary.format, .confirmed(.heif))
    XCTAssertEqual(repository.entries[0].thumbnail.state, .loaded)
  }

  func testCatalogPlaceholderPolicyBuildsItemsFromValidatedHandles() {
    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(from: [10, 12])

    XCTAssertEqual(items.map(\.handle), [10, 12])
    XCTAssertEqual(items[0].filename, "0x0000000A")
    XCTAssertEqual(items[0].formatLabel, "")
    XCTAssertEqual(items[0].captureDate, "")
    XCTAssertEqual(items[0].byteSizeText, "")
  }

  func testGalleryStateKeepsCatalogMetadataStableWhenThumbnailInfoConflicts() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let resolvedCatalogItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB"
    )
    let conflictingThumbnailInfo = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF7551.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:25 08:41:12",
      byteSizeText: "1 MB",
      orientation: 4
    )
    var state = CameraVendorGalleryState(items: [resolvedCatalogItem])

    state.updateThumbnail(handle: 7, data: thumbnail, resolvedItem: conflictingThumbnailInfo)

    XCTAssertEqual(state.items[0].filename, "DSCF0007.JPG")
    XCTAssertEqual(state.items[0].formatLabel, "JPG")
    XCTAssertEqual(state.items[0].captureDate, "2026:06:24 10:11:12")
    XCTAssertEqual(state.items[0].thumbnailData, thumbnail)
    XCTAssertEqual(state.items[0].orientation, 4)
  }

  func testGalleryThumbnailResultMergePreservesCatalogTruthAndPublishesPtpOrientation() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let catalogItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB"
    )
    let thumbnailItem = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF7551.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:25 08:41:12",
      byteSizeText: "1 MB",
      orientation: 4
    )

    let merged = NativeGalleryThumbnailResultMergePolicy.item(
      existingItem: catalogItem,
      thumbnailData: thumbnail,
      resolvedItem: thumbnailItem
    )

    XCTAssertEqual(merged.filename, "DSCF0007.JPG")
    XCTAssertEqual(merged.captureDate, "2026:06:24 10:11:12")
    XCTAssertEqual(merged.orientation, 4)
    XCTAssertEqual(merged.thumbnailData, thumbnail)
  }

  func testGalleryStateDoesNotDropInitialFormatHintsWhenThumbnailInfoIsStillUnresolved() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let placeholder = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let unresolvedThumbnailInfo = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "",
      byteSizeText: ""
    )
    var state = CameraVendorGalleryState(items: [placeholder])

    state.updateThumbnail(handle: 7, data: thumbnail, resolvedItem: unresolvedThumbnailInfo)

    XCTAssertEqual(state.items[0].formatHints, [.heif, .raw])
    XCTAssertNil(NativeGalleryFormatDisplayPolicy.badgeText(for: state.items[0]))
  }

  func testThumbnailMetadataConflictDoesNotPerturbOldestSortOrder() {
    let thumbnail = Data([0xFF, 0xD8, 0xFF])
    let oldest = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:05:01 10:00:00",
      byteSizeText: "4 MB"
    )
    let newest = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.JPG",
      formatLabel: "JPG",
      captureDate: "2026:05:02 10:00:00",
      byteSizeText: "4 MB"
    )
    let conflictingThumbnailInfo = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF7551.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:21 08:42:12",
      byteSizeText: "1 MB"
    )
    var state = CameraVendorGalleryState(items: [oldest, newest])

    state.updateThumbnail(handle: 1, data: thumbnail, resolvedItem: conflictingThumbnailInfo)

    let oldestFirst = NativeGalleryFilterPolicy.filteredItems(
      state.items,
      state: NativeGalleryFilterState(sort: .oldest),
      now: Date(timeIntervalSince1970: 0)
    )

    XCTAssertEqual(oldestFirst.map(\.handle), [1, 2])
    XCTAssertEqual(oldestFirst.first?.captureDate, "2026:05:01 10:00:00")
  }

  func testNativeGalleryThumbnailRetryPolicyStopsWhenBatchMakesNoProgress() {
    XCTAssertFalse(
      NativeGalleryThumbnailRetryPolicy.shouldContinueLoadingAfterBatch(
        requestedCount: 6,
        loadedCount: 0
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailRetryPolicy.shouldContinueLoadingAfterBatch(
        requestedCount: 6,
        loadedCount: 1
      )
    )
  }

  func testNativeGalleryThumbnailDecodeCachePolicyUsesCacheOnlyWhenDataAndImageExist() {
    XCTAssertTrue(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: UIImage()
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: nil,
        cachedImage: UIImage()
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailDecodeCachePolicy.shouldUseCachedImage(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: nil
      )
    )
  }

  func testVisibleThumbnailPolicyRehydratesCachedDataWhenImageCacheMisses() {
    let thumbnailData = Data([0xFF, 0xD8, 0xFF])
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: thumbnailData,
        cachedImage: UIImage(),
        hasFailedThumbnailRequest: false
      ),
      .none
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: thumbnailData,
        cachedImage: nil,
        hasFailedThumbnailRequest: false
      ),
      .decodeCachedData
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil,
        hasFailedThumbnailRequest: false
      ),
      .fetchFromCamera
    )
    XCTAssertEqual(
      NativeGalleryVisibleThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil,
        hasFailedThumbnailRequest: true
      ),
      .fetchFromCamera
    )
  }

  func testGalleryBackgroundMetadataStopsWhenCommunicationIsNoLongerCurrent() {
    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 8
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: false,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: true,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7
      )
    )
  }

  func testGalleryBackgroundMetadataStopsDuringPriorityDownload() {
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldContinue(
        taskIsCancelled: false,
        sessionIsConnected: true,
        capturedGeneration: 7,
        currentGeneration: 7,
        isPriorityDownloadActive: true
      )
    )
  }

  func testGalleryBackgroundMetadataUsesShortTimeoutAndInvalidatesAfterSocketFailure() {
    XCTAssertEqual(CameraVendorBackgroundMetadataRefreshPolicy.objectInfoReadTimeoutSeconds, 3.0)
    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSocket", code: 9)
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSocket", code: 9),
        isPriorityDownloadActive: true
      )
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(
        NSError(domain: "CameraVendorPtpSession", code: 0x2005)
      )
    )
  }

  func testPriorityDownloadDoesNotInvalidateInFlightBackgroundMetadata() {
    XCTAssertFalse(
      CameraVendorPriorityDownloadExclusivePtpPolicy.shouldInvalidateInFlightPtpOperation(
        activeThumbnailRequests: 0,
        activeBackgroundMetadataRequests: 1
      )
    )
    XCTAssertFalse(
      CameraVendorPriorityDownloadExclusivePtpPolicy.shouldInvalidateInFlightPtpOperation(
        activeThumbnailRequests: 1,
        activeBackgroundMetadataRequests: 2
      )
    )
  }

  private func makePtpRuntimeForExclusiveWindowTests(
    commandLane: CameraCommandLane = CameraCommandLane()
  ) -> CameraVendorPtpSessionRuntime {
    CameraVendorPtpSessionRuntime(
      session: CameraVendorPtpSession(),
      commandLane: commandLane,
      diagnosticHandler: { _ in },
      communicationGeneration: { 0 }
    )
  }

  private func assertPtpRuntimeOverlappingWindows(
    releaseFirstWindowFirst: Bool
  ) async throws {
    let runtime = makePtpRuntimeForExclusiveWindowTests()
    let firstStarted = expectation(description: "first PTP runtime window started")
    let secondStarted = expectation(description: "second PTP runtime window started")
    let releaseFirst = AsyncTestGate()
    let releaseSecond = AsyncTestGate()
    let firstOperation: () async throws -> String = {
      firstStarted.fulfill()
      await releaseFirst.wait()
      try Task.checkCancellation()
      return "first"
    }
    let secondOperation: () async throws -> String = {
      secondStarted.fulfill()
      await releaseSecond.wait()
      try Task.checkCancellation()
      return "second"
    }

    let first = Task { () -> String in
      do {
        return try await runtime.withExclusiveDownloadWindow(firstOperation)
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let second = Task { () -> String in
      do {
        return try await runtime.withExclusiveDownloadWindow(secondOperation)
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    await fulfillment(of: [firstStarted, secondStarted], timeout: 1)
    if releaseFirstWindowFirst {
      await releaseFirst.open()
      let firstResult = await first.value
      XCTAssertEqual(firstResult, "first")
    } else {
      await releaseSecond.open()
      let secondResult = await second.value
      XCTAssertEqual(secondResult, "second")
    }

    let probeResult: String
    do {
      _ = try await runtime.fetchPreviewImage(for: 1)
      probeResult = "ran"
    } catch is CancellationError {
      probeResult = "cancelled"
    } catch {
      probeResult = "other-error"
    }
    XCTAssertEqual(probeResult, "cancelled")

    if releaseFirstWindowFirst {
      await releaseSecond.open()
      let secondResult = await second.value
      XCTAssertEqual(secondResult, "second")
    } else {
      await releaseFirst.open()
      let firstResult = await first.value
      XCTAssertEqual(firstResult, "first")
    }
  }

  private func assertRealtimeServiceOverlappingWindows(
    releaseFirstWindowFirst: Bool
  ) async throws {
    let service = CameraVendorRealtimeGalleryService()
    let logLock = NSLock()
    var logs: [String] = []
    service.diagnosticHandler = { message in
      logLock.withLock {
        logs.append(message)
      }
    }
    let firstStarted = expectation(description: "first service window started")
    let secondStarted = expectation(description: "second service window started")
    let releaseFirst = AsyncTestGate()
    let releaseSecond = AsyncTestGate()
    let firstOperation: () async throws -> String = {
      firstStarted.fulfill()
      await releaseFirst.wait()
      try Task.checkCancellation()
      return "first"
    }
    let secondOperation: () async throws -> String = {
      secondStarted.fulfill()
      await releaseSecond.wait()
      try Task.checkCancellation()
      return "second"
    }

    let first = Task { () -> String in
      do {
        return try await service.withExclusiveDownloadWindow(firstOperation)
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let second = Task { () -> String in
      do {
        return try await service.withExclusiveDownloadWindow(secondOperation)
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    await fulfillment(of: [firstStarted, secondStarted], timeout: 1)
    XCTAssertEqual(
      logLock.withLock {
        logs.filter { $0.contains("PTP_EXCLUSIVE_DOWNLOAD_ADMISSION_READY") }.count
      },
      1
    )

    if releaseFirstWindowFirst {
      await releaseFirst.open()
      let firstResult = await first.value
      XCTAssertEqual(firstResult, "first")
    } else {
      await releaseSecond.open()
      let secondResult = await second.value
      XCTAssertEqual(secondResult, "second")
    }

    let probeResult: String
    do {
      _ = try await service.fetchPreviewImage(for: 1)
      probeResult = "ran"
    } catch is CancellationError {
      probeResult = "cancelled"
    } catch {
      probeResult = "other-error"
    }
    XCTAssertEqual(probeResult, "cancelled")

    if releaseFirstWindowFirst {
      await releaseSecond.open()
      let secondResult = await second.value
      XCTAssertEqual(secondResult, "second")
    } else {
      await releaseFirst.open()
      let firstResult = await first.value
      XCTAssertEqual(firstResult, "first")
    }
    XCTAssertEqual(
      logLock.withLock {
        logs.filter { $0.contains("PRIORITY_DOWNLOAD_FINISH") }.count
      },
      1
    )
  }

  func testPtpRuntimeEndWhileDrainingCancelsWithWindowBeforeOperation() async throws {
    let lane = CameraCommandLane()
    let runtime = makePtpRuntimeForExclusiveWindowTests(commandLane: lane)
    let activeStarted = expectation(description: "active command started")
    let releaseActive = DispatchSemaphore(value: 0)
    let operationLock = NSLock()
    var operationCount = 0
    let operation: () async throws -> String = {
      operationLock.withLock {
        operationCount += 1
      }
      return "operation"
    }

    let active = Task {
      try await lane.run(priority: .details) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let window = Task { () -> String in
      do {
        return try await runtime.withExclusiveDownloadWindow(operation)
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let barrierProbe = Task { () -> String in
      do {
        return try await lane.run(priority: .hdPreview) { "ran" }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let barrierProbeResult = await barrierProbe.value
    XCTAssertEqual(barrierProbeResult, "cancelled")

    runtime.forceEndExclusiveDownloadWindow()
    let windowResult = await window.value
    XCTAssertEqual(windowResult, "cancelled")
    XCTAssertEqual(operationLock.withLock { operationCount }, 0)

    releaseActive.signal()
    _ = try? await active.value
  }

  func testPtpRuntimeCancellationAfterOperationStartsKeepsBarrierUntilOperationFinishes() async throws {
    let lane = CameraCommandLane()
    let runtime = makePtpRuntimeForExclusiveWindowTests(commandLane: lane)
    let operationStarted = expectation(description: "exclusive operation started")
    let releaseOperation = AsyncTestGate()

    let window = Task { () -> String in
      do {
        return try await runtime.withExclusiveDownloadWindow {
          operationStarted.fulfill()
          await releaseOperation.wait()
          return "operation"
        }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    await fulfillment(of: [operationStarted], timeout: 1)
    window.cancel()

    let probeWhileOperationIsRunning: String
    do {
      _ = try await lane.run(priority: .hdPreview) { "ran" }
      probeWhileOperationIsRunning = "ran"
    } catch is CancellationError {
      probeWhileOperationIsRunning = "cancelled"
    } catch {
      probeWhileOperationIsRunning = "failed"
    }
    XCTAssertEqual(probeWhileOperationIsRunning, "cancelled")

    await releaseOperation.open()
    let windowResult = await window.value
    XCTAssertEqual(windowResult, "operation")

    let probeAfterOperationFinishes = try await lane.run(priority: .hdPreview) { "ran" }
    XCTAssertEqual(probeAfterOperationFinishes, "ran")
  }

  func testPtpRuntimeOverlappingWindowsKeepBarrierWhenFirstFinishesFirst() async throws {
    try await assertPtpRuntimeOverlappingWindows(releaseFirstWindowFirst: true)
  }

  func testPtpRuntimeOverlappingWindowsKeepBarrierWhenSecondFinishesFirst() async throws {
    try await assertPtpRuntimeOverlappingWindows(releaseFirstWindowFirst: false)
  }

  func testRealtimeGalleryServiceOverlappingWindowsKeepBatchWhenFirstFinishesFirst() async throws {
    try await assertRealtimeServiceOverlappingWindows(releaseFirstWindowFirst: true)
  }

  func testRealtimeGalleryServiceOverlappingWindowsKeepBatchWhenSecondFinishesFirst() async throws {
    try await assertRealtimeServiceOverlappingWindows(releaseFirstWindowFirst: false)
  }

  func testRealtimeGalleryServiceTerminateForceReleasesAllOwners() async throws {
    let service = CameraVendorRealtimeGalleryService()
    let logLock = NSLock()
    var logs: [String] = []
    service.diagnosticHandler = { message in
      logLock.withLock {
        logs.append(message)
      }
    }

    let firstOwner = service.beginExclusiveDownloadWindow()
    let secondOwner = service.beginExclusiveDownloadWindow()
    try await service.awaitExclusiveDownloadWindowReady(ownerID: firstOwner)
    try await service.awaitExclusiveDownloadWindowReady(ownerID: secondOwner)
    XCTAssertEqual(
      logLock.withLock {
        logs.filter { $0.contains("PTP_EXCLUSIVE_DOWNLOAD_ADMISSION_READY") }.count
      },
      1
    )

    service.terminateCameraCommunication(reason: "test-force-release")
    service.endExclusiveDownloadWindow(ownerID: firstOwner)
    service.endExclusiveDownloadWindow(ownerID: secondOwner)

    let probeResult: String
    do {
      _ = try await service.fetchPreviewImage(for: 1)
      probeResult = "ran"
    } catch is CancellationError {
      probeResult = "cancelled"
    } catch {
      probeResult = "other-error"
    }
    XCTAssertNotEqual(probeResult, "cancelled")
    XCTAssertEqual(
      logLock.withLock {
        logs.filter { $0.contains("PRIORITY_DOWNLOAD_FINISH") }.count
      },
      1
    )
  }

  func testPtpRuntimeOldOwnerReleaseAfterForceEndDoesNotReleaseReplacementWindow() async throws {
    let lane = CameraCommandLane()
    let runtime = makePtpRuntimeForExclusiveWindowTests(commandLane: lane)
    let oldOwner = runtime.beginExclusiveDownloadWindow()
    try await runtime.awaitExclusiveDownloadWindowReady(ownerID: oldOwner)

    runtime.forceEndExclusiveDownloadWindow()
    let replacementOwner = runtime.beginExclusiveDownloadWindow()
    try await runtime.awaitExclusiveDownloadWindowReady(ownerID: replacementOwner)

    runtime.endExclusiveDownloadWindow(ownerID: oldOwner)
    let probeResult: String
    do {
      probeResult = try await lane.run(priority: .visibleThumbnail) { "ran" }
    } catch is CancellationError {
      probeResult = "cancelled"
    }

    runtime.endExclusiveDownloadWindow(ownerID: replacementOwner)

    XCTAssertEqual(probeResult, "cancelled")
  }

  func testPtpRuntimeOldWaiterCannotObserveReplacementAcquisitionAsReady() async throws {
    let lane = CameraCommandLane()
    let runtime = makePtpRuntimeForExclusiveWindowTests(commandLane: lane)
    let activeStarted = expectation(description: "active command started")
    let releaseActive = DispatchSemaphore(value: 0)
    let active = Task {
      try await lane.run(priority: .details) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let oldOwner = runtime.beginExclusiveDownloadWindow()
    let oldWaiter = Task { () -> String in
      do {
        try await runtime.awaitExclusiveDownloadWindowReady(ownerID: oldOwner)
        return "ready"
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    await Task.yield()

    runtime.forceEndExclusiveDownloadWindow()
    let replacementOwner = runtime.beginExclusiveDownloadWindow()
    releaseActive.signal()
    _ = try? await active.value
    try await runtime.awaitExclusiveDownloadWindowReady(ownerID: replacementOwner)

    let oldWaiterResult = await oldWaiter.value
    XCTAssertEqual(oldWaiterResult, "cancelled")
    runtime.endExclusiveDownloadWindow(ownerID: replacementOwner)
  }

  func testRealtimeGalleryServiceOldOwnerReleaseAfterTerminateDoesNotFinishReplacementBatch() async throws {
    let service = CameraVendorRealtimeGalleryService()
    let logLock = NSLock()
    var logs: [String] = []
    service.diagnosticHandler = { message in
      logLock.withLock {
        logs.append(message)
      }
    }
    let oldOwner = service.beginExclusiveDownloadWindow()
    try await service.awaitExclusiveDownloadWindowReady(ownerID: oldOwner)

    service.terminateCameraCommunication(reason: "replace-exclusive-owner")
    let replacementOwner = service.beginExclusiveDownloadWindow()
    try await service.awaitExclusiveDownloadWindowReady(ownerID: replacementOwner)

    service.endExclusiveDownloadWindow(ownerID: oldOwner)

    XCTAssertEqual(
      logLock.withLock {
        logs.filter { $0.contains("PRIORITY_DOWNLOAD_FINISH") }.count
      },
      1
    )
    service.endExclusiveDownloadWindow(ownerID: replacementOwner)
  }

  func testRealtimeGalleryServiceLastOwnerFinishPrecedesInterleavedReplacementBatchBegin() async throws {
    let service = CameraVendorRealtimeGalleryService()
    let eventLock = NSLock()
    var events: [String] = []
    service.diagnosticHandler = { message in
      eventLock.withLock {
        if message.contains("PTP_PRIORITY_DOWNLOAD_BATCH_BEGIN_COMMAND_LANE") {
          events.append("begin")
        } else if message.contains("PRIORITY_DOWNLOAD_FINISH") {
          events.append("finish")
        }
      }
    }

    let oldOwner = service.beginExclusiveDownloadWindow()
    try await service.awaitExclusiveDownloadWindowReady(ownerID: oldOwner)

    var replacementOwner: CameraVendorExclusiveDownloadWindowOwnerID?
    service.exclusiveDownloadWindowEndStateDidCommitForTesting = {
      service.exclusiveDownloadWindowEndStateDidCommitForTesting = nil
      replacementOwner = service.beginExclusiveDownloadWindow()
    }
    service.endExclusiveDownloadWindow(ownerID: oldOwner)

    let unwrappedReplacementOwner = try XCTUnwrap(replacementOwner)
    try await service.awaitExclusiveDownloadWindowReady(ownerID: unwrappedReplacementOwner)

    XCTAssertEqual(
      eventLock.withLock { events },
      ["begin", "finish", "begin"]
    )
    service.endExclusiveDownloadWindow(ownerID: unwrappedReplacementOwner)
  }

  func testRealtimeGalleryServiceDiagnosticCallbackCanEndWindowWithoutDeadlock() async throws {
    let service = CameraVendorRealtimeGalleryService()
    let ownerID = service.beginExclusiveDownloadWindow()
    let callbackReturned = expectation(description: "diagnostic callback returned after ending window")
    service.diagnosticHandler = { message in
      guard message.contains("PTP_PRIORITY_DOWNLOAD_BATCH_BEGIN_COMMAND_LANE") else { return }
      service.endExclusiveDownloadWindow(ownerID: ownerID)
      callbackReturned.fulfill()
    }

    let waiter = Task { () -> String in
      do {
        try await service.awaitExclusiveDownloadWindowReady(ownerID: ownerID)
        return "ready"
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    await fulfillment(of: [callbackReturned], timeout: 1)
    let waiterResult = await waiter.value
    XCTAssertEqual(waiterResult, "cancelled")
  }

  func testPriorityBatchFinishIsSerializedBeforeNextCommandLaneOperation() async throws {
    let lane = CameraCommandLane()
    let lease = try await lane.acquireExclusiveDownloadLease()
    let activeStarted = expectation(description: "active download command started")
    let releaseActive = DispatchSemaphore(value: 0)
    let orderLock = NSLock()
    var order: [String] = []
    let active = Task {
      try await lane.run(priority: .download) {
        activeStarted.fulfill()
        releaseActive.wait()
        orderLock.withLock {
          order.append("active")
        }
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    lease.release(afterSerialized: {
      orderLock.withLock {
        order.append("finish")
      }
    })
    let next = Task {
      try await lane.run(priority: .visibleThumbnail) {
        orderLock.withLock {
          order.append("next")
        }
      }
    }

    releaseActive.signal()
    _ = try? await active.value
    _ = try? await next.value

    XCTAssertEqual(orderLock.withLock { order }, ["active", "finish", "next"])
  }

  func testCameraCommandLaneUsesOnePriorityOrderForAllPtpConsumers() {
    XCTAssertEqual(CameraCommandPriority.sessionMutation.rawValue, -1)
    XCTAssertEqual(CameraCommandPriority.download.rawValue, 0)
    XCTAssertEqual(CameraCommandPriority.hdPreview.rawValue, 1)
    XCTAssertEqual(CameraCommandPriority.visibleThumbnail.rawValue, 2)
    XCTAssertEqual(CameraCommandPriority.details.rawValue, 3)
    XCTAssertEqual(CameraCommandPriority.keepAlive.rawValue, 4)
  }

  func testCameraCommandLanePrioritizesVisibleThumbnailBeforeKeepAlive() async {
    let backgroundQueued = expectation(description: "background waiter queued")
    let thumbnailQueued = expectation(description: "thumbnail waiter queued")
    let lane = CameraCommandLane { priority in
      switch priority {
      case .keepAlive:
        backgroundQueued.fulfill()
      case .visibleThumbnail:
        thumbnailQueued.fulfill()
      default:
        break
      }
    }
    let activeStarted = expectation(description: "active request started")
    let releaseActive = DispatchSemaphore(value: 0)
    let orderLock = NSLock()
    var order: [String] = []

    let active = Task {
      try await lane.run(priority: .keepAlive) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let background = Task {
      try await lane.run(priority: .keepAlive) {
        orderLock.lock()
        order.append("background")
        orderLock.unlock()
      }
    }
    await fulfillment(of: [backgroundQueued], timeout: 1)
    let thumbnail = Task {
      try await lane.run(priority: .visibleThumbnail) {
        orderLock.lock()
        order.append("thumbnail")
        orderLock.unlock()
      }
    }
    await fulfillment(of: [thumbnailQueued], timeout: 1)

    releaseActive.signal()
    _ = try? await active.value
    _ = try? await thumbnail.value
    _ = try? await background.value

    XCTAssertEqual(order, ["thumbnail", "background"])
  }

  func testCameraCommandLaneRemovesCancelledWaitersLikeAndroid() async {
    let lane = CameraCommandLane()
    let activeStarted = expectation(description: "active request started")
    let releaseActive = DispatchSemaphore(value: 0)

    let active = Task {
      try await lane.run(priority: .keepAlive) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let cancelled = Task { () -> String in
      do {
        try await lane.run(priority: .keepAlive) {
          XCTFail("cancelled waiter should not run")
        }
        return "ran"
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    cancelled.cancel()

    let thumbnail = Task { () -> String in
      do {
        return try await lane.run(priority: .visibleThumbnail) {
          "thumbnail"
        }
      } catch {
        return "failed"
      }
    }

    releaseActive.signal()
    _ = try? await active.value

    let thumbnailResult = await thumbnail.value
    let cancelledResult = await cancelled.value

    XCTAssertEqual(thumbnailResult, "thumbnail")
    XCTAssertEqual(cancelledResult, "cancelled")
  }

  func testCameraCommandLaneRejectsNewNonDownloadRequestsDuringExclusiveDownload() async throws {
    let lane = CameraCommandLane()
    let lease = try await lane.acquireExclusiveDownloadLease()
    var didRunThumbnail = false

    let thumbnail = Task { () -> String in
      do {
        return try await lane.run(priority: .visibleThumbnail) {
          didRunThumbnail = true
          return "thumbnail"
        }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    let result = await thumbnail.value
    lease.release()

    XCTAssertEqual(result, "cancelled")
    XCTAssertFalse(didRunThumbnail)
  }

  func testCameraCommandLaneAllowsDownloadRequestsDuringExclusiveDownload() async throws {
    let lane = CameraCommandLane()
    let lease = try await lane.acquireExclusiveDownloadLease()

    let result = try? await lane.run(priority: .download) {
      "download"
    }

    lease.release()
    XCTAssertEqual(result, "download")
  }

  func testCameraCommandLaneDownloadBarrierPreservesQueuedSessionMutation() async throws {
    let mutationQueued = expectation(description: "session mutation queued")
    let lane = CameraCommandLane { priority in
      if priority == .sessionMutation {
        mutationQueued.fulfill()
      }
    }
    let activeStarted = expectation(description: "active details started")
    let releaseActive = DispatchSemaphore(value: 0)

    let active = Task {
      try await lane.run(priority: .details) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let mutation = Task { () -> String in
      do {
        return try await lane.run(priority: .sessionMutation) {
          "mutation"
        }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    await fulfillment(of: [mutationQueued], timeout: 1)

    let leaseTask = Task {
      try await lane.acquireExclusiveDownloadLease()
    }
    try? await Task.sleep(nanoseconds: 30_000_000)
    releaseActive.signal()
    _ = try? await active.value

    let mutationResult = await mutation.value
    let lease = try await leaseTask.value
    lease.release()

    XCTAssertEqual(mutationResult, "mutation")
  }

  func testCameraCommandLaneQueuesNewSessionMutationDuringDownloadBarrier() async throws {
    let mutationQueued = expectation(description: "session mutation queued")
    let lane = CameraCommandLane { priority in
      if priority == .sessionMutation {
        mutationQueued.fulfill()
      }
    }
    let lease = try await lane.acquireExclusiveDownloadLease()
    let downloadStarted = expectation(description: "download started")
    let releaseDownload = DispatchSemaphore(value: 0)

    let download = Task {
      try await lane.run(priority: .download) {
        downloadStarted.fulfill()
        releaseDownload.wait()
      }
    }
    await fulfillment(of: [downloadStarted], timeout: 1)

    let mutation = Task { () -> String in
      do {
        return try await lane.run(priority: .sessionMutation) {
          "mutation"
        }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    await fulfillment(of: [mutationQueued], timeout: 1)

    releaseDownload.signal()
    _ = try? await download.value
    let mutationResult = await mutation.value
    lease.release()

    XCTAssertEqual(mutationResult, "mutation")
  }

  func testCameraCommandLaneCancelsQueuedNonDownloadWorkBeforeAdmittingDownload() async throws {
    let lane = CameraCommandLane()
    let activeMetadataStarted = expectation(description: "active metadata started")
    let releaseActiveMetadata = DispatchSemaphore(value: 0)
    let orderQueue = DispatchQueue(label: "CameraCommandLaneTests.order")
    var order: [String] = []

    let activeMetadata = Task {
      try await lane.run(priority: .details) {
        activeMetadataStarted.fulfill()
        releaseActiveMetadata.wait()
        orderQueue.sync {
          order.append("active-metadata-ended")
        }
      }
    }
    await fulfillment(of: [activeMetadataStarted], timeout: 1)

    let queuedThumbnail = Task { () -> String in
      do {
        try await lane.run(priority: .visibleThumbnail) {
          XCTFail("queued thumbnail must not run after download barrier starts")
        }
        return "ran"
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    try? await Task.sleep(nanoseconds: 30_000_000)

    let leaseTask = Task {
      try await lane.acquireExclusiveDownloadLease()
    }
    let download = Task {
      let lease = try await leaseTask.value
      defer { lease.release() }
      try await lane.run(priority: .download) {
        orderQueue.sync {
          order.append("download-started")
        }
      }
    }

    try? await Task.sleep(nanoseconds: 30_000_000)
    let orderBeforeDrain = orderQueue.sync { order }
    XCTAssertTrue(orderBeforeDrain.isEmpty)

    releaseActiveMetadata.signal()
    _ = try? await activeMetadata.value
    _ = try? await download.value
    let queuedThumbnailResult = await queuedThumbnail.value

    let finalOrder = orderQueue.sync { order }
    XCTAssertEqual(queuedThumbnailResult, "cancelled")
    XCTAssertEqual(finalOrder, ["active-metadata-ended", "download-started"])
  }

  func testCameraCommandLaneWaitsForActiveTransactionToDrainBeforeDownloadLeaseIsReady() async throws {
    let lane = CameraCommandLane()
    let activeMetadataStarted = expectation(description: "active metadata started")
    let releaseActiveMetadata = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var didBecomeReady = false

    let activeMetadata = Task {
      try await lane.run(priority: .details) {
        activeMetadataStarted.fulfill()
        releaseActiveMetadata.wait()
      }
    }
    await fulfillment(of: [activeMetadataStarted], timeout: 1)

    let admission = Task {
      let lease = try await lane.acquireExclusiveDownloadLease()
      stateLock.withLock {
        didBecomeReady = true
      }
      return lease
    }

    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(stateLock.withLock { didBecomeReady })

    releaseActiveMetadata.signal()
    _ = try? await activeMetadata.value
    let lease = try await admission.value
    XCTAssertTrue(stateLock.withLock { didBecomeReady })
    lease.release()
  }

  func testCameraCommandLaneDoesNotCompleteDownloadLeaseBeforeActiveCommandDrains() async {
    let lane = CameraCommandLane()
    let activeStarted = expectation(description: "active command started")
    let releaseActive = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var leaseReady = false

    let active = Task {
      try await lane.run(priority: .details) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let admission = Task {
      let lease = try await lane.acquireExclusiveDownloadLease()
      stateLock.withLock {
        leaseReady = true
      }
      return lease
    }
    let barrierProbe = Task { () -> String in
      do {
        return try await lane.run(priority: .hdPreview) { "ran" }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    let barrierProbeResult = await barrierProbe.value
    XCTAssertEqual(barrierProbeResult, "cancelled")
    XCTAssertFalse(stateLock.withLock { leaseReady })

    releaseActive.signal()
    _ = try? await active.value
    let lease = try? await admission.value

    XCTAssertTrue(stateLock.withLock { leaseReady })
    lease?.release()
  }

  func testCameraCommandLaneCancellingDownloadAdmissionWhileDrainingReleasesItsBarrier() async {
    let thumbnailQueued = expectation(description: "thumbnail queued after cancelled admission")
    let admissionCancelled = expectation(description: "download admission cancelled before drain")
    let lane = CameraCommandLane { priority in
      if priority == .visibleThumbnail {
        thumbnailQueued.fulfill()
      }
    }
    let activeStarted = expectation(description: "active command started")
    let releaseActive = DispatchSemaphore(value: 0)

    let active = Task {
      try await lane.run(priority: .details) {
        activeStarted.fulfill()
        releaseActive.wait()
      }
    }
    await fulfillment(of: [activeStarted], timeout: 1)

    let admission = Task { () -> String in
      do {
        let lease = try await lane.acquireExclusiveDownloadLease()
        lease.release()
        return "ready"
      } catch is CancellationError {
        admissionCancelled.fulfill()
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let barrierProbe = Task { () -> String in
      do {
        return try await lane.run(priority: .hdPreview) { "ran" }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }
    let barrierProbeResult = await barrierProbe.value
    XCTAssertEqual(barrierProbeResult, "cancelled")

    admission.cancel()
    await fulfillment(of: [admissionCancelled], timeout: 1)
    let thumbnail = Task { () -> String in
      do {
        return try await lane.run(priority: .visibleThumbnail) { "thumbnail" }
      } catch is CancellationError {
        return "cancelled"
      } catch {
        return "failed"
      }
    }

    await fulfillment(of: [thumbnailQueued], timeout: 1)
    releaseActive.signal()
    _ = try? await active.value

    let admissionResult = await admission.value
    let thumbnailResult = await thumbnail.value
    XCTAssertEqual(admissionResult, "cancelled")
    XCTAssertEqual(thumbnailResult, "thumbnail")
  }

  func testCameraCommandLaneExclusiveSessionMutationWaitsForActiveReadAndBlocksDownloads() async {
    let lane = CameraCommandLane()
    let activeReadStarted = expectation(description: "active read started")
    let releaseActiveRead = DispatchSemaphore(value: 0)
    let mutationStarted = expectation(description: "mutation started")
    let releaseMutation = DispatchSemaphore(value: 0)
    let orderLock = NSLock()
    var order: [String] = []

    let activeRead = Task {
      try await lane.run(priority: .visibleThumbnail) {
        activeReadStarted.fulfill()
        releaseActiveRead.wait()
      }
    }
    await fulfillment(of: [activeReadStarted], timeout: 1)

    let mutation = Task {
      try await lane.runExclusiveSessionMutation {
        orderLock.lock()
        order.append("mutation")
        orderLock.unlock()
        mutationStarted.fulfill()
        releaseMutation.wait()
      }
    }

    let download = Task {
      try await lane.run(priority: .download) {
        orderLock.lock()
        order.append("download")
        orderLock.unlock()
      }
    }

    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(order.isEmpty)
    releaseActiveRead.signal()
    _ = try? await activeRead.value
    await fulfillment(of: [mutationStarted], timeout: 1)
    XCTAssertEqual(order, ["mutation"])

    releaseMutation.signal()
    _ = try? await mutation.value
    _ = try? await download.value
    XCTAssertEqual(order, ["mutation", "download"])
  }

  func testCameraCommandLeaseReleaseIsIdempotent() async throws {
    let lane = CameraCommandLane()
    let lease = try await lane.acquireExclusiveDownloadLease()

    lease.release()
    lease.release()

    let result = try await lane.run(priority: .visibleThumbnail) { "thumbnail" }
    XCTAssertEqual(result, "thumbnail")
  }

  func testCameraCommandLeaseDeinitReleasesDownloadBarrier() async throws {
    let lane = CameraCommandLane()
    var lease: CameraCommandLease? = try await lane.acquireExclusiveDownloadLease()
    XCTAssertNotNil(lease)

    lease = nil

    let result = try await lane.run(priority: .visibleThumbnail) { "thumbnail" }
    XCTAssertEqual(result, "thumbnail")
  }

  func testCameraCommandLeaseFirstReleaseKeepsOverlappingSecondBarrierActive() async throws {
    let lane = CameraCommandLane()
    let firstLease = try await lane.acquireExclusiveDownloadLease()
    let secondLease = try await lane.acquireExclusiveDownloadLease()

    firstLease.release()
    let blockedResult: String
    do {
      blockedResult = try await lane.run(priority: .visibleThumbnail) { "ran" }
    } catch is CancellationError {
      blockedResult = "cancelled"
    }

    secondLease.release()
    let admittedResult = try await lane.run(priority: .visibleThumbnail) { "thumbnail" }

    XCTAssertEqual(blockedResult, "cancelled")
    XCTAssertEqual(admittedResult, "thumbnail")
  }

  func testCameraCommandLeaseSecondReleaseKeepsOverlappingFirstBarrierActive() async throws {
    let lane = CameraCommandLane()
    let firstLease = try await lane.acquireExclusiveDownloadLease()
    let secondLease = try await lane.acquireExclusiveDownloadLease()

    secondLease.release()
    let blockedResult: String
    do {
      blockedResult = try await lane.run(priority: .visibleThumbnail) { "ran" }
    } catch is CancellationError {
      blockedResult = "cancelled"
    }

    firstLease.release()
    let admittedResult = try await lane.run(priority: .visibleThumbnail) { "thumbnail" }

    XCTAssertEqual(blockedResult, "cancelled")
    XCTAssertEqual(admittedResult, "thumbnail")
  }

  func testCameraVendorPlaceholderObjectInfoUsesUndefinedFormatLikeAndroid() {
    let info = CameraVendorCameraObjectInfo.placeholder(handle: 10)

    XCTAssertEqual(info.formatCode, 0x3000)
    XCTAssertEqual(info.filename, "0x0000000A")
    XCTAssertFalse(info.hasResolvedFormat)
  }

  func testCatalogPlaceholderPolicyAssignsValidatedDateGroupsInCameraOrder() {
    let groups = [
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260624", objectCount: 2),
      CameraVendorSpecifiedObjectDateGroup(dateText: "20260623", objectCount: 1),
    ]

    let items = CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: [100, 102, 101],
      dateGroups: groups
    )
    let sections = NativeGallerySectionPolicy.sections(
      from: items,
      now: Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 6, day: 24, hour: 12))!,
      calendar: Calendar(identifier: .gregorian)
    )

    XCTAssertEqual(items.map(\.handle), [100, 102, 101])
    XCTAssertEqual(items.map(\.captureDate), ["20260624", "20260624", "20260623"])
    XCTAssertEqual(sections.map(\.title), ["今天 6月24日 2 张", "6月23日 1 张"])
    XCTAssertEqual(sections.map { $0.items.map(\.handle) }, [[100, 102], [101]])
  }

  func testGalleryInitialItemsPreserveD621OrderInsteadOfSortingByHandle() {
    let infos = [
      CameraVendorCameraObjectInfo.placeholder(handle: 1267, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1268, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1265, captureDate: "20260426"),
      CameraVendorCameraObjectInfo.placeholder(handle: 1266, captureDate: "20260426"),
    ]

    let items = CameraVendorGalleryItemOrderingPolicy.galleryItems(
      from: infos,
      preserveInputOrder: true
    )

    XCTAssertEqual(items.map(\.handle), [1267, 1268, 1265, 1266])
  }

  func testCameraVendorGalleryItemOrderingCarriesObjectOrientation() {
    let info = CameraVendorCameraObjectInfo(
      handle: 77,
      storageID: 0x00010001,
      formatCode: 0x3801,
      compressedSize: 4_000_000,
      thumbCompressedSize: 80_000,
      filename: "DSCF0077.JPG",
      captureDate: "2026:06:24 10:10:10",
      orientation: 2
    )

    let items = CameraVendorGalleryItemOrderingPolicy.galleryItems(from: [info])

    XCTAssertEqual(items.first?.orientation, 2)
  }

  func testNativeGalleryMetadataMergePreservesInitialDateGroupWhenResolvedDateIsMissingOrWrong() {
    let existing = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let missingDate = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: "4 MB"
    )
    let sameDayWithTime = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB"
    )
    let wrongDay = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:23 10:11:12",
      byteSizeText: "4 MB"
    )

    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: missingDate).captureDate,
      "20260624"
    )
    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: sameDayWithTime).captureDate,
      "2026:06:24 10:11:12"
    )
    XCTAssertEqual(
      NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: wrongDay).captureDate,
      "20260624"
    )
  }

  func testNativeGalleryMetadataMergeReplacesUnresolvedPlaceholderWithRawAndHeifMetadata() {
    let placeholder = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      thumbnailData: Data([0xFF, 0xD8, 0xFF])
    )
    let raw = CameraVendorGalleryItem(
      handle: 1,
      filename: "DSCF0001.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "42 MB"
    )
    let heif = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:06:24 10:12:12",
      byteSizeText: "6 MB"
    )

    let mergedRaw = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: raw)
    let mergedHeif = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: nil, resolvedItem: heif)

    XCTAssertEqual(mergedRaw.filename, "DSCF0001.RAF")
    XCTAssertEqual(mergedRaw.formatLabel, "RAW")
    XCTAssertEqual(mergedRaw.thumbnailData, placeholder.thumbnailData)
    XCTAssertEqual(mergedHeif.filename, "DSCF0002.HEIC")
    XCTAssertEqual(mergedHeif.formatLabel, "HEIF")
  }

  func testNativeGalleryMetadataMergeClearsAmbiguousHintsWhenFormatResolves() {
    let placeholder = CameraVendorGalleryItem(
      handle: 7,
      filename: "0x00000007",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.heif, .raw]
    )
    let raw = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.RAF",
      formatLabel: "RAW",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "42 MB"
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: raw)

    XCTAssertEqual(merged.formatLabel, "RAW")
    XCTAssertTrue(merged.formatHints.isEmpty)
  }

  func testNativeGalleryMetadataMergeUpgradesResolvedFormatWithoutOverwritingStableCatalogTruth() {
    let existing = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      formatHints: [.jpg]
    )
    let resolved = CameraVendorGalleryItem(
      handle: 7,
      filename: "DSCF7551.HEIC",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB"
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: existing, resolvedItem: resolved)

    XCTAssertEqual(merged.filename, "DSCF0007.JPG")
    XCTAssertEqual(merged.formatLabel, "JPG")
    XCTAssertEqual(merged.captureDate, "2026:06:24 10:11:12")
    XCTAssertEqual(merged.byteSizeText, "4 MB")
    XCTAssertTrue(merged.formatHints.isEmpty)
  }

  func testNativeGalleryMetadataMergeUpdatesOrientationFromResolvedMetadata() {
    let placeholder = CameraVendorGalleryItem(
      handle: 8,
      filename: "0x00000008",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: "",
      orientation: nil,
      thumbnailData: Data([0xFF, 0xD8])
    )
    let resolved = CameraVendorGalleryItem(
      handle: 8,
      filename: "DSCF0008.JPG",
      formatLabel: "JPG",
      captureDate: "2026:06:24 10:11:12",
      byteSizeText: "4 MB",
      orientation: 4
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItem(existingItem: placeholder, resolvedItem: resolved)

    XCTAssertEqual(merged.orientation, 4)
    XCTAssertEqual(merged.thumbnailData, Data([0xFF, 0xD8]))
  }

  func testNativeGalleryMetadataMergePreservesExistingHandleOrderForBackgroundBatches() {
    let first = CameraVendorGalleryItem(
      handle: 1,
      filename: "0x00000001",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let second = CameraVendorGalleryItem(
      handle: 2,
      filename: "0x00000002",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let third = CameraVendorGalleryItem(
      handle: 3,
      filename: "0x00000003",
      formatLabel: "",
      captureDate: "20260624",
      byteSizeText: ""
    )
    let resolvedSecond = CameraVendorGalleryItem(
      handle: 2,
      filename: "DSCF0002.HEIC",
      formatLabel: "HEIF",
      captureDate: "2026:06:24 10:12:12",
      byteSizeText: "6 MB"
    )

    let merged = NativeGalleryMetadataMergePolicy.mergedItemsPreservingExistingOrder(
      existingItems: [first, second, third],
      resolvedItems: [resolvedSecond]
    )

    XCTAssertEqual(merged.map(\.handle), [1, 2, 3])
    XCTAssertEqual(merged[1].filename, "DSCF0002.HEIC")
    XCTAssertEqual(merged[1].formatLabel, "HEIF")
  }

  func testNativeGalleryBackgroundMetadataUIRefreshPolicyUsesVisibleOnlyForDefaultAndroidGallery() {
    XCTAssertTrue(NativeGalleryBackgroundMetadataUIRefreshPolicy.shouldApplyPublishedAndroidBatchImmediately)
    XCTAssertTrue(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState()
      )
    )

    XCTAssertFalse(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState(formats: .selected([.heif]))
      )
    )

    XCTAssertFalse(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.canRefreshVisibleItemsOnly(
        filterState: NativeGalleryFilterState(sort: .oldest)
      )
    )
  }

  func testNativeGalleryBackgroundMetadataUIRefreshPolicyKeepsVisibleOnlyRefreshForResolvedExistingHandles() {
    let existingItems = [
      CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "20260624", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "", captureDate: "20260624", byteSizeText: ""),
    ]
    let resolvedItems = [
      CameraVendorGalleryItem(handle: 2, filename: "DSCF0002.HEIC", formatLabel: "HEIF", captureDate: "2026:06:24 10:12:12", byteSizeText: "6 MB")
    ]

    XCTAssertFalse(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.requiresCollectionReload(
        existingItems: existingItems,
        resolvedItems: resolvedItems,
        filterState: NativeGalleryFilterState()
      )
    )
  }

  func testNativeGalleryBackgroundMetadataUIRefreshPolicyRequiresReloadWhenBatchIntroducesNewHandles() {
    let existingItems = [
      CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "20260624", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "", captureDate: "20260624", byteSizeText: ""),
    ]
    let resolvedItems = [
      CameraVendorGalleryItem(handle: 3, filename: "DSCF0003.RAF", formatLabel: "RAW", captureDate: "2026:06:24 10:13:12", byteSizeText: "42 MB")
    ]

    XCTAssertTrue(
      NativeGalleryBackgroundMetadataUIRefreshPolicy.requiresCollectionReload(
        existingItems: existingItems,
        resolvedItems: resolvedItems,
        filterState: NativeGalleryFilterState()
      )
    )
  }

  func testGalleryCatalogRuntimeOwnsDetailsWorkInsteadOfVendorBackgroundLoop() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let vendorSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    )
    let runtimeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift")
    )

    XCTAssertFalse(vendorSource.contains("scheduleFullObjectInfoRefreshAfterInitialPlaceholders"))
    XCTAssertTrue(runtimeSource.contains("private func loadDetails("))
    XCTAssertTrue(runtimeSource.contains("result = try await source.loadDetails(handle: handle)"))
  }

  func testRealtimeGalleryServiceHasNoFastInitialOrFullObjectInfoCatalogFallback() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertFalse(source.contains("fastInitialGalleryObjectInfos"))
    XCTAssertFalse(source.contains("galleryObjectInfos()"))
    XCTAssertFalse(source.contains("GALLERY_FAST_INITIAL_ITEMS"))
  }

  func testRealtimeGalleryServiceOwnsDedicatedPtpRuntimeForTransportScheduling() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let serviceStart = try XCTUnwrap(source.range(of: "final class CameraVendorRealtimeGalleryService")?.lowerBound)
    let configureStart = try XCTUnwrap(source.range(of: "func configure(connectionSummary:", range: serviceStart..<source.endIndex)?.lowerBound)
    let serviceBody = String(source[serviceStart..<configureStart])

    XCTAssertTrue(serviceBody.contains("private lazy var ptpRuntime = CameraVendorPtpSessionRuntime("))
    XCTAssertTrue(serviceBody.contains("session: session"))
    XCTAssertTrue(source.contains("private let commandLane: CameraCommandLane"))
    XCTAssertTrue(source.contains("commandLane: CameraCommandLane = CameraCommandLane()"))
    XCTAssertFalse(serviceBody.contains("private let requestScheduler = CameraVendorGalleryRequestScheduler()"))
    XCTAssertFalse(serviceBody.contains("private let priorityDownloadLock = NSLock()"))
  }

  func testPtpRuntimePublishesOnlyInitializedExclusiveDownloadLeaseAcquisition() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let acquisitionStart = try XCTUnwrap(
      source.range(of: "private final class ExclusiveDownloadLeaseAcquisition")?.lowerBound
    )
    let acquisitionEnd = try XCTUnwrap(
      source.range(of: "private let session:", range: acquisitionStart..<source.endIndex)?.lowerBound
    )
    let acquisitionBody = String(source[acquisitionStart..<acquisitionEnd])

    XCTAssertTrue(acquisitionBody.contains("private let task: Task<Void, Error>"))
    XCTAssertTrue(acquisitionBody.contains("init(commandLane: CameraCommandLane)"))
    XCTAssertTrue(acquisitionBody.contains("task = Task"))
    XCTAssertFalse(acquisitionBody.contains("func start(commandLane:"))
    let waitUntilReadyStart = try XCTUnwrap(
      acquisitionBody.range(of: "func waitUntilReady() async throws")?.lowerBound
    )
    let cancellationBody = acquisitionBody[waitUntilReadyStart..<acquisitionBody.endIndex]
    XCTAssertTrue(cancellationBody.contains("task.cancel()"))
    XCTAssertTrue(cancellationBody.contains("state.cancel(afterSerialized: finalizer)"))

    let beginStart = try XCTUnwrap(
      source.range(
        of: "func beginExclusiveDownloadWindow(ownerID:",
        range: acquisitionEnd..<source.endIndex
      )?.lowerBound
    )
    let awaitStart = try XCTUnwrap(
      source.range(of: "func awaitExclusiveDownloadWindowReady(", range: beginStart..<source.endIndex)?.lowerBound
    )
    let beginBody = source[beginStart..<awaitStart]
    let construction = try XCTUnwrap(
      beginBody.range(of: "let acquisition = ExclusiveDownloadLeaseAcquisition(commandLane: commandLane)")
    )
    let publication = try XCTUnwrap(
      beginBody.range(of: "exclusiveDownloadWindowGenerations[ownerID.generationID] =")
    )

    XCTAssertLessThan(construction.lowerBound, publication.lowerBound)
    XCTAssertFalse(beginBody.contains("acquisition.start("))
    XCTAssertTrue(source.contains("func awaitExclusiveDownloadWindowReady(\n    ownerID:"))
    XCTAssertTrue(source.contains("async throws -> T"))
    XCTAssertFalse(source.contains("async rethrows -> T"))
  }

  func testBackgroundMetadataRefreshResumePolicyTracksPendingHandlesAcrossResolutionAndRecovery() {
    let initial = CameraVendorBackgroundMetadataRefreshResumePolicy.initialState(
      handles: [7, 7, 8],
      communicationGeneration: 5
    )
    let appended = CameraVendorBackgroundMetadataRefreshResumePolicy.appendingHandles(
      [8, 9, 10],
      to: initial
    )
    let reduced = CameraVendorBackgroundMetadataRefreshResumePolicy.removingResolvedHandles(
      [7, 10],
      from: appended
    )

    XCTAssertEqual(initial?.pendingHandles, [7, 8])
    XCTAssertEqual(appended?.pendingHandles, [7, 8, 9, 10])
    XCTAssertEqual(reduced?.pendingHandles, [8, 9])
  }

  func testBackgroundMetadataRefreshResumePolicyOnlyResumesCurrentConnectedNonPriorityState() {
    let state = CameraVendorBackgroundMetadataRefreshResumePolicy.initialState(
      handles: [7, 8],
      communicationGeneration: 5
    )

    XCTAssertEqual(
      CameraVendorBackgroundMetadataRefreshResumePolicy.resumableState(
        state,
        currentGeneration: 5,
        sessionIsConnected: true,
        isPriorityDownloadActive: false
      )?.pendingHandles,
      [7, 8]
    )
    XCTAssertNil(
      CameraVendorBackgroundMetadataRefreshResumePolicy.resumableState(
        state,
        currentGeneration: 6,
        sessionIsConnected: true,
        isPriorityDownloadActive: false
      )
    )
    XCTAssertNil(
      CameraVendorBackgroundMetadataRefreshResumePolicy.resumableState(
        state,
        currentGeneration: 5,
        sessionIsConnected: false,
        isPriorityDownloadActive: false
      )
    )
    XCTAssertNil(
      CameraVendorBackgroundMetadataRefreshResumePolicy.resumableState(
        state,
        currentGeneration: 5,
        sessionIsConnected: true,
        isPriorityDownloadActive: true
      )
    )
  }

  func testNativeGalleryThumbnailFailurePolicyRetriesInteractionAndDownloadPauses() {
    XCTAssertFalse(NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(CancellationError()))
    XCTAssertFalse(
      NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(
        NSError(
          domain: "CameraVendorRealtimeGalleryService",
          code: CameraVendorPriorityDownloadThumbnailGatePolicy.suspendedThumbnailErrorCode
        )
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailFailurePolicy.shouldRememberFailure(
        NSError(domain: "CameraVendorPtpSession", code: 0x100A)
      )
    )
  }

  func testNativeGalleryThumbnailLoadingPolicyDoesNotStartCatalogWorkOutsideGalleryReady() {
    XCTAssertFalse(
      NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
        runtimeCanAcceptCatalogCommands: false,
        isDownloading: false
      )
    )
    XCTAssertFalse(
      NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
        runtimeCanAcceptCatalogCommands: true,
        isDownloading: true
      )
    )
    XCTAssertTrue(
      NativeGalleryThumbnailLoadingPolicy.shouldStartCatalogWork(
        runtimeCanAcceptCatalogCommands: true,
        isDownloading: false
      )
    )
  }

  func testNativeGalleryThumbnailFailureLoggingTreatsCancellationAsNormal() {
    XCTAssertFalse(NativeGalleryThumbnailUILogPolicy.shouldEmitFailure(for: CancellationError()))
    XCTAssertTrue(
      NativeGalleryThumbnailUILogPolicy.shouldEmitFailure(
        for: NSError(domain: "CameraVendorPtpSession", code: 0x100A)
      )
    )
  }

  func testPriorityDownloadDoesNotForcePtpInterruptionBeforeDownload() {
    XCTAssertFalse(
      NativeGalleryPriorityDownloadPolicy.shouldInterruptPtpBeforeDownload(
        isThumbnailRequestInFlight: true
      )
    )
    XCTAssertFalse(
      NativeGalleryPriorityDownloadPolicy.shouldInterruptPtpBeforeDownload(
        isThumbnailRequestInFlight: false
      )
    )
  }

  func testPreviewThumbnailPolicyPausesWhileDownloading() {
    XCTAssertFalse(NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(isDownloading: true))
    XCTAssertTrue(NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(isDownloading: false))
  }

  func testNativeGalleryDownloadFlowRemovesPauseAndBackgroundBudgetPaths() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertFalse(source.contains("private func requestPauseDownload()"))
    XCTAssertFalse(source.contains("private func requestBackgroundBudgetPauseIfNeeded(reason: String)"))
    XCTAssertFalse(source.contains("private func resumeDownloadsAfterBackgroundPauseIfNeeded(reason: String)"))
    XCTAssertFalse(source.contains("backgroundBudgetPaused"))
  }

  func testPartialObjectDownloadPolicyStopsAtExpectedSizeEvenForJpeg() {
    XCTAssertTrue(
      CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: 167_936,
        expectedBytes: 167_936,
        isJpegObject: true,
        hasJpegEndMarker: false
      )
    )
    XCTAssertFalse(
      CameraVendorPartialObjectDownloadPolicy.shouldStopAfterChunk(
        totalBytes: 64_000,
        expectedBytes: 167_936,
        isJpegObject: true,
        hasJpegEndMarker: false
      )
    )
  }

  func testCameraVendorCameraObjectInfoLabelsHeifFormat() {
    let info = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0x3812,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: "DSCF0001.HEIC",
      captureDate: ""
    )

    XCTAssertEqual(info.formatLabel, "HEIF")
  }

  func testCameraVendorCameraObjectInfoLabelsCameraVendorRawVariant() {
    let info = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0,
      formatCode: 0xB103,
      compressedSize: 0,
      thumbCompressedSize: 0,
      filename: "DSCF0001.RAF",
      captureDate: ""
    )

    XCTAssertEqual(info.formatLabel, "RAW")
  }

  func testCameraVendorDualSlotStatusDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.dualSlotStatus, 0xD244)
    XCTAssertEqual(CameraVendorDevicePropCode.dualSlotStatus, CameraVendorDevicePropCode.referenceAppGalleryAccessState)
  }

  func testCameraVendorSpecifiedObjectCountDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.specifiedObjectCount, 0xD620)
  }

  func testCameraVendorSpecifiedObjectHandlesDevicePropertyMatchesReferenceAppNativeSDK() {
    XCTAssertEqual(CameraVendorDevicePropCode.specifiedObjectHandles, 0xD621)
  }

  func testCameraVendorSpecifiedObjectHandlesParserReadsCountPrefixedHandles() {
    let data = Data([
      0x02, 0x00, 0x00, 0x00,
      0xCA, 0x03, 0x00, 0x00,
      0xC9, 0x03, 0x00, 0x00,
    ])

    XCTAssertEqual(CameraVendorPtpDataParser.uint32Array(from: data), [0x000003CA, 0x000003C9])
  }

  func testCameraVendorSpecifiedObjectCountGroupByDateParserReadsDateGroups() {
    let data = Data([
      0x02, 0x00, 0x00, 0x00,
      0x1B, 0x00, 0x00, 0x00,
      0x09, 0x32, 0x00, 0x30, 0x00, 0x32, 0x00, 0x36, 0x00, 0x30, 0x00,
      0x35, 0x00, 0x30, 0x00, 0x34, 0x00, 0x00, 0x00,
      0x07, 0x00, 0x00, 0x00,
      0x1B, 0x00, 0x00, 0x00,
      0x09, 0x32, 0x00, 0x30, 0x00, 0x32, 0x00, 0x36, 0x00, 0x30, 0x00,
      0x35, 0x00, 0x31, 0x00, 0x30, 0x00, 0x00, 0x00,
      0x03, 0x00, 0x00, 0x00,
    ])

    let groups = CameraVendorPtpDataParser.specifiedObjectDateGroups(from: data)

    XCTAssertEqual(groups.count, 2)
    XCTAssertEqual(groups[0].dateText, "20260504")
    XCTAssertEqual(groups[0].objectCount, 7)
    XCTAssertEqual(groups[1].dateText, "20260510")
    XCTAssertEqual(groups[1].objectCount, 3)
  }

  func testCameraVendorLegacyThumbnailPacketsUseAlternateDataAndResponseKinds() {
    XCTAssertEqual(CameraVendorLegacyPacketMapper.packetType(forKind: 21), CameraVendorPtpPacketType.dataPacket)
    XCTAssertEqual(CameraVendorLegacyPacketMapper.packetType(forKind: 12), CameraVendorPtpPacketType.operationResponse)
  }

  func testCameraVendorLegacyThumbnailCompletionPacketSynthesizesOkResponse() {
    let payload = Data([0x00, 0x00, 0x34, 0x12, 0x00, 0x00])

    XCTAssertEqual(
      CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: 12, body: payload),
      Data([0x01, 0x20, 0x34, 0x12, 0x00, 0x00])
    )
    XCTAssertEqual(CameraVendorLegacyPacketMapper.operationResponsePayload(forKind: 3, body: payload), payload)
  }

  func testCameraVendorCompressionResetPayloadUsesUInt32Zero() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      transactionID: 14,
      data: Data([0x00, 0x00, 0x00, 0x00])
    )

    XCTAssertEqual(Array(data.suffix(4)), [0x00, 0x00, 0x00, 0x00])
  }

  func testCameraVendorInitSequencePayloadUsesUInt16Twenty() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.setDevicePropValue),
      transactionID: 18,
      data: Data([0x14, 0x00])
    )

    XCTAssertEqual(Array(data.suffix(2)), [0x14, 0x00])
  }

  func testMtpGetObjectPropListOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.mtpGetObjectPropList, 0x9805)
  }

  func testCameraVendorGetSearchModeDescAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll, 0x9050)
  }

  func testCameraVendorGetSearchModeDescAllPacketHasNoParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeDescAll),
      transactionID: 11
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x50, 0x90,
        0x0B, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSearchModeAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll, 0x9052)
  }

  func testCameraVendorGetSearchModeAllPacketHasNoParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSearchModeAll),
      transactionID: 12
    )

    XCTAssertEqual(
      Array(data),
      [
        0x0C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x52, 0x90,
        0x0C, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSpecifiedObjectCountGroupByDateOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate, 0x9053)
  }

  func testCameraVendorGetExtensionThumbOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb, 0x9055)
  }

  func testCameraVendorGetExtensionThumbPacketMatchesReferenceAppCurrentHandle() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionThumb),
      transactionID: 10,
      parameters: [CameraVendorReferenceAppCurrentImageContextPolicy.currentImageHandle]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x55, 0x90,
        0x0A, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x10,
      ]
    )
  }

  func testCameraVendorGetPartialObjectOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.getPartialObject, 0x101B)
  }

  func testCameraVendorGetPartialObjectPacketMatchesReferenceAppJpegParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.getPartialObject),
      transactionID: 17,
      parameters: CameraVendorPartialObjectRequestPolicy.standardPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
      )
    )

    XCTAssertEqual(
      Array(data),
      [
        0x18, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x1B, 0x10,
        0x11, 0x00, 0x00, 0x00,
        0xCA, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00,
      ]
    )
  }

  func testCameraVendorGetExtensionPartialObjectOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorGetExtensionPartialObject, 0x9056)
  }

  func testCameraVendorGetExtensionPartialObjectPacketMatchesReferenceAppParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetExtensionPartialObject),
      transactionID: 16,
      parameters: CameraVendorPartialObjectRequestPolicy.extensionPartialObjectParameters(
        handle: 0x000003CA,
        offset: 0,
        size: CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize
      )
    )

    XCTAssertEqual(
      Array(data),
      [
        0x1C, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x56, 0x90,
        0x10, 0x00, 0x00, 0x00,
        0xCA, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorGetSpecifiedObjectCountGroupByDatePacketMatchesReferenceAppParameters() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyOperationRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorGetSpecifiedObjectCountGroupByDate),
      transactionID: 15,
      parameters: [0, 30000]
    )

    XCTAssertEqual(
      Array(data),
      [
        0x14, 0x00, 0x00, 0x00,
        0x01, 0x00,
        0x53, 0x90,
        0x0F, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x30, 0x75, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorSetSearchModeAllOperationMatchesNativeSDK() {
    XCTAssertEqual(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll, 0x9051)
  }

  func testCameraVendorSetSearchModeAllEmptyPayloadMatchesReferenceAppResetLayout() {
    let data = CameraVendorPtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(
      operationCode: UInt16(CameraVendorPtpOperationCode.cameraVendorSetSearchModeAll),
      transactionID: 13,
      data: Data([0x00, 0x00, 0x00, 0x00])
    )

    XCTAssertEqual(
      Array(data),
      [
        0x10, 0x00, 0x00, 0x00,
        0x02, 0x00,
        0x51, 0x90,
        0x0D, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
      ]
    )
  }

  func testCameraVendorSetSearchModeAllObjectFormatPayloadIncludesAndroidAllFormats() {
    XCTAssertEqual(
      CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
        CameraVendorSearchModeAllPayload.allObjectFormatMask
      ),
      Data([
        0x01, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x04, 0xD6,
        0x1F, 0x00,
      ])
    )
  }

  func testCameraVendorSetSearchModeAllHEIFPayloadMatchesOfficialXAppWire() {
    XCTAssertEqual(
      CameraVendorSearchModeAllPayload.objectFormatMaskPayload(
        CameraVendorSearchModeAllPayload.heifObjectFormatMask
      ),
      Data([
        0x01, 0x00, 0x00, 0x00,
        0x08, 0x00, 0x00, 0x00,
        0x04, 0xD6,
        0x02, 0x00,
      ])
    )
  }

  func testCameraVendorSearchModeReadbackExtractsOfficialD604Value() {
    let readback = Data([
      0x05, 0x00, 0x00, 0x00,
      0x09, 0x00, 0x00, 0x00, 0x01, 0xD6, 0x01, 0x00, 0x00,
      0x09, 0x00, 0x00, 0x00, 0x02, 0xD6, 0x01, 0x00, 0x00,
      0x08, 0x00, 0x00, 0x00, 0x03, 0xD6, 0x00, 0x00,
      0x08, 0x00, 0x00, 0x00, 0x04, 0xD6, 0x02, 0x00,
      0x0A, 0x00, 0x00, 0x00, 0x05, 0xD6, 0x00, 0x00, 0x00, 0x00,
    ])

    XCTAssertEqual(
      CameraVendorSearchModeAllReadback.uint16Value(
        propertyCode: CameraVendorSearchModeAllPayload.objectFormatPropertyCode,
        from: readback
      ),
      CameraVendorSearchModeAllPayload.heifObjectFormatMask
    )
  }

  func testCameraVendorCatalogTransactionReadsDirectoryImmediatelyAfterWriteWithoutUncapturedReadback() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func cameraVendorCatalogSnapshot(")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "private func primeCameraVendorCurrentImageContextIfNeeded(", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])
    let write = try XCTUnwrap(body.range(of: "sendCommandWithData("))
    let directory = try XCTUnwrap(body.range(of: "requestCameraVendorSpecifiedObjectSnapshot("))

    XCTAssertLessThan(write.lowerBound, directory.lowerBound)
    XCTAssertFalse(body.contains("catalog-query-verify-"))
    XCTAssertFalse(body.contains("CameraVendorSearchModeAllReadback.uint16Value("))
  }

  func testCameraVendorSearchModeAllPayloadDoesNotExposeAnUntypedStringCondition() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("case ptpString"))
  }

  func testGalleryFilterRefreshUsesRuntimeCameraCatalogTransactionInsteadOfObjectInfoSync() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let requestStart = try XCTUnwrap(
      source.range(of: "private func submitGalleryIntent()")?.lowerBound
    )
    let requestEnd = try XCTUnwrap(
      source.range(of: "@objc private func toggleFilterPanel()", range: requestStart..<source.endIndex)?.lowerBound
    )
    let requestBody = String(source[requestStart..<requestEnd])

    XCTAssertTrue(requestBody.contains("runtime.submitGalleryFilter("))
    XCTAssertTrue(requestBody.contains("rule: filterState.rule"))
    XCTAssertTrue(requestBody.contains("sort: filterState.sortIntent"))
    XCTAssertFalse(requestBody.contains("submitUnsupportedGalleryFilter"))
    XCTAssertFalse(requestBody.contains("runtime.requestCameraCatalog(query:"))
    XCTAssertFalse(requestBody.contains("runtime.requestCompleteGalleryCatalog()"))
  }

  @MainActor
  func testCatalogRuntimeStartUsesInitialDirectoryBeforeFilteredCatalogTransactions() async throws {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        if case .ready = presentation.state {
          initialReady.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 2)

    XCTAssertEqual(source.initialCatalogRequestCount, 1)
    XCTAssertEqual(source.catalogIntents, [])
    await runtime.cancelAllChildren()
  }

  func testCatalogRuntimeDelegatesThumbnailAndDetailsTasksToPipeline() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery")
    let runtimeSource = try String(
      contentsOf: root.appendingPathComponent("CameraGalleryCatalogRuntime.swift")
    )

    XCTAssertTrue(runtimeSource.contains("CameraGalleryThumbnailPipeline"))
    XCTAssertFalse(runtimeSource.contains("private var thumbnailTask"))
    XCTAssertFalse(runtimeSource.contains("private var detailsTask"))
    XCTAssertFalse(runtimeSource.contains("private var activeThumbnailRequest"))
    XCTAssertFalse(runtimeSource.contains("private var enrichedObjectInfos"))
  }

  @MainActor
  func testThumbnailPipelineRejectsPublicationFromAnOldCatalogIdentity() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsThumbnailResultsUntilReleased = true
    let oldIdentity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let currentIdentity = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: oldIdentity.sessionEpoch,
      generation: 2
    )
    var publications: [CameraGalleryThumbnailPipeline.Publication] = []
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { publication in
      publications.append(publication)
    }

    await pipeline.install(
      catalogIdentity: oldIdentity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await source.waitForThumbnailRequestCount(1)
    let installCurrent = Task {
      await pipeline.install(
        catalogIdentity: currentIdentity,
        membership: [7],
        reusableObjectInfos: [:]
      )
    }
    for _ in 0..<20 { await Task.yield() }
    source.releaseThumbnailResults()
    await installCurrent.value
    await pipeline.waitUntilIdle()

    let loadedThumbnailPublications = publications.filter {
      if case .thumbnail = $0 { return true }
      return false
    }
    XCTAssertEqual(loadedThumbnailPublications.count, 0)
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineInstallCannotStartNewCatalogDetailsFromOldWorkerCleanup() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsThumbnailBatchFinishUntilReleased = true
    source.suspendsDetailsRequestsUntilReleased = true
    let firstIdentity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let secondIdentity = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: firstIdentity.sessionEpoch,
      generation: 2
    )
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: firstIdentity,
      membership: [1],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1])
    await source.waitForThumbnailBatchFinishStartCount(1)

    let installTask = Task {
      await pipeline.install(
        catalogIdentity: secondIdentity,
        membership: [9],
        reusableObjectInfos: [:]
      )
    }
    for _ in 0..<20 { await Task.yield() }
    source.releaseThumbnailBatchFinishes()
    await installTask.value
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(
      source.requestedDetailsHandles,
      [],
      "Cleanup from the old thumbnail worker must not start Details against the newly installed catalog"
    )
    source.releaseDetailsRequests()
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelinePreservesSameSessionHandleCacheAcrossFilterChange() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let firstIdentity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let secondIdentity = CameraGalleryCatalogIdentity.fixture(
      sessionEpoch: firstIdentity.sessionEpoch,
      generation: 2
    )
    var publishedIdentities: [CameraGalleryMediaIdentity] = []
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { publication in
      if case .thumbnail(let identity, _) = publication {
        publishedIdentities.append(identity)
      }
    }

    await pipeline.install(
      catalogIdentity: firstIdentity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()
    await pipeline.install(
      catalogIdentity: secondIdentity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7])
    XCTAssertEqual(publishedIdentities.map(\.catalog), [firstIdentity, secondIdentity])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineClearsCacheWhenSessionEpochChanges() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let firstIdentity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let secondIdentity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: firstIdentity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()
    await pipeline.invalidateSession()
    await pipeline.install(
      catalogIdentity: secondIdentity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()

    XCTAssertNotEqual(firstIdentity.sessionEpoch, secondIdentity.sessionEpoch)
    XCTAssertEqual(source.requestedThumbnailHandles, [7, 7])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineSuspendPreservesLoadedAndRetryState() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailFailuresRemaining[8] = 1
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7, 8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7, 8])
    await pipeline.waitUntilIdle()
    await pipeline.suspendForExternalWork()
    await pipeline.resumeExternalWork()
    await pipeline.requestVisible(handles: [7, 8])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7, 8, 8])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineResumeReplaysCancelledVisibleWindowWithoutNewUIRequest() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsChildRequests = true
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7, 8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7, 8])
    await source.waitForThumbnailRequestCount(1)

    await pipeline.suspendForExternalWork()
    source.suspendsChildRequests = false
    await pipeline.resumeExternalWork()
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7, 7, 8])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineOlderViewportCannotReplaceNewerViewportAfterDetailsJoin() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsDetailsRequestsUntilReleased = true
    source.delaysDetailsCancellationUntilReleased = true
    let detailsCancelled = expectation(description: "older viewport waits for details cancellation")
    detailsCancelled.assertForOverFulfill = false
    source.onDetailsRequestCancelled = {
      detailsCancelled.fulfill()
    }
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [1, 2, 3],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1])
    await source.waitForDetailsRequestCount(1)

    let olderViewport = Task {
      await pipeline.requestVisible(handles: [2])
    }
    await fulfillment(of: [detailsCancelled], timeout: 1)

    let newerViewport = Task {
      await pipeline.requestVisible(handles: [3])
    }
    await source.waitForThumbnailRequestCount(2)
    source.releaseDetailsRequests()
    await olderViewport.value
    await newerViewport.value
    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(
      source.requestedThumbnailHandles,
      [1, 3],
      "An older actor invocation must not restart its stale viewport after a newer request has entered"
    )
    let cleanup = Task {
      await pipeline.cancelAndJoin()
    }
    source.releaseDetailsRequests()
    await cleanup.value
  }

  @MainActor
  func testThumbnailPipelineReprioritizesWithoutJoiningTheInFlightViewportBatch() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsThumbnailResultsUntilReleased = true
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [1, 2, 3, 9, 8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1, 2, 3])
    await source.waitForThumbnailRequestCount(1)

    let reprioritized = expectation(description: "latest viewport accepted without joining the in-flight PTP request")
    Task {
      await pipeline.requestVisible(handles: [9, 8])
      reprioritized.fulfill()
    }

    await fulfillment(of: [reprioritized], timeout: 0.2)
    source.suspendsThumbnailResultsUntilReleased = false
    source.releaseThumbnailResults()
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [1, 9, 8])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineDoesNotRestartBatchForIdenticalOrderedViewport() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsThumbnailResultsUntilReleased = true
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [1, 2, 3],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1, 2, 3], submissionID: 1)
    await source.waitForThumbnailRequestCount(1)
    await pipeline.requestVisible(handles: [1, 2, 3], submissionID: 2)
    source.releaseThumbnailResults()
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [1, 2, 3])
    XCTAssertEqual(source.begunThumbnailBatchHandles, [[1, 2, 3]])
    XCTAssertEqual(source.finishedThumbnailBatchHandles, [[1, 2, 3]])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineStopsStaleCacheReplayWhenANewerViewportArrives() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var publishedHandles: [Int] = []
    var shouldSuspendFirstCachedPublication = false
    var suspendedPublication: CheckedContinuation<Void, Never>?
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { publication in
      guard case .thumbnail(let mediaIdentity, _) = publication else { return }
      publishedHandles.append(mediaIdentity.handle)
      if shouldSuspendFirstCachedPublication,
         mediaIdentity.handle == 1,
         suspendedPublication == nil {
        await withCheckedContinuation { continuation in
          suspendedPublication = continuation
        }
      }
    }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [1, 2, 3],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1, 2, 3], submissionID: 1)
    await pipeline.waitUntilIdle()

    publishedHandles = []
    shouldSuspendFirstCachedPublication = true
    let staleViewport = Task {
      await pipeline.requestVisible(handles: [1, 2, 3], submissionID: 2)
    }
    for _ in 0..<100 where suspendedPublication == nil {
      await Task.yield()
    }
    XCTAssertNotNil(suspendedPublication)

    let latestViewport = Task {
      await pipeline.requestVisible(handles: [3], submissionID: 3)
    }
    await latestViewport.value
    suspendedPublication?.resume()
    suspendedPublication = nil
    await staleViewport.value

    XCTAssertEqual(
      publishedHandles,
      [1, 3],
      "The stale viewport may finish its in-flight publication, but must not replay the rest of its cache batch"
    )
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineMetadataWithoutExactObjectInfoStillLoadsDetails() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.returnsResolvedDetails = true
    source.thumbnailResolvedMetadataByHandle[7] = CameraGalleryResolvedItemMetadata(
      handle: 7,
      filename: "DSCF0007.JPG",
      formatLabel: "JPG",
      captureDate: "",
      byteSizeText: "",
      compressedSize: nil,
      orientation: nil,
      formatHints: []
    )
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(
      source.requestedDetailsHandles,
      [7],
      "Metadata labels without exact ObjectInfo must not suppress the authoritative Details request"
    )
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineDetailsResumeFromFirstIncompleteHandleAfterViewportInterruption() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.returnsResolvedDetails = true
    source.detailsHandlesToSuspend = [2]
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { _ in }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [1, 2, 3],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [1])
    await source.waitForDetailsRequestCount(2)

    await pipeline.requestVisible(handles: [3])
    await source.waitForDetailsRequestCount(3)

    XCTAssertEqual(
      Array(source.requestedDetailsHandles.prefix(3)),
      [1, 2, 2],
      "Completed Details handles must not be republished from the catalog head after viewport cancellation"
    )
    source.detailsHandlesToSuspend = []
    source.releaseDetailsRequests()
    await pipeline.waitUntilIdle()
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelinePublishesTerminalFailureAfterBoundedRetries() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailFailuresRemaining[8] = 4
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var states: [CameraGalleryThumbnailState] = []
    let pipeline = CameraGalleryThumbnailPipeline(
      source: source,
      retryDelaysNanoseconds: [0, 0]
    ) { publication in
      if case .thumbnailState(_, let state) = publication {
        states.append(state)
      }
    }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [8])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [8, 8, 8])
    XCTAssertFalse(states.contains(.loading))
    XCTAssertEqual(states.last, .failed)
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineRetriesTerminalFailureOnNextExplicitViewportSubmission() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailFailuresRemaining[8] = 3
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var loadedHandles: [Int] = []
    let pipeline = CameraGalleryThumbnailPipeline(
      source: source,
      retryDelaysNanoseconds: [0, 0]
    ) { publication in
      if case .thumbnail(let mediaIdentity, _) = publication {
        loadedHandles.append(mediaIdentity.handle)
      }
    }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [8], submissionID: 1)
    await pipeline.waitUntilIdle()
    await pipeline.requestVisible(handles: [8], submissionID: 2)
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [8, 8, 8, 8])
    XCTAssertEqual(loadedHandles, [8])
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailPipelineDoesNotPublishLoadingStateForPlaceholderCells() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var states: [CameraGalleryThumbnailState] = []
    var loadedHandles: [Int] = []
    let pipeline = CameraGalleryThumbnailPipeline(source: source) { publication in
      switch publication {
      case .thumbnail(let identity, _):
        loadedHandles.append(identity.handle)
      case .thumbnailState(_, let state):
        states.append(state)
      case .details:
        break
      }
    }

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(loadedHandles, [7])
    XCTAssertFalse(states.contains(.loading))
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testGalleryCatalogTransportFailurePersistsAnErrorInsteadOfLookingEmpty() async throws {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.catalogError = NSError(
      domain: "RunnerTests",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: "socket 未建立"]
    )
    let failed = expectation(description: "failed presentation published")
    var lastPresentation = CameraGalleryPresentation.unavailable
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if case .failed = presentation.state {
          failed.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [failed], timeout: 2)

    XCTAssertEqual(lastPresentation.items, [])
    XCTAssertEqual(lastPresentation.errorMessage, "socket 未建立")
    guard case .failed = lastPresentation.state else {
      return XCTFail("Transport failure must remain a failed presentation, not an empty ready catalog")
    }
  }

  @MainActor
  func testCatalogRuntimeDoesNotPublishLoadingWhenSwitchingBackToCachedFormatMembership() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    var presentations: [CameraGalleryPresentation] = []
    var isRecordingCachedSwitch = false
    let initialReady = expectation(description: "initial catalog ready")
    let jpgReady = expectation(description: "jpg catalog ready")
    let allReady = expectation(description: "all catalog restored from cache")
    let cachedJPGReady = expectation(description: "jpg catalog restored from cache")
    var readyStage = 0
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        if isRecordingCachedSwitch {
          presentations.append(presentation)
        }
        guard case .ready = presentation.state else { return }
        switch readyStage {
        case 0 where presentation.intent.format == .all:
          readyStage = 1
          initialReady.fulfill()
        case 1 where presentation.intent.format == .jpg:
          readyStage = 2
          jpgReady.fulfill()
        case 2 where presentation.intent.format == .all:
          readyStage = 3
          allReady.fulfill()
        case 3 where presentation.intent.format == .jpg:
          readyStage = 4
          cachedJPGReady.fulfill()
        default:
          break
        }
      },
      reportTransportEvidence: { _ in }
    )
    let jpg = CameraGalleryFilterIntent(
      date: .all,
      format: .jpg,
      sort: .newest,
      downloadStatus: .all
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    await runtime.submit(
      jpg,
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 1),
      downloadedHandles: []
    )
    await fulfillment(of: [jpgReady], timeout: 1)
    await runtime.submit(
      .all,
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 2),
      downloadedHandles: []
    )
    await fulfillment(of: [allReady], timeout: 1)

    presentations = []
    isRecordingCachedSwitch = true
    await runtime.submit(
      jpg,
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 3),
      downloadedHandles: []
    )
    await fulfillment(of: [cachedJPGReady], timeout: 1)

    XCTAssertFalse(presentations.contains(where: { $0.isLoading }))
    XCTAssertEqual(source.catalogIntents.map(\.format), [.jpg])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeCoalescesRapidIntentsToTheLatestPendingTransaction() async throws {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsCatalogRequests = true
    let initialReady = expectation(description: "initial catalog published")
    let ready = expectation(description: "latest catalog published")
    var lastPresentation = CameraGalleryPresentation.unavailable
    var didFulfillInitialReady = false
    var didFulfillReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if !didFulfillInitialReady,
           case .ready = presentation.state,
           presentation.intent.format == .all {
          didFulfillInitialReady = true
          initialReady.fulfill()
        }
        guard !didFulfillReady,
              case .ready = presentation.state,
              presentation.intent.format == .raw else { return }
        didFulfillReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .jpg,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    await source.waitForCatalogRequestCount(1)
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .raw,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 2), downloadedHandles: [])
    source.resolveCatalogRequest(
      at: 0,
      snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [1])
    )
    await source.waitForCatalogRequestCount(2)
    source.resolveCatalogRequest(
      at: 1,
      snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [9, 8])
    )
    await fulfillment(of: [ready], timeout: 2)

    XCTAssertEqual(source.catalogIntents.map(\.format), [.jpg, .raw])
    XCTAssertEqual(lastPresentation.items.map(\.handle), [9, 8])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRejectsAnOlderSubmissionThatArrivesAfterTheLatestIntent() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsCatalogRequests = true
    let initialReady = expectation(description: "initial catalog ready")
    let latestReady = expectation(description: "latest stamped catalog published")
    var lastPresentation = CameraGalleryPresentation.unavailable
    var didObserveInitialReady = false
    var didObserveLatestReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if !didObserveInitialReady,
           case .ready = presentation.state,
           presentation.intent.format == .all {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        if !didObserveLatestReady,
           case .ready = presentation.state,
           presentation.intent.format == .raw {
          didObserveLatestReady = true
          latestReady.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    source.suspendsCatalogRequests = false
    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    source.suspendsCatalogRequests = true

    await runtime.submit(
      CameraGalleryFilterIntent(
        date: .all,
        format: .raw,
        sort: .newest,
        downloadStatus: .all
      ),
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 2),
      downloadedHandles: []
    )
    await source.waitForCatalogRequestCount(1)

    await runtime.submit(
      CameraGalleryFilterIntent(
        date: .all,
        format: .jpg,
        sort: .newest,
        downloadStatus: .all
      ),
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 1),
      downloadedHandles: []
    )
    source.resolveCatalogRequest(
      at: 0,
      snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [9, 8])
    )

    await fulfillment(of: [latestReady], timeout: 1)
    XCTAssertEqual(source.catalogIntents.map(\.format), [.raw])
    XCTAssertEqual(lastPresentation.intent.format, .raw)
    XCTAssertEqual(lastPresentation.items.map(\.handle), [9, 8])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRejectsVisibleThumbnailsWhileMembershipTransitionJoinsOldDetails() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsDetailsRequestsUntilReleased = true
    let ready = expectation(description: "initial catalog ready")
    var didObserveReady = false
    let detailsCancelled = expectation(description: "old details task cancelled")
    detailsCancelled.assertForOverFulfill = false
    source.onDetailsRequestCancelled = {
      detailsCancelled.fulfill()
    }
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.requestVisibleThumbnails(handles: [3, 2])
    await source.waitForDetailsRequestCount(1)
    let thumbnailRequestsBeforeTransition = source.requestedThumbnailHandles

    let submitTask = Task {
      await runtime.submit(CameraGalleryFilterIntent(
        date: .all,
        format: .raw,
        sort: .newest,
        downloadStatus: .all
      ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    }
    await fulfillment(of: [detailsCancelled], timeout: 1)

    await runtime.requestVisibleThumbnails(handles: [3, 2])
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(
      source.requestedThumbnailHandles,
      thumbnailRequestsBeforeTransition,
      "The membership transition must reject additional visible-thumbnail work"
    )
    source.suspendsDetailsRequestsUntilReleased = false
    source.releaseDetailsRequests()
    await submitTask.value
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRejectsViewportFromAnotherCatalogIdentity() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let queryEngine = CameraCatalogQueryEngine(
      source: source,
      sessionEpoch: sessionEpoch
    )
    let ready = expectation(description: "catalog ready")
    var readyIdentity: CameraGalleryCatalogIdentity?
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      queryEngine: queryEngine,
      cameraID: "camera",
      publishPresentation: { presentation in
        guard case .ready(let generation, let snapshotID) = presentation.state else { return }
        readyIdentity = CameraGalleryCatalogIdentity(
          cameraID: "camera",
          sessionEpoch: sessionEpoch,
          generation: generation,
          snapshotID: snapshotID
        )
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    let currentIdentity = try! XCTUnwrap(readyIdentity)
    let staleIdentity = CameraGalleryCatalogIdentity(
      cameraID: currentIdentity.cameraID,
      sessionEpoch: currentIdentity.sessionEpoch,
      generation: CameraGalleryGenerationID(rawValue: currentIdentity.generation.rawValue &+ 1),
      snapshotID: currentIdentity.snapshotID
    )

    await runtime.requestVisibleThumbnails(
      handles: [3],
      submissionID: 1,
      expectedCatalogIdentity: staleIdentity
    )
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(source.requestedThumbnailHandles, [])

    await runtime.requestVisibleThumbnails(
      handles: [3],
      submissionID: 2,
      expectedCatalogIdentity: currentIdentity
    )
    await runtime.waitUntilIdle()
    XCTAssertEqual(source.requestedThumbnailHandles, [3])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeJoinsThumbnailBatchFinishBeforeStartingNextCatalogTransaction() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsChildRequests = true
    source.suspendsThumbnailBatchFinishUntilReleased = true
    let ready = expectation(description: "catalog ready before thumbnail batch")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.requestVisibleThumbnails(handles: [3, 2])
    await source.waitForThumbnailRequestCount(1)

    let submitTask = Task {
      await runtime.submit(
        CameraGalleryFilterIntent(
          date: .all,
          format: .raw,
          sort: .newest,
          downloadStatus: .all
        ),
        submissionID: CameraGalleryIntentSubmissionID(rawValue: 1),
        downloadedHandles: []
      )
    }
    await source.waitForThumbnailBatchFinishStartCount(1)

    XCTAssertEqual(
      source.catalogIntents.map(\.format),
      [],
      "The next catalog transaction must wait until the old thumbnail batch has fully finished"
    )

    source.releaseThumbnailBatchFinishes()
    await submitTask.value
    await source.waitForCatalogRequestCount(1)

    XCTAssertEqual(source.finishedThumbnailBatchHandles, [[3, 2]])
    XCTAssertEqual(source.catalogIntents.map(\.format), [.raw])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRejectsVisibleThumbnailsWhileNewCatalogIsLoading() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    var didObserveInitialReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveInitialReady, case .ready = presentation.state else { return }
        didObserveInitialReady = true
        initialReady.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    source.suspendsCatalogRequests = true
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .raw,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    await source.waitForCatalogRequestCount(1)

    await runtime.requestVisibleThumbnails(handles: [3, 2])
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(source.requestedThumbnailHandles, [])
    source.resolveCatalogRequest(
      at: 0,
      snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [9, 8])
    )
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeKeepsVisibleThumbnailsAvailableAfterLocalDateProjection() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    var didObserveInitialReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveInitialReady, case .ready = presentation.state else { return }
        didObserveInitialReady = true
        initialReady.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    let selectedDay = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2026, month: 7, day: 14)
    )!
    await runtime.submit(CameraGalleryFilterIntent(
      date: .specificDay(selectedDay),
      format: .all,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])

    await runtime.requestVisibleThumbnails(handles: [3, 2])
    await runtime.waitUntilIdle()

    XCTAssertEqual(source.initialCatalogRequestCount, 1)
    XCTAssertEqual(source.requestedThumbnailHandles, [3, 2])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeProjectsDateAndDownloadScopeWithoutAnotherCameraCatalog() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let locallyProjected = expectation(description: "date and download scope projected locally")
    var initialGeneration: CameraGalleryGenerationID?
    var lastPresentation = CameraGalleryPresentation.unavailable
    var didFulfillLocalProjection = false
    let selectedDay = Calendar(identifier: .gregorian).date(
      from: DateComponents(year: 2026, month: 7, day: 14)
    )!
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if initialGeneration == nil,
           case .ready(let generation, _) = presentation.state {
          initialGeneration = generation
          initialReady.fulfill()
        }
        if !didFulfillLocalProjection,
           presentation.intent.date == .specificDay(selectedDay),
           presentation.intent.downloadStatus == .notDownloaded,
           presentation.items.map(\.handle) == [3, 1] {
          didFulfillLocalProjection = true
          locallyProjected.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    await runtime.submit(
      CameraGalleryFilterIntent(
        date: .specificDay(selectedDay),
        format: .all,
        sort: .newest,
        downloadStatus: .notDownloaded
      ),
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 1),
      downloadedHandles: [2]
    )
    await fulfillment(of: [locallyProjected], timeout: 1)

    XCTAssertEqual(source.initialCatalogRequestCount, 1)
    XCTAssertEqual(source.catalogIntents, [])
    XCTAssertEqual(lastPresentation.generation, initialGeneration)
    XCTAssertEqual(lastPresentation.items.map(\.handle), [3, 1])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRejectsVisibleThumbnailsAfterCatalogFailure() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let failed = expectation(description: "catalog failed")
    var didObserveInitialReady = false
    var didObserveFailure = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        if !didObserveInitialReady, case .ready = presentation.state {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        if !didObserveFailure, case .failed = presentation.state {
          didObserveFailure = true
          failed.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    source.catalogError = NSError(
      domain: "RunnerTests",
      code: 19,
      userInfo: [NSLocalizedDescriptionKey: "catalog failed"]
    )
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .raw,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    await fulfillment(of: [failed], timeout: 1)

    await runtime.requestVisibleThumbnails(handles: [3, 2])
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(source.requestedThumbnailHandles, [])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeDoesNotRestartThumbnailWorkerForSameSnapshotSubsetRefresh() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsChildRequests = true
    let ready = expectation(description: "catalog ready before thumbnail request")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.requestVisibleThumbnails(handles: [3, 2])
    await source.waitForThumbnailRequestCount(1)

    await runtime.requestVisibleThumbnails(handles: [2])
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(source.requestedThumbnailHandles, [3])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeFirstViewportWinsOverInitialDetailsGrace() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let ready = expectation(description: "catalog ready")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.requestVisibleThumbnails(handles: [3])
    await source.waitForThumbnailRequestCount(1)

    XCTAssertEqual(source.requestedThumbnailHandles, [3])
    XCTAssertEqual(source.requestedDetailsHandles, [])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeDoesNotStartDetailsBeforeFirstVisibleWindow() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsDetailsRequestsUntilReleased = true
    let ready = expectation(description: "catalog ready before first visible window")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    try? await Task.sleep(nanoseconds: 100_000_000)

    XCTAssertEqual(
      source.requestedDetailsHandles,
      [],
      "Details must not occupy PTP before the UI has completed its first visible thumbnail window"
    )

    await runtime.requestVisibleThumbnails(handles: [3])
    await source.waitForDetailsRequestCount(1)
    XCTAssertEqual(source.requestedThumbnailHandles, [3])
    XCTAssertEqual(source.requestedDetailsHandles, [3])
    source.releaseDetailsRequests()
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeRunsDetailsAfterThumbnailBurstWithoutStarvation() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.initialSnapshotHandles = Array(stride(from: 10, through: 1, by: -1))
    source.suspendsDetailsRequestsUntilReleased = true
    let ready = expectation(description: "catalog ready")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.requestVisibleThumbnails(handles: source.initialSnapshotHandles)
    await source.waitForDetailsRequestCount(1)

    XCTAssertEqual(source.requestedThumbnailHandles, source.initialSnapshotHandles)
    XCTAssertEqual(source.requestedDetailsHandles, [10])
    source.releaseDetailsRequests()
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeHDPreviewSuspensionCancelsChildWorkAndRejectsNewThumbnailRequests() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsChildRequests = true
    let ready = expectation(description: "catalog ready before HD suspension")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.suspendChildWorkForHighDefinitionPreview()
    await runtime.requestVisibleThumbnails(handles: [1])

    XCTAssertEqual(source.requestedThumbnailHandles, [])
    let isSuspended = await runtime.isChildWorkSuspendedForHighDefinitionPreview()
    XCTAssertTrue(isSuspended)
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeHDPreviewResumeAcceptsThumbnailRequestsAgain() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.initialSnapshotHandles = [1]
    let ready = expectation(description: "catalog ready before HD resume")
    var didObserveReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard !didObserveReady, case .ready = presentation.state else { return }
        didObserveReady = true
        ready.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [ready], timeout: 1)
    await runtime.suspendChildWorkForHighDefinitionPreview()
    await runtime.resumeChildWorkAfterHighDefinitionPreview()
    await runtime.requestVisibleThumbnails(handles: [1])
    for _ in 0..<100 where source.requestedThumbnailHandles.isEmpty {
      await Task.yield()
    }

    XCTAssertEqual(source.requestedThumbnailHandles, [1])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeDownloadSuspensionSurvivesCatalogInstallation() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let filteredReady = expectation(description: "filtered catalog installed while download is pending")
    var didObserveInitialReady = false
    var didObserveFilteredReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        if !didObserveInitialReady,
           case .ready = presentation.state,
           presentation.intent.format == .all {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        if !didObserveFilteredReady,
           case .ready = presentation.state,
           presentation.intent.format == .raw {
          didObserveFilteredReady = true
          filteredReady.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    source.suspendsCatalogRequests = true
    await runtime.submit(
      CameraGalleryFilterIntent(
        date: .all,
        format: .raw,
        sort: .newest,
        downloadStatus: .all
      ),
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 1),
      downloadedHandles: []
    )
    await source.waitForCatalogRequestCount(1)
    await runtime.suspendChildWorkForDownload()
    source.resolveCatalogRequest(
      at: 0,
      snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [9])
    )
    await fulfillment(of: [filteredReady], timeout: 1)

    await runtime.requestVisibleThumbnails(handles: [9])
    for _ in 0..<100 {
      await Task.yield()
    }

    XCTAssertEqual(
      source.requestedThumbnailHandles,
      [],
      "Installing a catalog must not reopen child PTP work while download admission owns suspension"
    )
    await runtime.resumeChildWorkAfterDownload()
    for _ in 0..<100 where source.requestedThumbnailHandles.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(source.requestedThumbnailHandles, [9])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRepositoryRejectsUnknownOrStaleChildResults() {
    var repository = CameraGalleryRepository()
    let generation = CameraGalleryGenerationID(rawValue: 1)
    let snapshot = CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [3])
    repository.install(snapshot, generation: generation)
    let staleIdentity = CameraGalleryChildIdentity(
      generation: CameraGalleryGenerationID(rawValue: 2),
      snapshotID: snapshot.snapshotID,
      handle: 3
    )
    let unknownIdentity = CameraGalleryChildIdentity(
      generation: generation,
      snapshotID: snapshot.snapshotID,
      handle: 99
    )
    let thumbnail = CameraGalleryThumbnailResult(data: Data([1, 2, 3]), resolvedMetadata: nil)

    XCTAssertFalse(repository.applyThumbnail(thumbnail, identity: staleIdentity))
    XCTAssertFalse(repository.applyThumbnail(thumbnail, identity: unknownIdentity))
    XCTAssertNil(repository.items.first?.thumbnailData)
  }

  @MainActor
  func testCatalogRuntimeReprojectsReadyPresentationWhenDownloadedHandlesChange() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.suspendsChildRequests = true
    let initialReady = expectation(description: "initial catalog ready")
    let reprojected = expectation(description: "download status reprojected")
    var lastPresentation = CameraGalleryPresentation.unavailable
    var didObserveInitialReady = false
    var didFulfill = false
    var isWaitingForDownloadedProjection = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if !didObserveInitialReady, case .ready = presentation.state {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        guard isWaitingForDownloadedProjection,
              !didFulfill,
              presentation.items.map(\.handle) == [2, 1, 3] else { return }
        didFulfill = true
        reprojected.fulfill()
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .all,
      sort: .notDownloaded,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    for _ in 0..<20 {
      await Task.yield()
    }
    isWaitingForDownloadedProjection = true
    await runtime.updateDownloadedHandles([3])

    await fulfillment(of: [reprojected], timeout: 1)
    XCTAssertEqual(lastPresentation.items.map(\.handle), [2, 1, 3])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimePublishesDeferredDownloadProjectionWhenDownloadSuspensionEnds() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let reprojected = expectation(description: "deferred download projection published")
    var didObserveInitialReady = false
    var isWaitingForDeferredProjection = false
    var lastPresentation = CameraGalleryPresentation.unavailable
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        lastPresentation = presentation
        if !didObserveInitialReady, case .ready = presentation.state {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        if isWaitingForDeferredProjection,
           presentation.items.map(\.handle) == [2, 1] {
          isWaitingForDeferredProjection = false
          reprojected.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: CameraGalleryFilterIntent(
      date: .all,
      format: .all,
      sort: .newest,
      downloadStatus: .notDownloaded
    ))
    await fulfillment(of: [initialReady], timeout: 1)
    await runtime.suspendChildWorkForDownload()
    isWaitingForDeferredProjection = true
    await runtime.updateDownloadedHandles([3])

    XCTAssertEqual(lastPresentation.items.map(\.handle), [3, 2, 1])

    await runtime.resumeChildWorkAfterDownload()
    await fulfillment(of: [reprojected], timeout: 1)
    XCTAssertEqual(lastPresentation.items.map(\.handle), [2, 1])
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeCancelsStaleGenerationWithoutMetadataMembershipMutation() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let initialReady = expectation(description: "initial catalog ready")
    let rawReady = expectation(description: "new RAW generation published")
    var readyFormats: [CameraGalleryFormatIntent] = []
    var didObserveInitialReady = false
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        guard case .ready = presentation.state else { return }
        if !didObserveInitialReady, presentation.intent.format == .all {
          didObserveInitialReady = true
          initialReady.fulfill()
        }
        readyFormats.append(presentation.intent.format)
        if presentation.intent.format == .raw {
          rawReady.fulfill()
        }
      },
      reportTransportEvidence: { _ in }
    )

    await runtime.start(initial: .all)
    await fulfillment(of: [initialReady], timeout: 1)
    source.suspendsCatalogRequests = true
    await runtime.submit(CameraGalleryFilterIntent(
      date: .all,
      format: .jpg,
      sort: .newest,
      downloadStatus: .all
    ), submissionID: CameraGalleryIntentSubmissionID(rawValue: 1), downloadedHandles: [])
    await source.waitForCatalogRequestCount(1)
    await runtime.submit(
      CameraGalleryFilterIntent(
        date: .all,
        format: .raw,
        sort: .newest,
        downloadStatus: .all
      ),
      submissionID: CameraGalleryIntentSubmissionID(rawValue: 2),
      downloadedHandles: []
    )
    source.resolveCatalogRequest(at: 0, snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [30]))
    await source.waitForCatalogRequestCount(2)
    source.resolveCatalogRequest(at: 1, snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [9, 8]))
    await fulfillment(of: [rawReady], timeout: 1)

    XCTAssertEqual(readyFormats, [.all, .raw])
    XCTAssertEqual(source.catalogIntents.map(\.format), [.jpg, .raw])
    await runtime.cancelAllChildren()
  }

  func testProductionHasOneCatalogGenerationAuthority() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let controllerSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )
    let runtimeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraSessionRuntime.swift")
    )

    XCTAssertFalse(controllerSource.contains("completeGalleryCatalogGeneration"))
    XCTAssertFalse(controllerSource.contains("completeGalleryCatalogTask"))
    XCTAssertFalse(runtimeSource.contains("cameraCatalogRequestGeneration"))
  }

  func testGalleryControllerSubmitsCompleteIntentInsteadOfInstallingCatalog() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("submitGalleryIntent"))
    XCTAssertFalse(source.contains("runtime.requestCameraCatalog(query:"))
    XCTAssertFalse(source.contains("applyLoadedGalleryItems(snapshot.items"))
  }

  func testVendorBackgroundMetadataCannotDisconnectOrPublishUntypedGalleryNotifications() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("scheduleFullObjectInfoRefreshAfterInitialPlaceholders"))
    XCTAssertFalse(source.contains("nativeGalleryMetadataDidUpdate"))
    XCTAssertFalse(source.contains("nativeGalleryMetadataIndexDidComplete"))
  }

  func testInitialGalleryActivationCarriesOnlySessionReadinessNotParallelCatalogItems() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let loaderSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorGalleryMainlineSessionLoader.swift")
    )
    let bridgeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorConnectFlowBridge.swift")
    )
    let workerSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionConnectionWorker.swift")
    )
    let controllerSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeConnectViewController.swift")
    )

    XCTAssertFalse(loaderSource.contains("initialItems"))
    XCTAssertFalse(loaderSource.contains("loadGalleryItems("))
    XCTAssertFalse(bridgeSource.contains("initialItems"))
    XCTAssertFalse(workerSource.contains("initialItems"))
    XCTAssertFalse(controllerSource.contains("private let initialItems"))
  }

  func testSessionRuntimeExposesNoLegacyCatalogOrThumbnailOwnerAPI() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let runtimeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionRuntime.swift")
    )
    let transportSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionTransferExecutor.swift")
    )

    for forbidden in [
      "func requestThumbnailWithInfo(",
      "func requestThumbnail(",
      "func requestCompleteGalleryCatalog(",
      "func requestCameraFormatCatalogHandles(",
      "func announceVisibleThumbnailBatch(",
      "func completeVisibleThumbnailBatch(",
    ] {
      XCTAssertFalse(runtimeSource.contains(forbidden), "Legacy runtime API remains: \(forbidden)")
    }
    XCTAssertFalse(transportSource.contains("func fetchCompleteGallery("))
    XCTAssertFalse(transportSource.contains("func fetchCameraFormatCatalogHandles("))
  }

  func testCameraCoreGallerySourcesExposeNoCameraVendorResultTypes() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGallerySources.swift")
    let source = try String(contentsOf: sourceURL)

    for forbidden in [
      "CameraVendorCameraObjectInfo",
      "CameraVendorGalleryThumbnail",
      "CameraVendorGalleryPreview",
    ] {
      XCTAssertFalse(source.contains(forbidden), "CameraCore gallery source exposes vendor result: \(forbidden)")
    }
  }

  func testCameraCoreGalleryRuntimeExposesNoCameraVendorResultTypes() throws {
    let galleryDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery")
    let runtimeFiles = [
      "CameraGalleryCatalogRuntime.swift",
      "CameraGalleryThumbnailPipeline.swift",
      "CameraGalleryHDPreviewPipeline.swift",
      "CameraGallerySession.swift",
    ]

    for filename in runtimeFiles {
      let source = try String(contentsOf: galleryDirectory.appendingPathComponent(filename))
      for forbidden in [
        "CameraVendorCameraObjectInfo",
        "CameraVendorGalleryThumbnail",
        "CameraVendorGalleryPreview",
      ] {
        XCTAssertFalse(source.contains(forbidden), "\(filename) exposes vendor result: \(forbidden)")
      }
    }
  }

  func testCameraCoreCatalogContractsExposeNoVendorCatalogDTOs() throws {
    let galleryDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: galleryDirectory,
        includingPropertiesForKeys: nil
      )
    )
    let forbidden = [
      "CameraVendorGalleryItem",
      "CameraVendorSpecifiedObjectDateGroup",
      "CameraVendorGalleryFormatHint",
    ]

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
      let source = try String(contentsOf: fileURL)
      for typeName in forbidden {
        XCTAssertFalse(
          source.contains(typeName),
          "\(fileURL.lastPathComponent) exposes vendor catalog DTO: \(typeName)"
        )
      }
    }
  }

  func testGalleryControllerOwnsNoCatalogLifecycleTaskOrCameraRequestTask() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL)
    let galleryStart = try XCTUnwrap(source.range(of: "final class NativeGalleryViewController")?.lowerBound)
    let galleryEnd = try XCTUnwrap(
      source.range(of: "final class NativeDownloadListViewController", range: galleryStart..<source.endIndex)?.lowerBound
    )
    let gallerySource = String(source[galleryStart..<galleryEnd])

    for forbidden in [
      "catalogLifecycleTask",
      "visibleThumbnailRefreshTask",
      "requestPreviewImageWithInfo",
      "requestThumbnailWithInfo",
      "loadObjectInfo(handle:",
    ] {
      XCTAssertFalse(gallerySource.contains(forbidden), "Gallery controller owns camera work: \(forbidden)")
    }
  }

  func testGalleryControllerLeavesDownloadAdmissionToRuntimeAndPreservesSelectionOnRejection() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL)
    let start = try XCTUnwrap(
      source.range(of: "let startDownload = { [weak self] in")?.lowerBound
    )
    let end = try XCTUnwrap(
      source.range(
        of: "private func finishOpeningDownloadCenter",
        range: start..<source.endIndex
      )?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertFalse(body.contains("pauseGalleryHDPreviewForDownload"))
    XCTAssertFalse(source.contains("resumeGalleryHDPreviewAfterDownload"))
    let submissionGuard = try XCTUnwrap(
      body.range(of: "guard self.runtime.submitDownload(")?.lowerBound
    )
    let selectionClear = try XCTUnwrap(
      body.range(of: "self.selectedHandles = NativeGalleryPostDownloadSelectionPolicy")?.lowerBound
    )
    XCTAssertLessThan(submissionGuard, selectionClear)
  }

  func testHomeControllerOwnsNoCatalogObserverOrDownloadDisconnectPolicy() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL)

    for forbidden in [
      "observeIncrementalCatalogUpdates",
      "onDownloadThumbnailGenerated",
      "onMovedFromParent",
      "disconnectAfterDownload",
    ] {
      XCTAssertFalse(source.contains(forbidden), "Home controller owns gallery/download policy: \(forbidden)")
    }
  }

  func testDownloadControllerOwnsNoTransportTerminationCallback() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL)
    let downloadStart = try XCTUnwrap(
      source.range(of: "final class NativeDownloadListViewController")?.lowerBound
    )
    let downloadSource = String(source[downloadStart...])

    XCTAssertFalse(downloadSource.contains("onMovedFromParent"))
    XCTAssertFalse(downloadSource.contains("terminateCameraCommunication"))
    XCTAssertFalse(downloadSource.contains("exitGalleryAndDisconnect"))
  }

  func testCatalogRuntimeShutdownWaitsForActiveTransactionCleanupInsteadOfCancellingIt() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift")
    let source = try String(contentsOf: sourceURL)
    let start = try XCTUnwrap(source.range(of: "func cancelAllChildren() async")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "func markTransportLost", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertFalse(body.contains("activeTransactionTask?.cancel()"))
    XCTAssertTrue(body.contains("await activeTransactionTask?.value"))
  }

  func testCatalogRuntimeCancelsSupersededCameraTransactionButKeepsShutdownJoinOnly() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift")
    let source = try String(contentsOf: sourceURL)
    let submitStart = try XCTUnwrap(
      source.range(of: "private func submit(\n    _ intent: CameraGalleryFilterIntent")?.lowerBound
    )
    let submitEnd = try XCTUnwrap(
      source.range(of: "private func start(_ transaction: PendingTransaction)", range: submitStart..<source.endIndex)?.lowerBound
    )
    let submitBody = String(source[submitStart..<submitEnd])
    let shutdownStart = try XCTUnwrap(source.range(of: "func cancelAllChildren() async")?.lowerBound)
    let shutdownEnd = try XCTUnwrap(
      source.range(of: "func markTransportLost", range: shutdownStart..<source.endIndex)?.lowerBound
    )
    let shutdownBody = String(source[shutdownStart..<shutdownEnd])

    XCTAssertTrue(submitBody.contains("activeTransactionTask?.cancel()"))
    XCTAssertTrue(shutdownBody.contains("await activeTransactionTask?.value"))
    XCTAssertFalse(shutdownBody.contains("activeTransactionTask?.cancel()"))
  }

  func testHEIFCatalogRuntimeHasNoPrepublicationObjectInfoRefinement() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift")
    let source = try String(contentsOf: sourceURL)
    XCTAssertFalse(source.contains("private func refineHEIFCandidate("))
    XCTAssertFalse(source.contains("CameraVendorCatalogCandidateRefinementPolicy"))

    let vendorSourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let vendorSource = try String(contentsOf: vendorSourceURL)
    XCTAssertFalse(vendorSource.contains("CameraVendorFormatCatalogValidationPolicy"))
  }

  func testPtpFilePayloadReaderAggregatesOneBoundedPayloadBeforeWriting() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSocket.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func readExactlyToFile(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "func close()", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("var payload = Data(count: length)"))
    XCTAssertTrue(body.contains("fileHandle.write(contentsOf: payload)"))
    XCTAssertFalse(body.contains("Data(buffer.prefix(count))"))
  }

  func testCameraVendorCatalogSnapshotValidationRequiresCameraCountsAndUniqueHandles() {
    XCTAssertTrue(
      CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
        declaredCount: 3,
        dateGroups: [
          CameraVendorSpecifiedObjectDateGroup(dateText: "20260713", objectCount: 2),
          CameraVendorSpecifiedObjectDateGroup(dateText: "20260712", objectCount: 1),
        ],
        orderedHandles: [301, 299, 298]
      )
    )
    XCTAssertFalse(
      CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
        declaredCount: 3,
        dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260713", objectCount: 2)],
        orderedHandles: [301, 299, 298]
      )
    )
    XCTAssertFalse(
      CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
        declaredCount: 3,
        dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260713", objectCount: 3)],
        orderedHandles: [301, 299, 299]
      )
    )
  }

  func testSubtractBaselineValidationRequiresCompleteSupersetRelationship() {
    let baseline = CameraVendorSpecifiedObjectSnapshot(
      declaredCount: 2,
      dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260729", objectCount: 2)],
      handles: [1, 2]
    )
    let validFormat = CameraVendorSpecifiedObjectSnapshot(
      declaredCount: 3,
      dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260729", objectCount: 3)],
      handles: [1, 2, 3]
    )
    let ambiguousFormat = CameraVendorSpecifiedObjectSnapshot(
      declaredCount: 2,
      dateGroups: [CameraVendorSpecifiedObjectDateGroup(dateText: "20260729", objectCount: 2)],
      handles: [2, 3]
    )

    XCTAssertEqual(
      CameraVendorSubtractBaselineValidationPolicy.isolatedHandles(
        baseline: baseline,
        format: validFormat
      ),
      [3]
    )
    XCTAssertNil(
      CameraVendorSubtractBaselineValidationPolicy.isolatedHandles(
        baseline: baseline,
        format: ambiguousFormat
      ),
      "The format response cannot prove subtraction membership when it drops a baseline handle"
    )
  }

  @MainActor
  func testRuntimeCatalogSourceProvidesExpandedCatalogWithoutSendingExactHEIFQuery() async throws {
    let transport = CameraSessionRuntimeSpy()
    let source = CameraSessionGalleryCatalogRuntimeSource(transport: transport)

    _ = try await source.loadExpandedCatalog()

    XCTAssertEqual(transport.capturedCatalogQueries, [])
    XCTAssertEqual(transport.initialCatalogRequestCount, 1)
  }

  func testPriorityDownloadBatchFinishSkipsD226ResetAfterSocketLoss() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func finishPriorityDownloadBatchOnCommandLane()")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "private func prepareDownloadModeForPriorityBatch(", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("guard isConnected else"))
    XCTAssertTrue(body.contains("PTP_PRIORITY_DOWNLOAD_BATCH_RESET_SKIPPED_DISCONNECTED"))
  }

  func testRuntimeTransportFailureRetainsErrorDomainCodeAndMessage() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionRuntime.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "case .transportFailed(let error):")?.lowerBound)
    let end = try XCTUnwrap(
      source.range(of: "case .transferFinished", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("errorDomain="))
    XCTAssertTrue(body.contains("errorCode="))
    XCTAssertTrue(body.contains("error.localizedDescription"))
  }

  func testCatalogTransactionRestoresSearchModeBeforeEnrichmentOnly() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let vendorSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let runtimeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift"),
      encoding: .utf8
    )
    let vendorStart = try XCTUnwrap(vendorSource.range(of: "func cameraVendorCatalogSnapshot(")?.lowerBound)
    let vendorEnd = try XCTUnwrap(
      vendorSource.range(
        of: "private func primeCameraVendorCurrentImageContextIfNeeded(",
        range: vendorStart..<vendorSource.endIndex
      )?.lowerBound
    )
    let vendorBody = String(vendorSource[vendorStart..<vendorEnd])

    XCTAssertFalse(vendorBody.contains("objectInfo(handle:"))
    XCTAssertFalse(vendorBody.contains("CameraVendorCatalogCandidateRefinementPolicy.refinedSnapshot"))
    XCTAssertTrue(vendorBody.contains("restore: { savedSearchMode in"))
    XCTAssertFalse(runtimeSource.contains("private func refineHEIFCandidate("))
    XCTAssertFalse(runtimeSource.contains("CameraVendorCatalogCandidateRefinementPolicy.refinedSnapshot"))
  }

  func testCameraVendorInitialCatalogUsesCapturedUnfilteredWireSequence() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    XCTAssertTrue(source.contains("func cameraVendorInitialCatalogSnapshot("))
    guard let start = source.range(of: "func cameraVendorInitialCatalogSnapshot(")?.lowerBound,
          let end = source.range(of: "func cameraVendorCatalogSnapshot(", range: start..<source.endIndex)?.lowerBound else {
      return
    }
    let body = String(source[start..<end])
    let baseline = try XCTUnwrap(body.range(of: "stage: \"initial-camera-catalog-baseline\""))
    let expanded = try XCTUnwrap(body.range(of: "stage: \"initial-camera-catalog\""))
    XCTAssertFalse(body.contains("requestCameraVendorSearchModeAll("))
    XCTAssertTrue(body.contains("cameraVendorSetSearchModeAll"))
    XCTAssertLessThan(baseline.lowerBound, expanded.lowerBound)
  }

  @MainActor
  func testRuntimeCatalogSourceInitialLoadDoesNotUseFilteredQueryTransport() async throws {
    let transport = CameraSessionRuntimeSpy()
    let source = CameraSessionGalleryCatalogRuntimeSource(transport: transport)

    _ = try await source.loadExpandedCatalog()

    XCTAssertEqual(transport.requestedCatalogLabels, [])
    XCTAssertEqual(transport.initialCatalogRequestCount, 1)
  }

  @MainActor
  func testRuntimeCatalogSourceAllFormatsTodayUsesExpandedInitialCatalog() async throws {
    let transport = CameraSessionRuntimeSpy()
    let source = CameraSessionGalleryCatalogRuntimeSource(transport: transport)
    let engine = CameraCatalogQueryEngine(source: source)

    _ = try await engine.resolve(
      rule: CameraMediaFilterRule(formats: .all, date: .today, downloadScope: .all),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(transport.initialCatalogRequestCount, 1)
    XCTAssertEqual(transport.requestedCatalogLabels.count, 0)
  }

  @MainActor
  func testRuntimeCatalogSourceAllFormatsSpecificDayUsesExpandedInitialCatalog() async throws {
    let transport = CameraSessionRuntimeSpy()
    let source = CameraSessionGalleryCatalogRuntimeSource(transport: transport)
    let engine = CameraCatalogQueryEngine(source: source)

    _ = try await engine.resolve(
      rule: CameraMediaFilterRule(
        formats: .all,
        date: .specificDay(Date(timeIntervalSince1970: 1_800_000_000)),
        downloadScope: .all
      ),
      owner: .gallery(UUID()),
      downloadedHandles: []
    )

    XCTAssertEqual(transport.initialCatalogRequestCount, 1)
    XCTAssertEqual(transport.requestedCatalogLabels.count, 0)
  }

  func testTransferModeCoordinatorResetPreviewResetOriginalOrder() {
    var coordinator = CameraVendorTransferModeCoordinator()

    XCTAssertEqual(
      coordinator.actionsForReset(),
      [.setProperty(CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 0,
        width: .uint16
      ))]
    )
    coordinator.recordResetSucceeded()
    XCTAssertEqual(coordinator.currentPurpose, .reset)

    XCTAssertEqual(
      coordinator.actionsForPreparing(.screenPreview),
      [.setProperty(CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 1,
        width: .uint16
      ))]
    )
    coordinator.recordPreparationSucceeded(.screenPreview)
    XCTAssertEqual(coordinator.currentPurpose, .screenPreview)

    XCTAssertEqual(
      coordinator.actionsForReset(),
      [.setProperty(CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 0,
        width: .uint16
      ))]
    )
    coordinator.recordResetSucceeded()

    XCTAssertEqual(
      coordinator.actionsForPreparing(.originalDownload),
      [.setProperty(CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 2,
        width: .uint16
      ))]
    )
  }

  func testTransferModeCoordinatorCompressedToOriginalResetsBeforeD2262() {
    var coordinator = CameraVendorTransferModeCoordinator(currentPurpose: .reset)
    XCTAssertEqual(
      coordinator.actionsForPreparing(.compressedDownload),
      [
        .setProperty(CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.objectCompressionSetting,
          value: 1,
          width: .uint16
        )),
        .setProperty(CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 1,
          width: .uint16
        )),
      ]
    )
    coordinator.recordPreparationSucceeded(.compressedDownload)

    XCTAssertEqual(
      coordinator.actionsForPreparing(.originalDownload),
      [
        .setProperty(CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 0,
          width: .uint16
        )),
        .setProperty(CameraVendorDownloadModeProperty(
          code: CameraVendorDevicePropCode.imageForceCompression,
          value: 2,
          width: .uint16
        )),
      ]
    )
  }

  func testTransferModeCoordinatorFailuresMakePhysicalStateUnknown() {
    var coordinator = CameraVendorTransferModeCoordinator(currentPurpose: .reset)
    coordinator.recordPreparationFailed()
    XCTAssertEqual(coordinator.currentPurpose, .unknown)

    coordinator.recordPreparationSucceeded(.originalDownload)
    coordinator.recordResetFailed()
    XCTAssertEqual(coordinator.currentPurpose, .unknown)
    XCTAssertEqual(
      coordinator.actionsForPreparing(.screenPreview).first,
      .setProperty(CameraVendorDownloadModeProperty(
        code: CameraVendorDevicePropCode.imageForceCompression,
        value: 0,
        width: .uint16
      ))
    )
  }

  func testPtpSessionRoutesPreviewAndDownloadsThroughSingleTransferModeCoordinator() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraVendorPtpSession.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("private var transferModeCoordinator = CameraVendorTransferModeCoordinator()"))
    let previewStart = try XCTUnwrap(source.range(of: "func previewImageWithInfo(handle: UInt32)")?.lowerBound)
    let previewEnd = try XCTUnwrap(
      source.range(of: "private func readObjectSample", range: previewStart..<source.endIndex)?.lowerBound
    )
    let previewBody = String(source[previewStart..<previewEnd])
    XCTAssertTrue(previewBody.contains("prepareTransferMode("))
    XCTAssertTrue(previewBody.contains(".screenPreview"))
    XCTAssertTrue(source.contains("physicalPurpose(for: downloadMode)"))
    XCTAssertTrue(source.contains("resetTransferMode(reason:"))
    XCTAssertFalse(source.contains("originalDownloadD226Lifetime"))
    XCTAssertFalse(source.contains("originalDownloadBatchModeState"))
    XCTAssertFalse(source.contains("PTP_PRIORITY_DOWNLOAD_BATCH_D226_RESET_SUPPRESSED"))

    let uiAndRuntimeFiles = [
      "NativeGalleryViewController.swift",
      "NativePhotoPreviewViewController.swift",
      "NativeGalleryHDFullScreenViewController.swift",
      "CameraSessionRuntime.swift",
    ]
    for filename in uiAndRuntimeFiles {
      let body = try String(
        contentsOf: runnerDirectory.appendingPathComponent(filename),
        encoding: .utf8
      )
      XCTAssertFalse(body.contains("imageForceCompression"), "\(filename) must not write D226")
      XCTAssertFalse(body.contains("0xD226"), "\(filename) must not write D226")
    }
  }

  func testTransferModeCoordinatorLogsGenerationAtTheExistingBatchOwner() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraVendorPtpSession.swift"),
      encoding: .utf8
    )
    let serviceSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(source.contains("func beginPriorityDownloadBatch(generation: UInt64)"))
    XCTAssertTrue(serviceSource.contains("session.beginPriorityDownloadBatch(") )
    XCTAssertTrue(serviceSource.contains("generation: self.currentCommunicationGeneration()"))

    let start = try XCTUnwrap(
      source.range(of: "func beginPriorityDownloadBatch(generation: UInt64)")?.lowerBound
    )
    let end = try XCTUnwrap(
      source.range(of: "func finishPriorityDownloadBatchOnCommandLane()", range: start..<source.endIndex)?.lowerBound
    )
    let body = String(source[start..<end])
    XCTAssertTrue(body.contains("transferPurpose="))
    XCTAssertTrue(body.contains("session="))
    XCTAssertTrue(body.contains(#"generation=\(generation)"#))
  }

  func testOriginalDownloadFileUsesSharedTransferModeCoordinatorInsteadOfPerFileReset() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "func objectFile(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "private func withSerializedCommand", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("prepareDownloadModeForPriorityBatch("))
    XCTAssertFalse(body.contains("download-file-reset"))
  }

  func testGalleryFormatSelectionRequestsTheRuntimeCameraCatalog() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let gallerySource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("Runner/NativeGalleryViewController.swift")
    )

    let chipStart = try XCTUnwrap(gallerySource.range(of: "@objc private func chipFilterChanged()")?.lowerBound)
    let chipEnd = try XCTUnwrap(
      gallerySource.range(of: "private func submitGalleryIntent()", range: chipStart..<gallerySource.endIndex)?.lowerBound
    )
    let chipBody = String(gallerySource[chipStart..<chipEnd])
    XCTAssertTrue(chipBody.contains("filterState.formats = CameraMediaFormatSelection.normalized(selectedFormats)"))
    XCTAssertTrue(chipBody.contains("submitGalleryIntent()"))
  }

  func testGalleryMetadataMergeRestrictsDetailsToCurrentCatalogMembership() {
    let catalog = [
      CameraVendorGalleryItem(handle: 1, filename: "0x00000001", formatLabel: "", captureDate: "20260713", byteSizeText: ""),
      CameraVendorGalleryItem(handle: 2, filename: "0x00000002", formatLabel: "", captureDate: "20260713", byteSizeText: ""),
    ]
    let resolved = [
      CameraVendorGalleryItem(handle: 2, filename: "DSCF0002.HEIC", formatLabel: "HEIF", captureDate: "2026:07:13 10:00:00", byteSizeText: "6 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "DSCF0003.RAF", formatLabel: "RAW", captureDate: "2026:07:13 10:01:00", byteSizeText: "42 MB"),
    ]

    let merged = NativeGalleryMetadataMergePolicy.mergedItemsRestrictingMembership(
      existingItems: catalog,
      resolvedItems: resolved
    )

    XCTAssertEqual(merged.map(\.handle), [1, 2])
    XCTAssertEqual(merged[1].formatLabel, "HEIF")
  }

  func testGalleryFormatProjectionPublishesCameraCatalogBeforeObjectInfoCompletes() {
    let items = [
      CameraVendorGalleryItem(handle: 1, filename: "A.JPG", formatLabel: "JPG", captureDate: "20260713", byteSizeText: "4 MB"),
      CameraVendorGalleryItem(handle: 2, filename: "B.HEIC", formatLabel: "HEIF", captureDate: "20260713", byteSizeText: "6 MB"),
      CameraVendorGalleryItem(handle: 3, filename: "C.RAF", formatLabel: "RAW", captureDate: "20260713", byteSizeText: "42 MB"),
    ]

    XCTAssertEqual(
      NativeGalleryCameraCatalogProjection.items(
        items,
        sort: .newest,
        downloadedHandles: []
      ).map(\.handle),
      [1, 2, 3]
    )
  }

  func testGalleryControllerHasNoObjectInfoCompletionMembershipGate() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("isCurrentCatalogObjectInfoIndexComplete"))
    XCTAssertFalse(source.contains("applyCurrentFilters"))
  }

  func testCameraCatalogTransactionDoesNotSwallowSearchModeRestoreFailure() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "private func cameraVendorSubtractBaselineCatalogSnapshot(")?.lowerBound
    )
    let end = try XCTUnwrap(
      source.range(
        of: "private func cameraVendorCountSweepCatalogSnapshot(",
        range: start..<source.endIndex
      )?.lowerBound
    )
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("CameraVendorCatalogTransactionExecutor.execute"))
    XCTAssertTrue(body.contains("try restoreCameraVendorSearchModeAll("))
    XCTAssertFalse(body.contains("try? restoreCameraVendorSearchModeAll("))
  }

  func testCameraCatalogTransactionBacksUpPerformsAndRestoresInOrder() throws {
    var events: [String] = []

    let result: Int = try CameraVendorCatalogTransactionExecutor.execute(
      backup: {
        events.append("backup")
        return Data([0x01])
      },
      perform: {
        events.append("write")
        events.append("read")
        events.append("validate")
        return 42
      },
      restore: { saved in
        XCTAssertEqual(saved, Data([0x01]))
        events.append("restore")
      }
    )

    XCTAssertEqual(result, 42)
    XCTAssertEqual(events, ["backup", "write", "read", "validate", "restore"])
  }

  func testCameraCatalogTransactionPreservesPrimaryAndRestorationFailures() {
    let primary = NSError(
      domain: "RunnerTests.Primary",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "catalog read failed"]
    )
    let restoration = NSError(
      domain: "RunnerTests.Restore",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "search mode restore failed"]
    )

    XCTAssertThrowsError(
      try CameraVendorCatalogTransactionExecutor.execute(
        backup: { Data([0x02]) },
        perform: { () -> Int in throw primary },
        restore: { _ in throw restoration }
      )
    ) { error in
      guard let failure = error as? CameraGalleryCatalogTransactionFailure else {
        return XCTFail("Expected typed catalog transaction failure, got \(error)")
      }
      XCTAssertEqual(failure.primaryMessage, "catalog read failed")
      XCTAssertEqual(failure.restorationMessage, "search mode restore failed")
      XCTAssertTrue(failure.provesTransportLost)
    }
  }

  func testCameraCatalogTransactionRejectsSuccessfulSnapshotWhenRestorationFails() {
    let restoration = NSError(
      domain: "RunnerTests.Restore",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "restore unavailable"]
    )

    XCTAssertThrowsError(
      try CameraVendorCatalogTransactionExecutor.execute(
        backup: { Data([0x03]) },
        perform: { 7 },
        restore: { _ in throw restoration }
      )
    ) { error in
      guard let failure = error as? CameraGalleryCatalogTransactionFailure else {
        return XCTFail("Expected typed catalog transaction failure, got \(error)")
      }
      XCTAssertEqual(failure.primaryMessage, "目录读取已完成，但 SearchMode 恢复失败")
      XCTAssertEqual(failure.restorationMessage, "restore unavailable")
      XCTAssertTrue(failure.provesTransportLost)
    }
  }

  func testCameraVendorStartupTimingSummaryIncludesAllPacketPhases() {
    let timing = CameraVendorDataCommandTiming(
      requestToFirstByteMs: 2,
      dataCompleteMs: 3,
      responseCompleteMs: 4,
      totalMs: 4
    )

    for operationCode: UInt16 in [0x9054, 0x9055, 0xD22B] {
      let message = CameraVendorDataCommandTimingLogPolicy.completedMessage(
        operationCode: operationCode,
        handle: 0x10000001,
        byteCount: 128,
        timing: timing
      )
      XCTAssertTrue(message.contains("PTP_GALLERY_BOOTSTRAP_COMMAND_TIMING"))
      XCTAssertTrue(message.contains("op=0x\(String(format: "%04X", operationCode))"))
      XCTAssertTrue(message.contains("handle=0x10000001"))
      XCTAssertTrue(message.contains("bytes=128"))
      XCTAssertTrue(message.contains("requestToFirstByteMs=2"))
      XCTAssertTrue(message.contains("dataCompleteMs=3"))
      XCTAssertTrue(message.contains("responseCompleteMs=4"))
      XCTAssertTrue(message.contains("totalMs=4"))
    }
  }

  func testFileDownloadTimingIncludesNetworkAndWriteStages() throws {
    let source = try runnerSource("CameraVendorPtpSession.swift")
    let start = try XCTUnwrap(source.range(of: "private func readObjectByPartialObjectsToFile(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "private func persistOriginalTransferCapability", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("requestToFirstByteMs"))
    XCTAssertTrue(body.contains("socketReceiveMs"))
    XCTAssertTrue(body.contains("fileWriteMs"))
    XCTAssertTrue(body.contains("speedMBps"))
  }

  func testMtpGetObjectPropListParametersMatchNativeSDKLayout() {
    XCTAssertEqual(
      CameraVendorPtpPacketBuilder.mtpObjectPropListParameters(
        objectHandle: UInt32(bitPattern: -1),
        propertyCode: CameraVendorDevicePropCode.currentObjectHandle
      ),
      [
        UInt32(bitPattern: -1),
        0,
        CameraVendorDevicePropCode.currentObjectHandle,
        0,
        0,
      ]
    )
  }

  func testReferenceAppFunctionVersionPolicyUsesPcapObservedRemotePhotoViewExVersion() {
    XCTAssertEqual(
      CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: Data([0x01, 0x00, 0x00, 0x00])),
      3
    )
    XCTAssertEqual(CameraVendorReferenceAppFunctionVersionPolicy.versionToWrite(from: Data()), 3)
  }

  func testReferenceAppRemoteImageViewerPolicyMatchesFudgeAndReferenceAppClientStates() {
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.cameraStateRemoteAccess, 6)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteModeClientState, 5)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.referenceAppRemoteImageViewerClientState, 20)
    XCTAssertEqual(CameraVendorReferenceAppRemoteImageViewerPolicy.remoteGetObjectVersionToWrite, 5)
  }

  func testReferenceAppReservedReceiveProbePolicyMatchesReferenceAppModeTwentyOne() {
    XCTAssertFalse(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldProbeDuringGalleryHandshake)
    XCTAssertTrue(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldUseSeparatePtpSession)
    XCTAssertFalse(CameraVendorReferenceAppReservedReceiveProbePolicy.shouldExposeManualDiagnosticEntry)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveClientState, 21)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedReceiveVersionToWrite, 3)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.reservedObjectHandle, 1)
    XCTAssertEqual(CameraVendorReferenceAppReservedReceiveProbePolicy.sampleReadBytes, CameraVendorPartialObjectRequestPolicy.referenceAppInitialReadSize)
  }

  func testReservedReceiveDiagnosticResultSummarizesObjectInfoAndSampleBytes() {
    let objectInfo = CameraVendorCameraObjectInfo(
      handle: 1,
      storageID: 0x00010001,
      formatCode: 0x3812,
      compressedSize: 12_345_678,
      thumbCompressedSize: 0,
      filename: "DSCF0001.HEIF",
      captureDate: "2026:05:03 11:42:00"
    )
    let result = CameraVendorReservedReceiveDiagnosticResult(
      objectInfo: objectInfo,
      sampleByteCount: 16_384
    )

    XCTAssertTrue(result.summary.contains("DSCF0001.HEIF"))
    XCTAssertTrue(result.summary.contains("HEIF"))
    XCTAssertTrue(result.summary.contains("12.3 MB"))
    XCTAssertTrue(result.summary.contains("sample=16,384 bytes"))
  }

  func testCameraVendorRemoteImageViewerDevicePropCodesMatchOpenImplementations() {
    XCTAssertEqual(CameraVendorDevicePropCode.imageGetVersion, 0xDF21)
    XCTAssertEqual(CameraVendorDevicePropCode.getObjectVersion, 0xDF22)
    XCTAssertEqual(CameraVendorDevicePropCode.remoteGetObjectVersion, 0xDF25)
    XCTAssertEqual(CameraVendorDevicePropCode.referenceAppReservedReceive, 0xDF29)
  }

  func testPtpResponsePolicyRejectsOperationNotSupported() {
    XCTAssertThrowsError(
      try CameraVendorPtpResponsePolicy.validateOK(responseCode: 0x2005, operationName: "GetStorageIDs")
    ) { error in
      XCTAssertTrue(error.localizedDescription.contains("0x2005"))
      XCTAssertTrue(error.localizedDescription.contains("GetStorageIDs"))
    }
  }

  func testBackgroundKeepAliveUsesReferenceAppD212InsteadOfStorageIDs() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorPtpSession.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let keepAliveStart = try XCTUnwrap(source.range(of: "func keepAlive(readTimeout: TimeInterval = 3) throws")?.lowerBound)
    let nextMethodStart = try XCTUnwrap(source.range(of: "private func sendCommand(operationCode:", range: keepAliveStart..<source.endIndex)?.lowerBound)
    let keepAliveBody = String(source[keepAliveStart..<nextMethodStart])

    XCTAssertTrue(keepAliveBody.contains("referenceAppGalleryObjectContext"))
    XCTAssertFalse(keepAliveBody.contains("getStorageIDs"))
  }

  func testPtpReconnectErrorPolicyDoesNotRetryGalleryNotReadyMarker() {
    let notReadyError = NSError(
      domain: "CameraVendorPtpSession",
      code: 0xD222,
      userInfo: [NSLocalizedDescriptionKey: "相机图库状态未 ready"]
    )

    XCTAssertFalse(CameraVendorPtpReconnectErrorPolicy.shouldRetry(notReadyError))
    XCTAssertTrue(
      CameraVendorPtpReconnectErrorPolicy.shouldRetry(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
      )
    )
  }

  func testPtpInitCommandPacketMatchesCameraVendorReferenceLayout() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(friendlyName: "CamTransfer")

    XCTAssertEqual(data.count, 82)
    XCTAssertEqual(
      Array(data.prefix(28)),
      [
        0x52, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xF2, 0xE4, 0x53, 0x8F,
        0xAD, 0xA5, 0x48, 0x5D,
        0x87, 0xB2, 0x7F, 0x0B,
        0xD3, 0xD5, 0xDE, 0xD0,
        0x00, 0x00, 0x00, 0x00,
      ]
    )

    let expectedNameBytes: [UInt8] = [
      0x43, 0x00, 0x61, 0x00, 0x6D, 0x00, 0x54, 0x00,
      0x72, 0x00, 0x61, 0x00, 0x6E, 0x00, 0x73, 0x00,
      0x66, 0x00, 0x65, 0x00, 0x72, 0x00,
      0x00, 0x00,
    ]
    XCTAssertEqual(Array(data[28..<(28 + expectedNameBytes.count)]), expectedNameBytes)
    XCTAssertEqual(Array(data[(28 + expectedNameBytes.count)..<data.count]), Array(repeating: 0, count: 30))
  }

  func testOfficialGalleryPtpInitPolicyUsesOnlyCameraVendorLegacyVariants() {
    let variants = CameraVendorOfficialGalleryPtpInitPolicy.variants()

    XCTAssertEqual(
      variants.map(\.name),
      [
        "CameraVendor legacy + client IP GUID",
        "CameraVendor legacy",
      ]
    )
    XCTAssertEqual(variants.map(\.includesClientIP), [true, false])
    XCTAssertFalse(variants.map(\.name).contains { $0.contains("PTP/IP standard") })
  }

  func testOfficialGalleryPtpInitPolicyBuildsOnlyLegacyInitPackets() {
    let attempts = CameraVendorOfficialGalleryPtpInitPolicy.initAttempts(
      clientName: "CamTransfer",
      clientIP: "192.168.0.127"
    )

    XCTAssertEqual(attempts.map(\.name), [
      "CameraVendor legacy + client IP GUID",
      "CameraVendor legacy",
    ])
    XCTAssertEqual(
      attempts[0].packet,
      CameraVendorPtpPacketBuilder.buildInitCommandRequest(
        friendlyName: "CamTransfer",
        clientIP: "192.168.0.127"
      )
    )
    XCTAssertEqual(
      attempts[1].packet,
      CameraVendorPtpPacketBuilder.buildInitCommandRequest(
        friendlyName: "CamTransfer",
        clientIP: nil
      )
    )
    XCTAssertFalse(
      attempts.contains {
        $0.packet == CameraVendorPtpPacketBuilder.buildStandardInitCommandRequest(
          friendlyName: "CamTransfer",
          clientIP: "192.168.0.127"
        )
      }
    )
  }

  func testStandardPtpIpInitCommandPacketUsesIsoFieldOrder() {
    let data = CameraVendorPtpPacketBuilder.buildStandardInitCommandRequest(friendlyName: "CamTransfer")

    XCTAssertEqual(
      Array(data.prefix(28)),
      [
        0x35, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0xAD, 0xA5, 0x48, 0x5D,
        0x87, 0xB2, 0x7F, 0x0B,
        0xD3, 0xD5, 0xDE, 0xD0,
        0x00, 0x00, 0x00, 0x00,
        0x0C,
        0x43, 0x00, 0x61,
      ]
    )
    XCTAssertEqual(Array(data.suffix(4)), [0x00, 0x00, 0x01, 0x00])
  }

  func testPtpInitCommandCanIncludeClientIpInGuid() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(
      friendlyName: "CamTransfer",
      clientIP: "192.168.0.127"
    )

    XCTAssertEqual(Array(data[24..<28]), [0x7F, 0x00, 0xA8, 0xC0])
  }

  func testCameraWifiSubnetRecognizesOnlyCameraAssignedIp() {
    XCTAssertTrue(CameraVendorPtpConstants.isCameraWifiIPv4Address("192.168.0.122"))
    XCTAssertFalse(CameraVendorPtpConstants.isCameraWifiIPv4Address("192.168.3.28"))
    XCTAssertFalse(CameraVendorPtpConstants.isCameraWifiIPv4Address(nil))
  }

  func testPtpInitCommandIgnoresNonCameraSubnetClientIpInGuid() {
    let data = CameraVendorPtpPacketBuilder.buildInitCommandRequest(
      friendlyName: "CamTransfer",
      clientIP: "192.168.3.28"
    )

    XCTAssertEqual(Array(data[24..<28]), [0x00, 0x00, 0x00, 0x00])
  }

  func testPtpUInt32ArrayParserReadsCountedPayload() {
    let payload = Data([
      0x02, 0x00, 0x00, 0x00,
      0x11, 0x00, 0x00, 0x00,
      0x22, 0x00, 0x00, 0x00,
    ])

    XCTAssertEqual(CameraVendorPtpDataParser.uint32Array(from: payload), [17, 34])
  }

  func testPtpObjectInfoParserReadsFilenameAndDate() {
    var payload = Data()
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // storageId
    payload.append(contentsOf: [0x01, 0x38]) // JPEG
    payload.append(contentsOf: [0x00, 0x00]) // protection
    payload.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // size
    payload.append(contentsOf: [0x01, 0x38]) // thumb format
    payload.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // thumb size
    payload.append(contentsOf: [0x40, 0x00, 0x00, 0x00]) // thumb w
    payload.append(contentsOf: [0x30, 0x00, 0x00, 0x00]) // thumb h
    payload.append(contentsOf: [0x00, 0x04, 0x00, 0x00]) // image w
    payload.append(contentsOf: [0x00, 0x03, 0x00, 0x00]) // image h
    payload.append(contentsOf: [0x18, 0x00, 0x00, 0x00]) // depth
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // parent
    payload.append(contentsOf: [0x00, 0x00]) // assoc type
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // assoc desc
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // seq
    payload.append(ptpString("DSCF0001.JPG"))
    payload.append(ptpString("2026:04:26 17:00:00"))

    let info = CameraVendorPtpDataParser.objectInfo(handle: 99, data: payload)

    XCTAssertEqual(info.handle, 99)
    XCTAssertEqual(info.filename, "DSCF0001.JPG")
    XCTAssertEqual(info.captureDate, "2026:04:26 17:00:00")
    XCTAssertEqual(info.formatCode, 0x3801)
  }

  func testCameraVendorObjectInfoParserNormalizesOrientationMetadataAfterCaptureDateLikeAndroid() {
    var payload = Data()
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x10]) // storage
    payload.append(contentsOf: [0x01, 0x38]) // JPEG
    payload.append(contentsOf: [0x00, 0x00]) // protection
    payload.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // size
    payload.append(contentsOf: [0x01, 0x38]) // thumb format
    payload.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // thumb size
    payload.append(contentsOf: [0x40, 0x00, 0x00, 0x00]) // thumb w
    payload.append(contentsOf: [0x30, 0x00, 0x00, 0x00]) // thumb h
    payload.append(contentsOf: [0x00, 0x04, 0x00, 0x00]) // image w
    payload.append(contentsOf: [0x00, 0x03, 0x00, 0x00]) // image h
    payload.append(contentsOf: [0x18, 0x00, 0x00, 0x00]) // depth
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // parent
    payload.append(contentsOf: [0x00, 0x00]) // assoc type
    payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // assoc desc
    payload.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // seq
    payload.append(ptpString("DSCF0001.JPG"))
    payload.append(ptpString("2026:04:26 17:00:00"))
    payload.append(ptpString("Orientation:6"))

    let info = CameraVendorPtpDataParser.objectInfo(handle: 99, data: payload)

    XCTAssertEqual(info.orientation, 2)
  }

  func testCameraVendorVendorObjectInfoParserReadsReferenceAppLayout() {
    let payload = Data([
      0x01, 0x00, 0x00, 0x10, 0x12, 0x38, 0x00, 0x00,
      0x07, 0xB1, 0x0D, 0x00, 0x01, 0xB9, 0x80, 0xCB,
      0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0xE0, 0x01,
      0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, 0x20, 0x14,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]) + ptpString("DSCF3309.HEIC") + ptpString("20260328T045849") + ptpString("Orientation:1")

    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: 0x10000001, data: payload)

    XCTAssertEqual(info.handle, 0x10000001)
    XCTAssertEqual(info.filename, "DSCF3309.HEIC")
    XCTAssertEqual(info.captureDate, "20260328T045849")
    XCTAssertEqual(info.formatCode, 0x3812)
    XCTAssertEqual(info.compressedSize, 897287)
    XCTAssertEqual(info.orientation, 1)
  }

  func testCameraVendorVendorObjectInfoParserNormalizesReferenceAppExifOrientationLikeAndroid() {
    let payload = Data([
      0x01, 0x00, 0x00, 0x10, 0x12, 0x38, 0x00, 0x00,
      0x07, 0xB1, 0x0D, 0x00, 0x01, 0xB9, 0x80, 0xCB,
      0x00, 0x00, 0x80, 0x02, 0x00, 0x00, 0xE0, 0x01,
      0x00, 0x00, 0x30, 0x1E, 0x00, 0x00, 0x20, 0x14,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]) + ptpString("DSCF3309.HEIC") + ptpString("20260328T045849") + ptpString("Orientation:8")

    let info = CameraVendorPtpDataParser.cameraVendorVendorObjectInfo(handle: 0x10000001, data: payload)

    XCTAssertEqual(info.orientation, 4)
  }

  func testReferenceAppGalleryContextParserReadsD222Value() {
    let referenceAppReadyContext = Data([
      0x02, 0x00, 0x00, 0xDF,
      0x14, 0x00, 0x00, 0x00,
      0x22, 0xD2, 0x92, 0x09, 0x00, 0x00,
    ])
    let notReadyContext = Data([
      0x02, 0x00, 0x00, 0xDF,
      0x14, 0x00, 0x00, 0x00,
      0x22, 0xD2, 0x02, 0x00, 0x00, 0x00,
    ])

    XCTAssertEqual(
      CameraVendorPtpDataParser.cameraVendorGalleryContextValue(for: 0xD222, in: referenceAppReadyContext),
      0x0992
    )
    XCTAssertEqual(
      CameraVendorPtpDataParser.cameraVendorGalleryContextValue(for: 0xD222, in: notReadyContext),
      0x0002
    )
  }

  func testReferenceAppGalleryReadyPolicyAllowsProbeThroughNotReadyMarker() {
    XCTAssertFalse(CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: 0x0002))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.isReady(marker: 0x0993))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: 0x0002))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: UInt32?.none))
    XCTAssertTrue(CameraVendorReferenceAppGalleryReadyPolicy.shouldContinueToLatestObjectProbe(marker: 0x0992))
  }

  func testSuccessfulPtpHandshakeTreatsEmptyOrNonReadyD222AsObservationOnly() {
    XCTAssertTrue(
      CameraVendorGalleryHandshakeDiagnosticPolicy.isD222ObservationOnly(
        hasSuccessfulPtpHandshake: true,
        marker: nil
      )
    )
    XCTAssertTrue(
      CameraVendorGalleryHandshakeDiagnosticPolicy.isD222ObservationOnly(
        hasSuccessfulPtpHandshake: true,
        marker: 0x0002
      )
    )
    XCTAssertEqual(CameraVendorGalleryHandshakeDiagnosticPolicy.fixedReferenceD212ReadCount, 2)
  }

  func testConnectionSummaryDoesNotGenerateCameraWifiCandidatesWithoutOfficialCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiCandidates.isEmpty)
  }

  func testConnectionSummaryDoesNotUseDeviceNameAsWifiFallbackWhenNameContainsSerialSuffix() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A-003B",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiCandidates.isEmpty)
  }

  func testReferenceAppWifiNetworkDecoderReadsVisibleSsidPassphraseAndBssid() {
    let credentials = CameraVendorReferenceAppNetworkConfigDecoder.networkConfiguration(
      from: [
        CameraVendorReferenceAppNetworkConfigDecoder.ssidCharacteristicUUIDString:
          Data("CAMERA-DEVICE-A-003B".utf8),
        CameraVendorReferenceAppNetworkConfigDecoder.passphraseCharacteristicUUIDString:
          Data("uQMggJcFEEBhCDjgkww0".utf8),
        CameraVendorReferenceAppNetworkConfigDecoder.macAddressCharacteristicUUIDString:
          Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
      ]
    )

    XCTAssertEqual(
      credentials,
      CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: false,
        bssid: "aa:bb:cc:dd:ee:ff"
      )
    )
  }

  func testConnectionSummaryPrefersBleReportedWifiConfiguration() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "221019F1932011003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "uQMggJcFEEBhCDjgkww0",
        isHidden: true
      )
    )

    XCTAssertEqual(
      summary.wifiConfigurations,
      [
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "uQMggJcFEEBhCDjgkww0",
          isHidden: true
        )
      ]
    )
  }

  func testOfficialImportImageTransferPlanUsesLaunchRequestCharacteristic() {
    let previousPreference = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = true
    defer {
      CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = previousPreference
    }

    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .officialImportImage
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
          payload: Data([0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
          payload: Data([0x01])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
          payload: CameraVendorTransferActivationResizePolicy.resizeDisabledPayload
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
          payload: Data([0x03, 0x00])
        )
      ]
    )
  }

  func testOfficialImportImageActivationIgnoresDownloadCompressionPreference() {
    let previousPreference = CameraVendorTransferActivationResizePolicy.preferCompressedDownloads
    defer {
      CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = previousPreference
    }

    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = false
    let originalModeWrites = CameraVendorReferenceAppTransferActivationPlan.writes(for: .officialImportImage)

    CameraVendorTransferActivationResizePolicy.preferCompressedDownloads = true
    let compressedModeWrites = CameraVendorReferenceAppTransferActivationPlan.writes(for: .officialImportImage)

    XCTAssertEqual(originalModeWrites, compressedModeWrites)
    XCTAssertTrue(
      compressedModeWrites.contains {
        $0.characteristicUUIDString
          == CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString
      }
    )
  }

  func testOfficialImportImageActivationIncludesReferenceAppSettings() {
    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(for: .officialImportImage)
    let writtenUUIDs = Set(writes.map(\.characteristicUUIDString))

    XCTAssertTrue(
      writtenUUIDs.contains(
        CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString
      )
    )
    XCTAssertTrue(
      writtenUUIDs.contains(
        CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString
      )
    )
  }

  func testOfficialImportImageSupportDoesNotRequireHeifTransferSettingCharacteristic() {
    let available: Set<String> = [
      CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
      CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
      CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
      CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
      CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
    ]

    XCTAssertEqual(
      CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
        forAvailableCharacteristicUUIDStrings: available
      ),
      [.officialImportImage]
    )
  }

  func testBleStateSamplingPlanIsDisabledForCleanImportAttempt() {
    XCTAssertEqual(CameraVendorBleStateSamplingPlan.sampleDelaysSeconds, [])
    XCTAssertEqual(CameraVendorBleStateSamplingPlan.characteristicUUIDStrings, [])
    XCTAssertFalse(CameraVendorBleStateSamplingPlan.shouldDelayGalleryUntilSamplingCompletes)
  }

  func testReservedImageReceiveStateProbePlanIsDisabledForCleanImportAttempt() {
    XCTAssertEqual(CameraVendorReservedImageReceiveStateProbePlan.writeRequests, [])
  }

  func testOfficialImportImageTransferPlanTracksApStateCharacteristic() {
    XCTAssertEqual(
      CameraVendorReferenceAppTransferActivationPlan.trackedStatusCharacteristicUUIDStrings(
        for: .officialImportImage
      ),
      [
        CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
      ]
    )
  }

  func testOfficialImportImageTreatsAnyLaunchedApStateAsGalleryWifiReady() {
    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x00, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x03, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .officialImportImage
      )
    )

    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.transferStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .officialImportImage
      )
    )
  }

  func testConnectionSummaryOnlyRepresentsGalleryMode() {
    let summary = CameraVendorConnectionSummary(deviceName: "DEVICE-A", serialNumber: "1234")

    XCTAssertEqual(summary.subtitle, "序列号 1234")
    XCTAssertFalse(summary.subtitle.contains("自动接收"))
  }

  func testConnectionSummaryCapturesTransferSizeModeAtActivation() {
    let defaultSummary = CameraVendorConnectionSummary(deviceName: "DEVICE-A", serialNumber: "1234")
    let originalSummary = CameraVendorConnectionSummary(
      deviceName: "DEVICE-A",
      serialNumber: "1234",
      preferCompressedDownloads: false
    )

    XCTAssertFalse(defaultSummary.preferCompressedDownloads)
    XCTAssertEqual(defaultSummary.activeTransferDownloadMode, .original)
    XCTAssertFalse(originalSummary.preferCompressedDownloads)
    XCTAssertEqual(originalSummary.activeTransferDownloadMode, .original)
  }

  func testNativeLogTextPolicyTrimsLongLiveText() {
    let longText = String(repeating: "a", count: NativeLogTextViewPolicy.maxDisplayedCharacters + 50)
    let rendered = NativeLogTextViewPolicy.appending("next", to: longText)

    XCTAssertLessThanOrEqual(rendered.count, NativeLogTextViewPolicy.maxDisplayedCharacters + 4)
    XCTAssertTrue(rendered.hasPrefix("...\n"))
    XCTAssertTrue(rendered.hasSuffix("next"))
  }

  func testNativeLogTextPolicySkipsInvisibleLiveTextViews() {
    XCTAssertFalse(
      NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: .active,
        hasWindow: true,
        visibleHeight: 0
      )
    )
    XCTAssertTrue(
      NativeLogTextViewPolicy.shouldRenderLiveText(
        applicationState: .active,
        hasWindow: true,
        visibleHeight: 12
      )
    )
  }

  func testNativeGalleryGridLayoutUsesThreeColumnsOnPhone() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.columnCount(forCollectionWidth: 390),
      3
    )
  }

  func testNativeGalleryGridLayoutUsesFourColumnsOnWideScreens() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.columnCount(forCollectionWidth: 768),
      4
    )
  }

  func testNativeGalleryGridLayoutAllowsAndroidPinchRangeTwoThroughSix() {
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(1), 2)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(2), 2)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(6), 6)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.clampedColumnCount(7), 6)
    XCTAssertEqual(NativeGalleryGridLayoutPolicy.androidGridSpacing, 2)
  }

  func testNativeGalleryGridLayoutComputesSquareItemSide() {
    XCTAssertEqual(
      NativeGalleryGridLayoutPolicy.itemSide(
        forCollectionWidth: 390,
        horizontalInset: 12,
        interItemSpacing: 8
      ),
      116,
      accuracy: 0.001
    )
  }

  func testTransferActivationStatePolicyHandlesDuplicateReadyApState() {
    XCTAssertTrue(
      CameraVendorTransferActivationStateUpdatePolicy.shouldHandleTrackedStatusUpdate(
        previousValue: Data([0x01, 0x80]),
        newValue: Data([0x01, 0x80]),
        isReadyToJoinWifi: true
      )
    )
    XCTAssertFalse(
      CameraVendorTransferActivationStateUpdatePolicy.shouldHandleTrackedStatusUpdate(
        previousValue: Data([0x00, 0x80]),
        newValue: Data([0x00, 0x80]),
        isReadyToJoinWifi: false
      )
    )
  }

  func testPreferredImageTransferPlanUsesReferenceAppRemoteImageViewModeFallback() {
    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .preferredRemoteImageView
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
          payload: Data([0x02, 0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
          payload: Data([0x14, 0x00, 0x00, 0x00])
        )
      ]
    )
  }

  func testCompatibleImageTransferPlanUsesLegacyRemoteImageViewMode() {
    let writes = CameraVendorReferenceAppTransferActivationPlan.writes(
      for: .compatibleRemoteImageView
    )

    XCTAssertEqual(
      writes,
      [
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
          payload: Data([0x02, 0x00])
        ),
        CameraVendorBleWriteRequest(
          characteristicUUIDString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
          payload: Data([0x0B, 0x00, 0x00, 0x00])
        )
      ]
    )
  }

  func testTransferActivationOnlyExposesOfficialImportImage() {
    let strategies = CameraVendorReferenceAppTransferActivationPlan.supportedStrategies(
      forAvailableCharacteristicUUIDStrings: [
        CameraVendorReferenceAppTransferActivationPlan.connectedDeviceImageReceiveStateCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageTransferSettingExCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.imageResizeSettingCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString,
        CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString,
      ]
    )

    XCTAssertEqual(strategies, [.officialImportImage])
  }

  func testLegacyTransferDoesNotTreatNotLaunchedApStateAsWifiReady() {
    XCTAssertFalse(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x00, 0x80]),
        for: .preferredRemoteImageView
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isReadyToJoinWifi(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.apStateCharacteristicUUIDString,
        value: Data([0x01, 0x80]),
        for: .preferredRemoteImageView
      )
    )
  }

  func testTransferActivationRecognizesActionCommandCharacteristic() {
    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.connectedDeviceImageReceiveStateCharacteristicUUIDString
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.launchRequestCharacteristicUUIDString
      )
    )

    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.actionCommandCharacteristicUUIDString
      )
    )
  }

  func testTransferActivationRecognizesModeCommandCharacteristic() {
    XCTAssertTrue(
      CameraVendorReferenceAppTransferActivationPlan.isActivationCommandCharacteristic(
        uuidString: CameraVendorReferenceAppTransferActivationPlan.modeCommandCharacteristicUUIDString
      )
    )
  }

  func testMainThreadDispatcherRunsImmediatelyOnMainThread() {
    var didRun = false

    CameraVendorMainThread.run {
      XCTAssertTrue(Thread.isMainThread)
      didRun = true
    }

    XCTAssertTrue(didRun)
  }

  func testMainThreadDispatcherHopsBackToMainThreadFromBackgroundQueue() {
    let callbackOnMain = expectation(description: "callback on main")

    DispatchQueue.global(qos: .userInitiated).async {
      CameraVendorMainThread.run {
        XCTAssertTrue(Thread.isMainThread)
        callbackOnMain.fulfill()
      }
    }

    wait(for: [callbackOnMain], timeout: 2.0)
  }

  func testGalleryFailureMessageIncludesDiagnostics() {
    let message = CameraVendorGalleryDiagnostics.composeFailureMessage(
      baseMessage: "无法连接相机网络",
      diagnostics: ["尝试连接 Wi-Fi: DEVICE-A-003B", "PTP 命令端口连接失败"]
    )

    XCTAssertTrue(message.contains("无法连接相机网络"))
    XCTAssertTrue(message.contains("尝试连接 Wi-Fi: DEVICE-A-003B"))
    XCTAssertTrue(message.contains("PTP 命令端口连接失败"))
  }

  func testGalleryFailureBaseMessageDoesNotBlameWifiAfterVerifiedHandoff() {
    let message = CameraVendorGalleryDiagnostics.galleryReadFailureBaseMessage(
      errorDescription: "读取失败: Socket is not connected",
      didCompleteWifiHandoff: true
    )

    XCTAssertTrue(message.contains("相机 Wi-Fi 已连接"))
    XCTAssertTrue(message.contains("PTP/相册初始化失败"))
    XCTAssertFalse(message.contains("请先让 iPhone 连上相机 Wi"))
  }

  func testConnectionSummaryPrefersHiddenWifiCandidateFirst() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "CAMERA-DEVICE-A",
      serialNumber: "1234003B",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "CAMERA-DEVICE-A-003B",
        passphrase: "secret123",
        isHidden: true
      )
    )

    XCTAssertEqual(
      summary.wifiConfigurations,
      [
        CameraVendorWifiNetworkConfiguration(
          ssid: "CAMERA-DEVICE-A-003B",
          passphrase: "secret123",
          isHidden: true
        )
      ]
    )
  }

  func testGalleryAssociationPreflightSkipsJoinWhenAlreadyOnCameraWifi() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: "CAMERA-DEVICE-A-003B",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: false
      )
    )
  }

  func testGalleryAssociationPreflightDoesNotSkipJoinWhenOnlyPtpIsReachableWithoutSSID() {
    XCTAssertFalse(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: nil,
        wifiConfigurations: [],
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryAssociationPreflightDoesNotSkipJoinWhenWifiAndPtpAbsent() {
    XCTAssertFalse(
      CameraVendorGalleryAssociationPreflight.shouldSkipAutomaticWifiJoin(
        currentSSID: "Home WiFi",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: false
      )
    )
  }

  func testGalleryAssociationPreflightConfirmsCameraWifiFromSubnetWithoutSSID() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasConfirmedCameraNetwork(
        currentSSID: nil,
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ],
        isCameraPtpReachable: true
      )
    )
  }

  func testGalleryAssociationPreflightAllowsUnchangedCameraSubnetDuringManualRecovery() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: nil,
        currentIP: "192.168.0.114",
        manualPromptBaselineIP: "192.168.0.114",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ]
      )
    )
  }

  func testGalleryAssociationPreflightAllowsChangedCameraSubnetDuringManualRecovery() {
    XCTAssertTrue(
      CameraVendorGalleryAssociationPreflight.hasManualRecoveryCameraNetworkEvidence(
        currentSSID: nil,
        currentIP: "192.168.0.2",
        manualPromptBaselineIP: "192.168.0.114",
        wifiConfigurations: [
          CameraVendorWifiNetworkConfiguration(
            ssid: "CAMERA-DEVICE-A-003B",
            passphrase: "secret123",
            isHidden: true
          )
        ]
      )
    )
  }

  func testWifiHandoffCompletionRequiresConcreteNetworkEvidence() {
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: true,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: true,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: true,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: false,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: false,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertFalse(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: true,
        postJoinCameraPtpReachable: false
      )
    )
    XCTAssertTrue(
      CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff(
        hasConfirmedCameraNetwork: false,
        postJoinConfirmedCameraNetwork: true,
        didJoinWifiAutomatically: true,
        skippedAutoJoinBecauseManual: false,
        manualRecoveryNetworkEvidence: false,
        postJoinCameraPtpReachable: true
      )
    )
  }

  func testPtpRouteStartRequiresCompletedWifiHandoffEvidence() {
    XCTAssertTrue(
      CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
        didCompleteWifiHandoff: true
      )
    )
    XCTAssertFalse(
      CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute(
        didCompleteWifiHandoff: false
      )
    )
  }

  func testRealtimeGalleryServiceHasHardGateBeforeStartingPtpRoute() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorRealtimeGalleryService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let handoffResult = try XCTUnwrap(source.range(of: "let didCompleteWifiHandoff = CameraVendorWifiHandoffCompletionPolicy.didCompleteWifiHandoff")?.lowerBound)
    let connectPtpStart = try XCTUnwrap(source.range(of: "func connectGalleryPtp(", range: handoffResult..<source.endIndex)?.lowerBound)
    let guardedRegion = String(source[handoffResult..<connectPtpStart])

    XCTAssertTrue(guardedRegion.contains("CameraVendorPtpRouteStartPolicy.shouldStartPtpRoute"))
    XCTAssertTrue(guardedRegion.contains("didCompleteWifiHandoff: didCompleteWifiHandoff"))
  }

  func testRealtimeGalleryServiceDoesNotOwnPrePtpCoordinator() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("IOSCameraGalleryConnectionCoordinator"))
    XCTAssertFalse(source.contains("IOSCameraConnectionStepRunner(step: .reconnectPairedBle"))
    XCTAssertFalse(source.contains("IOS_OFFICIAL_GALLERY_PRE_PTP_CONFIRMED"))
  }

  func testRealtimeGalleryServiceDoesNotOwnPtpAndLoadGalleryCoordinator() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("private func fetchGallerySync"))
    XCTAssertFalse(source.contains("func loadGalleryItems("))
    XCTAssertFalse(source.contains("IOSCameraConnectionStepRunner(step: .connectPtp"))
  }

  func testRealtimeGalleryServiceDoesNotOwnConnectionStepExecutors() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("func executeReconnectPairedBleStep("))
    XCTAssertFalse(source.contains("func executeTransferAuthorizationStep("))
    XCTAssertFalse(source.contains("func executeActivateCameraWifiStep("))
    XCTAssertFalse(source.contains("func executeWaitCameraWifiReadyStep("))
    XCTAssertFalse(source.contains("func executeJoinCameraWifiStep("))
    XCTAssertFalse(source.contains("func executeConnectPtpStep("))
    XCTAssertFalse(source.contains("func executeConfirmGalleryModeStep("))
    XCTAssertFalse(source.contains("func executeLoadGalleryStep("))
  }

  func testRealtimeGalleryServiceHasNoLegacyFetchGalleryBranch() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraVendorBluetoothService.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("func fetchGallery() async throws"))
    XCTAssertFalse(source.contains("fetchAutoImageImportGallery()"))
  }

  func testProAccessAllowsTwentyFreeJPGDownloadsPerDay() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    let items = (0..<20).map { galleryItem(handle: $0, formatLabel: "JPG") }

    XCTAssertNil(access.restriction(for: items, now: fixedDate()))
  }

  func testProAccessBlocksFreeBatchAboveDailyLimit() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    let items = (0..<21).map { galleryItem(handle: $0, formatLabel: "JPG") }

    guard case .tooManyFiles(let limit) = access.restriction(for: items, now: fixedDate()) else {
      return XCTFail("Expected tooManyFiles restriction")
    }
    XCTAssertEqual(limit, 20)
  }

  func testProAccessBlocksNonJPGForFreePlan() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    guard case .nonJPG = access.restriction(for: [galleryItem(handle: 1, formatLabel: "HEIF")], now: fixedDate()) else {
      return XCTFail("Expected nonJPG restriction")
    }
  }

  func testProAccessCountsFreeDailyUsage() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(expiredTrialStartDate())

    access.registerFreeDownloads(items: (0..<20).map { galleryItem(handle: $0, formatLabel: "JPG") }, now: fixedDate())

    guard case .dailyLimitReached(let limit) = access.restriction(for: [galleryItem(handle: 21, formatLabel: "JPG")], now: fixedDate()) else {
      return XCTFail("Expected dailyLimitReached restriction")
    }
    XCTAssertEqual(limit, 20)
  }

  func testProAccessDoesNotRestrictDuringSevenDayTrial() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.setTrialStartDateForTesting(fixedDate())

    let items = (0..<80).map { galleryItem(handle: $0, formatLabel: "RAW") }

    XCTAssertNil(access.restriction(for: items, now: fixedDate()))
    access.registerFreeDownloads(items: items, now: fixedDate())
    XCTAssertEqual(access.remainingFreeJPGDownloads(now: fixedDate()), 20)
  }

  func testProAccessDoesNotRestrictWhenProUnlocked() {
    let access = CamTransferProAccessController.shared
    access.resetForTesting()
    access.isProUnlocked = true

    XCTAssertNil(access.restriction(for: [galleryItem(handle: 1, formatLabel: "RAW")], now: fixedDate()))

    access.resetForTesting()
  }

  func testGalleryDownloadsAreNotGatedByProAccess() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let selectionStart = try XCTUnwrap(
      source.range(of: "@objc private func downloadSelectedTapped()")?.lowerBound
    )
    let selectionEnd = try XCTUnwrap(
      source.range(of: "@objc private func downloadListTapped()", range: selectionStart..<source.endIndex)?.lowerBound
    )
    let selectionBody = String(source[selectionStart..<selectionEnd])
    XCTAssertFalse(selectionBody.contains("CamTransferProAccessController"))
    XCTAssertFalse(selectionBody.contains("presentCamTransferPaywall"))

    let downloadStart = try XCTUnwrap(
      source.range(of: "private func openDownloadCenter(for handles: [Int])")?.lowerBound
    )
    let downloadEnd = try XCTUnwrap(
      source.range(of: "\n}\nextension NativeGalleryViewController", range: downloadStart..<source.endIndex)?.lowerBound
    )
    let downloadBody = String(source[downloadStart..<downloadEnd])
    XCTAssertFalse(downloadBody.contains("registerFreeDownloads"))
    XCTAssertFalse(downloadBody.contains("CamTransferProAccessController"))
  }

  func testIOSCameraIdentityUsesStableCameraIDNotPeripheralID() {
    let identity = IOSCameraIdentity(
      cameraID: "12345678_X-T5",
      displayName: "X-T5",
      serialNumber: "12345678",
      bleEndpoint: IOSCameraBleEndpoint(identifier: "core-bluetooth-uuid", address: "AA:BB:CC:DD:EE:FF")
    )

    XCTAssertEqual(identity.cameraID, "12345678_X-T5")
    XCTAssertNotEqual(identity.cameraID, identity.bleEndpoint.identifier)
  }

  func testIOSOfficialWifiCredentialRejectsGuessedSSIDAndDefaultPassword() {
    XCTAssertNil(
      IOSCameraWifiCredential.official(
        ssid: "X-T5-003B",
        passphrase: "00000000",
        bssid: nil,
        source: .guessed
      )
    )
    XCTAssertNotNil(
      IOSCameraWifiCredential.official(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "camera-secret",
        bssid: "00:11:22:33:44:55",
        source: .bleHandshake
      )
    )
  }

  func testIOSRegistrationGuardRequiresSystemBondCleanupForStaleBond() {
    let issue = IOSCameraRegistrationGuard.evaluate(
      localRecord: nil,
      scannedEndpoint: IOSCameraBleEndpoint(identifier: "scan-id", address: "AA:BB:CC:DD:EE:FF"),
      bondedAddresses: ["AA:BB:CC:DD:EE:FF"]
    )

    XCTAssertEqual(issue, .needsSystemBondCleanup(address: "AA:BB:CC:DD:EE:FF"))
  }

  func testIOSGalleryConnectionCoordinatorRunsAndroidStepOrder() async throws {
    var executedSteps: [IOSCameraConnectionStep] = []
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: IOSCameraConnectionStep.officialGalleryOrder.map { step in
        IOSCameraConnectionStepRunner(step: step) { context in
          executedSteps.append(step)
          let evidence: IOSCameraConnectionStepEvidence
          switch step {
          case .reconnectPairedBle:
            evidence = .bleIdentityVerified(cameraID: context.cameraID)
          case .transferAuthorization:
            let wifi = IOSCameraWifiCredential(
              ssid: "FUJIFILM-X-T5-003B",
              passphrase: "camera-secret",
              bssid: nil,
              source: .bleHandshake
            )
            evidence = .officialWifiCredential(wifi)
          case .activateCameraWifi:
            evidence = .cameraWifiActivationAcknowledged
          case .waitCameraWifiReady:
            evidence = .cameraWifiReady
          case .joinCameraWifi:
            evidence = .joinedCameraWifi(ssid: "FUJIFILM-X-T5-003B")
          case .connectPtp:
            evidence = .ptpConnected(IOSCameraPtpSessionEvidence(sessionID: "ptp"))
          case .confirmGalleryMode:
            evidence = .galleryModeConfirmed
          case .loadGallery:
            evidence = .galleryLoaded(IOSCameraGalleryReadyEvidence(ptpSessionID: "ptp"))
          default:
            fatalError("Unexpected gallery step \(step)")
          }
          return IOSCameraConnectionStepExecution(context: context, evidence: evidence)
        }
      }
    )

    let result = try await coordinator.connect(
      context: IOSCameraConnectionContext(
        cameraID: "12345678_X-T5",
        pairingRecord: nil,
        wifiCredential: nil,
        ptpSessionID: nil
      )
    )

    XCTAssertEqual(executedSteps, IOSCameraConnectionStep.officialGalleryOrder)
    XCTAssertEqual(result.cameraID, "12345678_X-T5")
  }

  func testIOSGalleryConnectionStepOrderIncludesConfirmGalleryModeBeforeLoadGallery() {
    XCTAssertEqual(
      IOSCameraConnectionStep.officialGalleryOrder,
      [
        .reconnectPairedBle,
        .transferAuthorization,
        .activateCameraWifi,
        .waitCameraWifiReady,
        .joinCameraWifi,
        .connectPtp,
        .confirmGalleryMode,
        .loadGallery,
      ]
    )
    XCTAssertEqual(IOSCameraConnectionStep.confirmGalleryMode.androidDisplayName, "ConfirmGalleryMode")
  }

  func testIOSGalleryConnectionCoordinatorStopsAtFailedStep() async {
    var executedSteps: [IOSCameraConnectionStep] = []
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: [
        IOSCameraConnectionStepRunner(step: .reconnectPairedBle) { context in
          executedSteps.append(.reconnectPairedBle)
          return IOSCameraConnectionStepExecution(
            context: context,
            evidence: .bleIdentityVerified(cameraID: context.cameraID)
          )
        },
        IOSCameraConnectionStepRunner(step: .transferAuthorization) { _ in
          executedSteps.append(.transferAuthorization)
          throw IOSCameraConnectionIssue(step: .transferAuthorization, reason: "missing official Wi-Fi credential")
        },
        IOSCameraConnectionStepRunner(step: .activateCameraWifi) { context in
          executedSteps.append(.activateCameraWifi)
          return IOSCameraConnectionStepExecution(
            context: context,
            evidence: .cameraWifiActivationAcknowledged
          )
        },
      ]
    )

    do {
      _ = try await coordinator.connect(
        context: IOSCameraConnectionContext(
          cameraID: "12345678_X-T5",
          pairingRecord: nil,
          wifiCredential: nil,
          ptpSessionID: nil
        )
      )
      XCTFail("Expected transferAuthorization failure")
    } catch let issue as IOSCameraConnectionIssue {
      XCTAssertEqual(issue.step, .transferAuthorization)
      XCTAssertEqual(coordinator.confirmedSteps(), [.reconnectPairedBle])
      XCTAssertEqual(executedSteps, [.reconnectPairedBle, .transferAuthorization])
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSGalleryConnectionCoordinatorRejectsOutOfOrderRunnersBeforeRunningThem() async {
    var didRun = false
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: [
        IOSCameraConnectionStepRunner(step: .connectPtp) { context in
          didRun = true
          return IOSCameraConnectionStepExecution(
            context: context,
            evidence: .ptpConnected(IOSCameraPtpSessionEvidence(sessionID: "ptp"))
          )
        }
      ]
    )

    do {
      _ = try await coordinator.connect(
        context: IOSCameraConnectionContext(
          cameraID: "12345678_X-T5",
          pairingRecord: nil,
          wifiCredential: nil,
          ptpSessionID: nil
        )
      )
      XCTFail("Expected reconnectPairedBle ordering failure")
    } catch let issue as IOSCameraConnectionIssue {
      XCTAssertEqual(issue.step, .reconnectPairedBle)
      XCTAssertTrue(issue.reason.contains("Cannot run ConnectPtp before ReconnectPairedBle"))
      XCTAssertFalse(didRun)
      XCTAssertTrue(coordinator.confirmedSteps().isEmpty)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSGalleryConnectionCoordinatorRequiresStateMachineEvidenceBeforeConfirmingStep() async {
    let coordinator = IOSCameraGalleryConnectionCoordinator(
      runners: [
        IOSCameraConnectionStepRunner(step: .reconnectPairedBle) { context in
          IOSCameraConnectionStepExecution(
            context: context,
            evidence: .cameraWifiReady
          )
        }
      ]
    )

    do {
      _ = try await coordinator.connect(
        context: IOSCameraConnectionContext(
          cameraID: "12345678_X-T5",
          pairingRecord: nil,
          wifiCredential: nil,
          ptpSessionID: nil
        )
      )
      XCTFail("Expected reconnectPairedBle evidence failure")
    } catch let issue as IOSCameraConnectionIssue {
      XCTAssertEqual(issue.step, .reconnectPairedBle)
      XCTAssertTrue(coordinator.confirmedSteps().isEmpty)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSAppFlowRunsRegistrationGuardBeforePairingAndStopsAfterPairing() async throws {
    var guardCallCount = 0
    var pairingCallCount = 0
    var galleryCallCount = 0
    let flow = IOSCameraAppFlowCoordinator(
      registrationGuard: {
        guardCallCount += 1
        return .pass
      },
      pairingModule: IOSCameraPairingModule(start: {
        pairingCallCount += 1
      }),
      galleryConnector: { _ in
        galleryCallCount += 1
        return IOSCameraConnectionContext(cameraID: "12345678_X-T5", pairingRecord: nil, wifiCredential: nil, ptpSessionID: "ptp")
      }
    )

    try await flow.startPairing()

    XCTAssertEqual(guardCallCount, 1)
    XCTAssertEqual(pairingCallCount, 1)
    XCTAssertEqual(galleryCallCount, 0)
  }

  func testIOSRegistrationGuardBlocksPairingWhenCleanupRequired() async {
    let flow = IOSCameraAppFlowCoordinator(
      registrationGuard: {
        .needsSystemBondCleanup(address: "AA:BB:CC:DD:EE:FF")
      },
      pairingModule: IOSCameraPairingModule(start: {
        XCTFail("Pairing should not start when registration is blocked")
      }),
      galleryConnector: { _ in
        XCTFail("Gallery entry should not start when registration is blocked")
        return IOSCameraConnectionContext(cameraID: "12345678_X-T5", pairingRecord: nil, wifiCredential: nil, ptpSessionID: "ptp")
      }
    )

    do {
      _ = try await flow.startPairing()
      XCTFail("Expected registrationBlocked")
    } catch let error as IOSCameraAppFlowIssue {
      XCTAssertEqual(error, .registrationBlocked(.needsSystemBondCleanup(address: "AA:BB:CC:DD:EE:FF")))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testIOSPairingFlowStopsAtPairedAndDoesNotEnterGallery() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    var galleryCallCount = 0
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          galleryCallCount += 1
          return IOSCameraConnectionContext(cameraID: record.identity.cameraID, pairingRecord: record, wifiCredential: record.wifiCredential, ptpSessionID: "ptp")
        }
      ),
      gallerySessionLoader: { _, _ in
        IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
      }
    )

    try await coordinator.startPairing()
    XCTAssertEqual(coordinator.state, .waitingForPairingConfirmation)
    XCTAssertNil(coordinator.navigationEvent)

    try await coordinator.confirmPairing()
    XCTAssertEqual(coordinator.state, .paired(record))
    XCTAssertNil(coordinator.navigationEvent)
    XCTAssertEqual(galleryCallCount, 0)
  }

  func testIOSConnectFlowCoordinatorExposesStructuredIssueForCurrentStepFailure() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let issue = IOSCameraConnectionIssue(
      step: .loadGallery,
      reason: "gallery load failed"
    )
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          throw issue
        }
      ),
      gallerySessionLoader: { _, _ in
        XCTFail("Gallery session loader should not run on connection failure")
        return IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
      }
    )

    do {
      try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertEqual(coordinator.state, .failed(issue))
    XCTAssertEqual(coordinator.issue, issue)
    XCTAssertEqual(coordinator.retryTarget, .galleryEntryWithBle)
    XCTAssertNil(coordinator.navigationEvent)
  }

  func testIOSConnectFlowCoordinatorStartsAtReconnectStepBeforeConnectionContextArrives() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let connectorStarted = expectation(description: "connector started")
    let expectedSession = IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          connectorStarted.fulfill()
          try await Task.sleep(nanoseconds: 200_000_000)
          return IOSCameraConnectionContext(
            cameraID: record.identity.cameraID,
            pairingRecord: record,
            wifiCredential: record.wifiCredential,
            ptpSessionID: "ptp"
          )
        }
      ),
      gallerySessionLoader: { _, _ in
        expectedSession
      }
    )

    let task = Task {
      try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    }

    await fulfillment(of: [connectorStarted], timeout: 1.0)
    XCTAssertEqual(coordinator.state, .connecting(.reconnectPairedBle))

    try await task.value
    XCTAssertEqual(coordinator.state, .galleryReady(expectedSession))
  }

  func testIOSConnectFlowCoordinatorPublishesIntermediateConnectionSteps() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let sawTransferAuthorization = expectation(description: "saw transfer authorization")
    let expectedSession = IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          IOSCameraConnectionContext(
            cameraID: record.identity.cameraID,
            pairingRecord: record,
            wifiCredential: record.wifiCredential,
            ptpSessionID: "ptp"
          )
        }
      ),
      gallerySessionLoader: { _, publishStep in
        publishStep(.transferAuthorization)
        sawTransferAuthorization.fulfill()
        try await Task.sleep(nanoseconds: 100_000_000)
        publishStep(.connectPtp)
        return expectedSession
      }
    )

    let task = Task {
      try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    }

    await fulfillment(of: [sawTransferAuthorization], timeout: 1.0)
    XCTAssertEqual(coordinator.state, .connecting(.transferAuthorization))

    try await task.value
    XCTAssertEqual(coordinator.state, .galleryReady(expectedSession))
  }

  func testIOSConnectFlowCoordinatorMapsLoaderFailureToStructuredLoadGalleryIssue() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          IOSCameraConnectionContext(
            cameraID: record.identity.cameraID,
            pairingRecord: record,
            wifiCredential: record.wifiCredential,
            ptpSessionID: "ptp"
          )
        }
      ),
      gallerySessionLoader: { _, _ in
        throw NSError(
          domain: "RunnerTests",
          code: 9,
          userInfo: [NSLocalizedDescriptionKey: "gallery load failed"]
        )
      }
    )

    do {
      try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let expectedIssue = IOSCameraConnectionIssue(
      step: .loadGallery,
      reason: "gallery load failed"
    )
    XCTAssertEqual(coordinator.state, .failed(expectedIssue))
    XCTAssertEqual(coordinator.issue, expectedIssue)
    XCTAssertEqual(coordinator.retryTarget, .galleryEntryWithBle)
    XCTAssertNil(coordinator.navigationEvent)
  }

  func testIOSConnectFlowCoordinatorMapsInvalidRememberedPairingToTransferAuthorizationIssue() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          throw IOSCameraConnectFlowRuntimeError.invalidRememberedPairing
        }
      ),
      gallerySessionLoader: { _, _ in
        XCTFail("Gallery session loader should not run on invalid remembered pairing")
        return IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
      }
    )

    do {
      try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let expectedIssue = IOSCameraConnectionIssue(
      step: .transferAuthorization,
      reason: "已配对记录缺少官方 Wi-Fi 配置，请重新配对"
    )
    XCTAssertEqual(coordinator.state, .failed(expectedIssue))
    XCTAssertEqual(coordinator.issue, expectedIssue)
    XCTAssertEqual(coordinator.retryTarget, .galleryEntryWithBle)
  }

  func testIOSConnectFlowCoordinatorProducesGallerySessionOnSuccess() async throws {
    let record = IOSCameraPairingRecord(
      identity: IOSCameraIdentity(
        cameraID: "12345678_X-T5",
        displayName: "X-T5",
        serialNumber: "12345678",
        bleEndpoint: IOSCameraBleEndpoint(identifier: "id", address: "AA:BB:CC:DD:EE:FF")
      ),
      wifiCredential: try XCTUnwrap(
        IOSCameraWifiCredential.official(
          ssid: "FUJIFILM-X-T5-003B",
          passphrase: "camera-secret",
          bssid: nil,
          source: .bleHandshake
        )
      )
    )
    let expectedSession = IOSCameraGallerySession(cameraID: record.identity.cameraID, ptpSessionID: "ptp")
    let coordinator = IOSCameraConnectFlowCoordinator(
      appFlow: IOSCameraAppFlowCoordinator(
        registrationGuard: { .pass },
        pairingModule: IOSCameraPairingModule(
          start: {
          },
          confirm: {
            IOSCameraPairingResult(record: record)
          }
        ),
        galleryConnector: { _ in
          IOSCameraConnectionContext(cameraID: record.identity.cameraID, pairingRecord: record, wifiCredential: record.wifiCredential, ptpSessionID: "ptp")
        }
      ),
      gallerySessionLoader: { context, _ in
        XCTAssertEqual(context.cameraID, record.identity.cameraID)
        return expectedSession
      }
    )

    try await coordinator.enterRememberedGallery(cameraID: record.identity.cameraID)
    XCTAssertEqual(coordinator.state, .galleryReady(expectedSession))
    XCTAssertEqual(coordinator.navigationEvent, .enterGallery(expectedSession))
  }

  func testIOSConnectionStepOrderMatchesAndroidMainline() {
    XCTAssertEqual(
      IOSCameraConnectionStep.officialGalleryOrder,
      [
        .reconnectPairedBle,
        .transferAuthorization,
        .activateCameraWifi,
        .waitCameraWifiReady,
        .joinCameraWifi,
        .connectPtp,
        .confirmGalleryMode,
        .loadGallery,
      ]
    )
  }

  func testIOSRetryTargetMatchesAndroidRules() {
    XCTAssertEqual(
      IOSCameraConnectionRetryPolicy.target(for: .pairingConfirmation),
      .pairingConfirmation
    )
    XCTAssertEqual(
      IOSCameraConnectionRetryPolicy.target(for: .joinCameraWifi),
      .wifiHandoffWithoutBle
    )
    XCTAssertEqual(
      IOSCameraConnectionRetryPolicy.target(for: .connectPtp),
      .resetConnection
    )
    XCTAssertEqual(
      IOSCameraConnectionRetryPolicy.target(for: .loadGallery),
      .galleryEntryWithBle
    )
    XCTAssertEqual(
      IOSCameraConnectionRetryPolicy.target(for: nil),
      .pairingScan
    )
  }

  func testIOSConnectionStateMachineRequiresEvidenceBeforeAdvancing() throws {
    let machine = IOSCameraConnectionStateMachine()
    let wifiCredential = try XCTUnwrap(
      IOSCameraWifiCredential.official(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "camera-secret",
        bssid: "00:11:22:33:44:55",
        source: .bleHandshake
      )
    )

    XCTAssertEqual(
      try machine.advance(
        from: .reconnectPairedBle,
        with: .bleIdentityVerified(cameraID: "12345678_X-T5")
      ),
      .transferAuthorization
    )
    XCTAssertEqual(
      try machine.advance(
        from: .transferAuthorization,
        with: .officialWifiCredential(wifiCredential)
      ),
      .activateCameraWifi
    )
    XCTAssertEqual(
      try machine.advance(
        from: .activateCameraWifi,
        with: .cameraWifiActivationAcknowledged
      ),
      .waitCameraWifiReady
    )
    XCTAssertEqual(
      try machine.advance(
        from: .waitCameraWifiReady,
        with: .cameraWifiReady
      ),
      .joinCameraWifi
    )
    XCTAssertEqual(
      try machine.advance(
        from: .joinCameraWifi,
        with: .joinedCameraWifi(ssid: wifiCredential.ssid)
      ),
      .connectPtp
    )
    XCTAssertEqual(
      try machine.advance(
        from: .connectPtp,
        with: .ptpConnected(IOSCameraPtpSessionEvidence(sessionID: "ptp-session"))
      ),
      .confirmGalleryMode
    )
    XCTAssertEqual(
      try machine.advance(
        from: .confirmGalleryMode,
        with: .galleryModeConfirmed
      ),
      .loadGallery
    )
    XCTAssertFalse(machine.hasGalleryReadyEvidence)
    XCTAssertNil(
      try machine.advance(
        from: .loadGallery,
        with: .galleryLoaded(IOSCameraGalleryReadyEvidence(ptpSessionID: "ptp-session"))
      )
    )
    XCTAssertTrue(machine.hasGalleryReadyEvidence)
  }

  func testIOSConnectionStateMachineStopsOnFailedEvidenceCheck() throws {
    let machine = IOSCameraConnectionStateMachine()

    XCTAssertThrowsError(
      try machine.advance(
        from: .transferAuthorization,
        with: .bleIdentityVerified(cameraID: "12345678_X-T5")
      )
    ) { error in
      guard let issue = error as? IOSCameraConnectionIssue else {
        return XCTFail("Expected IOSCameraConnectionIssue, got \(error)")
      }
      XCTAssertEqual(issue.step, .transferAuthorization)
      XCTAssertEqual(issue.action, .retryStep)
      XCTAssertEqual(issue.retryTarget, .galleryEntryWithBle)
      XCTAssertFalse(machine.hasGalleryReadyEvidence)
    }

  }

  func testNativeGalleryChromeCopyMatchesAndroidHeaderAndCollapsedFilter() {
    XCTAssertEqual(NativeGalleryChromeCopy.title, "CAMERA GALLERY")
    XCTAssertEqual(NativeGalleryChromeCopy.filterTitle, "筛选")
    XCTAssertEqual(NativeGalleryChromeCopy.defaultFilterSummary, "全部日期 · 全部格式 · 最新优先")
    XCTAssertEqual(NativeGalleryChromeCopy.sortOptionTitles, ["最新", "最早", "未下载"])
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 2, isLoading: true, isTransferring: false), "下载中 2")
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: false, isTransferring: true), "正在下载")
    XCTAssertEqual(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: true, isTransferring: false), "正在读取相机照片")
    XCTAssertNil(NativeGalleryChromeCopy.loadingText(activeDownloadCount: 0, isLoading: false, isTransferring: false))
  }

  func testNativeGalleryFilteredEmptyStateOffersShowAllRecovery() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let runnerDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Runner")
    let controllerSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeGalleryViewController.swift"),
      encoding: .utf8
    )
    let policySource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("NativeGalleryPolicies.swift"),
      encoding: .utf8
    )

    XCTAssertTrue(policySource.contains("NativeGalleryEmptyStatePolicy"))
    XCTAssertTrue(policySource.contains("当前筛选没有照片"))
    XCTAssertTrue(policySource.contains("显示全部"))
    XCTAssertTrue(controllerSource.contains("filteredEmptyContainer"))
    XCTAssertTrue(controllerSource.contains("refreshGalleryEmptyState()"))
    XCTAssertTrue(controllerSource.contains("showAllPhotosTapped"))
    XCTAssertTrue(controllerSource.contains("filterState = NativeGalleryFilterState(sort: filterState.sort)"))
    XCTAssertTrue(controllerSource.contains("submitGalleryIntent()"))
  }

  func testNativeGalleryFilteredEmptyStateOnlyAppearsForEffectiveFilter() {
    XCTAssertTrue(
      NativeGalleryEmptyStatePolicy.shouldShow(
        itemCount: 0,
        isLoading: false,
        errorMessage: nil,
        filterState: NativeGalleryFilterState(date: .today)
      )
    )
    XCTAssertFalse(
      NativeGalleryEmptyStatePolicy.shouldShow(
        itemCount: 0,
        isLoading: false,
        errorMessage: nil,
        filterState: NativeGalleryFilterState()
      )
    )
    XCTAssertFalse(
      NativeGalleryEmptyStatePolicy.shouldShow(
        itemCount: 0,
        isLoading: true,
        errorMessage: nil,
        filterState: NativeGalleryFilterState(date: .today)
      )
    )
    XCTAssertFalse(
      NativeGalleryEmptyStatePolicy.shouldShow(
        itemCount: 0,
        isLoading: false,
        errorMessage: "catalog failed",
        filterState: NativeGalleryFilterState(date: .today)
      )
    )
    XCTAssertFalse(
      NativeGalleryEmptyStatePolicy.shouldShow(
        itemCount: 1,
        isLoading: false,
        errorMessage: nil,
        filterState: NativeGalleryFilterState(date: .today)
      )
    )
  }

  func testNativeGalleryShowAllRecoveryClearsRuleAndPreservesSort() {
    let filteredState = NativeGalleryFilterState(
      formats: .selected([.heif]),
      date: .today,
      downloadScope: .notDownloaded,
      sort: .oldest
    )

    let recoveredState = NativeGalleryFilterState(sort: filteredState.sort)

    XCTAssertEqual(recoveredState.rule, .galleryDefault)
    XCTAssertEqual(recoveredState.sort, .oldest)
  }

  func testNativeGalleryTopChromeKeepsActionsInTopHeaderLikeAndroid() {
    XCTAssertTrue(NativeGalleryTopChromePolicy.shouldHideSystemNavigationBar)
    XCTAssertEqual(NativeGalleryTopChromePolicy.horizontalInset, 18)
    XCTAssertEqual(NativeGalleryTopChromePolicy.topInset, 0)
    XCTAssertEqual(NativeGalleryTopChromePolicy.bottomInset, 0)
    XCTAssertEqual(NativeGalleryTopChromePolicy.actionRowHeight, 36)
    XCTAssertEqual(NativeGalleryTopChromePolicy.actionSpacing, 8)
    XCTAssertEqual(NativeGalleryTopChromePolicy.statusSpacing, 0)
  }

  func testNativeGalleryAndroidParityLayoutKeepsGridTightUnderFilter() {
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterToGridSpacing, 2)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterHeaderHeight, 42)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.filterTopSpacing, 0)
    XCTAssertTrue(NativeGalleryAndroidParityLayoutPolicy.shouldShowPinchHintBubble)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.bottomBarHeight, 52)
    XCTAssertEqual(NativeGalleryAndroidParityLayoutPolicy.bottomBarBottomInset, 10)
  }

  func testNativeGalleryCollapsedFilterReanchorsGridDirectlyBelowToolRow() throws {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sourceURL = testsDirectory
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("collectionTopToToolRowConstraint"))
    XCTAssertTrue(source.contains("collectionTopToExpandedFilterConstraint"))
    XCTAssertTrue(source.contains("updateFilterPanelLayout(animated:"))
  }

  func testThumbnailTimingLogPolicyMatchesAndroidDiagnosticShape() {
    XCTAssertEqual(
      CameraVendorThumbnailTimingLogPolicy.successMessage(
        handle: 0x123,
        bytes: 4096,
        ptpElapsedMs: 72,
        decodeElapsedMs: 3,
        totalElapsedMs: 81
      ),
      "[OBS] THUMBNAIL_TIMING_OK handle=0x00000123 bytes=4096 ptpMs=72 decodeMs=3 totalMs=81"
    )
    XCTAssertEqual(
      CameraVendorThumbnailTimingLogPolicy.failureMessage(handle: 0x123, elapsedMs: 91, errorDescription: "boom"),
      "[OBS] THUMBNAIL_TIMING_FAILED handle=0x00000123 totalMs=91 error=boom"
    )
  }

  func testNativeGalleryCellDoesNotDecodeThumbnailDataOnMainThreadFallback() {
    XCTAssertFalse(NativeGalleryCellThumbnailDecodePolicy.shouldDecodeDataDuringCellConfigure)
  }

  func testDownloadCenterRehydratesPersistedThumbnailsOffMainThread() {
    XCTAssertTrue(NativeDownloadCenterThumbnailPolicy.shouldRehydratePersistedThumbnailData)
    XCTAssertEqual(
      NativeDownloadCenterThumbnailPolicy.action(
        thumbnailData: Data([0xFF, 0xD8, 0xFF]),
        cachedImage: nil
      ),
      .decodeCachedData
    )
    XCTAssertEqual(
      NativeDownloadCenterThumbnailPolicy.action(
        thumbnailData: nil,
        cachedImage: nil
      ),
      .none
    )
  }

  func testTopChromeIconButtonsDoNotDrawExtraCardFrames() {
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesFilledBackground)
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesBorder)
    XCTAssertFalse(NativeTopChromeIconButtonStylePolicy.usesShadow)
    XCTAssertEqual(NativeTopChromeIconButtonStylePolicy.sideLength, 42)
  }

  func testThumbnailPtpVerboseDiagnosticsAreSuppressedDuringSmoothGalleryScrolling() {
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_REQUEST handle=0x00000001"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_DATA bytes=123 handle=0x00000001 elapsedMs=8"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_GET_THUMB_CONTEXT_PRIMED_STANDARD handle=0x00000001 ms=3"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_THUMB_DATA source=standardGetThumb handle=0x00000001 rawBytes=123 normalizedBytes=123 rawHead=ffd8 normalizedHead=ffd8"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] THUMBNAIL_TIMING_OK handle=0x00000001 bytes=123 ptpMs=8 decodeMs=3 totalMs=11"))
    XCTAssertTrue(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] THUMBNAIL_TIMING_FAILED handle=0x00000001 totalMs=80 error=boom"))
  }

  func testPtpPacketLevelDiagnosticsAreSuppressedDuringDownloads() {
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("等待 PTP 包头"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("等待 CameraVendor legacy PTP 包头"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到 PTP 包 type=10 length=4194312"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到 CameraVendor legacy PTP 包 kind=2 length=14"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("收到数据包 type=10, 当前数据大小=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("操作响应: responseCode=0x2001, 总数据大小=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("CameraVendor 操作响应: responseCode=0x2001 txnID=42"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_SOCKET_PACKET_READ transport=standard type=10 length=4194312 headerMs=0 payloadMs=500"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_SOCKET_PAYLOAD_PROGRESS transport=standard bytesRead=1048576 totalBytes=4194304 payloadMs=120"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_REQUEST purpose=download-data handle=0x000004CA offset=0 maxBytes=4194304 expectedSize=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_CHUNK purpose=download-data handle=0x000004CA chunkBytes=4194304 totalBytes=4194304 chunkMs=1730 isJpeg=true"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_REQUEST purpose=download-file handle=0x000004CA offset=0 size=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_FILE_CHUNK purpose=download-file handle=0x000004CA chunkBytes=4194304 totalBytes=4194304 chunkMs=1730"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_STANDARD_PARTIAL_OBJECT_COMPLETE reason=expected-size handle=0x000004CA totalBytes=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_PREPARE_BEGIN handle=0x000004CA mode=compressed"))
    XCTAssertTrue(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_TIMING handle=0x000004CA mode=original bytes=4194304 prepMs=20 freshInfoMs=180 readMs=1400 normalizeMs=1 totalMs=1601"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_INFO handle=0x000004CA size=4194304"))
    XCTAssertFalse(CameraVendorPtpDiagnosticLogPolicy.shouldEmit("[OBS] PTP_DOWNLOAD_DATA_COMPLETE handle=0x000004CA bytes=4194304 elapsedMs=1730"))
  }

  func testNativeGalleryThumbnailUISuccessLogsAreSuppressedDuringSmoothScrolling() {
    XCTAssertFalse(NativeGalleryThumbnailUILogPolicy.shouldEmitSuccess(totalElapsedMs: 42))
    XCTAssertTrue(
      NativeGalleryThumbnailUILogPolicy.shouldEmitFailure(
        for: NSError(domain: "CameraVendorPtpSession", code: 0x100A)
      )
    )
  }

  func testNativeGalleryDoesNotRebuildSectionsAfterEveryThumbnail() {
    XCTAssertFalse(NativeGalleryThumbnailSectionRefreshPolicy.shouldRebuildSectionsAfterThumbnailLoad)
  }

  func testNativeDownloadCenterChromeMatchesAndroidHeaderSummaryAndGrid() {
    XCTAssertEqual(NativeDownloadCenterChrome.title, "DOWNLOADS")
    XCTAssertEqual(NativeDownloadCenterChrome.clearRecordsTitle, "清理记录")
    XCTAssertEqual(NativeDownloadCenterChrome.emptyTitle, "下载中心为空")
    XCTAssertEqual(NativeDownloadCenterChrome.terminateAlertTitle, "终止当前下载？")
    XCTAssertEqual(NativeDownloadCenterChrome.terminateAlertConfirmTitle, "终止下载")
    XCTAssertEqual(
      NativeDownloadCenterChrome.summary(totalCount: 8, doneCount: 5, activeCount: 2),
      "8 张 · 已保存 5 · 进行中 2"
    )
    XCTAssertEqual(NativeDownloadCenterChrome.gridColumnCount, 3)
    XCTAssertEqual(NativeDownloadCenterChrome.gridInsets, UIEdgeInsets(top: 8, left: 12, bottom: 24, right: 12))
    XCTAssertEqual(NativeDownloadCenterChrome.gridHorizontalSpacing, 8)
    XCTAssertEqual(NativeDownloadCenterChrome.gridVerticalSpacing, 12)
  }

  func testNativeDownloadCenterBackAlwaysAvailableAndConfirmsTermination() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "final class NativeDownloadListViewController")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "extension NativeDownloadListViewController", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertNil(body.range(of: "pauseDownloadButton"))
    XCTAssertNil(body.range(of: "onPauseDownload"))
    XCTAssertNil(body.range(of: "@objc private func pauseDownloadTapped()"))
    XCTAssertNotNil(body.range(of: "NativeDownloadCenterChrome.terminateAlertTitle"))
    XCTAssertNotNil(body.range(of: "await runtime.stopDownloadAndWait()"))
    XCTAssertNotNil(body.range(of: "backButton.isEnabled = true"))
    XCTAssertNotNil(body.range(of: "backButton.isEnabled = false"))
  }

  func testNativeDownloadCenterTerminationReturnsToGalleryWithoutDisconnectingCamera() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "final class NativeDownloadListViewController")?.lowerBound)
    let confirmation = try XCTUnwrap(source.range(
      of: "alert.addAction(UIAlertAction(title: NativeDownloadCenterChrome.terminateAlertConfirmTitle",
      range: start..<source.endIndex
    )?.lowerBound)
    let confirmationEnd = try XCTUnwrap(source.range(
      of: "    present(alert, animated: true)",
      range: confirmation..<source.endIndex
    )?.lowerBound)
    let confirmationBody = String(source[confirmation..<confirmationEnd])
    XCTAssertNotNil(confirmationBody.range(of: "await runtime.stopDownloadAndWait()"))
    XCTAssertFalse(confirmationBody.contains("navigationController?.popViewController"))
    XCTAssertFalse(confirmationBody.contains("disconnectCamera"))
  }

  func testNativeDownloadCenterDoesNotPopTwiceAfterUserTerminatesTransfer() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "final class NativeDownloadListViewController")?.lowerBound)
    let confirmation = try XCTUnwrap(source.range(
      of: "alert.addAction(UIAlertAction(title: NativeDownloadCenterChrome.terminateAlertConfirmTitle",
      range: start..<source.endIndex
    )?.lowerBound)
    let confirmationEnd = try XCTUnwrap(source.range(
      of: "    present(alert, animated: true)",
      range: confirmation..<source.endIndex
    )?.lowerBound)
    let confirmationBody = String(source[confirmation..<confirmationEnd])
    XCTAssertTrue(confirmationBody.contains("!self.isStoppingForExit"))
    XCTAssertFalse(confirmationBody.contains("navigationController?.popViewController"))

    let handlerStart = try XCTUnwrap(source.range(
      of: "@objc private func downloadStateDidChange()",
      range: start..<source.endIndex
    )?.lowerBound)
    let handlerEnd = try XCTUnwrap(source.range(
      of: "  private func refreshEmptyState()",
      range: handlerStart..<source.endIndex
    )?.lowerBound)
    let handler = String(source[handlerStart..<handlerEnd])
    XCTAssertTrue(handler.contains("navigationController?.topViewController === self"))
    XCTAssertFalse(handler.contains("popViewController"))
  }

  func testNativeDownloadCenterReturnsToGalleryWhenAnActiveRunCompletes() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeGalleryViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "final class NativeDownloadListViewController")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "extension NativeDownloadListViewController", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])
    let handlerStart = try XCTUnwrap(body.range(of: "@objc private func downloadStateDidChange()")?.lowerBound)
    let handlerEnd = try XCTUnwrap(body.range(of: "  private func refreshEmptyState()", range: handlerStart..<body.endIndex)?.lowerBound)
    let handler = String(body[handlerStart..<handlerEnd])
    let backStart = try XCTUnwrap(body.range(of: "@objc private func backTapped()")?.lowerBound)
    let backEnd = try XCTUnwrap(body.range(of: "  @objc private func clearRecordsTapped()", range: backStart..<body.endIndex)?.lowerBound)
    let backBody = String(body[backStart..<backEnd])

    XCTAssertTrue(body.contains("private var hasObservedActiveTransfer = false"))
    XCTAssertTrue(handler.contains("hasObservedActiveTransfer"))
    XCTAssertFalse(handler.contains("popViewController"))
    XCTAssertTrue(backBody.contains("guard isTransferActiveProvider() else"))
    XCTAssertTrue(backBody.contains("navigationController?.popViewController(animated: true)"))
  }

  func testIOSDownloadHistoryPersistsObjectInfoAndThumbnailBytes() throws {
    let record = IOSCameraDownloadHistoryRecord(
      cameraID: "12345678_X-T5",
      objectInfo: IOSCameraObjectInfo(
        handle: 42,
        filename: "DSCF0042.JPG",
        formatLabel: "JPG",
        captureDate: Date(timeIntervalSince1970: 1_800_000_000),
        byteSize: 4_200_000,
        orientation: 6
      ),
      thumbnailBytes: Data([0xFF, 0xD8, 0xFF]),
      completedAt: Date(timeIntervalSince1970: 1_800_000_100)
    )

    let payload = IOSCameraDownloadHistoryPayload(records: [record])
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(IOSCameraDownloadHistoryPayload.self, from: data)

    XCTAssertEqual(decoded.records.first?.objectInfo.filename, "DSCF0042.JPG")
    XCTAssertEqual(decoded.records.first?.objectInfo.orientation, 6)
    XCTAssertEqual(decoded.records.first?.thumbnailBytes, Data([0xFF, 0xD8, 0xFF]))
  }

  func testLegacyConnectionSummaryDoesNotGenerateGuessedWifiCandidates() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "12345678",
      preferredWifiNetwork: nil
    )

    XCTAssertTrue(summary.wifiConfigurations.isEmpty)
  }

  func testLegacyConnectionSummaryKeepsOnlyOfficialWifiCredential() {
    let summary = CameraVendorConnectionSummary(
      deviceName: "X-T5",
      serialNumber: "12345678",
      preferredWifiNetwork: CameraVendorWifiNetworkConfiguration(
        ssid: "FUJIFILM-X-T5-003B",
        passphrase: "camera-secret",
        isHidden: true
      )
    )

    XCTAssertEqual(summary.wifiConfigurations.count, 1)
    XCTAssertEqual(summary.wifiConfigurations.first?.ssid, "FUJIFILM-X-T5-003B")
    XCTAssertEqual(summary.wifiConfigurations.first?.passphrase, "camera-secret")
  }

  func testLegacyPoliciesDisablePairingAutoGalleryAndPartialThumbnailFallback() {
    XCTAssertFalse(
      IOSCameraTransferFlowDriver.canBeginRememberedGalleryEntry(
        hasCompletedPairing: true,
        hasUserInitiatedTransfer: false
      )
    )
    XCTAssertFalse(CameraVendorThumbnailFetchPolicy.shouldUsePartialPreviewFallback)
  }

  private func ptpString(_ string: String) -> Data {
    var data = Data([UInt8(string.count + 1)])
    for scalar in string.unicodeScalars {
      let value = UInt16(scalar.value)
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
    }
    data.append(0)
    data.append(0)
    return data
  }

  private func jpegDataWithExifOrientation(_ orientation: CGImagePropertyOrientation) throws -> Data {
    let image = solidImage(size: CGSize(width: 16, height: 12), fill: .red)
    let output = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
      output,
      "public.jpeg" as CFString,
      1,
      nil
    ))
    CGImageDestinationAddImage(
      destination,
      try XCTUnwrap(image.cgImage),
      [kCGImagePropertyOrientation as String: orientation.rawValue] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return output as Data
  }

  private func jpegData(size: CGSize, fill: UIColor) throws -> Data {
    let image = solidImage(size: size, fill: fill)
    return try XCTUnwrap(image.jpegData(compressionQuality: 1))
  }

  private func solidImage(size: CGSize, fill: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: size).image { context in
      fill.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }

  private func dominantRedValue(in image: UIImage) throws -> Int {
    let cgImage = try XCTUnwrap(image.cgImage)
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var redTotal = 0
    var sampleCount = 0
    stride(from: 0, to: pixels.count, by: bytesPerPixel).forEach { offset in
      redTotal += Int(pixels[offset])
      sampleCount += 1
    }
    return redTotal / max(sampleCount, 1)
  }

  func testGalleryFilterStorePersistsIndependentlyPerCamera() throws {
    let suiteName = "RunnerTests.CameraGalleryFilterStateStore.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = CameraGalleryFilterStateStore(defaults: defaults)
    let firstCamera = CameraSessionIdentity(cameraName: "X-T5", historyKey: "serial-a")
    let secondCamera = CameraSessionIdentity(cameraName: "X-T5", historyKey: "serial-b")
    let firstState = CameraGalleryFilterIntent(
      rule: CameraMediaFilterRule(
        formats: .selected([.raw]),
        date: .today,
        downloadScope: .notDownloaded
      ),
      sort: .oldest
    )

    store.save(firstState, for: firstCamera)

    XCTAssertEqual(store.load(for: firstCamera), firstState)
    XCTAssertEqual(store.load(for: secondCamera), .all)
  }

  @MainActor
  func testGallerySessionRestoresAllDefaultsForANewCamera() async throws {
    let suiteName = "RunnerTests.CameraGallerySession.Defaults.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let session = CameraGallerySession(
      identity: CameraSessionIdentity(cameraName: "new-camera", historyKey: "new-serial"),
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch),
      filterStore: CameraGalleryFilterStateStore(defaults: defaults),
      downloadedHandles: { [] },
      fetchPreview: { _ in throw CancellationError() }
    )

    await session.enter()

    XCTAssertEqual(session.filterIntent, .all)
    XCTAssertEqual(session.presentation.intent, .all)
    await session.invalidate()
  }

  @MainActor
  func testGallerySessionExplicitReloadClearsSessionMembershipCache() async throws {
    let suiteName = "RunnerTests.CameraGallerySession.Reload.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let session = CameraGallerySession(
      identity: CameraSessionIdentity(cameraName: "X-T5", historyKey: "reload-serial"),
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch),
      filterStore: CameraGalleryFilterStateStore(defaults: defaults),
      downloadedHandles: { [] },
      fetchPreview: { _ in throw CancellationError() }
    )

    await session.enter()
    for _ in 0..<1_000 where session.presentation.items.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(source.initialCatalogRequestCount, 1)
    await session.reload()
    for _ in 0..<1_000 where source.initialCatalogRequestCount < 2 {
      await Task.yield()
    }

    XCTAssertEqual(source.initialCatalogRequestCount, 2)
    await session.invalidate()
  }

  func testGallerySessionOwnsGalleryCatalogWithoutReadingQuickDownloadState() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let sessionSource = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraGallerySession.swift")
    )
    let catalogRuntimeSource = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraGalleryCatalogRuntime.swift")
    )
    let controllerSource = try String(
      contentsOf: runner.appendingPathComponent("NativeGalleryViewController.swift")
    )

    XCTAssertTrue(sessionSource.contains("private let catalogRuntime: CameraGalleryCatalogRuntime"))
    XCTAssertTrue(catalogRuntimeSource.contains("private let thumbnailPipeline: CameraGalleryThumbnailPipeline"))
    XCTAssertTrue(sessionSource.contains("private let hdPreviewPipeline: CameraGalleryHDPreviewPipeline"))
    XCTAssertFalse(sessionSource.contains("QuickDownload"))
    XCTAssertFalse(controllerSource.contains("CameraGalleryCatalogRuntime("))
    XCTAssertFalse(controllerSource.contains("CameraGalleryHDPreviewPipeline("))
  }

  func testRuntimeOwnsSharedQueryEngineIndependentOfGallerySession() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let runtimeSource = try String(
      contentsOf: runner.appendingPathComponent("CameraSessionRuntime.swift")
    )
    let sessionSource = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraGallerySession.swift")
    )

    XCTAssertTrue(runtimeSource.contains("private var catalogQueryEngine: CameraCatalogQueryEngine?"))
    XCTAssertTrue(runtimeSource.contains("CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch)"))
    XCTAssertTrue(runtimeSource.contains("queryEngine: queryEngine"))
    XCTAssertTrue(runtimeSource.contains("let resolution = try await queryEngine.resolve("))
    XCTAssertTrue(sessionSource.contains("queryEngine: CameraCatalogQueryEngine"))
    XCTAssertFalse(sessionSource.contains("CameraCatalogQueryEngine(source:"))
    XCTAssertFalse(sessionSource.contains("await queryEngine.invalidate()"))
  }

  @MainActor
  func testGallerySessionSwitchesFilterWithLatestGenerationOnly() async throws {
    let suiteName = "RunnerTests.CameraGallerySession.Generation.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let session = CameraGallerySession(
      identity: CameraSessionIdentity(cameraName: "X-T5", historyKey: "serial"),
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch),
      filterStore: CameraGalleryFilterStateStore(defaults: defaults),
      downloadedHandles: { [] },
      fetchPreview: { _ in throw CancellationError() }
    )
    await session.enter()
    source.suspendsCatalogRequests = true
    var readyFormats: [CameraGalleryFormatIntent] = []
    let observerID = session.observePresentation { presentation in
      if case .ready = presentation.state, presentation.intent.format != .all {
        readyFormats.append(presentation.intent.format)
      }
    }

    let jpg = CameraGalleryFilterIntent(date: .all, format: .jpg, sort: .newest, downloadStatus: .all)
    let raw = CameraGalleryFilterIntent(date: .all, format: .raw, sort: .newest, downloadStatus: .all)
    await session.submitFilter(jpg)
    await source.waitForCatalogRequestCount(1)
    await session.submitFilter(raw)
    source.resolveCatalogRequest(at: 0, snapshot: .fixture(handles: [1]))
    await source.waitForCatalogRequestCount(2)
    source.resolveCatalogRequest(at: 1, snapshot: .fixture(handles: [9, 8]))
    for _ in 0..<1_000 where session.presentation.items.map(\.handle) != [9, 8] {
      await Task.yield()
    }

    XCTAssertEqual(readyFormats, [.raw])
    XCTAssertEqual(session.presentation.items.map(\.handle), [9, 8])
    session.removeObserver(observerID)
    await session.invalidate()
  }

  func testGalleryExitInvalidatesCatalogAndBothPreviewPipelines() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let sessionSource = try String(
      contentsOf: runner.appendingPathComponent("CameraCore/Gallery/CameraGallerySession.swift")
    )
    let runtimeSource = try String(
      contentsOf: runner.appendingPathComponent("CameraSessionRuntime.swift")
    )
    let invalidateStart = try XCTUnwrap(sessionSource.range(of: "func invalidate() async")?.lowerBound)
    let invalidateBody = String(sessionSource[invalidateStart...])

    XCTAssertTrue(invalidateBody.contains("await catalogRuntime.cancelAllChildren()"))
    XCTAssertFalse(invalidateBody.contains("thumbnailPipeline"))
    XCTAssertTrue(invalidateBody.contains("await hdPreviewPipeline.invalidateSession()"))
    let exitStart = try XCTUnwrap(runtimeSource.range(of: "func exitGalleryAndDisconnect(reason: String)")?.lowerBound)
    let exitBody = String(runtimeSource[exitStart...])
    XCTAssertTrue(exitBody.contains("terminateCatalogSession(reason: reason)"))
    let terminationStart = try XCTUnwrap(
      runtimeSource.range(of: "private func beginCatalogSessionTermination(reason: String)")?.lowerBound
    )
    let terminationBody = String(runtimeSource[terminationStart..<exitStart])
    let fenceCall = try XCTUnwrap(terminationBody.range(of: "previousGenerationFence?.invalidate()"))
    let invalidateCall = try XCTUnwrap(terminationBody.range(of: "await previousSession?.invalidate()"))
    let lifecycleJoin = try XCTUnwrap(terminationBody.range(of: "await previousLifecycleTask?.value"))
    let terminateCall = try XCTUnwrap(
      terminationBody.range(of: "transport.terminateCameraCommunication(reason: reason)")
    )
    XCTAssertLessThan(fenceCall.lowerBound, terminateCall.lowerBound)
    XCTAssertLessThan(terminateCall.lowerBound, invalidateCall.lowerBound)
    XCTAssertLessThan(terminateCall.lowerBound, lifecycleJoin.lowerBound)
  }

  @MainActor
  func testInvalidatedGalleryGenerationFenceRejectsFurtherPhysicalCommands() async {
    let transport = CameraSessionRuntimeSpy()
    let fence = CameraSessionGenerationFence()
    let source = CameraSessionGalleryCatalogRuntimeSource(
      transport: transport,
      generationFence: fence
    )

    fence.invalidate()

    do {
      _ = try await source.loadThumbnail(handle: 101)
      XCTFail("An invalidated gallery generation must reject physical camera work")
    } catch is CancellationError {
      // Expected: the old generation is fenced before it can touch the transport.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    XCTAssertEqual(transport.thumbnailHandles, [])
  }

  private func fixedDate() -> Date {
    Date(timeIntervalSince1970: 1_800_000_000)
  }

  private func expiredTrialStartDate() -> Date {
    fixedDate().addingTimeInterval(-8 * 24 * 60 * 60)
  }

  @MainActor
  private func waitForRuntimeGalleryReady(
    _ runtime: CameraSessionRuntime,
    timeout: TimeInterval = 1
  ) async {
    guard runtime.presentation.phase != .galleryReady else { return }
    let ready = expectation(description: "runtime initial catalog ready")
    var didFulfill = false
    let observerID = runtime.observe { presentation in
      guard !didFulfill, presentation.phase == .galleryReady else { return }
      didFulfill = true
      ready.fulfill()
    }
    await fulfillment(of: [ready], timeout: timeout)
    runtime.removeObserver(observerID)
  }

  @MainActor
  private func waitForRuntimePhase(
    _ runtime: CameraSessionRuntime,
    _ phase: CameraSessionPhase,
    timeout _: TimeInterval = 1
  ) async {
    for _ in 0..<1_000 where runtime.presentation.phase != phase {
      await Task.yield()
    }
    XCTAssertEqual(runtime.presentation.phase, phase)
  }

  @MainActor
  private func waitForRuntimeInFlight(
    _ runtime: CameraSessionRuntime,
    timeout _: TimeInterval = 1
  ) async {
    for _ in 0..<1_000 where runtime.presentation.inFlightHandle == nil {
      await Task.yield()
    }
    XCTAssertNotNil(runtime.presentation.inFlightHandle)
  }

  @MainActor
  private func waitForStartedHandleCount(
    _ count: Int,
    transport: CameraSessionRuntimeSpy
  ) async {
    for _ in 0..<10_000 where transport.startedHandles.count < count {
      await Task.yield()
    }
    XCTAssertEqual(transport.startedHandles.count, count)
  }

  private func galleryItem(handle: Int, formatLabel: String) -> CameraVendorGalleryItem {
    CameraVendorGalleryItem(
      handle: handle,
      filename: "DSCF\(String(format: "%04d", handle)).\(formatLabel.lowercased())",
      formatLabel: formatLabel,
      captureDate: "2026:05:17 10:00:00",
      byteSizeText: "1.0 MB"
    )
  }

  func testRuntimeUsesOneSubmissionAPIForManualQuickAndRecoveryDownloads() throws {
    let runner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let runtimeSource = try String(contentsOf: runner.appendingPathComponent("CameraSessionRuntime.swift"))
    let gallerySource = try String(contentsOf: runner.appendingPathComponent("NativeGalleryViewController.swift"))
    let quickSource = try String(contentsOf: runner.appendingPathComponent("QuickDownloadUseCase.swift"))

    XCTAssertTrue(runtimeSource.contains("func submitDownload(_ submission: CameraDownloadSubmission)"))
    XCTAssertTrue(gallerySource.contains("runtime.submitDownload("))
    XCTAssertTrue(gallerySource.contains("origin: .gallery"))
    XCTAssertTrue(quickSource.contains("runtime.submitDownload("))
    XCTAssertTrue(quickSource.contains("origin: .quickDownload"))
    XCTAssertTrue(runtimeSource.contains("origin: .recovery"))
    XCTAssertFalse(gallerySource.contains(".startDownloadRequests("))
    XCTAssertFalse(quickSource.contains(".startDownload("))
  }

  @MainActor
  func testQuickDownloadUseCaseRoutesNoMatchWithoutStartingDownload() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination { routedHome = true }
    }
    let rule = CameraAutoDownloadRule(
      isEnabled: true,
      filter: .quickDownloadDefault,
      downloadMode: .original,
      disconnectAfterDownload: true
    )

    let result = await QuickDownloadUseCase(runtime: runtime).execute(rule: rule)

    XCTAssertEqual(result, .noMatch(ruleSummary: rule.summaryText))
    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(runtime.presentation.phase, .idle)
    XCTAssertTrue(routedHome)
  }

  @MainActor
  func testQuickDownloadFailureRoutesByDisconnectCompletionPolicy() async throws {
    for disconnectAfterDownload in [false, true] {
      let flow = CameraSessionRuntimeConnectionFlowSpy()
      let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
      let transport = CameraSessionRuntimeSpy()
      let runtime = CameraSessionRuntime(
        transport: transport,
        connectionWorker: worker,
        gallerySessionActivator: CameraSessionRuntimeGallerySessionActivatorSpy()
      )
      let connected = expectation(description: "gallery connected")
      runtime.startRememberedGalleryConnection(
        record: CameraSessionRuntimeConnectionFlowSpy.record
      ) { state in
        guard case .galleryReady = state else {
          XCTFail("Expected GalleryReady before Quick query failure")
          return
        }
        connected.fulfill()
      }
      await flow.waitUntilRememberedGalleryStarts()
      flow.finishRememberedGallery()
      await fulfillment(of: [connected], timeout: 1)

      var routedDestinations: [CameraSessionRuntimePresentationDestination] = []
      runtime.onPresentationDestinationReady = { routedDestinations.append($0) }
      transport.catalogError = NSError(
        domain: "RunnerTests.QuickDownloadQuery",
        code: 1
      )
      let rule = CameraAutoDownloadRule(
        isEnabled: true,
        filter: .quickDownloadDefault,
        downloadMode: .original,
        disconnectAfterDownload: disconnectAfterDownload
      )

      let result = await QuickDownloadUseCase(runtime: runtime).execute(rule: rule)
      for _ in 0..<1_000 where routedDestinations.isEmpty {
        await Task.yield()
      }

      XCTAssertEqual(result, .failed(reason: "自动下载失败：相册加载失败"))
      if disconnectAfterDownload {
        XCTAssertEqual(runtime.presentation.phase, .idle)
        XCTAssertEqual(transport.terminateCount, 1)
        XCTAssertTrue(routedDestinations.contains { if case .home = $0 { return true }; return false })
      } else {
        XCTAssertEqual(runtime.presentation.phase, .galleryReady)
        XCTAssertEqual(transport.terminateCount, 0)
        XCTAssertTrue(routedDestinations.contains { if case .gallery = $0 { return true }; return false })
      }
    }
  }

  @MainActor
  func testDisconnectToHomePublishesOnlyAfterCameraTermination() async throws {
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 101, formatLabel: "JPG")]
    transport.suspendsThumbnailRequestsUntilReleased = true
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [101])
    await transport.waitForThumbnailRequestCount(1)
    for _ in 0..<20 { await Task.yield() }

    var terminalEvents: [String] = []
    transport.onTerminate = { terminalEvents.append("terminate") }
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination { terminalEvents.append("home") }
    }

    let routingTask = Task { @MainActor in
      await runtime.routeQuickDownloadNoMatch(completionPolicy: .disconnectToHome)
    }
    for _ in 0..<20 { await Task.yield() }

    XCTAssertEqual(terminalEvents, ["terminate", "home"])
    XCTAssertEqual(transport.terminateCount, 1)

    transport.releaseThumbnailRequests()
    let didRoute = await routingTask.value
    XCTAssertTrue(didRoute)
    XCTAssertEqual(terminalEvents, ["terminate", "home"])
  }

  @MainActor
  func testGalleryExitStillTerminatesAReplacementTransportBeforeCatalogInstallation() async {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "old-session")))
    await waitForRuntimeGalleryReady(runtime)

    runtime.exitGalleryAndDisconnect(reason: "old-session-exit")
    XCTAssertEqual(transport.terminateCount, 1)

    _ = runtime.beginTransportBinding(identity: CameraSessionIdentity(cameraName: "replacement"))
    runtime.exitGalleryAndDisconnect(reason: "replacement-exit-before-catalog")

    XCTAssertEqual(transport.terminateCount, 2)
  }

  @MainActor
  func testStaleGuardedGalleryExitCannotTerminateReplacementTransport() async {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    let oldBinding = runtime.beginTransportBinding(
      identity: CameraSessionIdentity(cameraName: "old-session")
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "old-session")))
    await waitForRuntimeGalleryReady(runtime)

    let replacementBinding = runtime.beginTransportBinding(
      identity: CameraSessionIdentity(cameraName: "replacement")
    )

    XCTAssertFalse(runtime.exitGalleryAndDisconnect(
      reason: "stale-overlay-cancel",
      expectedBinding: oldBinding
    ))
    XCTAssertEqual(transport.terminateCount, 0)
    XCTAssertTrue(runtime.acceptsTransportCallback(replacementBinding))

    XCTAssertTrue(runtime.exitGalleryAndDisconnect(
      reason: "current-overlay-cancel",
      expectedBinding: replacementBinding
    ))
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testRuntimeRejectsOverlappingDownloadBatch() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)

    XCTAssertTrue(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [
        CameraSessionQueuedDownload(handle: 101, mode: .original),
        CameraSessionQueuedDownload(handle: 101, mode: .compressed),
        CameraSessionQueuedDownload(handle: 102, mode: .original),
      ],
      origin: .gallery,
      completionPolicy: .returnToGallery
    )))
    XCTAssertFalse(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 201, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    )))

    await waitForStartedHandleCount(1, transport: transport)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
    XCTAssertEqual(transport.startedHandles, [101])
  }

  @MainActor
  func testRuntimeAllowsExplicitRedownloadOfSavedHandles() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      savedHandleStore: CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101])
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)

    XCTAssertEqual(runtime.downloadState(for: 101), .saved)
    XCTAssertTrue(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .gallery,
      completionPolicy: .returnToGallery
    )))

    await waitForStartedHandleCount(1, transport: transport)
    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(runtime.downloadState(for: 101), .downloading)
  }

  @MainActor
  func testManualDownloadTerminalReturnsGalleryReadyWithoutDisconnect() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .gallery,
      completionPolicy: .returnToGallery
    ))

    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(transport.terminateCount, 0)
  }

  @MainActor
  func testQuickDownloadTerminalRoutesByDisconnectCompletionPolicy() async throws {
    let keepTransport = CameraSessionRuntimeSpy()
    let keepRuntime = CameraSessionRuntime(transport: keepTransport)
    keepRuntime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(keepRuntime)
    keepRuntime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .returnToGallery
    ))
    await waitForStartedHandleCount(1, transport: keepTransport)
    keepRuntime.send(.transferFinished(handle: 101))

    XCTAssertEqual(keepRuntime.presentation.phase, .galleryReady)
    XCTAssertEqual(keepTransport.terminateCount, 0)

    let disconnectTransport = CameraSessionRuntimeSpy()
    let disconnectRuntime = CameraSessionRuntime(transport: disconnectTransport)
    disconnectRuntime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(disconnectRuntime)
    var routedHome = false
    disconnectRuntime.onPresentationDestinationReady = { destination in
      if case .home = destination { routedHome = true }
    }
    disconnectRuntime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 201, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    ))
    await waitForStartedHandleCount(1, transport: disconnectTransport)
    disconnectRuntime.send(.transferFinished(handle: 201))
    for _ in 0..<1_000 where !routedHome { await Task.yield() }

    XCTAssertEqual(disconnectRuntime.presentation.phase, .idle)
    XCTAssertTrue(routedHome)
  }

  @MainActor
  func testQuickDownloadCancellationRoutesByDisconnectCompletionPolicy() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination { routedHome = true }
    }
    runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    ))

    await runtime.stopDownloadAndWait()

    // User-initiated stop always returns to gallery, even for quick download
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertFalse(routedHome)
  }

  @MainActor
  func testCameraSessionRuntimeGalleryDetachmentDoesNotCancelHealthyDownload() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    runtime.send(.galleryPresentationDetached)

    XCTAssertEqual(runtime.presentation.phase, .downloadingForeground)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
    XCTAssertEqual(transport.terminateCount, 0)
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotPublishGalleryReadyBeforeInitialCatalogInstalls() {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))

    XCTAssertEqual(runtime.presentation.phase, .galleryLoading)
    XCTAssertEqual(runtime.presentation.catalog.state, .unavailable)
  }

  @MainActor
  func testCameraSessionRuntimePublishesGalleryReadyAfterInitialCatalogInstalls() async {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    let ready = expectation(description: "initial catalog installed")
    var didObserveReady = false
    runtime.observe { presentation in
      guard !didObserveReady, presentation.phase == .galleryReady else { return }
      didObserveReady = true
      ready.fulfill()
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))

    await fulfillment(of: [ready], timeout: 1)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    guard case .ready = runtime.presentation.catalog.state else {
      return XCTFail("Initial validated catalog must publish ready")
    }
  }

  @MainActor
  func testCameraSessionRuntimeJoinsSupersededCatalogBeforeStartingReplacement() async {
    let transport = CameraSessionRuntimeSpy()
    transport.suspendsCatalogRequests = true
    let runtime = CameraSessionRuntime(transport: transport)
    let replacementReady = expectation(description: "replacement catalog ready")
    var didObserveReplacementReady = false
    runtime.observe { presentation in
      guard !didObserveReplacementReady,
            presentation.phase == .galleryReady,
            presentation.catalog.items.map(\.handle) == [222] else { return }
      didObserveReplacementReady = true
      replacementReady.fulfill()
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "old-session")))
    await transport.waitForInitialCatalogRequestCount(1)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "new-session")))
    for _ in 0..<20 {
      await Task.yield()
    }
    let requestCountBeforeOldCatalogReturns = transport.initialCatalogRequestCount

    transport.resolveInitialCatalogRequest(at: 0, items: [galleryItem(handle: 111, formatLabel: "JPG")])
    await transport.waitForInitialCatalogRequestCount(2)

    XCTAssertEqual(
      requestCountBeforeOldCatalogReturns,
      1,
      "Replacement catalog must wait for the superseded actor to finish its active transaction"
    )
    XCTAssertEqual(runtime.presentation.phase, .galleryLoading)
    XCTAssertEqual(
      runtime.presentation.catalog.items,
      [],
      "The superseded actor must not publish its catalog into the replacement session"
    )

    transport.resolveInitialCatalogRequest(at: 1, items: [galleryItem(handle: 222, formatLabel: "JPG")])
    await fulfillment(of: [replacementReady], timeout: 1)
    XCTAssertEqual(runtime.activeCameraIdentity?.cameraName, "new-session")
    XCTAssertEqual(runtime.presentation.catalog.items.map(\.handle), [222])
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotPublishLiveActivityForGalleryReadySession() throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      activityReporter: activityReporter
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    XCTAssertTrue(activityReporter.snapshots.isEmpty)
  }

  @MainActor
  func testCameraSessionRuntimePublishesDownloadProgressAndKeepsActivityAfterGalleryDetaches() async throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      activityReporter: activityReporter
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    let gallerySessionID = try XCTUnwrap(activityReporter.snapshots.last?.sessionID)
    runtime.send(.galleryPresentationDetached)
    runtime.send(.transferFinished(handle: 101))

    let activity = try XCTUnwrap(activityReporter.snapshots.last)
    XCTAssertEqual(activity.sessionID, gallerySessionID)
    XCTAssertEqual(activity.downloadCompletedCount, 1)
    XCTAssertEqual(activity.downloadTotalCount, 2)
    XCTAssertTrue(activity.isShowingDownloadProgress)
    XCTAssertTrue(activityReporter.endedSessionIDs.isEmpty)
  }

  @MainActor
  func testCameraSessionRuntimeClearsStaleLiveActivityWhileRestoringRecoverableQueue() throws {
    let sessionID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: sessionID,
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 102, mode: .original)],
        inFlightHandle: 102,
        completedCount: 2,
        failedCount: 1,
        updatedAt: Date()
      )
    )
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore,
      activityReporter: activityReporter
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertTrue(activityReporter.snapshots.isEmpty)
    XCTAssertEqual(
      activityReporter.staleCleanupReasons,
      ["restore-persisted-download-awaiting-execution"]
    )
  }

  @MainActor
  func testCameraSessionRuntimeCleansStaleLiveActivityWithoutRecoverableSnapshot() throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      activityReporter: activityReporter
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertEqual(activityReporter.staleCleanupReasons, ["no-persisted-recovery"])
  }

  @MainActor
  func testCameraSessionRuntimeEndsLiveActivityOnlyForTerminalDownloadCommands() async throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      activityReporter: activityReporter
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    let sessionID = try XCTUnwrap(activityReporter.snapshots.last?.sessionID)
    runtime.send(.cancelDownloadByUser)
    runtime.send(.transferCancelled(handle: 101))

    XCTAssertEqual(activityReporter.endedSessionIDs, [sessionID])
  }

  @MainActor
  func testCameraSessionRuntimeEndsLiveActivityWhenDownloadCompletes() async throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      activityReporter: activityReporter
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    let sessionID = try XCTUnwrap(activityReporter.snapshots.last?.sessionID)

    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(activityReporter.endedSessionIDs, [sessionID])
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testCameraSessionRuntimeEndsLiveActivityWhenExecutionBecomesRecoverable() async throws {
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority,
      activityReporter: activityReporter
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    let sessionID = try XCTUnwrap(activityReporter.snapshots.last?.sessionID)

    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)

    XCTAssertEqual(activityReporter.endedSessionIDs, [sessionID])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
  }

  @MainActor
  func testCameraSessionRuntimeUserCancellationStopsQueueWithoutDisconnectingHealthyCamera() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.cancelDownloadByUser)

    XCTAssertEqual(runtime.presentation.phase, .cancelling)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(transport.terminateCount, 0)

    runtime.send(.transferCancelled(handle: 101))

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
  }

  @MainActor
  func testCameraSessionRuntimeStopDownloadAndWaitJoinsCancelledTransfer() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    var didReturn = false
    let stopTask = Task { @MainActor in
      await runtime.stopDownloadAndWait()
      didReturn = true
    }
    for _ in 0..<100 where runtime.presentation.phase != .cancelling {
      await Task.yield()
    }
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertEqual(runtime.presentation.phase, .cancelling)
    XCTAssertFalse(didReturn)
    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(transport.terminateCount, 0)

    runtime.send(.transferCancelled(handle: 101))
    await stopTask.value

    XCTAssertTrue(didReturn)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(transport.terminateCount, 0)
  }

  @MainActor
  func testCameraSessionRuntimeStopDownloadAndWaitReturnsImmediatelyWhenIdle() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)

    await runtime.stopDownloadAndWait()

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(transport.cancelActiveTransferCount, 0)
    XCTAssertEqual(transport.terminateCount, 0)
  }

  @MainActor
  func testCameraSessionRuntimeDrainsCancelledTransferBeforeAcceptingAnotherQueue() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    runtime.send(.cancelDownloadByUser)
    runtime.send(.startDownload(handles: [201], mode: .original))

    XCTAssertEqual(runtime.presentation.phase, .cancelling)
    XCTAssertEqual(transport.startedHandles, [101])

    runtime.send(.transferCancelled(handle: 101))
    runtime.send(.startDownload(handles: [201], mode: .original))
    await waitForStartedHandleCount(2, transport: transport)

    XCTAssertEqual(runtime.presentation.phase, .downloadingForeground)
    XCTAssertEqual(transport.startedHandles, [101, 201])
  }

  @MainActor
  func testCameraSessionRuntimeCancelsQueuedWorkWithoutInFlightTransferDuringBackgroundTransition() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationWillResignActive)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertNil(runtime.presentation.inFlightHandle)
    XCTAssertEqual(runtime.presentation.queuedHandles, [102])

    runtime.send(.cancelDownloadByUser)

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
    XCTAssertEqual(transport.cancelActiveTransferCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 1)
    XCTAssertEqual(executionAuthority.releaseCount, 1)
  }

  func testCameraSessionRuntimeTransferCommitGateDoesNotReportCancelledPhotoChangeAsCommitted() {
    let gate = CameraSessionRuntimeTransferCommitGate()

    gate.invalidate()

    XCTAssertFalse(gate.didBeginPhotoLibraryCommit)
  }

  @MainActor
  func testCameraSessionRuntimeHoldsOneExclusiveLeaseAcrossTheWholeQueue() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    XCTAssertEqual(transport.beginDownloadLeaseCount, 1)
    XCTAssertEqual(transport.startedHandles, [101])

    runtime.send(.transferFinished(handle: 101))
    XCTAssertEqual(transport.startedHandles, [101, 102])
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)

    runtime.send(.transferFinished(handle: 102))
    XCTAssertEqual(transport.endDownloadLeaseCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotStartDownloadUntilGalleryChildrenHaveJoined() async throws {
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3, 2, 1].map {
      galleryItem(handle: $0, formatLabel: "JPG")
    }
    transport.suspendsThumbnailRequestsUntilReleased = true
    let childCancelled = expectation(description: "gallery child cancelled before download admission")
    transport.onThumbnailRequestCancelled = {
      childCancelled.fulfill()
    }
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3])
    await transport.waitForThumbnailRequestCount(1)

    runtime.send(.startDownload(handles: [101], mode: .original))

    XCTAssertEqual(
      transport.startedHandles,
      [],
      "Download admission must not mint an exclusive token while a Gallery child is still active"
    )
    await fulfillment(of: [childCancelled], timeout: 1)
    XCTAssertEqual(transport.startedHandles, [])

    transport.releaseThumbnailRequests()
    for _ in 0..<100 where transport.startedHandles.isEmpty {
      await Task.yield()
    }
    XCTAssertEqual(transport.startedHandles, [101])
  }

  @MainActor
  func testCameraSessionRuntimeAdmissionUsesBackgroundPhaseWhenAppEntersBackgroundBeforeJoin() async throws {
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3].map { galleryItem(handle: $0, formatLabel: "JPG") }
    transport.suspendsThumbnailRequestsUntilReleased = true
    let childCancelled = expectation(description: "gallery child cancelled before background admission")
    transport.onThumbnailRequestCancelled = {
      childCancelled.fulfill()
    }
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy()
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3])
    await transport.waitForThumbnailRequestCount(1)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await fulfillment(of: [childCancelled], timeout: 1)

    runtime.send(.applicationWillResignActive)
    runtime.send(.applicationEnteredBackground)
    transport.releaseThumbnailRequests()
    for _ in 0..<100 where transport.startedHandles.isEmpty {
      await Task.yield()
    }

    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(runtime.presentation.phase, .downloadingBackground)
  }

  @MainActor
  func testCameraSessionRuntimeExpirationPersistsRecoverableOnceAndStopsTransfer() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)
    runtime.send(.backgroundExecutionExpired)

    XCTAssertEqual(recoveryStore.records.count, 1)
    XCTAssertEqual(recoveryStore.records.first?.handles, [101, 102])
    XCTAssertEqual(recoveryStore.records.first?.inFlightHandle, 101)
    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotClaimRecoverableWhenRecoveryPersistenceFails() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeNonPersistingRecoveryStore()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)

    XCTAssertEqual(recoveryStore.persistAttempts, 1)
    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .interrupted)
    XCTAssertEqual(runtime.downloadState(for: 101), .failed("无法保存下载恢复状态"))
  }

  @MainActor
  func testCameraSessionRuntimeRecoveryOverlayCancellationFallsBackWhenPersistenceFailed() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeNonPersistingRecoveryStore()
    let recoveryConnector = CameraSessionRuntimeRecoveryConnectorSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority,
      recoveryConnector: recoveryConnector
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)

    XCTAssertEqual(runtime.presentation.phase, .interrupted)
    XCTAssertFalse(runtime.cancelRecoveredDownloadFromConnectionOverlay())
    XCTAssertEqual(recoveryConnector.cancelledReasons, [])
  }

  @MainActor
  func testCameraSessionRuntimeTransportFailureUsesTheSameRecoveryTransaction() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let runtime = CameraSessionRuntime(transport: transport, recoveryStore: recoveryStore)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))

    for _ in 0..<100 where runtime.presentation.phase != .recovering {
      await Task.yield()
    }

    XCTAssertEqual(recoveryStore.records.count, 1)
    XCTAssertEqual(recoveryStore.records.first?.reason, "transport-failed")
    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .recovering)
  }

  @MainActor
  func testCameraSessionRuntimeQuickCancellationDuringTransportFailureCleanupReturnsToGallery() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryConnector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      recoveryConnector: recoveryConnector
    )
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome = true
      }
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    XCTAssertTrue(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    )))
    await waitForStartedHandleCount(1, transport: transport)

    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))
    await runtime.stopDownloadAndWait()

    // User-initiated stop returns to the gallery UI, but a transport-failed
    // session must reconnect before catalog/preview commands are admitted.
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
    XCTAssertFalse(routedHome)
    XCTAssertEqual(recoveryConnector.requestedIdentities.map(\.cameraName), ["X-T5"])
  }

  @MainActor
  func testCameraSessionRuntimeStopDownloadForcesTransportShutdownAfterSoftCancelGracePeriod() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryConnector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      recoveryConnector: recoveryConnector,
      userCancellationHardInterruptDelayNanoseconds: 1_000_000
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    await runtime.stopDownloadAndWait()

    XCTAssertEqual(
      transport.cancelActiveTransferReasons,
      ["user-cancelled-download", "user-cancelled-download-timeout"]
    )
    XCTAssertEqual(transport.terminateCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
    XCTAssertEqual(recoveryConnector.requestedIdentities.map(\.cameraName), ["X-T5"])
  }

  @MainActor
  func testCameraSessionRuntimeTransportFailureDuringAdmissionNeverMintsDownloadLease() async throws {
    let childCancelled = expectation(description: "catalog child cancellation observed")
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3, 2, 1].map {
      galleryItem(handle: $0, formatLabel: "JPG")
    }
    transport.suspendsThumbnailRequestsUntilReleased = true
    transport.onThumbnailRequestCancelled = {
      childCancelled.fulfill()
    }
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy()
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3, 2, 1])
    await transport.waitForThumbnailRequestCount(1)
    runtime.send(.startDownload(handles: [101], mode: .original))
    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)

    runtime.send(.transportFailed(NSError(
      domain: "PTPTransport",
      code: 54,
      userInfo: [NSLocalizedDescriptionKey: "connection reset by peer"]
    )))

    await fulfillment(of: [childCancelled], timeout: 1)
    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    XCTAssertEqual(runtime.presentation.phase, .recovering)

    transport.releaseThumbnailRequests()
    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(transport.cancelActiveTransferCount, 1)
    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
  }

  @MainActor
  func testCameraSessionRuntimeUserCancellationAfterAdmissionFailureDoesNotReleaseUnownedLease() async throws {
    let childCancelled = expectation(description: "catalog child cancellation observed")
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3].map { galleryItem(handle: $0, formatLabel: "JPG") }
    transport.suspendsThumbnailRequestsUntilReleased = true
    transport.onThumbnailRequestCancelled = { childCancelled.fulfill() }
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy()
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3])
    await transport.waitForThumbnailRequestCount(1)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.transportFailed(NSError(domain: "PTPTransport", code: 54)))
    await fulfillment(of: [childCancelled], timeout: 1)

    runtime.send(.cancelDownloadByUser)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    transport.releaseThumbnailRequests()
    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
  }

  @MainActor
  func testCameraSessionRuntimeStopDownloadAndWaitReturnsAfterAdmissionFailure() async throws {
    let childCancelled = expectation(description: "catalog child cancellation observed")
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3].map { galleryItem(handle: $0, formatLabel: "JPG") }
    transport.suspendsThumbnailRequestsUntilReleased = true
    transport.onThumbnailRequestCancelled = { childCancelled.fulfill() }
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy()
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3])
    await transport.waitForThumbnailRequestCount(1)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.transportFailed(NSError(domain: "PTPTransport", code: 54)))
    await fulfillment(of: [childCancelled], timeout: 1)

    var didReturn = false
    let stopTask = Task { @MainActor in
      await runtime.stopDownloadAndWait()
      didReturn = true
    }
    for _ in 0..<100 where !didReturn { await Task.yield() }
    XCTAssertTrue(didReturn)
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)

    transport.releaseThumbnailRequests()
    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    await stopTask.value
  }

  @MainActor
  func testCameraSessionRuntimeSessionSupersessionDuringAdmissionCannotMintOldLease() async throws {
    let childCancelled = expectation(description: "catalog child cancellation observed")
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [3].map { galleryItem(handle: $0, formatLabel: "JPG") }
    transport.suspendsThumbnailRequestsUntilReleased = true
    transport.onThumbnailRequestCancelled = { childCancelled.fulfill() }
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy()
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.requestVisibleGalleryThumbnails(handles: [3])
    await transport.waitForThumbnailRequestCount(1)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.transportFailed(NSError(domain: "PTPTransport", code: 54)))
    await fulfillment(of: [childCancelled], timeout: 1)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5-new")))
    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    transport.releaseThumbnailRequests()
    for _ in 0..<100 { await Task.yield() }

    XCTAssertEqual(transport.beginDownloadLeaseCount, 0)
    XCTAssertEqual(transport.endDownloadLeaseCount, 0)
    XCTAssertEqual(transport.startedHandles, [])
  }

  @MainActor
  func testCameraSessionRuntimeContinuesQueuedTransferInBackgroundWhileExecutionIsGranted() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.transferFinished(handle: 101))
    await waitForStartedHandleCount(2, transport: transport)

    XCTAssertEqual(executionAuthority.acquireCount, 1)
    XCTAssertEqual(executionAuthority.releaseCount, 0)
    XCTAssertEqual(transport.startedHandles, [101, 102])
    XCTAssertEqual(runtime.presentation.phase, .downloadingBackground)
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotStartNextFileAfterExecutionExpires() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(executionAuthority.releaseCount, 1)
    XCTAssertEqual(recoveryStore.records.count, 1)
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotStartNextFileDuringWillResignActiveWindow() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority
    )
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    runtime.send(.applicationWillResignActive)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(executionAuthority.acquireCount, 1)
    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(runtime.presentation.queuedHandles, [102])
    XCTAssertNil(runtime.presentation.inFlightHandle)

    runtime.send(.applicationEnteredBackground)
    await waitForStartedHandleCount(2, transport: transport)

    XCTAssertEqual(transport.startedHandles, [101, 102])
    XCTAssertEqual(runtime.presentation.phase, .downloadingBackground)
  }

  @MainActor
  func testCameraSessionRuntimePublishesTheSamePresentationToEveryObserver() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    let galleryRecorder = CameraSessionPresentationRecorder()
    let downloadCenterRecorder = CameraSessionPresentationRecorder()
    runtime.observe(galleryRecorder.record)
    runtime.observe(downloadCenterRecorder.record)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))

    XCTAssertEqual(galleryRecorder.presentations, downloadCenterRecorder.presentations)
    XCTAssertEqual(galleryRecorder.presentations.last?.phase, .downloadingForeground)
  }

  @MainActor
  func testCameraSessionRuntimeObserverStartsWithCurrentPresentation() {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    var presentations: [CameraSessionPresentation] = []

    let observerID = runtime.observe { presentation in
      presentations.append(presentation)
    }
    defer { runtime.removeObserver(observerID) }

    XCTAssertEqual(presentations, [.idle])
  }

  @MainActor
  func testCameraSessionRuntimeIncrementalCatalogObserverStartsOnlyAfterContentUpdate() {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    var updatedHandles: [Set<Int>] = []

    let observerID = runtime.observeIncrementalCatalogUpdates { _, delta in
      updatedHandles.append(delta.changedHandles)
    }
    defer { runtime.removeObserver(observerID) }

    XCTAssertTrue(updatedHandles.isEmpty)
  }

  @MainActor
  func testCameraSessionRuntimeTransportTransfersOneFileThenReportsCompletion() async throws {
    let completion = expectation(description: "runtime transport completed")
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver,
      onTransferFinished: { handle in
        XCTAssertEqual(handle, 101)
        completion.fulfill()
      },
      onTransportFailed: { error in
        XCTFail("Unexpected transport failure: \(error)")
      }
    )

    transport.startTransfer(handle: 101, mode: .original)
    await fulfillment(of: [completion], timeout: 1)

    XCTAssertEqual(galleryService.requestedHandles, [101])
    XCTAssertEqual(fileSaver.savedFilenames, ["DSCF101.RAF"])
  }

  @MainActor
  func testRuntimeTransportEmitsOneOriginalDownloadTimingAfterPhotoSave() async throws {
    let saveCommitted = expectation(description: "photo save committed")
    let timingEmitted = expectation(description: "end-to-end timing emitted")
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    galleryService.downloadedFileTransferTiming = CameraVendorOriginalFileTransferTiming(
      byteCount: 86_801_408,
      prepareMs: 310,
      requestToFirstByteMs: 221,
      socketReceiveMs: 17_704,
      fileWriteMs: 218,
      commandGapMs: 48,
      transferMs: 18_501
    )
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    fileSaver.waitsAfterCommit = true
    fileSaver.onSaveCommitted = { saveCommitted.fulfill() }
    var messages: [String] = []
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver,
      diagnosticHandler: { message in
        messages.append(message)
        timingEmitted.fulfill()
      }
    )

    transport.startTransfer(handle: 101, mode: .original)
    await fulfillment(of: [saveCommitted], timeout: 1)

    XCTAssertTrue(messages.isEmpty)

    fileSaver.resumeCommitBoundary()
    await fulfillment(of: [timingEmitted], timeout: 1)

    XCTAssertEqual(messages.count, 1)
    XCTAssertTrue(messages[0].hasPrefix("[OBS] ORIGINAL_DOWNLOAD_TIMING"))
    XCTAssertTrue(messages[0].contains("handle=0x00000065"))
    XCTAssertTrue(messages[0].contains("filename=DSCF101.RAF"))
    XCTAssertTrue(messages[0].contains("bytes=86801408"))
    XCTAssertTrue(messages[0].contains("prepareMs=310"))
    XCTAssertTrue(messages[0].contains("photoSaveMs="))
    XCTAssertTrue(messages[0].contains("totalMs="))
  }

  @MainActor
  func testBoundRuntimeTransportAdvancesTheRuntimeAfterTheFileIsSaved() async throws {
    let completed = expectation(description: "runtime returned to gallery")
    var didFulfillCompletion = false
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )
    let runtime = CameraSessionRuntime(transport: transport)
    transport.bind(to: runtime)
    runtime.observe { presentation in
      if !didFulfillCompletion,
         presentation.phase == .galleryReady,
         galleryService.requestedHandles == [101] {
        didFulfillCompletion = true
        completed.fulfill()
      }
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await fulfillment(of: [completed], timeout: 1)

    XCTAssertEqual(fileSaver.savedFilenames, ["DSCF101.RAF"])
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testRuntimeMarksPhotoSaveFailureWithoutRecoveringOrRetransferringSourceFile() async throws {
    let completed = expectation(description: "runtime continues after save failure")
    var didFulfillCompletion = false
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    fileSaver.remainingFailures = [CameraSessionRuntimeTestError.photoSaveFailed]
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )
    let runtime = CameraSessionRuntime(transport: transport, recoveryStore: recoveryStore)
    transport.bind(to: runtime)
    runtime.observe { presentation in
      if !didFulfillCompletion,
         presentation.phase == .galleryReady,
         galleryService.requestedHandles == [101, 102] {
        didFulfillCompletion = true
        completed.fulfill()
      }
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await fulfillment(of: [completed], timeout: 1)

    guard case .failed = runtime.downloadState(for: 101) else {
      return XCTFail("Photo save failure must remain retryable in the gallery")
    }
    XCTAssertEqual(runtime.downloadState(for: 102), .saved)
    XCTAssertEqual(galleryService.requestedHandles, [101, 102])
    XCTAssertEqual(recoveryStore.records, [])
    XCTAssertEqual(galleryService.interruptCount, 0)
  }

  @MainActor
  func testRuntimeTransportRemovesTemporaryDownloadWhenPhotoSaveFails() async throws {
    let saveFailed = expectation(description: "photo save failure reported")
    let temporaryFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("camtransfer-save-failure-\(UUID().uuidString).RAF")
    FileManager.default.createFile(atPath: temporaryFileURL.path, contents: Data([0x01]))
    defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    galleryService.downloadedFileURL = temporaryFileURL
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    fileSaver.remainingFailures = [CameraSessionRuntimeTestError.photoSaveFailed]
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver,
      onFileSaveFailed: { handle, _ in
        XCTAssertEqual(handle, 101)
        saveFailed.fulfill()
      }
    )

    transport.startTransfer(handle: 101, mode: .original)
    await fulfillment(of: [saveFailed], timeout: 1)

    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFileURL.path))
  }

  @MainActor
  func testRuntimeTransportUserCancellationDoesNotCloseHealthyPtpSession() throws {
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: CameraSessionRuntimeFileSaverSpy()
    )

    transport.cancelActiveTransfer(reason: "user-cancelled-download")

    XCTAssertEqual(galleryService.interruptCount, 0)

    transport.cancelActiveTransfer(reason: "background-execution-expired")

    XCTAssertEqual(galleryService.interruptCount, 1)
  }

  @MainActor
  func testRuntimeTransportUserCancellationRequestsSoftPtpAbortWithoutDisconnectingCamera() throws {
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: CameraSessionRuntimeFileSaverSpy()
    )

    transport.cancelActiveTransfer(reason: "user-cancelled-download")

    XCTAssertEqual(galleryService.softCancellationCount, 1)
    XCTAssertEqual(galleryService.interruptCount, 0)
  }

  @MainActor
  func testRuntimeLeavesCancellingWhenPtpCancellationUnblocksActiveTransfer() async throws {
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    galleryService.blocksDownloadUntilCancellation = true
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )
    let runtime = CameraSessionRuntime(transport: transport)
    transport.bind(to: runtime)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    for _ in 0..<1_000 where galleryService.requestedHandles.isEmpty {
      await Task.yield()
    }

    runtime.send(.cancelDownloadByUser)
    for _ in 0..<1_000 where runtime.presentation.phase == .cancelling {
      await Task.yield()
    }

    XCTAssertEqual(galleryService.softCancellationCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
    XCTAssertEqual(fileSaver.savedFilenames, [])
  }

  @MainActor
  func testRuntimeTransportUserCancellationDoesNotSaveLateCancelledTransfer() async throws {
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    galleryService.ignoresTaskCancellation = true
    let temporaryFileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("camtransfer-cancelled-transfer-\(UUID().uuidString).RAF")
    FileManager.default.createFile(atPath: temporaryFileURL.path, contents: Data([0x01]))
    defer { try? FileManager.default.removeItem(at: temporaryFileURL) }
    galleryService.downloadedFileURL = temporaryFileURL
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )

    transport.startTransfer(handle: 101, mode: .original)
    await Task.yield()
    transport.cancelActiveTransfer(reason: "user-cancelled-download")
    try await Task.sleep(nanoseconds: 75_000_000)

    XCTAssertEqual(fileSaver.savedFilenames, [])
    XCTAssertEqual(galleryService.interruptCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryFileURL.path))
  }

  @MainActor
  func testRuntimeTransportUserCancellationPreventsLatePhotoLibraryCommit() async throws {
    let saveStarted = expectation(description: "photo save reached commit boundary")
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    fileSaver.waitsAtCommitBoundary = true
    fileSaver.onSaveStarted = { saveStarted.fulfill() }
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )

    transport.startTransfer(handle: 101, mode: .original)
    await fulfillment(of: [saveStarted], timeout: 1)
    transport.cancelActiveTransfer(reason: "user-cancelled-download")
    fileSaver.resumeCommitBoundary()
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(fileSaver.savedFilenames, [])
    XCTAssertEqual(galleryService.interruptCount, 0)
  }

  @MainActor
  func testStaleTransportCancellationCannotDrainNewSessionWithTheSameHandle() async throws {
    let oldGalleryService = CameraSessionRuntimeGalleryServiceSpy()
    oldGalleryService.ignoresTaskCancellation = true
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    let oldTransport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: oldGalleryService,
      fileSaver: CameraSessionRuntimeFileSaverSpy()
    )
    oldTransport.bind(to: runtime)
    oldTransport.startTransfer(handle: 101, mode: .original)
    await Task.yield()

    _ = runtime.beginTransportBinding(identity: CameraSessionIdentity(cameraName: "new-X-T5"))
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "new-X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForRuntimeInFlight(runtime)
    runtime.send(.cancelDownloadByUser)
    oldTransport.cancelActiveTransfer(reason: "user-cancelled-download")
    try? await Task.sleep(nanoseconds: 75_000_000)

    XCTAssertEqual(runtime.presentation.phase, .cancelling)
    XCTAssertEqual(runtime.presentation.inFlightHandle, 101)
  }

  @MainActor
  func testRuntimeRecordsSavedHandleWhenCancellationArrivesAfterPhotoCommit() async throws {
    let saveCommitted = expectation(description: "photo save committed")
    let savedHandleRecorded = expectation(description: "saved handle recorded")
    let galleryService = CameraSessionRuntimeGalleryServiceSpy()
    let fileSaver = CameraSessionRuntimeFileSaverSpy()
    fileSaver.waitsAfterCommit = true
    fileSaver.onSaveCommitted = { saveCommitted.fulfill() }
    let savedHandleStore = CameraSessionRuntimeSavedHandleStoreSpy {
      savedHandleRecorded.fulfill()
    }
    let transport = CameraVendorGallerySessionRuntimeTransport(
      galleryService: galleryService,
      fileSaver: fileSaver
    )
    let runtime = CameraSessionRuntime(
      transport: transport,
      savedHandleStore: savedHandleStore
    )
    transport.bind(to: runtime)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await fulfillment(of: [saveCommitted], timeout: 1)

    // A successful Photos commit must durably record its handle before a
    // lifecycle interruption can persist the same item for recovery.
    await fulfillment(of: [savedHandleRecorded], timeout: 1)
    runtime.send(.backgroundExecutionExpired)
    fileSaver.resumeCommitBoundary()
  }

  @MainActor
  func testCameraDownloadSessionRuntimeRecoveryStorePersistsQueuedModesAndInFlightHandle() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("camtransfer-runtime-recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CameraDownloadSessionStore(
      fileURL: directory.appendingPathComponent("camera-download-recovery.json")
    )
    let recoveryStore = CameraDownloadSessionRuntimeRecoveryStore(store: store)
    let peripheralID = UUID()

    try recoveryStore.persistInterruptedRecoverable(
      sessionID: UUID(),
      identity: CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID),
      downloads: [
        CameraSessionQueuedDownload(handle: 101, mode: .original),
        CameraSessionQueuedDownload(handle: 102, mode: .compressed),
      ],
      inFlightHandle: 101,
      completedCount: 4,
      failedCount: 1,
      origin: .quickDownload,
      completionPolicy: .disconnectToHome,
      reason: "background-execution-expired"
    )

    let snapshot = try XCTUnwrap(try store.load())
    XCTAssertEqual(snapshot.peripheralID, peripheralID)
    XCTAssertEqual(snapshot.state, .interruptedRecoverable)
    XCTAssertEqual(snapshot.inFlightHandle, 101)
    XCTAssertEqual(snapshot.completedCount, 4)
    XCTAssertEqual(snapshot.failedCount, 1)
    XCTAssertEqual(snapshot.origin, .quickDownload)
    XCTAssertEqual(snapshot.completionPolicy, .disconnectToHome)
    XCTAssertEqual(
      snapshot.queue,
      [
        CameraDownloadSessionItem(handle: 101, mode: .original),
        CameraDownloadSessionItem(handle: 102, mode: .compressed),
      ]
    )
  }

  @MainActor
  func testCameraSessionRuntimeRestoresPersistedQueueWithoutGivingThePageAWorker() async throws {
    let peripheralID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: peripheralID,
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [
          CameraDownloadSessionItem(handle: 101, mode: .original),
          CameraDownloadSessionItem(handle: 102, mode: .compressed),
        ],
        inFlightHandle: 101,
        completedCount: 4,
        failedCount: 1,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport, recoveryStore: recoveryStore)

    runtime.send(.restorePersistedDownload)

    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
    XCTAssertEqual(runtime.presentation.inFlightHandle, nil)
    XCTAssertEqual(transport.startedHandles, [])

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)))
    runtime.send(.resumeRecoveredDownload(availableHandles: [101, 102]))
    await waitForStartedHandleCount(1, transport: transport)

    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(transport.beginDownloadLeaseCount, 1)
    XCTAssertEqual(runtime.presentation.inFlightHandle, 101)
    XCTAssertEqual(runtime.downloadState(for: 101), .downloading)
    XCTAssertEqual(runtime.downloadState(for: 102), .queued)
  }

  @MainActor
  func testCameraSessionRuntimeRequestsRecoveredConnectionWhenItRestoresDurableQueue() throws {
    let peripheralID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: peripheralID,
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let connector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore,
      recoveryConnector: connector
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertEqual(connector.requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)
    ])
  }

  @MainActor
  func testCameraSessionRuntimeRequestsRecoveryConnectionAfterForegroundTransportFailure() async throws {
    let peripheralID = UUID()
    let connector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      recoveryConnector: connector
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))
    await waitForRuntimePhase(runtime, .recovering)

    XCTAssertEqual(connector.requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)
    ])
  }

  @MainActor
  func testCameraSessionRuntimeRetriesRecoveryConnectionAfterARejectedRequestAndForegroundReturn() async throws {
    let peripheralID = UUID()
    let connector = CameraSessionRuntimeRecoveryConnectorSpy(requestResults: [false, true])
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      recoveryConnector: connector
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))
    await waitForRuntimePhase(runtime, .recovering)
    runtime.send(.applicationBecameActive)

    XCTAssertEqual(connector.requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID),
      CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID),
    ])
  }

  @MainActor
  func testCameraSessionRuntimeDefersRecoveryConnectionUntilForegroundAfterBackgroundTransportFailure() async throws {
    let peripheralID = UUID()
    let connector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy(),
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(),
      recoveryConnector: connector
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.applicationEnteredBackground)
    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))
    await waitForRuntimePhase(runtime, .recovering)

    XCTAssertEqual(connector.requestedIdentities, [])

    runtime.send(.applicationBecameActive)

    XCTAssertEqual(connector.requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)
    ])
  }

  @MainActor
  func testCameraSessionRuntimeUserCancellationClearsRecoveringSnapshot() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [
          CameraDownloadSessionItem(handle: 101, mode: .original),
          CameraDownloadSessionItem(handle: 102, mode: .compressed),
        ],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.cancelDownloadByUser)
    runtime.send(.restorePersistedDownload)

    XCTAssertEqual(recoveryStore.clearCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
  }

  @MainActor
  func testCameraSessionRuntimeRestartedQuickRecoveryCancellationReturnsToGallery() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore
    )
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome = true
      }
    }

    runtime.send(.restorePersistedDownload)
    runtime.send(.cancelDownloadByUser)

    // The gallery surface remains selected, but a restarted recovery has no
    // usable PTP catalog session until reconnection completes.
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
    XCTAssertFalse(routedHome)
    XCTAssertEqual(recoveryStore.clearCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeFreshSessionClearsRecoveredQuickRouting() async throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5-old",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.enterGallery(CameraSessionIdentity(
      cameraName: "X-T5-new",
      peripheralID: UUID()
    )))
    await waitForRuntimeGalleryReady(runtime)

    XCTAssertEqual(recoveryStore.clearCount, 1)
    runtime.send(.restorePersistedDownload)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testCameraSessionRuntimeFreshSessionCancelsOutstandingRecoveryConnection() async throws {
    let oldPeripheralID = UUID()
    let newIdentity = CameraSessionIdentity(cameraName: "X-T5-new", peripheralID: UUID())
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: oldPeripheralID,
        cameraName: "X-T5-old",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let connector = CameraSessionRuntimeDeferredRecoveryConnector()
    var requestedIdentities: [CameraSessionIdentity] = []
    var pendingCompletions: [(Bool) -> Void] = []
    var cancellationReasons: [String] = []
    connector.attach(
      { identity, completion in
        requestedIdentities.append(identity)
        pendingCompletions.append(completion)
      },
      cancellationHandler: { cancellationReasons.append($0) }
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore,
      recoveryConnector: connector
    )

    runtime.send(.restorePersistedDownload)
    XCTAssertEqual(requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5-old", peripheralID: oldPeripheralID)
    ])

    runtime.send(.enterGallery(newIdentity))
    await waitForRuntimeGalleryReady(runtime)

    XCTAssertEqual(cancellationReasons, ["fresh-session-superseded-download-recovery"])
    XCTAssertEqual(recoveryStore.clearCount, 1)
    var replacementResults: [Bool] = []
    connector.requestRecoveredConnection(identity: newIdentity) {
      replacementResults.append($0)
    }
    XCTAssertEqual(requestedIdentities, [
      CameraSessionIdentity(cameraName: "X-T5-old", peripheralID: oldPeripheralID),
      newIdentity,
    ])
    XCTAssertEqual(replacementResults, [])

    pendingCompletions.first?(false)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
    XCTAssertEqual(replacementResults, [])
    pendingCompletions.last?(true)
    XCTAssertEqual(replacementResults, [true])
  }

  @MainActor
  func testCameraSessionRuntimeNilPeripheralCannotInheritConcreteRecovery() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5-old",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5-new", peripheralID: nil)))

    XCTAssertEqual(recoveryStore.clearCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .galleryLoading)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
  }

  @MainActor
  func testCameraSessionRuntimeSameProcessQuickRecoveryReconnectPreservesDisconnectRouting() async throws {
    let peripheralID = UUID()
    let identity = CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 101, formatLabel: "JPG")]
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    )
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome = true
      }
    }

    runtime.send(.enterGallery(identity))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    XCTAssertTrue(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    )))
    await waitForRuntimePhase(runtime, .recovering)

    runtime.send(.applicationBecameActive)
    runtime.send(.enterGallery(identity))

    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101])
    XCTAssertEqual(recoveryStore.clearCount, 0)

    runtime.send(.resumeRecoveredDownload(availableHandles: [101]))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(runtime.presentation.phase, .idle)
    XCTAssertTrue(routedHome)
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeSameProcessRecoveryReopensCatalogAfterRecoveredDownloadCompletes() async throws {
    let peripheralID = UUID()
    let identity = CameraSessionIdentity(cameraName: "X-T5", peripheralID: peripheralID)
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 101, formatLabel: "JPG")]
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeRecoveryStoreSpy()
    )

    runtime.send(.enterGallery(identity))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)

    runtime.send(.transportFailed(CameraSessionRuntimeTestError.socketClosed))
    await waitForRuntimePhase(runtime, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)

    runtime.send(.enterGallery(identity))
    await waitForStartedHandleCount(2, transport: transport)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertTrue(runtime.canAcceptCatalogCommands)
  }

  @MainActor
  func testCameraSessionRuntimeTerminalGalleryExitClearsDurableQuickRecovery() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)
    runtime.exitGalleryAndDisconnect(reason: "terminal-gallery-exit")

    XCTAssertEqual(recoveryStore.clearCount, 1)
    runtime.send(.restorePersistedDownload)
    XCTAssertEqual(runtime.presentation.phase, .idle)
    XCTAssertEqual(runtime.presentation.queuedHandles, [])
  }

  @MainActor
  func testCameraSessionRuntimeOverlayCancellationClearsRecoverableQueue() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let connector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore,
      recoveryConnector: connector
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertTrue(runtime.cancelRecoveredDownloadFromConnectionOverlay())
    XCTAssertEqual(recoveryStore.clearCount, 1)
    XCTAssertEqual(connector.cancelledReasons, ["user-cancelled-download-recovery"])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
  }

  @MainActor
  func testCameraSessionRuntimeCancelsItsRecoveryConnectionWhenUserCancelsRecovery() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let connector = CameraSessionRuntimeRecoveryConnectorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore,
      recoveryConnector: connector
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.cancelDownloadByUser)

    XCTAssertEqual(connector.cancelledReasons, ["user-cancelled-download-recovery"])
    XCTAssertEqual(recoveryStore.clearCount, 1)
  }

  @MainActor
  func testDeferredRecoveryConnectorDropsLateCompletionAfterRuntimeCancellation() throws {
    let connector = CameraSessionRuntimeDeferredRecoveryConnector()
    var delayedCompletion: ((Bool) -> Void)?
    var results: [Bool] = []
    connector.attach(
      { _, completion in
        delayedCompletion = completion
      },
      cancellationHandler: { _ in }
    )

    connector.requestRecoveredConnection(
      identity: CameraSessionIdentity(cameraName: "X-T5")
    ) { result in
      results.append(result)
    }
    connector.cancelRecoveryConnection(reason: "user-cancelled-download-recovery")
    delayedCompletion?(true)

    XCTAssertEqual(results, [])
  }

  @MainActor
  func testRuntimeConnectionWorkerDropsLateGalleryCompletionAfterCancellation() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    var completions: [IOSCameraConnectFlowState] = []

    worker.enterRememberedGallery(
      record: CameraSessionRuntimeConnectionFlowSpy.record
    ) { state in
      completions.append(state)
    }
    await flow.waitUntilRememberedGalleryStarts()

    worker.cancel(reason: "user-cancelled-connect")
    flow.finishRememberedGallery()
    await Task.yield()

    XCTAssertEqual(flow.cancelCount, 1)
    XCTAssertEqual(completions, [])
    XCTAssertFalse(worker.isActive)
  }

  @MainActor
  func testRuntimeConnectionWorkerRejectsDuplicatePairingConfirmationWhileConfirmationIsActive() async {
    let flow = CameraSessionRuntimeBlockingConfirmationFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)

    worker.confirmPairing { _ in }
    await flow.waitUntilConfirmationStarts()
    worker.confirmPairing { _ in }
    await Task.yield()

    XCTAssertEqual(flow.confirmationCount, 1)
    flow.finishConfirmation()
  }

  @MainActor
  func testRuntimeActivatesGalleryTransportAfterRememberedConnectionWithoutHomeOwnership() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let completion = expectation(description: "remembered gallery connected")

    runtime.startRememberedGalleryConnection(record: CameraSessionRuntimeConnectionFlowSpy.record) { state in
      guard case .galleryReady = state else {
        XCTFail("Expected gallery-ready connection state, got \(state)")
        return
      }
      completion.fulfill()
    }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [completion], timeout: 1)

    let payload = try XCTUnwrap(runtime.galleryPresentationPayload)

    XCTAssertEqual(activator.activatedCameraIDs, ["X-T5"])
    XCTAssertEqual(payload.rememberedPeripheralID, CameraSessionRuntimeConnectionFlowSpy.record.peripheralID)
    XCTAssertEqual(payload.summary.deviceName, "X-T5")
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testRuntimeQuickDownloadConnectionDoesNotStartGalleryCatalogBeforeItsOwnQuery() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let completion = expectation(description: "quick download transport connected")

    runtime.startRememberedQuickDownloadConnection(
      record: CameraSessionRuntimeConnectionFlowSpy.record
    ) { state in
      guard case .galleryReady = state else {
        XCTFail("Expected transport-ready state, got \(state)")
        return
      }
      completion.fulfill()
    }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [completion], timeout: 1)

    XCTAssertEqual(activator.activatedCameraIDs, ["X-T5"])
    XCTAssertEqual(transport.initialCatalogRequestCount, 0)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertEqual(runtime.presentation.catalog, .unavailable)

    _ = try await runtime.resolveCatalog(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .all,
        downloadScope: .all
      ),
      owner: .quickDownload(UUID())
    )

    XCTAssertEqual(transport.initialCatalogRequestCount, 0)
    XCTAssertEqual(transport.requestedCatalogLabels, ["format-jpg"])
  }

  @MainActor
  func testRuntimeQuickDownloadCatalogResolutionRetainsMetadataForDownloadHistory() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    let item = galleryItem(handle: 101, formatLabel: "JPG")
    transport.catalogItems = [item]
    let savedHandleStore = CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [])
    let runtime = CameraSessionRuntime(
      transport: transport,
      savedHandleStore: savedHandleStore,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let completion = expectation(description: "quick download transport connected")

    runtime.startRememberedQuickDownloadConnection(
      record: CameraSessionRuntimeConnectionFlowSpy.record
    ) { state in
      guard case .galleryReady = state else {
        XCTFail("Expected transport-ready state, got \(state)")
        return
      }
      completion.fulfill()
    }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [completion], timeout: 1)

    _ = try await runtime.resolveCatalog(
      rule: CameraMediaFilterRule(
        formats: .selected([.jpg]),
        date: .all,
        downloadScope: .all
      ),
      owner: .quickDownload(UUID())
    )
    runtime.recordSavedHandle(101)

    XCTAssertEqual(savedHandleStore.recordedItemsByHandle[101], item)
    XCTAssertEqual(runtime.presentation.catalog, .unavailable)
  }

  @MainActor
  func testRuntimeQuickDownloadReturnToGalleryStartsCatalogOnlyAtTerminalRoute() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    transport.suspendsCatalogRequests = true
    let runtime = CameraSessionRuntime(
      transport: transport,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let connectionCompleted = expectation(description: "quick connection completed")
    let galleryRouted = expectation(description: "gallery routed after its catalog is ready")
    runtime.onPresentationDestinationReady = { destination in
      guard case .gallery = destination else { return }
      galleryRouted.fulfill()
    }

    runtime.startRememberedQuickDownloadConnection(
      record: CameraSessionRuntimeConnectionFlowSpy.record
    ) { _ in
      connectionCompleted.fulfill()
    }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [connectionCompleted], timeout: 1)
    XCTAssertEqual(transport.initialCatalogRequestCount, 0)
    flow.resetStateAfterConnectionCompletion()

    let didRoute = await runtime.routeQuickDownloadNoMatch(completionPolicy: .returnToGallery)
    XCTAssertTrue(didRoute)
    guard didRoute else { return }
    await transport.waitForInitialCatalogRequestCount(1)
    XCTAssertEqual(runtime.presentation.phase, .galleryLoading)

    transport.resolveInitialCatalogRequest(
      at: 0,
      items: [galleryItem(handle: 101, formatLabel: "JPG")]
    )
    await fulfillment(of: [galleryRouted], timeout: 1)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testRuntimeDoesNotCompleteRememberedGalleryBeforeInitialCatalogIsReady() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    transport.suspendsCatalogRequests = true
    let runtime = CameraSessionRuntime(
      transport: transport,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let connectionCompleted = expectation(description: "gallery connection completed")
    let destinationReady = expectation(description: "gallery destination ready")
    var didCompleteConnection = false
    var didRouteDestination = false
    runtime.onPresentationDestinationReady = { _ in
      didRouteDestination = true
      destinationReady.fulfill()
    }

    runtime.startRememberedGalleryConnection(record: CameraSessionRuntimeConnectionFlowSpy.record) { state in
      guard case .galleryReady = state else {
        XCTFail("Expected aggregate gallery-ready result, got (state)")
        return
      }
      didCompleteConnection = true
      connectionCompleted.fulfill()
    }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await transport.waitForInitialCatalogRequestCount(1)
    for _ in 0..<20 {
      await Task.yield()
    }

    XCTAssertFalse(didCompleteConnection, "PTP readiness must not complete the user Gallery flow")
    XCTAssertFalse(didRouteDestination, "Navigation must wait for the first catalog installation")
    XCTAssertEqual(runtime.presentation.phase, .galleryLoading)

    transport.resolveInitialCatalogRequest(at: 0, items: [galleryItem(handle: 101, formatLabel: "JPG")])
    await fulfillment(of: [connectionCompleted, destinationReady], timeout: 1)
    XCTAssertTrue(didCompleteConnection)
    XCTAssertTrue(didRouteDestination)
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testRuntimeRoutesRecoveredConnectionDirectlyToDownloadCenterAndStartsRecovery() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [
      CameraVendorGalleryItem(
        handle: 101,
        filename: "DSCF0101.JPG",
        formatLabel: "JPG",
        captureDate: "2026-07-12",
        byteSizeText: "1 MB"
      )
    ]
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: CameraSessionRuntimeConnectionFlowSpy.record.peripheralID,
        cameraName: "X-T5",
        historyKey: "serial",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let routed = expectation(description: "recovery download center routed")
    runtime.onPresentationDestinationReady = { destination in
      guard case let .recoveryDownloadCenter(payload) = destination else {
        XCTFail("Recovered queue must not route through Gallery")
        return
      }
      XCTAssertEqual(payload.rememberedPeripheralID, CameraSessionRuntimeConnectionFlowSpy.record.peripheralID)
      routed.fulfill()
    }

    runtime.send(.restorePersistedDownload)
    runtime.startRememberedGalleryConnection(record: CameraSessionRuntimeConnectionFlowSpy.record) { _ in }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [routed], timeout: 1)

    XCTAssertEqual(transport.startedHandles, [101])
    XCTAssertEqual(runtime.presentation.phase, .downloadingForeground)
  }

  @MainActor
  func testRuntimeRoutesNormalConnectionToGalleryWithoutPageOwnedCatalogItems() async throws {
    let flow = CameraSessionRuntimeConnectionFlowSpy()
    let worker = CameraSessionRuntimeConnectionWorker(flow: flow)
    let activator = CameraSessionRuntimeGallerySessionActivatorSpy()
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      connectionWorker: worker,
      gallerySessionActivator: activator
    )
    let routed = expectation(description: "gallery routed")
    runtime.onPresentationDestinationReady = { destination in
      guard case let .gallery(payload) = destination else {
        XCTFail("Normal connection must route through Gallery")
        return
      }
      XCTAssertEqual(payload.rememberedPeripheralID, CameraSessionRuntimeConnectionFlowSpy.record.peripheralID)
      routed.fulfill()
    }

    runtime.startRememberedGalleryConnection(record: CameraSessionRuntimeConnectionFlowSpy.record) { _ in }
    await flow.waitUntilRememberedGalleryStarts()
    flow.finishRememberedGallery()
    await fulfillment(of: [routed], timeout: 1)

    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
  }

  @MainActor
  func testRuntimeRejectsVisibleThumbnailIntentWhileDownloadOwnsThePtpLease() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))

    runtime.requestVisibleGalleryThumbnails(handles: [201])
    await Task.yield()

    XCTAssertEqual(transport.thumbnailHandles, [])
    XCTAssertEqual(runtime.presentation.phase, .downloadingForeground)
  }

  @MainActor
  func testCameraSessionRuntimeExposesRecoveringQueueAsCancellableToDownloadCenter() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [
          CameraDownloadSessionItem(handle: 101, mode: .original),
          CameraDownloadSessionItem(handle: 102, mode: .compressed),
        ],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertTrue(runtime.canCancelDownload)
  }

  @MainActor
  func testCameraSessionRuntimeMarksUnavailableRecoveredHandleAsFailed() async throws {
    let peripheralID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: peripheralID,
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.enterGallery(CameraSessionIdentity(
      cameraName: "X-T5",
      peripheralID: peripheralID
    )))
    await waitForRuntimeGalleryReady(runtime)

    guard case .failed = runtime.downloadState(for: 101) else {
      return XCTFail("Unavailable recovery item must remain visible as failed")
    }
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertTrue(runtime.canAcceptCatalogCommands)
  }

  @MainActor
  func testCameraSessionRuntimeRestartedQuickRecoveryCompletionDisconnectsToHome() async throws {
    let peripheralID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: peripheralID,
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 101, formatLabel: "JPG")]
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore
    )
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome = true
      }
    }

    runtime.send(.restorePersistedDownload)
    runtime.send(.enterGallery(CameraSessionIdentity(
      cameraName: "X-T5",
      peripheralID: peripheralID
    )))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.transferFinished(handle: 101))

    XCTAssertEqual(runtime.presentation.phase, .idle)
    XCTAssertTrue(routedHome)
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeRestartedQuickRecoveryReconciledQueueDisconnectsToHome() async throws {
    let peripheralID = UUID()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: peripheralID,
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        origin: .quickDownload,
        completionPolicy: .disconnectToHome,
        queue: [CameraDownloadSessionItem(handle: 101, mode: .original)],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 101, formatLabel: "JPG")]
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      savedHandleStore: CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101])
    )
    let routedHome = expectation(description: "reconciled Quick recovery routed home")
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome.fulfill()
      }
    }

    runtime.send(.restorePersistedDownload)
    runtime.send(.enterGallery(CameraSessionIdentity(
      cameraName: "X-T5",
      peripheralID: peripheralID
    )))

    await fulfillment(of: [routedHome], timeout: 1)
    XCTAssertEqual(runtime.presentation.phase, .idle)
    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeOwnsGalleryKeepAliveWhileBackgroundedWithoutTransfer() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.applicationBecameActive)

    XCTAssertEqual(executionAuthority.acquireCount, 1)
    XCTAssertEqual(backgroundMaintainer.ptpKeepAliveModes, [true])
    XCTAssertEqual(backgroundMaintainer.stopCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeRepreparesBackgroundAuthorityAfterReturningActive() async {
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(),
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.applicationBecameActive)

    XCTAssertEqual(backgroundMaintainer.prepareCount, 2)
  }

  @MainActor
  func testCameraSessionRuntimeStopsIdleBackgroundMaintenanceWhenNoExecutionAuthorityExists() {
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    runtime.send(.applicationEnteredBackground)

    XCTAssertEqual(backgroundMaintainer.ptpKeepAliveModes, [true])
    XCTAssertEqual(backgroundMaintainer.stopCount, 1)
  }

  @MainActor
  func testDeferredBackgroundMaintainerPreparesAuthorizationAfterLateAttach() {
    let deferred = CameraSessionRuntimeDeferredBackgroundMaintainer()
    let maintainer = CameraSessionRuntimeBackgroundMaintainerSpy()

    deferred.prepareBackgroundExecution()
    deferred.attach(maintainer)

    XCTAssertEqual(maintainer.prepareCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeKeepsOnlyBleAliveWhileBackgroundDownloadUsesPtpLane() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.applicationEnteredBackground)

    XCTAssertEqual(backgroundMaintainer.ptpKeepAliveModes, [false])
  }

  @MainActor
  func testBackgroundActivityLeaseRequiresCallbackInCurrentBackgroundEpoch() {
    let lease = CameraSessionRuntimeBackgroundActivityLease()

    XCTAssertFalse(lease.hasObservedHardwareActivity)

    lease.beginBackgroundEpoch()
    XCTAssertFalse(lease.hasObservedHardwareActivity)

    XCTAssertTrue(lease.recordHardwareCallback())
    XCTAssertTrue(lease.hasObservedHardwareActivity)
    XCTAssertFalse(lease.recordHardwareCallback())

    lease.beginBackgroundEpoch()
    XCTAssertFalse(lease.hasObservedHardwareActivity)

    XCTAssertTrue(lease.recordHardwareCallback())
    XCTAssertTrue(lease.hasObservedHardwareActivity)

    lease.endBackgroundEpoch()
    XCTAssertFalse(lease.hasObservedHardwareActivity)
  }

  func testBackgroundHardwareActivityLoggingUsesTheFirstCallbackGate() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionBackgroundSupervisor.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("func recordHardwareCallback() -> Bool"))
    XCTAssertTrue(source.contains("recordHardwareCallback() == true"))
  }

  @MainActor
  func testCameraSessionRuntimeKeepsTransferRunningAfterFiniteTaskExpiryWhenRuntimeBleActivityIsActive() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy(
      sustainsBackgroundExecution: true
    )
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.backgroundExecutionExpired)
    runtime.send(.transferFinished(handle: 101))
    await waitForStartedHandleCount(2, transport: transport)

    XCTAssertEqual(runtime.presentation.phase, .downloadingBackground)
    XCTAssertEqual(runtime.presentation.inFlightHandle, 102)
    XCTAssertEqual(transport.startedHandles, [101, 102])
    XCTAssertEqual(transport.cancelActiveTransferCount, 0)
    XCTAssertTrue(recoveryStore.records.isEmpty)
  }

  @MainActor
  func testCameraSessionRuntimeIgnoresLateBackgroundExpiryAfterForegroundReturn() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.applicationBecameActive)
    runtime.send(.backgroundExecutionExpired)

    XCTAssertEqual(runtime.presentation.phase, .downloadingForeground)
    XCTAssertEqual(runtime.presentation.inFlightHandle, 101)
    XCTAssertEqual(transport.cancelActiveTransferCount, 0)
    XCTAssertTrue(recoveryStore.records.isEmpty)
  }

  func testRuntimeBackgroundSupervisorDoesNotRequestAlwaysLocationForDownloadContinuation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/CameraSessionBackgroundSupervisor.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertFalse(source.contains("CameraSessionRuntimeLocationExecutionMaintainer"))
    XCTAssertFalse(source.contains("requestAlwaysAuthorization()"))
  }

  @MainActor
  func testCameraSessionBackgroundExecutionLeaseRejectsOldExpiryAfterReacquire() {
    let lease = CameraSessionBackgroundExecutionLease()
    let firstLeaseID = lease.acquire()

    lease.release()
    let secondLeaseID = lease.acquire()

    XCTAssertFalse(lease.consumeExpiry(for: firstLeaseID))
    XCTAssertTrue(lease.consumeExpiry(for: secondLeaseID))
  }

  @MainActor
  func testCameraSessionRuntimeStopsIdlePtpKeepAliveBeforeBackgroundDownloadStarts() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy()
    let backgroundMaintainer = CameraSessionRuntimeBackgroundMaintainerSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      executionAuthority: executionAuthority,
      backgroundMaintainer: backgroundMaintainer
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.startDownload(handles: [101], mode: .original))

    await waitForStartedHandleCount(1, transport: transport)
    XCTAssertEqual(backgroundMaintainer.ptpKeepAliveModes, [true, false])
    XCTAssertEqual(runtime.presentation.phase, .downloadingBackground)
  }

  @MainActor
  func testCameraSessionRuntimePersistsInsteadOfStartingBackgroundDownloadWithoutExecutionAuthority() async throws {
    let transport = CameraSessionRuntimeSpy()
    let executionAuthority = CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: executionAuthority
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.startDownload(handles: [101], mode: .original))

    await waitForRuntimePhase(runtime, .recovering)
    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(recoveryStore.records.first?.handles, [101])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
  }

  @MainActor
  func testCancellingInterruptedAdmissionRequiresReconnectBeforeGalleryThumbnailWork() async throws {
    let transport = CameraSessionRuntimeSpy()
    transport.catalogItems = [galleryItem(handle: 3, formatLabel: "JPG")]
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: CameraSessionRuntimeNonPersistingRecoveryStore(),
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.startDownload(handles: [101], mode: .original))
    await waitForRuntimePhase(runtime, .interrupted)

    runtime.send(.cancelDownloadByUser)
    runtime.send(.applicationBecameActive)
    runtime.requestVisibleGalleryThumbnails(handles: [3])

    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertFalse(runtime.canAcceptCatalogCommands)
    XCTAssertEqual(transport.thumbnailHandles, [])
  }

  @MainActor
  func testCancellingRecoveringQuickDownloadReturnsToGallery() async throws {
    let transport = CameraSessionRuntimeSpy()
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    )
    var routedHome = false
    runtime.onPresentationDestinationReady = { destination in
      if case .home = destination {
        routedHome = true
      }
    }

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.applicationEnteredBackground)
    XCTAssertTrue(runtime.submitDownload(CameraDownloadSubmission(
      id: UUID(),
      requests: [CameraSessionQueuedDownload(handle: 101, mode: .original)],
      origin: .quickDownload,
      completionPolicy: .disconnectToHome
    )))
    await waitForRuntimePhase(runtime, .recovering)
    XCTAssertEqual(recoveryStore.records.first?.origin, .quickDownload)
    XCTAssertEqual(recoveryStore.records.first?.completionPolicy, .disconnectToHome)

    runtime.send(.applicationBecameActive)
    runtime.send(.cancelDownloadByUser)

    // User-initiated cancel always returns to gallery
    XCTAssertEqual(runtime.presentation.phase, .galleryReady)
    XCTAssertFalse(routedHome)
  }

  @MainActor
  func testCameraSessionRuntimeDoesNotResumeRecoveredDownloadInBackgroundWithoutExecutionAuthority() throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [
          CameraDownloadSessionItem(handle: 101, mode: .original),
          CameraDownloadSessionItem(handle: 102, mode: .compressed),
        ],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      savedHandleStore: CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101]),
      executionAuthority: CameraSessionRuntimeExecutionAuthoritySpy(grantsAuthority: false)
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.applicationEnteredBackground)
    runtime.send(.resumeRecoveredDownload(availableHandles: [101, 102]))

    XCTAssertEqual(transport.startedHandles, [])
    XCTAssertEqual(runtime.presentation.phase, .recovering)
    XCTAssertEqual(runtime.presentation.queuedHandles, [101, 102])
    XCTAssertEqual(runtime.downloadState(for: 101), .queued)
  }

  @MainActor
  func testCameraSessionRuntimePresentationTracksSavedAndQueuedItemStates() async throws {
    let transport = CameraSessionRuntimeSpy()
    let runtime = CameraSessionRuntime(transport: transport)
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.startDownload(handles: [101, 102], mode: .original))
    await waitForStartedHandleCount(1, transport: transport)
    runtime.send(.transferFinished(handle: 101))
    await waitForStartedHandleCount(2, transport: transport)

    XCTAssertEqual(runtime.downloadState(for: 101), .saved)
    XCTAssertEqual(runtime.downloadState(for: 102), .downloading)
    XCTAssertEqual(runtime.downloadableHandles(from: [101, 102]), [])
  }

  @MainActor
  func testCameraSessionRuntimeLoadsPersistedSavedHandlesWithoutHomeSupplyingThemToRecovery() async throws {
    let recoveryStore = CameraSessionRuntimeRecoveryStoreSpy(
      snapshot: CameraDownloadSessionSnapshot(
        sessionID: UUID(),
        peripheralID: UUID(),
        cameraName: "X-T5",
        state: .interruptedRecoverable,
        recoveryIntent: "background-execution-expired",
        presentationSurface: "runtime",
        queue: [
          CameraDownloadSessionItem(handle: 101, mode: .original),
          CameraDownloadSessionItem(handle: 102, mode: .original),
        ],
        inFlightHandle: 101,
        completedCount: 0,
        failedCount: 0,
        updatedAt: Date()
      )
    )
    let transport = CameraSessionRuntimeSpy()
    let activityReporter = CameraSessionRuntimeActivityReporterSpy()
    let runtime = CameraSessionRuntime(
      transport: transport,
      recoveryStore: recoveryStore,
      savedHandleStore: CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101]),
      activityReporter: activityReporter
    )

    runtime.send(.restorePersistedDownload)
    runtime.send(.resumeRecoveredDownload(availableHandles: [101, 102]))
    await waitForStartedHandleCount(1, transport: transport)

    XCTAssertEqual(transport.startedHandles, [102])
    XCTAssertEqual(transport.beginDownloadLeaseCount, 1)
    XCTAssertEqual(runtime.downloadState(for: 101), .saved)
    XCTAssertEqual(activityReporter.snapshots.last?.downloadCompletedCount, 1)
    XCTAssertEqual(activityReporter.snapshots.last?.downloadTotalCount, 2)
  }

  @MainActor
  func testCameraSessionRuntimeClearsOnePersistedSavedHandleAndMakesItDownloadable() throws {
    let savedHandleStore = CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101, 102])
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      savedHandleStore: savedHandleStore
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    runtime.send(.clearSavedDownloadHistory(handle: 101))

    XCTAssertEqual(savedHandleStore.removedHandles, [101])
    XCTAssertEqual(runtime.downloadableHandles(from: [101, 102]), [101])
    XCTAssertEqual(runtime.downloadState(for: 102), .saved)
  }

  @MainActor
  func testCameraSessionRuntimeClearsAllPersistedDownloadHistoryWithoutPageStoreMutation() throws {
    let savedHandleStore = CameraSessionRuntimeSavedHandleStoreSpy(savedHandles: [101, 102])
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      savedHandleStore: savedHandleStore
    )

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    runtime.send(.clearAllSavedDownloadHistory)

    XCTAssertEqual(savedHandleStore.clearCount, 1)
    XCTAssertEqual(runtime.savedDownloadHandles(), Set<Int>())
    XCTAssertEqual(runtime.downloadableHandles(from: [101, 102]), [101, 102])
  }

  @MainActor
  func testCameraSessionRuntimeAllowsExplicitRetryAfterPhotoSaveFailure() throws {
    let runtime = CameraSessionRuntime(transport: CameraSessionRuntimeSpy())
    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    runtime.send(.startDownload(handles: [101], mode: .original))
    runtime.send(.fileSaveFailed(handle: 101, error: CameraSessionRuntimeTestError.photoSaveFailed))

    XCTAssertEqual(runtime.downloadableHandles(from: [101]), [101])
  }

  @MainActor
  func testCameraSessionRuntimeTerminatesTransportBeforeCatalogTransactionFinishes() async {
    let transport = CameraSessionRuntimeSpy()
    transport.suspendsCatalogRequests = true
    let terminated = expectation(description: "transport terminated before catalog cleanup")
    transport.onTerminate = {
      terminated.fulfill()
    }
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5")))
    await transport.waitForInitialCatalogRequestCount(1)

    runtime.send(.disconnectCamera(reason: "gallery-back"))
    await fulfillment(of: [terminated], timeout: 1)
    XCTAssertEqual(transport.terminateCount, 1)
    XCTAssertEqual(runtime.presentation.phase, .idle)

    transport.resolveInitialCatalogRequest(at: 0, items: [galleryItem(handle: 1, formatLabel: "JPG")])
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeIsTheOnlyPathThatTerminatesCameraCommunication() async throws {
    let transport = CameraSessionRuntimeSpy()
    let terminated = expectation(description: "transport terminated")
    transport.onTerminate = {
      terminated.fulfill()
    }
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.disconnectCamera(reason: "gallery-back"))

    await fulfillment(of: [terminated], timeout: 1)
    XCTAssertEqual(transport.terminateCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeUsesItsTransportAdapterBeforeGalleryTransportIsBound() async throws {
    let transport = CameraSessionRuntimeDeferredTransport()
    var terminationReasons: [String] = []
    let terminated = expectation(description: "unbound transport terminated")
    transport.attachUnboundTerminationHandler { reason in
      terminationReasons.append(reason)
      terminated.fulfill()
    }
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.disconnectCamera(reason: "home-disconnect-active-camera-session"))

    await fulfillment(of: [terminated], timeout: 1)
    XCTAssertEqual(terminationReasons, ["home-disconnect-active-camera-session"])
  }

  @MainActor
  func testCameraSessionRuntimeDisconnectClearsTheActiveSessionIdentity() async throws {
    let transport = CameraSessionRuntimeSpy()
    let terminated = expectation(description: "transport terminated")
    transport.onTerminate = { terminated.fulfill() }
    let runtime = CameraSessionRuntime(transport: transport)

    runtime.send(.enterGallery(CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())))
    await waitForRuntimeGalleryReady(runtime)
    runtime.send(.disconnectCamera(reason: "home-disconnect-active-camera-session"))

    await fulfillment(of: [terminated], timeout: 1)
    XCTAssertNil(runtime.activeCameraIdentity)
  }

  func testHomeStartupRecoveryRequiresExplicitConfirmation() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    XCTAssertTrue(source.contains("offerPendingDownloadRecoveryIfNeeded"))
    XCTAssertFalse(source.contains("guard !resumePendingDownloadSessionIfNeeded() else { return }"))
  }

  func testHomeDisconnectPathRejectsRepeatedInvocationWhileClosing() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner/NativeConnectViewController.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: "private func disconnectActiveRememberedCamera(")?.lowerBound)
    let end = try XCTUnwrap(source.range(of: "private func hidePairedCard()", range: start..<source.endIndex)?.lowerBound)
    let body = String(source[start..<end])

    XCTAssertTrue(body.contains("isDisconnectingActiveRememberedCamera"))
    XCTAssertTrue(body.contains("guard !isDisconnectingActiveRememberedCamera"))
  }

  @MainActor
  func testCameraSessionRuntimeLifecycleAdapterRoutesAppNotificationsWithoutHomeController() async {
    let center = NotificationCenter()
    let sink = CameraSessionRuntimeCommandSinkSpy()
    let adapter = CameraSessionRuntimeLifecycleAdapter(center: center, runtime: sink)

    center.post(name: UIApplication.willResignActiveNotification, object: nil)
    center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    await Task.yield()
    await Task.yield()

    XCTAssertEqual(sink.lifecycleEvents, ["willResignActive", "enteredBackground", "becameActive"])
    adapter.invalidate()
  }

  func testCameraSessionRuntimeInternalModulesKeepOneRuntimeOwnerBoundary() throws {
    let runnerDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Runner")
    let expectedModules = [
      "CameraSessionConnectionWorker.swift": "final class CameraSessionRuntimeConnectionWorker",
      "CameraSessionTransferExecutor.swift": "final class CameraVendorGallerySessionRuntimeTransport",
      "CameraSessionBackgroundSupervisor.swift": "final class CameraSessionUIKitExecutionAuthority",
      "CameraSessionRecoveryStore.swift": "final class CameraDownloadSessionRuntimeRecoveryStore",
    ]

    for (filename, requiredDeclaration) in expectedModules {
      let url = runnerDirectory.appendingPathComponent(filename)
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing runtime module: \(filename)")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let source = try String(contentsOf: url, encoding: .utf8)
      XCTAssertTrue(source.contains(requiredDeclaration), "\(filename) must own \(requiredDeclaration)")
    }

    let runtimeSource = try String(
      contentsOf: runnerDirectory.appendingPathComponent("CameraSessionRuntime.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(runtimeSource.contains("final class CameraSessionRuntime"))
    XCTAssertTrue(runtimeSource.contains("func send(_ command: CameraSessionCommand)"))
    XCTAssertFalse(runtimeSource.contains("final class CameraSessionRuntimeConnectionWorker"))
    XCTAssertFalse(runtimeSource.contains("final class CameraVendorGallerySessionRuntimeTransport"))
    XCTAssertFalse(runtimeSource.contains("final class CameraSessionUIKitExecutionAuthority"))
    XCTAssertFalse(runtimeSource.contains("final class CameraDownloadSessionRuntimeRecoveryStore"))
  }

  @MainActor
  func testCameraSessionRuntimeClearsLegacyGalleryResumeOnlyThroughRuntimeRecoveryBoundary() {
    let legacyResume = CameraSessionRuntimeLegacyResumeMigratorSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      legacyResumeMigrator: legacyResume
    )

    runtime.send(.restorePersistedDownload)

    XCTAssertEqual(legacyResume.discardCount, 1)
  }

  @MainActor
  func testDeferredRuntimeBindingRetiresOldWrapperLocallyWithoutInterruptingSharedPtpSession() {
    let deferredTransport = CameraSessionRuntimeDeferredTransport()
    let deferredBackground = CameraSessionRuntimeDeferredBackgroundMaintainer()
    let transportA = CameraSessionRuntimeSpy()
    let transportB = CameraSessionRuntimeSpy()
    let backgroundA = CameraSessionRuntimeBackgroundMaintainerSpy()
    let backgroundB = CameraSessionRuntimeBackgroundMaintainerSpy()
    let identity = CameraSessionIdentity(cameraName: "X-T5", peripheralID: UUID())
    let bindingA = CameraSessionRuntimeBinding(sessionID: UUID(), identity: identity)
    let bindingB = CameraSessionRuntimeBinding(sessionID: UUID(), identity: identity)

    deferredTransport.attach(transportA, binding: bindingA)
    deferredBackground.attach(backgroundA, binding: bindingA)
    deferredBackground.start(allowingPtpKeepAlive: true)
    deferredTransport.attach(transportB, binding: bindingB)
    deferredBackground.attach(backgroundB, binding: bindingB)
    deferredTransport.startTransfer(handle: 42, mode: .original)

    XCTAssertEqual(transportA.retireForSessionSupersessionCount, 1)
    XCTAssertEqual(transportA.cancelActiveTransferCount, 0)
    XCTAssertEqual(transportA.terminateCount, 0)
    XCTAssertEqual(backgroundA.stopCount, 1)
    XCTAssertEqual(transportB.startedHandles, [42])
    XCTAssertEqual(backgroundB.ptpKeepAliveModes, [true])
  }

  @MainActor
  func testDeferredRuntimeTransportForwardsEachDownloadLeaseReleaseExactlyOnce() {
    let deferredTransport = CameraSessionRuntimeDeferredTransport()
    let transport = CameraSessionRuntimeSpy()

    deferredTransport.attach(transport, binding: CameraSessionRuntimeBinding(
      sessionID: UUID(),
      identity: CameraSessionIdentity(cameraName: "X-T5")
    ))
    deferredTransport.beginDownloadLease()
    deferredTransport.endDownloadLease()

    XCTAssertEqual(transport.beginDownloadLeaseCount, 1)
    XCTAssertEqual(transport.endDownloadLeaseCount, 1)
  }

  @MainActor
  func testCameraSessionRuntimeRoutesHomeBleCommandsThroughItsConnectionController() throws {
    let controller = CameraSessionRuntimeHomeCommandSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      connectionController: controller
    )

    XCTAssertTrue(runtime.restoreRememberedCameraRecords())
    runtime.requestCameraDiscovery()
    runtime.clearConnectionLogs()
    runtime.acknowledgeSystemBluetoothPairingCleanupForFreshPairing()
    runtime.forgetLastRememberedCamera()
    runtime.forgetRememberedCamera(peripheralID: controller.rememberedPeripheralID)

    XCTAssertEqual(controller.restoreCount, 1)
    XCTAssertEqual(controller.scanCount, 1)
    XCTAssertEqual(controller.clearLogsCount, 1)
    XCTAssertEqual(controller.acknowledgeCleanupCount, 1)
    XCTAssertEqual(controller.forgetLastCount, 1)
    XCTAssertEqual(controller.forgottenPeripheralIDs, [controller.rememberedPeripheralID])
  }

  @MainActor
  func testNativeHomeConnectionPresentationBlocksOnlyTheRelevantHomeActions() {
    XCTAssertEqual(
      NativeHomeConnectionPresentationPolicy.resolve(
        requiresSystemBluetoothPairingCleanup: true,
        isPairingConfirmationBlockingRememberedGalleryEntry: false
      ),
      .systemBluetoothCleanup
    )
    XCTAssertEqual(
      NativeHomeConnectionPresentationPolicy.resolve(
        requiresSystemBluetoothPairingCleanup: false,
        isPairingConfirmationBlockingRememberedGalleryEntry: true
      ),
      .pairingConfirmation
    )
    XCTAssertEqual(
      NativeHomeConnectionPresentationPolicy.resolve(
        requiresSystemBluetoothPairingCleanup: false,
        isPairingConfirmationBlockingRememberedGalleryEntry: false
      ),
      .normal
    )
  }

  @MainActor
  func testCameraSessionRuntimeRepairsBluetoothCleanupBeforeStartingFreshDiscovery() {
    let controller = CameraSessionRuntimeHomeCommandSpy()
    let runtime = CameraSessionRuntime(
      transport: CameraSessionRuntimeSpy(),
      connectionController: controller
    )

    runtime.repairSystemBluetoothCleanupAndStartFreshDiscovery()

    XCTAssertEqual(controller.events, [.acknowledgeCleanup, .forgetLast, .clearLogs, .scan])
  }

}

private final class CameraSessionRuntimeHomeCommandSpy: CameraSessionRuntimeConnectionControlling {
  enum Event: Equatable {
    case restore
    case scan
    case clearLogs
    case acknowledgeCleanup
    case forgetLast
    case forgetRemembered
  }

  let rememberedPeripheralID = UUID()
  var onSnapshotChanged: ((IOSCameraHomeSnapshot) -> Void)?
  var onLogAppended: ((String) -> Void)?
  private(set) var restoreCount = 0
  private(set) var scanCount = 0
  private(set) var clearLogsCount = 0
  private(set) var acknowledgeCleanupCount = 0
  private(set) var forgetLastCount = 0
  private(set) var forgottenPeripheralIDs: [UUID] = []
  private(set) var events: [Event] = []

  var currentLogText: String { "" }
  var logFileURL: URL { FileManager.default.temporaryDirectory }
  var rememberedCameraRecords: [IOSCameraRememberedCameraRecord] { [] }
  var hasPreconnectedProbe: Bool { false }
  var preconnectedProbePeripheralID: UUID? { nil }

  func snapshot() -> IOSCameraHomeSnapshot {
    IOSCameraHomeSnapshot(
      discoveredCameras: [],
      rememberedCameras: [],
      status: "",
      isBusy: false,
      requiresSystemBluetoothPairingCleanup: false
    )
  }

  func restoreLastPairedCameraIfAvailable() -> Bool {
    restoreCount += 1
    events.append(.restore)
    return true
  }

  func startScan() {
    scanCount += 1
    events.append(.scan)
  }
  func clearLogs() {
    clearLogsCount += 1
    events.append(.clearLogs)
  }
  func publishSystemBluetoothCleanupBlockIfNeeded() -> Bool { false }
  func acknowledgeSystemBluetoothPairingCleanupForFreshPairing() {
    acknowledgeCleanupCount += 1
    events.append(.acknowledgeCleanup)
  }
  func forgetLastPairedCamera() {
    forgetLastCount += 1
    events.append(.forgetLast)
  }
  func forgetRememberedCamera(peripheralID: UUID) {
    forgottenPeripheralIDs.append(peripheralID)
    events.append(.forgetRemembered)
  }
  func probePairing(peripheralID _: UUID) async -> CameraVendorPairingProbeResult { .bluetoothOff }
  func cancelPairingProbe(reason _: String) {}
}

@MainActor
private final class CameraSessionRuntimeSpy: CameraSessionRuntimeTransport {
  private(set) var beginDownloadLeaseCount = 0
  private(set) var endDownloadLeaseCount = 0
  private(set) var cancelActiveTransferCount = 0
  private(set) var cancelActiveTransferReasons: [String] = []
  private(set) var retireForSessionSupersessionCount = 0
  private(set) var terminateCount = 0
  private(set) var startedHandles: [UInt32] = []
  private(set) var thumbnailHandles: [Int] = []
  private(set) var finishedThumbnailBatchHandles: [[Int]] = []
  private(set) var requestedCatalogLabels: [String] = []
  private(set) var initialCatalogRequestCount = 0
  private(set) var capturedCatalogQueries: [CameraVendorCatalogQuery] = []
  var suspendsCatalogRequests = false
  var suspendsThumbnailRequestsUntilReleased = false
  var catalogError: Error?
  var onThumbnailRequestCancelled: (@Sendable () -> Void)?
  var onTerminate: (() -> Void)?
  var catalogItems: [CameraVendorGalleryItem] = []
  private var thumbnailRequestContinuations: [CheckedContinuation<Void, Never>] = []
  private var thumbnailCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var catalogContinuations: [CheckedContinuation<CameraVendorCatalogSnapshot, Error>?] = []
  private var catalogCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var initialCatalogContinuations: [CheckedContinuation<CameraVendorCatalogSnapshot, Error>?] = []
  private var initialCatalogCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func beginDownloadLease() {
    beginDownloadLeaseCount += 1
  }

  func endDownloadLease() {
    endDownloadLeaseCount += 1
  }

  func fetchThumbnailWithInfo(for handle: Int) async throws -> CameraVendorGalleryThumbnail {
    thumbnailHandles.append(handle)
    resumeThumbnailCountWaitersIfNeeded()
    if suspendsThumbnailRequestsUntilReleased {
      let cancellationHandler = onThumbnailRequestCancelled
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          thumbnailRequestContinuations.append(continuation)
        }
      } onCancel: {
        cancellationHandler?()
      }
      try Task.checkCancellation()
    }
    return CameraVendorGalleryThumbnail(data: Data(), item: nil)
  }

  func fetchThumbnail(for handle: Int) async throws -> Data {
    thumbnailHandles.append(handle)
    return Data()
  }

  func fetchPreviewImage(for handle: Int) async throws -> Data {
    thumbnailHandles.append(handle)
    return Data()
  }

  func fetchCameraCatalog(query: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    requestedCatalogLabels.append(query.label)
    capturedCatalogQueries.append(query)
    resumeCatalogCountWaitersIfNeeded()
    if let catalogError { throw catalogError }
    guard suspendsCatalogRequests else { return catalogSnapshot(items: catalogItems) }
    return try await withCheckedThrowingContinuation { continuation in
      catalogContinuations.append(continuation)
    }
  }

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    initialCatalogRequestCount += 1
    resumeInitialCatalogCountWaitersIfNeeded()
    guard suspendsCatalogRequests else { return catalogSnapshot(items: catalogItems) }
    return try await withCheckedThrowingContinuation { continuation in
      initialCatalogContinuations.append(continuation)
    }
  }

  func waitForInitialCatalogRequestCount(_ count: Int) async {
    if initialCatalogRequestCount >= count { return }
    await withCheckedContinuation { continuation in
      initialCatalogCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func resolveInitialCatalogRequest(at index: Int, items: [CameraVendorGalleryItem]) {
    guard initialCatalogContinuations.indices.contains(index),
          let continuation = initialCatalogContinuations[index] else { return }
    initialCatalogContinuations[index] = nil
    continuation.resume(returning: catalogSnapshot(items: items))
  }

  func waitForCatalogRequestCount(_ count: Int) async {
    if requestedCatalogLabels.count >= count { return }
    await withCheckedContinuation { continuation in
      catalogCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func waitForThumbnailRequestCount(_ count: Int) async {
    if thumbnailHandles.count >= count { return }
    await withCheckedContinuation { continuation in
      thumbnailCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func releaseThumbnailRequests() {
    let continuations = thumbnailRequestContinuations
    thumbnailRequestContinuations = []
    continuations.forEach { $0.resume() }
  }

  func resolveCatalogRequest(at index: Int, items: [CameraVendorGalleryItem]) {
    guard catalogContinuations.indices.contains(index),
          let continuation = catalogContinuations[index] else { return }
    catalogContinuations[index] = nil
    continuation.resume(returning: catalogSnapshot(items: items))
  }

  private func catalogSnapshot(items: [CameraVendorGalleryItem]) -> CameraVendorCatalogSnapshot {
    CameraVendorCatalogSnapshot(
      dateGroups: items.isEmpty ? [] : [
        CameraVendorSpecifiedObjectDateGroup(
          dateText: "20260712",
          objectCount: UInt32(items.count)
        )
      ],
      orderedHandles: items.map { UInt32($0.handle) },
      items: items
    )
  }

  private func resumeCatalogCountWaitersIfNeeded() {
    let ready = catalogCountWaiters.filter { requestedCatalogLabels.count >= $0.count }
    catalogCountWaiters.removeAll { requestedCatalogLabels.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  private func resumeInitialCatalogCountWaitersIfNeeded() {
    let ready = initialCatalogCountWaiters.filter { initialCatalogRequestCount >= $0.count }
    initialCatalogCountWaiters.removeAll { initialCatalogRequestCount >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  private func resumeThumbnailCountWaitersIfNeeded() {
    let ready = thumbnailCountWaiters.filter { thumbnailHandles.count >= $0.count }
    thumbnailCountWaiters.removeAll { thumbnailHandles.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  func beginVisibleThumbnailBatch(handles _: [Int]) {}
  func finishVisibleThumbnailBatch(handles: [Int]) {
    finishedThumbnailBatchHandles.append(handles)
  }

  func startTransfer(handle: UInt32, mode: CameraVendorTransferDownloadMode) {
    startedHandles.append(handle)
  }

  func cancelActiveTransfer(reason: String) {
    cancelActiveTransferCount += 1
    cancelActiveTransferReasons.append(reason)
  }

  func retireForSessionSupersession() {
    retireForSessionSupersessionCount += 1
  }

  func terminateCameraCommunication(reason: String) {
    terminateCount += 1
    onTerminate?()
  }
}

@MainActor
private final class CameraSessionRuntimeCommandSinkSpy: CameraSessionRuntimeCommandHandling {
  private(set) var lifecycleEvents: [String] = []

  func send(_ command: CameraSessionCommand) {
    switch command {
    case .applicationWillResignActive:
      lifecycleEvents.append("willResignActive")
    case .applicationEnteredBackground:
      lifecycleEvents.append("enteredBackground")
    case .applicationBecameActive:
      lifecycleEvents.append("becameActive")
    default:
      break
    }
  }
}

@MainActor
private final class CameraSessionRuntimeLegacyResumeMigratorSpy: CameraSessionRuntimeLegacyResumeMigrating {
  private(set) var discardCount = 0

  func discardLegacyRememberedGalleryResume() {
    discardCount += 1
  }
}

@MainActor
private final class CameraSessionRuntimeExecutionAuthoritySpy: CameraSessionRuntimeExecutionAuthorizing {
  private(set) var acquireCount = 0
  private(set) var releaseCount = 0
  private let grantsAuthority: Bool

  init(grantsAuthority: Bool = true) {
    self.grantsAuthority = grantsAuthority
  }

  func acquire(reason: String) -> Bool {
    acquireCount += 1
    return grantsAuthority
  }

  func release(reason: String) {
    releaseCount += 1
  }
}

@MainActor
private final class CameraSessionPresentationRecorder {
  private(set) var presentations: [CameraSessionPresentation] = []

  func record(_ presentation: CameraSessionPresentation) {
    presentations.append(presentation)
  }
}

@MainActor
private final class CameraSessionRuntimeActivityReporterSpy: CameraSessionRuntimeActivityReporting {
  private(set) var snapshots: [CameraSessionRuntimeActivitySnapshot] = []
  private(set) var endedSessionIDs: [UUID] = []
  private(set) var staleCleanupReasons: [String] = []

  func publish(_ snapshot: CameraSessionRuntimeActivitySnapshot, reason _: String) {
    snapshots.append(snapshot)
  }

  func end(sessionID: UUID, reason _: String) {
    endedSessionIDs.append(sessionID)
  }

  func cleanupStale(reason: String) {
    staleCleanupReasons.append(reason)
  }
}

private final class CameraVendorBleBackgroundKeepAliveSpy: CameraVendorBleBackgroundKeepAlive {
  private(set) var reasons: [String] = []

  func performBackgroundBleKeepAlive(reason: String) {
    reasons.append(reason)
  }
}

private final class CameraSessionRuntimeGalleryServiceSpy: CameraVendorGalleryService, CameraVendorActiveDownloadInterrupting, CameraVendorActiveDownloadCancellationRequesting {
  private(set) var requestedHandles: [Int] = []
  private(set) var interruptCount = 0
  private(set) var softCancellationCount = 0
  var ignoresTaskCancellation = false
  var blocksDownloadUntilCancellation = false
  var previewItem: CameraVendorGalleryItem?
  var downloadedFileTransferTiming: CameraVendorOriginalFileTransferTiming?
  var downloadedFileURL: URL?
  private var blockedDownloadContinuation: CheckedContinuation<Void, Error>?

  func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
    CameraVendorCatalogSnapshot(
      dateGroups: [],
      orderedHandles: [],
      items: []
    )
  }

  func fetchCameraCatalog(query _: CameraVendorCatalogQuery) async throws -> CameraVendorCatalogSnapshot {
    CameraVendorCatalogSnapshot(
      dateGroups: [],
      orderedHandles: [],
      items: []
    )
  }
  func fetchThumbnail(for handle: Int) async throws -> Data { Data() }
  func fetchPreviewImage(for handle: Int) async throws -> Data { Data() }
  func fetchPreviewImageWithInfo(for handle: Int) async throws -> CameraVendorGalleryPreview {
    CameraVendorGalleryPreview(data: Data(), item: previewItem)
  }
  func downloadOriginal(for handle: Int) async throws -> Data { Data() }

  func downloadOriginalData(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedPhotoData {
    CameraVendorDownloadedPhotoData(data: Data(), filename: "DSCF\(handle).RAF")
  }

  func downloadOriginalFile(for handle: Int) async throws -> CameraVendorDownloadedFile {
    try await downloadOriginalFile(for: handle, mode: .original)
  }

  func downloadOriginalFile(
    for handle: Int,
    mode: CameraVendorTransferDownloadMode
  ) async throws -> CameraVendorDownloadedFile {
    requestedHandles.append(handle)
    if blocksDownloadUntilCancellation {
      try await withCheckedThrowingContinuation { continuation in
        blockedDownloadContinuation = continuation
      }
    }
    if ignoresTaskCancellation {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return CameraVendorDownloadedFile(
      fileURL: downloadedFileURL ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("camtransfer-test-\(UUID().uuidString).RAF"),
      filename: "DSCF\(handle).RAF",
      mediaType: .raw,
      transferTiming: downloadedFileTransferTiming
    )
  }

  func interruptActiveDownload(reason: String) {
    interruptCount += 1
  }

  func requestActiveDownloadCancellation(reason: String) {
    softCancellationCount += 1
    blockedDownloadContinuation?.resume(throwing: NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: reason]
    ))
    blockedDownloadContinuation = nil
  }
}

@MainActor
private final class CameraSessionRuntimeFileSaverSpy: CameraSessionRuntimeFileSaving {
  private(set) var savedFilenames: [String] = []
  var remainingFailures: [Error] = []
  var waitsAtCommitBoundary = false
  var waitsAfterCommit = false
  var onSaveStarted: (() -> Void)?
  var onSaveCommitted: (() -> Void)?
  private var commitBoundaryContinuation: CheckedContinuation<Void, Never>?

  func save(
    _ file: CameraVendorDownloadedFile,
    commitGate: CameraSessionRuntimeTransferCommitGate,
    onPhotoLibraryCommit: @escaping @MainActor () -> Void
  ) async throws {
    if !remainingFailures.isEmpty {
      throw remainingFailures.removeFirst()
    }
    onSaveStarted?()
    if waitsAtCommitBoundary {
      await withCheckedContinuation { continuation in
        commitBoundaryContinuation = continuation
      }
    }
    guard commitGate.allowsPhotoLibraryCommit else {
      throw CancellationError()
    }
    savedFilenames.append(file.filename)
    onSaveCommitted?()
    onPhotoLibraryCommit()
    if waitsAfterCommit {
      await withCheckedContinuation { continuation in
        commitBoundaryContinuation = continuation
      }
    }
  }

  func resumeCommitBoundary() {
    commitBoundaryContinuation?.resume()
    commitBoundaryContinuation = nil
  }
}

@MainActor
private final class CameraSessionRuntimeRecoveryStoreSpy: CameraSessionRuntimeRecoveryStoring {
  struct Record: Equatable {
    let identity: CameraSessionIdentity
    let handles: [UInt32]
    let inFlightHandle: UInt32?
    let completedCount: Int
    let failedCount: Int
    let origin: CameraDownloadOrigin
    let completionPolicy: CameraDownloadCompletionPolicy
    let reason: String
  }

  private(set) var records: [Record] = []
  private var persistedSnapshot: CameraDownloadSessionSnapshot?
  private(set) var clearCount = 0

  init(snapshot: CameraDownloadSessionSnapshot? = nil) {
    persistedSnapshot = snapshot
  }

  func persistInterruptedRecoverable(
    sessionID _: UUID,
    identity: CameraSessionIdentity,
    downloads: [CameraSessionQueuedDownload],
    inFlightHandle: UInt32?,
    completedCount: Int,
    failedCount: Int,
    origin: CameraDownloadOrigin,
    completionPolicy: CameraDownloadCompletionPolicy,
    reason: String
  ) {
    records.append(
      Record(
        identity: identity,
        handles: downloads.map(\.handle),
        inFlightHandle: inFlightHandle,
        completedCount: completedCount,
        failedCount: failedCount,
        origin: origin,
        completionPolicy: completionPolicy,
        reason: reason
      )
    )
  }

  func loadInterruptedRecoverable() -> CameraDownloadSessionSnapshot? {
    persistedSnapshot
  }

  func clear() {
    clearCount += 1
    persistedSnapshot = nil
  }
}

@MainActor
private final class CameraSessionRuntimeNonPersistingRecoveryStore: CameraSessionRuntimeRecoveryStoring {
  private(set) var persistAttempts = 0

  func persistInterruptedRecoverable(
    sessionID _: UUID,
    identity _: CameraSessionIdentity,
    downloads _: [CameraSessionQueuedDownload],
    inFlightHandle _: UInt32?,
    completedCount _: Int,
    failedCount _: Int,
    origin _: CameraDownloadOrigin,
    completionPolicy _: CameraDownloadCompletionPolicy,
    reason _: String
  ) throws {
    persistAttempts += 1
    throw CameraSessionRuntimeTestError.recoveryPersistenceFailed
  }

  func loadInterruptedRecoverable() -> CameraDownloadSessionSnapshot? { nil }
  func clear() {}
}

@MainActor
private final class CameraSessionRuntimeRecoveryConnectorSpy: CameraSessionRuntimeRecoveryConnecting, CameraSessionRuntimeRecoveryCancelling {
  private(set) var requestedIdentities: [CameraSessionIdentity] = []
  private(set) var cancelledReasons: [String] = []
  private var requestResults: [Bool]

  init(requestResults: [Bool] = [true]) {
    self.requestResults = requestResults
  }

  func requestRecoveredConnection(
    identity: CameraSessionIdentity,
    completion: @escaping (Bool) -> Void
  ) {
    requestedIdentities.append(identity)
    completion(requestResults.isEmpty ? true : requestResults.removeFirst())
  }

  func cancelRecoveryConnection(reason: String) {
    cancelledReasons.append(reason)
  }
}

@MainActor
private final class CameraSessionRuntimeSavedHandleStoreSpy: CameraSessionRuntimeSavedHandleStoring {
  private var handles: Set<Int>
  private let onRecord: (() -> Void)?
  private(set) var removedHandles: [Int] = []
  private(set) var clearCount = 0
  private(set) var recordedItemsByHandle: [Int: CameraVendorGalleryItem] = [:]
  private(set) var recordedHandleOnly: [Int] = []

  init(onRecord: @escaping () -> Void) {
    self.onRecord = onRecord
    self.handles = []
  }

  init(savedHandles: Set<Int>) {
    self.onRecord = nil
    self.handles = savedHandles
  }

  func savedHandles(identity _: CameraSessionIdentity) -> Set<Int> {
    handles
  }

  func historyItems(identity _: CameraSessionIdentity) -> [CameraVendorGalleryItem] {
    []
  }

  func recordSaved(handle: Int, item: CameraVendorGalleryItem?, identity _: CameraSessionIdentity) {
    handles.insert(handle)
    if let item {
      recordedItemsByHandle[handle] = item
    } else {
      recordedHandleOnly.append(handle)
    }
    onRecord?()
  }

  func removeSaved(handle: Int, identity _: CameraSessionIdentity) {
    handles.remove(handle)
    removedHandles.append(handle)
  }

  func clear(identity _: CameraSessionIdentity) {
    handles = []
    clearCount += 1
  }
}

private enum CameraSessionRuntimeTestError: Error {
  case socketClosed
  case photoSaveFailed
  case recoveryPersistenceFailed
}

@MainActor
private final class CameraSessionRuntimeBackgroundMaintainerSpy: CameraSessionRuntimeBackgroundMaintaining, CameraSessionRuntimeBackgroundExecutionSustaining, CameraSessionRuntimeBackgroundExecutionPreparing {
  private(set) var ptpKeepAliveModes: [Bool] = []
  private(set) var stopCount = 0
  private(set) var prepareCount = 0
  let sustainsBackgroundExecution: Bool

  init(sustainsBackgroundExecution: Bool = false) {
    self.sustainsBackgroundExecution = sustainsBackgroundExecution
  }

  var isSustainingBackgroundExecution: Bool {
    sustainsBackgroundExecution
  }

  func start(allowingPtpKeepAlive: Bool) {
    ptpKeepAliveModes.append(allowingPtpKeepAlive)
  }

  func stop(reason: String) {
    stopCount += 1
  }

  func prepareBackgroundExecution() {
    prepareCount += 1
  }

}

@MainActor
private final class CameraSessionRuntimeConnectionFlowSpy: CameraSessionRuntimeConnectionFlow {
  static let record = IOSCameraRememberedCameraRecord(
    peripheralID: UUID(),
    identity: IOSCameraIdentity(
      cameraID: "X-T5",
      displayName: "X-T5",
      serialNumber: "serial",
      bleEndpoint: IOSCameraBleEndpoint(identifier: UUID().uuidString, address: nil)
    ),
    wifiCredential: IOSCameraWifiCredential(
      ssid: "FUJIFILM",
      passphrase: "password",
      bssid: nil,
      source: .bleHandshake
    ),
    connectedDeviceName: "iPhone",
    systemBluetoothPairingValidatedAt: Date()
  )

  private(set) var state: IOSCameraConnectFlowState = .idle
  private(set) var navigationEvent: IOSCameraConnectFlowNavigationEvent?
  private(set) var cancelCount = 0
  private var rememberedContinuation: CheckedContinuation<Void, Never>?
  private var rememberedStartedContinuation: CheckedContinuation<Void, Never>?

  func startPairing(camera _: IOSCameraDiscoveredCamera) async throws {}
  func confirmPairing() async throws {}

  func enterRememberedGallery(record _: IOSCameraRememberedCameraRecord) async throws {
    state = .connecting(.reconnectPairedBle)
    rememberedStartedContinuation?.resume()
    rememberedStartedContinuation = nil
    await withCheckedContinuation { continuation in
      rememberedContinuation = continuation
    }
    let session = IOSCameraGallerySession(
      cameraID: "X-T5",
      rememberedPeripheralID: Self.record.peripheralID,
      ptpSessionID: "x-t5-ptp",
      presentation: IOSCameraGalleryPresentation(
        deviceName: "X-T5",
        serialNumber: "serial",
        connectedDeviceName: "iPhone",
        preferCompressedDownloads: false
      )
    )
    state = .galleryReady(session)
    navigationEvent = .enterGallery(session)
  }

  func cancelActiveFlow() {
    cancelCount += 1
  }

  func waitUntilRememberedGalleryStarts() async {
    await withCheckedContinuation { continuation in
      rememberedStartedContinuation = continuation
    }
  }

  func finishRememberedGallery() {
    rememberedContinuation?.resume()
    rememberedContinuation = nil
  }

  func resetStateAfterConnectionCompletion() {
    state = .idle
    navigationEvent = nil
  }
}

@MainActor
private final class CameraSessionRuntimeBlockingConfirmationFlowSpy: CameraSessionRuntimeConnectionFlow {
  private(set) var state: IOSCameraConnectFlowState = .waitingForPairingConfirmation
  var navigationEvent: IOSCameraConnectFlowNavigationEvent? { nil }
  private(set) var confirmationCount = 0
  private var confirmationContinuations: [CheckedContinuation<Void, Never>] = []
  private var confirmationStartedContinuation: CheckedContinuation<Void, Never>?

  func startPairing(camera _: IOSCameraDiscoveredCamera) async throws {}

  func confirmPairing() async throws {
    confirmationCount += 1
    confirmationStartedContinuation?.resume()
    confirmationStartedContinuation = nil
    await withCheckedContinuation { continuation in
      confirmationContinuations.append(continuation)
    }
  }

  func enterRememberedGallery(record _: IOSCameraRememberedCameraRecord) async throws {}
  func cancelActiveFlow() {}

  func waitUntilConfirmationStarts() async {
    if confirmationCount > 0 { return }
    await withCheckedContinuation { continuation in
      confirmationStartedContinuation = continuation
    }
  }

  func finishConfirmation() {
    let continuations = confirmationContinuations
    confirmationContinuations = []
    continuations.forEach { $0.resume() }
  }
}

@MainActor
private final class CameraSessionRuntimeGallerySessionActivatorSpy: CameraSessionRuntimeGallerySessionActivating {
  private(set) var activatedCameraIDs: [String] = []

  func activateGallerySession(
    _ session: IOSCameraGallerySession,
    runtime _: CameraSessionRuntime
  ) throws -> CameraSessionRuntimeGalleryPresentationPayload {
    activatedCameraIDs.append(session.cameraID)
    return CameraSessionRuntimeGalleryPresentationPayload(
      rememberedPeripheralID: CameraSessionRuntimeConnectionFlowSpy.record.peripheralID,
      summary: CameraVendorConnectionSummary(deviceName: "X-T5", serialNumber: "serial")
    )
  }
}

@MainActor
private final class CameraGalleryCatalogRuntimeSourceSpy: CameraGalleryCatalogRuntimeSource {
  private final class DetailsRequestContinuationRegistry: @unchecked Sendable {
    private enum State {
      case waitingForContinuation
      case suspended(CheckedContinuation<Void, Never>)
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    func begin(_ requestID: UUID) {
      lock.lock()
      states[requestID] = .waitingForContinuation
      lock.unlock()
    }

    func suspend(
      _ requestID: UUID,
      continuation: CheckedContinuation<Void, Never>
    ) {
      var shouldResume = false
      lock.lock()
      if case .waitingForContinuation? = states[requestID] {
        states[requestID] = .suspended(continuation)
      } else {
        shouldResume = true
      }
      lock.unlock()
      if shouldResume {
        continuation.resume()
      }
    }

    func cancel(_ requestID: UUID) {
      var continuation: CheckedContinuation<Void, Never>?
      lock.lock()
      if case let .suspended(pending)? = states.removeValue(forKey: requestID) {
        continuation = pending
      }
      lock.unlock()
      continuation?.resume()
    }

    func releaseAll() {
      lock.lock()
      let continuations = states.values.compactMap { state -> CheckedContinuation<Void, Never>? in
        guard case let .suspended(continuation) = state else { return nil }
        return continuation
      }
      states.removeAll()
      lock.unlock()
      continuations.forEach { $0.resume() }
    }
  }

  private var catalogContinuations: [CheckedContinuation<CameraGalleryCatalogSnapshot, Error>?] = []
  private var catalogCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var thumbnailCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var detailsCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var thumbnailBatchFinishStartWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private let detailsRequestContinuations = DetailsRequestContinuationRegistry()
  private var thumbnailBatchFinishContinuations: [CheckedContinuation<Void, Never>] = []
  private var thumbnailResultContinuations: [CheckedContinuation<Void, Never>] = []
  var catalogError: Error?
  var suspendsCatalogRequests = false
  var suspendsChildRequests = false
  var suspendsDetailsRequestsUntilReleased = false
  var detailsHandlesToSuspend: Set<Int> = []
  var delaysDetailsCancellationUntilReleased = false
  var suspendsThumbnailBatchFinishUntilReleased = false
  var suspendsThumbnailResultsUntilReleased = false
  var thumbnailError: Error?
  var thumbnailFailuresRemaining: [Int: Int] = [:]
  var thumbnailResolvedMetadataByHandle: [Int: CameraGalleryResolvedItemMetadata] = [:]
  var onDetailsRequestCancelled: (@Sendable () -> Void)?
  var initialSnapshotHandles: [Int] = [3, 2, 1]
  var initialSnapshotHasDateGroups = true
  var returnsResolvedDetails = false
  private(set) var catalogIntents: [CameraGalleryFilterIntent] = []
  private(set) var initialCatalogRequestCount = 0
  private(set) var requestedThumbnailHandles: [Int] = []
  private(set) var requestedDetailsHandles: [Int] = []
  private(set) var begunThumbnailBatchHandles: [[Int]] = []
  private(set) var thumbnailBatchFinishStartCount = 0
  private(set) var finishedThumbnailBatchHandles: [[Int]] = []

  func loadExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot {
    try await loadInitialCatalog()
  }

  func loadExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot {
    let formatIntent: CameraGalleryFormatIntent
    switch format {
    case .jpg: formatIntent = .jpg
    case .raw: formatIntent = .raw
    case .heif: formatIntent = .heif
    }
    return try await loadCatalog(for: CameraGalleryFilterIntent(
      date: .all,
      format: formatIntent,
      sort: .newest,
      downloadStatus: .all
    ))
  }

  func loadSubtractBaselineCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot {
    try await loadExactCatalog(for: format)
  }

  func loadInitialCatalog() async throws -> CameraGalleryCatalogSnapshot {
    initialCatalogRequestCount += 1
    if let catalogError {
      throw catalogError
    }
    return Self.snapshot(handles: initialSnapshotHandles, includeDateGroups: initialSnapshotHasDateGroups)
  }

  func loadCatalog(for intent: CameraGalleryFilterIntent) async throws -> CameraGalleryCatalogSnapshot {
    catalogIntents.append(intent)
    resumeCatalogCountWaitersIfNeeded()
    if let catalogError {
      throw catalogError
    }
    guard suspendsCatalogRequests else {
      return Self.snapshot(handles: [3, 2, 1])
    }
    return try await withCheckedThrowingContinuation { continuation in
      catalogContinuations.append(continuation)
    }
  }

  func loadThumbnail(handle: Int) async throws -> CameraGalleryThumbnailResult {
    requestedThumbnailHandles.append(handle)
    resumeThumbnailCountWaitersIfNeeded()
    if suspendsThumbnailResultsUntilReleased {
      await withCheckedContinuation { continuation in
        thumbnailResultContinuations.append(continuation)
      }
    }
    if let thumbnailError {
      throw thumbnailError
    }
    if let remaining = thumbnailFailuresRemaining[handle], remaining > 0 {
      thumbnailFailuresRemaining[handle] = remaining - 1
      throw NSError(domain: "CameraGalleryCatalogRuntimeSourceSpy.thumbnail", code: handle)
    }
    if suspendsChildRequests {
      while !Task.isCancelled {
        await Task.yield()
      }
      throw CancellationError()
    }
    return CameraGalleryThumbnailResult(
      data: Data([UInt8(truncatingIfNeeded: handle)]),
      resolvedMetadata: thumbnailResolvedMetadataByHandle[handle]
    )
  }

  func loadDetails(handle: Int) async throws -> CameraGalleryDetailsSourceResult {
    requestedDetailsHandles.append(handle)
    resumeDetailsCountWaitersIfNeeded()
    if suspendsDetailsRequestsUntilReleased || detailsHandlesToSuspend.contains(handle) {
      let requestID = UUID()
      detailsRequestContinuations.begin(requestID)
      let continuationRegistry = detailsRequestContinuations
      let cancellationHandler = onDetailsRequestCancelled
      let delaysCancellation = delaysDetailsCancellationUntilReleased
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          continuationRegistry.suspend(requestID, continuation: continuation)
        }
      } onCancel: {
        cancellationHandler?()
        if !delaysCancellation {
          continuationRegistry.cancel(requestID)
        }
      }
      try Task.checkCancellation()
    }
    if returnsResolvedDetails {
      return CameraGalleryDetailsSourceResult(
        handle: handle,
        orientation: .confirmed(1),
        refinedFormat: .confirmed(.jpg),
        notes: [],
        resolvedMetadata: CameraGalleryResolvedItemMetadata(
          handle: handle,
          filename: "DSCF\(handle).JPG",
          formatLabel: "JPG",
          captureDate: "20250615T150640",
          byteSizeText: "1 KB",
          compressedSize: 1_024,
          orientation: 1,
          formatHints: []
        )
      )
    }
    if suspendsChildRequests {
      while !Task.isCancelled {
        await Task.yield()
      }
      throw CancellationError()
    }
    throw CancellationError()
  }

  func resetEnrichmentCache() {}

  func beginVisibleThumbnailBatch(handles: [Int]) {
    begunThumbnailBatchHandles.append(handles)
  }
  func finishVisibleThumbnailBatch(handles: [Int]) async {
    thumbnailBatchFinishStartCount += 1
    resumeThumbnailBatchFinishStartWaitersIfNeeded()
    if suspendsThumbnailBatchFinishUntilReleased {
      await withCheckedContinuation { continuation in
        thumbnailBatchFinishContinuations.append(continuation)
      }
    }
    finishedThumbnailBatchHandles.append(handles)
  }

  func waitForCatalogRequestCount(_ count: Int) async {
    if catalogIntents.count >= count { return }
    await withCheckedContinuation { continuation in
      catalogCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func waitForThumbnailRequestCount(_ count: Int) async {
    if requestedThumbnailHandles.count >= count { return }
    await withCheckedContinuation { continuation in
      thumbnailCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func waitForDetailsRequestCount(_ count: Int) async {
    if requestedDetailsHandles.count >= count { return }
    await withCheckedContinuation { continuation in
      detailsCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func waitForThumbnailBatchFinishStartCount(_ count: Int) async {
    if thumbnailBatchFinishStartCount >= count { return }
    await withCheckedContinuation { continuation in
      thumbnailBatchFinishStartWaiters.append((count: count, continuation: continuation))
    }
  }

  func releaseDetailsRequests() {
    detailsRequestContinuations.releaseAll()
  }

  func releaseThumbnailBatchFinishes() {
    let continuations = thumbnailBatchFinishContinuations
    thumbnailBatchFinishContinuations = []
    continuations.forEach { $0.resume() }
  }

  func releaseThumbnailResults() {
    suspendsThumbnailResultsUntilReleased = false
    let continuations = thumbnailResultContinuations
    thumbnailResultContinuations = []
    continuations.forEach { $0.resume() }
  }

  func resolveCatalogRequest(at index: Int, snapshot: CameraGalleryCatalogSnapshot) {
    guard catalogContinuations.indices.contains(index),
          let continuation = catalogContinuations[index] else {
      return
    }
    catalogContinuations[index] = nil
    continuation.resume(returning: snapshot)
  }

  static func snapshot(
    handles: [Int],
    includeDateGroups: Bool = true
  ) -> CameraGalleryCatalogSnapshot {
    let items = handles.map {
      CameraVendorGalleryItem(
        handle: $0,
        filename: "0x\(String(format: "%08X", $0))",
        formatLabel: "",
        captureDate: includeDateGroups ? "20260714" : "",
        byteSizeText: ""
      )
    }
    return CameraGalleryCatalogSnapshot(
      snapshotID: CameraGallerySnapshotID(),
      dateGroups: includeDateGroups ? [
        CameraVendorSpecifiedObjectDateGroup(
          dateText: "20260714",
          objectCount: UInt32(handles.count)
        ),
      ] : [],
      orderedHandles: handles.map(UInt32.init),
      items: items
    )
  }

  private func resumeCatalogCountWaitersIfNeeded() {
    let ready = catalogCountWaiters.filter { catalogIntents.count >= $0.count }
    catalogCountWaiters.removeAll { catalogIntents.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  private func resumeThumbnailCountWaitersIfNeeded() {
    let ready = thumbnailCountWaiters.filter { requestedThumbnailHandles.count >= $0.count }
    thumbnailCountWaiters.removeAll { requestedThumbnailHandles.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  private func resumeDetailsCountWaitersIfNeeded() {
    let ready = detailsCountWaiters.filter { requestedDetailsHandles.count >= $0.count }
    detailsCountWaiters.removeAll { requestedDetailsHandles.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }

  private func resumeThumbnailBatchFinishStartWaitersIfNeeded() {
    let ready = thumbnailBatchFinishStartWaiters.filter { thumbnailBatchFinishStartCount >= $0.count }
    thumbnailBatchFinishStartWaiters.removeAll { thumbnailBatchFinishStartCount >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }
}

private actor CatalogLeaseAcquisitionFlag {
  private(set) var value = false

  func markAcquired() {
    value = true
  }
}

@MainActor
private final class CameraCatalogQuerySourceSpy: CameraCatalogQuerySource {
  private let expandedSnapshot: CameraGalleryCatalogSnapshot
  private let exactSnapshots: [CameraMediaFormat: CameraGalleryCatalogSnapshot]
  private let subtractBaselineSnapshots: [CameraMediaFormat: CameraGalleryCatalogSnapshot]
  private let subtractBaselineErrors: [CameraMediaFormat: Error]
  private(set) var expandedRequestCount = 0
  private(set) var exactRequests: [CameraMediaFormat] = []
  private(set) var subtractBaselineRequests: [CameraMediaFormat] = []
  var suspendsSubtractBaselineRequests = false
  private var subtractBaselineRequestContinuations: [CheckedContinuation<Void, Never>] = []
  private var subtractBaselineCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(
    expandedSnapshot: CameraGalleryCatalogSnapshot? = nil,
    exactSnapshots: [CameraMediaFormat: CameraGalleryCatalogSnapshot] = [:],
    subtractBaselineSnapshots: [CameraMediaFormat: CameraGalleryCatalogSnapshot] = [:],
    subtractBaselineErrors: [CameraMediaFormat: Error] = [:]
  ) {
    self.expandedSnapshot = expandedSnapshot ?? .fixture(handles: [])
    self.exactSnapshots = exactSnapshots
    self.subtractBaselineSnapshots = subtractBaselineSnapshots
    self.subtractBaselineErrors = subtractBaselineErrors
  }

  func loadExpandedCatalog() async throws -> CameraGalleryCatalogSnapshot {
    expandedRequestCount += 1
    return expandedSnapshot
  }

  func loadExactCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot {
    exactRequests.append(format)
    guard let snapshot = exactSnapshots[format] else {
      throw NSError(domain: "CameraCatalogQuerySourceSpy", code: 1)
    }
    return snapshot
  }

  func loadSubtractBaselineCatalog(for format: CameraMediaFormat) async throws -> CameraGalleryCatalogSnapshot {
    subtractBaselineRequests.append(format)
    resumeSubtractBaselineCountWaitersIfNeeded()
    if suspendsSubtractBaselineRequests {
      await withCheckedContinuation { continuation in
        subtractBaselineRequestContinuations.append(continuation)
      }
    }
    try Task.checkCancellation()
    if let error = subtractBaselineErrors[format] {
      throw error
    }
    guard let snapshot = subtractBaselineSnapshots[format] else {
      throw NSError(domain: "CameraCatalogQuerySourceSpy", code: 2)
    }
    return snapshot
  }

  func waitForSubtractBaselineRequestCount(_ count: Int) async {
    if subtractBaselineRequests.count >= count { return }
    await withCheckedContinuation { continuation in
      subtractBaselineCountWaiters.append((count: count, continuation: continuation))
    }
  }

  func releaseSubtractBaselineRequests() {
    suspendsSubtractBaselineRequests = false
    let continuations = subtractBaselineRequestContinuations
    subtractBaselineRequestContinuations = []
    continuations.forEach { $0.resume() }
  }

  private func resumeSubtractBaselineCountWaitersIfNeeded() {
    let ready = subtractBaselineCountWaiters.filter { subtractBaselineRequests.count >= $0.count }
    subtractBaselineCountWaiters.removeAll { subtractBaselineRequests.count >= $0.count }
    ready.forEach { $0.continuation.resume() }
  }
}

@MainActor
private extension CameraGalleryCatalogSnapshot {
  static func fixture(handles: [Int]) -> CameraGalleryCatalogSnapshot {
    CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: handles)
  }
}

private extension CameraVendorCameraObjectInfo {
  static func fixture(handle: Int, formatCode: UInt16) -> CameraVendorCameraObjectInfo {
    CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: 1,
      formatCode: formatCode,
      compressedSize: 1,
      thumbCompressedSize: 1,
      filename: "ignored.bin",
      captureDate: "20260727T120000"
    )
  }

  static func previewFixture(
    handle: Int,
    formatCode: UInt16,
    compressedSize: UInt32,
    filename: String,
    captureDate: String = "20260802T120000"
  ) -> CameraVendorCameraObjectInfo {
    CameraVendorCameraObjectInfo(
      handle: handle,
      storageID: 1,
      formatCode: formatCode,
      compressedSize: compressedSize,
      thumbCompressedSize: 16_384,
      filename: filename,
      captureDate: captureDate
    )
  }
}

private extension CameraGalleryCatalogIdentity {
  static func fixture(
    cameraID: String = "camera-a",
    sessionEpoch: UUID = UUID(),
    generation: UInt64
  ) -> CameraGalleryCatalogIdentity {
    CameraGalleryCatalogIdentity(
      cameraID: cameraID,
      sessionEpoch: sessionEpoch,
      generation: CameraGalleryGenerationID(rawValue: generation),
      snapshotID: CameraGallerySnapshotID()
    )
  }
}

private extension NativeGalleryHDPreviewSnapshot {
  static func fixture(
    sectionHandles: [[Int]],
    sessionDate: Date = Date(timeIntervalSince1970: 1_721_779_200)
  ) -> NativeGalleryHDPreviewSnapshot {
    NativeGalleryHDPreviewSnapshot(
      sections: sectionHandles.enumerated().map { sectionIndex, handles in
        NativeGalleryHDPreviewSection(
          day: Calendar.current.date(
            byAdding: .day,
            value: -sectionIndex,
            to: sessionDate
          ),
          title: "section-\(sectionIndex)",
          orderedRepresentedHandles: handles,
          items: handles.map { handle in
            NativeGalleryHDPreviewItem(
              displayItem: CameraVendorGalleryItem(
                handle: handle,
                filename: "DSCF\(handle).JPG",
                formatLabel: "JPG",
                captureDate: "20260724T120000",
                byteSizeText: ""
              ),
              rawSidecar: nil
            )
          }
        )
      }
    )
  }

  static func fixture(handles: [Int]) -> NativeGalleryHDPreviewSnapshot {
    fixture(sectionHandles: [handles])
  }
}

// MARK: - CameraTransportFailureDisposition Tests

extension RunnerTests {

  // MARK: HD Preview Pipeline Transport Loss

  @MainActor
  func testHDPreviewTransportLossStopsBeforeRequestingTheNextHandle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-transport-loss-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    var transportFailureReported = false

    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        // Simulate PTP socket EOF on handle 7
        throw NSError(
          domain: "CameraVendorPtpSocket",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 0/4 字节)"]
        )
      },
      publish: { _ in },
      reportTransportFailure: { _ in
        transportFailureReported = true
      }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [7, 8, 9]),
      visibleHandles: [7, 8, 9]
    )
    await pipeline.waitUntilIdle()

    // Only handle 7 was attempted; the pump stopped after transport loss.
    XCTAssertEqual(fetchedHandles, [7])
    // Transport failure was reported to the session owner.
    XCTAssertTrue(transportFailureReported)
  }

  @MainActor
  func testHDPreviewContentFailureContinuesToNextHandle() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-content-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var fetchedHandles: [Int] = []
    var transportFailureReported = false

    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        if identity.handle == 7 {
          // Content/decode failure — should NOT stop the pump
          throw NSError(
            domain: "ImageDecoder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported HEIF variant"]
          )
        }
        return CameraGalleryPreviewResult(data: Data([UInt8(identity.handle)]), objectOrientation: nil)
      },
      publish: { _ in },
      reportTransportFailure: { _ in
        transportFailureReported = true
      }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: .fixture(handles: [7, 8, 9]),
      visibleHandles: [7, 8, 9]
    )
    await pipeline.waitUntilIdle()

    // Handle 7 failed with content error, but pump continued to 8 and 9.
    XCTAssertEqual(fetchedHandles, [7, 8, 9])
    // No transport failure reported.
    XCTAssertFalse(transportFailureReported)
  }

  @MainActor
  func testHDPreviewTransportLossLatchBlocksSubsequentTriggers() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hd-preview-transport-latch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
    let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let snapshot = NativeGalleryHDPreviewSnapshot.fixture(handles: [7, 8])
    var fetchedHandles: [Int] = []
    var transportFailureCount = 0
    let pipeline = CameraGalleryHDPreviewPipeline(
      cache: cache,
      suspendThumbnailPipeline: {},
      resumeThumbnailPipeline: {},
      fetchPreview: { identity in
        fetchedHandles.append(identity.handle)
        throw NSError(
          domain: "CameraVendorPtpSocket",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
        )
      },
      publish: { _ in },
      reportTransportFailure: { _ in
        transportFailureCount += 1
      }
    )

    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: snapshot,
      visibleHandles: [7, 8]
    )
    await pipeline.waitUntilIdle()

    pipeline.updateVisibleHandles([8])
    pipeline.retry(handle: 7)
    await pipeline.suspend()
    await pipeline.resume()
    await pipeline.activate(
      catalogIdentity: catalog,
      snapshot: snapshot,
      visibleHandles: [8]
    )
    await pipeline.waitUntilIdle()

    XCTAssertEqual(fetchedHandles, [7])
    XCTAssertEqual(transportFailureCount, 1)
  }

  @MainActor
  func testThumbnailTransportLossDoesNotConsumeRetryBudget() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 0/4 字节)"]
    )
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var failedStates: [CameraGalleryMediaIdentity] = []
    var transportFailures: [NSError] = []
    let pipeline = CameraGalleryThumbnailPipeline(
      source: source,
      retryDelaysNanoseconds: [10_000_000_000, 10_000_000_000],
      publish: { publication in
        if case .thumbnailState(let identity, .failed) = publication {
          failedStates.append(identity)
        }
      },
      reportTransportFailure: { error in
        transportFailures.append(error as NSError)
      }
    )

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7, 8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7, 8])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7])
    XCTAssertEqual(failedStates.map(\.handle), [7])
    XCTAssertEqual(transportFailures.count, 1)
    XCTAssertEqual(transportFailures.first?.domain, "CameraVendorPtpSocket")
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailCancellationDoesNotPublishFailureUIOrReportTransportLoss() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "cancelled by generation fence"]
    )
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    var failedPublicationCount = 0
    var transportFailureCount = 0
    let pipeline = CameraGalleryThumbnailPipeline(
      source: source,
      retryDelaysNanoseconds: [0, 0],
      publish: { publication in
        if case .thumbnailState(_, .failed) = publication {
          failedPublicationCount += 1
        }
      },
      reportTransportFailure: { _ in
        transportFailureCount += 1
      }
    )

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7])
    XCTAssertEqual(failedPublicationCount, 0)
    XCTAssertEqual(transportFailureCount, 0)
    await pipeline.cancelAndJoin()
  }

  @MainActor
  func testThumbnailTransportLossDoesNotStartDetailsWorker() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.thumbnailError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
    )
    let identity = CameraGalleryCatalogIdentity.fixture(generation: 1)
    let pipeline = CameraGalleryThumbnailPipeline(
      source: source,
      retryDelaysNanoseconds: [0, 0],
      publish: { _ in },
      reportTransportFailure: { _ in }
    )

    await pipeline.install(
      catalogIdentity: identity,
      membership: [7, 8],
      reusableObjectInfos: [:]
    )
    await pipeline.requestVisible(handles: [7, 8])
    await pipeline.waitUntilIdle()

    XCTAssertEqual(source.requestedThumbnailHandles, [7])
    XCTAssertEqual(source.requestedDetailsHandles, [])
    await pipeline.cancelAndJoin()
  }

  // MARK: Task 1: Disposition classification

  func testCameraTransportFailureDispositionClassifiesPtpEarlyEOFAsSessionTerminal() {
    // CameraVendorPtpSocket code 8 = EOF ("相机提前断开连接 (已读 0/4 字节)")
    let eofError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接 (已读 0/4 字节)"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: eofError),
      .sessionTerminal
    )
  }

  func testCameraTransportFailureDispositionClassifiesPtpTimeoutAsSessionTerminal() {
    // CameraVendorPtpSocket code 9 = timeout
    let timeoutError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 9,
      userInfo: [NSLocalizedDescriptionKey: "等待相机返回数据超时"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: timeoutError),
      .sessionTerminal
    )
  }

  func testCameraTransportFailureDispositionClassifiesPOSIXAsSessionTerminal() {
    // POSIX errors: broken pipe, connection reset
    let brokenPipe = NSError(domain: NSPOSIXErrorDomain, code: 32, userInfo: nil) // EPIPE
    let connReset = NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: nil) // ECONNRESET
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: brokenPipe),
      .sessionTerminal
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: connReset),
      .sessionTerminal
    )
  }

  func testCameraTransportFailureDispositionDoesNotPromoteCancellationOrDecodeFailure() {
    // CancellationError → .cancelled
    let cancellation = CancellationError()
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: cancellation),
      .cancelled
    )

    // Decode/content error → .contentFailure
    let decodeError = NSError(
      domain: "ImageDecoder",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Unsupported HEIF variant"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: decodeError),
      .contentFailure
    )

    let urlCancellation = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "generation changed"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: urlCancellation),
      .cancelled
    )
  }

  func testCameraTransportFailureDispositionPrefersUnderlyingStructuredTransportError() {
    let eofError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
    )
    let wrapper = NSError(
      domain: "ImageDecoder",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "preview unavailable",
        NSUnderlyingErrorKey: eofError,
      ]
    )

    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: wrapper),
      .sessionTerminal
    )
  }

  func testCameraTransportFailureDispositionKeepsUnknownOperationFailureRetryable() {
    let transientError = NSError(
      domain: "CameraGalleryCatalogRuntimeSourceSpy.thumbnail",
      code: 7,
      userInfo: [NSLocalizedDescriptionKey: "temporary request failure"]
    )

    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: transientError),
      .retryableOperation
    )
  }

  func testCameraTransportFailureDispositionDefaultChildContextKeepsNonTerminalCodesRetryable() {
    let socketCreationFailure = NSError(
      domain: "CameraVendorPtpSocket",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "无法创建本地 socket"]
    )
    let invalidArgument = NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(EINVAL),
      userInfo: [NSLocalizedDescriptionKey: "Invalid argument"]
    )

    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: socketCreationFailure),
      .retryableOperation
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: invalidArgument),
      .retryableOperation
    )
  }

  func testLegacyTransportAdaptersPreserveDomainCompatibility() {
    let socketCreationFailure = NSError(
      domain: "CameraVendorPtpSocket",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "无法创建本地 socket"]
    )
    let unknownSocketFailure = NSError(
      domain: "CameraVendorPtpSocket",
      code: 10,
      userInfo: [NSLocalizedDescriptionKey: "vendor socket error"]
    )
    let invalidArgument = NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(EINVAL),
      userInfo: [NSLocalizedDescriptionKey: "Invalid argument"]
    )

    XCTAssertTrue(CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(socketCreationFailure))
    XCTAssertTrue(CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(unknownSocketFailure))
    XCTAssertFalse(CameraVendorCatalogTransportEvidencePolicy.provesTransportLost(invalidArgument))

    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(socketCreationFailure)
    )
    XCTAssertTrue(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(unknownSocketFailure)
    )
    XCTAssertFalse(
      CameraVendorBackgroundMetadataRefreshPolicy.shouldDisconnectSessionAfterFailure(invalidArgument)
    )

    XCTAssertFalse(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(socketCreationFailure))
    XCTAssertFalse(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(unknownSocketFailure))
    XCTAssertTrue(NativeGalleryDownloadFailurePolicy.shouldStopQueueAfterFailure(invalidArgument))
  }

  func testExistingTransportPoliciesDelegateToUnifiedDispositionPolicy() throws {
    let catalogSource = try runnerSource("CameraVendorCatalogPolicy.swift")
    let downloadSource = try runnerSource("NativeGalleryPolicies.swift")
    let metadataSource = try runnerSource("CameraVendorBluetoothService.swift")

    XCTAssertTrue(catalogSource.contains("context: .catalog"))
    XCTAssertTrue(downloadSource.contains("context: .download"))
    XCTAssertTrue(metadataSource.contains("context: .backgroundMetadata"))
  }

  func testCameraTransportFailureDispositionClassifiesPtpSessionAsRetryable() {
    // CameraVendorPtpSession domain = command-level, PTP lane may survive
    let busyError = NSError(
      domain: "CameraVendorPtpSession",
      code: 0x2019,
      userInfo: [NSLocalizedDescriptionKey: "Device busy"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: busyError),
      .retryableOperation
    )

    let storeNotAvailable = NSError(
      domain: "CameraVendorPtpSession",
      code: 0x2013,
      userInfo: [NSLocalizedDescriptionKey: "Store not available"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: storeNotAvailable),
      .retryableOperation
    )
  }

  func testCameraTransportFailureDispositionMessageFallback() {
    // Errors with transport-loss messages but non-standard domain
    let wrappedSocketClosed = NSError(
      domain: "CameraVendorTransport",
      code: 0,
      userInfo: [NSLocalizedDescriptionKey: "Socket is closed"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: wrappedSocketClosed),
      .sessionTerminal
    )

    let wrappedBrokenPipe = NSError(
      domain: "CustomDomain",
      code: 0,
      userInfo: [NSLocalizedDescriptionKey: "I/O error: Broken pipe during read"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: wrappedBrokenPipe),
      .sessionTerminal
    )

    let localizedPtpTimeout = NSError(
      domain: "CameraVendorPtpSession",
      code: 5,
      userInfo: [NSLocalizedDescriptionKey: "读取数据失败: 等待相机返回数据超时"]
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: localizedPtpTimeout),
      .sessionTerminal
    )
  }

  func testCameraTransportFailureDispositionURLErrorSessionTerminal() {
    let connLost = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNetworkConnectionLost,
      userInfo: nil
    )
    let timedOut = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: nil
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: connLost),
      .sessionTerminal
    )
    XCTAssertEqual(
      CameraTransportFailureDispositionPolicy.disposition(for: timedOut),
      .sessionTerminal
    )
  }

  @MainActor
  func testCatalogRuntimeCatchAllClassifiesSocketEOFAsTransportLoss() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.catalogError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
    )
    var reportedFailures: [CameraGalleryCatalogFailure] = []
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { _ in },
      reportTransportEvidence: { failure in
        reportedFailures.append(failure)
      }
    )

    await runtime.start(initial: .all)
    await runtime.waitUntilIdle()

    XCTAssertEqual(reportedFailures.count, 1)
    XCTAssertTrue(reportedFailures[0].provesTransportLost)
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testCatalogRuntimeCatchAllTreatsURLCancellationAsSilent() async {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    source.catalogError = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorCancelled,
      userInfo: [NSLocalizedDescriptionKey: "catalog generation changed"]
    )
    var failedPresentationCount = 0
    var reportedFailureCount = 0
    let runtime = CameraGalleryCatalogRuntime(
      source: source,
      publishPresentation: { presentation in
        if case .failed = presentation.state {
          failedPresentationCount += 1
        }
      },
      reportTransportEvidence: { _ in
        reportedFailureCount += 1
      }
    )

    await runtime.start(initial: .all)
    await runtime.waitUntilIdle()

    XCTAssertEqual(failedPresentationCount, 0)
    XCTAssertEqual(reportedFailureCount, 0)
    await runtime.cancelAllChildren()
  }

  @MainActor
  func testGallerySessionRoutesThumbnailTransportLossWithTerminalEvidence() async throws {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let session = CameraGallerySession(
      identity: CameraSessionIdentity(cameraName: "X-T5", historyKey: "thumbnail-loss"),
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch),
      downloadedHandles: { [] },
      fetchPreview: { _ in throw CancellationError() }
    )
    let failureReported = expectation(description: "thumbnail transport failure reported")
    var reportedFailures: [CameraGalleryCatalogFailure] = []
    session.onTransportFailure = { failure in
      reportedFailures.append(failure)
      failureReported.fulfill()
    }

    await session.enter()
    for _ in 0..<1_000 where session.catalogIdentity == nil {
      await Task.yield()
    }
    let catalogIdentity = try XCTUnwrap(session.catalogIdentity)
    source.thumbnailError = NSError(
      domain: "CameraVendorPtpSocket",
      code: 8,
      userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
    )

    await session.requestVisibleThumbnails(
      handles: [3, 2],
      submissionID: 1,
      expectedCatalogIdentity: catalogIdentity
    )
    await fulfillment(of: [failureReported], timeout: 2)

    XCTAssertEqual(source.requestedThumbnailHandles, [3])
    XCTAssertEqual(reportedFailures.count, 1)
    XCTAssertTrue(reportedFailures[0].provesTransportLost)
    await session.invalidate()
  }

  @MainActor
  func testGallerySessionRoutesHDPreviewTransportLossWithTerminalEvidence() async throws {
    let source = CameraGalleryCatalogRuntimeSourceSpy()
    let sessionEpoch = UUID()
    let session = CameraGallerySession(
      identity: CameraSessionIdentity(cameraName: "X-T5", historyKey: "preview-loss"),
      source: source,
      sessionEpoch: sessionEpoch,
      queryEngine: CameraCatalogQueryEngine(source: source, sessionEpoch: sessionEpoch),
      downloadedHandles: { [] },
      fetchPreview: { _ in
        throw NSError(
          domain: "CameraVendorPtpSocket",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "相机提前断开连接"]
        )
      }
    )
    let failureReported = expectation(description: "HD preview transport failure reported")
    var reportedFailures: [CameraGalleryCatalogFailure] = []
    session.onTransportFailure = { failure in
      reportedFailures.append(failure)
      failureReported.fulfill()
    }

    await session.enter()
    for _ in 0..<1_000 where session.catalogIdentity == nil {
      await Task.yield()
    }
    _ = try XCTUnwrap(session.catalogIdentity)
    await session.switchPreviewMode(
      .highDefinition,
      snapshot: .fixture(handles: [3, 2]),
      visibleHandles: [3, 2]
    )
    await fulfillment(of: [failureReported], timeout: 2)

    XCTAssertEqual(reportedFailures.count, 1)
    XCTAssertTrue(reportedFailures[0].provesTransportLost)
    await session.invalidate()
  }
}

// MARK: - Collection View Snapshot Consistency Tests

extension RunnerTests {

  func testNativeGalleryHeaderNeverReturnsBareSuppView() throws {
    // Verify the production code no longer contains `return UICollectionReusableView()`
    // in the supplementary view callback.
    let source = try runnerSource("NativeGalleryViewController.swift")

    // Find the viewForSupplementaryElementOfKind method
    guard let methodStart = source.range(
      of: "viewForSupplementaryElementOfKind kind: String"
    )?.lowerBound else {
      XCTFail("Cannot find viewForSupplementaryElementOfKind method")
      return
    }
    // Find the end of the method (next extension or func boundary)
    let searchRange = methodStart..<source.endIndex
    let methodBody: String
    if let nextFunc = source.range(of: "\n  func collectionView", range: searchRange)?.lowerBound {
      methodBody = String(source[methodStart..<nextFunc])
    } else {
      methodBody = String(source[searchRange])
    }

    // Must not contain bare UICollectionReusableView() return
    XCTAssertFalse(
      methodBody.contains("return UICollectionReusableView()"),
      "viewForSupplementaryElementOfKind must not return bare UICollectionReusableView() — " +
      "it triggers UIKit assertion when the view wasn't dequeued for the requesting collection view"
    )
  }

  func testNativeGalleryHeaderSizeRespectsHDCollectionSnapshot() throws {
    // Verify referenceSizeForHeaderInSection distinguishes HD vs normal collection
    let source = try runnerSource("NativeGalleryViewController.swift")

    guard let methodStart = source.range(
      of: "referenceSizeForHeaderInSection section: Int"
    )?.lowerBound else {
      XCTFail("Cannot find referenceSizeForHeaderInSection method")
      return
    }
    let searchRange = methodStart..<source.endIndex
    let methodBody: String
    if let nextFunc = source.range(of: "\n  func collectionView", range: searchRange)?.lowerBound {
      methodBody = String(source[methodStart..<nextFunc])
    } else {
      methodBody = String(source[searchRange])
    }

    // Must check HD collection view separately
    XCTAssertTrue(
      methodBody.contains("hdCollectionView") || methodBody.contains("hdPresentationState"),
      "referenceSizeForHeaderInSection must validate against the HD snapshot " +
      "when the requesting collection is hdCollectionView"
    )
  }

  func testNativeGalleryCatalogReplacementDoesNotLayoutHiddenHDCollectionView() throws {
    // Verify that applyCatalogPresentation only layouts hdCollectionView in HD mode
    let source = try runnerSource("NativeGalleryViewController.swift")

    guard let methodStart = source.range(
      of: "private func applyCatalogPresentation"
    )?.lowerBound else {
      XCTFail("Cannot find applyCatalogPresentation method")
      return
    }
    // Find the layoutIfNeeded block for hdCollectionView
    let searchRange = methodStart..<source.endIndex
    guard let layoutBlock = source.range(
      of: "hdCollectionView.layoutIfNeeded()",
      range: searchRange
    )?.lowerBound else {
      // If hdCollectionView.layoutIfNeeded() doesn't exist at all, that's fine
      return
    }
    // The layoutIfNeeded must be guarded by browseMode check
    let contextStart = source.index(layoutBlock, offsetBy: -200, limitedBy: methodStart) ?? methodStart
    let context = String(source[contextStart..<layoutBlock])
    XCTAssertTrue(
      context.contains("browseMode == .highDefinition"),
      "hdCollectionView.layoutIfNeeded() must only run when browseMode == .highDefinition"
    )
  }

  func testNativeDownloadListCellUsesOneBoundsCheckedItemsSnapshot() throws {
    // Verify cellForItemAt captures items once and bounds-checks before indexing
    let source = try runnerSource("NativeGalleryViewController.swift")

    guard let extensionStart = source.range(
      of: "extension NativeDownloadListViewController: UICollectionViewDataSource"
    )?.lowerBound else {
      XCTFail("Cannot find NativeDownloadListViewController data source extension")
      return
    }
    guard let cellMethod = source.range(
      of: "cellForItemAt indexPath: IndexPath",
      range: extensionStart..<source.endIndex
    )?.lowerBound else {
      XCTFail("Cannot find cellForItemAt in download list")
      return
    }
    let methodEnd = source.range(
      of: "\n  func collectionView",
      range: cellMethod..<source.endIndex
    )?.lowerBound ?? source.endIndex
    let methodBody = String(source[cellMethod..<methodEnd])

    // Must capture items with bounds check
    XCTAssertTrue(
      methodBody.contains("items.indices.contains(indexPath.item)"),
      "Download list cellForItemAt must bounds-check before indexing into items"
    )
    // Must not directly index itemsProvider()[indexPath.item] without guard
    XCTAssertFalse(
      methodBody.contains("itemsProvider()[indexPath.item]"),
      "Download list cellForItemAt must capture items to a local before indexing"
    )
  }
}
