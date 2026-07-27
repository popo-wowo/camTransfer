# iOS Gallery and Quick Download Terminal Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Every production change follows RED -> GREEN -> REFACTOR.

**Goal:** Implement the approved terminal architecture in which Gallery and Quick Download have independent state and results while sharing one catalog query engine, one filter engine, one camera command lane, and one Runtime-owned sequential download queue.

**Architecture:** `CameraSessionRuntime` remains the single camera-session and download owner. `CameraCatalogQueryEngine` serializes complete catalog resolutions, `CameraFilterEngine` owns all shared filter semantics, `CameraGallerySession` owns Gallery-only state and preview pipelines, and `QuickDownloadUseCase` resolves transient handles without reading or mutating Gallery presentation.

**Tech Stack:** Swift 5, UIKit, Swift Concurrency, XCTest, Xcode, Fujifilm PTP adapter.

---

## Scope and baseline

- Work only in `/Users/g01d-01-1224/.config/superpowers/worktrees/camtransfer/codex/ios-gallery-terminal-refactor`.
- Preserve `/Users/g01d-01-1224/Documents/camtransfer` and all unrelated worktrees.
- The comparison baseline is `/tmp/codex-ios-gallery-terminal-baseline-failures.txt` with 76 known failed test names from untouched `main`.
- Every task must run focused tests before commit.
- Final full-suite verification may retain baseline failures but must add no new failed test name.
- Real-camera behavior is a separate final proof layer.

## Target file map

Create:

- `ios/Runner/CameraCore/Gallery/CameraMediaFilterRule.swift`
- `ios/Runner/CameraCore/Gallery/CameraFilterEngine.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryMediaIdentity.swift`
- `ios/Runner/CameraCore/Gallery/CameraCatalogAccessLease.swift`
- `ios/Runner/CameraCore/Gallery/CameraCatalogQueryEngine.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryFilterStateStore.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- `ios/Runner/QuickDownloadUseCase.swift`

Modify:

- `ios/Runner/CameraCommandLane.swift`
- `ios/Runner/CameraVendorRealtimeGalleryService.swift`
- `ios/Runner/CameraVendorPtpSession.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogModels.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift`
- `ios/Runner/CameraCore/Gallery/CameraGalleryRepositoryAdapters.swift`
- `ios/Runner/CameraCore/Gallery/CameraGallerySources.swift`
- `ios/Runner/CameraSessionTransferExecutor.swift`
- `ios/Runner/CameraSessionRuntime.swift`
- `ios/Runner/CameraAutoDownloadRule.swift`
- `ios/Runner/NativeAutoDownloadSettingsViewController.swift`
- `ios/Runner/NativeGalleryPolicies.swift`
- `ios/Runner/NativeGalleryHDPreviewSession.swift`
- `ios/Runner/NativePhotoPreviewViewController.swift`
- `ios/Runner/NativeGalleryViewController.swift`
- `ios/Runner/NativeConnectViewController.swift`
- `ios/Runner.xcodeproj/project.pbxproj`
- `ios/RunnerTests/RunnerTests.swift`

Remove after consumers migrate:

- `ios/Runner/QuickDownloadCoordinator.swift`
- duplicated filter implementation from `CameraAutoDownloadRule.swift`
- duplicated date/status projection from `NativeGalleryPolicies.swift` and `CameraGalleryCatalogRuntime.swift`

Do not create `CameraDownloadManager.swift`.

## Verification command template

Use the booted simulator:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/<testName>
```

### Task 1: Close the single-command-lane ownership gaps

**Files:** Modify `CameraCommandLane.swift`, `CameraVendorRealtimeGalleryService.swift`, `CameraVendorPtpSession.swift`, and tests.

- [ ] Add failing tests:

```swift
func testPtpRuntimeOldOwnerReleaseAfterForceEndDoesNotReleaseReplacementWindow()
func testPtpRuntimeOldWaiterCannotObserveReplacementAcquisitionAsReady()
func testRealtimeGalleryServiceOldOwnerReleaseAfterTerminateDoesNotFinishReplacementBatch()
func testRealtimeGalleryServiceDiagnosticCallbackCanEndWindowWithoutDeadlock()
func testPriorityBatchFinishIsSerializedBeforeNextCommandLaneOperation()
```

