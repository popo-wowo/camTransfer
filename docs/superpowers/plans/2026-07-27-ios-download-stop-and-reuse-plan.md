# iOS Download Stop and Session Reuse Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make download-page exit wait for real cancellation completion while preserving the existing reusable camera/PTP session, sequential Runtime queue, and batch scheduling barrier.

**Architecture:** `CameraSessionRuntime` remains the sole download owner and exposes one awaitable stop command. `NativeDownloadListViewController` awaits that command before navigation; manual, quick, and recovered download entry points reuse the same page and Runtime. No new manager, owner refcount, generation, connection, or transfer lane is added.

**Tech Stack:** Swift 5, UIKit, Swift Concurrency, XCTest, Xcode, Fujifilm PTP adapter.

---

## Scope and baseline

- Work only in `/Users/g01d-01-1224/.config/superpowers/worktrees/camtransfer/codex/ios-gallery-terminal-refactor`.
- Preserve the original `/Users/g01d-01-1224/Documents/camtransfer` checkout.
- Keep the committed single `CameraCommandLane` and existing exclusive download scheduling barrier.
- Do not change BLE pairing, Wi-Fi handoff, `Connect -> GalleryReady`, PTP chunking, throughput tuning, catalog filters, or cache identities.
- The known untouched baseline is 856 tests with 76 failed test methods; completion must add no new failed test name.

### Task 1: Add the Runtime stop-and-join contract

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`

- [ ] **Step 1: Write the failing active-transfer test**

Add `testCameraSessionRuntimeStopDownloadAndWaitJoinsCancelledTransfer` beside the existing Runtime cancellation tests. Start handle 101, launch a MainActor Task awaiting `runtime.stopDownloadAndWait()`, yield until Runtime reaches `.cancelling`, assert the Task has not returned, send `.transferCancelled(handle: 101)`, await the Task, then assert `.galleryReady` and no camera termination.

- [ ] **Step 2: Run the new test and verify RED**

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeStopDownloadAndWaitJoinsCancelledTransfer
```

Expected: compilation fails because `CameraSessionRuntime` has no `stopDownloadAndWait()`.

- [ ] **Step 3: Implement the minimal Runtime API**

Add a Runtime-owned collection of cancellation wait continuations. `stopDownloadAndWait()` sends `.cancelDownloadByUser`, returns immediately unless the resulting phase is `.cancelling`, and otherwise registers a continuation. After each command mutation, resume and clear the continuations when the phase is no longer `.cancelling`.

- [ ] **Step 4: Add and pass the immediate-return test**

Add `testCameraSessionRuntimeStopDownloadAndWaitReturnsImmediatelyWhenIdle`, enter gallery, await `galleryReady`, call the API, and assert the phase and transport termination count remain unchanged.

- [ ] **Step 5: Run both Runtime tests**

Use two exact `-only-testing` selectors and expect `Executed 2 tests, with 0 failures`.

### Task 2: Bind download-page navigation to the Runtime join

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`

- [ ] **Step 1: Write the failing navigation-order contract**

Add `testNativeDownloadListBackWaitsForRuntimeStopBeforePopping`. Extract the `backTapped()` source body and assert `await runtime.stopDownloadAndWait()` appears before `popViewController`, the body contains a stopping-state guard, and it does not call `onTerminateDownload`.

- [ ] **Step 2: Run the test and verify RED**

Expected: assertion failure because the current controller invokes `onTerminateDownload()` and immediately pops.

- [ ] **Step 3: Implement minimal page behavior**

Remove the `onTerminateDownload` initializer dependency and all three parent call-site closures. Add `isStoppingForExit`; after destructive confirmation, set it, refresh the stopping UI, await `runtime.stopDownloadAndWait()`, and pop only after the await returns. While stopping, keep the spinner active, show `正在停止下载…`, disable back, and prevent record clearing.

- [ ] **Step 4: Run the navigation-order and Runtime tests**

Expected: all selected tests pass and controller call sites compile.

### Task 3: Verify existing session-reuse contracts

**Files:** Modify only if a regression caused by Tasks 1-2 is found.

- [ ] Run the existing cancellation/session-reuse tests:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeUserCancellationStopsQueueWithoutDisconnectingHealthyCamera \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeDrainsCancelledTransferBeforeAcceptingAnotherQueue \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeHoldsOneExclusiveLeaseAcrossTheWholeQueue
```

- [ ] Run HD preview pause/resume and visible-thumbnail admission tests selected by exact current method names.
- [ ] Run `git diff --check`.

### Task 4: Full verification

**Files:** Modify only if verification exposes a change-caused defect.

- [ ] Run full `RunnerTests` on simulator and capture the executed count and unique failed test names.
- [ ] Compare failures with `/tmp/codex-ios-gallery-terminal-baseline-failures.txt`; the new-only set must be empty.
- [ ] Run a generic iPhoneOS Debug build:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

- [ ] Run `git diff --check`, inspect `git status --short`, and review every changed line against the scope.
- [ ] Report simulator/build evidence separately from the still-required real-camera stop-and-return acceptance.
