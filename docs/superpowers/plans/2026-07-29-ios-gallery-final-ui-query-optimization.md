# iOS Gallery Final UI and Query Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove repeat same-session Catalog PTP queries, atomically synchronize Gallery render sections with Runtime presentation, and expose only one date selector in HD mode.

**Architecture:** `CameraCatalogQueryEngine` owns a session-scoped membership cache keyed only by format selection and reprojects date/download scope per resolve. `NativeGalleryRenderState` atomically owns the immutable presentation plus derived sections while selection remains controller-local. HD mode keeps its fixed-session date button and disables filter expansion.

**Tech Stack:** Swift 5, UIKit, Swift concurrency actors, XCTest, Xcodebuild.

---

### Task 1: Cache Catalog membership inside QueryEngine

**Files:**
- Modify: `ios/Runner/CameraCore/Gallery/CameraCatalogQueryEngine.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add a failing test resolving the same format selection twice with different date/download projections and assert the source Catalog request count remains one.
- [ ] Add a failing test resolving two different format selections and assert each required source query executes.
- [ ] Run the two focused tests and confirm the same-plan test fails because the source count is two.
- [ ] Add a private Hashable cache key and cache membership items in `CameraCatalogQueryEngine`.
- [ ] Check the cache before gate acquisition and again after acquisition; build each result with the current rule and downloaded handles.
- [ ] Clear cached memberships in `invalidate()`.
- [ ] Run the focused tests and the existing QueryEngine/filter tests.

### Task 2: Introduce atomic NativeGalleryRenderState

**Files:**
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Modify: `ios/Runner/NativeGalleryViewController.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Add a failing test proving a non-structural incremental presentation updates item content inside existing sections without changing section identity.
- [ ] Add a failing test proving an identical full presentation produces no replacement render state.
- [ ] Run both focused tests and confirm failure because `NativeGalleryRenderState` does not exist.
- [ ] Implement immutable `NativeGalleryRenderState` with full replacement and incremental-application APIs.
- [ ] Replace writable `catalogPresentation` and `gallerySections` fields with one render-state field and read-only computed projections.
- [ ] Update full and incremental observers to install render state atomically; skip full reload for identical presentation.
- [ ] Run render-state, selection, section, thumbnail incremental-update, and empty-state tests.

### Task 3: Remove duplicate HD date interaction

**Files:**
- Modify: `ios/Runner/NativeGalleryPolicies.swift`
- Test: `ios/RunnerTests/RunnerTests.swift`

- [ ] Correct the existing HD filter expansion test to expect `false` in `.highDefinition` and `true` in `.thumbnail`.
- [ ] Run the focused test and confirm it fails against the current always-true policy.
- [ ] Make `canExpandFilters(mode:)` return true only for thumbnail mode.
- [ ] Run the focused HD chrome and HD date-session tests.

### Task 4: Verification

**Files:**
- Verify only; no new production scope.

- [ ] Run all focused tests from Tasks 1-3.
- [ ] Run adjacent quick-download, Catalog generation, filter persistence, thumbnail incremental publication, Gallery ownership, selection, and HD pipeline tests.
- [ ] Run `git diff --check`.
- [ ] Build the current worktree for the paired physical iPhone with a fresh DerivedData directory.
- [ ] Install, verify the installed app record, and launch it.
- [ ] Report real-camera interaction separately; do not claim live PTP speed or UI acceptance until the camera is connected and exercised.
