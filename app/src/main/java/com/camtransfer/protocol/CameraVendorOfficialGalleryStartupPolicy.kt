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
