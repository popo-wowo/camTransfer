package com.camtransfer.viewmodel.gallery

import android.graphics.BitmapFactory
import com.camtransfer.model.CameraFile
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import java.util.LinkedHashMap

class GalleryPreviewController(
    private val scope: CoroutineScope,
    private val requestScheduler: GalleryRequestScheduler,
    private val thumbnailController: GalleryThumbnailController,
) {
    private val previewImageCache = LinkedHashMap<Int, ByteArray>()
    private val _previewImages = MutableStateFlow<Map<Int, ByteArray>>(emptyMap())
    val previewImages: StateFlow<Map<Int, ByteArray>> = _previewImages.asStateFlow()

    private var previewImageJob: Job? = null

    @Volatile
    private var pendingPreviewFile: CameraFile? = null

    fun loadPreviewImage(cameraSource: CameraFileSource, file: CameraFile) {
        val handle = file.info.handle
        if (!GalleryPreviewFullImageLoadPolicy.shouldRequestFullImagePreview(file, previewImageCache.containsKey(handle))) {
            return
        }
        pendingPreviewFile = file
        if (previewImageJob?.isActive == true) return
        previewImageJob = scope.launch(Dispatchers.IO) {
            while (true) {
                val nextFile = pendingPreviewFile ?: return@launch
                pendingPreviewFile = null
                loadPreviewImageNow(cameraSource, nextFile)
                yield()
            }
        }
    }

    fun reset() {
        previewImageJob?.cancel()
        previewImageJob = null
        previewImageCache.clear()
        pendingPreviewFile = null
        _previewImages.value = emptyMap()
    }

    private suspend fun loadPreviewImageNow(cameraSource: CameraFileSource, file: CameraFile) {
        val handle = file.info.handle
        if (previewImageCache.containsKey(handle)) return
        DiagnosticLog.append(cameraSource.context, TAG, "Preview image request handle=$handle")
        thumbnailController.pauseForExclusiveOperation(cameraSource, reason = "preview")
        try {
            val data = requestScheduler.run(GalleryRequestPriority.PreviewImage) {
                cameraSource.getPreviewImage(handle)
            }
            val decodedSize = data.decodedBounds()
            cachePreviewImage(handle, data)
            _previewImages.value = previewImageCache.toMap()
            DiagnosticLog.append(
                cameraSource.context,
                TAG,
                "Preview image loaded handle=$handle source=compressedPreview bytes=${data.size} " +
                    "decoded=${decodedSize.width}x${decodedSize.height}",
            )
        } catch (e: Exception) {
            DiagnosticLog.append(cameraSource.context, TAG, "Preview image failed handle=$handle", e)
        } finally {
            thumbnailController.resumeAfterExclusiveOperation(cameraSource, reason = "preview")
        }
    }

    private fun cachePreviewImage(handle: Int, data: ByteArray) {
        previewImageCache.remove(handle)
        previewImageCache[handle] = data
        while (previewImageCache.size > MAX_CACHED_PREVIEW_IMAGES) {
            val oldestHandle = previewImageCache.keys.firstOrNull() ?: return
            previewImageCache.remove(oldestHandle)
        }
    }

    private fun ByteArray.decodedBounds(): PreviewDecodedBounds {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(this, 0, size, options)
        return PreviewDecodedBounds(
            width = options.outWidth,
            height = options.outHeight,
        )
    }

    private companion object {
        const val TAG = "GalleryPreviewController"
        const val MAX_CACHED_PREVIEW_IMAGES = 2
    }
}

private data class PreviewDecodedBounds(
    val width: Int,
    val height: Int,
)

internal object GalleryPreviewFullImageLoadPolicy {
    fun shouldRequestFullImagePreview(file: CameraFile, hasPreviewImage: Boolean): Boolean {
        if (hasPreviewImage) return false
        return file.info.isJpeg || file.info.isHeif
    }
}
