# Gallery Modular Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split gallery UI and camera-read behavior into independent modules so thumbnail loading, preview/original display, selection, filtering, and download coordination can evolve without affecting connection.

**Architecture:** Keep the stable pairing/connection code unchanged. Extract gallery file loading, thumbnail loading, preview loading, selection, request scheduling, image decoding, grid UI, preview UI, filter UI, and download bar UI into focused files. `BrowseViewModel` becomes a coordinator over controllers; UI emits intents and never talks to PTP/connection internals.

**Tech Stack:** Android Kotlin, Jetpack Compose, Kotlin coroutines, JUnit, Gradle.

---

## File Structure

- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryRequestScheduler.kt`
  - Owns request priority and serial execution policy for gallery camera reads.
- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
  - Owns initial placeholders, full ObjectInfo loading, and file list merge policy.
- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`
  - Owns thumbnail queue, thumbnail cache, visible/preview thumbnail request policy, and pause/resume.
- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewController.kt`
  - Owns preview image request policy, cache, and pending preview replacement.
- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GallerySelectionController.kt`
  - Owns selected handle set and selection mutations.
- Modify `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`
  - Delegate to controllers and keep public API stable for current UI.
- Create focused UI files in `app/src/main/java/com/camtransfer/ui/`
  - `GalleryHeader.kt`
  - `GalleryFilterPanel.kt`
  - `GalleryGestures.kt`
  - `GalleryGrid.kt`
  - `GalleryGridItem.kt`
  - `GalleryDownloadBar.kt`
  - `GalleryPreviewDialog.kt`
  - `GalleryImageDecode.kt`
  - `GalleryDialogs.kt`
- Modify `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
  - Keep only route-level state collection and component composition.
- Add/modify tests under `app/src/test/java/com/camtransfer/viewmodel/` and `app/src/test/java/com/camtransfer/service/`
  - Assert gallery modules exist and boundaries stay clean.
  - Assert request priorities keep download/preview above background thumbnails.
  - Assert old thumbnail/file-load policies still behave.

## Tasks

### Task 1: Lock Gallery Module Boundaries

- [ ] Add a test that asserts the gallery controller files exist.
- [ ] Add a test that asserts `BrowseViewModel` references controllers and does not define `ThumbnailLoadQueue`.
- [ ] Add a test that asserts UI gallery files do not import `PtpCommands`, `PtpConnection`, BLE, Wi-Fi, or connection modules.
- [ ] Run the boundary tests and confirm they fail before production changes.

### Task 2: Add Request Scheduler

- [ ] Add `GalleryRequestPriority` with explicit order: download, preview, visible thumbnail, preview-neighbor thumbnail, background metadata.
- [ ] Add `GalleryRequestScheduler` with a single `run(priority, block)` entrypoint.
- [ ] Add tests proving priority order values and serial execution policy are explicit.

### Task 3: Extract ViewModel Controllers

- [ ] Move file loading policy and file-list work into `GalleryFilesController`.
- [ ] Move `ThumbnailLoadQueue`, thumbnail cache, worker policy, and pause/resume logic into `GalleryThumbnailController`.
- [ ] Move preview cache and pending preview loading into `GalleryPreviewController`.
- [ ] Move selection mutations into `GallerySelectionController`.
- [ ] Keep `BrowseViewModel` public methods stable for UI.
- [ ] Run existing viewmodel tests.

### Task 4: Split Compose UI Files

- [ ] Move header composables to `GalleryHeader.kt`.
- [ ] Move filter panel/date chip composables to `GalleryFilterPanel.kt`.
- [ ] Move grid gesture modifiers to `GalleryGestures.kt`.
- [ ] Move grid container to `GalleryGrid.kt`.
- [ ] Move grid item/badges/placeholder to `GalleryGridItem.kt`.
- [ ] Move bottom bar to `GalleryDownloadBar.kt`.
- [ ] Move preview dialog/zoomable preview to `GalleryPreviewDialog.kt`.
- [ ] Move bitmap decode/rotation helpers to `GalleryImageDecode.kt`.
- [ ] Move date/disconnect dialogs to `GalleryDialogs.kt`.
- [ ] Keep `BrowseScreen.kt` as the route.

### Task 5: Verify

- [ ] Run `./gradlew testDebugUnitTest`.
- [ ] Run `./gradlew assembleDebug`.
- [ ] Inspect changed files and confirm connection modules were not behaviorally edited.
