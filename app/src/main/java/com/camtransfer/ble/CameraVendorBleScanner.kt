package com.camtransfer.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

private const val TAG = "CameraVendorBleScanner"

class CameraVendorBleScanner(private val context: Context) {

    @SuppressLint("MissingPermission")
    fun scan(): Flow<ScanResult> = callbackFlow {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val scanner = manager.adapter.bluetoothLeScanner
            ?: throw IllegalStateException("蓝牙未开启")

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (isLikelyCameraVendorCamera(result)) {
                    Log.d(TAG, "Match: name=${result.device.name}, addr=${result.device.address}")
                    trySend(result)
                }
            }
            override fun onScanFailed(errorCode: Int) {
                Log.e(TAG, "Scan failed: $errorCode")
                close(Exception("BLE scan failed: $errorCode"))
            }
        }

        val filters = CameraVendorBleProfile.CAMERA_VENDOR_ADVERT_UUIDS.map { uuid ->
            ScanFilter.Builder().setServiceUuid(ParcelUuid(uuid)).build()
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(filters, settings, callback)
        Log.d(TAG, "Scan started with ${filters.size} UUID filters")

        awaitClose {
            scanner.stopScan(callback)
            Log.d(TAG, "Scan stopped")
        }
    }

    @SuppressLint("MissingPermission")
    fun scanAll(): Flow<ScanResult> = callbackFlow {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val scanner = manager.adapter.bluetoothLeScanner
            ?: throw IllegalStateException("蓝牙未开启")

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (isLikelyCameraVendorCamera(result)) {
                    Log.d(TAG, "Match (unfiltered): name=${result.device.name}, addr=${result.device.address}")
                    trySend(result)
                }
            }
            override fun onScanFailed(errorCode: Int) {
                close(Exception("BLE scan failed: $errorCode"))
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        scanner.startScan(null, settings, callback)
        Log.d(TAG, "Unfiltered scan started")

        awaitClose {
            scanner.stopScan(callback)
        }
    }

    companion object {
        @SuppressLint("MissingPermission")
        fun isLikelyCameraVendorCamera(result: ScanResult): Boolean {
            val record = result.scanRecord ?: return false

            val serviceUuids = record.serviceUuids?.map { it.uuid } ?: emptyList()
            if (serviceUuids.any { it in CameraVendorBleProfile.CAMERA_VENDOR_ADVERT_UUIDS }) return true

            val name = result.device.name ?: record.deviceName ?: ""
            if (name.isNotEmpty()) {
                val upper = name.uppercase()
                if (
                    "CAMERA_VENDOR" in upper ||
                    "FUJIFILM" in upper ||
                    upper.startsWith("X-") ||
                    upper.startsWith("GFX") ||
                    upper.startsWith("CAMERA-")
                ) return true
            }

            val mfgData = record.manufacturerSpecificData
            if (mfgData != null) {
                for (i in 0 until mfgData.size()) {
                    val bytes = mfgData.valueAt(i)
                    if (bytes != null && bytes.size >= 2) {
                        if ((bytes[0].toInt() and 0xFF == 0xD8 && bytes[1].toInt() and 0xFF == 0x04) ||
                            (bytes[0].toInt() and 0xFF == 0x04 && bytes[1].toInt() and 0xFF == 0xD8)) {
                            return true
                        }
                    }
                }
            }

            return false
        }
    }
}
