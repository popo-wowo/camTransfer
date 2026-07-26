# iOS Persistent Download Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-batch exclusive download windows with one reusable download manager and one permanent PTP command lane per camera session.

**Architecture:** `CameraSessionRuntime` owns one `CameraDownloadManager` for the lifetime of the camera session. A batch is a zero-or-one active task inside that manager; completion or cancellation returns the manager to idle, while only camera-session teardown destroys the manager and PTP lane.

**Tech Stack:** Swift 5, UIKit, Swift Concurrency, XCTest, Xcode, Fujifilm PTP adapter.

---

## Baseline and scope

- Preserve the isolated worktree and existing command-lane commits through `e8d759cd`.
- Remove only the current uncommitted multi-owner/generation/terminal-reservation WIP before implementation.
- Do not change BLE pairing, Wi-Fi handoff, `Connect -> GalleryReady`, catalog filtering, or physical transfer chunk semantics.
- Existing full-suite baseline remains 856 tests with 76 failed test methods; new failed test names are not allowed.

### Task 1: Lock the persistent-runtime contract

**Files:** Modify `ios/RunnerTests/RunnerTests.swift`.

- [ ] Add a failing source/behavior contract proving the camera runtime owns exactly one download manager and one command lane for the camera-session lifetime.
- [ ] Add a failing test proving two sequential batches use the same manager/transport identity and the first completion returns the manager to idle.
- [ ] Add a failing test proving normal completion does not call camera disconnect/termination.
- [ ] Run only the new tests and confirm RED because `CameraDownloadManager` does not exist and the current runtime owns per-batch leases.
- [ ] Commit tests only after the RED output is captured with the implementation task, not as a passing standalone commit.

### Task 2: Extract the single CameraDownloadManager

**Files:** Create `ios/Runner/CameraDownloadManager.swift`; modify `ios/Runner/CameraSessionRuntime.swift`, `ios/Runner/CameraSessionTransferExecutor.swift`, `ios/Runner.xcodeproj/project.pbxproj`, and tests.

- [ ] Move download queue, active handle, item state/progress, completed/failed counts, recovery snapshot, batch task, and batch presentation ownership from `CameraSessionRuntime` into one `@MainActor CameraDownloadManager`.
- [ ] Define `start(batch:)`, `stopAndJoin(reason:)`, and `shutdownAndJoin(reason:)`.
- [ ] Reject `start` unless state is `idle`; do not add owner IDs, refcounts, or overlapping batch support.
- [ ] Keep the manager instance installed until camera-session teardown.
- [ ] Route each physical download request through the existing `CameraCommandLane` with `.download` priority.
- [ ] Run the persistent-runtime tests and existing download queue/progress/recovery tests; expect zero targeted failures.
- [ ] Commit with `refactor(ios): add persistent camera download manager`.

### Task 3: Remove per-batch exclusive download windows

**Files:** Modify `ios/Runner/CameraVendorRealtimeGalleryService.swift`, `ios/Runner/CameraSessionTransferExecutor.swift`, `ios/Runner/CameraSessionRuntime.swift`, and tests.

- [ ] Add a failing source contract asserting production no longer contains `CameraVendorExclusiveDownloadWindowControlling`, `beginExclusiveDownloadWindow`, or `endExclusiveDownloadWindow`.
- [ ] Remove service/runtime per-batch window acquisition, owner/refcount state, and transport begin/end lease methods.
- [ ] Keep `CameraCommandLane` as the permanent serialization mechanism.
- [ ] Execute batch begin and finish/reset inside the same lane as ordered download/session-mutation work.
- [ ] Verify a later gallery command runs only after the final batch cleanup command.
- [ ] Commit with `refactor(ios): remove per-batch download windows`.

### Task 4: Make cancellation a single stop-and-join path

**Files:** Modify `ios/Runner/CameraDownloadManager.swift`, `ios/Runner/CameraSessionTransferExecutor.swift`, `ios/Runner/CameraSessionRuntime.swift`, and tests.

- [ ] Add failing tests for active transfer cancellation, queued-only cancellation, repeated stop, and stop while Photo Library commit is pending.
- [ ] Implement one stored stop task so repeated `stopAndJoin` calls await the same operation.
- [ ] Request cooperative transfer cancellation, cancel the batch task, await its exit, run terminal cleanup on the command lane, and return to idle.
- [ ] Keep `shutdownAndJoin` separate: it calls stop-and-join first, then permits transport/session teardown.
- [ ] Run cancellation, commit-gate, recovery, and command-lane ordering tests; expect zero targeted failures.
- [ ] Commit with `refactor(ios): make download cancellation joinable`.

### Task 5: Bind download-page navigation to stop completion

**Files:** Locate and modify the actual download progress/list controller, `ios/Runner/CameraSessionRuntime.swift`, and tests.

- [ ] Add a failing controller/runtime contract proving navigation occurs only after `stopAndJoin` completes.
- [ ] Render a stopping state and disable repeated stop/navigation actions while joining.
- [ ] On natural completion, keep the camera session and manager alive so gallery navigation works immediately.
- [ ] Ensure page/view lifecycle code does not restart or terminate gallery protocols.
- [ ] Commit with `refactor(ios): await download stop before navigation`.

### Task 6: Resume independent gallery pipelines after a batch

**Files:** Modify `ios/Runner/CameraSessionRuntime.swift`, Catalog/thumbnail runtime files, HD preview session, and tests.

- [ ] Add failing tests proving thumbnail/details and HD work are suspended/joined before the first download command and can resume after manager state returns to idle.
- [ ] Resume only against the current catalog/media identity; stale results remain rejected.
- [ ] Prove completing a batch allows gallery commands and a later batch on the same lane.
- [ ] Commit with `refactor(ios): resume gallery pipelines after download batch`.

### Task 7: Verification

**Files:** Modify only if verification exposes a refactor-caused defect.

- [ ] Run focused tests for `CameraCommandLane`, `CameraDownloadManager`, cancellation, recovery, gallery resume, thumbnail, and HD preview.
- [ ] Run the full suite and compare unique failed test names against `/tmp/codex-ios-gallery-terminal-baseline-failures.txt`; the new-only set must be empty.
- [ ] Run a generic iPhoneOS Debug build and confirm `** BUILD SUCCEEDED **`.
- [ ] Run `git diff --check` and inspect `git status --short`.
- [ ] Report physical-camera download/cancel/gallery-resume verification separately; tests/build do not replace a fresh camera session.
