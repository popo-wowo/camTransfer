# iOS Gallery Android Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS camera gallery match the current Android gallery in layout, thumbnail browsing, HD preview session behavior, RAW sidecar queueing, download controls, and PTP exclusivity while preserving the existing connection and transfer mainlines.

**Architecture:** Keep the existing camera connection, catalog repository, D226 preview protocol, and download owner. Add a focused HD browse-session policy/coordinator, add a reversible catalog-child-work suspension API, extend downloads to accept per-item modes for mixed display/RAW queues, and rebuild `NativeGalleryViewController` chrome so UIKit renders the Android state model instead of owning transport scheduling.

**Tech Stack:** Swift 5, UIKit, Swift concurrency, XCTest `RunnerTests`, existing CameraCore gallery runtime, Xcode iOS Simulator 18.4, physical iPhone verification when available.

---

## File map

- Create `ios/Runner/NativeGalleryHDPreviewSession.swift`: HD date snapshot, display/RAW pairing, visible-window priority, progress, load state, and coordinator.
- Track and modify `ios/Runner/NativeGalleryHDPreviewCell.swift`: Android-aligned HD card rendering and button states.
- Modify `ios/Runner/NativeGalleryViewController.swift`: Android-aligned chrome and binding to the HD session coordinator.
- Modify `ios/Runner/NativeGalleryPolicies.swift`: small reusable UI policies for top tools and HD bottom-bar presentation.
- Modify `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`: suspend/resume child catalog work without dropping GalleryReady.
- Modify `ios/Runner/CameraSessionRuntime.swift`: expose gallery-child suspension and accept mixed per-item download modes.
- Modify `ios/Runner.xcodeproj/project.pbxproj`: add the new Swift source to the Runner target.
- Modify `ios/RunnerTests/RunnerTests.swift`: behavior-first regression tests.

## Verification commands

Targeted tests use the booted simulator:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/<test-name>
```

Full regression:

```bash
xcodebuild test -project ios/Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
```

Build checks:

```bash
xcodebuild build -project ios/Runner.xcodeproj -scheme Runner \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F'
git diff --check
```

### Task 1: Port the Android HD date snapshot and RAW pairing policy

**Files:**
- Create: `ios/Runner/NativeGalleryHDPreviewSession.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing snapshot, date, pairing, and visible-window tests**

Add these tests to `RunnerTests`:

```swift
func testNativeGalleryHDSessionChoosesNewestAvailableDateWhenCurrentDateHasNoPreview() throws {
  let current = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 25)))
  let older = CameraVendorGalleryItem(
    handle: 10,
    filename: "DSCF0010.JPG",
    formatLabel: "JPG",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )

  let selected = NativeGalleryHDPreviewSessionPolicy.preferredActiveDate(
    items: [older],
    currentDate: current
  )

  XCTAssertEqual(Calendar.current.component(.day, from: selected), 24)
}

func testNativeGalleryHDSessionPairsSameStemRawSidecarWithoutAddingRawToTimeline() throws {
  let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 24)))
  let jpg = CameraVendorGalleryItem(
    handle: 102,
    filename: "DSCF0102.JPG",
    formatLabel: "JPG",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )
  let raw = CameraVendorGalleryItem(
    handle: 101,
    filename: "DSCF0102.RAF",
    formatLabel: "RAW",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )

  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(items: [raw, jpg], activeDate: date)

  XCTAssertEqual(snapshot.items.map(\.displayItem.handle), [102])
  XCTAssertEqual(snapshot.items.first?.rawSidecar?.handle, 101)
}

func testNativeGalleryHDWindowPrioritizesVisibleThenTwentyAfterThenFiveBefore() {
  let ordered = Array(1...40)

  let window = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
    orderedHandles: ordered,
    visibleHandles: [10, 11, 12],
    loadedHandles: [],
    loadingHandles: [],
    failedHandles: []
  )

  XCTAssertEqual(Array(window.prefix(3)), [10, 11, 12])
  XCTAssertEqual(Array(window.dropFirst(3).prefix(20)), Array(13...32))
  XCTAssertEqual(Array(window.suffix(5)), [5, 6, 7, 8, 9])
}
```

- [ ] **Step 2: Run the tests and preserve RED evidence**

