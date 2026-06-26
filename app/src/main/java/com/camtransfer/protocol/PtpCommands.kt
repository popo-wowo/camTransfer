package com.camtransfer.protocol

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.flow.flow
import java.io.OutputStream

private const val TAG = "PtpCommands"

class PtpCommands(
    private val connection: PtpConnection,
    private val diagnosticContext: Context? = null,
) {

    suspend fun getStorageIDs(): List<Int> {
        val data = connection.sendCommandGetData(PtpOpCode.GET_STORAGE_IDS)
        return CameraVendorPtpDataParser.uint32Array(data)
    }

    suspend fun getObjectHandles(
        storageId: Int,
        formatCode: Int = 0,
        parentHandle: Int = CameraVendorConst.ALL_HANDLES,
    ): List<Int> {
        val data = connection.sendCommandGetData(
            PtpOpCode.GET_OBJECT_HANDLES, listOf(storageId, formatCode, parentHandle)
        )
        return CameraVendorPtpDataParser.uint32Array(data)
    }

    suspend fun getObjectInfo(handle: Int): ObjectInfo {
        val data = connection.sendCommandGetData(PtpOpCode.GET_OBJECT_INFO, listOf(handle))
        return CameraVendorPtpDataParser.objectInfo(handle, data)
    }

    suspend fun getCameraVendorObjectInfo(handle: Int): ObjectInfo {
        val data = connection.sendCommandGetData(
            PtpOpCode.CAMERA_VENDOR_GET_LATEST_OBJECT_INFO,
            listOf(handle),
        )
        val info = CameraVendorPtpDataParser.cameraVendorObjectInfo(handle, data)
        if (info.orientation == null) {
            diagnostic(
                "Vendor ObjectInfo orientation missing handle=$handle " +
                    "bytes=${data.size} tail=${data.tailHex()}",
            )
        }
        return info
    }

    suspend fun galleryObjectInfos(): List<ObjectInfo> {
        val startedMs = SystemClock.elapsedRealtime()
        resetCameraVendorCompressionMode()
        if (connection.cameraVendorSpecifiedObjectHandles.isEmpty()) {
            runCatching { connection.loadCameraVendorGalleryObjectHandles() }
                .onFailure { diagnostic("Gallery handle initialization failed: ${it.message}") }
        }
        val specifiedHandles = connection.cameraVendorSpecifiedObjectHandles
        diagnostic("Gallery discovery ${specifiedHandles.summaryLabel("specifiedHandles")}")
        if (specifiedHandles.isNotEmpty()) {
            val initialHandles = CameraVendorGalleryDiscoveryPolicy.initialSpecifiedHandles(specifiedHandles)
            if (initialHandles.size < specifiedHandles.size) {
                diagnostic(
                    "Gallery discovery initialHandles=${initialHandles.size}/${specifiedHandles.size} " +
                        "largeGallery=true",
                )
            }
            val vendorStartedMs = SystemClock.elapsedRealtime()
            val specifiedInfos = initialHandles.map { handle ->
                runCatching { getObjectInfo(handle) }
                    .getOrElse { placeholderObjectInfo(handle) }
            }
            val forwardInfos = if (CameraVendorGalleryDiscoveryPolicy.isLargeGallery(specifiedHandles.size)) {
                emptyList()
            } else {
                forwardObjectInfos(initialHandles, specifiedInfos)
            }
            val hiddenInfos = if (CameraVendorHiddenObjectProbePolicy.shouldProbeHiddenHandles(specifiedHandles)) {
                hiddenObjectInfos(initialHandles, specifiedInfos)
            } else {
                emptyList()
            }
            val vendorInfos = mergeInfos(specifiedInfos + hiddenInfos + forwardInfos)
            diagnostic(
                "Gallery discovery vendorInfos=${vendorInfos.size} " +
                    "elapsedMs=${SystemClock.elapsedRealtime() - vendorStartedMs}",
            )
            // iOS logic: if specified list has no HEIF/RAW, do standard PTP enumeration
            // (GetStorageIDs → GetObjectHandles → GetObjectInfo) which returns ALL formats
            val hasExtendedStill = vendorInfos.any { it.isHeif || it.isRaw }
            val standardInfos = if (
                CameraVendorGalleryDiscoveryPolicy.shouldIncludeStandardEnumeration(specifiedHandles.size) ||
                CameraVendorGalleryDiscoveryPolicy.shouldProbeStandardWhenNoExtendedStill(hasExtendedStill)
            ) {
                val standardStartedMs = SystemClock.elapsedRealtime()
                runCatching { standardObjectInfosCapped() }
                    .onSuccess {
                        val elapsedMs = SystemClock.elapsedRealtime() - standardStartedMs
                        Log.d(TAG, "Standard enumeration loaded count=${it.size} elapsedMs=$elapsedMs")
                        diagnostic("Gallery discovery standardInfos=${it.size} elapsedMs=$elapsedMs hasExtendedStill=$hasExtendedStill")
                    }
                    .onFailure { Log.d(TAG, "Standard enumeration failed: ${it.message}") }
                    .getOrElse { emptyList() }
            } else {
                emptyList()
            }
            // iOS logic: use standard result only if it has extended still or more items
            val useStandard = standardInfos.isNotEmpty() && (
                standardInfos.any { it.isHeif || it.isRaw || it.isVideo } ||
                standardInfos.size > vendorInfos.size
            )
            val merged = if (useStandard) {
                mergeInfos(vendorInfos + standardInfos)
            } else {
                vendorInfos
            }
            diagnostic("Gallery discovery merged=${merged.size} elapsedMs=${SystemClock.elapsedRealtime() - startedMs}")
            if (merged.isNotEmpty()) {
                return merged
            }
        }

        val standardInfos = standardObjectInfos()
        diagnostic("Gallery discovery standardOnly=${standardInfos.size} elapsedMs=${SystemClock.elapsedRealtime() - startedMs}")
        return standardInfos
    }

    suspend fun getThumb(handle: Int): ByteArray =
        getThumbWithInfo(handle).data

    suspend fun getThumbWithInfo(handle: Int): PtpThumbnailData {
        val startedMs = SystemClock.elapsedRealtime()
        var objectInfo: ObjectInfo? = null
        if (CameraVendorThumbnailReadPolicy.shouldPrimeObjectContextBeforeStandardThumbnail()) {
            val primeStartedMs = SystemClock.elapsedRealtime()
            runCatching { getCameraVendorObjectInfo(handle) }
                .recoverCatching { vendorError ->
                    diagnostic(
                        "Thumbnail vendor context prime failed handle=$handle " +
                            "elapsedMs=${SystemClock.elapsedRealtime() - primeStartedMs} " +
                            "error=${vendorError.message}",
                    )
                    getObjectInfo(handle)
                }
                .onSuccess {
                    objectInfo = it
                    diagnostic(
                        "Thumbnail context primed handle=$handle " +
                            "format=0x${it.format.toString(16)} " +
                            "thumb=${it.thumbPixWidth}x${it.thumbPixHeight} " +
                            "orientation=${it.orientation?.toString() ?: "unknown"} " +
                            "elapsedMs=${SystemClock.elapsedRealtime() - primeStartedMs}",
                    )
                }
                .onFailure { error ->
                    diagnostic(
                        "Thumbnail context prime failed handle=$handle " +
                            "elapsedMs=${SystemClock.elapsedRealtime() - primeStartedMs} error=${error.message}",
                    )
                }
        }
        val standardStartedMs = SystemClock.elapsedRealtime()
        val standard = runCatching {
            connection.sendCommandGetData(
                PtpOpCode.GET_THUMB,
                listOf(handle),
                readTimeoutMs = CameraVendorThumbnailReadPolicy.STANDARD_THUMB_TIMEOUT_MS,
            )
        }.onFailure { error ->
            diagnostic(
                "Thumbnail standard failed handle=$handle " +
                    "elapsedMs=${SystemClock.elapsedRealtime() - standardStartedMs} " +
                    "totalElapsedMs=${SystemClock.elapsedRealtime() - startedMs} error=${error.message}",
            )
        }.getOrNull()
        if (standard != null) {
            val normalized = CameraVendorPtpDataParser.imageData(standard)
            if (standard.size >= 100 && CameraVendorPtpDataParser.isLikelyImageData(normalized)) {
                val message = "Thumbnail standard handle=$handle rawBytes=${standard.size} " +
                    "imageBytes=${normalized.size} elapsedMs=${SystemClock.elapsedRealtime() - standardStartedMs} " +
                    "totalElapsedMs=${SystemClock.elapsedRealtime() - startedMs}"
                Log.d(TAG, message)
                diagnostic(message)
                return PtpThumbnailData(data = normalized, objectInfo = objectInfo)
            }
            val message = "Thumbnail standard unusable handle=$handle rawBytes=${standard.size} " +
                "imageBytes=${normalized.size} head=${normalized.headHex()} " +
                "elapsedMs=${SystemClock.elapsedRealtime() - startedMs}"
            Log.d(TAG, message)
            diagnostic(message)
        }

        throw IllegalStateException(
            "Thumbnail unavailable handle=$handle; partial object fallback is disabled by policy",
        )
    }

    private suspend fun readVendorExtensionThumbnail(handle: Int, startedMs: Long): ByteArray {
        val vendorStartedMs = SystemClock.elapsedRealtime()
        val data = connection.sendCommandGetData(
            PtpOpCode.CAMERA_VENDOR_GET_EXTENSION_THUMB,
            listOf(handle),
            readTimeoutMs = CameraVendorThumbnailReadPolicy.VENDOR_EXTENSION_THUMB_TIMEOUT_MS,
        )
        val normalized = CameraVendorPtpDataParser.imageData(data)
        if (!CameraVendorPtpDataParser.isLikelyImageData(normalized)) {
            throw IllegalStateException(
                "Vendor extension thumbnail is not image data: rawBytes=${data.size} " +
                    "imageBytes=${normalized.size} head=${normalized.headHex()}",
            )
        }
        val message = "Thumbnail vendorExtension handle=$handle rawBytes=${data.size} " +
            "imageBytes=${normalized.size} head=${normalized.headHex()} " +
            "elapsedMs=${SystemClock.elapsedRealtime() - vendorStartedMs} " +
            "totalElapsedMs=${SystemClock.elapsedRealtime() - startedMs}"
        Log.d(TAG, message)
        diagnostic(message)
        return normalized
    }

    suspend fun getPreviewImage(handle: Int): ByteArray {
        val startedMs = SystemClock.elapsedRealtime()
        val info = getObjectInfo(handle)
        if (!CameraVendorPreviewImageReadPolicy.shouldReadCompressedPreview(info)) {
            throw IllegalStateException(
                "Compressed preview unavailable handle=$handle format=0x${info.format.toString(16)} size=${info.compressedSize}",
            )
        }
        val previewSize = info.compressedSize.coerceAtMost(CameraVendorReferenceApp.PARTIAL_PREVIEW_READ_SIZE)
        val raw = getPartialObject(handle, 0, previewSize)
        val image = CameraVendorPtpDataParser.imageData(raw)
        if (!CameraVendorPtpDataParser.isLikelyImageData(image)) {
            throw IllegalStateException("Preview image is not image data handle=$handle bytes=${raw.size} head=${image.headHex()}")
        }
        if (CameraVendorThumbnailReadPolicy.shouldRejectIncompletePartialPreview(image)) {
            throw IllegalStateException("Preview image is incomplete JPEG handle=$handle bytes=${image.size}")
        }
        val message = "Preview image compressed handle=$handle rawBytes=${raw.size} imageBytes=${image.size} " +
            "object=${info.imagePixWidth}x${info.imagePixHeight} elapsedMs=${SystemClock.elapsedRealtime() - startedMs}"
        Log.d(TAG, message)
        diagnostic(message)
        return image
    }

    suspend fun getObject(
        handle: Int,
        expectedSize: Int? = null,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
        objectInfo: ObjectInfo? = null,
    ): ByteArray {
        val resetProperties = mutableListOf<CameraVendorDevicePropertyValue>()
        try {
            Log.d(TAG, "Download prepare handle=$handle expectedSize=$expectedSize mode=${downloadMode.name.lowercase()}")
            runCatching {
                connection.readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
            }
            runCatching {
                connection.readDeviceProperty(CameraVendorDevicePropCode.COMPRESSION_CUT_OFF)
            }
            val prepareProperties = CameraVendorDownloadModePolicy.prepareProperties(downloadMode, objectInfo)
            prepareProperties.forEach { prepareProperty ->
                val response = setDeviceProperty(prepareProperty)
                val message = "Download mode prepare handle=$handle mode=${downloadMode.name.lowercase()} " +
                    "format=${objectInfo?.formatLabel ?: "unknown"} " +
                    "prop=0x${prepareProperty.code.toString(16)} value=${prepareProperty.value} " +
                    "width=${prepareProperty.width.name.lowercase()} response=0x${response.responseCode.toString(16)}"
                Log.d(TAG, message)
                diagnostic(message)
                CameraVendorDownloadModePolicy.resetProperty(prepareProperty)?.let(resetProperties::add)
            }
            val freshInfo = runCatching { getObjectInfo(handle) }.getOrNull()
            val size = freshInfo?.compressedSize?.takeIf { it > 0 } ?: expectedSize
            Log.d(
                TAG,
                "Download partial handle=$handle freshSize=${freshInfo?.compressedSize ?: 0} " +
                    "readSize=${size ?: 0} mode=${downloadMode.name.lowercase()}",
            )
            val data = readObjectByPartialObjects(handle, size)
            Log.d(TAG, "Download complete handle=$handle bytes=${data.size} mode=${downloadMode.name.lowercase()} head=${data.headHex()}")
            return CameraVendorPtpDataParser.imageData(data)
        } finally {
            resetProperties.asReversed().forEach { resetProperty ->
                runCatching {
                    val response = setDeviceProperty(resetProperty)
                    val message = "Download mode reset handle=$handle mode=${downloadMode.name.lowercase()} " +
                        "prop=0x${resetProperty.code.toString(16)} value=${resetProperty.value} " +
                        "width=${resetProperty.width.name.lowercase()} response=0x${response.responseCode.toString(16)}"
                    Log.d(TAG, message)
                    diagnostic(message)
                }.onFailure {
                    Log.d(TAG, "Reset download mode failed: ${it.message}")
                }
            }
        }
    }

    suspend fun writeObjectToStream(
        handle: Int,
        expectedSize: Int? = null,
        downloadMode: TransferDownloadMode = TransferDownloadMode.ORIGINAL,
        objectInfo: ObjectInfo? = null,
        output: OutputStream,
    ): Long {
        val resetProperties = mutableListOf<CameraVendorDevicePropertyValue>()
        try {
            Log.d(TAG, "Download stream prepare handle=$handle expectedSize=$expectedSize mode=${downloadMode.name.lowercase()}")
            runCatching {
                connection.readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
            }
            runCatching {
                connection.readDeviceProperty(CameraVendorDevicePropCode.COMPRESSION_CUT_OFF)
            }
            val prepareProperties = CameraVendorDownloadModePolicy.prepareProperties(downloadMode, objectInfo)
            prepareProperties.forEach { prepareProperty ->
                val response = setDeviceProperty(prepareProperty)
                val message = "Download mode prepare handle=$handle mode=${downloadMode.name.lowercase()} " +
                    "format=${objectInfo?.formatLabel ?: "unknown"} " +
                    "prop=0x${prepareProperty.code.toString(16)} value=${prepareProperty.value} " +
                    "width=${prepareProperty.width.name.lowercase()} response=0x${response.responseCode.toString(16)}"
                Log.d(TAG, message)
                diagnostic(message)
                CameraVendorDownloadModePolicy.resetProperty(prepareProperty)?.let(resetProperties::add)
            }
            val freshInfo = runCatching { getObjectInfo(handle) }.getOrNull()
            val size = freshInfo?.compressedSize?.takeIf { it > 0 } ?: expectedSize
            Log.d(
                TAG,
                "Download partial stream handle=$handle freshSize=${freshInfo?.compressedSize ?: 0} " +
                    "readSize=${size ?: 0} mode=${downloadMode.name.lowercase()}",
            )
            val bytes = readObjectByPartialObjectsToStream(handle, size, output)
            Log.d(TAG, "Download stream complete handle=$handle bytes=$bytes mode=${downloadMode.name.lowercase()}")
            return bytes
        } finally {
            resetProperties.asReversed().forEach { resetProperty ->
                runCatching {
                    val response = setDeviceProperty(resetProperty)
                    val message = "Download mode reset handle=$handle mode=${downloadMode.name.lowercase()} " +
                        "prop=0x${resetProperty.code.toString(16)} value=${resetProperty.value} " +
                        "width=${resetProperty.width.name.lowercase()} response=0x${response.responseCode.toString(16)}"
                    Log.d(TAG, message)
                    diagnostic(message)
                }.onFailure {
                    Log.d(TAG, "Reset download mode failed: ${it.message}")
                }
            }
        }
    }

    fun getObjectStream(handle: Int) = flow {
        val expectedSize = runCatching { getObjectInfo(handle).compressedSize }.getOrNull()
        emit(getObject(handle, expectedSize))
    }

    private suspend fun setDeviceProperty(property: CameraVendorDevicePropertyValue): PtpOperationResponse =
        when (property.width) {
            CameraVendorDevicePropertyWidth.UINT16 -> connection.setDevicePropertyUInt16(property.code, property.value)
            CameraVendorDevicePropertyWidth.UINT32 -> connection.setDevicePropertyUInt32(property.code, property.value)
        }

    suspend fun getPartialObject(handle: Int, offset: Int, maxBytes: Int): ByteArray {
        return connection.sendCommandGetData(
            PtpOpCode.GET_PARTIAL_OBJECT,
            listOf(handle, offset, maxBytes),
            readTimeoutMs = CameraVendorReferenceApp.PARTIAL_FILE_READ_TIMEOUT_MS,
        )
    }

    private suspend fun resetCameraVendorCompressionMode() {
        runCatching {
            connection.setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, 0)
            connection.setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_COMPRESSION_REAL_INFO, 0)
        }.onFailure {
            Log.d(TAG, "Compression reset skipped: ${it.message}")
        }
    }

    private suspend fun standardObjectInfos(): List<ObjectInfo> {
        val infos = mutableListOf<ObjectInfo>()
        for (storageId in getStorageIDs()) {
            for (handle in getObjectHandles(storageId)) {
                runCatching { getObjectInfo(handle) }
                    .onSuccess { if (!it.isFolder) infos.add(it) }
                    .onFailure { Log.d(TAG, "Standard ObjectInfo failed handle=$handle: ${it.message}") }
            }
        }
        return infos.sortedByDescending { it.handle }
    }

    private suspend fun standardObjectInfosCapped(): List<ObjectInfo> {
        val maxProbe = CameraVendorGalleryDiscoveryPolicy.MAX_STANDARD_OBJECT_INFO_PROBE_COUNT
        val infos = mutableListOf<ObjectInfo>()
        for (storageId in getStorageIDs()) {
            val handles = getObjectHandles(storageId)
            diagnostic("Standard enumeration storageId=0x${storageId.toString(16)} handles=${handles.size}")
            for (handle in handles.take(maxProbe)) {
                if (infos.size >= maxProbe) break
                runCatching { getObjectInfo(handle) }
                    .onSuccess { if (!it.isFolder) infos.add(it) }
                    .onFailure { Log.d(TAG, "Standard ObjectInfo failed handle=$handle: ${it.message}") }
            }
        }
        return infos.sortedByDescending { it.handle }
    }

    private suspend fun hiddenObjectInfos(
        specifiedHandles: List<Int>,
        currentInfos: List<ObjectInfo>,
    ): List<ObjectInfo> {
        val candidates = hiddenHandleCandidates(specifiedHandles)
        val existing = currentInfos.map { it.handle }.toSet()
        return candidates.filterNot { it in existing }.mapNotNull { handle ->
            runCatching { getObjectInfo(handle) }
                .onFailure { Log.d(TAG, "Hidden ObjectInfo failed handle=$handle: ${it.message}") }
                .getOrNull()
        }
    }

    suspend fun hiddenStillObjectInfos(knownHandles: List<Int>): List<ObjectInfo> {
        val gapCandidates = CameraVendorHiddenObjectProbePolicy.backgroundHiddenHandleCandidates(knownHandles)
        val forwardCandidates = CameraVendorHiddenObjectProbePolicy.forwardProbeCandidates(knownHandles)
        val allCandidates = (gapCandidates + forwardCandidates).distinct()
        if (allCandidates.isEmpty()) {
            diagnostic("Gallery hidden metadata skipped because no candidates found")
            return emptyList()
        }
        diagnostic("Gallery hidden metadata probing candidates=${allCandidates.size} gaps=${gapCandidates.size} forward=${forwardCandidates.size}")
        val known = knownHandles.toSet()
        var consecutiveForwardFailures = 0
        val infos = mutableListOf<ObjectInfo>()
        for (handle in allCandidates) {
            if (handle in known) continue
            val info = runCatching { getObjectInfo(handle) }
                .onSuccess {
                    consecutiveForwardFailures = 0
                    if (it.isHeif || it.isRaw || it.isVideo) {
                        diagnostic(
                            "Gallery hidden metadata found handle=$handle " +
                                "format=0x${it.format.toString(16)} label=${it.formatLabel} filename=${it.filename}",
                        )
                    }
                }
                .onFailure {
                    consecutiveForwardFailures++
                    Log.d(TAG, "Background hidden ObjectInfo failed handle=$handle: ${it.message}")
                }
                .getOrNull()
            if (info != null && (info.isHeif || info.isRaw || info.isVideo)) {
                infos.add(info)
            }
            // Stop forward probing after too many consecutive failures
            if (handle in forwardCandidates.toSet() && consecutiveForwardFailures >= 8) {
                diagnostic("Gallery hidden forward probe stopped after $consecutiveForwardFailures consecutive failures")
                break
            }
        }
        diagnostic("Gallery hidden metadata selected=${infos.size}")
        return mergeInfos(infos)
    }

    private suspend fun forwardObjectInfos(
        specifiedHandles: List<Int>,
        currentInfos: List<ObjectInfo>,
    ): List<ObjectInfo> {
        val maxHandle = specifiedHandles.maxOrNull() ?: return emptyList()
        val existing = currentInfos.map { it.handle }.toMutableSet()
        val infos = mutableListOf<ObjectInfo>()
        var consecutiveFailures = 0
        for (handle in (maxHandle + 1)..(maxHandle + 120)) {
            if (handle in existing) continue
            val info = runCatching { getObjectInfo(handle) }.getOrNull()
            if (info != null) {
                infos.add(info)
                existing.add(handle)
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                val limit = if (infos.isEmpty()) 8 else 3
                if (consecutiveFailures >= limit) break
            }
        }
        return infos
    }

    private fun hiddenHandleCandidates(handles: List<Int>): List<Int> {
        val unique = handles.toSet()
        val min = unique.minOrNull() ?: return emptyList()
        val max = unique.maxOrNull() ?: return emptyList()
        if (max < min || max - min > CameraVendorHiddenObjectProbePolicy.MAX_HANDLE_RANGE) return emptyList()

        val candidates = linkedSetOf<Int>()
        for (handle in handles) {
            if (handle > 0 && handle - 1 !in unique) candidates.add(handle - 1)
            if (handle < Int.MAX_VALUE && handle + 1 !in unique) candidates.add(handle + 1)
        }
        val sorted = unique.sorted()
        for (i in 0 until sorted.lastIndex) {
            val lower = sorted[i]
            val upper = sorted[i + 1]
            val gapSize = upper - lower - 1
            if (gapSize in 1..8) {
                for (candidate in (lower + 1) until upper) candidates.add(candidate)
            }
        }
        return candidates.toList()
    }

    private suspend fun readObjectByPartialObjects(handle: Int, expectedSize: Int?): ByteArray {
        val maxBytes = expectedSize?.takeIf { it > 0 }
            ?: CameraVendorReferenceApp.PARTIAL_MAX_BYTES_WITHOUT_KNOWN_SIZE
        val chunks = mutableListOf<ByteArray>()
        var offset = 0
        var readSize = CameraVendorReferenceApp.PARTIAL_FILE_READ_SIZE
        var previousLastByte: Byte? = null
        while (offset < maxBytes) {
            val remaining = maxBytes - offset
            val requestSize = minOf(readSize, remaining)
            val chunk = try {
                getPartialObject(handle, offset, requestSize)
            } catch (e: Throwable) {
                if (readSize > CameraVendorReferenceApp.PARTIAL_INITIAL_READ_SIZE) {
                    readSize = CameraVendorReferenceApp.PARTIAL_INITIAL_READ_SIZE
                    continue
                }
                throw e
            }
            if (chunk.isEmpty()) break
            chunks.add(chunk)
            offset += chunk.size
            Log.d(
                TAG,
                "Partial chunk handle=$handle offset=$offset/${maxBytes} bytes=${chunk.size} readSize=$readSize",
            )
            if (
                CameraVendorPartialObjectReadPolicy.shouldStopAfterChunk(
                    expectedSize = expectedSize,
                    previousLastByte = previousLastByte,
                    chunk = chunk,
                    offset = offset,
                    maxBytes = maxBytes,
                )
            ) {
                return flatten(chunks)
            }
            previousLastByte = chunk.last()
        }
        return flatten(chunks)
    }

    private suspend fun readObjectByPartialObjectsToStream(
        handle: Int,
        expectedSize: Int?,
        output: OutputStream,
    ): Long {
        val maxBytes = expectedSize?.takeIf { it > 0 }
            ?: CameraVendorReferenceApp.PARTIAL_MAX_BYTES_WITHOUT_KNOWN_SIZE
        var offset = 0
        var totalBytes = 0L
        var readSize = CameraVendorReferenceApp.PARTIAL_FILE_READ_SIZE
        var previousLastByte: Byte? = null
        while (offset < maxBytes) {
            val remaining = maxBytes - offset
            val requestSize = minOf(readSize, remaining)
            val chunk = try {
                getPartialObject(handle, offset, requestSize)
            } catch (e: Throwable) {
                if (readSize > CameraVendorReferenceApp.PARTIAL_INITIAL_READ_SIZE) {
                    readSize = CameraVendorReferenceApp.PARTIAL_INITIAL_READ_SIZE
                    continue
                }
                throw e
            }
            if (chunk.isEmpty()) break
            output.write(chunk)
            totalBytes += chunk.size
            offset += chunk.size
            Log.d(
                TAG,
                "Partial stream chunk handle=$handle offset=$offset/${maxBytes} bytes=${chunk.size} readSize=$readSize",
            )
            if (
                CameraVendorPartialObjectReadPolicy.shouldStopAfterChunk(
                    expectedSize = expectedSize,
                    previousLastByte = previousLastByte,
                    chunk = chunk,
                    offset = offset,
                    maxBytes = maxBytes,
                )
            ) {
                return totalBytes
            }
            previousLastByte = chunk.last()
        }
        return totalBytes
    }

    private fun mergeInfos(infos: List<ObjectInfo>): List<ObjectInfo> =
        infos.associateBy { it.handle }.values.sortedByDescending { it.handle }

    private fun List<Int>.summaryLabel(name: String): String {
        if (isEmpty()) return "$name=0"
        return "$name=$size min=${minOrNull()} max=${maxOrNull()}"
    }

    private fun flatten(chunks: List<ByteArray>): ByteArray {
        val total = chunks.sumOf { it.size }
        val out = ByteArray(total)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(out, offset)
            offset += chunk.size
        }
        return out
    }

    private fun hasJpegEndMarker(previousLastByte: Byte?, chunk: ByteArray): Boolean {
        if (chunk.isEmpty()) return false
        if (previousLastByte == 0xFF.toByte() && chunk.first() == 0xD9.toByte()) return true
        return chunk.size >= 2 &&
            chunk[chunk.size - 2] == 0xFF.toByte() &&
            chunk[chunk.size - 1] == 0xD9.toByte()
    }

    private fun placeholderObjectInfo(handle: Int): ObjectInfo = ObjectInfo(
        handle = handle,
        storageId = 0,
        format = PtpObjectFormat.UNDEFINED,
        compressedSize = 0,
        thumbFormat = 0,
        thumbCompressedSize = 0,
        thumbPixWidth = 0,
        thumbPixHeight = 0,
        imagePixWidth = 0,
        imagePixHeight = 0,
        parentObject = 0,
        filename = "0x%08X".format(handle),
        captureDate = "",
    )

    private fun ByteArray.headHex(byteCount: Int = 16): String {
        return take(byteCount).joinToString("") { "%02x".format(it) }
    }

    private fun ByteArray.tailHex(byteCount: Int = 96): String {
        return takeLast(byteCount).joinToString("") { "%02x".format(it) }
    }

    private fun diagnostic(message: String) {
        diagnosticContext?.let { DiagnosticLog.append(it, TAG, message) }
    }
}

