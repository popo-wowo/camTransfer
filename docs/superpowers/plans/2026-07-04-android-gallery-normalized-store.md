# Android Gallery Normalized Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split Android gallery runtime state so catalog order, metadata, thumbnails, preview images, and transfer state cannot mutate each other.

**Architecture:** The gallery will move toward a normalized session/store/selectors shape. `CatalogStore` owns D621 order and date buckets, `MetadataStore` owns resolved `ObjectInfo`, `ThumbnailStore` owns thumbnail bytes and loading state, `PreviewStore` owns session-only HD preview bytes, and `TransferStore` remains the shared download queue. A future `GallerySessionActor` will be the only PTP request entry for metadata, thumbnails, preview, and download.

**Tech Stack:** Kotlin, Android ViewModel, StateFlow, Jetpack Compose, existing PTP `CameraFileSource`, existing `GalleryRequestScheduler`.

---

## Boundaries

- Do not modify pairing, BLE, Wi-Fi handoff, PTP open-session, or `Connect -> GalleryReady`.
- Do not move `9050 -> D22B -> 9053 -> D620 -> D621` startup logic.
- Do not add protocol fallbacks, sleeps, retries, or SearchMode mutations.
- Each task must compile and be independently revertible.
- UI must not restart gallery startup.

## Target Files

- Create `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailStore.kt`: in-memory thumbnail state keyed by handle.
- Modify `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`: write thumbnail bytes into `GalleryThumbnailStore`.
- Modify `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`: stop treating thumbnail bytes as catalog state.
- Modify `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`: expose `thumbnailsByHandle`.
- Modify `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`: pass thumbnails into grid and derived selected files.
- Modify `app/src/main/java/com/camtransfer/ui/GalleryGrid.kt`: read thumbnail from `thumbnailsByHandle[file.info.handle]`.
- Modify `app/src/main/java/com/camtransfer/ui/GalleryGridItem.kt`: accept thumbnail bytes separately from `CameraFile`.
- Modify `app/src/test/java/com/camtransfer/viewmodel/GalleryFileLoadPolicyTest.kt`: prove thumbnail publish no longer changes catalog metadata/order.
- Modify `app/src/test/java/com/camtransfer/viewmodel/ThumbnailRequestTrackerTest.kt`: prove thumbnail store blocks duplicate requests.
- Modify `docs/android-current-execution-logic.md`: record the normalized store rule.

## Task 1: Independent Thumbnail Store

**Files:**
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailStore.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/GalleryFileLoadPolicyTest.kt`

- [ ] **Step 1: Write the store test**

Add a test proving thumbnail updates are keyed by handle and do not require catalog mutation:

```kotlin
@Test
fun thumbnailStorePublishesByHandleWithoutCatalogMutation() {
    val store = GalleryThumbnailStore()
    val thumb = byteArrayOf(0x01, 0x02)

    store.put(10, thumb)

    assertArrayEquals(thumb, store.thumbnails.value[10])
    assertTrue(store.hasThumbnail(10))
}
```

- [ ] **Step 2: Run the test and verify it fails before implementation**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest.thumbnailStorePublishesByHandleWithoutCatalogMutation
```

Expected: compile failure because `GalleryThumbnailStore` does not exist.

- [ ] **Step 3: Implement `GalleryThumbnailStore`**

Create a focused store:

```kotlin
package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GalleryThumbnailStore {
    private val _thumbnails = MutableStateFlow<Map<Int, ByteArray>>(emptyMap())
    val thumbnails: StateFlow<Map<Int, ByteArray>> = _thumbnails.asStateFlow()

    fun put(handle: Int, thumbnail: ByteArray) {
        _thumbnails.value = _thumbnails.value + (handle to thumbnail)
    }

    fun putAll(updates: Map<Int, ByteArray>) {
        if (updates.isEmpty()) return
        _thumbnails.value = _thumbnails.value + updates
    }

    fun hasThumbnail(handle: Int): Boolean =
        _thumbnails.value.containsKey(handle)

    fun snapshot(): Map<Int, ByteArray> = _thumbnails.value

    fun clear() {
        _thumbnails.value = emptyMap()
    }
}
```

- [ ] **Step 4: Wire controller to store**