Run all three selectors. Expected result: compile failure because `NativeGalleryHDPreviewSessionPolicy` does not exist.

- [ ] **Step 3: Implement the pure HD session model**

Create `NativeGalleryHDPreviewSession.swift` with these public shapes:

```swift
import Foundation

enum NativeGalleryBrowseMode {
  case thumbnail
  case highDefinition
}

struct NativeGalleryHDPreviewItem: Equatable {
  let displayItem: CameraVendorGalleryItem
  let rawSidecar: CameraVendorGalleryItem?
}

struct NativeGalleryHDPreviewSnapshot: Equatable {
  let activeDate: Date
  let items: [NativeGalleryHDPreviewItem]

  var displayHandles: [Int] { items.map(\.displayItem.handle) }
  var allDownloadHandles: Set<Int> {
    Set(items.flatMap { item -> [Int] in
      var handles = [item.displayItem.handle]
      if let rawSidecar = item.rawSidecar {
        handles.append(rawSidecar.handle)
      }
      return handles
    })
  }
}

enum NativeGalleryHDPreviewSessionPolicy {
  static func availableDates(items: [CameraVendorGalleryItem]) -> [Date]
  static func preferredActiveDate(items: [CameraVendorGalleryItem], currentDate: Date) -> Date
  static func snapshot(items: [CameraVendorGalleryItem], activeDate: Date) -> NativeGalleryHDPreviewSnapshot
  static func priorityWindow(
    orderedHandles: [Int],
    visibleHandles: [Int],
    loadedHandles: Set<Int>,
    loadingHandles: Set<Int>,
    failedHandles: Set<Int>
  ) -> [Int]
  static func loadedCount(sessionHandles: Set<Int>, loadedHandles: Set<Int>) -> Int
}
```

Implementation rules:

- Parse dates with `NativeGalleryFilterPolicy.parsedCaptureDate(_:)` and compare calendar days.
- Display candidates are resolved JPG/HEIF or items hinted as JPG/HEIF.
- RAW candidates are resolved RAW or RAW-only hinted items.
- Prefer same filename stem; otherwise pair the closest handle on the same day only when distance is at most 3.
- Do not include RAW files as display timeline entries.
- Build priority as visible order, next 20, previous 5, then filter loaded/loading/failed handles.

Add the new source file to the Runner group and Sources build phase in `project.pbxproj`. Remove `NativeGalleryBrowseMode` from `NativeGalleryHDPreviewCell.swift` so the type has one owner.

- [ ] **Step 4: Run the three tests and verify GREEN**

Expected result: three tests execute and pass.

- [ ] **Step 5: Commit the pure policy**

```bash
git add ios/Runner/NativeGalleryHDPreviewSession.swift \
  ios/Runner/NativeGalleryHDPreviewCell.swift \
  ios/Runner.xcodeproj/project.pbxproj \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): add Android parity HD gallery session policy"
```

### Task 2: Add reversible catalog child-work suspension

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing catalog suspension tests**

```swift
func testCatalogRuntimeHDPreviewSuspensionCancelsChildWorkAndRejectsNewThumbnailRequests() async {
  let source = CameraGalleryCatalogRuntimeSourceSpy()
  let runtime = CameraGalleryCatalogRuntime(
    source: source,
    publishPresentation: { _ in },
    reportTransportEvidence: { _ in }
  )

  async let start: Void = runtime.start()
  await Task.yield()
  source.resolveCatalogRequest(at: 0, snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [1, 2]))
  await start
  await runtime.suspendChildWorkForHighDefinitionPreview()
  await runtime.requestVisibleThumbnails(handles: [1])

  XCTAssertEqual(source.requestedThumbnailHandles, [])
  XCTAssertTrue(await runtime.isChildWorkSuspendedForHighDefinitionPreview())
}

func testCatalogRuntimeHDPreviewResumeAcceptsThumbnailRequestsAgain() async {
  let source = CameraGalleryCatalogRuntimeSourceSpy()
  let runtime = CameraGalleryCatalogRuntime(
    source: source,
    publishPresentation: { _ in },
    reportTransportEvidence: { _ in }
  )

  async let start: Void = runtime.start()
  await Task.yield()
  source.resolveCatalogRequest(at: 0, snapshot: CameraGalleryCatalogRuntimeSourceSpy.snapshot(handles: [1]))
  await start
  await runtime.suspendChildWorkForHighDefinitionPreview()
  await runtime.resumeChildWorkAfterHighDefinitionPreview()
  await runtime.requestVisibleThumbnails(handles: [1])

  XCTAssertEqual(source.requestedThumbnailHandles, [1])
}
```