internal enum class CameraVendorDevicePropertyWidth {
    UINT16,
    UINT32,
}

internal data class CameraVendorDevicePropertyValue(
    val code: Int,
    val value: Int,
    val width: CameraVendorDevicePropertyWidth,
)

internal object CameraVendorDownloadModePolicy {
    private const val RESIZE_RATE_S = 1
    private const val FORCE_COMPRESSED = 1
    private const val FORCE_ORIGINAL = 2
    private const val FORCE_RESET = 0

    fun prepareProperties(
        mode: TransferDownloadMode,
        objectInfo: ObjectInfo? = null,
    ): List<CameraVendorDevicePropertyValue> =
        when (mode) {
            TransferDownloadMode.COMPRESSED -> listOf(
                CameraVendorDevicePropertyValue(
                    code = CameraVendorDevicePropCode.OBJECT_COMPRESSION_SETTING,
                    value = RESIZE_RATE_S,
                    width = CameraVendorDevicePropertyWidth.UINT16,
                ),
                imageForceCompression(FORCE_COMPRESSED),
            )
            TransferDownloadMode.ORIGINAL -> listOf(imageForceCompression(FORCE_ORIGINAL))
        }

    fun prepareProperty(
        mode: TransferDownloadMode,
        objectInfo: ObjectInfo? = null,
    ): CameraVendorDevicePropertyValue =
        prepareProperties(mode, objectInfo).last()

