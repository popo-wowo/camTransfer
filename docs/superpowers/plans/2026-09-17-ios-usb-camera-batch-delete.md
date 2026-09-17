# iOS USB Camera Batch Delete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow one or more selected files in the iOS USB camera gallery to be deleted from the camera storage with truthful per-item results.

**Architecture:** Keep selection and result classification as pure, testable policies in `WiredCameraImportModels.swift`. Keep ImageCaptureCore ownership in `WiredCameraImportService`, issuing one native batch request. Adapt the existing UIKit action to confirm and render single, complete, partial, failed, and unknown outcomes.

**Tech Stack:** Swift 5, UIKit, ImageCaptureCore, XCTest, Xcode 26.

---

### Task 1: Batch Selection And Result Policies

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift:99`
- Modify: `ios/Runner/WiredCameraImportModels.swift:301`

- [ ] **Step 1: Write failing policy tests**

Replace the single-item expectations with tests that call `WiredCameraDeletePolicy.selectedItems(from:isDeleting:)`, accept multiple live selected items including imported items, and reject cached, empty, importing, and deleting states. Add result-classification tests around:

```swift
let result = WiredCameraDeleteResult.classify(
  requestedItemIDs: ["1", "2", "3"],
  successfulItemIDs: ["1"],
  failedItemIDs: ["2"]
)
XCTAssertEqual(result.successfulItemIDs, ["1"])
XCTAssertEqual(result.failedItemIDs, ["2"])
XCTAssertEqual(result.unknownItemIDs, ["3"])
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeletePolicyAllowsMultipleLiveSelectedFilesIncludingImported \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeleteResultClassifiesMissingItemsAsUnknown
```

Expected: FAIL because the batch policy and result type do not exist.

- [ ] **Step 3: Implement minimal pure policies**

Add `selectedItems(from:isDeleting:) -> [WiredCameraImportItem]` and a `WiredCameraDeleteResult` initializer/classifier. Preserve requested ordering while ensuring success takes precedence over failure and all unreported IDs become unknown.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: both tests pass.

### Task 2: Native Batch Delete Boundary

**Files:**
- Modify: `ios/Runner/WiredCameraImportService.swift:273`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing source-contract and mapper tests**

Add tests proving the service exposes `deleteFiles(for:completion:)`, passes the full file array to `requestDeleteFiles`, and maps native successful and failed handles back to requested IDs without treating a nil top-level error as proof for missing items.

- [ ] **Step 2: Run focused tests and verify RED**

Run the new tests with the same simulator destination. Expected: FAIL because `deleteFiles` and the mapping policy are missing.

- [ ] **Step 3: Implement one native batch request**

Resolve every requested ID before starting. Reject an empty request, a closed session, or any missing file. Call:

```swift
camera.requestDeleteFiles(files, deleteFailed: { failures in
  // diagnostic logging only
}, completion: { result, error in
  // map successful and failed camera items to IDs and classify unknown IDs
})
```

Return `Result<WiredCameraDeleteResult, Error>` only for request-level precondition failures; return the structured result for complete, partial, failed, and unknown native outcomes. Refresh the live catalog after completion and never retry automatically.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: policy and service contract tests pass.

### Task 3: Batch Delete UI

**Files:**
- Modify: `ios/Runner/WiredCameraImportViewController.swift:314`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing UI-policy tests**

Add tests for confirmation/result copy so multi-select reports selected, imported, success, failure, and unknown counts without depending on a live controller.

- [ ] **Step 2: Run focused tests and verify RED**

Expected: FAIL because the copy policy does not exist.

- [ ] **Step 3: Wire the UI to batch semantics**

Show the delete button for any non-empty deletable selection. Confirm one or many files with destructive wording. Call `deleteFiles`, remove only successful IDs from selection, retain failed/unknown selection, and show truthful completion text. Disable grid and competing operations while deletion is active.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: all USB delete tests pass.

### Task 4: Regression Verification

**Files:**
- Verify: `ios/Runner/WiredCameraImportModels.swift`
- Verify: `ios/Runner/WiredCameraImportService.swift`
- Verify: `ios/Runner/WiredCameraImportViewController.swift`
- Verify: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Run all wired-camera policy tests**

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeletePolicyAllowsMultipleLiveSelectedFilesIncludingImported \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeletePolicyRejectsCachedEmptyAndBusySelections \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeleteResultClassifiesMissingItemsAsUnknown \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraDeleteCopyDescribesBatchAndPartialResult \
  -only-testing:RunnerTests/RunnerTests/testWiredCameraThumbnailQueueDoesNotStartWhileDeletionIsInFlight
```

Expected: all selected tests pass.

- [ ] **Step 2: Build the Runner target**

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
```

Expected: `BUILD SUCCEEDED`, or any unrelated pre-existing WIP failure is recorded with its exact source location.

- [ ] **Step 3: Inspect the final diff**

Run `git diff --check` and confirm only the plan plus the four scoped USB delete files changed for this implementation. Record that physical deletion still requires USB camera acceptance with expendable test photos.
