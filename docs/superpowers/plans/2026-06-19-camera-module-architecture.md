# Camera Module Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split camera pairing, connection, gallery, and download into clean modules, with connection implemented as independent step runners.

**Architecture:** Keep `CameraService` as a compatibility facade while extracting responsibilities into focused services. Connection becomes an orchestrator over typed step runners, each representing one official XApp step and returning a typed output for the next step.

**Tech Stack:** Android Kotlin, coroutines, existing BLE/PTP/Wi-Fi adapters, JUnit unit tests, Gradle.

---

## File Structure

- Create `app/src/main/java/com/camtransfer/service/gallery/PtpCameraGallerySource.kt`
  - Implements `CameraFileSource` for connected PTP gallery operations only.
- Create `app/src/main/java/com/camtransfer/service/pairing/CameraPairingService.kt`
  - Owns fresh pairing and pairing confirmation.
- Create `app/src/main/java/com/camtransfer/service/connection/CameraGalleryConnectionStepRunner.kt`
  - Defines typed connection step runner contract.
- Create `app/src/main/java/com/camtransfer/service/connection/CameraGalleryConnectionSteps.kt`
  - Contains independent runners for each official connection step.
- Create `app/src/main/java/com/camtransfer/service/connection/CameraGalleryConnectionService.kt`
  - Orchestrates official connection steps in order.
- Modify `app/src/main/java/com/camtransfer/service/CameraService.kt`
  - Convert to facade and shared dependency owner.
- Modify tests under `app/src/test/java/com/camtransfer/service`
  - Add boundary tests and keep existing behavior tests green.

## Tasks

### Task 1: Lock Connection Step Contracts

- [ ] Add tests that assert each official connection step is represented by an independent runner.
- [ ] Create `CameraGalleryConnectionStepRunner<I, O>` with `val step: CameraConnectionStep`.
- [ ] Add concrete runner shells for all eight official connection steps.
- [ ] Run `./gradlew testDebugUnitTest --tests com.camtransfer.service.CameraConnectionFlowTest`.

### Task 2: Extract Gallery Source

- [ ] Add `PtpCameraGallerySource` implementing `CameraFileSource`.
- [ ] Move `listFiles`, `fastInitialFiles`, `getThumbnail`, `getThumbnailWithInfo`, `resolveFile`, `getPreviewImage`, `getFile`, and placeholder ObjectInfo creation out of `CameraService`.
- [ ] Make `CameraService` delegate `CameraFileSource` methods to `PtpCameraGallerySource`.
- [ ] Run gallery and thumbnail tests.

### Task 3: Extract Pairing Service

- [ ] Add `CameraPairingService` with dependencies: `Context`, `CameraVendorBleScanner`, `CameraVendorPairedCameraStore`, and BLE session callbacks.
- [ ] Move `pairWithCamera`, `confirmPairing`, stale bond check, and system bond removal helpers.
- [ ] Keep `CameraService` facade methods with same signatures.
- [ ] Run pairing and connection unit tests.

### Task 4: Extract Connection Service and Step Runners

- [ ] Move remembered BLE reconnect into `ReconnectPairedBleStep`.
- [ ] Move transfer authorization into `TransferAuthorizationStep`.
- [ ] Move transfer activation into `ActivateCameraWifiStep`.
- [ ] Move AP ready wait into `WaitCameraWifiReadyStep`.
- [ ] Move Wi-Fi join into `JoinCameraWifiStep`.
- [ ] Move PTP open into `ConnectPtpStep`.
- [ ] Move gallery mode confirmation into `ConfirmGalleryModeStep`.
- [ ] Move handle load into `LoadGalleryStep`.
- [ ] Keep `CameraGalleryConnectionService.connectToGallery()` as the only orchestrator.

### Task 5: Clean Facade and Boundaries

- [ ] Ensure `CameraService` only delegates and owns shared runtime objects.
- [ ] Ensure `TransferService` still only depends on `CameraFileSource`.
- [ ] Ensure Gallery code does not import BLE/Wi-Fi packages.
- [ ] Update docs if any boundary changes during implementation.

### Task 6: Verify and Install

- [ ] Run `./gradlew testDebugUnitTest`.
- [ ] Run `./gradlew assembleDebug`.
- [ ] Run `./gradlew installDebug`.
- [ ] Pull diagnostic logs after user validation if connection fails.
