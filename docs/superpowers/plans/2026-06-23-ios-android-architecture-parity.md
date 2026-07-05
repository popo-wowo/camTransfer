# iOS Android Architecture Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the iOS camera flow around Android-equivalent modules and a single orchestration layer.

**Architecture:** Add typed Swift module boundaries first, cover them with unit tests, then migrate existing BLE/PTP/UI behavior behind those interfaces. The first implementation batch creates the core architecture without deleting working legacy protocol code.

**Tech Stack:** Swift 5, UIKit, XCTest, CoreBluetooth/NetworkExtension adapters, XcodeGen project sources.

---

## File Structure

- Create `ios/Runner/CameraCore/Models/CameraCoreModels.swift`
- Create `ios/Runner/CameraCore/Registration/CameraRegistrationGuard.swift`
- Create `ios/Runner/CameraCore/Pairing/CameraPairingModule.swift`
- Create `ios/Runner/CameraCore/Connection/CameraConnectionSteps.swift`
- Create `ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift`
- Create `ios/Runner/CameraCore/Gallery/CameraGalleryModule.swift`
- Create `ios/Runner/CameraCore/Download/CameraDownloadModule.swift`
- Create `ios/Runner/CameraCore/Orchestration/CameraAppFlowCoordinator.swift`
- Modify `ios/RunnerTests/RunnerTests.swift`

## Tasks

### Task 1: Core Models and RegistrationGuard

- [ ] Add failing XCTest cases for `cameraID` identity, official Wi-Fi credential validation, and RegistrationGuard outputs.
- [ ] Create shared camera identity, pairing record, Wi-Fi credential, registration issue, and diagnostic step models.
- [ ] Implement pure `CameraRegistrationGuard.evaluate(...)`.
- [ ] Run the specific RunnerTests suite and confirm the new tests pass.

### Task 2: Connection Step Runner and Coordinator

- [ ] Add failing XCTest cases proving the connection coordinator runs exactly `ReconnectPairedBle -> TransferAuthorization -> ActivateCameraWifi -> WaitCameraWifiReady -> JoinCameraWifi -> ConnectPtp -> LoadGallery`.
- [ ] Define protocol-based connection step runners.
- [ ] Implement `CameraGalleryConnectionCoordinator` over injected step closures/runners.
- [ ] Ensure failed steps stop the chain and report the exact failed step.

### Task 3: Pairing and App Flow Orchestration

- [ ] Add failing XCTest cases proving pairing runs RegistrationGuard first and does not auto-enter gallery after save.
- [ ] Define `CameraPairingModule` protocol and pairing result models.
- [ ] Implement `CameraAppFlowCoordinator.startPairing()` and `enterCameraGallery(cameraID:)` over injected modules.
- [ ] Ensure UI-facing actions can only enter connection through the app flow coordinator.

### Task 4: Gallery and Download State Modules

- [ ] Add failing XCTest cases for gallery filter defaults, date range, format all, sort not downloaded, and download history persistence payload shape.
- [ ] Create Gallery state/filter policy matching Android dimensions.
- [ ] Create Download history model that stores `ObjectInfo`-equivalent metadata plus thumbnail bytes.
- [ ] Keep these pure Swift so they can be tested before live PTP migration.

### Task 5: Legacy Adapter Integration

- [ ] Wrap existing `CameraVendorBluetoothService` pairing/connection/gallery capabilities behind the new protocols without changing protocol behavior yet.
- [ ] Remove or disable architecture-forbidden paths at the adapter boundary: guessed SSID candidates, default password candidates, thumbnail `GET_PARTIAL_OBJECT` fallback for list thumbnails, and pairing auto-enter-gallery.
- [ ] Route `NativeConnectViewController` primary actions through `CameraAppFlowCoordinator`.

### Task 6: UI Parity Pass

- [ ] Move pairing/discovered camera entry to the upper home area.
- [ ] Change gallery header to Android parity: back icon, `CAMERA GALLERY`, download center icon.
- [ ] Change gallery bottom bar to all-select, selected/total, compression toggle, download.
- [ ] Change download center header to back icon, `DOWNLOADS`, text `清理记录`.

### Task 7: Verification and Device Install

- [ ] Run `xcodegen generate --spec ios/project.yml`.
- [ ] Run `xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,name=iPhone 17'`.
- [ ] Run `xcodebuild build -project ios/Runner.xcodeproj -scheme Runner -destination 'generic/platform=iOS'`.
- [ ] Install to the connected iPhone using the repo's existing device build path or `xcodebuild` destination once signing/device discovery is available.