    fun resetProperty(prepareProperty: CameraVendorDevicePropertyValue): CameraVendorDevicePropertyValue? =
        when (prepareProperty.code) {
            CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION -> prepareProperty.copy(value = FORCE_RESET)
            else -> null
        }

    private fun imageForceCompression(value: Int): CameraVendorDevicePropertyValue =
        CameraVendorDevicePropertyValue(
            code = CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION,
            value = value,
            width = CameraVendorDevicePropertyWidth.UINT16,
        )
}

data class PtpThumbnailData(
    val data: ByteArray,
    val objectInfo: ObjectInfo? = null,
)

internal object CameraVendorThumbnailReadPolicy {
    const val STANDARD_THUMB_TIMEOUT_MS = 3_000
    const val VENDOR_EXTENSION_THUMB_TIMEOUT_MS = 3_000

    fun shouldPrimeObjectContextBeforeStandardThumbnail(): Boolean = true

    fun shouldPrimeObjectContextBeforePartialFallback(): Boolean = false

    fun shouldReadPartialPreviewAsThumbnailFallback(): Boolean = false

    fun shouldTryVendorExtensionThumbnailFirst(): Boolean = false

    fun shouldReadPartialPreviewBeforeStandardThumbnail(objectInfo: ObjectInfo?): Boolean {
        return false
    }