Inject `GalleryThumbnailStore` into `GalleryThumbnailController`. On disk hit and camera thumbnail success, call `thumbnailStore.put(handle, data)` before any UI publish. Keep old `filesController.mergeThumbnail(...)` only as a temporary compatibility call until Task 2 removes UI dependence.

- [ ] **Step 5: Expose thumbnails from ViewModel**

In `BrowseViewModel`, create `private val thumbnailStore = GalleryThumbnailStore()`, pass it to `GalleryThumbnailController`, and expose `val thumbnailsByHandle = thumbnailStore.thumbnails`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Task 2: UI Reads Thumbnails From Store

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryGrid.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryGridItem.kt`
- Test: `app/src/test/java/com/camtransfer/ui/GalleryUiPolicyTest.kt`

- [ ] **Step 1: Add UI policy test**

Add a pure policy test that a thumbnail lookup by handle does not require changing `CameraFile.thumbnail`:

```kotlin
@Test
fun thumbnailDisplayBytesPreferStoreThumbnailByHandle() {
    val file = cameraFile(handle = 10, thumbnail = null)
    val thumbnail = byteArrayOf(0x01)

    assertArrayEquals(
        thumbnail,
        GalleryThumbnailDisplayPolicy.thumbnailFor(file, mapOf(10 to thumbnail)),
    )
}
```

- [ ] **Step 2: Add policy function**

Add to `GalleryUiPolicy.kt`:

```kotlin
object GalleryThumbnailDisplayPolicy {
    fun thumbnailFor(file: CameraFile, thumbnailsByHandle: Map<Int, ByteArray>): ByteArray? =
        thumbnailsByHandle[file.info.handle] ?: file.thumbnail
}
```

- [ ] **Step 3: Collect thumbnail state in `BrowseScreen`**

Add:

```kotlin
val thumbnailsByHandle by viewModel.thumbnailsByHandle.collectAsState()
```

Pass it through `GalleryGrid`.

- [ ] **Step 4: Render grid item from external thumbnail**

Change `GalleryGrid` and `GalleryGridItem` to pass a `thumbnail: ByteArray?` argument. `GalleryGridItem` should render that argument instead of reading `file.thumbnail` directly.

- [ ] **Step 5: Run UI tests and compile**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.ui.GalleryUiPolicyTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Task 3: Stop Thumbnail Updates From Mutating Catalog

**Files:**
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/GalleryFileLoadPolicyTest.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/ThumbnailRequestTrackerTest.kt`

- [ ] **Step 1: Add catalog immutability test**

Add a test proving `GalleryThumbnailPublishPolicy` is no longer required by the thumbnail path:

```kotlin
@Test
fun thumbnailAvailabilityCanComeFromStoreWithoutChangingFiles() {
    val files = listOf(cameraFile(handle = 10, filename = "0x0000000A"))
    val store = GalleryThumbnailStore()

    store.put(10, byteArrayOf(0x01))

    assertEquals("0x0000000A", files.single().info.filename)
    assertTrue(store.hasThumbnail(10))
}
```

- [ ] **Step 2: Change `GalleryFilesController.hasThumbnail`**

Make `GalleryFilesController` accept a `hasCachedThumbnail: (Int) -> Boolean` provider or remove the method entirely after `GalleryThumbnailController` consults `GalleryThumbnailStore`.

- [ ] **Step 3: Remove thumbnail merge call from controller**

In `GalleryThumbnailController.loadThumbnailNow`, remove `filesController.mergeThumbnail(...)` calls once Task 2 UI rendering is reading from `ThumbnailStore`.

- [ ] **Step 4: Keep metadata merge separate**

Do not remove ObjectInfo metadata merge yet. That belongs to Task 4.

- [ ] **Step 5: Run focused tests**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest --tests com.camtransfer.viewmodel.ThumbnailRequestTrackerTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Task 4: Metadata Store And D621 Stable Order

