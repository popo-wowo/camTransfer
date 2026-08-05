# iOS Gallery Entry Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the first wireless gallery Catalog a prepared, single, unfiltered transaction so X-M5 and existing X-T5 sessions can reach `GalleryReady` without same-session `0x2013` replay.

**Architecture:** Keep the existing `CameraSessionRuntime`, Catalog owner, actor/generation fences, and command lane. Move the existing legacy gallery preparation before the first Catalog request, replace the two-pass D604 initial Catalog with one validated base snapshot, and remove the StoreNotAvailable bootstrap replay. Do not change D212, D227 width, BLE lifetime, filtering, thumbnails, previews, or downloads in this plan.

**Tech Stack:** Swift 5, UIKit, Swift concurrency, XCTest, Xcode 16+, `xcodebuild`, PTP/IP vendor commands.

---

## Execution Status — 2026-08-05（更新）

- Production/TDD work for Tasks 1-5 is complete in the required worktree and branch.
- Task 6 automated verification and simulator/generic-device builds are complete. After the X-T5 slow-entry correction, the focused entry group passed 16/16. The full suite executed 1112 tests: 1110 passed; the two remaining Info.plist tests contain three unchanged location/background-mode assertion failures outside this Catalog refactor.
- The first X-T5 physical run exposed a blocking-entry regression in the pre-correction build: optional `0x9054/0x9055` primes against magic handle `0x10000001` consumed about 14.720 s and 7.465 s before Catalog. The base Catalog itself completed in about 0.572 s for 1813 handles. The correction skips only those two optional bootstrap primes while preserving D212 #2, D244, D22B, D212 #3, and the single base Catalog.
- Task 7 Step 1 is complete: the corrected signed iPhoneOS build was installed on iPhone `952611F0-557B-5C5F-BF1F-265474E9BC4B` as `com.camtransfer.app` at 2026-08-04 18:56. Automatic launch was denied only because the phone was locked. The X-M5, X-S20, corrected X-T5, and GFX100RF physical-camera matrices remain pending, so the physical Phase 1 Gate is **not** complete.
- All planned commit steps were intentionally skipped because the user explicitly required no commit and no push. The worktree remains dirty by design.
- The final design and evidence-audit documents contain the implementation result, test/build/install evidence, deviations, and remaining physical Gate.
- User-approved Phase 2 HEIF/video support is implemented: base GalleryReady remains first, ALL is enriched afterward with HEIF plus MOV/MP4, and Gallery exposes one `视频` filter. Quick Download remains JPG/RAW/HEIF-only.
- Phase 2 affected tests passed 59/59. After the first review closure, the focused group passed 13/13 and the entry/enrichment/download-routing group passed 19/19. A second review then found two actor-state races: stale filtered intent overwrite and stale Ready presentation fallback. Both were reproduced first with 2 tests / 5 expected RED assertions, fixed without changing owners or lifecycle boundaries, and passed 2/2; the final expanded Gallery/Catalog group passed 49/49.
- Fresh full RunnerTests executed 1136: 1134 test cases passed; only the same two Info.plist tests failed with three unchanged location/background-mode assertions. Fresh unsigned generic and signed device builds succeeded.
- As of 2026-08-04 23:31, the second-review-fixed signed package could not be installed in the latest retry because iPhone `952611F0-557B-5C5F-BF1F-265474E9BC4B` was `unavailable` and CoreDevice returned error 1011; the later D22B B package below supersedes that device-state observation.
- 2026-08-05 the later D22B B package superseded that install blocker: it built, installed, launched, and completed a fresh X-T5 first entry. Only the first-Catalog bootstrap D22B read was skipped; D212, D244, the one base snapshot, GalleryReady install gate, Runtime/Catalog ownership, generation fences, and CommandLane were unchanged.
- X-T5 A/B evidence: A waited 3687 ms for D22B; B reduced the pre-Catalog prepare/mainline plus first Catalog interval from about 4.377 s to 0.637 s. Both runs produced the same initial 1813-handle D621 payload. B also completed HEIF, MOV, MP4 and JPG queries without `0x2013`, `0x2019`, StoreNotAvailable, bootstrap replay, PTP route/refused/INIT errors, or pairing lookup errors.
- Latest automated evidence is 4/4 D22B contract tests and 17/17 expanded entry/connection/GalleryReady tests. Full RunnerTests executed 1140: 1138 passed; the same two Info.plist tests failed with three unchanged assertions. Result bundles are under `/private/tmp/camtransfer-d22b-*-20260805-01.xcresult`.
- The 13:54 disconnect was confirmed by the user as camera battery depletion and is excluded from D22B regression attribution. X-T5 re-entry/reconnect plus X-M5, X-S20, and GFX100RF remain physical Gates. The plan does not claim that all historical BLE/Wi-Fi/PTP connection failures are fixed.

