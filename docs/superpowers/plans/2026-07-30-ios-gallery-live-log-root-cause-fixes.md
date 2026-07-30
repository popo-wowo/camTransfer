# iOS Gallery Live-Log Root-Cause Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the post-filter thumbnail stall, make HD decode failures retryable, and add low-noise device diagnostics for the remaining orientation issue.

**Architecture:** Keep the existing Catalog Runtime, Repository, Thumbnail Pipeline, and HD Preview Pipeline ownership. Preserve already-enriched item content when a new catalog generation contains the same handle, invalidate an HD cache entry before retrying it, and log only state-machine boundaries needed to distinguish query, install, publication, viewport, fetch, decode, and rotation decisions.

**Tech Stack:** Swift, UIKit, Swift Concurrency, XCTest, Xcode device build, `xcrun devicectl`.

---

### Task 1: Preserve enriched items across catalog generations

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

Add a repository test that installs a first snapshot, applies a thumbnail and confirmed orientation, then installs a second snapshot containing the same handle and asserts that `thumbnailData`, orientation, confirmed format, and entry thumbnail state remain available.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' -only-testing:RunnerTests/RunnerTests/testGalleryRepositoryPreservesEnrichedContentForSharedHandlesAcrossInstall
```

Expected: FAIL because `install` currently replaces `items` with the bare catalog snapshot.

- [ ] **Step 3: Implement the minimal merge**

In `CameraGalleryRepository.install`, index the existing items by handle and merge their monotonic resolved metadata and `thumbnailData` into matching incoming items before rebuilding entries. Do not preserve handles absent from the new membership.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same `xcodebuild test` command and expect one passing test with zero failures.

### Task 2: Make HD decode failures retryable

**Files:**
- Modify: `ios/Runner/NativePhotoPreviewViewController.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write the failing test**

Add a pipeline test that preloads a bad cache entry, activates the pipeline, calls `retry(handle:)`, and asserts that the fetch closure is invoked and the replacement data is cached.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' -only-testing:RunnerTests/RunnerTests/testHDPreviewRetryInvalidatesLoadedCacheEntryAndRefetches
```

Expected: FAIL because `retry(handle:)` leaves the handle in `cache.loadedHandles`, so the pump excludes it.

- [ ] **Step 3: Implement explicit single-entry invalidation**

Add `remove(_:)` to `NativeGalleryHighDefinitionPreviewCache` and call it from `CameraGalleryHDPreviewPipeline.retry(handle:)` before reprioritizing the handle.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the same focused command and expect zero failures.

### Task 3: Add low-noise live diagnostics

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add diagnostic contract assertions**

Assert that source contains stable event names for catalog resolution/install/publication, viewport submission/cache-hit count, HD plan/request/finish/cancel/skip, HD decode failure, and orientation decision inputs.

- [ ] **Step 2: Implement boundary logs without handle-array dumps**

Emit counts, identity values, one active handle, elapsed milliseconds, and decision reasons. Do not log full catalog payloads or full handle arrays.

- [ ] **Step 3: Run diagnostic contract tests**

Run the focused RunnerTests diagnostics tests and expect zero failures.

### Task 4: Verify and install

**Files:**
- Verify all scoped changes above.

- [ ] **Step 1: Run full RunnerTests**

Run the repository-native `xcodebuild test` command against the available iOS simulator and record executed/passed counts.

- [ ] **Step 2: Run iPhoneOS build**

```bash
xcodebuild -project ios/Runner.xcodeproj -scheme Runner -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/camtransfer-gallery-log-fix-device-build -allowProvisioningUpdates build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install on the paired iPhone**

```bash
xcrun devicectl device install app --device 952611F0-557B-5C5F-BF1F-265474E9BC4B /private/tmp/camtransfer-gallery-log-fix-device-build/Build/Products/Debug-iphoneos/Runner.app
```

- [ ] **Step 4: Execute and pull the acceptance log**

Exercise all -> RAW, all -> HEIF, thumbnail -> HD with more than 30 cards, and one known wrong-orientation handle. Pull `Documents/camtransfer_debug*.log` and compare the new boundary timestamps and terminal pending/failed sets.

### Task 5: Fence viewport submissions to the catalog that produced them

**Files:**
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Capture a RED regression for stale cache replay and source contracts**

Run the four focused tests for stale cache replay, runtime identity stamping, accepted-submit logging, and UIImage orientation diagnostics. Expected: four failures before production changes.

- [x] **Step 2: Stamp the catalog identity before creating the runtime Task**

Capture `expectedCatalogIdentity` synchronously in `CameraSessionRuntime`, pass it through `CameraGallerySession`, and reject it in `CameraGalleryCatalogRuntime` unless it exactly matches the current ready generation and snapshot.

- [x] **Step 3: Stop stale cache publication at the next actor re-entry**

Classify cached, failed, and camera-backed handles without awaiting. Before and after each cached publication, verify the viewport submission and catalog identity are still current so an older viewport can finish at most its in-flight publication.

- [x] **Step 4: Make diagnostics describe real submissions and full orientation inputs**

Emit `THUMBNAIL_VIEWPORT_SUBMIT` only after runtime/admission/duplicate guards accept the viewport, and include camera `objectOrientation` in the UIImage-oriented decode branch.

- [ ] **Step 5: Run focused GREEN and device verification**

Run the four focused tests, the gallery core regression set, `git diff --check`, an iPhoneOS build, install, and launch. Keep live camera/HD 30-card acceptance open until new user-driven logs are captured.
