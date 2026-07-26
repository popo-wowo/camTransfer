# iOS Gallery Terminal Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor CamTransfer iOS gallery, quick download, preview, and download orchestration into one camera session owner, one catalog owner, independent thumbnail/HD pipelines, and one physical PTP command lane.

**Architecture:** `CameraSessionRuntime` remains the app-level façade and lifecycle owner, but delegates catalog membership, thumbnail enrichment, HD preview, download batches, and PTP admission to focused components. Catalog results are immutable identity-bound snapshots; every camera command uses one command lane; all stale asynchronous results are rejected before cache or UI publication.

**Tech Stack:** Swift 5, UIKit, Swift Concurrency actors/tasks, XCTest, Xcode, Fujifilm PTP adapter.

---

## Baseline contract

The untouched `main` baseline at `622c1b76` executes 856 tests with 123 assertion failures across 76 test methods. The failed test names are captured at `/tmp/codex-ios-gallery-terminal-baseline-failures.txt`; many are stale source-inspection tests looking in files from which the implementation has already moved.

Completion requires:

1. Every new behavior follows RED → GREEN.
2. All command-lane, CatalogRuntime, thumbnail, HD preview, quick-download, and download-admission targeted tests pass.
3. The full suite adds no failed test name outside the captured baseline.
4. `git diff --check` passes.
5. A generic iPhoneOS Debug build succeeds.
6. Real-camera acceptance remains a separate proof layer.

## File map

Create:

- `ios/Runner/CameraCommandLane.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryMediaIdentity.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- `ios/Runner/CameraCore/Gallery/CameraCatalogAccessLease.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryFilterPolicies.swift`
- `ios/Runner/CameraDownloadManager.swift`

Modify:

- `ios/Runner/CameraVendorRealtimeGalleryService.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogModels.swift`
- `ios/Runner/CameraCore/Gallery/CameraGallerySources.swift`
- `ios/Runner/NativeGalleryHDPreviewSession.swift`
- `ios/Runner/NativePhotoPreviewViewController.swift`
- `ios/Runner/CameraSessionRuntime.swift`
- `ios/Runner/QuickDownloadCoordinator.swift`
- `ios/Runner/CameraAutoDownloadRule.swift`
- `ios/Runner/NativeGalleryViewController.swift`
- `ios/Runner/NativeConnectViewController.swift`
- `ios/Runner/CameraSessionTransferExecutor.swift`
- `ios/Runner/NativeDownloadListViewController.swift`
- `ios/Runner.xcodeproj/project.pbxproj`
- `ios/RunnerTests/RunnerTests.swift`

Remove:

- `ios/Runner/CameraVendorGalleryRequestScheduler.swift`

### Task 1: Establish one physical command lane

**Files:** Create `ios/Runner/CameraCommandLane.swift`; modify `CameraVendorRealtimeGalleryService.swift`, the Xcode project, and tests; remove the old scheduler file.

- [ ] Write failing tests for the required priority order and download barrier:

```swift
func testCameraCommandLaneUsesOnePriorityOrderForAllPtpConsumers() {
  XCTAssertEqual(CameraCommandPriority.sessionMutation.rawValue, -1)
  XCTAssertEqual(CameraCommandPriority.download.rawValue, 0)
  XCTAssertEqual(CameraCommandPriority.hdPreview.rawValue, 1)
  XCTAssertEqual(CameraCommandPriority.visibleThumbnail.rawValue, 2)
  XCTAssertEqual(CameraCommandPriority.details.rawValue, 3)
  XCTAssertEqual(CameraCommandPriority.keepAlive.rawValue, 4)
}
```

- [ ] Run the test and confirm compilation fails because `CameraCommandLane` does not exist.
- [ ] Move the existing waiter, cancellation, priority, mutation-barrier, idle-wait, and download-barrier behavior behind this API:

```swift
enum CameraCommandPriority: Int, Sendable {
  case sessionMutation = -1
  case download = 0
  case hdPreview = 1
  case visibleThumbnail = 2
  case details = 3
  case keepAlive = 4
}

final class CameraCommandLane {
  func run<T>(priority: CameraCommandPriority, _ operation: () throws -> T) async throws -> T
  func runExclusiveSessionMutation<T>(_ operation: () throws -> T) async throws -> T
  func acquireExclusiveDownloadLease() async -> CameraCommandLease
  func waitUntilIdle() async
}

final class CameraCommandLease: @unchecked Sendable {
  func release()
}
```

`CameraCommandLease.release()` is idempotent and `deinit` releases once, so cancellation and page teardown cannot leave a barrier active.

- [ ] Update all catalog, thumbnail, preview, metadata, keep-alive, mutation, and download requests to use this single instance.
- [ ] Run the new tests and the existing scheduler tests at lines 9399–9665; expect zero failures.
- [ ] Commit with `refactor(ios): establish single camera command lane`.

### Task 2: Add complete media identities

**Files:** Create `CameraGalleryMediaIdentity.swift`; modify Catalog models, Xcode project, and tests.

- [ ] Write a failing test showing that the same handle from another session epoch is stale.
- [ ] Run it and confirm the identity types are missing.
- [ ] Add these immutable domain types:

```swift
struct CameraGalleryCatalogIdentity: Hashable, Sendable {
  let cameraID: String
  let sessionEpoch: UUID
  let generation: CameraGalleryGenerationID
  let snapshotID: CameraGallerySnapshotID
}

