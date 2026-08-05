# iOS Gallery Connection Copy and D22B A/B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 安全修复 Wi-Fi 前后连接文案，并在该版本真机通过后用单变量 A/B 验证 `D22B` 是否可以从首次 Catalog 前移除或延后。

**Architecture:** 文案进度继续复用 `IOSCameraConnectionStep`，但所有 step observer 都通过显式 `@MainActor` 契约执行，`CameraVendorConnectFlowBridge` 只能在 MainActor 上发布 Snapshot。性能实验与文案包完全分离，只改变首次 legacy prepare 中的 `D22B` 一个 wire-visible 变量。

**Tech Stack:** Swift 5、UIKit、Swift Concurrency、XCTest、Xcode 16+、CoreDevice、PTP/IP vendor commands。

**Delivery constraint:** 不创建 commit，不 push，不 reset/clean/stash/checkout；只使用现有隔离工作树。

---

## File Structure

- `ios/Runner/CameraCore/Connection/CameraConnectionSteps.swift`
  - 连接 step 到用户文案的纯策略。
- `ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift`
  - 保证 step-start observer 通过 MainActor 执行。
- `ios/Runner/CameraCore/Orchestration/CameraConnectFlowCoordinator.swift`
  - 把 Gallery loader 的 `publishStep` 类型固定为 `@MainActor`。
- `ios/Runner/CameraCore/Orchestration/CameraConnectFlowRuntime.swift`
  - 把 Runtime environment 的 step callback actor 契约传递到 Bridge。
- `ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift`
  - 把 pre-PTP 和 route coordinator 的 step callback 保持为 MainActor observer。
- `ios/Runner/CameraVendorConnectFlowBridge.swift`
  - 在 MainActor 上更新连接文案并发布已有 Home Snapshot。
- `ios/Runner/CameraVendorBluetoothService.swift`
  - Wi-Fi handoff 前只发布“正在等待相机 Wi-Fi”。
- `ios/RunnerTests/RunnerTests.swift`
  - wire/state 文案测试、真实后台执行器到 MainActor 的并发回归、连接协调器回归。
- `ios/Runner/CameraVendorPtpSession.swift`
  - 阶段二 B 包唯一允许改变的协议文件；阶段一不得修改。
- `docs/ios-gallery-entry-final-solution-20260804.md`
  - 回写阶段一与阶段二实际证据和真机 Gate。

### Task 1: Add RED tests for copy boundaries and MainActor delivery

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add the pure copy-boundary test**

```swift
func testGalleryConnectionStatusCopyChangesOnlyAfterWifiJoinCompletes() {
  for step in [
    IOSCameraConnectionStep.reconnectPairedBle,
    .transferAuthorization,
    .activateCameraWifi,
    .waitCameraWifiReady,
    .joinCameraWifi,
  ] {
    XCTAssertEqual(
      CameraVendorConnectionStepStatusTextPolicy.status(for: step),
      "正在等待相机 Wi-Fi"
    )
  }

  for step in [
    IOSCameraConnectionStep.connectPtp,
    .confirmGalleryMode,
    .loadGallery,
  ] {
    XCTAssertEqual(
      CameraVendorConnectionStepStatusTextPolicy.status(for: step),
      "正在进入相机相册"
    )
  }
}
```

- [ ] **Step 2: Add the runtime concurrency regression**

Create a coordinator inside `Task.detached`, start `.reconnectPairedBle`, and use an `@MainActor` `onStepStarted` observer that records `Thread.isMainThread`. Assert the observed step is `.reconnectPairedBle` and the callback ran on the main thread.

- [ ] **Step 3: Run RED tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project Runner.xcodeproj \
  -scheme Runner \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testGalleryConnectionStatusCopyChangesOnlyAfterWifiJoinCompletes \
  -only-testing:RunnerTests/RunnerTests/testIOSGalleryConnectionCoordinatorDeliversStepObserverOnMainThread
```

Expected: compile/test failure because the status policy and `@MainActor` step-observer contract do not exist yet. The RED result must not be an unrelated build or simulator failure.

### Task 2: Make the step callback actor contract explicit

**Files:**
- Modify: `ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift`
- Modify: `ios/Runner/CameraCore/Orchestration/CameraConnectFlowCoordinator.swift`
- Modify: `ios/Runner/CameraCore/Orchestration/CameraConnectFlowRuntime.swift`
- Modify: `ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift`
- Modify: `ios/Runner/CameraVendorConnectFlowBridge.swift`

- [ ] **Step 1: Require a MainActor observer at the connection coordinator boundary**

Use this contract:

```swift
private let onStepStarted: (@MainActor (IOSCameraConnectionStep) -> Void)?
```

Invoke it from `connect` with:

```swift
if let onStepStarted {
  await onStepStarted(runner.step)
}
```

- [ ] **Step 2: Propagate the same actor contract through loader/runtime signatures**

Every `publishStep` parameter in the Gallery loader chain must be:

```swift
publishStep: @escaping @MainActor (IOSCameraConnectionStep) -> Void
```

Do not add a second progress callback or another connection owner.

- [ ] **Step 3: Add the Bridge MainActor snapshot update**

In `CameraVendorConnectFlowBridge.loadGallerySession`, pass a MainActor closure that first forwards `publishStep(step)`, then applies the pure status policy and calls the existing `publishSnapshot()`.

Do not modify `NativeGalleryLoadingPhrase` and do not dispatch UIKit work from a loader/background queue.

- [ ] **Step 4: Run the concurrency test**

Expected: `testIOSGalleryConnectionCoordinatorDeliversStepObserverOnMainThread` passes and reports `Thread.isMainThread == true`.

### Task 3: Implement the copy policy without changing protocol behavior

**Files:**
- Modify: `ios/Runner/CameraCore/Connection/CameraConnectionSteps.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add the pure status policy**

