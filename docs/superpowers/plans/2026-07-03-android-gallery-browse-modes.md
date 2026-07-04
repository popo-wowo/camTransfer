# Android Gallery Browse Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split post-entry gallery browsing into isolated thumbnail and HD-preview modes, while keeping the pairing/connection/gallery-entry mainline unchanged and making download exclusive over all other camera reads.

**Architecture:** Keep `Connect -> GalleryReady` exactly as the recovered Android mainline and move all mode behavior under gallery controllers/viewmodels/UI only. Add a small browse-mode/session layer that coordinates existing file, thumbnail, preview, and transfer modules through a single serial scheduler and explicit pause/resume rules.

**Tech Stack:** Android Kotlin, Jetpack Compose, Kotlin coroutines/StateFlow, JUnit, Gradle.

---

## File Structure

- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryBrowseModeController.kt`
  - Own current browse mode, current HD date, and mode-switch state that does not reconnect.
- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/HighDefinitionPreviewSession.kt`
  - Own the active date, sequential preview queue, loaded/failed/queued handles, and transfer-wait bookkeeping for HD mode.
- Modify `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewController.kt`
  - Extend from single pending file to sequential session-driven preview loading with pause/resume and “wait current read before transfer” semantics.
- Modify `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`
  - Keep visible thumbnail logic, but expose state/methods needed for full transfer exclusivity and mode-safe pause/resume.
- Modify `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
  - Keep placeholders/full metadata/hidden-format discovery, but ensure transfer exclusivity remains explicit and resumable.
- Modify `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`
  - Become the gallery-mode coordinator across files, thumbnails, preview session, and transfer callbacks.
- Modify `app/src/main/java/com/camtransfer/viewmodel/TransferViewModel.kt`
  - Accept a pre-transfer gate so download starts only after current HD preview read finishes.
- Modify `app/src/main/java/com/camtransfer/MainActivity.kt`
  - Route gallery download requests through the new pre-transfer gating path without changing connection setup.
- Modify `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
  - Add in-gallery mode switch and route body between thumbnail mode and HD-preview mode.
- Modify `app/src/main/java/com/camtransfer/ui/HighDefinitionPreviewScreen.kt`
  - Show one-column, one-date, sequential HD cards with per-card download and fullscreen only from loaded HD bytes.
- Modify `app/src/main/java/com/camtransfer/ui/GalleryPreviewDialog.kt`
  - Reuse already-loaded HD bytes when available and avoid hidden fallback loads in HD mode.
- Modify/add tests:
  - `app/src/test/java/com/camtransfer/viewmodel/GalleryBrowseModeControllerTest.kt`
  - `app/src/test/java/com/camtransfer/viewmodel/GalleryPreviewControllerTest.kt`
  - `app/src/test/java/com/camtransfer/viewmodel/GalleryThumbnailControllerTest.kt`
  - `app/src/test/java/com/camtransfer/viewmodel/BrowseViewModelTest.kt`
  - `app/src/test/java/com/camtransfer/ui/GalleryUiPolicyTest.kt`

## Tasks

### Task 1: Lock the browse-mode boundary before code changes

**Files:**
- Create: `app/src/test/java/com/camtransfer/viewmodel/GalleryBrowseModeControllerTest.kt`
- Modify: `app/src/test/java/com/camtransfer/viewmodel/GalleryModularArchitectureTest.kt`

- [ ] Add a boundary test that asserts browse-mode state lives under `viewmodel/gallery` and not under connection modules or `CameraService`.
- [ ] Extend the architecture test to assert `BrowseViewModel` coordinates `GalleryBrowseModeController` and `HighDefinitionPreviewSession`.
- [ ] Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryModularArchitectureTest`
- [ ] Confirm the new assertions fail before implementation.
- [ ] Commit after the boundary test lands.

### Task 2: Add browse-mode state and HD session model

**Files:**
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryBrowseModeController.kt`
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/HighDefinitionPreviewSession.kt`
- Create: `app/src/test/java/com/camtransfer/viewmodel/GalleryBrowseModeControllerTest.kt`

- [ ] Write tests for:
  - default mode is thumbnail
  - switching modes does not imply reconnect
  - HD mode default date is today
  - switching date replaces the queued HD session but keeps loaded cache bookkeeping separate
- [ ] Implement `GalleryBrowseMode`, `GalleryBrowseModeState`, and `GalleryBrowseModeController`.
- [ ] Implement `HighDefinitionPreviewSession` with:
  - active date
  - ordered candidate handles/files for that date
  - current sequential index
  - queued download handles
  - paused-for-transfer flag
  - completed/failed handle tracking
- [ ] Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryBrowseModeControllerTest`
- [ ] Commit the browse-mode/session layer.

