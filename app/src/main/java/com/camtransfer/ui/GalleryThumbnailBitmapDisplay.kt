package com.camtransfer.ui

import android.graphics.Bitmap
import kotlin.math.max

internal object GalleryThumbnailLetterboxCropper {
    fun crop(bitmap: Bitmap): Bitmap {
        if (bitmap.width < MIN_DIMENSION || bitmap.height < MIN_DIMENSION) return bitmap
        val readableBitmap = readableBitmap(bitmap) ?: return bitmap

        val top = darkHorizontalBand(readableBitmap, fromTop = true)
        val bottom = darkHorizontalBand(readableBitmap, fromTop = false)
        val left = darkVerticalBand(readableBitmap, fromLeft = true)
        val right = darkVerticalBand(readableBitmap, fromLeft = false)

        val minHorizontalBand = max(2, readableBitmap.height / 80)
        val minVerticalBand = max(2, readableBitmap.width / 80)
        val cropTop = top.takeIf { it >= minHorizontalBand } ?: 0
        val cropBottom = bottom.takeIf { it >= minHorizontalBand } ?: 0
        val cropLeft = left.takeIf { it >= minVerticalBand } ?: 0
        val cropRight = right.takeIf { it >= minVerticalBand } ?: 0

        val cropWidth = readableBitmap.width - cropLeft - cropRight
        val cropHeight = readableBitmap.height - cropTop - cropBottom
        if (cropWidth <= readableBitmap.width * MIN_REMAINING_RATIO) return bitmap
        if (cropHeight <= readableBitmap.height * MIN_REMAINING_RATIO) return bitmap
        if (cropLeft == 0 && cropRight == 0 && cropTop == 0 && cropBottom == 0) return bitmap

        return runCatching {
            Bitmap.createBitmap(readableBitmap, cropLeft, cropTop, cropWidth, cropHeight)
        }.getOrDefault(bitmap)
    }

    private fun readableBitmap(bitmap: Bitmap): Bitmap? =
        if (bitmap.config == Bitmap.Config.HARDWARE) {
            runCatching { bitmap.copy(Bitmap.Config.ARGB_8888, false) }.getOrNull()
        } else {
            bitmap
        }

    private fun darkHorizontalBand(bitmap: Bitmap, fromTop: Boolean): Int {
        val limit = bitmap.height / 3
        var count = 0
        while (count < limit) {
            val y = if (fromTop) count else bitmap.height - 1 - count
            if (!isDarkRow(bitmap, y)) break
            count += 1
        }
        return count
    }

    private fun darkVerticalBand(bitmap: Bitmap, fromLeft: Boolean): Int {
        val limit = bitmap.width / 3
        var count = 0
        while (count < limit) {
            val x = if (fromLeft) count else bitmap.width - 1 - count
            if (!isDarkColumn(bitmap, x)) break
            count += 1
        }
        return count
    }

    private fun isDarkRow(bitmap: Bitmap, y: Int): Boolean {
        val step = max(1, bitmap.width / SAMPLE_COUNT)
        var samples = 0
        var darkSamples = 0
        var x = 0
        while (x < bitmap.width) {
            samples += 1
            if (isDarkPixel(bitmap.getPixel(x, y))) darkSamples += 1
            x += step
        }
        return samples > 0 && darkSamples.toFloat() / samples >= DARK_SAMPLE_RATIO
    }

    private fun isDarkColumn(bitmap: Bitmap, x: Int): Boolean {
        val step = max(1, bitmap.height / SAMPLE_COUNT)
        var samples = 0
        var darkSamples = 0
        var y = 0
        while (y < bitmap.height) {
            samples += 1
            if (isDarkPixel(bitmap.getPixel(x, y))) darkSamples += 1
            y += step
        }
        return samples > 0 && darkSamples.toFloat() / samples >= DARK_SAMPLE_RATIO
    }

    private fun isDarkPixel(pixel: Int): Boolean {
        val alpha = pixel ushr 24
        if (alpha < 16) return false
        val red = pixel shr 16 and 0xFF
        val green = pixel shr 8 and 0xFF
        val blue = pixel and 0xFF
        return max(red, max(green, blue)) <= DARK_CHANNEL_MAX
    }

    private const val MIN_DIMENSION = 24
    private const val SAMPLE_COUNT = 64
    private const val DARK_CHANNEL_MAX = 26
    private const val DARK_SAMPLE_RATIO = 0.92f
    private const val MIN_REMAINING_RATIO = 0.55f
}
