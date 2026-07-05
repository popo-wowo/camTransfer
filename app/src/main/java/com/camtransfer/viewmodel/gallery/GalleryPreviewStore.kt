package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.LinkedHashMap

class GalleryPreviewStore(
    private val maxEntries: Int = MAX_CACHED_PREVIEW_IMAGES,
) {
    private val previewImageCache = LinkedHashMap<Int, ByteArray>(maxEntries, 0.75f, true)
    private val cacheLock = Any()

    private val _previewImages = MutableStateFlow<Map<Int, ByteArray>>(emptyMap())
    val previewImages: StateFlow<Map<Int, ByteArray>> = _previewImages.asStateFlow()

    private val _loadedHandles = MutableStateFlow<Set<Int>>(emptySet())
    val loadedHandles: StateFlow<Set<Int>> = _loadedHandles.asStateFlow()

    private val _loadingHandles = MutableStateFlow<Set<Int>>(emptySet())
    val loadingHandles: StateFlow<Set<Int>> = _loadingHandles.asStateFlow()

    private val _failedHandles = MutableStateFlow<Set<Int>>(emptySet())
    val failedHandles: StateFlow<Set<Int>> = _failedHandles.asStateFlow()

    fun hasPreview(handle: Int): Boolean =
        synchronized(cacheLock) { previewImageCache.containsKey(handle) }

    fun markLoading(handle: Int) {
        _loadingHandles.value = _loadingHandles.value + handle
    }

    fun clearLoading(handle: Int) {
        _loadingHandles.value = _loadingHandles.value - handle
    }

    fun markLoaded(handle: Int, data: ByteArray, protectedHandles: Set<Int> = emptySet()) {
        synchronized(cacheLock) {
            previewImageCache.remove(handle)
            previewImageCache[handle] = data
            trimToLimit(protectedHandles)
            _previewImages.value = previewImageCache.toMap()
        }
        _loadedHandles.value = _loadedHandles.value + handle
        _failedHandles.value = _failedHandles.value - handle
    }

    fun markRestored(handles: Set<Int>) {
        if (handles.isEmpty()) return
        _loadedHandles.value = _loadedHandles.value + handles
    }

    fun markFailed(handle: Int) {
        _failedHandles.value = _failedHandles.value + handle
    }

    fun removeLoaded(handles: Set<Int>) {
        if (handles.isEmpty()) return
        _loadedHandles.value = _loadedHandles.value - handles
    }

    fun keepFailuresFor(handles: Set<Int>) {
        _failedHandles.value = _failedHandles.value.intersect(handles)
    }

    fun putRestored(handle: Int, data: ByteArray, protectedHandles: Set<Int>): Map<Int, ByteArray> =
        synchronized(cacheLock) {
            previewImageCache.remove(handle)
            previewImageCache[handle] = data
            trimToLimit(protectedHandles)
            previewImageCache.toMap().also { _previewImages.value = it }
        }

    fun clear() {
        synchronized(cacheLock) {
            previewImageCache.clear()
        }
        _previewImages.value = emptyMap()
        _loadedHandles.value = emptySet()
        _loadingHandles.value = emptySet()
        _failedHandles.value = emptySet()
    }

    private fun trimToLimit(protectedHandles: Set<Int>) {
        while (previewImageCache.size > maxEntries) {
            val oldestHandle = previewImageCache.keys.firstOrNull { it !in protectedHandles }
                ?: previewImageCache.keys.firstOrNull()
                ?: return
            previewImageCache.remove(oldestHandle)
        }
    }

    companion object {
        const val MAX_CACHED_PREVIEW_IMAGES = 30
    }
}
