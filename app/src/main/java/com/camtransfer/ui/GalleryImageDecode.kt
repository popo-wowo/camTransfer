package com.camtransfer.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.camtransfer.model.CameraFile
import com.camtransfer.model.TransferItem
import com.camtransfer.model.TransferState
import com.camtransfer.service.CameraFileSource
import com.camtransfer.viewmodel.BrowseViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.LinkedHashMap
import kotlin.math.hypot

@Composable
internal fun EmptyGalleryMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, color = CamTransferColors.SecondaryInk)
    }
}


internal fun decodeThumbnailBitmapForDisplay(
    file: CameraFile,
    data: ByteArray,
    maxDecodedSide: Int,
): Bitmap? {
    val bitmap = decodeThumbnailBitmap(data, maxDecodedSide) ?: return null
    val rotationDegrees = GalleryThumbnailDisplayPolicy.rotationDegrees(
        file = file,
        decodedWidth = bitmap.width,
        decodedHeight = bitmap.height,
        thumbnail = data,
    )
    return GalleryThumbnailLetterboxCropper.crop(rotateGalleryBitmapForDisplay(bitmap, rotationDegrees))
}

internal fun decodeThumbnailBitmap(
    data: ByteArray,
    maxDecodedSide: Int = GalleryThumbnailDecodePolicy.PREVIEW_MAX_DECODED_SIDE,
) = decodeThumbnailBitmapLegacy(data, maxDecodedSide)
    ?: if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
                    width = info.size.width,
                    height = info.size.height,
                    maxDecodedSide = maxDecodedSide,
                )
                if (sampleSize > 1) {
                    decoder.setTargetSampleSize(sampleSize)
                }
            }
        }.getOrNull()
    } else {
        null
    }

internal fun decodeThumbnailBitmapLegacy(data: ByteArray, maxDecodedSide: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
    val sampleSize = GalleryThumbnailDecodePolicy.sampleSize(
        width = bounds.outWidth,
        height = bounds.outHeight,
        maxDecodedSide = maxDecodedSide,
    )
    return BitmapFactory.decodeByteArray(
        data,
        0,
        data.size,
        BitmapFactory.Options().apply { inSampleSize = sampleSize },
    )
}

internal fun rotateGalleryBitmapForDisplay(bitmap: Bitmap, degrees: Int): Bitmap {
    val normalizedDegrees = ((degrees % 360) + 360) % 360
    if (normalizedDegrees == 0) return bitmap
    val matrix = Matrix().apply { postRotate(normalizedDegrees.toFloat()) }
    return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
}

internal data class GalleryDecodedThumbnailKey(
    val handle: Int,
    val format: Int,
    val compressedSize: Int,
    val filename: String,
    val thumbnailSize: Int,
    val maxDecodedSide: Int,
)

internal class GalleryDecodedThumbnailCache<T>(
    private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
    private val entries = LinkedHashMap<GalleryDecodedThumbnailKey, T>(maxEntries, 0.75f, true)

    @Synchronized
    fun get(key: GalleryDecodedThumbnailKey): T? = entries[key]

    @Synchronized
    fun put(key: GalleryDecodedThumbnailKey, value: T) {
        entries.remove(key)
        entries[key] = value
        while (entries.size > maxEntries) {
            val oldestKey = entries.keys.firstOrNull() ?: return
            entries.remove(oldestKey)
        }
    }

    @Synchronized
    fun clear() {
        entries.clear()
    }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 120

        fun key(
            file: CameraFile,
            thumbnailSize: Int,
            maxDecodedSide: Int,
        ): GalleryDecodedThumbnailKey =
            GalleryDecodedThumbnailKey(
                handle = file.info.handle,
                format = file.info.format,
                compressedSize = file.info.compressedSize,
                filename = file.info.filename,
                thumbnailSize = thumbnailSize,
                maxDecodedSide = maxDecodedSide,
            )
    }
}