---

## Source of Truth and Scope

- Final design: `docs/ios-gallery-entry-final-solution-20260804.md`
- Evidence audit: `docs/ios-xapp-gallery-full-chain-difference-audit-20260804.md`
- Implementation worktree: `/Users/g01d-01-1224/.config/superpowers/worktrees/camtransfer/codex/ios-red-app-info-handshake`
- Active implementation branch: `codex/ios-gallery-entry-catalog-refactor`
- Preserve existing dirty WIP in:
  - `docs/camera-vendor-adaptation-protocol.md`
  - `ios/Runner/CameraVendorPtpSession.swift`
  - `ios/RunnerTests/RunnerTests.swift`

This plan implements only M1, M2, M3, M5 regression coverage, M6, and M10 preservation.

The implementation worker must stay in the exact worktree and branch above. It must not switch, reset, clean, stash, or recreate the worktree, because the branch intentionally contains the uncommitted `9050` and App-identity handshake baseline that this refactor builds on.

This plan must not implement:

- M4 post-ready `9050` UI or descriptor storage.
- M7 D227 payload width changes.
- M8 D212 removal.
- BLE disconnect/keep-alive changes.
- D244 writes or automatic card-slot switching.
- HEIF enrichment, thumbnail, HD preview, original download, or background changes.

## File Map

- Modify `ios/Runner/CameraVendorPtpSession.swift`
  - Expose one initial-gallery preparation method.
  - Remove StoreNotAvailable bootstrap recovery method.
  - Replace the initial D604 baseline/expanded Catalog with one base snapshot.
- Modify `ios/Runner/CameraVendorRealtimeGalleryService.swift`
  - Prepare before the first Catalog inside the existing exclusive session mutation.
  - Remove same-session `0x2013` replay.
- Modify `ios/Runner/CameraVendorCatalogPolicy.swift`
  - Remove the obsolete initial Catalog bootstrap recovery policy.
  - Preserve D212 and all post-entry filter policies.
- Modify `ios/RunnerTests/RunnerTests.swift`
  - Define the new wire contract before implementation.
  - Replace tests that currently require failure-only bootstrap and D604 initial Catalog behavior.
  - Preserve GalleryReady, owner, generation, and downstream regression coverage.

---

### Task 1: Freeze the New Initial Catalog Contract with Failing Tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift:4470`
- Modify: `ios/RunnerTests/RunnerTests.swift:7200`
- Modify: `ios/RunnerTests/RunnerTests.swift:16900`

- [x] **Step 1: Replace the StoreNotAvailable recovery policy test**

Replace `testInitialCatalogBootstrapRecoveryIsLimitedToStoreNotAvailable()` with:

```swift
func testInitialCatalogDoesNotExposeStoreNotAvailableBootstrapRecoveryPolicy() throws {
  let policySource = try runnerSource("CameraVendorCatalogPolicy.swift")
  let serviceSource = try runnerSource("CameraVendorRealtimeGalleryService.swift")
  let sessionSource = try runnerSource("CameraVendorPtpSession.swift")

  XCTAssertFalse(policySource.contains("CameraVendorInitialCatalogBootstrapRecoveryPolicy"))
  XCTAssertFalse(serviceSource.contains("recoverInitialCameraCatalogAfterStoreNotAvailable"))
  XCTAssertFalse(sessionSource.contains("recoverInitialCameraCatalogAfterStoreNotAvailable"))
  XCTAssertFalse(sessionSource.contains("PTP_INITIAL_CAMERA_CATALOG_BOOTSTRAP_RECOVERY"))
}
```

- [x] **Step 2: Replace the failure-only bootstrap owner test**

Replace `testLegacyPtpLoadGalleryBootstrapHasOneOwnerBeforeCatalogRuntime()` with:

```swift
func testInitialGalleryPreparationRunsBeforeSingleCatalogSnapshot() throws {
  let sessionSource = try runnerSource("CameraVendorPtpSession.swift")
  let serviceSource = try runnerSource("CameraVendorRealtimeGalleryService.swift")

  XCTAssertTrue(sessionSource.contains("func prepareCameraVendorInitialGalleryAccessIfNeeded()"))

  let fetchStart = try XCTUnwrap(
    serviceSource.range(
      of: "func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {"
    )?.lowerBound
  )
  let fetchEnd = try XCTUnwrap(
    serviceSource.range(
      of: "func fetchCameraCatalog(query:",
      range: fetchStart..<serviceSource.endIndex
    )?.lowerBound
  )
  let fetchBody = String(serviceSource[fetchStart..<fetchEnd])
  let prepare = try XCTUnwrap(
    fetchBody.range(of: "self.session.prepareCameraVendorInitialGalleryAccessIfNeeded()")
  )
  let catalog = try XCTUnwrap(
    fetchBody.range(of: "self.session.cameraVendorInitialCatalogSnapshot()")
  )

  XCTAssertLessThan(prepare.lowerBound, catalog.lowerBound)
  XCTAssertFalse(fetchBody.contains("recoverInitialCameraCatalogAfterStoreNotAvailable"))
  XCTAssertFalse(fetchBody.contains("CameraVendorInitialCatalogBootstrapRecoveryPolicy"))
  XCTAssertEqual(
    fetchBody.components(separatedBy: "self.session.cameraVendorInitialCatalogSnapshot()").count - 1,
    1
  )
}
```

