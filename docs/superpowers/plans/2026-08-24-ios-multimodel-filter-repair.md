# iOS Multimodel Filter Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Repair iOS Gallery filter frame isolation, stale-session reuse, false empty catalogs, and add the smallest tested session-level multimodel connection-plan boundary.

**Architecture:** Keep one `CameraSessionRuntime`, one physical `CameraVendorPtpSession`, one serialized `CameraCommandLane`, and one catalog owner. Promote framing/transaction corruption to terminal lane/session state; fence catalog, thumbnail, metadata, preview, and opaque D621 references by session/generation/snapshot identity. Resolve model/family/firmware into a session-local plan without copying runtimes or treating XM5-private D621 as universal.

**Tech Stack:** Swift, XCTest, Xcode project, existing iOS Runner architecture.

---

### Task 1: Establish command-lane framing failure contract

**Files:**
- Modify: `ios/Runner/CameraTransportFailureDisposition.swift`
- Modify: `ios/Runner/CameraVendorPtpSession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing tests** for transaction mismatch, zero/short legacy length, and rejection of the next command after framing becomes unknown.
- [ ] **Step 2: Run only the new tests** with the iPhoneOS RunnerTests command and confirm RED for the missing terminal framing state.
- [ ] **Step 3: Add the smallest explicit framing state/error and classify it as session-terminal.** Do not alter successful JPG/HEIF/RAW packet sequences.
- [ ] **Step 4: Make `CameraVendorPtpSession` invalidate the physical session and command path exactly once on framing corruption; subsequent commands fail without socket reuse.**
- [ ] **Step 5: Re-run the focused tests and commit `fix(ios): isolate corrupted ptp command sessions`.

### Task 2: Fence filter transactions from child media work

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryThumbnailPipeline.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing async tests** proving filter submission awaits thumbnail/metadata cancellation and join before starting the catalog query.
- [ ] **Step 2: Run focused tests and confirm RED** with an ordering assertion.
- [ ] **Step 3: Implement the smallest cancel-and-join boundary** using existing child-task ownership; do not add another protocol owner.
- [ ] **Step 4: Add session/generation/snapshot fencing** so stale thumbnail/metadata/preview results are dropped before repository/cache/presentation publication.
- [ ] **Step 5: Re-run focused tests and commit `fix(ios): fence gallery filter child work`.

### Task 3: Preserve the last good catalog on filter failure

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogModels.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryRepository.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing tests** distinguishing true empty success from failed query with an existing valid catalog, and assert failed query never publishes `items=0` as success.
- [ ] **Step 2: Run focused tests and confirm RED.**
- [ ] **Step 3: Add explicit query failure state carrying label/generation/error while retaining the previous immutable catalog presentation.**
- [ ] **Step 4: Ensure a real empty result remains representable and does not get conflated with failure.**
- [ ] **Step 5: Re-run focused tests and commit `fix(ios): retain catalog on filter failure`.

### Task 4: Fresh-session recovery and ALL catalog reload

**Files:**
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Connection/CameraGalleryConnectionCoordinator.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing tests** proving framing failure triggers one recovery request and recovery installs a new session/generation with a fresh ALL catalog, never old D621 references.
- [ ] **Step 2: Run focused tests and confirm RED.**
- [ ] **Step 3: Wire the existing runtime recovery owner to terminate the old PTP session and restart the minimum existing connection path.**
- [ ] **Step 4: Require fresh ALL catalog installation before GalleryReady/presentation restart; keep recovery idempotent.**
- [ ] **Step 5: Re-run focused tests and commit `fix(ios): recover gallery on fresh ptp session`.

### Task 5: Minimal multimodel connection-plan boundary

**Files:**
- Modify: `ios/Runner/CameraCore/Models/CameraCoreModels.swift`
- Modify: `ios/Runner/CameraCore/Connection/CameraCompatibility.swift`
- Modify: `ios/Runner/CameraAdapters/Fujifilm/FujifilmCompatibility.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing tests** for model/family/firmware facts resolving to a session-local connection plan, unknown facts remaining unknown, and XM5-private D621 not becoming a universal mapping.
- [ ] **Step 2: Run focused tests and confirm RED.**
- [ ] **Step 3: Implement only the resolver/registry boundary and immutable plan snapshot; reuse the existing Runtime and protocol engine.**
- [ ] **Step 4: Add explicit support-status/evidence checks and keep unverified rules out of production defaults.**
- [ ] **Step 5: Re-run focused tests and commit `feat(ios): add session multimodel connection plans`.

### Task 6: Verification gates

- [ ] Run all focused RunnerTests.
- [ ] Run complete `RunnerTests` when the environment permits.
- [ ] Run iPhoneOS build/test gate and inspect exit status/output.
- [ ] Run `git diff --check` and inspect the full diff.
- [ ] Report implementation, automated proof, build/install/launch evidence, and real-camera/service acceptance separately; do not claim device resolution without fresh-device evidence.
