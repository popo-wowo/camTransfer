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
) {
    val isJpeg: Boolean get() = format == PtpObjectFormat.JPEG
    val isRaw: Boolean get() = format == PtpObjectFormat.CAMERA_VENDOR_RAF
    val isVideo: Boolean get() = format == PtpObjectFormat.MOV || format == PtpObjectFormat.MP4
    val isFolder: Boolean get() = format == PtpObjectFormat.ASSOCIATION

    val formatLabel: String get() = when {
        isJpeg -> "JPG"
        isRaw -> "RAW"
        isVideo -> "Video"
        else -> "Unknown"
    }
}

data class CameraFile(
    val info: ObjectInfo,
    val thumbnail: ByteArray? = null,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is CameraFile) return false
        return info == other.info
    }
    override fun hashCode(): Int = info.hashCode()
}

enum class TransferState { PENDING, DOWNLOADING, SAVING, DONE, ERROR }

data class TransferItem(
    val file: CameraFile,
    val state: TransferState = TransferState.PENDING,
    val progress: Float = 0f,
    val error: String? = null,
)
