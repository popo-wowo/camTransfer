package com.camtransfer.viewmodel.gallery

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class GalleryThumbnailStore(
    private val maxEntries: Int = MAX_CACHED_THUMBNAILS,
) {
    private val entries = LinkedHashMap<Int, ByteArray>(maxEntries, 0.75f, true)
    private val _thumbnails = MutableStateFlow<Map<Int, ByteArray>>(emptyMap())
    val thumbnails: StateFlow<Map<Int, ByteArray>> = _thumbnails.asStateFlow()

    @Synchronized
    fun put(handle: Int, thumbnail: ByteArray) {
        entries.remove(handle)
        entries[handle] = thumbnail
        trimToLimit()
        _thumbnails.value = entries.toMap()
    }

    @Synchronized
    fun hasThumbnail(handle: Int): Boolean =
        entries.containsKey(handle)

    @Synchronized
    fun snapshot(): Map<Int, ByteArray> =
        entries.toMap()

    @Synchronized
    fun clear() {
        entries.clear()
        _thumbnails.value = emptyMap()
    }

    private fun trimToLimit() {
        while (entries.size > maxEntries) {
            val oldestHandle = entries.keys.firstOrNull() ?: return
            entries.remove(oldestHandle)
        }
    }

    companion object {
        const val MAX_CACHED_THUMBNAILS = 300
    }
}
