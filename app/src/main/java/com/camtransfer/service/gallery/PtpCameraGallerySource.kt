package com.camtransfer.service.gallery

import android.content.Context
import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.CameraVendorGalleryDiscoveryPolicy
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.service.CameraFileSource
import com.camtransfer.service.CameraThumbnail
import com.camtransfer.service.DiagnosticLog

private const val TAG = "PtpCameraGallerySource"

class PtpCameraGallerySource(
    override val context: Context,
    private val connection: PtpConnection,
    private val commands: PtpCommands,
) : CameraFileSource {
    override suspend fun listFiles(): List<CameraFile> {
        DiagnosticLog.append(context, TAG, "Reading gallery object infos")
        val files = commands.galleryObjectInfos()
            .filterNot { it.isFolder || it.isVideo }
            .map { CameraFile(it) }
            .sortedWith(compareByDescending<CameraFile> { it.info.captureDate }.thenByDescending { it.info.handle })
        DiagnosticLog.append(context, TAG, "Gallery object infos visible=${files.size}")
        return files
    }

    override suspend fun fastInitialFiles(): List<CameraFile> {
        if (connection.cameraVendorSpecifiedObjectHandles.isEmpty()) {
            runCatching { connection.loadCameraVendorGalleryObjectHandles() }
                .onFailure {
                    DiagnosticLog.append(context, TAG, "Fast gallery handle initialization failed", it)
                }
        }
        val handles = CameraVendorGalleryDiscoveryPolicy.initialPlaceholderHandles(
            connection.cameraVendorSpecifiedObjectHandles
        )
        if (handles.isEmpty()) return emptyList()
        DiagnosticLog.append(context, TAG, "Fast gallery placeholders count=${handles.size}")
        return handles.map { handle -> CameraFile(placeholderObjectInfo(handle)) }
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
                    "Resolved file metadata handle=$handle filename=${file.info.filename} expected=${file.info.compressedSize}",
                )
            }
            .onFailure { error ->
                DiagnosticLog.append(context, TAG, "Resolve file metadata failed handle=$handle", error)
            }
            .getOrNull()
    }

    override suspend fun getPreviewImage(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get preview image handle=$handle")
        return commands.getPreviewImage(handle)
    }

    override suspend fun getFile(handle: Int): ByteArray {
        DiagnosticLog.append(context, TAG, "Get original file handle=$handle")
        val expectedSize = runCatching { commands.getObjectInfo(handle).compressedSize }.getOrNull()
        val data = commands.getObject(handle, expectedSize)
        DiagnosticLog.append(context, TAG, "Original file loaded handle=$handle bytes=${data.size} expected=$expectedSize")
        return data
    }

    override suspend fun disconnect() = Unit

    private fun placeholderObjectInfo(handle: Int): ObjectInfo = ObjectInfo(
        handle = handle,
        storageId = 0,
        format = PtpObjectFormat.JPEG,
        compressedSize = 0,
        thumbFormat = 0,
        thumbCompressedSize = 0,
        thumbPixWidth = 0,
        thumbPixHeight = 0,
        imagePixWidth = 0,
        imagePixHeight = 0,
        parentObject = 0,
        filename = "0x%08X.JPG".format(handle),
        captureDate = "",
    )
}
