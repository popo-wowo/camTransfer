package com.camtransfer.protocol

object CameraVendorGalleryDiscoveryPolicy {
    const val INITIAL_LARGE_GALLERY_HANDLE_LIMIT = 200
    const val MAX_STANDARD_OBJECT_INFO_PROBE_COUNT = 300
    private const val LARGE_GALLERY_THRESHOLD = 500

    fun shouldIncludeStandardEnumeration(specifiedHandleCount: Int): Boolean =
        specifiedHandleCount in 1..LARGE_GALLERY_THRESHOLD

    fun shouldProbeStandardWhenNoExtendedStill(hasExtendedStill: Boolean): Boolean =
        !hasExtendedStill

    fun initialSpecifiedHandles(specifiedHandles: List<Int>): List<Int> {
        val sorted = specifiedHandles.distinct().sortedDescending()
        if (sorted.size <= LARGE_GALLERY_THRESHOLD) return sorted
        return sorted.take(INITIAL_LARGE_GALLERY_HANDLE_LIMIT)
    }

    fun initialPlaceholderHandles(specifiedHandles: List<Int>): List<Int> =
        specifiedHandles.distinct()

    fun captureDatesByHandle(
        specifiedHandles: List<Int>,
        countsByDate: List<CameraVendorObjectCountByDate>,
    ): Map<Int, String> {
        if (specifiedHandles.isEmpty() || countsByDate.isEmpty()) return emptyMap()
        val handles = initialPlaceholderHandles(specifiedHandles)
        val result = mutableMapOf<Int, String>()
        var handleIndex = 0
        for (dateCount in countsByDate) {
            repeat(dateCount.numberOfImages) {
                val handle = handles.getOrNull(handleIndex) ?: return result
                result[handle] = dateCount.dateValue
                handleIndex++
            }
        }
        return result
    }

    fun isLargeGallery(specifiedHandleCount: Int): Boolean =
        specifiedHandleCount > LARGE_GALLERY_THRESHOLD
}