- [x] **Step 3: Replace the D604 initial Catalog test**

Replace `testCameraVendorInitialCatalogUsesCapturedUnfilteredWireSequence()` with:

```swift
func testCameraVendorInitialCatalogUsesOneBaseSnapshotWithoutSearchModeMutation() throws {
  let source = try runnerSource("CameraVendorPtpSession.swift")
  let start = try XCTUnwrap(
    source.range(of: "func cameraVendorInitialCatalogSnapshot()")?.lowerBound
  )
  let end = try XCTUnwrap(
    source.range(
      of: "func cameraVendorCatalogSnapshot(",
      range: start..<source.endIndex
    )?.lowerBound
  )
  let body = String(source[start..<end])

  XCTAssertEqual(
    body.components(separatedBy: "requestCameraVendorSpecifiedObjectSnapshot(").count - 1,
    1
  )
  XCTAssertTrue(body.contains("stage: \"initial-camera-catalog\""))
  XCTAssertTrue(body.contains("CameraVendorCatalogSnapshotValidationPolicy.isPublishable"))
  XCTAssertTrue(body.contains("CameraVendorCatalogPlaceholderPolicy.placeholderItems"))
  XCTAssertFalse(body.contains("cameraVendorSetSearchModeAll"))
  XCTAssertFalse(body.contains("initial-camera-catalog-baseline"))
  XCTAssertFalse(body.contains("CameraVendorSearchModeAllPayload"))
  XCTAssertFalse(body.contains("expandedStillFormatHints"))
  XCTAssertFalse(body.contains("PTP_INITIAL_CATALOG_BASELINE"))
  XCTAssertFalse(body.contains("PTP_INITIAL_CATALOG_EXPANDED"))
}
```

- [x] **Step 4: Run the three tests and confirm they fail for the intended reasons**

Run from the isolated worktree root:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testInitialCatalogDoesNotExposeStoreNotAvailableBootstrapRecoveryPolicy \
  -only-testing:RunnerTests/RunnerTests/testInitialGalleryPreparationRunsBeforeSingleCatalogSnapshot \
  -only-testing:RunnerTests/RunnerTests/testCameraVendorInitialCatalogUsesOneBaseSnapshotWithoutSearchModeMutation
```

Expected: FAIL because the recovery policy and method still exist, the service prepares only after failure, and the initial Catalog still sends D604 payloads.

- [x] **Step 5: Disposition the planned RED-test commit — intentionally skipped; no commit or push**

```bash
git add ios/RunnerTests/RunnerTests.swift
git commit -m "test(ios): define minimal initial gallery catalog contract"
```

---

### Task 2: Move Existing Legacy Preparation Before the First Catalog

**Files:**
- Modify: `ios/Runner/CameraVendorPtpSession.swift:602-655`
- Modify: `ios/Runner/CameraVendorRealtimeGalleryService.swift:507-520`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Rename the public preparation boundary without rewriting private bootstrap behavior**

Keep `private func prepareCameraVendorLegacyGalleryLoad()` unchanged. Replace the public wrapper and recovery method with:

```swift
func prepareCameraVendorInitialGalleryAccessIfNeeded() throws {
  let transportLabel = operationTransport == .cameraVendorLegacy
    ? "cameraVendorLegacy"
    : "standardPtpIp"
  report("[OBS] PTP_INITIAL_GALLERY_ACCESS_PREPARE_BEGIN transport=\(transportLabel)")
  defer {
    report("[OBS] PTP_INITIAL_GALLERY_ACCESS_PREPARE_END transport=\(transportLabel)")
  }
  guard operationTransport == .cameraVendorLegacy else { return }
  try prepareCameraVendorLegacyGalleryLoad()
}
```

Delete:

```swift
func prepareCameraVendorLegacyGalleryLoadIfNeeded() throws
func recoverInitialCameraCatalogAfterStoreNotAvailable() throws
```

Do not add `9050` back to `prepareCameraVendorLegacyGalleryLoad()`.

- [x] **Step 2: Prepare before the first Catalog inside the existing exclusive mutation**

Replace `CameraVendorRealtimeGalleryService.fetchInitialCameraCatalog()` with:

```swift
func fetchInitialCameraCatalog() async throws -> CameraVendorCatalogSnapshot {
  try await commandLane.runExclusiveSessionMutation {
    try self.session.prepareCameraVendorInitialGalleryAccessIfNeeded()
    return try self.session.cameraVendorInitialCatalogSnapshot()
  }
}
```

This ordering is the implementation of M1. Do not move preparation into `CameraVendorGalleryMainlineSessionLoader`; the Catalog Runtime remains the only owner.

- [x] **Step 3: Run the preparation-order test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testInitialGalleryPreparationRunsBeforeSingleCatalogSnapshot
```

