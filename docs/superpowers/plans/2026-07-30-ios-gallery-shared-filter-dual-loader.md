# iOS Gallery Shared Filter and Dual Loader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make thumbnail and high-definition browsing consume the same filtered, ordered, date-sectioned Gallery projection while keeping independent thumbnail and high-definition loaders and enforcing a true 30-entry HD cache.

**Architecture:** `CameraGallerySession` and `CameraGalleryCatalogRuntime` remain the only filter, generation, and membership owners. `NativeGalleryRenderState.sections` is projected once into a multi-section `NativeGalleryHDPreviewSnapshot`; `CameraGalleryThumbnailPipeline` continues loading thumbnails while `CameraGalleryHDPreviewPipeline` serially loads HD content from a global visible → below → above window. Full-screen preview uses the same HD media identity and cache but acquires the existing preview admission boundary so it cannot race thumbnail, HD-grid, or download work.

**Tech Stack:** Swift 5, UIKit, Swift concurrency, XCTest, Xcode 16+, `xcodebuild`, `xcrun simctl`, `xcrun devicectl`

---

## Scope and invariants

- Work only in `/Users/g01d-01-1224/.config/superpowers/worktrees/camtransfer/codex/ios-gallery-terminal-refactor` on `codex/ios-gallery-terminal-refactor`.
- Preserve all unrelated dirty WIP. Do not use `git reset`, `git clean`, or `git checkout --`.
- Do not add another Catalog owner, filter state, membership query, generation counter, combined enrichment coordinator, or shared thumbnail/HD fetch implementation.
- Do not remove the ObjectInfo prime before camera thumbnail requests.
- Keep thumbnail mode thumbnail-only; full-screen preview and HD mode are the only HD request entry points.
- Commit only the files listed by each task. If a listed file already contains unrelated WIP, stage it with `git add -p` and inspect the staged diff before committing.

## File map

- Modify `ios/Runner/NativeGalleryHDPreviewSession.swift`: multi-section HD projection, per-section RAW pairing, global flattened order, and 30-handle priority policy.
- Modify `ios/Runner/NativeGalleryPolicies.swift`: allow the one shared filter panel in both browse modes.
- Modify `ios/Runner/NativeGalleryViewController.swift`: remove the HD-only date owner, render shared sections in both collection views, submit the same filter intent, and coordinate mode/full-screen transitions.
- Modify `ios/Runner/NativePhotoPreviewViewController.swift`: true 30-entry HD LRU cache and displayed-page-only full-screen loading.
- Modify `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`: global priority-window scheduling, latest viewport reprioritization, cache touching, and lifecycle fencing.
- Modify `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`: suspend/resume both content loaders for full-screen HD work.
- Modify `ios/Runner/CameraSessionRuntime.swift`: expose fenced full-screen preview admission and identity-bound preview requests.
- Modify `ios/RunnerTests/RunnerTests.swift`: all RED/GREEN coverage in this plan.

### Task 1: Replace the single-date HD snapshot with the shared multi-section projection

**Files:**
- Modify: `ios/Runner/NativeGalleryHDPreviewSession.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Replace the old active-date tests with failing multi-section and pairing tests**

In `RunnerTests`, remove the tests for `preferredActiveDate`, `availableDates`, and `snapshot(items:activeDate:)`. Add these tests near the existing HD session tests:

```swift
func testNativeGalleryHDProjectionPreservesSharedSectionsAndRepresentsEveryHandle() throws {
  let firstDay = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 24)
  ))
  let secondDay = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 23)
  ))
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
  let rawOnly = CameraVendorGalleryItem(
    handle: 90,
    filename: "DSCF0090.RAF",
    formatLabel: "RAW",
    captureDate: "20260723T120000",
    byteSizeText: ""
  )
  let sharedSections = [
    NativeGalleryDaySection(day: firstDay, title: "7月24日 2 张", items: [jpg, raw]),
    NativeGalleryDaySection(day: secondDay, title: "7月23日 1 张", items: [rawOnly]),
  ]

  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: sharedSections)

  XCTAssertEqual(snapshot.sections.map(\.title), sharedSections.map(\.title))
  XCTAssertEqual(snapshot.sections.map(\.day), sharedSections.map(\.day))
  XCTAssertEqual(snapshot.sections[0].items.map(\.displayItem.handle), [102])
  XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.handle, 101)
  XCTAssertEqual(snapshot.sections[1].items.map(\.displayItem.handle), [90])
  XCTAssertEqual(snapshot.orderedRepresentedHandles, [102, 101, 90])
  XCTAssertEqual(snapshot.allRepresentedHandles, Set([102, 101, 90]))
  XCTAssertEqual(snapshot.loadableDisplayHandles, [102])
}

func testNativeGalleryHDProjectionNeverPairsRawAcrossDateSections() throws {
  let firstDay = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 24)
  ))
  let secondDay = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 23)
  ))
  let jpg = CameraVendorGalleryItem(
    handle: 102,
    filename: "DSCF0102.JPG",
    formatLabel: "JPG",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )
  let sameStemRawOnAnotherDay = CameraVendorGalleryItem(
    handle: 101,
    filename: "DSCF0102.RAF",
    formatLabel: "RAW",
    captureDate: "20260723T120000",
    byteSizeText: ""
  )

  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
    NativeGalleryDaySection(day: firstDay, title: "7月24日 1 张", items: [jpg]),
    NativeGalleryDaySection(day: secondDay, title: "7月23日 1 张", items: [sameStemRawOnAnotherDay]),
  ])

  XCTAssertNil(snapshot.sections[0].items.first?.rawSidecar)
  XCTAssertEqual(snapshot.sections[1].items.first?.displayItem.handle, 101)
  XCTAssertEqual(snapshot.allRepresentedHandles, Set([102, 101]))
}

func testNativeGalleryHDProjectionDoesNotAttachUnmatchedRawInsideOneSection() throws {
  let day = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 24)
  ))
  let jpg = CameraVendorGalleryItem(
    handle: 102,
    filename: "DSCF0102.JPG",
    formatLabel: "JPG",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )
  let unrelatedRaw = CameraVendorGalleryItem(
    handle: 101,
    filename: "DSCF9999.RAF",
    formatLabel: "RAW",
    captureDate: "20260724T120000",
    byteSizeText: ""
  )

  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
    NativeGalleryDaySection(day: day, title: "7月24日 2 张", items: [jpg, unrelatedRaw]),
  ])

  XCTAssertNil(snapshot.sections[0].items[0].rawSidecar)
  XCTAssertEqual(snapshot.sections[0].items[1].displayItem.handle, 101)
  XCTAssertEqual(snapshot.orderedRepresentedHandles, [102, 101])
}

func testNativeGalleryHDProjectionPairsExtendedStillPlaceholdersInsideOneSection() throws {
  let day = try XCTUnwrap(Calendar.current.date(
    from: DateComponents(year: 2026, month: 7, day: 11)
  ))
  let rawPlaceholder = CameraVendorGalleryItem(
    handle: 100,
    filename: "0x00000064",
    formatLabel: "",
    captureDate: "20260711",
    byteSizeText: "",
    formatHints: [.extendedStillCandidate]
  )
  let previewPlaceholder = CameraVendorGalleryItem(
    handle: 101,
    filename: "0x00000065",
    formatLabel: "",
    captureDate: "20260711",
    byteSizeText: "",
    formatHints: [.extendedStillCandidate]
  )

  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(sections: [
    NativeGalleryDaySection(
      day: day,
      title: "7月11日 2 张",
      items: [previewPlaceholder, rawPlaceholder]
    ),
  ])

  XCTAssertEqual(snapshot.sections[0].items.map(\.displayItem.handle), [101])
  XCTAssertEqual(snapshot.sections[0].items.first?.displayItem.formatHints, [.heif])
  XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.handle, 100)
  XCTAssertEqual(snapshot.sections[0].items.first?.rawSidecar?.formatHints, [.raw])
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionPreservesSharedSectionsAndRepresentsEveryHandle \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionNeverPairsRawAcrossDateSections \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionDoesNotAttachUnmatchedRawInsideOneSection \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionPairsExtendedStillPlaceholdersInsideOneSection
```

Expected: compilation fails because `NativeGalleryHDPreviewSnapshot.sections`, `orderedRepresentedHandles`, `allRepresentedHandles`, `loadableDisplayHandles`, and `snapshot(sections:)` do not exist.

- [ ] **Step 3: Implement the multi-section snapshot and section-local pairing**

In `NativeGalleryHDPreviewSession.swift`, replace the old snapshot shape with:

```swift
struct NativeGalleryHDPreviewSection: Equatable {
  let day: Date?
  let title: String
  let orderedRepresentedHandles: [Int]
  let items: [NativeGalleryHDPreviewItem]
}

