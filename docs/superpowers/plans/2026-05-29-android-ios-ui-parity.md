# Android iOS UI Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Match Android CamTransfer gallery, connection, and downloads UI to the existing iOS operation model.

**Architecture:** Keep camera transport services unchanged. Add a small UI policy layer for filtering and download selection status, then update Compose screens to consume that policy and render the iOS-style layout.

**Tech Stack:** Kotlin, Jetpack Compose Material 3, Android unit tests, Gradle.

---

### Task 1: Gallery UI Policy

**Files:**
- Create: `app/src/main/java/com/camtransfer/ui/GalleryUiPolicy.kt`
- Create: `app/src/test/java/com/camtransfer/ui/GalleryUiPolicyTest.kt`

- [ ] Add tests covering default JPG/HEIF filtering, date filtering, multi-format filtering, and non-selectable active download states.
- [ ] Implement `GalleryDateFilter`, `GalleryFormatFilter`, `GalleryFilterState`, and `GalleryDownloadUiPolicy`.
- [ ] Run `./gradlew testDebugUnitTest`.

### Task 2: Shared Theme

**Files:**
- Create: `app/src/main/java/com/camtransfer/ui/CamTransferTheme.kt`
- Modify: `app/src/main/java/com/camtransfer/MainActivity.kt`

- [ ] Add warm background, ink, secondary ink, accent, muted fill, and card colors.
- [ ] Wrap the app in the new theme.
- [ ] Run `./gradlew assembleDebug`.

### Task 3: iOS-Style Gallery

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
- Modify: `app/src/main/java/com/camtransfer/MainActivity.kt`

- [ ] Render the brand/header, filter chips, rounded grid tiles, selection circles, status badges, and floating bottom download bar.
- [ ] Start transfers from the gallery and keep the user in the gallery.
- [ ] Add a tray action that opens the download center.
- [ ] Run `./gradlew testDebugUnitTest assembleDebug`.

### Task 4: Download Center Grid

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/TransferScreen.kt`

- [ ] Replace the list cards with a grid-style download center using the same tile language.
- [ ] Show queued/downloading/saving/done/error status and progress.
- [ ] Run `./gradlew testDebugUnitTest assembleDebug`.

### Task 5: Connect Screen Polish

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/ConnectScreen.kt`

- [ ] Match the iOS connection surface: brand label, large title, status card, primary black button, and secondary outline actions.
- [ ] Run `./gradlew testDebugUnitTest assembleDebug`.

### Task 6: Device Verification

**Files:**
- No code changes.

- [ ] Install `app/build/outputs/apk/debug/app-debug.apk` with `adb install -r`.
- [ ] Open gallery, confirm thumbnails render, select images, start download, confirm tile states update, open download center, and confirm files save.
