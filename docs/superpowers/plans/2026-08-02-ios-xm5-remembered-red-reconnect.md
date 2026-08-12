# iOS X-M5 Remembered RED Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow an already-paired X-M5 advertising Fujifilm RED connected-device-information service `123D...` to enter the remembered BLE reconnect path, then require an exact `2A25` full-serial match before any BLE write.

**Architecture:** Preserve the existing generic matcher and every legacy/fresh-pairing branch. Add one explicit remembered-RED admission before the generic matcher: exact saved `CBPeripheral.identifier` plus `123D...`. Mark only that route with a typed admission value, and use a pure identity policy to fail closed on missing or mismatched saved/observed serial before the current secure handshake writes begin.

**Tech Stack:** Swift, CoreBluetooth, XCTest, Xcode project `ios/Runner.xcodeproj`.

---

### Task 1: Lock remembered RED advertisement admission with failing tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraVendorPairingStore.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`

- [x] **Step 1: Write failing policy tests**

Add tests proving that `X-M5 + 123D + exact saved peripheral ID` is admitted without a model-name match, while wrong endpoint and wrong service are rejected. Add a regression assertion that existing generic X-T/legacy/reference/standby matcher tests remain unchanged.

- [x] **Step 2: Run the focused tests and verify RED**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testRememberedRedReconnectAcceptsExactEndpointWith123D \
  -only-testing:RunnerTests/RunnerTests/testRememberedRedReconnectRejectsWrongEndpoint \
  -only-testing:RunnerTests/RunnerTests/testRememberedRedReconnectRejectsWrongService
```

Expected: compilation/test failure because the remembered RED admission API does not exist yet.

- [x] **Step 3: Implement the minimal typed admission**

Add a pure admission policy and a typed `generic` versus `rememberedRedReconnect` marker. Build the remembered match from the stored display name/app variant, exact endpoint, and `123D...`; retain the generic matcher as the fallback for every existing route.

- [x] **Step 4: Run the focused tests and verify GREEN**

Run the same focused command. Expected: three tests pass with zero failures.

### Task 2: Require full serial before remembered-RED writes

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Modify: `ios/Runner/CameraVendorPairingStore.swift`
- Modify: `ios/Runner/CameraVendorBluetoothService.swift`

- [x] **Step 1: Write failing identity-admission tests**

Add tests proving:

- exact stored and observed full serial permits the remembered-RED handshake;
- missing stored serial, missing `2A25`, and mismatched serial reject it;
- generic/legacy admissions are not changed by this new gate.

- [x] **Step 2: Run focused tests and verify RED**

Run the new identity-policy tests on the iPhone 16 simulator. Expected: failure because the identity decision API does not exist.

- [x] **Step 3: Implement the minimal pre-write gate**

Evaluate the pure identity policy only after metadata reads and notification subscriptions complete, but before `markHandshakeStarted()` and before any `writeValue`. On rejection, emit a reason code without full identifiers, stop the attempt, disconnect the selected peripheral, and require fresh pairing. Treat `2A00` as optional and do not compare model names.

- [x] **Step 4: Run focused admission and existing handshake tests**

Expected: all focused tests pass and existing secure-handshake ordering tests remain green.

### Task 3: Integration and regression verification

**Files:**
- Verify: `ios/Runner/CameraVendorBluetoothService.swift`
- Verify: `ios/Runner/CameraVendorPairingStore.swift`
- Verify: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Run all BLE matcher, pairing, remembered reconnect, and handshake tests**

Use `-only-testing` for the affected RunnerTests group and record the executed count and failures.

- [x] **Step 2: Run full RunnerTests**

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
```

Report the real executed/failure counts and distinguish any pre-existing failures.

- [x] **Step 3: Run iPhoneOS build and diff validation**

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug -destination 'generic/platform=iOS'
git diff --check
```

- [x] **Step 4: Preserve physical-device evidence boundary**

Do not claim real-camera completion until a fresh X-M5 run proves `rememberedRedReconnect` admission, exact `2A25` serial acceptance, ordered connection steps, and first Catalog success. Other models are regression evidence for wider rollout, not a prerequisite for implementing this isolated fix.
