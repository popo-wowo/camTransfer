package com.camtransfer.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GalleryFileLoadPolicyTest {
    @Test
    fun doesNotLoadAgainWhenSameSourceAlreadyLoaded() {
        val source = Any()

        assertFalse(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = source,
                loadedSource = source,
                isLoading = false,
                lastLoadFailed = false,
            )
        )
    }

    @Test
    fun loadsWhenSourceChanges() {
        assertTrue(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = Any(),
                loadedSource = Any(),
                isLoading = false,
                lastLoadFailed = false,
            )
        )
    }

    @Test
    fun allowsRetryAfterFailedLoad() {
        val source = Any()

        assertTrue(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = source,
                loadedSource = source,
                isLoading = false,
                lastLoadFailed = true,
            )
        )
    }

    @Test
    fun doesNotStartDuplicateLoadWhileLoading() {
        assertFalse(
            GalleryFileLoadPolicy.shouldLoad(
                currentSource = Any(),
                loadedSource = null,
                isLoading = true,
                lastLoadFailed = false,
            )
        )
    }
}