**Files:**
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryMetadataStore.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryUiPolicy.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/GalleryFileLoadPolicyTest.kt`

- [ ] **Step 1: Add D621 order test**

Add a test proving ObjectInfo resolution updates metadata but preserves input order:

```kotlin
@Test
fun metadataResolutionPreservesCatalogOrder() {
    val ordered = listOf(1267, 1268, 1265, 1266)
    val resolved = mapOf(1268 to cameraFile(handle = 1268, filename = "DSCF1268.RAF"))

    val result = GalleryCatalogMergePolicy.mergeMetadataPreservingOrder(ordered, resolved)

    assertEquals(ordered, result.map { it.info.handle })
}
```

- [ ] **Step 2: Introduce metadata store**

Create a store keyed by handle:

```kotlin
class GalleryMetadataStore {
    private val _objectInfoByHandle = MutableStateFlow<Map<Int, ObjectInfo>>(emptyMap())
    val objectInfoByHandle: StateFlow<Map<Int, ObjectInfo>> = _objectInfoByHandle.asStateFlow()

    fun put(file: CameraFile) {
        _objectInfoByHandle.value = _objectInfoByHandle.value + (file.info.handle to file.info)
    }

    fun putAll(files: List<CameraFile>) {
        if (files.isEmpty()) return
        _objectInfoByHandle.value = _objectInfoByHandle.value + files.associate { it.info.handle to it.info }
    }
}
```

- [ ] **Step 3: Stop metadata batch from sorting catalog**

Keep `GalleryFilesController.files` ordered by the placeholder D621 list. Metadata completion should update the metadata store and derived UI, not publish a newly sorted list.

- [ ] **Step 4: Run tests**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Task 5: Extended Still Candidate Format

**Files:**
- Modify: `app/src/main/java/com/camtransfer/model/CameraFile.kt`
- Modify: `app/src/main/java/com/camtransfer/service/gallery/PtpCameraGallerySource.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryUiPolicy.kt`
- Test: `app/src/test/java/com/camtransfer/ui/GalleryUiPolicyTest.kt`

- [ ] **Step 1: Add candidate hint**

Add `EXTENDED_STILL_CANDIDATE` to `CameraFileFormatHint`.

- [ ] **Step 2: Change D604 extended handle hints**

In `PtpCameraGallerySource.formatHintsByHandle`, mark baseline-extra still handles as `EXTENDED_STILL_CANDIDATE`, not both `HEIF` and `RAW`.

- [ ] **Step 3: Filter behavior**

For unresolved files, HEIF and RAW filters include `EXTENDED_STILL_CANDIDATE`. Counts should expose confirmed and candidate counts separately in a later UI task; for this task, do not hide candidates.

- [ ] **Step 4: Run tests**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.ui.GalleryUiPolicyTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Task 6: Gallery Session Actor

**Files:**
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/GallerySessionActor.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryRequestScheduler.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryThumbnailController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryFilesController.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/gallery/GallerySessionActorTest.kt`

- [ ] **Step 1: Add actor ordering test**

Write tests that enqueue download, preview, thumbnail, and metadata requests and assert execution order is download, preview, visible thumbnail, metadata.

- [ ] **Step 2: Route non-download gallery requests**

Move thumbnail, preview, and metadata calls through actor APIs while keeping `GalleryRequestScheduler` as the priority implementation detail.

- [ ] **Step 3: Route download exclusive mode**

Before download starts, actor enters transfer-exclusive state. Thumbnail, metadata, and preview requests are rejected or postponed until download exits.

- [ ] **Step 4: Run full gallery risk tests**

Run:

```bash
./gradlew --no-daemon testDebugUnitTest --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest --tests com.camtransfer.viewmodel.ThumbnailRequestTrackerTest --tests com.camtransfer.ui.GalleryUiPolicyTest compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

## Verification Before Device Install

Run after each committed phase:

```bash
./gradlew --no-daemon testDebugUnitTest \
  --tests com.camtransfer.service.AppCacheUsagePolicyTest \
  --tests com.camtransfer.service.DownloadedFileStoreTest \
  --tests com.camtransfer.viewmodel.GalleryFileLoadPolicyTest \
  --tests com.camtransfer.viewmodel.ThumbnailRequestTrackerTest \
  --tests com.camtransfer.ui.GalleryUiPolicyTest \
  compileDebugKotlin && git diff --check
```

Then install only after tests pass:

```bash
./gradlew --no-daemon installDebug
```
