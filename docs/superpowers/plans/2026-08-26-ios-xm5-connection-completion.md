# iOS XM5 Connection Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** Complete the XM5 BLE connection lifecycle so every formal connection has one owner, bounded timeout, generation-safe cancellation, precise terminal classification, and an evidence-based re-pair boundary.

**Architecture:** Keep CameraVendorBluetoothService as the single runtime owner. Add one managed BLE-connect entry point for mainline and recovery purposes, while keeping pairing probe as a separately identified purpose. Use pure policies for terminal classification and source-structure tests to prevent new direct connection bypasses.

**Tech Stack:** Swift, CoreBluetooth, XCTest, existing iOS Runner diagnostics.

---

### Task 1: Lock the managed-connect contract with failing tests

**Files:**
- Modify: ios/RunnerTests/RunnerTests.swift

- [x] **Step 1: Write failing tests**

Add tests asserting that timeout, failure, cancellation, and supersession map to distinct outcomes, and that production service source contains no unclassified formal central.connect call outside the managed helper or explicitly marked probe path.

- [x] **Step 2: Run focused tests to verify RED**

Run the existing Runner test command used by this worktree, filtering the new test names. Expected result: the new source-structure test fails because current service still has direct formal calls.

- [x] **Step 3: Implement only the minimum policy/test helpers**

Expose a pure source-inspection fixture helper in the test target if required; do not change production behavior in this task.

- [x] **Step 4: Run focused tests again**

Confirm policy tests pass and the source-structure test remains the single expected failure.

### Task 2: Introduce the single managed BLE-connect entry point

**Files:**
- Modify: ios/Runner/CameraVendorBluetoothService.swift
- Modify: ios/RunnerTests/RunnerTests.swift

- [x] **Step 1: Write failing behavior tests**

Cover fresh pairing, remembered direct reconnect, remembered scan reconnect, secure-handshake recovery, and activation recovery. Assert each creates a generation-bound timeout owner and records its purpose.

- [x] **Step 2: Run tests and verify RED**

Tests must fail because timeout is scheduled only in selected paths and direct call sites do not carry a purpose.

- [x] **Step 3: Implement the helper**

Add a private helper named startManagedBleConnect(peripheral, purpose, generation, delay). It validates the active token and selected peripheral, schedules exactly one timeout for the generation, emits BLE_CONNECT_START with purpose, and calls central.connect only after the optional delay. Existing timeout cleanup remains the single terminal owner.

- [x] **Step 4: Migrate formal call sites**

Migrate fresh pairing, phone-confirmation reconnect, remembered direct reconnect, scan reconnect, secure-handshake recovery, activation recovery, and automatic remembered scan reconnect. Keep pairing probe calls separate and explicitly labeled as probe-owned.

- [x] **Step 5: Run focused tests**

Confirm managed-connect tests pass and source-structure test reports only the intentional probe call.

### Task 3: Complete pairing-probe timeout and terminal isolation

**Files:**
- Modify: ios/Runner/CameraVendorBluetoothService.swift
- Modify: ios/Runner/CameraVendorPairingProbe.swift
- Modify: ios/RunnerTests/RunnerTests.swift

- [x] **Step 1: Write failing tests**

Add tests for probe timeout, cancellation, late didConnect, late didFailToConnect, and late disconnect after teardown. Assert probe completion never publishes mainline BLE success and each continuation completes once.

- [x] **Step 2: Run focused tests and verify RED**

Expected failure: probe lacks a complete timeout/terminal outcome for every connection path.

- [x] **Step 3: Implement bounded probe lifecycle**

Use a probe-specific timeout and teardown token. On timeout, complete the probe as offline/unknown unless an explicit pairing-invalid error was observed; cancel the peripheral and consume late callbacks through the existing teardown gate.

- [x] **Step 4: Run focused tests**

Confirm probe tests pass and mainline ownership tests remain green.

### Task 4: Finish typed terminal classification and user-action mapping

**Files:**
- Modify: ios/Runner/CameraVendorBluetoothService.swift
- Modify: ios/Runner/CameraSessionConnectionWorker.swift when typed terminal data crosses that boundary
- Modify: ios/RunnerTests/RunnerTests.swift

- [x] **Step 1: Write failing tests**

Assert distinct terminal reasons for remembered scan timeout, BLE timeout, identity mismatch, registration rejection, and activation disconnect. Assert only explicit security errors and explicit identity/registration conflicts request re-pair.

- [x] **Step 2: Run tests and verify RED**

