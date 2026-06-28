# Android 高清预览模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Android高清预览模式 that sequentially loads clear screen previews while pausing downloads, thumbnails, and background metadata until the user exits or previews finish.

**Architecture:** Keep the existing `BrowseViewModel` controller split. Add a small preview-mode state controller, extend `GalleryPreviewController` from single-current-preview loading to ordered queue loading, and gate `TransferService.startTransfer()` behind a shared preview-mode gate. PTP reads continue through `GalleryRequestScheduler` so only one camera read runs at a time.

**Tech Stack:** Kotlin, Android Compose, coroutines/Flow, Gradle unit tests.

---

### Task 1: Preview Mode State And Queue Policy

**Files:**
- Create: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewModeController.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/gallery/GalleryPreviewModeControllerTest.kt`

- [ ] **Step 1: Write failing tests**

```kotlin
package com.camtransfer.viewmodel.gallery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GalleryPreviewModeControllerTest {
    @Test
    fun beginPreviewModeBuildsCurrentFirstThenForwardQueue() {
        val controller = GalleryPreviewModeController()

        controller.begin(
            orderedHandles = listOf(10, 11, 12, 13),
            currentHandle = 11,
            alreadyLoadedHandles = emptySet(),
        )

        assertTrue(controller.isActive.value)
        assertEquals(listOf(11, 12, 13), controller.pendingHandles.value)
    }

    @Test
    fun currentHandleIsPromotedWhenUserJumpsForward() {
        val controller = GalleryPreviewModeController()
        controller.begin(listOf(10, 11, 12, 13), currentHandle = 10, alreadyLoadedHandles = emptySet())

        controller.promoteCurrentHandle(12, alreadyLoadedHandles = emptySet())

        assertEquals(listOf(12, 10, 11, 13), controller.pendingHandles.value)
    }

    @Test
    fun completedHandlesAreRemovedAndPreviewModeCanFinish() {
        val controller = GalleryPreviewModeController()
        controller.begin(listOf(10, 11), currentHandle = 10, alreadyLoadedHandles = emptySet())

        controller.markLoaded(10)
        controller.markLoaded(11)

        assertEquals(emptyList<Int>(), controller.pendingHandles.value)
        assertFalse(controller.hasPendingPreviews.value)
    }

    @Test
    fun stopClearsActiveQueue() {
        val controller = GalleryPreviewModeController()
        controller.begin(listOf(10, 11), currentHandle = 10, alreadyLoadedHandles = emptySet())

        controller.stop()

        assertFalse(controller.isActive.value)
        assertEquals(emptyList<Int>(), controller.pendingHandles.value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.gallery.GalleryPreviewModeControllerTest`

Expected: compilation failure because `GalleryPreviewModeController` does not exist.

- [ ] **Step 3: Implement controller**

Create `GalleryPreviewModeController` with:

```kotlin
class GalleryPreviewModeController {
    private val _isActive = MutableStateFlow(false)
    val isActive: StateFlow<Boolean> = _isActive.asStateFlow()

    private val _pendingHandles = MutableStateFlow<List<Int>>(emptyList())
    val pendingHandles: StateFlow<List<Int>> = _pendingHandles.asStateFlow()

    private val _hasPendingPreviews = MutableStateFlow(false)
    val hasPendingPreviews: StateFlow<Boolean> = _hasPendingPreviews.asStateFlow()

    fun begin(orderedHandles: List<Int>, currentHandle: Int, alreadyLoadedHandles: Set<Int>)
    fun promoteCurrentHandle(currentHandle: Int, alreadyLoadedHandles: Set<Int>)
    fun markLoaded(handle: Int)
    fun stop()
}
```

Use current-first, then forward handles, then backward handles. Filter `alreadyLoadedHandles` from the queue. Update `_hasPendingPreviews` every time `_pendingHandles` changes.

- [ ] **Step 4: Run test to verify it passes**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.gallery.GalleryPreviewModeControllerTest`

Expected: pass.

### Task 2: Transfer Pause Gate

**Files:**
- Create: `app/src/main/java/com/camtransfer/service/TransferStartGate.kt`
- Modify: `app/src/main/java/com/camtransfer/service/TransferService.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/TransferViewModel.kt`
- Test: `app/src/test/java/com/camtransfer/service/TransferStartGateTest.kt`

- [ ] **Step 1: Write failing tests**

```kotlin
package com.camtransfer.service

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TransferStartGateTest {
    @Test
    fun awaitOpenBlocksWhilePausedThenContinuesAfterResume() = runTest {
        val gate = TransferStartGate()
        gate.pause("preview")

        var continued = false
        val waiter = async {
            gate.awaitOpen()
            continued = true
        }
        delay(1)

        assertFalse(continued)
        gate.resume("preview")
        waiter.await()
        assertTrue(continued)
    }

    @Test
    fun nestedPauseRequiresMatchingResume() = runTest {
        val gate = TransferStartGate()
        gate.pause("preview")
        gate.pause("other")

        gate.resume("preview")

        assertTrue(gate.isPaused.value)
        gate.resume("other")
        assertFalse(gate.isPaused.value)
        assertEquals(0, gate.pauseCount.value)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.service.TransferStartGateTest`

Expected: compilation failure because `TransferStartGate` does not exist.

- [ ] **Step 3: Implement gate and wire service**

Create `TransferStartGate` using `MutableStateFlow<Int>` plus `awaitOpen()` that waits until pause count is zero.

Update `TransferService` constructor:

```kotlin
private val transferStartGate: TransferStartGate = TransferStartGate()
```

At the top of `startTransfer()` after pending-item check and before setting `_isTransferring = true`, call:

```kotlin
transferStartGate.awaitOpen()
```

Expose the same gate through `TransferViewModel` so `BrowseScreen` can pause and resume downloads while preview mode is active.

- [ ] **Step 4: Run focused tests**

Run:

```bash
./gradlew testDebugUnitTest \
  --tests com.camtransfer.service.TransferStartGateTest \
  --tests com.camtransfer.service.CameraModuleBoundaryTest
```

Expected: pass.

### Task 3: Sequential Preview Loading

**Files:**
- Modify: `app/src/main/java/com/camtransfer/viewmodel/gallery/GalleryPreviewController.kt`
- Modify: `app/src/main/java/com/camtransfer/viewmodel/BrowseViewModel.kt`
- Test: `app/src/test/java/com/camtransfer/viewmodel/gallery/GalleryPreviewFullImageLoadPolicyTest.kt`

- [ ] **Step 1: Write policy tests**

```kotlin
package com.camtransfer.viewmodel.gallery

import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GalleryPreviewFullImageLoadPolicyTest {
    @Test
    fun jpegAndHeifCanRequestFullPreviewWhenNotCached() {
        assertTrue(GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(file(format = 0x3801), false))
        assertTrue(GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(file(format = 0x3812), false))
    }

    @Test
    fun cachedOrUnsupportedFilesDoNotRequestFullPreview() {
        assertFalse(GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(file(format = 0x3801), true))
        assertFalse(GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(file(format = 0xB101), false))
    }

    private fun file(format: Int): CameraFile = CameraFile(
        ObjectInfo(
            handle = 1,
            storageId = 0,
            format = format,
            compressedSize = 100,
            thumbFormat = 0,
            thumbCompressedSize = 0,
            thumbPixWidth = 0,
            thumbPixHeight = 0,
            imagePixWidth = 0,
            imagePixHeight = 0,
            parentObject = 0,
            filename = "test",
            captureDate = "",
        )
    )
}
```

- [ ] **Step 2: Run test to verify current policy passes or expose missing coverage**

Run: `./gradlew testDebugUnitTest --tests com.camtransfer.viewmodel.gallery.GalleryPreviewFullImageLoadPolicyTest`

Expected: pass if policy already matches; keep as regression coverage.

- [ ] **Step 3: Extend controller API**

Add methods:

```kotlin
fun beginSequentialPreviewMode(cameraSource: CameraFileSource, files: List<CameraFile>, currentFile: CameraFile)
fun updateSequentialPreviewFocus(cameraSource: CameraFileSource, files: List<CameraFile>, currentFile: CameraFile)
fun stopSequentialPreviewMode(cameraSource: CameraFileSource)
fun cachedPreviewHandles(): Set<Int>
```

Reuse existing `loadPreviewImageNow`. When sequential mode is active, drain pending handles one by one. Keep `MAX_CACHED_PREVIEW_IMAGES = 30`.

- [ ] **Step 4: Wire `BrowseViewModel`**

Expose:

```kotlin
val isHighDefinitionPreviewMode: StateFlow<Boolean>
val pendingHighDefinitionPreviewHandles: StateFlow<List<Int>>
fun beginHighDefinitionPreviewMode(cameraSource: CameraFileSource, files: List<CameraFile>, currentFile: CameraFile)
fun updateHighDefinitionPreviewFocus(cameraSource: CameraFileSource, files: List<CameraFile>, currentFile: CameraFile)
fun stopHighDefinitionPreviewMode(cameraSource: CameraFileSource)
fun cachedPreviewHandles(): Set<Int>
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
./gradlew testDebugUnitTest \
  --tests com.camtransfer.viewmodel.gallery.GalleryPreviewFullImageLoadPolicyTest \
  --tests com.camtransfer.viewmodel.gallery.GalleryPreviewModeControllerTest
```

Expected: pass.

### Task 4: Original-Like Screen Preview Protocol

**Files:**
- Modify: `app/src/main/java/com/camtransfer/protocol/PtpCommands.kt`
- Modify: `app/src/test/java/com/camtransfer/service/CameraModuleBoundaryTest.kt`

- [ ] **Step 1: Add source-boundary test**

Add a test that asserts `getPreviewImage` contains:

```kotlin
setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, 1)
setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, 0)
getObjectInfo(handle)
getPartialObject(handle, 0, previewSize)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./gradlew testDebugUnitTest --tests "*Ptp*Boundary*"`

Expected: fail because current preview path does not set `D226`.

- [ ] **Step 3: Implement D226 preview path**

In `PtpCommands.getPreviewImage(handle)`:

- set `IMAGE_FORCE_COMPRESSION` to `1`
- read fresh `ObjectInfo`
- use fresh `compressedSize` with a max safety cap
- read partial object
- validate image data and complete JPEG
- reset `IMAGE_FORCE_COMPRESSION` to `0` in `finally`
- log messages starting with `Preview image D226 handle=`

- [ ] **Step 4: Run focused protocol tests**

Run: `./gradlew testDebugUnitTest --tests "*Ptp*Boundary*" --tests com.camtransfer.service.CameraModuleBoundaryTest`

Expected: pass.

### Task 5: Compose Wiring And Download Deferral

**Files:**
- Modify: `app/src/main/java/com/camtransfer/ui/BrowseScreen.kt`
- Modify: `app/src/main/java/com/camtransfer/ui/GalleryPreviewDialog.kt`
- Modify: `app/src/main/java/com/camtransfer/MainActivity.kt`

- [ ] **Step 1: Add preview-mode UI state wiring**

In `BrowseScreen`, collect preview-mode state and pass it into `PhotoPreviewDialog`.

When dialog opens:

```kotlin
viewModel.beginHighDefinitionPreviewMode(cameraSource, sortedFiles, file)
transferVM.pauseForHighDefinitionPreview()
```

When current page changes:

```kotlin
viewModel.updateHighDefinitionPreviewFocus(cameraSource, sortedFiles, currentFile)
```

When dialog closes:

```kotlin
viewModel.stopHighDefinitionPreviewMode(cameraSource)
transferVM.resumeAfterHighDefinitionPreview()
previewFile = null
```

- [ ] **Step 2: Adjust dialog text**

Show status text:

```text
高清预览中 · 下载将在退出后开始
```

When download is tapped in preview mode, enqueue only. Existing `onDownloadSelected(listOf(currentFile))` can remain because `TransferService` is paused by the gate.

- [ ] **Step 3: Stop thumbnail preloading inside preview mode**

Skip `onPreviewVisible(previewThumbnailHandles)` when高清预览模式 is active, because the mode is loading screen previews instead.

- [ ] **Step 4: Compile**

Run: `./gradlew compileDebugKotlin`

Expected: pass.

### Task 6: Verification

**Files:**
- All touched Android files

- [ ] **Step 1: Run focused unit tests**

Run:

```bash
./gradlew testDebugUnitTest \
  --tests com.camtransfer.viewmodel.gallery.GalleryPreviewModeControllerTest \
  --tests com.camtransfer.viewmodel.gallery.GalleryPreviewFullImageLoadPolicyTest \
  --tests com.camtransfer.service.TransferStartGateTest \
  --tests com.camtransfer.service.CameraModuleBoundaryTest
```

Expected: pass.

- [ ] **Step 2: Run full unit test suite**

Run: `./gradlew testDebugUnitTest`

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Inspect git diff**

Run: `git diff --stat` and `git diff -- app/src/main/java app/src/test/java`

Expected: changes are limited to Android preview mode, transfer pause gate, and protocol preview path.