struct NativeGalleryHDPreviewSnapshot: Equatable {
  let sections: [NativeGalleryHDPreviewSection]

  var items: [NativeGalleryHDPreviewItem] {
    sections.flatMap(\.items)
  }

  var sectionDisplayHandles: [[Int]] {
    sections.map { $0.items.map(\.displayItem.handle) }
  }

  var displayHandles: [Int] {
    items.map(\.displayItem.handle)
  }

  var orderedRepresentedHandles: [Int] {
    sections.flatMap(\.orderedRepresentedHandles)
  }

  var loadableDisplayHandles: [Int] {
    items.compactMap { item in
      NativeGalleryPreviewImageLoadPolicy.shouldRequestPreviewImage(
        item: item.displayItem,
        hasPreviewImage: false
      ) ? item.displayItem.handle : nil
    }
  }

  var allRepresentedHandles: Set<Int> {
    Set(items.flatMap { item in
      [item.displayItem.handle] + (item.rawSidecar.map { [$0.handle] } ?? [])
    })
  }

  var allDownloadHandles: Set<Int> {
    allRepresentedHandles
  }

  func item(at indexPath: IndexPath) -> NativeGalleryHDPreviewItem? {
    guard sections.indices.contains(indexPath.section),
          sections[indexPath.section].items.indices.contains(indexPath.item) else {
      return nil
    }
    return sections[indexPath.section].items[indexPath.item]
  }

  func indexPath(forDisplayHandle handle: Int) -> IndexPath? {
    for (sectionIndex, section) in sections.enumerated() {
      if let itemIndex = section.items.firstIndex(where: { $0.displayItem.handle == handle }) {
        return IndexPath(item: itemIndex, section: sectionIndex)
      }
    }
    return nil
  }
}
```

Replace `availableDates`, `preferredActiveDate`, and `snapshot(items:activeDate:)` with:

```swift
static func snapshot(
  sections: [NativeGalleryDaySection]
) -> NativeGalleryHDPreviewSnapshot {
  NativeGalleryHDPreviewSnapshot(
    sections: sections.map { section in
      NativeGalleryHDPreviewSection(
        day: section.day,
        title: section.title,
        orderedRepresentedHandles: section.items.map(\.handle),
        items: previewItems(from: section.items)
      )
    }
  )
}

private static func previewItems(
  from sectionItems: [CameraVendorGalleryItem]
) -> [NativeGalleryHDPreviewItem] {
  let indexByHandle = Dictionary(
    uniqueKeysWithValues: sectionItems.enumerated().map { ($0.element.handle, $0.offset) }
  )
  let ambiguousItems = ambiguousExtendedStillItems(sectionItems)
  var representedHandles = Set<Int>()
  ambiguousItems.forEach { item in
    representedHandles.insert(item.displayItem.handle)
    if let rawSidecar = item.rawSidecar {
      representedHandles.insert(rawSidecar.handle)
    }
  }

  let remaining = sectionItems.filter { !representedHandles.contains($0.handle) }
  let rawCandidates = remaining.filter(isRawCandidate)
  var usedRawHandles = Set<Int>()
  var cards = ambiguousItems

  for displayItem in remaining where isDisplayCandidate(displayItem) {
    let sidecar = rawSidecar(
      for: displayItem,
      candidates: rawCandidates,
      excluding: usedRawHandles
    )
    if let sidecar {
      usedRawHandles.insert(sidecar.handle)
      representedHandles.insert(sidecar.handle)
    }
    representedHandles.insert(displayItem.handle)
    cards.append(NativeGalleryHDPreviewItem(
      displayItem: displayItem,
      rawSidecar: sidecar
    ))
  }

  for item in sectionItems where !representedHandles.contains(item.handle) {
    representedHandles.insert(item.handle)
    cards.append(NativeGalleryHDPreviewItem(displayItem: item, rawSidecar: nil))
  }

  return cards.sorted { left, right in
    let leftIndex = indexByHandle[left.displayItem.handle] ?? Int.max
    let rightIndex = indexByHandle[right.displayItem.handle] ?? Int.max
    return leftIndex < rightIndex
  }
}
```

Replace `rawSidecar(for:candidates:excluding:)` so named files pair only by exact filename stem. Keep the explicit `extendedStillCandidate` handle pairing in `ambiguousExtendedStillItems`; remove the arbitrary nearest-handle fallback:

```swift
private static func rawSidecar(
  for displayItem: CameraVendorGalleryItem,
  candidates: [CameraVendorGalleryItem],
  excluding usedHandles: Set<Int>
) -> CameraVendorGalleryItem? {
  let displayStem = filenameStem(displayItem.filename)
  guard !displayStem.isEmpty else { return nil }
  return candidates.first {
    !usedHandles.contains($0.handle) && filenameStem($0.filename) == displayStem
  }
}
```

Update `NativeGalleryHDPreviewState.totalCount` to `snapshot.items.count`. Keep the existing format-detection and ambiguous-pairing helpers unchanged.

- [ ] **Step 4: Update the test fixture to construct one or more sections**

Replace the `NativeGalleryHDPreviewSnapshot.fixture(handles:)` extension at the bottom of `RunnerTests.swift` with:

```swift
private extension NativeGalleryHDPreviewSnapshot {
  static func fixture(
    sectionHandles: [[Int]],
    sessionDate: Date = Date(timeIntervalSince1970: 1_721_779_200)
  ) -> NativeGalleryHDPreviewSnapshot {
    NativeGalleryHDPreviewSnapshot(
      sections: sectionHandles.enumerated().map { sectionIndex, handles in
        NativeGalleryHDPreviewSection(
          day: Calendar.current.date(
            byAdding: .day,
            value: -sectionIndex,
            to: sessionDate
          ),
          title: "section-\(sectionIndex)",
          orderedRepresentedHandles: handles,
          items: handles.map { handle in
            NativeGalleryHDPreviewItem(
              displayItem: CameraVendorGalleryItem(
                handle: handle,
                filename: "DSCF\(handle).JPG",
                formatLabel: "JPG",
                captureDate: "20260724T120000",
                byteSizeText: ""
              ),
              rawSidecar: nil
            )
          }
        )
      }
    )
  }

  static func fixture(handles: [Int]) -> NativeGalleryHDPreviewSnapshot {
    fixture(sectionHandles: [handles])
  }
}
```

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2 again.

Expected: all 4 tests pass.

- [ ] **Step 6: Commit the projection change**

```bash
git add -p ios/Runner/NativeGalleryHDPreviewSession.swift ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git commit -m "refactor(ios): share gallery sections with hd preview"
```

### Task 2: Make HD mode render the shared sections and use the shared filter panel

**Files:**
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add failing tests for one filter surface and multi-section HD rendering**

Replace `testNativeGalleryHDModeKeepsFilterSurfaceButDisablesExpansion` with:

```swift
func testNativeGalleryFilterPanelCanExpandInBothBrowseModes() {
  XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.showsFilterSurface(mode: .thumbnail))
  XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.showsFilterSurface(mode: .highDefinition))
  XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.canExpandFilters(mode: .thumbnail))
  XCTAssertTrue(NativeGalleryAndroidParityChromePolicy.canExpandFilters(mode: .highDefinition))
}