Expected failure: scan timeout and connect timeout currently share broad reconnect wording.

- [x] **Step 3: Implement typed terminal reasons**

Add or extend the issue/disposition model with rememberedCameraScanTimeout, bleConnectTimeout, gattServiceDiscoveryFailed, identityReadFailed, identityMismatch, registrationRejected, and activationDisconnected. Map each reason to an actionable status without deleting pairing records for uncertain failures.

- [x] **Step 4: Add diagnostic observations**

Emit BLE_SCAN_TARGET, BLE_ADVERTISEMENT_CANDIDATE, BLE_MATCH_DECISION, GATT_IDENTITY_RESULT, APP_REGISTRATION_RESULT, and CONNECTION_TERMINAL with generation, purpose, and redacted identifiers.

- [x] **Step 5: Run focused tests**

Confirm terminal and log-shape tests pass.

### Task 5: Verify mutation ordering and stale-state cleanup

**Files:**
- Modify: ios/Runner/CameraVendorBluetoothService.swift
- Modify: ios/RunnerTests/RunnerTests.swift

- [x] **Step 1: Write failing ordering tests**

Assert connected-device-name writes, identification ACK writes, transfer activation, and Wi-Fi activation cannot occur before the remembered GATT identity gate succeeds. Assert identity mismatch clears only stale App registration state and does not erase unrelated display metadata.

- [x] **Step 2: Run tests and verify RED**

Expected failure in any branch that starts mutation after reconnect without completed identity evidence.

- [x] **Step 3: Implement minimum admission guards**

Guard every mutation entry with active generation and verified identity evidence. Route explicit mismatch/rejection to re-pair; route unknown timeout/disconnect to bounded recovery.

- [x] **Step 4: Run focused tests**

Confirm ordering and cleanup tests pass.

### Task 6: Full regression, build, install, and device gates

**Files:**
- No new production files.
- Evidence: test/build logs and device diagnostics.

- [x] **Step 1: Run focused XM5 tests**

Expected: all new policy, lifecycle, terminal, and ordering tests pass.

- [x] **Step 2: Run full RunnerTests**

Expected: the known pre-existing build-number assertion remains the only failure; do not change build metadata or weaken the test.

- [x] **Step 3: Run source/build checks**

Run git diff --check, generic iPhoneOS build, and signed build.

- [ ] **Step 4: Install and smoke test**

Install on the available iPhone and verify launch, normal XM5 connection, cancellation, background/foreground, camera power-off, and XApp re-pair sequence.

- [ ] **Step 5: Report remaining gates separately**

Report code, automated tests, build, install, successful-XM5 physical evidence, TestFlight distribution, and two failing-XM5 A/B evidence as separate gates. Do not claim 100% before the last two evidence gates are complete.

## Diagnostic instrumentation delivered

The XM5 BLE path now emits bounded observations at each troubleshooting
boundary without persisting Wi-Fi passphrases or raw registration payloads:

- `BLE_SCAN_TARGET` records scan purpose, generation, and remembered target.
- `BLE_ADVERTISEMENT_CANDIDATE` records safe advertisement shape, RSSI, and
  manufacturer summary; `BLE_MATCH_DECISION` records accepted/rejected reason.
- `GATT_IDENTITY_RESULT` records link, service-discovery, and characteristic-
  discovery outcomes.
- `APP_REGISTRATION_RESULT` records identification-marker, app-info write, and
  registration acceptance/rejection outcomes.
- `PAIRING_PROBE_TIMEOUT` and `CONNECTION_TERMINAL` preserve the first failed
  barrier and elapsed scan time.

These events are diagnostic only: generic scan/BLE timeouts remain recoverable
failures and do not trigger pairing cleanup. Cleanup remains restricted to
explicit security or registration/identity evidence.

## 2026-08-26 follow-up: Wi-Fi evidence and PTP framing recovery

- Wi-Fi interface snapshots now prefer `en0`. Cellular `pdp_*` interfaces are
  retained only as non-camera diagnostics and cannot be used as camera Wi-Fi
  evidence. The `freeifaddrs` list is always released through its original
  head pointer.
- A PTP transaction mismatch invalidates the physical session immediately.
  The command/event sockets are closed, later commands are rejected with a
  session-invalid error, and the existing bounded reconnect path must create a
  fresh INIT/OpenSession before gallery work resumes. Ordinary PTP response
  codes remain operation-level errors and do not automatically tear down the
  session.
- These changes are evidence-driven from the real-device crash and mismatch
  logs; they do not assert undocumented XApp internals.
