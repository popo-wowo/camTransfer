# iOS Gallery Thumbnail Smoothness Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make thumbnail loading fast, strictly follow the current top-to-bottom viewport after navigation/filter changes, and remove filter spinner and orientation replacement flashes.

**Architecture:** Keep `CameraGalleryCatalogRuntime`, `CameraGalleryThumbnailPipeline`, and the repository ownership model. Replace cancel-and-restart viewport batches with one stable serial worker that reads the latest ordered viewport after every in-flight thumbnail; keep ObjectInfo in the independent Details lane; let UIKit retain the previous decoded image until an orientation-correct replacement is ready.

**Tech Stack:** Swift concurrency actors, UIKit collection view, XCTest, Xcode simulator/device builds.

---

### Task 1: Lock the scheduling contract with RED tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add a test that submits viewport revision 2 before delayed revision 1 and expects only revision 2 to be accepted.
- [ ] Add a test that keeps handle 1 in flight, submits `[9, 8]`, and proves the submission returns without joining handle 1; after release the request order must be `[1, 9, 8]`.
- [ ] Add a request-window test expecting visible handles, then rows below, then rows above.
- [ ] Add source-contract tests proving `viewDidAppear` resubmits the visible window and thumbnail fetch does not pre-read ObjectInfo.
- [ ] Run the selected tests and record the expected failures against the current implementation.

### Task 2: Make viewport scheduling truly latest-wins

**Files:**
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`

- [ ] Stamp each UI viewport submission at `CameraSessionRuntime` before creating asynchronous work.
- [ ] Pass the stamp through Session and Catalog Runtime into the pipeline.
- [ ] Reject stamps older than the latest accepted stamp.
- [ ] Keep one thumbnail worker alive; update its ordered target list in place and re-evaluate it after the current PTP request completes.
- [ ] Cancel and join only background Details work when a visible request needs the PTP lane; do not cancel the active thumbnail batch for every viewport change.
- [ ] Run the focused pipeline/runtime tests until green.

### Task 3: Shorten the thumbnail hot path and prevent flashes

**Files:**
- Modify: `ios/Runner/CameraVendorTransferPolicy.swift`
- Modify: `ios/Runner/CameraVendorPtpSession.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeGalleryPolicies.swift`

- [ ] Keep the camera-required ObjectInfo context prime before `GetThumb`; optimize its cost only with a separately verified protocol path while Details remains authoritative.
- [ ] Change nearby ordering to visible -> below -> above and keep the window bounded.
- [ ] On orientation change, retain the old decoded image and mark it stale instead of deleting it.
- [ ] Decode the new orientation from existing thumbnail bytes, atomically swap the cache key/image, then remove the old image.
- [ ] Run thumbnail policy, repository, decode, and UI source-contract tests until green.

### Task 4: Remove filter and navigation churn

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraCatalogQueryEngine.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`

- [ ] Add a read-only cached-resolution lookup to the query engine.
- [ ] Install cached memberships directly without publishing `.loading`.
- [ ] Preserve the existing grid while an uncached camera membership transaction is running; avoid a redundant reload when only loading state changed.
- [ ] Resubmit the actual visible window from `viewDidAppear` so returning from preview immediately restores top-to-bottom priority.
- [ ] Run cached-filter and lifecycle tests until green.

### Task 5: Verify on simulator and physical device

**Files:**
- Verify only.

- [ ] Run selected regression tests on the booted iPhone 16 simulator.
- [ ] Run the complete `RunnerTests` suite and confirm a non-zero executed-test count with zero failures.
- [ ] Build `Runner` for `iphoneos`.
- [ ] Install and launch on device `952611F0-557B-5C5F-BF1F-265474E9BC4B`.
- [ ] Reproduce open gallery, return from preview, scroll, and format/date filter changes; compare request order, per-thumbnail latency, batch size, spinner publications, and orientation invalidation logs against the captured baseline.