func testNativeGalleryHDModeHasNoIndependentDateOwnerOrPicker() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativeGalleryViewController.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)

  XCTAssertFalse(source.contains("hdActiveDate"))
  XCTAssertFalse(source.contains("hdDateButton"))
  XCTAssertFalse(source.contains("selectHDDateTapped"))
  XCTAssertFalse(source.contains("preferredHDActiveDate"))
  XCTAssertTrue(source.contains("NativeGalleryHDPreviewSessionPolicy.snapshot(\n      sections: gallerySections"))
}

func testNativeGalleryHDCollectionUsesSnapshotSectionsAndSharedHeaders() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativeGalleryViewController.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)

  XCTAssertTrue(source.contains("hdPresentationState?.snapshot.sections.count"))
  XCTAssertTrue(source.contains("snapshot.item(at: indexPath)"))
  XCTAssertTrue(source.contains("configureGalleryHeader(header, at: indexPath)"))
  XCTAssertFalse(source.contains("if collectionView === hdCollectionView { return 1 }"))
  XCTAssertFalse(source.contains("if collectionView === hdCollectionView {\n      return .zero\n    }"))
  XCTAssertFalse(source.contains("browseMode != .thumbnail || !NativeGalleryEmptyStatePolicy.shouldShow"))
}

func testNativeGalleryUsesOneFilterSubmissionIndependentOfBrowseMode() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativeGalleryViewController.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)
  let switchStart = try XCTUnwrap(
    source.range(of: "private func switchBrowseMode(_ mode: NativeGalleryBrowseMode)")?.lowerBound
  )
  let switchEnd = try XCTUnwrap(
    source.range(of: "private func startHDPreviewLoading()", range: switchStart..<source.endIndex)?.lowerBound
  )
  let switchBody = String(source[switchStart..<switchEnd])

  XCTAssertEqual(source.components(separatedBy: "private var filterState").count - 1, 1)
  XCTAssertFalse(switchBody.contains("submitGalleryIntent()"))
  XCTAssertTrue(source.contains("rule: filterState.rule"))
  XCTAssertTrue(source.contains("sort: filterState.sortIntent"))
  XCTAssertTrue(source.contains("NativeGalleryHDPreviewSessionPolicy.snapshot(\n      sections: gallerySections"))
}
```

Replace `testNativeGalleryHDChromeKeepsGalleryBackgroundAndAndroidDateChipOrder` with:

```swift
func testNativeGalleryHDChromeKeepsGalleryBackground() {
  XCTAssertTrue(NativeGalleryHDChromePolicy.usesGalleryBackground)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryFilterPanelCanExpandInBothBrowseModes \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDModeHasNoIndependentDateOwnerOrPicker \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDCollectionUsesSnapshotSectionsAndSharedHeaders \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryUsesOneFilterSubmissionIndependentOfBrowseMode
```

Expected: the first 3 tests fail against the current locked filter, `hdActiveDate`, date picker, and single-section data source; the single-submission test protects the already-correct Catalog ownership.

- [ ] **Step 3: Allow the shared filter panel in both modes**

In `NativeGalleryPolicies.swift`, replace `canExpandFilters` with:

```swift
static func canExpandFilters(mode _: NativeGalleryBrowseMode) -> Bool {
  true
}
```

In `toggleFilterPanel`, remove the high-definition guard and its “筛选面板已锁定” toast. In `switchBrowseMode`, do not disable `galleryFilterButton`, do not force `isFilterPanelExpanded = false`, and do not collapse the panel when entering HD mode.

- [ ] **Step 4: Remove the HD-only date UI and build the HD snapshot from `gallerySections`**

In `NativeGalleryViewController.swift`:

1. Remove `hdActiveDate`, `hdDateButton`, `selectHDDateTapped`, and `preferredHDActiveDate`.
2. Remove `NativeGalleryHDChromePolicy.dateFormat` and `showsLoadCountBeforeDate`; keep only `usesGalleryBackground`.
3. Change `hdTopChipRow` to contain only `hdStatusLabel`.
4. Remove `hdDateButton.addTarget` and the `hdDateButton` height constraint.
5. Replace `startHDPreviewLoading` with:

```swift
private func startHDPreviewLoading() {
  guard let catalogIdentity = runtime.galleryCatalogIdentity else { return }
  let snapshot = NativeGalleryHDPreviewSessionPolicy.snapshot(
    sections: gallerySections
  )
  hdRenderedSectionDisplayHandles = []
  applyHDPreviewState(NativeGalleryHDPreviewState(
    snapshot: snapshot,
    loadedHandles: runtime.galleryHDPreviewLoadedHandles(for: catalogIdentity)
  ))
  hdCollectionView.layoutIfNeeded()
  let visibleHandles = hdVisibleHandles()
  enqueueHDTransition { [weak self] in
    guard let self else { return }
    await self.runtime.switchGalleryPreviewMode(
      .highDefinition,
      snapshot: snapshot,
      visibleHandles: visibleHandles
    )
  }
}
```

Rename `hdRenderedDisplayHandles` to:

```swift
private var hdRenderedSectionDisplayHandles: [[Int]] = []
```

Replace `updateHDStatusLabel` with:

```swift
private func updateHDStatusLabel(_ state: NativeGalleryHDPreviewState?) {
  guard let state, state.totalCount > 0 else {
    hdTopChipRow.isHidden = true
    return
  }
  hdStatusLabel.text = "  \(state.loadedCount)/\(state.totalCount)  "
  hdStatusLabel.isHidden = false
  hdTopChipRow.isHidden = false
}
```

- [ ] **Step 5: Make every HD collection lookup section-aware**

Use these helpers:

```swift
private func hdVisibleHandles() -> [Int] {
  guard let snapshot = hdPresentationState?.snapshot else { return [] }
  return hdCollectionView.indexPathsForVisibleItems
    .sorted { left, right in
      if left.section == right.section { return left.item < right.item }
      return left.section < right.section
    }
    .compactMap { snapshot.item(at: $0)?.displayItem.handle }
}

private func refreshHDCell(for handle: Int) {
  guard browseMode == .highDefinition,
        let snapshot = hdPresentationState?.snapshot,
        let indexPath = snapshot.indexPath(forDisplayHandle: handle),
        let item = snapshot.item(at: indexPath),
        let cell = hdCollectionView.cellForItem(at: indexPath) as? NativeGalleryHDPreviewCell else {
    return
  }
  configureHDCell(cell, previewItem: item)
}
```

In `applyHDPreviewState`, compare `state?.snapshot.sectionDisplayHandles` with `hdRenderedSectionDisplayHandles`. Reconfigure visible cells through `snapshot.item(at:)`.

Replace the HD branches of the collection data source and layout delegate with:

```swift
func numberOfSections(in collectionView: UICollectionView) -> Int {
  if collectionView === hdCollectionView {
    return hdPresentationState?.snapshot.sections.count ?? 0
  }
  return gallerySections.isEmpty ? 1 : gallerySections.count
}

func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
  if collectionView === hdCollectionView {
    guard collapsedSections.contains(section) == false,
          let sections = hdPresentationState?.snapshot.sections,
          sections.indices.contains(section) else { return 0 }
    return sections[section].items.count
  }
  guard gallerySections.indices.contains(section) else { return 0 }
  if collapsedSections.contains(section) { return 0 }
  return gallerySections[section].items.count
}
```

In the HD `cellForItemAt` and `sizeForItemAt` branches, resolve the item through `snapshot.item(at: indexPath)`. In `viewForSupplementaryElementOfKind`, use the same `configureGalleryHeader(header, at:)` path for both collection views. Return `NativeGalleryAndroidParityGridPolicy.sectionHeaderHeight` for both collection views in `referenceSizeForHeaderInSection`.

Update `toggleSectionCollapse` so it reloads the active collection view:

```swift
private func toggleSectionCollapse(at sectionIndex: Int) {
  guard gallerySections.indices.contains(sectionIndex) else { return }
  if collapsedSections.contains(sectionIndex) {
    collapsedSections.remove(sectionIndex)
  } else {
    collapsedSections.insert(sectionIndex)
  }
  let activeCollectionView = browseMode == .highDefinition ? hdCollectionView : collectionView
  UIView.performWithoutAnimation {
    activeCollectionView.reloadSections(IndexSet(integer: sectionIndex))
  }
}
```

When a Catalog replacement becomes ready, move both collection views to the top before scheduling the active loader:

```swift
let topOffset = CGPoint(x: 0, y: -collectionView.adjustedContentInset.top)
collectionView.setContentOffset(topOffset, animated: false)
hdCollectionView.setContentOffset(
  CGPoint(x: 0, y: -hdCollectionView.adjustedContentInset.top),
  animated: false
)
```

Make the shared empty state independent of browse mode:

```swift
private func refreshGalleryEmptyState() {
  filteredEmptyContainer.isHidden = !NativeGalleryEmptyStatePolicy.shouldShow(
    itemCount: catalogPresentation.items.count,
    isLoading: catalogPresentation.isLoading,
    errorMessage: catalogPresentation.errorMessage,
    filterState: filterState
  )
}
```

- [ ] **Step 6: Fix the adjacent HD RAW-selection double toggle while editing the card wiring**

In `configureHDCell`, keep exactly one call to `toggleSelection(for: rawSidecar)` in `onQueueRawTapped`. The current duplicated call cancels its own selection change.

- [ ] **Step 7: Run the focused tests and verify GREEN**

Run the command from Step 2 again.

Expected: all 4 tests pass.

- [ ] **Step 8: Commit the shared UI projection**

```bash
git add -p ios/Runner/NativeGalleryPolicies.swift ios/Runner/NativeGalleryViewController.swift ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git commit -m "refactor(ios): share gallery filter and sections across modes"
```

### Task 3: Enforce global visible → below → above HD scheduling with latest viewport priority

**Files:**
- Modify: `ios/Runner/NativeGalleryHDPreviewSession.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Replace the old 20-after/5-before test with failing global-window tests**

