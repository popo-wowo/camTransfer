# Android Connection Flow Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Android connection orchestration so auto mode and guided mode share explicit connection phases, steps, issues, and user actions.

**Architecture:** Keep BLE, WiFi, and PTP command implementations intact. Add a lightweight connection flow model and orchestrator policy layer, then route `ConnectionViewModel` through structured state instead of parsing status strings.

**Tech Stack:** Android Kotlin, Jetpack Compose, JUnit 4, Gradle Android plugin.

---

### Task 1: Connection Flow Model

**Files:**
- Create: `app/src/main/java/com/camtransfer/service/CameraConnectionFlow.kt`
- Test: `app/src/test/java/com/camtransfer/service/CameraConnectionFlowTest.kt`

- [x] **Step 1: Write failing tests**

Add tests for:

```kotlin
@Test fun `pairing ack issue blocks gallery entry`() {
    val issue = CameraConnectionIssue.pairingAckPending()
    assertEquals(CameraConnectionPhase.PAIR_CAMERA, issue.phase)
    assertEquals(CameraConnectionStep.PairingConfirmation, issue.step)
    assertFalse(issue.allowedActions.contains(CameraConnectionAction.EnterGallery))
}

@Test fun `wifi timeout switches auto flow to guided mode at wifi step`() {
    val transition = CameraConnectionFlowPolicy.onFailure(
        mode = CameraConnectionMode.AUTO,
        step = CameraConnectionStep.JoinCameraWifi,
        failure = CameraConnectionFailure.WifiJoinTimeout,
        attempt = 2,
    )
    assertEquals(CameraConnectionMode.GUIDED, transition.mode)
    assertEquals(CameraConnectionStep.JoinCameraWifi, transition.step)
}
```

- [x] **Step 2: Run tests and confirm they fail**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.service.CameraConnectionFlowTest`

- [x] **Step 3: Implement model**

Create enums/data classes:

```kotlin
enum class CameraConnectionPhase { PAIR_CAMERA, ENTER_GALLERY }
enum class CameraConnectionMode { AUTO, GUIDED }
enum class CameraConnectionAction { RetryStep, RestartPairing, EnterGallery, ConfirmCameraReady, ConfirmWifiJoined, OpenSystemBluetoothSettings }
```

Define `CameraConnectionStep`, `CameraConnectionFailure`, `CameraConnectionIssue`, `CameraConnectionTransition`, and `CameraConnectionFlowPolicy`.

- [x] **Step 4: Run tests and confirm they pass**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.service.CameraConnectionFlowTest`

### Task 2: ViewModel State Mapping

**Files:**
- Modify: `app/src/main/java/com/camtransfer/viewmodel/ConnectionViewModel.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/CameraConnectionStatusPolicyTest.kt`

- [x] **Step 1: Write failing tests**

Add tests proving:

```kotlin
@Test fun `guided wifi issue maps to wifi state and keeps paired context`() {
    val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.JoinCameraWifi)
    assertEquals(ConnectionState.CONNECTING_WIFI, state)
}

@Test fun `pairing confirmation step maps to waiting confirmation`() {
    val state = CameraConnectionUiPolicy.stateForStep(CameraConnectionStep.PairingConfirmation)
    assertEquals(ConnectionState.WAITING_CAMERA_CONFIRMATION, state)
}
```

- [x] **Step 2: Run tests and confirm they fail**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.CameraConnectionStatusPolicyTest`

- [x] **Step 3: Implement mapping**

Add `CameraConnectionUiPolicy` and expose structured `connectionIssue` / `connectionMode` state from `ConnectionViewModel`.

- [x] **Step 4: Run tests and confirm they pass**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.CameraConnectionStatusPolicyTest`

### Task 3: Connect Existing Flow Through Structured Issues

**Files:**
- Modify: `app/src/main/java/com/camtransfer/service/CameraService.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/ConnectionViewModel.kt`

- [x] **Step 1: Convert known failures to issues**

Map current failure messages into structured issues for:

```text
Stale system Bluetooth bond
Pairing ACK pending
WiFi join timeout
PTP not ready
Not connected to camera
```

- [x] **Step 2: Preserve existing BLE/WiFi/PTP calls**

Do not alter UUIDs, payloads, opcodes, or packet formats in this task.

- [x] **Step 3: Run unit tests**

Run: `./gradlew testDebugUnitTest`

### Task 4: Guided UI Surface

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/ConnectScreen.kt`

- [x] **Step 1: Show structured issue card**

When `ConnectionViewModel.connectionIssue` is non-null, show:

```text
title
detail
primary action
secondary action when present
```

- [x] **Step 2: Restrict actions by issue**

Do not show `Enter Gallery` while the issue is in `PAIR_CAMERA`.

- [x] **Step 3: Build**

Run: `./gradlew assembleDebug`

### Task 5: Install

**Files:**
- No source changes expected.

- [x] **Step 1: Verify device**

Run: `adb devices`

- [x] **Step 2: Install debug APK**

Run: `adb install -r app/build/outputs/apk/debug/app-debug.apk`

Expected: `Success`

### Task 6: Pairing Start Confirmation Gate

**Files:**
- Modify: `app/src/main/java/com/camtransfer/service/CameraConnectionFlow.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/ConnectionViewModel.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/ConnectScreen.kt`
- Modify: `app/src/test/java/com/camtransfer/service/CameraConnectionFlowTest.kt`
- Modify: `app/src/test/java/com/camtransfer/viewmodel/CameraConnectionStatusPolicyTest.kt`

- [x] **Step 1: Write failing tests**

Add tests proving `CameraPairingMode` creates a guided issue with `ConfirmCameraPairingMode`, and UI policy does not map this gate to active scanning.

- [x] **Step 2: Run tests and confirm they fail**

Run:

```text
./gradlew testDebugUnitTest --tests com.camtransfer.service.CameraConnectionFlowTest
./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.CameraConnectionStatusPolicyTest
```

- [x] **Step 3: Implement gate**

Clicking “连接相机” now publishes `CameraConnectionIssue.cameraPairingModeRequired()` and does not call BLE scan. The issue primary action confirms the camera is already on the pairing registration page, then starts the existing pairing flow.

- [x] **Step 4: Verify and install**

Run full unit tests, build debug APK, then install to Android device.