- [ ] Run the five selectors and verify RED against the current anonymous end/decrement behavior.
- [ ] Make every exclusive download acquisition carry a unique owner ID. Await and release by owner ID; a stale owner must be a no-op after force-end, terminate, or replacement.
- [ ] Under `exclusiveDownloadWindowLock`, record only generation-scoped state transitions. Execute PTP Runtime calls, session priority-batch begin/finish, and diagnostic callbacks after unlocking.
- [ ] Route wire-level priority-batch finish/reset through `CameraCommandLane` before the next queued command is admitted.
- [ ] Run the five new tests plus all existing `CameraCommandLane` and exclusive-download-window tests; expect zero focused failures.
- [ ] Commit: `fix(ios): bind command lane windows to owner identity`.

### Task 2: Add the shared filter domain and remove preset combinations

**Files:** Create `CameraMediaFilterRule.swift` and `CameraFilterEngine.swift`; modify rules, Gallery policies, settings UI, project file, and tests.

- [ ] Add failing pure-domain tests for:

```swift
func testMediaFormatSelectionMakesAllExclusiveFromSpecificFormats()
func testMediaFormatSelectionAllowsJpgRawAndHeifMultiSelection()
func testGalleryDefaultFilterIsAllFormatsAllDatesAllDownloads()
func testQuickDownloadDefaultFilterIsJpgAllDatesNotDownloaded()
func testFilterPlannerUsesExactQueriesForJpgAndRaw()
func testFilterPlannerUsesFallbackWheneverHeifIsSelected()
func testFilterProjectionAppliesDateAndDownloadScopeOnce()
```

- [ ] Run the selectors and verify compilation RED because the shared types do not exist.
- [ ] Add the approved shared types:

```swift
enum CameraMediaFormat: String, Codable, Hashable, Sendable {
  case jpg, raw, heif
}

enum CameraMediaFormatSelection: Equatable, Codable, Sendable {
  case all
  case selected(Set<CameraMediaFormat>)
}

enum CameraMediaDateSelection: Equatable, Codable, Sendable {
  case all
  case today
  case specificDay(Date)
}

enum CameraMediaDownloadScope: String, Codable, Equatable, Sendable {
  case all
  case notDownloaded
}

struct CameraMediaFilterRule: Equatable, Codable, Sendable {
  let formats: CameraMediaFormatSelection
  let date: CameraMediaDateSelection
  let downloadScope: CameraMediaDownloadScope
}
```

- [ ] Add a pure `CameraFilterEngine` that returns `.allCatalog`, `.exactFormats(Set<CameraMediaFormat>)`, or `.objectInfoFallback(requestedFormats:)`, and projects date/download-scope without filename or `formatLabel` inference.
- [ ] Replace `CameraAutoDownloadFormat` preset combinations with the shared multi-selection model. No migration code: the feature has not shipped.
- [ ] Keep only `all/today/specificDay` date cases. Delete `lastNDays`, `presets`, and `segmentPresets`.
- [ ] Change Quick settings to four format controls: All, JPG, RAW, HEIF. All is exclusive; specific formats can be multi-selected; default is JPG.
- [ ] Change Gallery format state to the same multi-selection model while keeping Gallery sort separate.
- [ ] Remove `CameraAutoDownloadRuleFilter` and duplicated local date/status matching after all tests use `CameraFilterEngine`.
- [ ] Run the new tests plus current Gallery filter and Quick settings tests; expect zero focused failures.
- [ ] Commit: `refactor(ios): unify media filter domain`.

### Task 3: Add immutable identities and a shared catalog query engine

**Files:** Create identity, access lease, and query engine files; modify Catalog models, source adapter, transfer executor, Runtime, project, and tests.

- [ ] Add failing tests:

```swift
func testCatalogIdentityRejectsAnotherCameraSessionEpoch()
func testCatalogAccessGateAllowsOnlyOneLogicalOwnerUntilRelease()
func testCatalogQueryEngineReturnsExactJpgAndRawUnionWithoutMutatingGalleryState()
func testCatalogQueryEngineUsesAllCatalogAndObjectInfoWhenHeifIsSelected()
func testCatalogQueryEngineFailsWholeResolutionWhenFallbackObjectInfoIsIncomplete()
```

- [ ] Run and verify RED because identity/query APIs do not exist.
- [ ] Add identities:

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
  let handle: Int
  let variant: CameraGalleryMediaVariant
}