Expected: PASS.

- [x] **Step 4: Verify the scope boundary in the diff**

Run:

```bash
git diff -- ios/Runner/CameraVendorPtpSession.swift ios/Runner/CameraVendorRealtimeGalleryService.swift
```

Expected:

- Existing private D212/D244/D22B bootstrap remains.
- Optional magic-handle `0x9054/0x9055` bootstrap primes are skipped before the first Catalog; post-ready requests using real object handles remain unchanged.
- `PTP_GALLERY_BOOTSTRAP_9050_SKIPPED` remains.
- No D227 encoding change.
- No BLE or loader change.

- [x] **Step 5: Disposition the planned preparation-order commit — intentionally skipped; no commit or push**

```bash
git add ios/Runner/CameraVendorPtpSession.swift ios/Runner/CameraVendorRealtimeGalleryService.swift
git commit -m "fix(ios): prepare gallery state before initial catalog"
```

---

### Task 3: Replace the Two-Pass D604 Initial Catalog with One Base Snapshot

**Files:**
- Modify: `ios/Runner/CameraVendorPtpSession.swift:887-969`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Replace `cameraVendorInitialCatalogSnapshot()` with a single base snapshot**

Use this implementation shape while preserving the existing saved-state/defer pattern:

```swift
func cameraVendorInitialCatalogSnapshot() throws -> CameraVendorCatalogSnapshot {
  let previousHandles = cameraVendorSpecifiedObjectHandles
  let previousDateGroups = cameraVendorSpecifiedObjectDateGroups
  let previousHandlesByFormatMask = cameraVendorSpecifiedObjectHandlesByFormatMask

  defer {
    cameraVendorSpecifiedObjectHandles = previousHandles
    cameraVendorSpecifiedObjectDateGroups = previousDateGroups
    cameraVendorSpecifiedObjectHandlesByFormatMask = previousHandlesByFormatMask
  }

  report("[OBS] PTP_INITIAL_CAMERA_CATALOG_BEGIN mode=base")
  let snapshot = try requestCameraVendorSpecifiedObjectSnapshot(
    stage: "initial-camera-catalog",
    allowsEmptyRetry: false
  )

  guard CameraVendorCatalogSnapshotValidationPolicy.isPublishable(
    declaredCount: snapshot.declaredCount,
    dateGroups: snapshot.dateGroups,
    orderedHandles: snapshot.handles
  ) else {
    throw NSError(
      domain: "CameraVendorPtpSession",
      code: NSURLErrorCannotParseResponse,
      userInfo: [NSLocalizedDescriptionKey: "相机返回的初始目录计数、日期组或句柄不一致"]
    )
  }

  let catalog = CameraVendorCatalogSnapshot(
    dateGroups: snapshot.dateGroups,
    orderedHandles: snapshot.handles,
    items: CameraVendorCatalogPlaceholderPolicy.placeholderItems(
      from: snapshot.handles,
      dateGroups: snapshot.dateGroups
    )
  )
  report(
    "[OBS] PTP_INITIAL_CAMERA_CATALOG_END mode=base " +
    "groups=\(catalog.dateGroups.count) handles=\(catalog.orderedHandles.count)"
  )
  return catalog
}
```

Delete from this method only:

- `CameraVendorSearchModeAllPayload.objectFormatMaskPayload(...)`.
- Both `cameraVendorSetSearchModeAll` writes.
- SearchMode clear/reset payload.
- `initial-camera-catalog-baseline` snapshot.
- `PTP_INITIAL_CATALOG_BASELINE` and `PTP_INITIAL_CATALOG_EXPANDED` logs.
- `expandedStillFormatHints(...)` use.

Do not delete the SearchMode/query implementation used by `cameraVendorCatalogSnapshot(query:)`.

- [x] **Step 2: Run the base snapshot contract test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testCameraVendorInitialCatalogUsesOneBaseSnapshotWithoutSearchModeMutation
```

Expected: PASS.

- [x] **Step 3: Run existing initial Catalog consumers**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testRuntimeCatalogSourceInitialLoadDoesNotUseFilteredQueryTransport \
  -only-testing:RunnerTests/RunnerTests/testRuntimeCatalogSourceAllFormatsTodayUsesExpandedInitialCatalog \
  -only-testing:RunnerTests/RunnerTests/testRuntimeCatalogSourceAllFormatsSpecificDayUsesExpandedInitialCatalog
```

