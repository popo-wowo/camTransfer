# iOS Gallery Session Termination Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make gallery and Quick Download cancellation immediate and reliable, restore thumbnail loading after HD preview, and route HEIF through the cancellable subtract-baseline catalog query instead of a per-file classification stall.

**Architecture:** Quick Download, gallery browsing, thumbnail preview, and HD preview remain independent feature pipelines and caches. They share one `CameraSessionRuntime` physical-session owner; that owner must stop command admission and terminate PTP before awaiting child cleanup. Catalog and preview cleanup may finish asynchronously, but stale work cannot publish into a new session.

**Tech Stack:** Swift, Swift Concurrency, XCTest, Xcode 16/iOS Simulator 18.4.

---

### Task 1: Physical-session termination ordering

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`

- [x] Change `testDisconnectToHomePublishesOnlyAfterCameraTermination` so a suspended thumbnail request still observes `terminate` immediately, while navigation to home waits only for the termination call and not for child completion.
- [x] Change `testGalleryExitInvalidatesCatalogAndBothPreviewPipelines` to require `transport.terminateCameraCommunication(reason:)` before awaiting `previousSession.invalidate()` or `previousLifecycleTask.value`.
- [x] Run the two tests and verify they fail against the current wait-first implementation.
- [x] In `beginCatalogSessionTermination`, detach the current session/query owner, reject new commands, call physical transport termination immediately, then asynchronously invalidate and join old child pipelines.
- [x] Fence the retired catalog/thumbnail/HD-preview generation synchronously before closing PTP, so no old task can issue another command through the rebindable transport.
- [x] Bind overlay cancellation to the exact captured transport binding and make the tap one-shot, so stale UI work cannot close a replacement session.
- [x] Keep termination idempotent and remove deferred terminal routing tasks so repeated page exit, Quick Download terminal routing, and transport-loss cleanup cannot close a replacement session.
- [x] Re-run the two tests and the existing Quick Download terminal tests.

### Task 2: Thumbnail visible-window replay

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`

- [x] Add a test that starts a visible thumbnail batch, suspends it before completion, resumes, and expects all uncached visible handles to be requested again without a new UI request.
- [x] Run the test and verify the current `resume()` fails because it only restarts Details.
- [x] Persist the latest visible handle order separately from the active task; on final resume, replay only uncached handles for the current catalog identity.
- [x] Clear the stored visible window on session invalidation and catalog membership replacement.
- [x] Re-run all thumbnail and HD-preview pipeline tests.

### Task 3: HEIF subtract-baseline cancellation and status

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraCatalogQueryEngine.swift`
- Modify: `ios/Runner/QuickDownloadUseCase.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`

- [x] Add a query-engine test that suspends the HEIF subtract-baseline request, invalidates the engine, and expects the late result to be rejected.
- [x] Add a Quick Download test that observes `.queryingCatalog` while the HEIF catalog query is running.
- [x] Run the tests and verify the progress and overlay-cancellation contracts are absent.
- [x] Add a small query progress value and callback without coupling Quick Download to gallery presentation state.
- [x] Update the connecting overlay to display `正在筛选相机照片` once connection is ready.
- [x] Ensure cancelling the overlay cancels the Quick Download task and triggers the immediate Runtime termination path when the flow is leaving the camera session.

### Task 4: Logging and verification

**Files:**
- Modify only the logging call sites proven to duplicate ObjectInfo/metadata lines.

- [x] Add a regression test so high-frequency ObjectInfo request begin/end records remain memory/console-only.
- [x] Remove high-frequency ObjectInfo success records from disk forwarding while preserving `[OBS]` begin/end and failure evidence.
- [x] Run targeted tests (20 executed, 0 failures):

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testDisconnectToHomePublishesOnlyAfterCameraTermination \
  -only-testing:RunnerTests/RunnerTests/testGalleryExitInvalidatesCatalogAndBothPreviewPipelines
```

- [x] Run all `RunnerTests` and compare against the frozen base instead of claiming a green suite that the repository does not have: base `aa4c599e` executed 933 tests with 60 failed test cases; the changed tree executed 941 tests with the same base failure set plus one independently reproduced flaky exclusive-window timing test that also fails on the unchanged base under the current simulator state.
- [x] Run a generic Debug iPhoneOS build and `git diff --check`.
- [ ] When the iPhone becomes available, pull `Runner.diskwrites_resource-2026-07-27-195208.ips`, install the new build, launch it, and reproduce the five reported scenarios with a real camera.
