package com.camtransfer.service

import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration

data class CameraVendorPairedCameraStoreUpdate(
    val records: List<CameraVendorPairedCameraRecord>,
    val selectedCameraId: String,
)

object CameraVendorPairedCameraStorePolicy {
    fun upsert(
        records: List<CameraVendorPairedCameraRecord>,
        record: CameraVendorPairedCameraRecord,
    ): List<CameraVendorPairedCameraRecord> {
        if (record.cameraId.isBlank()) return records
        val updated = records.toMutableList()
        val index = updated.indexOfFirst { it.cameraId == record.cameraId }
        if (index >= 0) {
            updated[index] = record
        } else {
            updated += record
        }
        return updated
    }

    fun remove(
        records: List<CameraVendorPairedCameraRecord>,
        cameraId: String,
    ): List<CameraVendorPairedCameraRecord> =
        records.filterNot { it.cameraId == cameraId }

    fun saveAndSelect(
        records: List<CameraVendorPairedCameraRecord>,
        record: CameraVendorPairedCameraRecord,
    ): CameraVendorPairedCameraStoreUpdate =
        CameraVendorPairedCameraStoreUpdate(
            records = upsert(records, record),
            selectedCameraId = record.cameraId,
        )

    fun selectedRecord(
        records: List<CameraVendorPairedCameraRecord>,
        selectedCameraId: String?,
    ): CameraVendorPairedCameraRecord? {
        if (records.isEmpty()) return null
        selectedCameraId?.takeIf { it.isNotBlank() }?.let { selected ->
            records.firstOrNull { it.cameraId == selected }?.let { return it }
        }
        return records.maxWithOrNull(compareBy<CameraVendorPairedCameraRecord> { it.lastConnectedAtMillis }.thenBy { it.deviceName })
    }

    fun encodeRecords(records: List<CameraVendorPairedCameraRecord>): String =
        records.joinToString("\n", transform = ::encodeRecord)

    fun decodeRecords(raw: String?): List<CameraVendorPairedCameraRecord> =
        raw
            ?.split("\n")
            ?.mapNotNull { decodeRecord(it) }
            .orEmpty()

    fun encodeWifiConfiguration(configuration: CameraVendorWifiNetworkConfiguration): String {
        return listOf(
            configuration.ssid.encodeField(),
            configuration.passphrase.encodeField(),
            configuration.isHidden.toString(),
            configuration.bssid.orEmpty().encodeField(),
        ).joinToString("|")
    }

    fun decodeWifiConfiguration(raw: String): CameraVendorWifiNetworkConfiguration? {
        val parts = raw.split("|")
        if (parts.size !in 3..4) return null
        val ssid = parts[0].decodeField().takeIf { it.isNotBlank() } ?: return null
        return CameraVendorWifiNetworkConfiguration(
            ssid = ssid,
            passphrase = parts[1].decodeField(),
            isHidden = parts[2].toBoolean(),
            bssid = parts.getOrNull(3)?.decodeField()?.takeIf { it.isNotBlank() },
        )
    }

    private fun encodeRecord(record: CameraVendorPairedCameraRecord): String {
        val wifi = record.wifiConfigurations
            .joinToString(";") { encodeWifiConfiguration(it).encodeField() }
        return listOf(
            record.cameraId.encodeField(),
            record.deviceName.encodeField(),
            record.serialNumber.encodeField(),
            record.bluetoothAddress.orEmpty().encodeField(),
            record.lastConnectedAtMillis.toString(),
            wifi,
        ).joinToString("|")
    }

    private fun decodeRecord(raw: String): CameraVendorPairedCameraRecord? {
        if (raw.isBlank()) return null
        val parts = raw.split("|")
        if (parts.size < 6) return null
        val cameraId = parts[0].decodeField().takeIf { it.isNotBlank() } ?: return null
        val wifiConfigurations = parts[5]
            .takeIf { it.isNotBlank() }
            ?.split(";")
            ?.mapNotNull { decodeWifiConfiguration(it.decodeField()) }
            .orEmpty()
        return CameraVendorPairedCameraRecord(
            cameraId = cameraId,
            deviceName = parts[1].decodeField(),
            serialNumber = parts[2].decodeField(),
            bluetoothAddress = parts[3].decodeField().takeIf { it.isNotBlank() },
            lastConnectedAtMillis = parts[4].toLongOrNull() ?: 0L,
            wifiConfigurations = wifiConfigurations,
        )
    }

    private fun String.encodeField(): String {
        return replace("%", "%25")
            .replace("|", "%7C")
            .replace("\n", "%0A")
            .replace(";", "%3B")
    }

    private fun String.decodeField(): String {
        return replace("%3B", ";")
            .replace("%0A", "\n")
            .replace("%7C", "|")
            .replace("%25", "%")
    }
}