- [ ] **Step 2: Run the two tests and verify RED**

Expected result: compile failure for the missing suspend/resume APIs.

- [ ] **Step 3: Implement suspension in the catalog actor**

Add a reference-counted `hdPreviewSuspensionCount`.

```swift
func suspendChildWorkForHighDefinitionPreview() async {
  hdPreviewSuspensionCount += 1
  guard hdPreviewSuspensionCount == 1 else { return }
  isAcceptingChildWork = false
  await cancelAndJoinChildWork()
}

func resumeChildWorkAfterHighDefinitionPreview() {
  guard hdPreviewSuspensionCount > 0 else { return }
  hdPreviewSuspensionCount -= 1
  guard hdPreviewSuspensionCount == 0,
        case .ready(let generation, let snapshotID) = currentPresentation.state,
        repository.generation == generation,
        repository.snapshotID == snapshotID else { return }
  isAcceptingChildWork = true
  startDetailsWork(handles: repository.items.map(\.handle), generation: generation, snapshotID: snapshotID)
}

func isChildWorkSuspendedForHighDefinitionPreview() -> Bool {
  hdPreviewSuspensionCount > 0
}
```

Expose matching async wrappers from `CameraSessionRuntime`:

```swift
func suspendGalleryChildWorkForHighDefinitionPreview() async {
  await catalogRuntime?.suspendChildWorkForHighDefinitionPreview()
}

func resumeGalleryChildWorkAfterHighDefinitionPreview() async {
  await catalogRuntime?.resumeChildWorkAfterHighDefinitionPreview()
}
```

- [ ] **Step 4: Run the tests and verify GREEN**

Expected result: both catalog suspension tests pass and existing catalog tests remain green.

- [ ] **Step 5: Commit the admission boundary**

```bash
git add ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift \
  ios/Runner/CameraSessionRuntime.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): suspend gallery child work during HD preview"
```

### Task 3: Move HD loading state out of the view controller

**Files:**
- Modify: `ios/Runner/NativeGalleryHDPreviewSession.swift`
- Modify: `ios/Runner/NativePhotoPreviewViewController.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

```swift
func testNativeGalleryHDCoordinatorCountsOnlyActiveDateLoadedHandles() throws {
  let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 24)))
  let items = [1, 2].map {
    CameraVendorGalleryItem(
      handle: $0,
      filename: "DSCF000\($0).JPG",
      formatLabel: "JPG",
      captureDate: "20260724T120000",
      byteSizeText: ""
    )
  }
  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(items: items, activeDate: date)
  let state = NativeGalleryHDPreviewState(snapshot: snapshot, loadedHandles: [1, 99])

  XCTAssertEqual(state.loadedCount, 1)
  XCTAssertEqual(state.totalCount, 2)
}

func testNativeGalleryHDCoordinatorCancellationDoesNotMarkHandleFailed() throws {
  let state = NativeGalleryHDPreviewLoadReducer.reduce(
    state: NativeGalleryHDPreviewLoadState(),
    event: .started(handle: 7)
  )
  let cancelled = NativeGalleryHDPreviewLoadReducer.reduce(state: state, event: .cancelled(handle: 7))

  XCTAssertFalse(cancelled.loadingHandles.contains(7))
  XCTAssertFalse(cancelled.failedHandles.contains(7))
}
```

- [ ] **Step 2: Run the two tests and verify RED**

Expected result: compile failure because the state and reducer are missing.

- [ ] **Step 3: Implement state, reducer, and coordinator**

Add:

```swift
struct NativeGalleryHDPreviewLoadState: Equatable {
  var loadingHandles: Set<Int> = []
  var failedHandles: Set<Int> = []
}

enum NativeGalleryHDPreviewLoadEvent: Equatable {
  case started(handle: Int)
  case succeeded(handle: Int)
  case failed(handle: Int)
  case cancelled(handle: Int)
  case reset
}