```swift
func testNativeGalleryHDWindowIsVisibleThenBelowThenNearestAboveAndLimitedToThirty() {
  let window = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
    orderedHandles: Array(1...40),
    visibleHandles: [35, 36],
    limit: 30
  )

  XCTAssertEqual(Array(window.prefix(2)), [35, 36])
  XCTAssertEqual(Array(window.dropFirst(2).prefix(4)), [37, 38, 39, 40])
  XCTAssertEqual(Array(window.dropFirst(6).prefix(4)), [34, 33, 32, 31])
  XCTAssertEqual(window.count, 30)
  XCTAssertEqual(Set(window).count, 30)
}

func testNativeGalleryHDWindowCrossesDateSectionsWithoutResetting() {
  let snapshot = NativeGalleryHDPreviewSnapshot.fixture(
    sectionHandles: [[1, 2], [3, 4]]
  )

  let window = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
    orderedHandles: snapshot.loadableDisplayHandles,
    visibleHandles: [2],
    limit: 30
  )

  XCTAssertEqual(snapshot.loadableDisplayHandles, [1, 2, 3, 4])
  XCTAssertEqual(window, [2, 3, 4, 1])
}
```

Add this pipeline test:

```swift
@MainActor
func testHDPreviewPipelineFinishesInflightRequestThenUsesLatestViewport() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("hd-preview-latest-viewport-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = NativeGalleryHighDefinitionPreviewCache(directory: directory)
  let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
  var fetchedHandles: [Int] = []
  var firstFetchContinuation: CheckedContinuation<Void, Never>?
  let pipeline = CameraGalleryHDPreviewPipeline(
    cache: cache,
    suspendThumbnailPipeline: {},
    resumeThumbnailPipeline: {},
    fetchPreview: { identity in
      fetchedHandles.append(identity.handle)
      if fetchedHandles.count == 1 {
        await withCheckedContinuation { continuation in
          firstFetchContinuation = continuation
        }
      }
      return CameraGalleryPreviewResult(
        data: Data([UInt8(identity.handle)]),
        objectOrientation: nil
      )
    },
    publish: { _ in }
  )

  await pipeline.activate(
    catalogIdentity: catalog,
    snapshot: .fixture(handles: [1, 2, 3, 4]),
    visibleHandles: [1]
  )
  for _ in 0..<100 where firstFetchContinuation == nil { await Task.yield() }

  pipeline.updateVisibleHandles([4])
  firstFetchContinuation?.resume()
  for _ in 0..<100 where fetchedHandles.count < 2 { await Task.yield() }
  await pipeline.suspend()

  XCTAssertEqual(Array(fetchedHandles.prefix(2)), [1, 4])
}
```

- [ ] **Step 2: Run the 3 focused tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDWindowIsVisibleThenBelowThenNearestAboveAndLimitedToThirty \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDWindowCrossesDateSectionsWithoutResetting \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineFinishesInflightRequestThenUsesLatestViewport
```

Expected: compilation fails because the priority policy does not accept `limit`; after adding only the label, ordering still fails because the old algorithm uses 20 below and the farthest five above.

- [ ] **Step 3: Implement the bounded global priority window**

Replace `priorityWindow` with:

```swift
static func priorityWindow(
  orderedHandles: [Int],
  visibleHandles: [Int],
  limit: Int = 30
) -> [Int] {
  let boundedLimit = max(1, limit)
  let ordered = orderedUnique(orderedHandles)
  let visibleSet = Set(visibleHandles)
  let visible = ordered.filter { visibleSet.contains($0) }
  guard !visible.isEmpty else {
    return Array(ordered.prefix(boundedLimit))
  }

  let indexByHandle = Dictionary(
    uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) }
  )
  let visibleIndices = visible.compactMap { indexByHandle[$0] }
  guard let firstVisibleIndex = visibleIndices.min(),
        let lastVisibleIndex = visibleIndices.max() else { return [] }

  var result = Array(visible.prefix(boundedLimit))
  var nextBelow = lastVisibleIndex + 1
  while result.count < boundedLimit, nextBelow < ordered.count {
    result.append(ordered[nextBelow])
    nextBelow += 1
  }

  var nextAbove = firstVisibleIndex - 1
  while result.count < boundedLimit, nextAbove >= 0 {
    result.append(ordered[nextAbove])
    nextAbove -= 1
  }
  return orderedUnique(result)
}
```

- [ ] **Step 4: Make the pipeline filter pending state after computing the latest global window**

In `CameraGalleryHDPreviewPipeline.pump`, replace the old policy call with:

```swift
let priorityHandles = NativeGalleryHDPreviewSessionPolicy.priorityWindow(
  orderedHandles: snapshot.loadableDisplayHandles,
  visibleHandles: visibleHandles.isEmpty
    ? Array(snapshot.loadableDisplayHandles.prefix(3))
    : visibleHandles,
  limit: 30
)
let excluded = cache.loadedHandles(for: catalogIdentity)
  .union(loadState.loadingHandles)
  .union(loadState.failedHandles)