Expected:

- Tests compile and execute.
- If the two test names containing `ExpandedInitialCatalog` fail only because the name/expectation encodes the old implementation, rename them to `BaseInitialCatalog` without changing the expected one-request behavior.
- `initialCatalogRequestCount` remains `1`.

- [x] **Step 4: Search for forbidden initial-entry behavior**

```bash
rg -n 'initial-camera-catalog-baseline|PTP_INITIAL_CATALOG_BASELINE|PTP_INITIAL_CATALOG_EXPANDED' ios/Runner ios/RunnerTests
```

Expected: no production references. Historical docs may still contain the terms.

- [x] **Step 5: Disposition the planned base-Catalog commit — intentionally skipped; no commit or push**

```bash
git add ios/Runner/CameraVendorPtpSession.swift ios/RunnerTests/RunnerTests.swift
git commit -m "fix(ios): load one unfiltered initial gallery catalog"
```

---

### Task 4: Remove Same-Session StoreNotAvailable Bootstrap Replay

**Files:**
- Modify: `ios/Runner/CameraVendorCatalogPolicy.swift:7-16`
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Verify: `ios/Runner/CameraVendorPtpSession.swift`
- Verify: `ios/Runner/CameraVendorRealtimeGalleryService.swift`

- [x] **Step 1: Delete the obsolete policy**

Delete:

```swift
enum CameraVendorInitialCatalogBootstrapRecoveryPolicy {
  static let storeNotAvailableResponseCode = 0x2013

  static func shouldRecover(after error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == "CameraVendorPtpSession"
      && nsError.code == storeNotAvailableResponseCode
  }
}
```

Do not change `CameraVendorSpecifiedObjectEmptySnapshotRecoveryPolicy`; empty-list retry is a separate behavior and is not the logged `0x2013` replay.

- [x] **Step 2: Run the removal contract test**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testInitialCatalogDoesNotExposeStoreNotAvailableBootstrapRecoveryPolicy
```

Expected: PASS.

- [x] **Step 3: Verify there are no remaining same-session recovery references**

```bash
rg -n 'CameraVendorInitialCatalogBootstrapRecoveryPolicy|recoverInitialCameraCatalogAfterStoreNotAvailable|PTP_INITIAL_CAMERA_CATALOG_BOOTSTRAP_RECOVERY' ios/Runner ios/RunnerTests
```

Expected: no matches.

- [x] **Step 4: Disposition the planned recovery-removal commit — intentionally skipped; no commit or push**

```bash
git add ios/Runner/CameraVendorCatalogPolicy.swift ios/RunnerTests/RunnerTests.swift
git commit -m "fix(ios): stop replaying failed initial catalog sessions"
```

---

### Task 5: Prove GalleryReady and Ownership Semantics Did Not Regress

**Files:**
- Verify: `ios/Runner/CameraSessionRuntime.swift`
- Verify: `ios/Runner/CameraSessionTransferExecutor.swift`
- Verify: `ios/Runner/CameraVendorGalleryMainlineSessionLoader.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [x] **Step 1: Run the GalleryReady gate tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeDoesNotPublishGalleryReadyBeforeInitialCatalogInstalls \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimePublishesGalleryReadyAfterInitialCatalogInstalls
```

Expected: both PASS without modifying `CameraSessionRuntime`.

- [x] **Step 2: Run Catalog owner and initial-load tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testInitialGalleryPreparationRunsBeforeSingleCatalogSnapshot \
  -only-testing:RunnerTests/RunnerTests/testRuntimeCatalogSourceInitialLoadDoesNotUseFilteredQueryTransport \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeJoinsSupersededCatalogBeforeStartingReplacement
```

Expected: all PASS and only one initial Catalog owner remains.

- [x] **Step 3: Confirm no out-of-scope production files changed**

```bash
git diff --name-only
```

Expected production files are limited to:

```text
ios/Runner/CameraVendorPtpSession.swift
ios/Runner/CameraVendorRealtimeGalleryService.swift
ios/Runner/CameraVendorCatalogPolicy.swift
```

`ios/RunnerTests/RunnerTests.swift` and documentation changes are also expected. Stop and review if BLE, Runtime, loader, thumbnail, preview, download, or background files changed.

- [x] **Step 4: Disposition the planned test-name cleanup commit — intentionally skipped; no commit or push**

If Task 3 renamed `ExpandedInitialCatalog` tests to `BaseInitialCatalog`, commit only those test changes:

```bash
git add ios/RunnerTests/RunnerTests.swift
git commit -m "test(ios): preserve gallery ready and catalog ownership gates"
```

If no cleanup was needed, do not create an empty commit.

---

