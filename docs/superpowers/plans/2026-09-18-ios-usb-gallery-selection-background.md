# iOS USB Gallery Selection and Background Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Match wireless-gallery drag selection in the USB gallery, simplify USB grid metadata, and report USB import progress on the Lock Screen and Dynamic Island during the finite background execution window.

**Architecture:** Generalize the existing wireless drag-selection policy over hashable item identifiers and call it from both gallery controllers. Reuse the existing ActivityKit controller and widget, adding optional aggregate byte progress so wireless count-only snapshots remain compatible. Give USB import its own UIKit background lease and centralize every import terminal path so the lease and Live Activity cannot leak.

**Tech Stack:** Swift 5, UIKit, ImageCaptureCore, ActivityKit, WidgetKit, XCTest, xcodebuild, devicectl.

---

### Task 1: Simplify USB Grid Metadata

**Files:**
- Modify: `ios/Runner/WiredCameraImportViewController.swift`

- [ ] **Step 1: Remove filename presentation from the USB grid cell**

Delete `titleLabel` from `WiredCameraImportGridCell`, set `detailLabel.text = item.fileSizeText`, and constrain the size label directly to the single-line information bar. Keep `formatBadgeLabel` as the format presentation.

- [ ] **Step 2: Build the app target**

Run:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED` with no references to the removed label.

### Task 2: Reuse Wireless Drag Selection in USB Gallery

**Files:**
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Modify: `ios/Runner/WiredCameraImportModels.swift`
- Modify: `ios/Runner/WiredCameraImportViewController.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing USB range-selection tests**

Add tests proving that USB item IDs use the shared `NativeGalleryDragSelectionPolicy` for selecting and deselecting continuous ranges while skipping unsupported IDs. Reuse existing intent and auto-scroll tests without adding a duplicate USB policy.

```swift
func testWiredCameraDragSelectionUsesSharedWirelessRangePolicy() {
  let updated = NativeGalleryDragSelectionPolicy.updatedRangeSelection(
    selectedHandles: Set(["outside"]),
    orderedHandles: ["1", "2", "unsupported", "3"],
    startHandle: "1",
    endHandle: "3",
    selectableHandles: Set(["1", "2", "3"]),
    mode: .selecting
  )
  XCTAssertEqual(updated, ["outside", "1", "2", "3"])
}
```

- [ ] **Step 2: Run the new test and verify RED**

Run the new `testWiredCameraDragSelection...` tests with `xcodebuild test` on simulator `9B0FEEC3-4C3B-4312-B606-876D9076EB0F`.

Expected: compile failure because the current policy accepts only `Int` handles.

- [ ] **Step 3: Generalize the shared policy**

Change `mode`, `shouldCommitDragSelection`, `updatedSelection`, and `updatedRangeSelection` in `NativeGalleryDragSelectionPolicy` to generic functions constrained to `ID: Hashable`. Do not change the gesture thresholds, continuous-range semantics, or auto-scroll calculation.

- [ ] **Step 4: Add USB gesture ownership**

Add a one-finger `UIPanGestureRecognizer` to `WiredCameraImportViewController` with the same delegate, touch cancellation, horizontal-intent, commit, and edge-scroll behavior as `NativeGalleryViewController`. Store the starting item ID, last endpoint, and shared selection mode.

Flatten `visibleItems()` for ordered IDs. Build selectable IDs from live, importable items, including already imported items because they remain valid camera-delete targets.

- [ ] **Step 5: Refresh selection UI without reloading thumbnails**

Add `updateSelectionOnly(_:)` to `WiredCameraImportGridCell`. During a drag, update only changed visible cells, visible date headers, the selection count, and bottom actions. Perform a normal render only after the gesture ends if another presentation value requires it.

- [ ] **Step 6: Run shared and USB drag tests**

Run all `testNativeGalleryDragSelection...` and `testWiredCamera...` tests.

Expected: existing wireless behavior remains green and the USB String-ID test passes.

### Task 3: Add Optional Byte Progress to Shared Live Activity

