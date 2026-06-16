package com.camtransfer.service

object CameraVendorCameraIdentityPolicy {
    fun cameraId(
        serialNumber: String?,
        deviceName: String?,
        bluetoothAddress: String? = null,
        wifiSsid: String? = null,
    ): String {
        val serial = serialNumber.cleanedIdentityPart()
        val name = deviceName.cleanedIdentityPart()
        if (serial.isNotBlank() && name.isNotBlank()) return "${serial}_$name"

        return listOf(
            serial,
            name,
            bluetoothAddress.cleanedIdentityPart(),
            wifiSsid.cleanedIdentityPart(),
        ).firstOrNull { it.isNotBlank() }.orEmpty()
    }

    fun matches(
        remembered: CameraVendorPairedCameraRecord,
        candidateCameraId: String?,
        candidateSerialNumber: String?,
        candidateDeviceName: String?,
        candidateBluetoothAddress: String?,
    ): Boolean {
        val rememberedId = remembered.cameraId.cleanedIdentityPart()
        val candidateId = candidateCameraId.cleanedIdentityPart()
        if (rememberedId.isOfficialCameraId() && candidateId.isOfficialCameraId()) return rememberedId == candidateId

        val rememberedSerial = remembered.serialNumber.cleanedIdentityPart()
        val candidateSerial = candidateSerialNumber.cleanedIdentityPart()
        if (rememberedSerial.isNotBlank() && candidateSerial.isNotBlank()) return rememberedSerial == candidateSerial

        val rememberedAddress = remembered.bluetoothAddress.cleanedAddress()
        val candidateAddress = candidateBluetoothAddress.cleanedAddress()
        if (rememberedAddress.isNotBlank() && candidateAddress.isNotBlank()) return rememberedAddress == candidateAddress

        val rememberedName = remembered.deviceName.cleanedIdentityPart()
        val candidateName = candidateDeviceName.cleanedIdentityPart()
        return rememberedName.isNotBlank() && candidateName.isNotBlank() && rememberedName == candidateName
    }

    private fun String?.cleanedIdentityPart(): String =
        this?.trim().orEmpty()

    private fun String?.cleanedAddress(): String =
        this?.trim()?.uppercase().orEmpty()

    private fun String.isOfficialCameraId(): Boolean =
        contains("_")
}
