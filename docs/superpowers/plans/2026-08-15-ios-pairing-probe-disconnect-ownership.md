# iOS Pairing Probe Disconnect Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a cancelled Home pairing probe's late BLE disconnect callback from terminating a newly started remembered-camera Gallery session.

**Architecture:** Add a focused probe teardown token/gate beside the existing full-reset gate, consume probe-owned disconnects before mainline routing, and require explicit active-mainline ownership before publishing terminal BLE failure. The UI awaits bounded probe teardown before starting the Runtime connection worker.

**Tech Stack:** Swift, CoreBluetooth, XCTest, Flutter iOS Runner Xcode project

---

### Task 1: Probe teardown gate

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing gate tests**

Add tests that construct a probe teardown token, begin teardown, and assert that only a matching peripheral UUID plus `ObjectIdentifier` consumes it. Add a timeout test asserting that the unresolved tombstone remains until the matching late callback arrives.

- [ ] **Step 2: Run the targeted tests and verify RED**

Run the RunnerTests target filtered to the new `BluetoothPairingProbeTeardown` test names. Expected: compile failure because the token and gate do not exist.

- [ ] **Step 3: Implement the minimal token and gate**

Add `CameraVendorPairingProbeTeardownToken` and `CameraVendorPairingProbeTeardownGate`, following the existing `CameraVendorBluetoothFullResetGate` locking, timeout, continuation, and tombstone pattern.

- [ ] **Step 4: Run the targeted tests and verify GREEN**

Run the same filtered tests. Expected: all new teardown gate tests pass.

### Task 2: Disconnect ownership routing

**Files:**
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing routing tests**

Add policy tests for probe teardown consumption, active-mainline acceptance, and orphan disconnect rejection. The active route must require matching UUID, peripheral object identity, and connection generation.

- [ ] **Step 2: Run the targeted tests and verify RED**

Expected: compile failure because the routing policy does not exist.

- [ ] **Step 3: Implement minimal routing policy and service wiring**

Register the probe teardown token before cancelling the probe peripheral. In `didDisconnectPeripheral`, consume full reset first, then probe teardown, then consult the active-mainline ownership policy. Log and return for orphan callbacks.

- [ ] **Step 4: Run the targeted tests and verify GREEN**

Expected: all disconnect routing tests pass.

### Task 3: Await teardown before remembered connection

**Files:**
- Modify: `ios/Runner/CameraSessionConnectionWorker.swift`
- Modify: `ios/Runner/CameraVendorConnectFlowBridge.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing orchestration test**

Add a Runtime/controller test proving that the remembered connection worker is not started until probe teardown completes, and that teardown failure produces a retryable preparation failure without starting BLE mainline work.

- [ ] **Step 2: Run the targeted test and verify RED**

Expected: failure because the current cancellation API is synchronous and starts the worker immediately.

- [ ] **Step 3: Add async teardown boundary**

Expose `cancelPairingProbeAndWait(reason:) async -> Bool` through the connection controller and Runtime. Split `connectRememberedCamera` so its existing connection start runs only after successful teardown.

- [ ] **Step 4: Run the targeted tests and verify GREEN**

Expected: orchestration and ownership tests pass.

### Task 4: Full verification and device acceptance

**Files:**
- Verify all modified iOS sources and tests.

- [ ] **Step 1: Run targeted tests**

Run all new probe teardown and disconnect ownership tests. Expected: zero failures.

- [ ] **Step 2: Run full RunnerTests**

Run the complete RunnerTests scheme. Expected: all tests pass with zero failures.

- [ ] **Step 3: Run source and build checks**

Run `git diff --check`, a generic iPhoneOS build, and a signed build for the connected device. Expected: exit code 0 for each command.

- [ ] **Step 4: Install and perform real-device acceptance**

Install a uniquely numbered build. Re-pair X-T5, immediately enter Gallery, and pull the diagnostic log. Expected: any probe disconnect is logged as consumed, no premature `REMEMBERED_GALLERY_TERMINAL_FAILURE` occurs, the dynamic Plan revises to verified RED after GATT, and the run reaches `GALLERY_READY`.