enum NativeGalleryHDPreviewLoadReducer {
  static func reduce(
    state: NativeGalleryHDPreviewLoadState,
    event: NativeGalleryHDPreviewLoadEvent
  ) -> NativeGalleryHDPreviewLoadState
}

struct NativeGalleryHDPreviewState {
  let snapshot: NativeGalleryHDPreviewSnapshot
  let loadedHandles: Set<Int>
  var loadedCount: Int
  var totalCount: Int
}
```

Create `@MainActor final class NativeGalleryHDPreviewCoordinator` in the same file. It owns the active snapshot, priority queue, load task, loading/failed sets, and the existing `NativeGalleryHighDefinitionPreviewCache`. Inject closures for suspend, resume, fetch preview, and state publication. It must cancel and join its task on mode/date/download changes and treat `CancellationError` as `.cancelled`, not `.failed`.

Remove `hdModeController`, `hdLoadTask`, `hdLoadingHandles`, `hdFailedHandles`, and the loading while-loop from `NativeGalleryViewController`. Keep the shared cache type in `NativePhotoPreviewViewController.swift` for now and inject it into the coordinator.

- [ ] **Step 4: Run coordinator tests and the three Task 1 tests**

Expected result: all five execute and pass.

- [ ] **Step 5: Commit the coordinator extraction**

```bash
git add ios/Runner/NativeGalleryHDPreviewSession.swift \
  ios/Runner/NativePhotoPreviewViewController.swift \
  ios/Runner/NativeGalleryViewController.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "refactor(ios): move HD gallery loading into session coordinator"
```

### Task 4: Support mixed display and RAW download modes

**Files:**
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing mixed-mode queue tests**

```swift
func testCameraSessionRuntimeAcceptsMixedDisplayAndRawDownloadModes() {
  let requests = NativeGalleryHDDownloadRequestPolicy.requests(
    displayHandles: [20],
    rawHandles: [19],
    preferCompressedDisplay: true
  )

  XCTAssertEqual(requests.map(\.handle), [20, 19])
  XCTAssertEqual(requests.map(\.mode), [.compressed, .original])
}

func testNativeGalleryHDDownloadRequestsDeduplicateHandles() {
  let requests = NativeGalleryHDDownloadRequestPolicy.requests(
    displayHandles: [20, 20],
    rawHandles: [19, 19],
    preferCompressedDisplay: false
  )

  XCTAssertEqual(requests.map(\.handle), [20, 19])
  XCTAssertEqual(requests.map(\.mode), [.original, .original])
}
```

- [ ] **Step 2: Run tests and verify RED**

Expected result: compile failure because `NativeGalleryHDDownloadRequestPolicy` and mixed request command are missing.

- [ ] **Step 3: Implement per-item request policy and runtime command**

Add to `CameraSessionCommand`:

```swift
case startDownloadRequests([CameraSessionQueuedDownload])
```

Keep `.startDownload(handles:mode:)` as a compatibility command that maps handles to requests. Route both cases through one private method that assigns `queuedDownloads` without replacing per-item modes.

Add:

```swift
enum NativeGalleryHDDownloadRequestPolicy {
  static func requests(
    displayHandles: [Int],
    rawHandles: [Int],
    preferCompressedDisplay: Bool
  ) -> [CameraSessionQueuedDownload]
}
```

Display handles use `.compressed` only when requested. RAW handles always use `.original`. Preserve display order, then RAW order, and remove duplicate handles.

- [ ] **Step 4: Run mixed-mode tests and existing runtime download tests**

Expected result: new tests pass and existing `.startDownload(handles:mode:)` behavior remains unchanged.

- [ ] **Step 5: Commit mixed-mode queue support**

```bash
git add ios/Runner/CameraSessionRuntime.swift \
  ios/Runner/NativeGalleryViewController.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): queue HD display and RAW downloads independently"
```

### Task 5: Rebuild the gallery top chrome and shared Android layout

**Files:**
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing layout policy tests**

```swift
func testNativeGalleryAndroidParityChromeUsesOneToolRow() {
  XCTAssertEqual(NativeGalleryAndroidParityChromePolicy.toolRowHeight, 42)
  XCTAssertEqual(NativeGalleryAndroidParityChromePolicy.toolSurfaceCount, 3)
  XCTAssertFalse(NativeGalleryAndroidParityChromePolicy.usesSeparateModeRow)
}

