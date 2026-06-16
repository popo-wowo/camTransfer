package com.camtransfer.model

import com.camtransfer.protocol.PtpObjectFormat

data class ObjectInfo(
    val handle: Int,
    val storageId: Int,
    val format: Int,
    val compressedSize: Int,
    val thumbFormat: Int,
    val thumbCompressedSize: Int,
    val thumbPixWidth: Int,
    val thumbPixHeight: Int,
    val imagePixWidth: Int,
    val imagePixHeight: Int,
    val parentObject: Int,
    val filename: String,
    val captureDate: String,
    val orientation: Int? = null,
) {
    val isJpeg: Boolean get() = format == PtpObjectFormat.JPEG
    val isHeif: Boolean get() = format == PtpObjectFormat.HEIF ||
        filename.endsWith(".HEIF", ignoreCase = true) ||
        filename.endsWith(".HEIC", ignoreCase = true) ||
        filename.endsWith(".HIF", ignoreCase = true)
    val isRaw: Boolean get() = format == PtpObjectFormat.CAMERA_VENDOR_RAF ||
        format == PtpObjectFormat.CAMERA_VENDOR_RAF_ALT
    val isVideo: Boolean get() = format == PtpObjectFormat.MOV || format == PtpObjectFormat.MP4
    val isFolder: Boolean get() = format == PtpObjectFormat.ASSOCIATION

    val formatLabel: String get() = when {
        isJpeg -> "JPG"
        isHeif -> "HEIF"
        isRaw -> "RAW"
        isVideo -> "Video"
        else -> "0x%04X".format(format)
    }
}

data class CameraFile(
    val info: ObjectInfo,
    val thumbnail: ByteArray? = null,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CameraFile) return false
        return info == other.info && thumbnail.contentEqualsNullable(other.thumbnail)
    }
    override fun hashCode(): Int =
        31 * info.hashCode() + (thumbnail?.contentHashCode() ?: 0)

    private fun ByteArray?.contentEqualsNullable(other: ByteArray?): Boolean {
        if (this == null || other == null) return this === other
        return contentEquals(other)
    }
}

enum class TransferState { PENDING, DOWNLOADING, SAVING, DONE, ERROR }

data class TransferItem(
    val file: CameraFile,
    val state: TransferState = TransferState.PENDING,
    val progress: Float = 0f,
    val error: String? = null,
)
