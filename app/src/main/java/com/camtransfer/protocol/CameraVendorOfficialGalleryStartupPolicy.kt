package com.camtransfer.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

enum class CameraVendorOfficialGalleryStartupOperation {
    SetFunctionMode,
    GetFunctionVersion,
    SetFunctionVersion,
    GetDualSlotStatus,
    GetLatestObjectInfo,
    GetExtensionThumb,
    GetSpecifiedObjectHandles,
}

object CameraVendorOfficialGalleryStartupPolicy {
    const val REMOTE_PHOTO_VIEW_EX_FUNCTION_VERSION = 3
    const val OPTIONAL_CONTEXT_PRIME_TIMEOUT_MS = 7_000

    fun initialObjectFormatMask(): Int = CameraVendorSearchMode.ALL_FORMATS

    fun expandedStillFormatMasks(): List<Int> =
        listOf(
            CameraVendorSearchMode.FORMAT_HEIF,
            CameraVendorSearchMode.FORMAT_RAW,
        )

    fun shouldReadCurrentObjectHandleSnapshotDuringBlockingStartup(): Boolean = false

    fun connectionStageOperations(): List<CameraVendorOfficialGalleryStartupOperation> =
        listOf(
            CameraVendorOfficialGalleryStartupOperation.SetFunctionMode,
            CameraVendorOfficialGalleryStartupOperation.GetFunctionVersion,
            CameraVendorOfficialGalleryStartupOperation.GetFunctionVersion,
            CameraVendorOfficialGalleryStartupOperation.SetFunctionVersion,
            CameraVendorOfficialGalleryStartupOperation.GetDualSlotStatus,
        )

    fun functionVersion(data: ByteArray): Int {
        require(data.size >= 4) { "Function version response too short: ${data.size}" }
        return ByteBuffer.wrap(data, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
    }
}
