# iOS Runtime Reconnect Convergence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent stale network and lifecycle state from starting invalid PTP reconnects or competing BLE probes.

**Architecture:** Keep asynchronous network evidence in the shared Gallery service, pass a verified client IPv4 into the existing PTP session, and keep the Runtime worker active until cancellation convergence. BLE probe capability absence is a typed non-offline result.

**Tech Stack:** Swift, UIKit, CoreBluetooth, NetworkExtension, XCTest.

---

### Task 1: Reconnect admission

**Files:**
- Modify: `ios/Runner/CameraVendorWifiPolicy.swift`
- Modify: `ios/Runner/CameraVendorRealtimeGalleryService.swift`
- Modify: `ios/Runner/CameraVendorPtpSession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] Add a failing test rejecting nil and non-camera IPv4 values.
- [x] Add the minimal policy requiring camera IPv4 and PTP reachability.
- [x] Collect SSID/IP/reachability before entering the download command lane.
- [x] Pass the verified IPv4 into PTP INIT and reject reconnect without it.
- [x] Run reconnect and download regression tests.

### Task 2: Home lifecycle convergence

**Files:**
- Modify: `ios/Runner/CameraSessionConnectionWorker.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] Add a failing test that blocks passive reset while the worker is active.
- [x] Keep the worker active until its cancelled task exits.
- [x] Gate passive reset and startup pairing probe on Runtime worker activity.
- [x] Run worker cancellation and Home probe regression tests.

### Task 3: Probe capability classification

**Files:**
- Modify: `ios/Runner/CameraVendorPairingProbe.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`
- Modify: `ios/Runner/NativeConnectViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] Add a failing test for `validationUnavailable`.
- [x] Map missing validation service/characteristic to the new result.
- [x] Preserve teardown waiting and remembered-pairing state.
- [x] Run pairing probe regression tests.

### Task 4: Verification and delivery

**Files:**
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] Run targeted tests for all changed boundaries.
- [x] Run complete RunnerTests and separate known baseline failures.
- [x] Run iPhoneOS build and `git diff --check`.
- [ ] Commit by reconnect/lifecycle boundary.
- [ ] Build, install, launch, and collect fresh device logs without claiming real-camera completion before evidence.