    fun shouldRejectIncompletePartialPreview(data: ByteArray): Boolean =
        isJpeg(data) && !hasJpegEndMarker(data)

    private fun isJpeg(data: ByteArray): Boolean =
        data.size >= 2 && data[0] == 0xFF.toByte() && data[1] == 0xD8.toByte()

    private fun hasJpegEndMarker(data: ByteArray): Boolean =
        data.size >= 2 && data[data.lastIndex - 1] == 0xFF.toByte() && data[data.lastIndex] == 0xD9.toByte()

}

internal object CameraVendorPreviewImageReadPolicy {
    fun shouldReadCompressedPreview(objectInfo: ObjectInfo): Boolean =
        (objectInfo.isJpeg || objectInfo.isHeif) &&
            objectInfo.compressedSize in 1..CameraVendorReferenceApp.PARTIAL_PREVIEW_READ_SIZE
}

internal object CameraVendorPartialObjectReadPolicy {
    fun shouldStopAfterChunk(
        expectedSize: Int?,
        previousLastByte: Byte?,
        chunk: ByteArray,
        offset: Int,
        maxBytes: Int,
    ): Boolean {
        if (offset >= maxBytes) return true
        return expectedSize == null && hasJpegEndMarker(previousLastByte, chunk)
    }

    private fun hasJpegEndMarker(previousLastByte: Byte?, chunk: ByteArray): Boolean {
        if (chunk.isEmpty()) return false
        if (previousLastByte == 0xFF.toByte() && chunk.first() == 0xD9.toByte()) return true
        return chunk.size >= 2 &&
            chunk[chunk.size - 2] == 0xFF.toByte() &&
            chunk[chunk.size - 1] == 0xD9.toByte()
    }
}