func testNativeGalleryHDModeKeepsFilterSurfaceButDisablesExpansion() {
  XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.showsFilterSurface(mode: .highDefinition))
  XCTAssertFalse(NativeGalleryAndroidParityChromePolicy.canExpandFilters(mode: .highDefinition))
}
```

- [ ] **Step 2: Run tests and verify RED**

Expected result: compile failure because the chrome policy is missing.

- [ ] **Step 3: Implement Android-aligned top chrome**

Add the tested policy. Replace the full-width `filterHeaderView` plus full-width `browseModeSegment` stack with one horizontal `galleryToolRow` containing:

- a compact filter button on the left;
- the two-segment thumbnail/HD control in the center;
- a compact tools button on the right.

Move share, download center, download folder, and cache actions into the tools menu. Keep the back button, centered `CAMERA GALLERY`, and concise status on the first row. Keep the filter detail panel below the tool row only while expanded in thumbnail mode.

Update constraints so both `collectionView` and `hdCollectionView` start below the optional filter detail panel, with no separate mode row.

- [ ] **Step 4: Run layout policy tests and simulator build**

Expected result: two tests pass and the Runner Debug simulator build exits 0.

- [ ] **Step 5: Commit top chrome**

```bash
git add ios/Runner/NativeGalleryPolicies.swift \
  ios/Runner/NativeGalleryViewController.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): align gallery chrome with Android"
```

### Task 6: Align HD cards, floating status, and bottom download bar

**Files:**
- Modify: `ios/Runner/NativeGalleryHDPreviewCell.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing presentation tests**

```swift
func testNativeGalleryHDCardRequiresLoadedPreviewBeforeQueueing() {
  XCTAssertEqual(
    NativeGalleryHDCardActionPolicy.displayTitle(hasImage: false, state: .idle),
    "加载后加入"
  )
  XCTAssertFalse(NativeGalleryHDCardActionPolicy.canQueue(hasImage: false, state: .idle))
  XCTAssertEqual(
    NativeGalleryHDCardActionPolicy.rawTitle(hasImage: true, state: .queued),
    "RAW 已加入"
  )
}

func testNativeGalleryHDBottomBarCountsOnlyActiveSnapshotQueuedHandles() {
  let presentation = NativeGalleryHDBottomBarPolicy.presentation(
    snapshotDownloadHandles: [10, 11, 12],
    queuedHandles: [11, 99]
  )

  XCTAssertEqual(presentation.queuedCount, 1)
  XCTAssertEqual(presentation.totalCount, 3)
  XCTAssertEqual(presentation.title, "已加入 1 张")
}
```

- [ ] **Step 2: Run tests and verify RED**

Expected result: compile failure because the card and bottom-bar policies are missing.

- [ ] **Step 3: Implement card state and bottom bar**

Add pure policies for exact Android copy and enabled states. Update `NativeGalleryHDPreviewCell` so:

- waiting and loading states disable display/RAW buttons;
- loaded state enables eligible idle/failed items;
- queued state changes the same button into a cancel action;
- RAW button is hidden without a paired sidecar;
- the image uses aspect fit on black with 2-point vertical spacing;
- tapping an enabled loaded image opens the existing full-screen preview.

In HD mode hide date section headers. Replace the single progress label with two floating chips: active date and `loaded / total`.

Change the bottom bar in HD mode to Android copy and semantics: queued count, total count, transfer-size capsule, and one start button. Per-card actions only mutate local display/raw selections. The start button sends `.startDownloadRequests(...)` and opens the existing download center.

- [ ] **Step 4: Run presentation tests and targeted HD tests**

Expected result: presentation tests plus Task 1 and Task 3 tests pass.

- [ ] **Step 5: Commit HD presentation parity**

```bash
git add ios/Runner/NativeGalleryHDPreviewCell.swift \
  ios/Runner/NativeGalleryViewController.swift \
  ios/Runner/NativeGalleryPolicies.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): align HD gallery cards and download bar"
```

### Task 7: Align thumbnail gallery layout and preserve targeted refresh

**Files:**
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Write failing thumbnail layout tests**

