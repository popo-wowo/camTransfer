package com.camtransfer.service.gallery

import android.content.Context
import com.camtransfer.model.CameraFile
import com.camtransfer.model.CameraFileFormatHint
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.protocol.CameraVendorGalleryDiscoveryPolicy
import com.camtransfer.protocol.CameraVendorHiddenObjectProbePolicy
import com.camtransfer.protocol.CameraVendorOfficialGalleryStartupPolicy
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.protocol.CameraVendorSearchMode
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.CameraThumbnail
import com.camtransfer.service.DiagnosticLog
import java.io.OutputStream

private const val TAG = "PtpCameraGallerySource"

class PtpCameraGallerySource(
    override val context: Context,
    private val connection: PtpConnection,
    private val commands: PtpCommands,
) : CameraFileSource {
    override suspend fun listFiles(): List<CameraFile> {
        DiagnosticLog.append(context, TAG, "Reading gallery object infos")
        val files = commands.galleryObjectInfos()
            .filterNot { it.isFolder }
            .map { CameraFile(it) }
            .sortedWith(compareByDescending<CameraFile> { it.info.captureDate }.thenByDescending { it.info.handle })
        DiagnosticLog.append(context, TAG, "Gallery object infos visible=${files.size}")
        return files
    }

    override suspend fun fastInitialFiles(): List<CameraFile> {
        val handles = CameraVendorGalleryDiscoveryPolicy.initialPlaceholderHandles(
            connection.cameraVendorSpecifiedObjectHandles
        )
        if (handles.isEmpty()) return emptyList()
        val captureDatesByHandle = CameraVendorGalleryDiscoveryPolicy.captureDatesByHandle(
            specifiedHandles = connection.cameraVendorSpecifiedObjectHandles,
            countsByDate = connection.cameraVendorSpecifiedObjectCountsByDate,
        )
        val formatHintsByHandle = formatHintsByHandle()
        DiagnosticLog.append(
            context,
            TAG,
            "Fast gallery placeholders count=${handles.size} dateGroups=${connection.cameraVendorSpecifiedObjectCountsByDate.size} " +
                "datedPlaceholders=${captureDatesByHandle.size} formatHints=${formatHintsByHandle.size}",
        )
        return handles.map { handle ->
            CameraFile(
                placeholderObjectInfo(
                    handle = handle,
                    captureDate = captureDatesByHandle[handle].orEmpty(),
                ),
                formatHints = formatHintsByHandle[handle].orEmpty(),
            )
        }
    }

    override suspend fun getThumbnail(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get thumbnail handle=$handle")
        return commands.getThumb(handle)
    }

    override suspend fun getThumbnailWithInfo(handle: Int): CameraThumbnail {
        DiagnosticLog.append(context, TAG, "Get thumbnail handle=$handle")
        val thumbnail = commands.getThumbWithInfo(handle)
        val info = thumbnail.objectInfo
        DiagnosticLog.append(
            context,
            TAG,
            "Thumbnail info handle=$handle orientation=${info?.orientation?.toString() ?: "unknown"} " +
                "object=${info?.imagePixWidth ?: 0}x${info?.imagePixHeight ?: 0} " +
                "thumb=${info?.thumbPixWidth ?: 0}x${info?.thumbPixHeight ?: 0}",
        )
        return CameraThumbnail(
            data = thumbnail.data,
            file = info?.let(::CameraFile),
        )
    }

    override suspend fun resolveFile(handle: Int): CameraFile? {
        DiagnosticLog.append(context, TAG, "Resolve file metadata handle=$handle")
        return runCatching { CameraFile(commands.getObjectInfo(handle)) }
            .onSuccess { file ->
                DiagnosticLog.append(
                    context,
                    TAG,
                    "Resolved file metadata handle=$handle filename=${file.info.filename} " +
                        "format=0x${file.info.format.toString(16)} label=${file.info.formatLabel} " +
                        "expected=${file.info.compressedSize}",
                )
            }
            .onFailure { error ->
                DiagnosticLog.append(context, TAG, "Resolve file metadata failed handle=$handle", error)
            }
            .getOrNull()
    }

    override fun hiddenProbeCandidates(knownHandles: List<Int>): List<Int> {
        val gapCandidates = CameraVendorHiddenObjectProbePolicy.backgroundHiddenHandleCandidates(knownHandles)
        val forwardCandidates = CameraVendorHiddenObjectProbePolicy.forwardProbeCandidates(knownHandles)
        return (gapCandidates + forwardCandidates).distinct().filterNot { it in knownHandles.toSet() }
    }

    override suspend fun resolveForwardFiles(knownHandles: List<Int>): List<CameraFile> {
        val candidates = CameraVendorHiddenObjectProbePolicy.forwardProbeCandidates(knownHandles)
        if (candidates.isEmpty()) return emptyList()
        DiagnosticLog.append(context, TAG, "Forward probe candidates=${candidates.size}")
        val known = knownHandles.toSet()
        val files = mutableListOf<CameraFile>()
        var consecutiveFailures = 0
        for (handle in candidates) {
            if (handle in known) continue
            val info = runCatching { commands.getObjectInfo(handle) }
                .onSuccess { consecutiveFailures = 0 }
                .onFailure { consecutiveFailures++ }
                .getOrNull()
            if (info != null && !info.isFolder) {
                files.add(CameraFile(info))
            }
            if (consecutiveFailures >= 8) break
        }
        DiagnosticLog.append(context, TAG, "Forward probe found=${files.size}")
        return files.sortedByDescending { it.info.handle }
    }

    override suspend fun resolveAdditionalFiles(knownHandles: List<Int>): List<CameraFile> {
        val files = commands.hiddenStillObjectInfos(knownHandles)
            .filterNot { it.isFolder }
            .filter { it.isHeif || it.isRaw || it.isVideo }
            .map { CameraFile(it) }
            .sortedByDescending { it.info.handle }
        DiagnosticLog.append(context, TAG, "Resolved additional hidden files count=${files.size}")
        return files
    }

    override suspend fun getPreviewImage(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get preview image handle=$handle")
        return commands.getPreviewImage(handle)
    }

    override suspend fun getFile(
        handle: Int,
        downloadMode: TransferDownloadMode,
    ): ByteArray {
        DiagnosticLog.append(context, TAG, "Get file handle=$handle mode=${downloadMode.name.lowercase()}")
        val expectedInfo = runCatching { commands.getObjectInfo(handle) }.getOrNull()
        val expectedSize = expectedInfo?.compressedSize
        val data = commands.getObject(
            handle = handle,
            expectedSize = expectedSize,
            downloadMode = downloadMode,
            objectInfo = expectedInfo,
        )
        DiagnosticLog.append(
            context,
            TAG,
            "File loaded handle=$handle bytes=${data.size} expected=$expectedSize mode=${downloadMode.name.lowercase()}",
        )
        return data
    }

    override suspend fun writeFile(
        handle: Int,
        downloadMode: TransferDownloadMode,
        output: OutputStream,
    ): Long {
        DiagnosticLog.append(context, TAG, "Stream file handle=$handle mode=${downloadMode.name.lowercase()}")
        val expectedInfo = runCatching { commands.getObjectInfo(handle) }.getOrNull()
        val expectedSize = expectedInfo?.compressedSize
        val bytes = commands.writeObjectToStream(
            handle = handle,
            expectedSize = expectedSize,
            downloadMode = downloadMode,
            objectInfo = expectedInfo,
            output = output,
        )
        DiagnosticLog.append(
            context,
            TAG,
            "File streamed handle=$handle bytes=$bytes expected=$expectedSize mode=${downloadMode.name.lowercase()}",
        )
        return bytes
    }

    override suspend fun disconnect() = Unit

    private fun formatHintsByHandle(): Map<Int, Set<CameraFileFormatHint>> {
        val handlesByMask = connection.cameraVendorSpecifiedObjectHandlesByFormatMask
        if (handlesByMask.isEmpty()) return emptyMap()

        val hints = linkedMapOf<Int, MutableSet<CameraFileFormatHint>>()
        fun add(handles: Iterable<Int>, hint: CameraFileFormatHint) {
            handles.forEach { handle ->
                hints.getOrPut(handle) { linkedSetOf() }.add(hint)
            }
        }

        add(handlesByMask[CameraVendorSearchMode.FORMAT_JPEG].orEmpty(), CameraFileFormatHint.JPG)
        add(handlesByMask[CameraVendorSearchMode.FORMAT_MOV].orEmpty(), CameraFileFormatHint.VIDEO)
        add(handlesByMask[CameraVendorSearchMode.FORMAT_MP4].orEmpty(), CameraFileFormatHint.VIDEO)

        val baselineHandles = handlesByMask[CameraVendorOfficialGalleryStartupPolicy.initialObjectFormatMask()]
            .orEmpty()
            .toSet()
        val expandedStillHandles = listOfNotNull(
            handlesByMask[CameraVendorSearchMode.FORMAT_HEIF],
            handlesByMask[CameraVendorSearchMode.FORMAT_RAW],
        )
            .maxByOrNull { it.size }
            .orEmpty()
            .filterNot { it in baselineHandles }
        add(expandedStillHandles, CameraFileFormatHint.EXTENDED_STILL_CANDIDATE)

        return hints
    }

    private fun placeholderObjectInfo(handle: Int, captureDate: String = ""): ObjectInfo = ObjectInfo(
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
        captureDate = captureDate,
    )
}