**Files:**
- Modify: `ios/Shared/CameraSessionActivityAttributes.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/CameraSessionLiveActivityController.swift`
- Modify: `ios/CameraSessionActivityWidget/CameraSessionActivityWidget.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing progress fallback tests**

Add tests proving that byte progress is used when total bytes are positive and count progress remains unchanged when byte fields are absent.

```swift
XCTAssertEqual(byteState.downloadProgressFraction, 0.25, accuracy: 0.001)
XCTAssertEqual(countState.downloadProgressFraction, 0.5, accuracy: 0.001)
```

- [ ] **Step 2: Run the progress tests and verify RED**

Expected: compile failure because byte fields do not exist.

- [ ] **Step 3: Extend the shared state compatibly**

Add optional `downloadCompletedBytes` and `downloadTotalBytes` fields to `CameraSessionActivityAttributes.ContentState` and `CameraSessionRuntimeActivitySnapshot`. Update `downloadProgressFraction` to prefer valid byte progress and fall back to completed/total counts.

Pass the optional values through `CameraSessionLiveActivityController` while leaving all wireless snapshot call sites valid through default `nil` values.

- [ ] **Step 4: Keep widget copy count based and progress byte aware**

Keep the existing remaining-item labels. The existing `ProgressView` automatically uses the updated computed fraction.

- [ ] **Step 5: Run affected ActivityKit tests**

Run the new progress tests plus current Live Activity/runtime activity tests.

Expected: byte and count paths both pass.

### Task 4: Connect USB Import to Live Activity and Background Lease

**Files:**
- Modify: `ios/Runner/WiredCameraImportModels.swift`
- Modify: `ios/Runner/WiredCameraImportViewController.swift`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing USB activity snapshot tests**

Add a pure `WiredCameraImportActivityPolicy` that creates start/progress snapshots and determines terminal cleanup. Test camera name, total item count, aggregate current bytes, completed count, and background state.

- [ ] **Step 2: Run the policy tests and verify RED**

Expected: compile failure because `WiredCameraImportActivityPolicy` does not exist.

- [ ] **Step 3: Implement the activity policy**

Create snapshots with a per-import UUID, selected-device name, catalog item count, imported count, total import count, aggregate completed bytes, total bytes, and current background state.

- [ ] **Step 4: Own activity and execution state in the USB controller**

Add a `CameraSessionLiveActivityController`, `CameraSessionUIKitExecutionAuthority`, lifecycle observer tokens, import session ID, completed byte count, total byte count, and expiry flag to `WiredCameraImportViewController`.

At import start:

- acquire the execution lease;
- create and publish the activity snapshot;
- update the snapshot from `downloadProgressHandler`;
- publish foreground/background changes from app lifecycle notifications.

- [ ] **Step 5: Centralize import cleanup**

On success, failure, cancellation, disconnect, expiry completion, and deinit:

- release the execution lease;
- end the matching Live Activity;
- clear session and byte state;
- leave `isImporting` false and restore navigation state.

When the UIKit background lease expires, cancel the queue. Since ImageCaptureCore does not expose `cancelDownload` on iOS, allow the active request callback to return, then stop before saving or starting the next item and show a foreground-required message.

- [ ] **Step 6: Run USB and activity tests**

Run all `testWiredCamera...` tests and affected activity tests. Expected: zero failures.

### Task 5: Device Verification and Delivery

**Files:**
- Verify: `ios/Runner.xcodeproj`

- [ ] **Step 1: Run diff and commit checks**

Run `git diff --check` and inspect staged hunks so unrelated dirty WIP stays unstaged.

- [ ] **Step 2: Build a signed device app**

Run `xcodebuild` against Xcode device UDID `00008150-001C7D2C2E7A401C` with a fresh derived-data directory and `-allowProvisioningUpdates`.

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Install and launch**

Install using CoreDevice ID `952611F0-557B-5C5F-BF1F-265474E9BC4B`, then launch `com.camtransfer.app` with `--terminate-existing`.

- [ ] **Step 4: Perform physical USB acceptance**

With the USB camera connected, verify:

- cells show format and size without filenames;
- horizontal drag selects and deselects across rows and date sections;
- edge drag scrolls;
- Lock Screen and Dynamic Island show count and moving byte progress;
- a short transfer continues after locking the phone;
- background expiry is reported truthfully instead of leaving a false active state.

- [ ] **Step 5: Commit only scoped implementation hunks**

Commit the production and test changes without staging pre-existing WIP.
