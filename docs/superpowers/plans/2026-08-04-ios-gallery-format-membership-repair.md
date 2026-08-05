# iOS Gallery Format Membership Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair HEIF/MOV/MP4 filter membership and prevent a non-terminal filter failure from replacing a valid Gallery Catalog with an empty presentation.

**Architecture:** Preserve the existing Runtime/Catalog ownership graph. Keep HEIF's current compatibility subtraction isolated to HEIF, route MOV and MP4 through direct validated Catalog transactions, and restore the previous Ready presentation when a filtered transaction fails without proving transport loss.

**Tech Stack:** Swift, XCTest, Xcode `RunnerTests`, `xcodebuild`, CoreDevice `devicectl`.

---

### Task 1: Lock the Physical Format Contracts with Failing Tests

**Files:**
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Replace the shared video-subtraction contract with format-specific assertions**

Add tests that require:

```swift
XCTAssertEqual(source.membershipPolicy(for: .heif), .subtractInitialBase)
XCTAssertEqual(source.membershipPolicy(for: .mov), .direct)
XCTAssertEqual(source.membershipPolicy(for: .mp4), .direct)
```

Use the production policy API introduced in Task 2; the RED test initially
fails because MOV and MP4 still use `.subtractBaseline`.

- [ ] **Step 2: Add a source integration regression for the device response shape**

Construct a transport spy with an exact MOV result and an empty MP4 result:

```swift
transport.catalogItemsByLabel = [
  "format-mov": [galleryItem(handle: 15, formatLabel: "MOV")],
  "format-mp4": [],
]
let snapshot = try await source.loadVideoCatalog()
XCTAssertEqual(transport.requestedCatalogLabels, ["format-mov", "format-mp4"])
XCTAssertEqual(snapshot.items.map(\.handle), [15])
```

- [ ] **Step 3: Add a runtime failure-preservation regression**

Start the runtime with a Ready base snapshot, make the next explicit filtered
query throw a non-terminal `CameraGalleryCatalogTransactionFailure`, and assert:

```swift
XCTAssertEqual(finalPresentation.items.map(\.handle), baseHandles)
XCTAssertTrue(finalPresentation.isReady)
XCTAssertFalse(publishedPresentations.contains { $0.items.isEmpty && !$0.isLoading })
```

- [ ] **Step 4: Add an ALL-equivalent restored-intent enrichment regression**

Persist an ALL membership intent with a non-default local sort or download
projection and assert that post-ready HEIF and video requests still start.

- [ ] **Step 5: Run the focused RED tests**

Run the existing focused `xcodebuild test` command with `-only-testing` entries
for the new test names. Expected: the format-policy and failure-preservation
tests fail for the intended production behavior; no compile errors.

### Task 2: Isolate HEIF Compatibility from Direct Video Queries

**Files:**
- Modify: `ios/Runner/CameraVendorCatalogPolicy.swift`
- Modify: `ios/Runner/CameraVendorPtpSession.swift`
- Modify: `ios/Runner/CameraSessionTransferExecutor.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySources.swift`

- [ ] **Step 1: Introduce a typed physical membership strategy**

Define a small policy that distinguishes:

```swift
enum CameraVendorPhysicalFormatMembershipPolicy: Equatable {
  case subtractInitialBase
  case direct
}
```

Map HEIF to `.subtractInitialBase`; map JPG, RAW, MOV, and MP4 to `.direct`.

- [ ] **Step 2: Route direct queries through the existing validated transaction**

Use `cameraVendorDirectCatalogSnapshot(query:)` for MOV and MP4 so declared
count, date-group totals, uniqueness, and order remain validated. Do not apply
`CameraVendorSubtractBaselineValidationPolicy` to either video format.

- [ ] **Step 3: Keep HEIF subtraction isolated**

Retain the current base/format structural validation and strict superset
requirement only for HEIF. Rename comments and APIs so they no longer claim the
strategy applies to Video.

- [ ] **Step 4: Execute and merge MOV and MP4**

Keep the two physical requests separate, preserve request order, deduplicate
their product `.video` union, and ensure an exact MOV snapshot reaches the MP4
request instead of throwing at the HEIF validator.

- [ ] **Step 5: Run the Task 1 focused tests**

Expected: format-policy and MOV/MP4 source tests pass; runtime failure test still
fails until Task 3.

### Task 3: Preserve the Last Ready Catalog on Non-Terminal Filter Failure

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Capture the installed Ready presentation before a filtered transaction**

Keep the current installed repository, membership intent, generation, and
snapshot identity unchanged until the new resolution passes all validation.

- [ ] **Step 2: Restore Ready state for non-terminal filtered failures**

When `provesTransportLost == false`, republish the last installed Ready
presentation instead of constructing:

```swift
CameraGalleryPresentation(state: .failed(...), items: [], entries: [])
```

Do not cache the failed membership. Preserve terminal transport reporting.

- [ ] **Step 3: Start ALL enrichment for ALL-equivalent membership**

Replace exact intent equality with `hasSameCameraMembership(as: .all)` while
keeping local sort/date/download projection on the installed resolution.

- [ ] **Step 4: Run all new focused tests**

Expected: all RED tests from Task 1 pass.

### Task 4: Verify the Repair Without Expanding Scope

**Files:**
- Modify: `docs/ios-gallery-entry-final-solution-20260804.md`
- Modify: `docs/ios-xapp-gallery-full-chain-difference-audit-20260804.md`
- Modify: `docs/superpowers/plans/2026-08-04-ios-gallery-entry-stabilization.md`

- [ ] **Step 1: Run the narrow RunnerTests group**

Run the new format-policy, video-source, runtime-failure, post-ready enrichment,
and generation-fence tests. Record the real executed/pass count.

- [ ] **Step 2: Run the broader Gallery/Catalog RunnerTests group**

Include initial Catalog, SearchMode wire payload, Catalog Runtime, Gallery
Session, filter engine, Quick Download exclusion, and still-only video guards.

- [ ] **Step 3: Run complete RunnerTests and build**

Run complete iOS simulator RunnerTests, `git diff --check`, generic iOS build,
and signed device build. Distinguish pre-existing plist failures from new
failures.

- [ ] **Step 4: Install and launch on the target iPhone**

Install `com.camtransfer.app` on
`952611F0-557B-5C5F-BF1F-265474E9BC4B`. Do not claim runtime proof from install
alone.

- [ ] **Step 5: Pull fresh X-T5 logs**

Verify:

```text
base Catalog installed before GalleryReady
HEIF isolated membership = 622 for the current card
MOV direct membership = 15
MP4 query executes and its raw membership is recorded
ALL publishes the deduplicated union
video filter publishes MOV + MP4
no non-loading items=0 publication on a retryable filter failure
```

- [ ] **Step 6: Write back evidence and remaining gates**

Record exact automated counts, build/install identity, fresh X-T5 counts, and
remaining X-M5/X-S20/GFX100RF gates. Do not commit or push.