enum CameraGalleryMediaVariant: Hashable, Sendable {
  case thumbnail
  case hdPreview
}

struct CameraGalleryMediaIdentity: Hashable, Sendable {
  let catalog: CameraGalleryCatalogIdentity
  let previewSessionID: UUID?
  let handle: Int
  let variant: CameraGalleryMediaVariant
}
```

- [ ] Add equality-based freshness checks and tests for camera ID, session epoch, generation, snapshot, preview session, handle, and variant.
- [ ] Run the identity tests; expect zero failures.
- [ ] Commit with `refactor(ios): add gallery media identity chain`.

### Task 3: Extract thumbnail/details work from CatalogRuntime

**Files:** Create `CameraGalleryThumbnailPipeline.swift`; modify CatalogRuntime, sources, Xcode project, and tests.

- [ ] Write a failing stale-result behavior test and a source ownership test:

```swift
func testCatalogRuntimeDelegatesThumbnailAndDetailsTasksToPipeline() throws {
  let source = try String(contentsOf: runnerSource("CameraCore/Gallery/CameraGalleryCatalogRuntime.swift"))
  XCTAssertFalse(source.contains("private var thumbnailTask"))
  XCTAssertFalse(source.contains("private var detailsTask"))
  XCTAssertTrue(source.contains("CameraGalleryThumbnailPipeline"))
}
```

- [ ] Run the tests and confirm CatalogRuntime still owns both tasks.
- [ ] Create the focused actor:

```swift
actor CameraGalleryThumbnailPipeline {
  func install(identity: CameraGalleryCatalogIdentity, handles: [Int]) async
  func requestVisible(handles: [Int]) async
  func suspend() async
  func resume(identity: CameraGalleryCatalogIdentity, handles: [Int]) async
  func cancelAndJoin() async
  func waitUntilIdle() async
}
```

- [ ] Move thumbnail/details tasks, active request state, enrichment cache, burst fairness, retry state, and child cancellation into the actor.
- [ ] Keep CatalogRuntime as the sole membership/repository owner; it applies pipeline publications only when generation, snapshot, and handle still match.
- [ ] Run the existing visible-window, burst fairness, HD suspension/resume, transaction-join, and repository-monotonicity tests; expect zero targeted failures.
- [ ] Commit with `refactor(ios): extract gallery thumbnail pipeline`.

### Task 4: Make HD preview an identity-bound leased session

**Files:** Modify HD session, Gallery VC, Runtime, preview cache, and tests.

- [ ] Write failing tests that require `NativeGalleryHDPreviewSnapshot` to contain `sessionID` and `catalogIdentity`, and require repeated stop/deinit paths to release admission exactly once.
- [ ] Run the tests and confirm the fields and lease do not exist.
- [ ] Change the snapshot contract to:

```swift
struct NativeGalleryHDPreviewSnapshot: Equatable {
  let sessionID: UUID
  let catalogIdentity: CameraGalleryCatalogIdentity
  let activeDate: Date
  let items: [NativeGalleryHDPreviewItem]
}
```

- [ ] Add Runtime admission:

```swift
func acquireHDPreviewSession(
  for identity: CameraGalleryCatalogIdentity
) async throws -> CameraCommandLease
```

- [ ] Admission rejects loading/stale Catalog state, suspends and joins thumbnail/details, waits for the command lane, then returns an idempotent lease.
- [ ] Catalog generation change, download admission, page exit, and transport loss cancel/join HD before releasing the lease.
- [ ] Replace handle-only HD cache access with `CameraGalleryMediaIdentity`; retain bounded memory/disk behavior.
- [ ] Run HD policy, cache identity, rapid switch, suspension, and resume tests; expect zero failures.
- [ ] Commit with `refactor(ios): bind HD preview to catalog lease`.

### Task 5: Add exclusive Catalog lease and exact async resolve

**Files:** Create `CameraCatalogAccessLease.swift`; modify CatalogRuntime, Runtime, Xcode project, and tests.

- [ ] Write a failing test proving a gallery owner blocks a quick-download owner until release.
- [ ] Run it and confirm the gate types are missing.
- [ ] Add:

```swift
enum CameraCatalogOwner: Hashable, Sendable {
  case gallery(UUID)
  case quickDownload(UUID)
}

