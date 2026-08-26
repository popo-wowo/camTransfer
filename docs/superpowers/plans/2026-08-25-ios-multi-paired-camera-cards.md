# iOS Multi-Paired Camera Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep multiple paired cameras independently persisted, show them as a horizontally swipeable card pager, operate only on the visible camera, and expose deletion from the card's top-right ellipsis menu instead of swipe-to-delete.

**Architecture:** Reuse the existing multi-record `CameraVendorPairedCameraStore` and single active `CameraSessionRuntime`. The home screen owns a horizontal paging container and passes one explicit `IOSCameraRememberedCameraRecord` to connection/probe/delete actions. No parallel connection state, multi-runtime switching, or cross-device cache is introduced.

**Tech Stack:** Swift, UIKit, XCTest, existing CamTransfer iOS Runtime and pairing store.

---

### Task 1: Lock paired-record isolation and explicit-current selection

**Files:**
- Modify: `ios/Runner/CameraVendorPairingStore.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Write failing tests** for the new pager/menu behavior; existing store tests already cover saving A/B, removing A, and legacy migration.
- [x] **Step 2: Run focused XCTest and verify RED.**
- [x] **Step 3: Add the smallest record-selection helpers and replace implicit first-record usage in service entry points that feed the home card/probe path.** Keep the existing store schema and legacy migration.
- [x] **Step 4: Run focused XCTest and verify GREEN.**

### Task 2: Add horizontal paired-camera card pager

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift` policy/test sections
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Write failing tests** proving the pager is horizontal and has one page per saved camera.
- [x] **Step 2: Run focused XCTest and verify RED.**
- [x] **Step 3: Add a horizontally paging `UIScrollView` page container.** Use one card per record and preserve the existing card action callbacks with their captured record.
- [x] **Step 4: Run focused XCTest and verify GREEN.**

### Task 3: Move deletion to ellipsis menu and remove swipe deletion

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Write failing tests** asserting the paired card exposes an ellipsis menu with a delete action and does not install left/right swipe recognizers for deletion.
- [x] **Step 2: Run focused XCTest and verify RED.**
- [x] **Step 3: Remove `revealDeleteAction`, `hideDeleteAction`, and the delete swipe gestures.** The top-right ellipsis opens a menu whose only action is deleting that card's captured record, followed by the existing confirmation flow.
- [x] **Step 4: Run focused XCTest and verify GREEN.**

### Task 4: Verify connection/probe/delete use only the visible card

**Files:**
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Modify: `ios/Runner/CameraVendorConnectFlowBridge.swift` only if explicit-record routing needs a narrow signature correction
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Preserve explicit record capture for connect, quick download, disconnect, and delete callbacks; visible card identity drives pairing probe selection.
- [x] **Step 2: Run focused regression tests.**
- [x] **Step 3: Keep unrelated recovery behavior unchanged unless it already receives an explicit peripheral ID.
- [x] **Step 4: Run the full iOS RunnerTests target and `git diff --check`.**

### Task 5: Build verification

**Files:**
- No production files.

- [x] **Step 1: Run the full test target again from a clean command invocation.**
- [x] **Step 2: Run the iOS Simulator build using the existing Runner scheme and destination available in the worktree.**
- [x] **Step 3: Inspect the diff for unrelated changes and report automated proof separately from device/UI acceptance.**
