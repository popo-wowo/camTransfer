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

    fun load(): CameraVendorPairedCameraRecord? =
        CameraVendorPairedCameraStorePolicy.selectedRecord(
            records = loadAll(),
            selectedCameraId = prefs.getString(KEY_SELECTED_CAMERA_ID, null),
        )

    private fun legacyRecord(): CameraVendorPairedCameraRecord? {
        val deviceName = prefs.getString(KEY_DEVICE_NAME, null)?.takeIf { it.isNotBlank() }
            ?: return null
        val serialNumber = prefs.getString(KEY_SERIAL_NUMBER, "") ?: ""
        val wifiConfigurations = prefs.getString(KEY_WIFI_CONFIGURATIONS, null)
            ?.split("\n")
            ?.mapNotNull(CameraVendorPairedCameraStorePolicy::decodeWifiConfiguration)
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
        if (cameraId.isBlank()) {
            load()
        } else {
            loadAll().firstOrNull { it.cameraId == cameraId }
        }

    fun loadAll(): List<CameraVendorPairedCameraRecord> =
        CameraVendorPairedCameraStorePolicy.decodeRecords(prefs.getString(KEY_CAMERA_RECORDS, null))
            .ifEmpty {
                legacyRecord()?.let { listOf(it) }.orEmpty()
            }

    fun selectedCameraId(): String? =
        load()?.cameraId

    fun select(cameraId: String) {
        if (loadAll().none { it.cameraId == cameraId }) return
        prefs.edit().putString(KEY_SELECTED_CAMERA_ID, cameraId).apply()
    }

    fun save(record: CameraVendorPairedCameraRecord) {
        if (record.cameraId.isBlank()) return
        forgetDeletedBluetoothAddress(record.bluetoothAddress)
        val update = CameraVendorPairedCameraStorePolicy.saveAndSelect(loadAll(), record)
        prefs.edit()
            .putString(KEY_CAMERA_RECORDS, CameraVendorPairedCameraStorePolicy.encodeRecords(update.records))
            .putString(KEY_SELECTED_CAMERA_ID, update.selectedCameraId)
            .putBoolean(KEY_MULTI_CAMERA_MIGRATED, true)
            .putString(KEY_DEVICE_NAME, record.deviceName)
            .putString(KEY_SERIAL_NUMBER, record.serialNumber)
            .putString(
                KEY_WIFI_CONFIGURATIONS,
                record.wifiConfigurations.joinToString("\n", transform = CameraVendorPairedCameraStorePolicy::encodeWifiConfiguration),
            )
            .putString(KEY_BLUETOOTH_ADDRESS, record.bluetoothAddress)
            .putString(KEY_CAMERA_ID, record.cameraId)
            .apply()
    }

    fun remove(cameraId: String) {
        val updated = CameraVendorPairedCameraStorePolicy.remove(loadAll(), cameraId)
        if (updated.isEmpty()) {
            clear()
            return
        }
        val selected = CameraVendorPairedCameraStorePolicy.selectedRecord(
            records = updated,
            selectedCameraId = prefs.getString(KEY_SELECTED_CAMERA_ID, null)?.takeIf { it != cameraId },
        )
        prefs.edit()
            .putString(KEY_CAMERA_RECORDS, CameraVendorPairedCameraStorePolicy.encodeRecords(updated))
            .putString(KEY_SELECTED_CAMERA_ID, selected?.cameraId.orEmpty())
            .putBoolean(KEY_MULTI_CAMERA_MIGRATED, true)
            .apply()
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