actor CameraCatalogAccessGate {
  func tryAcquire(owner: CameraCatalogOwner) -> CameraCatalogAccessLease?
}
```

- [ ] Add the exact generation API:

```swift
func resolveCatalog(
  intent: CameraGalleryFilterIntent,
  owner: CameraCatalogOwner
) async throws -> CameraGalleryPresentation
```

- [ ] Ensure resolve returns only the requested owner/generation and never completes from an arbitrary observed `.ready` state.
- [ ] Run owner, rapid-intent, stale-generation, and shutdown tests; expect zero failures.
- [ ] Commit with `refactor(ios): add exclusive catalog resolve lease`.

### Task 6: Unify query planning, projection, and quick download

**Files:** Create `CameraGalleryFilterPolicies.swift`; modify quick download, rules, Home VC, Gallery VC, Xcode project, and tests.

- [ ] Write failing tests proving quick download never treats filename extension or format label as authority and uses its own resolved Catalog generation.
- [ ] Run the tests and confirm the current filter violates the contract.
- [ ] Add pure policies:

```swift
enum CameraCatalogQueryPlanner {
  static func plan(
    intent: CameraGalleryFilterIntent,
    capabilities: CameraCatalogCapabilities
  ) -> Result<CameraCatalogQueryPlan, CameraGalleryUnsupportedReason>
}

struct CameraCatalogCapabilities: Equatable, Sendable {
  let supportedFormats: Set<CameraGalleryFormatIntent>
  let supportsCameraDateFiltering: Bool
}

enum GalleryProjectionPolicy {
  static func project(
    snapshot: CameraGalleryCatalogSnapshot,
    intent: CameraGalleryFilterIntent,
    downloadedHandles: Set<Int>
  ) -> [CameraGalleryEntry]
}
```

- [ ] Replace the observer-based Coordinator with an async `QuickDownloadUseCase` executing `ensureGalleryReady → Catalog lease → exact resolve → projection → DownloadBatch submission`.
- [ ] Delete catalog observer ownership, pending callbacks, filename/extension inference, and direct reads of arbitrary Runtime Catalog presentation.
- [ ] Run quick-download, gallery-filter, and shared-policy tests; expect zero failures.
- [ ] Commit with `refactor(ios): unify gallery and quick download policies`.

### Task 7: Extract the single DownloadManager

**Files:** Create `CameraDownloadManager.swift`; modify Runtime, transfer executor, download list, Xcode project, and tests.

- [ ] Write failing tests proving queued/downloading handles cannot be duplicated, saved handles can be explicitly redownloaded, and disconnect behavior belongs to batch completion policy.
- [ ] Run the tests and confirm the manager types are missing.
- [ ] Add batch contracts:

```swift
enum CameraDownloadCompletionPolicy: Equatable, Sendable {
  case keepSession
  case disconnectAfterTerminal
}

struct CameraDownloadBatch: Equatable, Sendable {
  let id: UUID
  let handles: [UInt32]
  let mode: CameraVendorTransferDownloadMode
  let completionPolicy: CameraDownloadCompletionPolicy
}
```

- [ ] Move queue, current handle, item states, progress, completed/failed counts, recovery snapshot, presentation, and final eligibility enforcement from Runtime into the manager.
- [ ] Acquire the exclusive download barrier before the first transfer; join Catalog/thumbnail/HD work; release only at terminal or recoverable interruption.
- [ ] Run admission, original-download, recovery, background, and completion-policy tests; expect zero targeted failures.
- [ ] Commit with `refactor(ios): extract single download manager`.

### Task 8: Close CameraCore vendor boundaries and slim controllers

**Files:** Modify Gallery sources/runtime, CameraAdapter, Home/Gallery controllers, and tests.

- [ ] Write failing tests asserting no `CameraVendor` reference in `CameraCore/Gallery/CameraGallerySources.swift` or `CameraGalleryCatalogRuntime.swift`.
- [ ] Write failing tests asserting Gallery/Home controllers contain no Catalog lifecycle task, transfer start, Catalog observer, or quick-download filter ownership.
- [ ] Run the tests and confirm the current vendor types and controller ownership remain.
- [ ] Introduce domain-only `CameraGalleryThumbnailResult` and `CameraGalleryDetailsResult`; convert vendor query, thumbnail, ObjectInfo, and preview types inside adapter/transport boundaries.
- [ ] Keep controllers responsible only for UI state, selection gestures, rendering, and navigation; call Runtime use-case methods for ordering.
- [ ] Run boundary and controller tests; expect zero failures.
- [ ] Commit with `refactor(ios): close terminal gallery architecture boundaries`.

### Task 9: Final verification

**Files:** Modify only if verification exposes a refactor-caused defect.

- [ ] Run focused tests containing `CameraCommandLane`, `GalleryRequestScheduler`, `CatalogRuntime`, `Thumbnail`, `HDPreview`, `QuickDownload`, `DownloadManager`, and `CameraCoreGallery`.
- [ ] Run the full suite into `/tmp/codex-ios-gallery-terminal-final.log` and extract unique failed test names.
- [ ] Compare with `comm -13 /tmp/codex-ios-gallery-terminal-baseline-failures.txt /tmp/codex-ios-gallery-terminal-final-failures.txt`; expected output is empty.
- [ ] Run:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/codex-ios-gallery-terminal-device-build
```

- [ ] Confirm `** BUILD SUCCEEDED **`, then run `git diff --check`, `git status --short`, and `git diff --stat main...HEAD`.
- [ ] Report that real-camera thumbnail → HD → thumbnail switching, download admission from both modes, stale-cache rejection, and transport-loss recovery are unverified until a fresh physical session is executed.