let pending = priorityHandles.filter { !excluded.contains($0) }
```

Do not cancel `loadTask` from `updateVisibleHandles`. The existing loop must finish the current awaited `fetchPreview`, validate the identity, then read `visibleHandles` again at the top of the next iteration.

- [ ] **Step 5: Run the 3 focused tests and verify GREEN**

Run the command from Step 2 again.

Expected: all 3 tests pass.

- [ ] **Step 6: Commit the scheduling change**

```bash
git add -p ios/Runner/NativeGalleryHDPreviewSession.swift ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git commit -m "fix(ios): order hd preview work by latest viewport"
```

### Task 4: Turn the HD cache into a true 30-entry LRU across memory, disk, loaded state, and orientation

**Files:**
- Modify: `ios/Runner/NativePhotoPreviewViewController.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Replace the old memory-only eviction tests with failing full-entry LRU tests**

Remove `testNativeGalleryHighDefinitionPreviewCacheKeepsLoadedStateAfterMemoryEviction` and `testNativeGalleryHighDefinitionPreviewCacheKeepsObjectOrientationAfterMemoryEviction`. Add:

```swift
func testNativeGalleryHighDefinitionPreviewCacheEvictsWholeLeastRecentlyUsedEntry() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("hd-preview-lru-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = NativeGalleryHighDefinitionPreviewCache(
    maxEntries: 2,
    directory: directory
  )
  let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
  let first = CameraGalleryMediaIdentity(catalog: catalog, handle: 1, variant: .hdPreview)
  let second = CameraGalleryMediaIdentity(catalog: catalog, handle: 2, variant: .hdPreview)
  let third = CameraGalleryMediaIdentity(catalog: catalog, handle: 3, variant: .hdPreview)

  cache.store(Data([1]), for: first, objectOrientation: 2)
  cache.store(Data([2]), for: second, objectOrientation: 4)
  XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.objectOrientation, 2)
  cache.store(Data([3]), for: third, objectOrientation: 6)

  XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 3]))
  XCTAssertNil(cache.memoryData(for: second))
  XCTAssertNil(cache.restoreLoadedPreview(for: second))
  XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.data, Data([1]))
  XCTAssertEqual(cache.restoreLoadedPreview(for: first)?.objectOrientation, 2)
  XCTAssertEqual(
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count,
    2
  )
}

func testNativeGalleryHighDefinitionPreviewCacheTouchesVisibleLoadedHandlesInPriorityOrder() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("hd-preview-touch-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = NativeGalleryHighDefinitionPreviewCache(maxEntries: 2, directory: directory)
  let catalog = CameraGalleryCatalogIdentity.fixture(generation: 1)
  let identities = [1, 2, 3].map {
    CameraGalleryMediaIdentity(catalog: catalog, handle: $0, variant: .hdPreview)
  }

  cache.store(Data([1]), for: identities[0])
  cache.store(Data([2]), for: identities[1])
  cache.touchLoadedHandles([2, 1], for: catalog)
  cache.store(Data([3]), for: identities[2])

  XCTAssertEqual(cache.loadedHandles(for: catalog), Set([1, 3]))
  XCTAssertNil(cache.restoreLoadedData(for: identities[1]))
}
```

The touch order is intentional: `[2, 1]` makes handle 1 the most recently touched, so handle 2 is evicted when handle 3 arrives.

- [ ] **Step 2: Run the focused tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHighDefinitionPreviewCacheEvictsWholeLeastRecentlyUsedEntry \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHighDefinitionPreviewCacheTouchesVisibleLoadedHandlesInPriorityOrder \
  -only-testing:RunnerTests/RunnerTests/testThumbnailAndHDPreviewCachesNeverShareEntries
```

Expected: compilation fails because `maxEntries` and `touchLoadedHandles` do not exist; the old cache would also keep handle 2 in loaded state and on disk.

- [ ] **Step 3: Replace the memory-only cache with one LRU order for complete entries**

In `NativeGalleryHighDefinitionPreviewCache`, rename `maxMemoryImages` to `maxEntries`, rename `memoryOrder` to `lruOrder`, and use this implementation for storage/touch/eviction:

```swift
private let maxEntries: Int
private let directory: URL
private var memory: [CameraGalleryMediaCacheKey: Data] = [:]
private var lruOrder: [CameraGalleryMediaCacheKey] = []
private var loaded: Set<CameraGalleryMediaCacheKey> = []
private var objectOrientations: [CameraGalleryMediaCacheKey: Int] = [:]

init(
  maxEntries: Int = 30,
  directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("hd-preview-cache", isDirectory: true)
) {
  self.maxEntries = max(1, maxEntries)
  self.directory = directory
}

func store(
  _ data: Data,
  for identity: CameraGalleryMediaIdentity,
  objectOrientation: Int? = nil
) {
  guard let key = cacheKey(for: identity) else { return }
  loaded.insert(key)
  objectOrientations[key] = objectOrientation
  memory[key] = data
  writeToDisk(data, for: key)
  touch(key)
  evictIfNeeded()
}

func touchLoadedHandles(
  _ handles: [Int],
  for catalogIdentity: CameraGalleryCatalogIdentity
) {
  for handle in handles {
    let key = CameraGalleryMediaCacheKey(
      sessionEpoch: catalogIdentity.sessionEpoch,
      handle: handle,
      variant: .hdPreview
    )
    guard loaded.contains(key) else { continue }
    touch(key)
  }
}

private func cacheInMemory(_ data: Data, for key: CameraGalleryMediaCacheKey) {
  memory[key] = data
  touch(key)
}

private func touch(_ key: CameraGalleryMediaCacheKey) {
  lruOrder.removeAll { $0 == key }
  lruOrder.append(key)
}

private func evictIfNeeded() {
  while lruOrder.count > maxEntries {
    let evicted = lruOrder.removeFirst()
    memory.removeValue(forKey: evicted)
    loaded.remove(evicted)
    objectOrientations.removeValue(forKey: evicted)
    try? FileManager.default.removeItem(at: fileURL(for: evicted))
    CameraVendorFileLogger.log(
      "[OBS] HD_PREVIEW_CACHE_EVICT handle=0x\(String(format: "%08X", evicted.handle)) retained=\(loaded.count)"
    )
  }
}
```

Update `memoryData` and successful disk restore to call `touch`. Update `reset` to clear `lruOrder`. Do not recreate an evicted entry from an orphaned disk file: `restoreLoadedData` must keep its existing `loaded.contains(key)` guard.

- [ ] **Step 4: Touch the current 30-handle priority window before choosing missing work**

In `CameraGalleryHDPreviewPipeline.pump`, after computing `priorityHandles`, add:

```swift
cache.touchLoadedHandles(Array(priorityHandles.reversed()), for: catalogIdentity)
```

`touch` appends to the MRU end. Reversing the policy order makes the visible prefix the last handles touched, so visible images remain hotter than below/above images. The focused touch test is the authority for this ordering.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run the command from Step 2 again.

Expected: all 3 tests pass; directory file count never exceeds the configured entry limit.

- [ ] **Step 6: Commit the cache change**

```bash
git add -p ios/Runner/NativePhotoPreviewViewController.swift ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git commit -m "fix(ios): bound hd preview cache to thirty entries"
```

### Task 5: Fence mode switches, filter generations, downloads, and full-screen preview on the PTP lane

**Files:**
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Modify: `ios/Runner/NativePhotoPreviewViewController.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift`
- Modify: `ios/Runner/CameraCore/Gallery/CameraGallerySession.swift`
- Modify: `ios/Runner/CameraSessionRuntime.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add failing lifecycle and displayed-page tests**

Add:

```swift
func testCameraGallerySessionFullScreenPreviewSuspendsBothContentLoaders() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/CameraCore/Gallery/CameraGallerySession.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)

  XCTAssertTrue(source.contains("func suspendContentWorkForFullScreenPreview() async"))
  XCTAssertTrue(source.contains("await hdPreviewPipeline.suspend()"))
  XCTAssertTrue(source.contains("await catalogRuntime.suspendChildWorkForHighDefinitionPreview()"))
  XCTAssertTrue(source.contains("func resumeContentWorkAfterFullScreenPreview() async"))
  XCTAssertTrue(source.contains("await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()"))
  XCTAssertTrue(source.contains("hdPreviewPipeline.resume()"))
}

func testNativePhotoPreviewOnlyLoadsHighDefinitionForDisplayedPage() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativePhotoPreviewViewController.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)

  XCTAssertTrue(source.contains("private var isDisplayedPage = false"))
  XCTAssertTrue(source.contains("func setDisplayedPage(_ isDisplayed: Bool)"))
  XCTAssertTrue(source.contains("guard isDisplayedPage else { return }"))
  XCTAssertTrue(source.contains("initialPage.setDisplayedPage(true)"))
  XCTAssertTrue(source.contains("previousViewControllers.forEach"))
  XCTAssertTrue(source.contains("page.setDisplayedPage(true)"))
}

func testFullScreenPreviewUsesCatalogIdentityBoundRequestAndBalancedAdmission() throws {
  let runtimeURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/CameraSessionRuntime.swift")
  let galleryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativeGalleryViewController.swift")
  let runtimeSource = try String(contentsOf: runtimeURL, encoding: .utf8)
  let gallerySource = try String(contentsOf: galleryURL, encoding: .utf8)

  XCTAssertTrue(runtimeSource.contains("func requestPreviewImageWithInfo(\n    for identity: CameraGalleryMediaIdentity"))
  XCTAssertTrue(runtimeSource.contains("guard identity.variant == .hdPreview"))
  XCTAssertTrue(runtimeSource.contains("galleryCatalogIdentity == identity.catalog"))
  XCTAssertTrue(gallerySource.contains("await self.runtime.suspendGalleryContentWorkForFullScreenPreview()"))
  XCTAssertTrue(gallerySource.contains("await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()"))
  XCTAssertTrue(gallerySource.contains("scheduleVisibleThumbnailRefresh(after: 0)"))
}

func testCameraGallerySessionStopsOldHDWorkBeforeSubmittingAnotherFilter() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/CameraCore/Gallery/CameraGallerySession.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)
  let submitStart = try XCTUnwrap(
    source.range(of: "func submitFilter(_ intent: CameraGalleryFilterIntent) async")?.lowerBound
  )
  let submitEnd = try XCTUnwrap(
    source.range(of: "\n  }", range: submitStart..<source.endIndex)?.upperBound
  )
  let submitBody = String(source[submitStart..<submitEnd])

  let hdCancel = try XCTUnwrap(submitBody.range(of: "await hdPreviewPipeline.prepareForCatalogChange()"))
  let catalogSubmit = try XCTUnwrap(submitBody.range(of: "await catalogRuntime.submit("))
  XCTAssertLessThan(hdCancel.lowerBound, catalogSubmit.lowerBound)
}

func testSwitchingBackToThumbnailClearsViewportIdentityAndResubmitsVisibleWindow() throws {
  let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Runner/NativeGalleryViewController.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)
  let switchStart = try XCTUnwrap(
    source.range(of: "private func switchBrowseMode(_ mode: NativeGalleryBrowseMode)")?.lowerBound
  )
  let switchEnd = try XCTUnwrap(
    source.range(of: "private func startHDPreviewLoading()", range: switchStart..<source.endIndex)?.lowerBound
  )
  let switchBody = String(source[switchStart..<switchEnd])

  XCTAssertTrue(switchBody.contains("await self?.runtime.switchGalleryPreviewMode(.thumbnail)"))
  XCTAssertTrue(switchBody.contains("self?.lastSubmittedThumbnailViewportIdentity = nil"))
  XCTAssertTrue(switchBody.contains("self?.scheduleVisibleThumbnailRefresh(after: 0)"))
}
```

- [ ] **Step 2: Run the focused lifecycle tests and verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testCameraGallerySessionFullScreenPreviewSuspendsBothContentLoaders \
  -only-testing:RunnerTests/RunnerTests/testNativePhotoPreviewOnlyLoadsHighDefinitionForDisplayedPage \
  -only-testing:RunnerTests/RunnerTests/testFullScreenPreviewUsesCatalogIdentityBoundRequestAndBalancedAdmission \
  -only-testing:RunnerTests/RunnerTests/testCameraGallerySessionStopsOldHDWorkBeforeSubmittingAnotherFilter \
  -only-testing:RunnerTests/RunnerTests/testSwitchingBackToThumbnailClearsViewportIdentityAndResubmitsVisibleWindow \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRejectsAnOldCatalogPublication \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRepeatedActivationBalancesThumbnailSuspensionOnce \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRepeatedActivationStaysPausedDuringDownload
```

Expected: the lifecycle tests fail because full-screen preview currently calls the transport directly, does not suspend the HD pipeline, page-controller prefetch can instantiate adjacent loaders, filter submission does not stop the previous HD worker, and thumbnail mode does not clear its old viewport identity before resubmission. The existing 3 pipeline tests remain green.

- [ ] **Step 3: Stop old-generation HD work before submitting a new filter**

In `CameraGalleryHDPreviewPipeline.swift`, add a Catalog-change boundary that cancels and joins the worker without releasing the HD mode's thumbnail suspension ownership:

```swift
func prepareForCatalogChange() async {
  await cancelLoading()
  loadState = NativeGalleryHDPreviewLoadState()
  let previousCatalogIdentity = catalogIdentity
  state = nil
  if let previousCatalogIdentity {
    publish(.state(previousCatalogIdentity, nil))
  }
}
```

In `CameraGallerySession.submitFilter`, call it before the Catalog transaction:

```swift
func submitFilter(_ intent: CameraGalleryFilterIntent) async {
  guard !isInvalidated else { return }
  filterIntent = intent
  filterStore.save(intent, for: identity)
  nextSubmissionRawValue &+= 1
  await hdPreviewPipeline.prepareForCatalogChange()
  await catalogRuntime.submit(
    intent,
    submissionID: CameraGalleryIntentSubmissionID(rawValue: nextSubmissionRawValue),
    downloadedHandles: downloadedHandles()
  )
}
```

Do not call `deactivate(resumeThumbnailPipeline:)` here: HD mode still owns one thumbnail-suspension count, and the next ready Catalog will reactivate the same HD pipeline without incrementing that ownership again.

- [ ] **Step 4: Add full-screen suspension to `CameraGallerySession` and runtime**

In `CameraGallerySession.swift`, add:

```swift
func suspendContentWorkForFullScreenPreview() async {
  await hdPreviewPipeline.suspend()
  await catalogRuntime.suspendChildWorkForHighDefinitionPreview()
}

func resumeContentWorkAfterFullScreenPreview() async {
  await catalogRuntime.resumeChildWorkAfterHighDefinitionPreview()
  hdPreviewPipeline.resume()
}
```

In `CameraSessionRuntime.swift`, replace the unused thumbnail-only preview wrappers with:

```swift
func suspendGalleryContentWorkForFullScreenPreview() async {
  await gallerySession?.suspendContentWorkForFullScreenPreview()
}

func resumeGalleryContentWorkAfterFullScreenPreview() async {
  await gallerySession?.resumeContentWorkAfterFullScreenPreview()
}
```

Add an identity-bound overload and keep the handle-only method only if another caller still uses it:

```swift
func requestPreviewImageWithInfo(
  for identity: CameraGalleryMediaIdentity
) async throws -> CameraVendorGalleryPreview {
  try validateCatalogCommand()
  guard identity.variant == .hdPreview,
        galleryCatalogIdentity == identity.catalog,
        gallerySession?.catalogIdentity == identity.catalog,
        gallerySession?.presentation.items.contains(where: {
          $0.handle == identity.handle
        }) == true else {
    throw CancellationError()
  }
  let preview = try await transport.fetchPreviewImageWithInfo(for: identity.handle)
  try validateCatalogCommand()
  guard galleryCatalogIdentity == identity.catalog else {
    throw CancellationError()
  }
  return preview
}
```

- [ ] **Step 5: Prevent adjacent page-controller prefetch from issuing HD requests**

In `NativePhotoPreviewPageController`, add:

```swift
private var isDisplayedPage = false