```swift
enum CameraVendorConnectionStepStatusTextPolicy {
  static let waitingForCameraWifiStatus = "正在等待相机 Wi-Fi"
  static let enteringGalleryStatus = "正在进入相机相册"

  static func status(for step: IOSCameraConnectionStep) -> String {
    switch step {
    case .reconnectPairedBle,
         .transferAuthorization,
         .activateCameraWifi,
         .waitCameraWifiReady,
         .joinCameraWifi:
      return waitingForCameraWifiStatus
    case .connectPtp, .confirmGalleryMode, .loadGallery:
      return enteringGalleryStatus
    default:
      return waitingForCameraWifiStatus
    }
  }
}
```

The implementation may return `String?` if needed for non-gallery steps, but the tested eight official Gallery steps must map exactly as specified.

- [ ] **Step 2: Change only the BLE/AP status copy**

Restore `CameraVendorTransferActivationStatusTextPolicy.waitingForCameraWifiStatus` and use it at transfer-start and AP-ready callbacks. Do not modify BLE writes, timeout durations, activation completion, Wi-Fi join or PTP logic.

- [ ] **Step 3: Run focused copy and connection tests**

Run the two new tests plus:

- `testIOSGalleryConnectionCoordinatorRunsAndroidStepOrder`
- `testIOSGalleryConnectionCoordinatorStopsAtFailedStep`
- `testIOSConnectFlowCoordinatorPublishesIntermediateConnectionSteps`
- `testIOSConnectFlowCoordinatorProducesGallerySessionOnSuccess`
- `testGalleryEntryNavigationWaitsForPreloadBeforeEnteringAlbumPage`

Expected: all selected tests pass with zero failures.

### Task 4: Verify and install the phase-one copy build

**Files:**
- No production file changes.

- [ ] **Step 1: Confirm scope**

Run `git diff --check` and verify `ios/Runner/CameraVendorPtpSession.swift` has no new phase-one hunk.

- [ ] **Step 2: Build a fresh signed device package**

Use destination `00008150-001C7D2C2E7A401C` and a new DerivedData directory.

- [ ] **Step 3: Install and launch**

Install to CoreDevice `952611F0-557B-5C5F-BF1F-265474E9BC4B`, launch `com.camtransfer.app`, and record install plus launch output.

- [ ] **Step 4: Stop at the physical-camera checkpoint**

The user verifies:

- no launch or connection crash;
- before phone Wi-Fi join: “正在等待相机 Wi-Fi”;
- after join and before GalleryReady: “正在进入相机相册”;
- Wi-Fi joins and GalleryReady completes.

Do not start Task 5 until this checkpoint is confirmed.

### Task 5: Run the D22B single-variable A/B after phase-one acceptance

**Files:**
- Modify only for B build: `ios/Runner/CameraVendorPtpSession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`
- Modify: `docs/ios-gallery-entry-final-solution-20260804.md`

- [ ] **Step 1: Capture A-build timings**

Pull device logs and record timestamps for user tap, AP ready, Wi-Fi join, PTP open, `PTP_GALLERY_BOOTSTRAP_D22B`, first `9053`, Catalog install and GalleryReady.

- [ ] **Step 2: Add a RED contract test for the B-build switch**

The test must prove only `D22B` changes while D212, D244, 9050 skip behavior, first 9053 and GalleryReady gating remain unchanged.

- [ ] **Step 3: Build B with one wire-visible difference**

Skip or defer only `requestCameraVendorCurrentObjectHandleSnapshot(stage: "gallery-bootstrap")`. Do not reorder or remove D212/D244 and do not add retry/replay.

- [ ] **Step 4: Run focused tests, build and install B**

Use a separate DerivedData/result bundle path from phase one and A build.

- [ ] **Step 5: Apply the X-T5/X-M5 Gate**

Validate first entry, second entry, filter, disconnect/reconnect and absence of `0x2013`, empty Catalog, double snapshot or premature GalleryReady.

- [ ] **Step 6: Decide production behavior and update documentation**

Keep B only if both camera models pass and the measured improvement matches the removed D22B wait. Otherwise restore A behavior. Record exact tests, builds, logs and remaining device gates without committing or pushing.