### Task 3: Convert HD preview loading to sequential session control

**Files:**
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewController.kt`
- Create: `app/src/test/java/com/camtransfer/viewmodel/GalleryPreviewControllerTest.kt`

- [ ] Add tests for:
  - only one preview read runs at a time
  - the next preview does not start until the previous one completes
  - starting transfer while one preview is active waits for the current read and then pauses the remaining session
  - failed preview marks the item and advances to the next candidate
  - switching dates rebuilds the queue without dropping already cached preview bytes
- [ ] Replace the single `pendingPreviewFile` model with session-driven sequential loading.
- [ ] Expose controller APIs for:
  - `startSession(cameraSource, session)`
  - `switchSession(cameraSource, session)`
  - `pauseForTransfer(cameraSource)`
  - `resumeAfterTransfer(cameraSource)`
  - `awaitIdleOrCurrentReadComplete()`
- [ ] Keep the preview cache keyed by handle and reuse it across date switches.
- [ ] Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryPreviewControllerTest`
- [ ] Commit the sequential preview controller.

### Task 4: Make transfer exclusive over thumbnails, metadata, and previews

**Files:**
- Modify: `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/TransferViewModel.kt`
- Modify: `app/src/main/java/com/camtransfer/MainActivity.kt`
- Create: `app/src/test/java/com/camtransfer/viewmodel/BrowseViewModelTest.kt`
- Create: `app/src/test/java/com/camtransfer/viewmodel/GalleryThumbnailControllerTest.kt`

- [ ] Add tests for:
  - transfer preparation pauses `GalleryFilesController`, `GalleryThumbnailController`, and `GalleryPreviewController`
  - when transfer starts from HD mode, the current preview read is allowed to finish before the queue begins
  - no thumbnail requests are accepted while transfer exclusive pause is active
  - resume only happens after the transfer queue reports finished
- [ ] Add a `BrowseViewModel` API that prepares exclusive transfer based on current mode and returns only when it is safe to start the queue.
- [ ] Update `TransferViewModel.startTransfer(...)` to accept an optional suspending `beforeStart` gate or equivalent explicit preflight.
- [ ] Change `MainActivity` browse download entry to:
  - call `browseVM.prepare...`
  - then call `transferVM.startTransfer(...)`
  - rely on `isTransferring` completion to resume the correct mode
- [ ] Ensure no connection-mainline types are modified.
- [ ] Run:
  - `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.BrowseViewModelTest`
  - `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryThumbnailControllerTest`
- [ ] Commit the transfer exclusivity work.

### Task 5: Wire the in-gallery mode switch and HD-preview UI

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/HighDefinitionPreviewScreen.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryPreviewDialog.kt`
- Modify: `app/src/test/java/com/camtransfer/ui/GalleryUiPolicyTest.kt`

- [ ] Add UI policy tests for:
  - mode switch labels/state
  - HD mode defaults to today
  - HD mode renders as one column
  - fullscreen is disabled until `previewImages[handle]` exists
- [ ] In `BrowseScreen`, add a top-level mode toggle inside gallery only; do not navigate out to another connection route.
- [ ] Keep thumbnail mode behavior unchanged except that transfer now freezes all gallery background work.
- [ ] Update `HighDefinitionPreviewScreen` to:
  - read only files for the active date
  - render one card per row
  - show per-card download action
  - request fullscreen only from already-loaded HD bytes
  - avoid requesting thumbnails when in HD mode
- [ ] Update preview dialog/fullscreen path to reuse cached HD preview bytes instead of triggering new thumbnail-based fetches.
- [ ] Run: `./gradlew testDebugUnitTest --tests com.camtransfer.ui.GalleryUiPolicyTest`
- [ ] Commit the browse-mode UI.

### Task 6: Full verification and Android install

**Files:**
- Verify only

- [ ] Run `./gradlew testDebugUnitTest`
- [ ] Run `./gradlew assembleDebug`
- [ ] Install to device: `./gradlew installDebug`
- [ ] Smoke-check on Android:
  - enter gallery without reconnect
  - switch thumbnail/HD modes
  - start a download in thumbnail mode and confirm thumbnail work pauses
  - start a download in HD mode and confirm current preview finishes first, then queue starts
  - return after download and confirm the active mode resumes
- [ ] Update docs if implementation details drifted from the current spec.