func setDisplayedPage(_ isDisplayed: Bool) {
  guard isDisplayedPage != isDisplayed else { return }
  isDisplayedPage = isDisplayed
  if isDisplayed {
    if isViewLoaded { loadImage() }
  } else {
    loadTask?.cancel()
    loadTask = nil
    spinner.stopAnimating()
  }
}
```

In `viewDidLoad`, replace unconditional `loadImage()` with:

```swift
if isDisplayedPage {
  loadImage()
}
```

At the beginning of `loadImage`, add:

```swift
guard isDisplayedPage else { return }
```

In `NativePhotoPreviewViewController.setupUI`, mark the initial page before installing it:

```swift
let initialPage = makePage(for: currentIndex)
initialPage.setDisplayedPage(true)
pageController.setViewControllers([initialPage], direction: .forward, animated: false)
```

In `didFinishAnimating`, replace the final body with:

```swift
previousViewControllers.forEach {
  ($0 as? NativePhotoPreviewPageController)?.setDisplayedPage(false)
}
guard let page = pageController.viewControllers?.first as? NativePhotoPreviewPageController else {
  return
}
page.setDisplayedPage(true)
currentIndex = page.index
refreshChromeForCurrentItem()
```

Change the page controller’s camera request dependency from direct `runtime.requestPreviewImageWithInfo(for: item.handle)` to an injected closure:

```swift
private let requestPreviewImage: (Int) async throws -> CameraVendorGalleryPreview
```

The parent closure must create `.hdPreview` identity from `previewCatalogIdentity` and call the identity-bound runtime overload.

- [ ] **Step 6: Acquire full-screen admission before pushing and release it exactly once on exit**

Add this closure and release guard to `NativePhotoPreviewViewController`:

```swift
private let onPreviewClosed: () -> Void
private var hasReportedPreviewClosed = false

private func reportPreviewClosedIfNeeded() {
  guard !hasReportedPreviewClosed else { return }
  hasReportedPreviewClosed = true
  onPreviewClosed()
}
```

Call `reportPreviewClosedIfNeeded()` from `viewDidDisappear` only when the controller is moving from its parent or being dismissed:

```swift
if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
  reportPreviewClosedIfNeeded()
}
```

In `NativeGalleryViewController.presentPreview`, capture the current items and Catalog identity, then serialize admission through `enqueueHDTransition`:

```swift
let previewItems = catalogPresentation.items
guard previewItems.indices.contains(index),
      let previewCatalogIdentity = runtime.galleryCatalogIdentity else { return }

enqueueHDTransition { [weak self] in
  guard let self else { return }
  await self.runtime.suspendGalleryContentWorkForFullScreenPreview()
  guard self.runtime.galleryCatalogIdentity == previewCatalogIdentity else {
    await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
    return
  }

  let controller = NativePhotoPreviewViewController(
    items: previewItems,
    initialIndex: index,
    runtime: self.runtime,
    previewImageCache: previewImageCache,
    previewCatalogIdentity: previewCatalogIdentity,
    requestPreviewImage: { [weak self] handle in
      guard let self else { throw CancellationError() }
      return try await self.runtime.requestPreviewImageWithInfo(
        for: CameraGalleryMediaIdentity(
          catalog: previewCatalogIdentity,
          handle: handle,
          variant: .hdPreview
        )
      )
    },
    onPreviewClosed: { [weak self] in
      guard let self else { return }
      self.enqueueHDTransition { [weak self] in
        guard let self else { return }
        await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
        if self.browseMode == .thumbnail {
          self.lastSubmittedThumbnailViewportIdentity = nil
          self.scheduleVisibleThumbnailRefresh(after: 0)
        } else {
          self.runtime.updateGalleryHDPreviewVisibleHandles(self.hdVisibleHandles())
        }
      }
    },
    shouldLoadPreviewThumbnail: { [weak self] in
      NativeGalleryPriorityDownloadPolicy.shouldLoadPreviewThumbnail(
        isDownloading: self?.runtime.isDownloading == true
      )
    },
    cachedThumbnailImageProvider: { [weak self] handle in
      self?.cachedThumbnailImage(for: handle)
    },
    displayStateProvider: { [weak self] handle in
      self?.galleryEntryViewState(for: handle)
    },
    isSelected: { [weak self] handle in
      self?.selectedHandles.contains(handle) ?? false
    },
    downloadStateProvider: { [weak self] handle in
      self?.runtime.downloadState(for: handle) ?? .idle
    },
    onSelectionToggle: { [weak self] item in
      self?.toggleSelection(for: item)
    },
    onDownload: { [weak self] item in
      self?.openDownloadCenter(for: [item.handle])
    },
    isTransferLocked: { [weak self] in
      self?.runtime.isDownloading == true
    },
    onTransferLockedDismissAttempt: { [weak self] in
      self?.showToast("正在下载，暂时不能关闭预览")
    }
  )

  guard let navigationController = self.navigationController else {
    await self.runtime.resumeGalleryContentWorkAfterFullScreenPreview()
    return
  }
  navigationController.pushViewController(controller, animated: true)
}
```

Retain the current selection/download guards inside the injected closures; the snippet above shows the admission and identity wiring, not permission to remove those guards.

In the `.thumbnail` branch of `switchBrowseMode`, clear the previous viewport identity before scheduling the real visible window:

```swift
enqueueHDTransition { [weak self] in
  await self?.runtime.switchGalleryPreviewMode(.thumbnail)
  await MainActor.run { [weak self] in
    self?.lastSubmittedThumbnailViewportIdentity = nil
    self?.scheduleVisibleThumbnailRefresh(after: 0)
  }
}
```

- [ ] **Step 7: Keep filter replacement and mode transitions hard boundaries**

Confirm these existing behaviors remain in production code and tests:

- `CameraGalleryHDPreviewPipeline.activate` cancels and joins the previous worker before installing another Catalog identity.
- `isCurrent(_:)` checks the complete `CameraGalleryCatalogIdentity`, handle membership, and `.hdPreview` variant before publication.
- `deactivate(resumeThumbnailPipeline:)` joins HD work before resuming thumbnail work.
- `CameraGalleryCatalogRuntime` keeps separate Catalog suspension and external/download counters; Catalog install must not clear preview/download suspension.
- `applyCatalogPresentation` clears the old viewport identity, moves the active collection to top, and submits the actual active viewport only after the ready presentation is installed.

Fix the duplicated `previewPublications.append(identity)` in `testHDPreviewPipelineRejectsAnOldCatalogPublication` so each publication is recorded once.

- [ ] **Step 8: Run the focused lifecycle tests and verify GREEN**

Run the command from Step 2 again.

Expected: all 8 tests pass.

- [ ] **Step 9: Commit the lifecycle change**

```bash
git add -p ios/Runner/NativeGalleryViewController.swift ios/Runner/NativePhotoPreviewViewController.swift ios/Runner/CameraCore/Gallery/CameraGalleryHDPreviewPipeline.swift ios/Runner/CameraCore/Gallery/CameraGallerySession.swift ios/Runner/CameraSessionRuntime.swift ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git commit -m "fix(ios): fence gallery preview content work"
```

### Task 6: Run regression, build, install, and camera-backed acceptance

**Files:**
- Modify only if a regression exposes an in-scope defect in the files listed above.

- [ ] **Step 1: Run all focused shared-filter/HD tests together**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionPreservesSharedSectionsAndRepresentsEveryHandle \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionNeverPairsRawAcrossDateSections \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionDoesNotAttachUnmatchedRawInsideOneSection \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDProjectionPairsExtendedStillPlaceholdersInsideOneSection \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryFilterPanelCanExpandInBothBrowseModes \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDModeHasNoIndependentDateOwnerOrPicker \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDCollectionUsesSnapshotSectionsAndSharedHeaders \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryUsesOneFilterSubmissionIndependentOfBrowseMode \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDWindowIsVisibleThenBelowThenNearestAboveAndLimitedToThirty \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHDWindowCrossesDateSectionsWithoutResetting \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineFinishesInflightRequestThenUsesLatestViewport \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHighDefinitionPreviewCacheEvictsWholeLeastRecentlyUsedEntry \
  -only-testing:RunnerTests/RunnerTests/testNativeGalleryHighDefinitionPreviewCacheTouchesVisibleLoadedHandlesInPriorityOrder \
  -only-testing:RunnerTests/RunnerTests/testThumbnailAndHDPreviewCachesNeverShareEntries \
  -only-testing:RunnerTests/RunnerTests/testCameraGallerySessionFullScreenPreviewSuspendsBothContentLoaders \
  -only-testing:RunnerTests/RunnerTests/testNativePhotoPreviewOnlyLoadsHighDefinitionForDisplayedPage \
  -only-testing:RunnerTests/RunnerTests/testFullScreenPreviewUsesCatalogIdentityBoundRequestAndBalancedAdmission \
  -only-testing:RunnerTests/RunnerTests/testCameraGallerySessionStopsOldHDWorkBeforeSubmittingAnotherFilter \
  -only-testing:RunnerTests/RunnerTests/testSwitchingBackToThumbnailClearsViewportIdentityAndResubmitsVisibleWindow \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRejectsAnOldCatalogPublication \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRepeatedActivationBalancesThumbnailSuspensionOnce \
  -only-testing:RunnerTests/RunnerTests/testHDPreviewPipelineRepeatedActivationStaysPausedDuringDownload
```