struct CameraGalleryMediaCacheKey: Hashable, Sendable {
  let sessionEpoch: UUID
  let handle: Int
  let variant: CameraGalleryMediaVariant
}
```

- [ ] Add an idempotent `CameraCatalogAccessLease` and owner types `.gallery(UUID)` / `.quickDownload(UUID)`. One complete resolution owns the gate until its query plan finishes.
- [ ] Add `CameraCatalogQueryEngine.resolve(rule:owner:downloadedHandles:) async throws -> CameraCatalogResolution`.
- [ ] Exact JPG/RAW plans use camera catalog transactions and union/deduplicate ordered handles. HEIF plans load all, apply date first, fetch ObjectInfo only for date candidates, classify using camera-returned format data, then apply download scope.
- [ ] Return immutable resolutions. Do not install them into Gallery state inside the query engine.
- [ ] Treat cancellation as normal obsolescence. Treat incomplete HEIF ObjectInfo classification as a failed resolution, never a partial result.
- [ ] Make `CameraSessionRuntime` own one query engine for the active camera session and invalidate it on disconnect/session replacement.
- [ ] Run the five new tests plus catalog transaction/restore tests; expect zero focused failures.
- [ ] Commit: `refactor(ios): add shared catalog query engine`.

### Task 4: Extract the independent thumbnail/details pipeline

**Files:** Create `CameraGalleryThumbnailPipeline.swift`; modify CatalogRuntime, repository, sources, project, and tests.

- [ ] Add failing tests:

```swift
func testCatalogRuntimeDelegatesThumbnailAndDetailsTasksToPipeline()
func testThumbnailPipelineRejectsPublicationFromAnOldCatalogIdentity()
func testThumbnailPipelinePreservesSameSessionHandleCacheAcrossFilterChange()
func testThumbnailPipelineClearsCacheWhenSessionEpochChanges()
func testThumbnailPipelineSuspendPreservesLoadedAndRetryState()
```

- [ ] Verify RED: `CameraGalleryCatalogRuntime` still owns `thumbnailTask`, `detailsTask`, active request state, and enrichment cache.
- [ ] Add `CameraGalleryThumbnailPipeline` with install, visible request, suspend, resume, cancel/join, wait-idle, and session invalidation APIs.
- [ ] Move thumbnail/details tasks, visible batching, request deduplication, retry/fairness state, and reusable ObjectInfo enrichment out of CatalogRuntime.
- [ ] Keep CatalogRuntime as Gallery membership/presentation owner. It applies publications only when catalog identity and handle remain current.
- [ ] Derive `CameraGalleryMediaCacheKey` from media identity for image bytes; use the full media/Catalog identity as publication authority.
- [ ] Preserve loaded/retry state during temporary download or HD suspension. Clear it only on session invalidation.
- [ ] Run new tests plus visible-window, burst fairness, transaction join, monotonic repository, and selection stability tests.
- [ ] Commit: `refactor(ios): extract gallery thumbnail pipeline`.

### Task 5: Make HD preview a separate identity-bound pipeline

**Files:** Create `CameraGalleryHDPreviewPipeline.swift`; modify HD session, HD cache, Gallery VC, Runtime/Gallery session APIs, project, and tests.

- [ ] Add failing tests:

```swift
func testHDPreviewCacheUsesSessionEpochHandleAndVariantIdentity()
func testThumbnailAndHDPreviewCachesNeverShareEntries()
func testHDPreviewPipelineRejectsAnOldCatalogPublication()
func testHDPreviewPipelineKeepsCacheWhenReturningToThumbnailMode()
func testHDPreviewPipelineClearsCacheAfterCameraDisconnect()
```

- [ ] Verify RED against the current handle-only `NativeGalleryHighDefinitionPreviewCache` and VC-owned coordinator.
- [ ] Move HD loading Task, visible priority window, load/failure state, and admission lifecycle into `CameraGalleryHDPreviewPipeline`.
- [ ] Keep the existing HD policy calculations where they are pure, but remove camera work ownership from `NativeGalleryViewController`.
- [ ] Key HD cache by session epoch + handle + `.hdPreview`; never consult thumbnail cache as HD authority.
- [ ] Switching thumbnail <-> HD stops the outgoing pipeline's camera work but preserves both caches. Session invalidation clears both.
- [ ] Run new tests plus current HD priority-window, pause/resume, retry, cache, and download-request tests.
- [ ] Commit: `refactor(ios): isolate gallery hd preview pipeline`.

### Task 6: Add the Gallery-only session and per-camera filter store

**Files:** Create `CameraGallerySession.swift` and `CameraGalleryFilterStateStore.swift`; modify Runtime, Gallery VC, CatalogRuntime wiring, project, and tests.

- [ ] Add failing tests:

```swift
func testGalleryFilterStorePersistsIndependentlyPerCamera()
func testGallerySessionRestoresAllDefaultsForANewCamera()
func testGallerySessionOwnsGalleryCatalogWithoutReadingQuickDownloadState()
func testGallerySessionSwitchesFilterWithLatestGenerationOnly()
func testGalleryExitInvalidatesCatalogAndBothPreviewPipelines()
```

- [ ] Verify RED because Gallery state currently lives in `NativeGalleryViewController` and Runtime directly constructs CatalogRuntime.
- [ ] Add `CameraGalleryFilterStateStore` keyed by `CameraSessionIdentity.historyKey`. Store shared filter fields and Gallery-only sort; default to all/all/all/newest.
- [ ] Add `CameraGallerySession` as the Gallery façade. It owns Gallery filter state, Gallery CatalogRuntime, thumbnail pipeline, HD pipeline, and Gallery observers.
- [ ] Have Runtime create one Gallery session per active camera session and expose use-case methods for enter, submit filter, request thumbnails, switch preview mode, and disconnect.
- [ ] Remove camera task creation and filter-state authority from Gallery VC. The VC renders snapshots and sends user intents only.
- [ ] On Gallery exit confirmation, await Gallery session invalidation, terminate the camera session, clear session caches, then route Home.
- [ ] Run the five new tests plus current Gallery lifecycle and controller source-boundary tests.
- [ ] Commit: `refactor(ios): add gallery session owner`.

### Task 7: Unify Runtime-owned download submission and completion routing

**Files:** Modify Runtime, download list, Gallery VC, transfer executor contracts, and tests. Do not create a download manager.

- [ ] Add failing tests:

```swift
func testRuntimeUsesOneSubmissionAPIForManualQuickAndRecoveryDownloads()
func testRuntimeRejectsOverlappingDownloadBatch()
func testRuntimeAllowsExplicitRedownloadOfSavedHandles()
func testManualDownloadTerminalReturnsGalleryReadyWithoutDisconnect()
func testQuickDownloadTerminalRoutesByDisconnectCompletionPolicy()
func testQuickDownloadCancellationRoutesByDisconnectCompletionPolicy()
```

- [ ] Verify RED against direct `.startDownload` commands and Home-controller-owned disconnect routing.
- [ ] Add Runtime-owned value contracts:

```swift
enum CameraDownloadOrigin: Equatable, Sendable {
  case gallery
  case quickDownload
  case recovery
}