### Task 6: Run Focused, Full, and Build Verification

**Files:**
- Verify: all Phase 1 files

- [x] **Step 1: Run the complete focused entry group**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests/RunnerTests/testInitialCatalogDoesNotExposeStoreNotAvailableBootstrapRecoveryPolicy \
  -only-testing:RunnerTests/RunnerTests/testInitialGalleryPreparationRunsBeforeSingleCatalogSnapshot \
  -only-testing:RunnerTests/RunnerTests/testCameraVendorInitialCatalogUsesOneBaseSnapshotWithoutSearchModeMutation \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimeDoesNotPublishGalleryReadyBeforeInitialCatalogInstalls \
  -only-testing:RunnerTests/RunnerTests/testCameraSessionRuntimePublishesGalleryReadyAfterInitialCatalogInstalls \
  -only-testing:RunnerTests/RunnerTests/testRuntimeCatalogSourceInitialLoadDoesNotUseFilteredQueryTransport
```

Expected: six tests execute and pass.

- [x] **Step 2: Run full RunnerTests and record the baseline comparison**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:RunnerTests
```

Expected: no new failure names compared with the pre-implementation worktree baseline. Record executed count, failed count, and unique failure names in the implementation handoff.

- [x] **Step 3: Build for simulator**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4'
```

Expected: `BUILD SUCCEEDED`.

- [x] **Step 4: Build the generic iOS device target**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [x] **Step 5: Run diff hygiene checks**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and no unrelated files staged or modified by this implementation.

---

### Task 7: Execute the Physical-Camera Gate Before Any Phase 2 Work

**Files:**
- Update evidence: `docs/ios-gallery-entry-final-solution-20260804.md`
- Update evidence: `docs/ios-xapp-gallery-full-chain-difference-audit-20260804.md`

- [x] **Step 1: Build and install the exact Phase 1 working tree on the test iPhone**

Use the repository's current signed device build/install path. Record:

```text
git HEAD
worktree path
app build identifier
iPhone identifier
camera model
camera firmware
```

Expected: the installed app revision matches the tested source revision.

Current evidence, 2026-08-04:

- The signed corrected build succeeded for `com.camtransfer.app` with team `27C9C4H26H`.
- App bundle: `/Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-dwsgnyalvqkhopglgncegafkfthg/Build/Products/Debug-iphoneos/Runner.app`.
- Installation succeeded at 18:56 on iPhone `952611F0-557B-5C5F-BF1F-265474E9BC4B`; CoreDevice reported bundle ID `com.camtransfer.app` and installation URL `/private/var/containers/Bundle/Application/B78C9012-8E1C-4231-AE73-93385E46C570/Runner.app/`.
- Automatic launch was denied because the phone was locked; unlock/manual launch and the corrected X-T5 timing run remain pending.
- The earlier X-T5 run is regression/root-cause evidence only; it is not acceptance evidence for the corrected source.

- [ ] **Step 2: Run the X-M5 matrix**

Execute separately and save a fresh diagnostic log for each:

```text
XM5-1: camera/app clean start -> enter gallery
XM5-2: exit gallery normally -> enter again
XM5-3: force-kill app during/after gallery -> relaunch -> enter again
```

Expected in every successful run:

```text
PTP_INITIAL_GALLERY_ACCESS_PREPARE_END before PTP_INITIAL_CAMERA_CATALOG_BEGIN
legacy route additionally contains PTP_GALLERY_BOOTSTRAP_COMPLETE
no D604=31 or D604=2 before first 9053
one PTP_INITIAL_CAMERA_CATALOG_9053
one PTP_INITIAL_CAMERA_CATALOG_D620
one PTP_INITIAL_CAMERA_CATALOG_D621
PTP_INITIAL_CAMERA_CATALOG_END mode=base
GalleryReady only after snapshot installation
```

- [ ] **Step 3: Run the X-T5 regression matrix**

Execute:

```text
XT5-1: enter gallery using the current slot
XT5-2: exit normally -> enter again
```

Do not add automatic D244 slot switching for this gate.

Expected: both runs reach GalleryReady with the same single base Catalog contract.

The corrected run must additionally prove:

```text
PTP_GALLERY_BOOTSTRAP_9054_SKIPPED
PTP_GALLERY_BOOTSTRAP_9055_SKIPPED
no actual gallery-bootstrap 0x9054/0x9055 request for handle 0x10000001
prepare duration drops substantially from the pre-correction 26.053 s
D22B, first 9053/D620/D621, snapshot installation, and GalleryReady still succeed
```

- [ ] **Step 4: Apply the stop rule if first 9053 still returns 0x2013**

If X-M5 still returns `0x2013` after prepare-before-Catalog and no D604:

- Stop Phase 1 expansion.
- Do not change D212, D227, BLE lifetime, or 9050 in the same revision.
- Record the exact fresh log boundary.
- Start a separate single-variable evidence plan for M7, M8, 9050, or BLE as justified by the new log.

- [ ] **Step 5: Record Gate 1 results in both design documents**

Add a dated evidence block containing:

```text
revision
device/camera matrix
log paths
first 9053 response
D620/D621 counts
GalleryReady result
re-entry result
known regressions
```

- [ ] **Step 6: Commit only the evidence update after the gate**

```bash
git add docs/ios-gallery-entry-final-solution-20260804.md \
  docs/ios-xapp-gallery-full-chain-difference-audit-20260804.md