```swift
func testNativeGalleryThumbnailLayoutMatchesAndroidGridSpacing() {
  XCTAssertEqual(NativeGalleryGridLayoutPolicy.androidGridSpacing, 2)
  XCTAssertEqual(NativeGalleryAndroidParityGridPolicy.horizontalInset, 0)
  XCTAssertEqual(NativeGalleryAndroidParityGridPolicy.sectionHeaderHeight, 44)
}

func testNativeGalleryContentUpdatesDoNotReloadWholeCollection() throws {
  let source = try String(contentsOfFile: "ios/Runner/NativeGalleryViewController.swift")
  let method = try XCTUnwrap(source.range(of: "private func applyGalleryContentUpdate"))
  let tail = source[method.lowerBound...]
  let block = String(tail.prefix(3500))

  XCTAssertFalse(block.contains("collectionView.reloadData()"))
  XCTAssertTrue(block.contains("refreshVisibleCells"))
}
```

- [ ] **Step 2: Run tests and verify RED for the new layout policy**

Expected result: the policy test fails to compile; the targeted-refresh regression must continue passing.

- [ ] **Step 3: Implement Android grid geometry**

Add `NativeGalleryAndroidParityGridPolicy`. Update the thumbnail collection layout to use Android spacing/insets while preserving date headers, current pinch column-count behavior, placeholder-first cells, format badges, selection state, and targeted content refresh. Do not reintroduce full `reloadData()` for thumbnail/details content events.

- [ ] **Step 4: Run both tests and relevant existing gallery selection tests**

Expected result: layout and targeted-refresh tests pass; selection tests remain green.

- [ ] **Step 5: Commit thumbnail layout parity**

```bash
git add ios/Runner/NativeGalleryViewController.swift \
  ios/Runner/NativeGalleryPolicies.swift \
  ios/RunnerTests/RunnerTests.swift
git commit -m "feat(ios): align thumbnail gallery layout with Android"
```

### Task 8: Complete regression, build, and device evidence

**Files:**
- Verify all scoped files only.

- [ ] **Step 1: Run all new focused tests together**

Run every new selector from Tasks 1-7 in one `xcodebuild test` invocation. Expected result: non-zero executed count and zero failures.

- [ ] **Step 2: Run complete RunnerTests**

Run the full suite on simulator `9B0FEEC3-4C3B-4312-B606-876D9076EB0F`. Record the actual executed count, passed count, and any failure names.

- [ ] **Step 3: Run static and simulator build checks**

Run `git diff --check` and the Debug simulator build. Both must exit 0 before claiming implementation equivalence.

- [ ] **Step 4: Build, install, and launch on the available physical iPhone**

Resolve the current device identifier with `xcrun devicectl list devices`, build for that exact destination, install the resulting `Runner.app`, and launch `com.camtransfer.app`. Record any device-lock, signing, or availability failure exactly.

- [ ] **Step 5: Execute the real-camera parity matrix**

On the same camera directory, verify thumbnail/HD switching, active-date count stability, visible-first loading, cache reuse after scrolling, display/RAW queueing, mixed download modes, no metadata/thumbnail request during HD, and no HD request after download starts. Capture logs proving PTP request ownership.

- [ ] **Step 6: Final scoped commit**

Stage only the files listed in this plan. Preserve `.claude/`, `.obsidian/`, `.playwright-cli/`, historical untracked plans/specs, `CameraGalleryThumbnailQueue.swift`, and `tmp/` unless a later user instruction explicitly expands scope.

```bash
git status --short
git diff --check
git add ios/Runner.xcodeproj/project.pbxproj \
  ios/Runner/NativeGalleryHDPreviewSession.swift \
  ios/Runner/NativeGalleryHDPreviewCell.swift \
  ios/Runner/NativeGalleryViewController.swift \
  ios/Runner/NativeGalleryPolicies.swift \
  ios/Runner/NativePhotoPreviewViewController.swift \
  ios/Runner/CameraCore/Gallery/CameraGalleryCatalogRuntime.swift \
  ios/Runner/CameraSessionRuntime.swift \
  ios/RunnerTests/RunnerTests.swift \
  docs/superpowers/plans/2026-07-25-ios-gallery-android-parity-implementation.md
git commit -m "feat(ios): align gallery with Android"
```
