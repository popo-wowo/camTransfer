# iOS Remove Blocking 9050 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop an unused `0x9050 SearchModeDescAll` query from failing Gallery startup while preserving the camera-side SearchMode filter transaction and future descriptor capability support.

**Architecture:** Remove the descriptor call from the blocking bootstrap and empty-Catalog recovery paths in `CameraVendorPtpSession`. Keep the opcode, request helper, retry policy, and filter transaction implementation. Lock the boundary with source-level regression tests and document that any future descriptor query is optional and outside GalleryReady.

**Tech Stack:** Swift, XCTest, Xcode `RunnerTests`, Markdown protocol documentation.

---

### Task 1: Lock the startup/filter boundary with tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Extend the bootstrap ownership test**

Add assertions that the body of `prepareCameraVendorLegacyGalleryLoad()` does not contain `requestCameraVendorSearchModeDescAll()` and still contains the `D22B` snapshot plus the final `D212 #3` read.

- [ ] **Step 2: Add a filter-chain preservation test**

Read the `cameraVendorCatalogSnapshot` implementation region and assert that the filter implementation still contains `requestCameraVendorSearchModeAll`, `cameraVendorSetSearchModeAll`, `restoreCameraVendorSearchModeAll`, `requestCameraVendorSpecifiedObjectSnapshot`, and the `0x9053/D620/D621` request helpers. Also assert that empty-Catalog recovery does not call `requestCameraVendorSearchModeDescAll()`.

- [ ] **Step 3: Run the targeted tests and verify RED**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests/RunnerTests/testLegacyPtpLoadGalleryBootstrapSkipsUnusedSearchModeDescription -only-testing:RunnerTests/RunnerTests/testCameraSideFilterTransactionDoesNotDependOnSearchModeDescription
```

Expected: the bootstrap test fails because production still calls `requestCameraVendorSearchModeDescAll()`.

### Task 2: Remove the blocking Gallery/Catalog requests

**Files:**
- Modify: `ios/Runner/CameraVendorPtpSession.swift:623-642`

- [ ] **Step 1: Delete the blocking `0x9050` call**

Remove the `PTP_GALLERY_BOOTSTRAP_9050` report and `try requestCameraVendorSearchModeDescAll()` from `prepareCameraVendorLegacyGalleryLoad()`.

- [ ] **Step 2: Add an explicit diagnostic boundary**

Report:

```swift
report("[OBS] PTP_GALLERY_BOOTSTRAP_9050_SKIPPED reason=unused-search-mode-description")
```

immediately before the existing `D22B` step.

Replace the empty-Catalog recovery call with:

```swift
report("[OBS] PTP_SPECIFIED_OBJECT_EMPTY_RECOVERY_9050_SKIPPED stage=... reason=unused-search-mode-description")
```

Keep the existing bounded delay, optional `D22B` refresh, and retry.

- [ ] **Step 3: Run the targeted tests and verify GREEN**

Run the Task 1 command again. Expected: both tests pass.

### Task 3: Record the protocol decision

**Files:**
- Modify: `docs/camera-vendor-adaptation-protocol.md`
- Verify: `docs/superpowers/specs/2026-08-03-ios-gallery-9050-boundary-design.md`

- [ ] **Step 1: Update the startup sequence**

Remove `9050` from the blocking production startup sequence and document the skip diagnostic.

- [ ] **Step 2: Preserve the future capability boundary**

Document that `9050` remains available for a future optional descriptor/capability probe, while camera-side filtering continues through `9052/9051/9053/D620/D621`.

- [ ] **Step 3: Scan for contradictory startup requirements**

Run:

```bash
rg -n '9050.*(must|required|必需|必须)|9050 -> D22B|9054 -> 9055 -> 9050' docs/camera-vendor-adaptation-protocol.md docs/superpowers/specs/2026-08-03-ios-gallery-9050-boundary-design.md
```

Expected: no current rule requires `9050` to block GalleryReady.

### Task 4: Verify the complete iOS test suite

**Files:**
- Verify: `ios/Runner/CameraVendorPtpSession.swift`
- Verify: `ios/RunnerTests/RunnerTests.swift`
- Verify: protocol documentation

- [ ] **Step 1: Run full RunnerTests**

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' -only-testing:RunnerTests
```

Expected: a non-zero executed-test count and zero failures.

- [ ] **Step 2: Review the final diff**

```bash
git diff --check
git diff -- ios/Runner/CameraVendorPtpSession.swift ios/RunnerTests/RunnerTests.swift docs/camera-vendor-adaptation-protocol.md docs/superpowers/specs/2026-08-03-ios-gallery-9050-boundary-design.md docs/superpowers/plans/2026-08-03-ios-remove-blocking-9050.md
```

Expected: no whitespace errors and only the approved startup-boundary changes.
