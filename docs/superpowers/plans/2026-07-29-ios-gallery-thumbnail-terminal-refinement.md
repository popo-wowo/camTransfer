# iOS Gallery Thumbnail Terminal Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Every production change follows RED -> GREEN -> REFACTOR.

**Goal:** Close the remaining iOS Gallery thumbnail terminal-architecture defects with layered suspension, latest-wins viewport scheduling, exact ObjectInfo reuse, monotonic Details enrichment, typed incremental events, and bounded failure state.

**Architecture:** Keep `CameraGalleryCatalogRuntime` and `CameraGalleryRepository` as membership and item-state owners. Refine `CameraGalleryThumbnailPipeline` into independent thumbnail and Details scheduling state, preserve exact ObjectInfo at the source boundary, and make UI updates consume typed content/structural deltas.

**Tech Stack:** Swift 5, UIKit, Swift Concurrency actors/tasks, XCTest, Xcode, Fujifilm PTP adapter.

---

## Scope

- Work only in `/Users/g01d-01-1224/.config/superpowers/worktrees/camtransfer/codex/ios-gallery-terminal-refactor`.
- Preserve all pre-existing dirty WIP.
- Do not add `EnrichmentCoordinator`, `MediaWorkGate`, or a second Gallery item store.
- Do not change connection startup, download protocol, or unrelated UI layout.

### Task 1: Layer Catalog and external suspension

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add/retain failing tests proving Download and HD suspension survive Catalog installation.
- [ ] Run the selectors and confirm the current shared counter fails.
- [ ] Replace the shared counter with explicit Catalog and external suspension reasons/counts.
- [ ] Clear only Catalog suspension in `install()` and replay the latest viewport only when all suspension reasons are clear.
- [ ] Run the suspension and Catalog transaction tests; expect zero focused failures.

### Task 2: Make viewport requests latest-wins across actor re-entry

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add a deterministic source that blocks cancellation/join and lets a newer viewport enter first.
- [ ] Add a failing test proving the older request currently cancels/replaces the newer request.
- [ ] Allocate a viewport revision before the first `await` and validate it after every join.
- [ ] Start work only if the revision still matches; preserve subset deduplication for the latest request.
- [ ] Run viewport, replay, visible-window, and same-snapshot subset tests.

### Task 3: Preserve exact ObjectInfo from thumbnailWithInfo

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Modify: `ios/Runner/CameraVendorRealtimeGalleryService.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySources.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryRepositoryAdapters.swift`
- Modify: `ios/Runner/CameraSessionTransferExecutor.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add failing tests with a non-zero format code and incomplete metadata-only response.
- [ ] Change `CameraVendorGalleryThumbnail`/`CameraGalleryThumbnailResult` to carry real ObjectInfo explicitly.
- [ ] Remove synthetic `formatCode: 0` promotion.
- [ ] Skip Details only for reusable ObjectInfo with confirmed completeness.
- [ ] Run thumbnail-with-info, Repository monotonicity, format, and orientation tests.

### Task 4: Make Details enrichment monotonic and starvation-free

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add a failing test that repeatedly interrupts Details with visible viewports and expects a deep handle to complete.
- [ ] Track membership-specific Details cursor and completed handles.
- [ ] Pause Details for visible work without discarding progress.
- [ ] Reset progress only when Catalog identity/membership changes; retain same-session reusable ObjectInfo.
- [ ] Run Details fairness, cancellation, resume, and wait-idle tests.

### Task 5: Publish typed incremental deltas

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add failing tests for late orientation re-decode and date/section structural refresh.
- [ ] Add a delta value describing changed handles plus structural/orientation effects.
- [ ] Have Repository mutations report the actual effects they caused.
- [ ] Use targeted cell refresh for content-only changes.
- [ ] Invalidate decoded images for orientation changes; rebuild sections and trim selection for structural changes.
- [ ] Run content-event, selection-stability, orientation, and section tests.

### Task 6: Add bounded thumbnail failure state

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogModels.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add failing tests for bounded retries, terminal failure publication, and no immediate re-request.
- [ ] Add deterministic retry policy with bounded attempts and backoff state.
- [ ] Publish loading/loaded/failed thumbnail state through Repository.
- [ ] Pass the real failed state to `NativeGalleryVisibleThumbnailPolicy`.
- [ ] Clear failure only on explicit retry or session invalidation.
- [ ] Run thumbnail retry/loading policy tests.

### Task 7: Close observer and decoded-cache identity gaps

**Files:**
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add failing source/lifecycle tests requiring incremental observer removal.
- [ ] Retain incremental observer IDs in Gallery and Download Center and remove them in `deinit`.
- [ ] Replace handle-only decoded-cache keys with session/orientation-aware keys or clear the cache on identity change.
- [ ] Guard background decode completion against the active cache identity.
- [ ] Run observer, reconnect, stale-cache, and orientation tests.

### Task 8: Validate HEIF subtract-baseline relationships

**Files:**
- Modify: `ios/Runner/CameraVendorPtpSession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add failing tests for malformed date groups, ambiguous set relationships, and invalid isolated counts.
- [ ] Validate both snapshots before subtraction and reject relationships that cannot prove the intended membership.
- [ ] Preserve cancellation and SearchMode restore behavior.
- [ ] Run HEIF query, cancellation, restore, and Catalog validation tests.

### Task 9: Verification

- [ ] Run all new and affected focused tests into `/tmp/camtransfer-thumbnail-terminal-targeted.log`.
- [ ] Run the complete RunnerTests suite into `/tmp/camtransfer-thumbnail-terminal-full.log` and extract failed test names.
- [ ] Compare failures with the pre-change review list and explain or repair every new failure.
- [ ] Run `git diff --check`.
- [ ] Build Debug for `generic/platform=iOS` with signing disabled.
- [ ] Review the final diff against the approved design and report real-camera scenarios separately.