git commit -m "docs(ios): record gallery entry physical-camera gate"
```

---

## Completion Criteria

The production implementation and automated verification are complete. The physical Phase 1 Gate remains incomplete until the unchecked criteria below are proven with fresh camera logs.

- [x] The three new contract tests pass.
- [x] Existing GalleryReady and Catalog owner tests pass.
- [x] Full RunnerTests show no new unrelated failures versus baseline.
- [x] Simulator and generic device builds succeed.
- [x] The corrected signed working tree is installed on the test iPhone.
- [ ] X-M5 clean, re-entry, and force-kill scenarios reach GalleryReady.
- [ ] X-T5 entry and re-entry remain successful.
- [ ] Fresh logs show no D604 before the first `9053`.
- [ ] Fresh logs show no same-session StoreNotAvailable bootstrap replay.

Do not begin Phase 2 post-ready enrichment until all completion criteria are met.

---

## 用户批准的 Phase 2 范围扩展（2026-08-04）

用户在 corrected X-T5 构建确认入口速度恢复后，进一步确认“全部”只显示 1813 项、HEIF 筛选显示 2435 项，并明确批准同时支持 HEIF 与视频筛选。因此本节覆盖上面的 Phase 2 暂停条件；未被本节点名的入口、传输和生命周期边界继续冻结。

**Goal:** 保持首次 base Catalog 与 GalleryReady 快速链不变，在 Ready 后补齐 ALL 的 HEIF、MOV、MP4 成员，并提供单一“视频（MOV + MP4）”筛选。

**Architecture:** `CameraGalleryCatalogRuntime` 的首次 generation 只安装 base snapshot。`CameraGallerySession` 在首次 Ready 后启动可取消的后置 ALL enrichment；`CameraCatalogQueryEngine` 复用首次 base，并依次读取 HEIF、MOV、MP4 subtract-baseline membership，去重后作为新 generation 原子安装。用户筛选或 session/generation 失效会取消旧 enrichment，旧结果不得发布。

**Scope remains frozen:** 不恢复首次 Catalog 前 D604，不恢复 magic-handle 9054/9055，不修改 D212、D227、D244、BLE/Wi-Fi/PTP INIT/retry、缩略图、HD Preview、下载和后台行为。视频仅扩展目录成员与相册筛选，不扩展视频预览或下载。

### Task 8: 先冻结 post-ready ALL 与视频 wire contract

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [x] 新增失败测试：首次 Ready 只包含 base，且 HEIF/MOV/MP4 enrichment 未完成时已经可见。
- [x] 新增失败测试：ALL 最终合并 base + HEIF + MOV + MP4，按全局顺序去重。
- [x] 新增失败测试：视频筛选只合并 MOV + MP4，HEIF 不混入视频集合。
- [x] 新增失败测试：用户切换筛选或 generation 失效后，迟到的 ALL enrichment 不得覆盖当前目录。
- [x] 修改旧 UI 契约测试：相册格式 chips 包含 `video/视频`；快速下载设置继续不暴露视频，避免扩大下载范围。
- [x] 运行最聚焦的 RunnerTests，确认测试因缺少新行为而失败，不接受编译错误或测试装配错误作为 RED。

### Task 9: 最小实现 post-ready enrichment 与视频筛选

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraMediaFilterRule.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogModels.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySources.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraFilterEngine.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraCatalogQueryEngine.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Modify: `ios/Runner/CameraSessionTransferExecutor.swift`
- Modify: `ios/Runner/CameraAutoDownloadRule.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`

- [x] 增加产品格式 `.video`，相册 chip 显示“视频”，快速下载 UI 保持 JPG/RAW/HEIF。
- [x] 将物理 subtract-baseline 格式显式建模为 HEIF、MOV、MP4；MOV 使用 `0x0004`，MP4 使用 `0x0008`。
- [x] 首次查询使用独立 base cache，不把 base 冒充 expanded ALL cache。
- [x] ALL 查询合并首次 base 与 HEIF/MOV/MP4 membership；视频查询只合并 MOV/MP4。
- [x] 首次 Ready 后启动不发布 loading 的 enrichment；查询期间保留 base 目录，安装前再次校验 session/generation/intent。
- [x] enrichment 非终端失败保留 base Ready；确定的 transport loss 继续走现有 Runtime 终止证据路径。
- [x] 运行聚焦测试至 GREEN，再运行受影响 Catalog/Session/UI 测试组。

### Task 10: 完整验证、安装和文档回写

- [x] 运行完整 `RunnerTests`，区分新增回归与既有 Info.plist 基线失败。
- [x] 运行 generic iOS build 与 signed device build。
- [ ] 安装到 iPhone `952611F0-557B-5C5F-BF1F-265474E9BC4B`，不提交、不 push。
- [ ] 使用 fresh X-T5 日志验证：首次 base Ready 不等待 D604；Ready 后出现 HEIF、MOV、MP4 enrichment；ALL、HEIF、视频三个视图成员数与集合关系正确。
- [x] 回写最终方案、差异审计和本计划的实际结果；无其他相机时保留 X-M5、X-S20、GFX100RF 真机 Gate。

### Phase 2 实际验证记录

```text
TDD / focused:
- HEIF + video query/source core: 3/3
- base-before-enrichment + late-generation fence: 2/2
- post-ready retryable/terminal failure: 2/2
- quick-download all excludes video: RED 2 tests / 4 assertions, GREEN 2/2
- affected Catalog/Session/UI/entry group: 59/59
- downstream admission tests adjusted for the intentional base->enriched generation change: 7/7
- review closure focused group: 13/13
  - production source adapter preserves terminal catalog transport evidence: 2/2
  - still-only selection/download/photo-preview/HD-preview/Quick Download gates: 5/5
  - local sort projection survives enrichment while membership changes still reject late results: 2/2
