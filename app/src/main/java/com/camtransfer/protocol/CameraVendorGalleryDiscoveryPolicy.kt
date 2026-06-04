package com.camtransfer.protocol

object CameraVendorGalleryDiscoveryPolicy {
    const val INITIAL_LARGE_GALLERY_HANDLE_LIMIT = 200
    private const val LARGE_GALLERY_THRESHOLD = 500

    fun shouldIncludeStandardEnumeration(specifiedHandleCount: Int): Boolean =
        specifiedHandleCount in 1..LARGE_GALLERY_THRESHOLD

    fun initialSpecifiedHandles(specifiedHandles: List<Int>): List<Int> {
        val sorted = specifiedHandles.distinct().sortedDescending()
        if (sorted.size <= LARGE_GALLERY_THRESHOLD) return sorted
        return sorted.take(INITIAL_LARGE_GALLERY_HANDLE_LIMIT)
    }

    fun initialPlaceholderHandles(specifiedHandles: List<Int>): List<Int> =
        initialSpecifiedHandles(specifiedHandles)

    fun isLargeGallery(specifiedHandleCount: Int): Boolean =
        specifiedHandleCount > LARGE_GALLERY_THRESHOLD
}