Expected: 22 tests execute and pass; the result must not report `0 tests`.

- [ ] **Step 2: Run the complete simulator test suite**

```bash
CAMTRANSFER_TEST_RESULT_DIR=$(mktemp -d /private/tmp/camtransfer-shared-filter-tests.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -destination 'platform=iOS Simulator,id=9B0FEEC3-4C3B-4312-B606-876D9076EB0F' \
  -resultBundlePath "$CAMTRANSFER_TEST_RESULT_DIR/RunnerTests.xcresult" \
  | tee "$CAMTRANSFER_TEST_RESULT_DIR/xcodebuild-test.log"
```

Expected: `** TEST SUCCEEDED **` and a non-zero executed test count. Record the exact pass/fail count from the log.

- [ ] **Step 3: Run static and diff checks**

```bash
rg -n "hdActiveDate|hdDateButton|selectHDDateTapped|preferredHDActiveDate|snapshot\(items:.*activeDate" \
  ios/Runner ios/RunnerTests/RunnerTests.swift
rg -n "NativeGalleryHDPreviewSnapshot\(\s*activeDate" ios/Runner ios/RunnerTests/RunnerTests.swift
git diff --check
git status --short --branch
```

Expected: both searches return no matches, `git diff --check` produces no output, and status contains only known WIP plus the scoped implementation.

- [ ] **Step 4: Build a signed iPhoneOS app into an isolated DerivedData directory**

```bash
CAMTRANSFER_DEVICE_BUILD_DIR=$(mktemp -d /private/tmp/camtransfer-shared-filter-device.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project ios/Runner.xcodeproj \
  -scheme Runner \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$CAMTRANSFER_DEVICE_BUILD_DIR"
```

Expected: `** BUILD SUCCEEDED **` and app path `$CAMTRANSFER_DEVICE_BUILD_DIR/Build/Products/Debug-iphoneos/Runner.app`.

- [ ] **Step 5: Install and launch the exact build on the paired iPhone 17**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app \
  --device 952611F0-557B-5C5F-BF1F-265474E9BC4B \
  "$CAMTRANSFER_DEVICE_BUILD_DIR/Build/Products/Debug-iphoneos/Runner.app"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch \
  --console \
  --terminate-existing \
  --device 952611F0-557B-5C5F-BF1F-265474E9BC4B \
  com.camtransfer.app \
  | tee /private/tmp/camtransfer-shared-filter-device-console.log
```

Expected: install succeeds for `com.camtransfer.app`, launch succeeds, and the console remains attached while the camera-backed matrix is performed.

- [ ] **Step 6: Execute the physical-device acceptance matrix on one unchanged camera session**

Perform these actions in order and record section titles, visible handles, and request logs:

1. Select “全部日期”; compare thumbnail and HD section titles, counts, and ordering.
2. Apply JPG, RAW, HEIF, specific date, not-downloaded, newest, and oldest filters; after each filter, compare both modes without reconnecting.
3. Stay in thumbnail mode for 10 seconds without opening a photo; verify no `PTP_PREVIEW_IMAGE_REQUEST` occurs.
4. Open one thumbnail full screen; verify exactly that displayed handle requests HD and adjacent pages do not request until the swipe completes.
5. Enter HD mode around a date boundary; verify `PTP_PREVIEW_IMAGE_REQUEST` follows visible handles, then lower global handles across the next date header, then upper handles.
6. Scroll far enough to retain more than 30 distinct HD images; verify `HD_PREVIEW_CACHE_EVICT` appears and every line reports `retained=30` after the cache first fills.
7. Rapidly switch modes and filters; verify no duplicate in-flight handle sequence, stale generation image, permanent placeholder, or out-of-order restart from the first Catalog item.
8. Start a download while HD or full-screen preview is active; verify preview work stops before download transfer and resumes only after download admission is released.

- [ ] **Step 7: Extract acceptance evidence from the captured console**

```bash
rg -n "PTP_PREVIEW_IMAGE_REQUEST|HD_PREVIEW_CACHE_EVICT|HD_PREVIEW_IMAGE_FAILED|PTP_GET_THUMB_REQUEST|GALLERY_CATALOG_INTENT_SUBMITTED" \
  /private/tmp/camtransfer-shared-filter-device-console.log \
  > /private/tmp/camtransfer-shared-filter-acceptance-evidence.log

awk '/HD_PREVIEW_CACHE_EVICT/ { print }' \
  /private/tmp/camtransfer-shared-filter-acceptance-evidence.log \
  | tail -40
```

Expected: thumbnail-only dwell has no HD request, full-screen requests the displayed handle, HD order crosses date sections, and cache evictions stay at 30 retained entries. Any camera lock, disconnect, or missing interaction must be reported as an unverified acceptance boundary rather than inferred from build/install success.

- [ ] **Step 8: Final scoped commit if verification required fixes**

If verification required an in-scope correction, stage only that correction and its regression test:

```bash
git add -p ios/Runner ios/RunnerTests/RunnerTests.swift
git diff --cached --check
git diff --cached --stat
git commit -m "fix(ios): stabilize shared gallery preview acceptance"
```

If no correction was needed, do not create an empty commit.

## Completion criteria

- Thumbnail and HD modes render the same Catalog membership, section order, and filter result.
- No HD-only date owner or picker remains.
- HD requests are serial and globally ordered visible → below → above, with a latest-viewport pending queue and safe in-flight completion.
- The HD cache has at most 30 complete entries across memory, disk, loaded state, and orientation metadata.
- Thumbnail mode issues no HD fetch except for the displayed full-screen page.
- Mode, filter, disconnect, download, and full-screen transitions balance suspension and reject stale media identities.
- Focused tests, full simulator tests, signed iPhoneOS build, exact-app install/launch, and the camera-backed matrix are reported separately with their actual evidence.