- final entry/enrichment/download-routing focused group: 19/19
- second review concurrency closure: RED 2 tests / 5 assertions, GREEN 2/2
- expanded Gallery/Catalog regression group after final fixes: 49/49

Full RunnerTests:
- 1136 executed
- 1134 passed test cases
- 2 existing Info.plist tests failed with 3 unchanged assertions
- expanded xcresult: /Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-dwsgnyalvqkhopglgncegafkfthg/Logs/Test/Test-Runner-2026.08.04_23-29-18-+0800.xcresult
- xcresult: /Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-dwsgnyalvqkhopglgncegafkfthg/Logs/Test/Test-Runner-2026.08.04_23-29-35-+0800.xcresult

Build:
- generic/platform=iOS with CODE_SIGNING_ALLOWED=NO: BUILD SUCCEEDED
- signed generic/platform=iOS: BUILD SUCCEEDED
- bundle: com.camtransfer.app 1.0 (6), TeamIdentifier 27C9C4H26H
- fresh builds completed at 2026-08-04 23:30
- signed app: /Users/g01d-01-1224/Library/Developer/Xcode/DerivedData/Runner-dwsgnyalvqkhopglgncegafkfthg/Build/Products/Debug-iphoneos/Runner.app

Install / device:
- second-review-fixed signed package install retried on 952611F0-557B-5C5F-BF1F-265474E9BC4B at 2026-08-04 23:31
- blocked because CoreDevice reported the iPhone unavailable and returned error 1011
- no fresh Phase 2 X-T5 log was collected from this build
```

Implementation deviations:

- Because `.all` is shared by Gallery and Quick Download, adding video to Gallery ALL would otherwise make Quick Download's “全部格式” include video. `CameraAutoDownloadRule.catalogFilter` maps Quick Download ALL to JPG/RAW/HEIF, removes video from mixed rules, and rejects video-only before Catalog query/submission.
- The video-only rejection follows the existing Quick Download completion policy: keep-connected returns to Gallery, disconnect-after-download terminates transport and returns Home; neither path submits a download.
- Review found that new video placeholders could bypass the previous string-only `formatLabel != "Video"` gate. A shared `CameraVendorGalleryDownloadPolicy.isSupportedStill` now blocks video hints, labels and filenames from selection, photo/HD preview and original download. This does not implement video transfer or preview.
- Review found that source-adapter catch blocks downgraded raw socket failures and that full-intent equality discarded enrichment after local date/sort changes. The adapter now preserves `.catalog` terminal evidence, while the enrichment fence compares membership identity and installs with the latest local projection. The single QueryEngine, Catalog owner and actor/generation fence remain unchanged.
- Second review found that a normal filtered transaction could overwrite a newer same-membership local intent when its old query completed. Filtered install now preserves the current intent whenever camera membership is unchanged; a real membership switch still uses the existing generation/pending fence.
- Second review also found that a superseded retryable failure could restore a presentation captured before incremental thumbnail/details updates. The fallback still stores only a stable Ready anchor, but restoration now rebuilds the presentation from the current Repository, preserving completed thumbnail, ObjectInfo, orientation and format details without adding a second Repository or Catalog owner.
