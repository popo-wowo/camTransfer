package com.camtransfer.service

import android.content.Context
import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration

data class CameraVendorPairedCameraRecord(
    val deviceName: String,
    val serialNumber: String,
    val wifiConfigurations: List<CameraVendorWifiNetworkConfiguration>,
    val bluetoothAddress: String? = null,
    val cameraId: String = "",
    val lastConnectedAtMillis: Long = 0L,
)

class CameraVendorPairedCameraStore(context: Context) {
    private val prefs = context.getSharedPreferences("camera_vendor_pairing", Context.MODE_PRIVATE)

    fun load(): CameraVendorPairedCameraRecord? {
        val deviceName = prefs.getString(KEY_DEVICE_NAME, null)?.takeIf { it.isNotBlank() }
            ?: return null
        val serialNumber = prefs.getString(KEY_SERIAL_NUMBER, "") ?: ""
        val wifiConfigurations = prefs.getString(KEY_WIFI_CONFIGURATIONS, null)
            ?.split("\n")
            ?.mapNotNull { decodeWifiConfiguration(it) }
            .orEmpty()
        val bluetoothAddress = prefs.getString(KEY_BLUETOOTH_ADDRESS, null)?.takeIf { it.isNotBlank() }
        return CameraVendorPairedCameraRecord(
            deviceName = deviceName,
            serialNumber = serialNumber,
            wifiConfigurations = wifiConfigurations,
            bluetoothAddress = bluetoothAddress,
            cameraId = prefs.getString(KEY_CAMERA_ID, null)?.takeIf { it.isNotBlank() }
                ?: CameraVendorCameraIdentityPolicy.cameraId(
                    serialNumber = serialNumber,
                    deviceName = deviceName,
                    bluetoothAddress = bluetoothAddress,
                    wifiSsid = wifiConfigurations.firstOrNull()?.ssid,
                ),
        )
    }

    fun load(cameraId: String): CameraVendorPairedCameraRecord? =
        load()?.takeIf { it.cameraId == cameraId || cameraId.isBlank() }

    fun loadAll(): List<CameraVendorPairedCameraRecord> =
        load()?.let { listOf(it) }.orEmpty()

    fun selectedCameraId(): String? =
        load()?.cameraId

    fun select(cameraId: String) {
        val current = load() ?: return
        if (current.cameraId == cameraId) {
            prefs.edit().putString(KEY_CAMERA_ID, cameraId).apply()
        }
    }

    fun save(record: CameraVendorPairedCameraRecord) {
        forgetDeletedBluetoothAddress(record.bluetoothAddress)
        prefs.edit()
            .putString(KEY_DEVICE_NAME, record.deviceName)
            .putString(KEY_SERIAL_NUMBER, record.serialNumber)
            .putString(KEY_WIFI_CONFIGURATIONS, record.wifiConfigurations.joinToString("\n", transform = ::encodeWifiConfiguration))
            .putString(KEY_BLUETOOTH_ADDRESS, record.bluetoothAddress)
            .putString(KEY_CAMERA_ID, record.cameraId)
            .apply()
    }

    fun remove(cameraId: String) {
        if (load()?.cameraId == cameraId) clear()
    }

    fun clear() {
        prefs.edit()
            .remove(KEY_CAMERA_RECORDS)
            .remove(KEY_SELECTED_CAMERA_ID)
            .remove(KEY_MULTI_CAMERA_MIGRATED)
            .remove(KEY_DEVICE_NAME)
            .remove(KEY_SERIAL_NUMBER)
            .remove(KEY_WIFI_CONFIGURATIONS)
            .remove(KEY_BLUETOOTH_ADDRESS)
            .remove(KEY_CAMERA_ID)
            .apply()
    }

    fun rememberDeletedBluetoothAddresses(bluetoothAddresses: Collection<String>) {
        val normalizedAddresses = bluetoothAddresses
            .filter { it.isNotBlank() }
            .map(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
        if (normalizedAddresses.isEmpty()) return

        val deletedAddresses = deletedBluetoothAddresses().toMutableSet()
        deletedAddresses.addAll(normalizedAddresses)
        prefs.edit()
            .putStringSet(KEY_DELETED_BLUETOOTH_ADDRESSES, deletedAddresses)
            .apply()
    }

    fun deletedBluetoothAddresses(): Set<String> =
        prefs.getStringSet(KEY_DELETED_BLUETOOTH_ADDRESSES, emptySet())
            .orEmpty()
            .mapTo(mutableSetOf(), CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)

    private fun forgetDeletedBluetoothAddress(bluetoothAddress: String?) {
        if (bluetoothAddress.isNullOrBlank()) return
        val normalizedAddress = CameraVendorPairingForgetPolicy.normalizeBluetoothAddress(bluetoothAddress)
        val deletedAddresses = deletedBluetoothAddresses().toMutableSet()
        if (!deletedAddresses.remove(normalizedAddress)) return
        prefs.edit()
            .putStringSet(KEY_DELETED_BLUETOOTH_ADDRESSES, deletedAddresses)
            .apply()
    }

    private fun encodeWifiConfiguration(configuration: CameraVendorWifiNetworkConfiguration): String {
        return listOf(
            configuration.ssid.encodeField(),
            configuration.passphrase.encodeField(),
            configuration.isHidden.toString(),
            configuration.bssid.orEmpty().encodeField(),
        ).joinToString("|")
    }

    private fun decodeWifiConfiguration(raw: String): CameraVendorWifiNetworkConfiguration? {
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

    private fun String.encodeField(): String {
        return replace("%", "%25").replace("|", "%7C").replace("\n", "%0A")
    }

    private fun String.decodeField(): String {
        return replace("%0A", "\n").replace("%7C", "|").replace("%25", "%")
    }

    private companion object {
        const val KEY_CAMERA_RECORDS = "camera_records"
        const val KEY_SELECTED_CAMERA_ID = "selected_camera_id"
        const val KEY_MULTI_CAMERA_MIGRATED = "multi_camera_migrated"
        const val KEY_DEVICE_NAME = "device_name"
        const val KEY_SERIAL_NUMBER = "serial_number"
        const val KEY_WIFI_CONFIGURATIONS = "wifi_configurations"
        const val KEY_BLUETOOTH_ADDRESS = "bluetooth_address"
        const val KEY_CAMERA_ID = "camera_id"
        const val KEY_DELETED_BLUETOOTH_ADDRESSES = "deleted_bluetooth_addresses"
    }
}