enum CameraDownloadCompletionPolicy: Equatable, Sendable {
  case returnToGallery
  case disconnectToHome
}

struct CameraDownloadSubmission: Equatable, Sendable {
  let id: UUID
  let requests: [CameraSessionQueuedDownload]
  let origin: CameraDownloadOrigin
  let completionPolicy: CameraDownloadCompletionPolicy
}
```

- [ ] Add one `submitDownload(_:)` Runtime API. It deduplicates requests, rejects queued/downloading duplicates and overlapping batches, but permits explicit `.saved` redownload.
- [ ] Keep queue, progress, recovery, current handle, lease, and counts inside Runtime.
- [ ] Apply completion policy after success, user cancellation, or terminal failure: Gallery -> `galleryReady`; Quick disconnect -> terminate and Home; Quick keep -> `galleryReady` and Gallery destination.
- [ ] Remove `disconnectAfterDownload` handling from `NativeConnectViewController.onMovedFromParent`; page navigation follows Runtime destination events.
- [ ] Keep `stopDownloadAndWait()` as the sole page-exit join contract.
- [ ] Run new tests plus admission, cancellation, recovery, background, completion, and session-reuse tests.
- [ ] Commit: `refactor(ios): unify runtime download submission`.

### Task 8: Replace QuickDownloadCoordinator with QuickDownloadUseCase

**Files:** Create `QuickDownloadUseCase.swift`; modify Quick rules, Home VC, project, tests; remove `QuickDownloadCoordinator.swift`.

- [ ] Add failing tests:

```swift
func testQuickDownloadUseCaseDoesNotObserveGalleryPresentation()
func testQuickDownloadUseCaseDoesNotMutateGalleryCatalog()
func testQuickDownloadUseCaseUsesSharedFilterEngine()
func testQuickDownloadUseCaseSubmitsRuntimeBatchWithConfiguredCompletionPolicy()
func testQuickDownloadUseCaseRoutesNoMatchWithoutStartingDownload()
```

- [ ] Verify RED against the current `runtime.observe`, `runtime.presentation.catalog`, and `CameraAutoDownloadRuleFilter` path.
- [ ] Implement async `QuickDownloadUseCase.execute(rule:)` as:

```text
validate active session
  -> resolve transient Catalog through CameraCatalogQueryEngine
  -> obtain filtered handles
  -> build CameraDownloadSubmission
  -> submit to CameraSessionRuntime
  -> return started/noMatch/failed
