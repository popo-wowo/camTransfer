package com.camtransfer.service

import android.bluetooth.le.ScanResult
import android.content.Context
import android.util.Log
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.protocol.PtpCommands
import com.camtransfer.protocol.PtpConnection
import com.camtransfer.protocol.PtpObjectFormat
import com.camtransfer.wifi.WifiConnector
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

private const val TAG = "CameraService"

class CameraService(private val context: Context) {

    private val scanner = CameraVendorBleScanner(context)
    private var handshake: CameraVendorBleHandshake? = null
    private val wifiConnector = WifiConnector(context)
    val connection = PtpConnection()
    val commands by lazy { PtpCommands(connection) }

    suspend fun connectToCamera(onStatus: (String) -> Unit = {}) {
        onStatus("正在搜索相机...")
        val scanResult: ScanResult = withTimeout(15_000) {
            scanner.scanAll().first()
        }
        Log.d(TAG, "Found camera: ${scanResult.device.name ?: scanResult.device.address}")

        onStatus("正在蓝牙配对...\n请在相机屏幕上确认连接")
        val hs = CameraVendorBleHandshake(context)
        handshake = hs
        hs.performHandshake(scanResult)

        val ssid = hs.wifiSSID ?: scanResult.device.name ?: "CAMERA_VENDOR"
        Log.d(TAG, "WiFi SSID: $ssid")

        onStatus("正在连接 WiFi: $ssid")
        wifiConnector.connect(ssid)

        onStatus("正在建立 PTP 连接...")
        connection.connect()

        onStatus("已连接")
        Log.d(TAG, "Full connection established")
    }

    suspend fun listFiles(): List<CameraFile> {
        val storageIds = commands.getStorageIDs()
        Log.d(TAG, "Storage IDs: $storageIds")

        val files = mutableListOf<CameraFile>()
        for (storageId in storageIds) {
            val handles = commands.getObjectHandles(storageId)
            Log.d(TAG, "Storage $storageId: ${handles.size} objects")
            for (handle in handles) {
                val info = commands.getObjectInfo(handle)
                if (!info.isFolder) {
                    files.add(CameraFile(info))
                }
            }
        }
        return files.sortedByDescending { it.info.captureDate }
    }

    suspend fun getThumbnail(handle: Int): ByteArray {
        return commands.getThumb(handle)
    }

    suspend fun getFile(handle: Int): ByteArray {
        return commands.getObject(handle)
    }

    fun getFileStream(handle: Int) = commands.getObjectStream(handle)

    suspend fun disconnect() {
        connection.disconnect()
        wifiConnector.disconnect()
        handshake?.disconnect()
        handshake = null
    }
}