```

- [ ] Use `.disconnectToHome` when the Quick rule's switch is on and `.returnToGallery` when off. Apply the same terminal routing when the filter returns no matching handles, while starting no download batch.
- [ ] Do not install Quick resolution into Gallery session and do not restore/modify Gallery filter state.
- [ ] Make Home VC retain/cancel only the use-case Task, render the result, and follow Runtime destination routing.
- [ ] Remove `QuickDownloadCoordinator.swift` and all Catalog observer cleanup fields/callbacks.
- [ ] Run the five new tests plus Home quick-entry/settings tests.
- [ ] Commit: `refactor(ios): add independent quick download use case`.

### Task 9: Close CameraCore boundaries and slim controllers

**Files:** Modify Gallery sources/models/adapters, Runtime, Home/Gallery controllers, project, and tests.

- [ ] Add failing source-boundary tests:

```swift
func testCameraCoreGallerySourcesExposeNoCameraVendorResultTypes()
func testCameraCoreGalleryRuntimeExposesNoCameraVendorResultTypes()
func testGalleryControllerOwnsNoCatalogLifecycleTaskOrCameraRequestTask()
func testHomeControllerOwnsNoCatalogObserverOrDownloadDisconnectPolicy()
func testDownloadControllerOwnsNoTransportTerminationCallback()
```

- [ ] Introduce domain-only thumbnail/details/preview results at the CameraCore boundary and convert vendor values inside `CameraSessionTransferExecutor` adapters.
- [ ] Remove remaining Controller-owned Catalog lifecycle, ObjectInfo, preview fetch, download completion policy, and transport termination code.
- [ ] Keep UIKit rendering, gestures, alerts, and navigation in controllers.
- [ ] Verify no duplicate filter implementation remains with `rg` and source tests.
- [ ] Run all boundary/controller tests and a generic iPhoneOS compile.
- [ ] Commit: `refactor(ios): close gallery terminal boundaries`.

### Task 10: Final verification and physical-device handoff

**Files:** Modify only if verification exposes a refactor-caused defect.

- [ ] Run focused tests containing `CameraCommandLane`, `CameraFilterEngine`, `CatalogQueryEngine`, `CatalogRuntime`, `ThumbnailPipeline`, `HDPreviewPipeline`, `GallerySession`, `QuickDownloadUseCase`, and `CameraSessionRuntime`.
- [ ] Run full RunnerTests and capture `/tmp/codex-ios-gallery-quick-terminal-final.log`.
- [ ] Extract sorted unique failed test names to `/tmp/codex-ios-gallery-quick-terminal-final-failures.txt`.
- [ ] Compare:

```bash
comm -13 \
  /tmp/codex-ios-gallery-terminal-baseline-failures.txt \
  /tmp/codex-ios-gallery-quick-terminal-final-failures.txt
```

Expected: empty output.

- [ ] Run:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/codex-ios-gallery-quick-terminal-device-build
```

- [ ] Run `git diff --check`, inspect `git status --short`, and review `git diff --stat 2c20aa94..HEAD`.
- [ ] Build with device signing, install and launch `com.camtransfer.app` on the connected iPhone.
- [ ] Report real-camera acceptance separately for Gallery filter multi-select, HEIF fallback, thumbnail/HD switching, manual download return, Quick disconnect-to-Home, Quick keep-to-Gallery, cancellation, and Gallery disconnect-to-Home.
