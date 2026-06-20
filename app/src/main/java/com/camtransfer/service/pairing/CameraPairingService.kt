package com.camtransfer.service.pairing

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.util.Log
import com.camtransfer.ble.CameraVendorBleHandshake
import com.camtransfer.ble.CameraVendorBleScanner
import com.camtransfer.ble.CameraVendorCameraPairingConfirmationPolicy
import com.camtransfer.service.CameraBluetoothPermissionPolicy
import com.camtransfer.service.CameraPairingGuidance
import com.camtransfer.service.CameraVendorPairedCameraRecord
import com.camtransfer.service.CameraVendorPairedCameraStore
import com.camtransfer.service.CameraVendorPairingForgetPolicy
import com.camtransfer.service.DiagnosticLog
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

private const val TAG = "CameraPairingService"

class CameraPairingService(
    private val context: Context,
    private val scanner: CameraVendorBleScanner,
    private val pairingStore: CameraVendorPairedCameraStore,
    private val currentHandshake: () -> CameraVendorBleHandshake?,
    private val publishHandshake: (CameraVendorBleHandshake) -> Unit,
    private val rememberedRecordFor: (CameraVendorBleHandshake) -> CameraVendorPairedCameraRecord,
) {
    suspend fun pairWithCamera(onStatus: (String) -> Unit = {}) {
        DiagnosticLog.append(context, TAG, "Pair with camera started")
        onStatus(CameraPairingGuidance.SCANNING_STATUS)
        val scanResult = withTimeout(15_000) {
            scanner.scanAll().first()
        }
        Log.d(TAG, "Found camera: ${scanResult.device.name ?: scanResult.device.address}")
        DiagnosticLog.append(context, TAG, "Found camera")
        ensureNoStaleSystemBondBeforeFreshPairing(scanResult.device)

        onStatus(CameraPairingGuidance.BLE_PAIRING_STATUS)
        val hs = CameraVendorBleHandshake(context)
        try {
            hs.performHandshake(scanResult)
            publishHandshake(hs)
        } catch (error: Throwable) {
            hs.disconnect()
            throw error
        }
        DiagnosticLog.append(context, TAG, "BLE handshake completed")
        onStatus(CameraVendorCameraPairingConfirmationPolicy.WAITING_FOR_PHONE_CONFIRMATION_STATUS)
    }

    suspend fun confirmPairing(onStatus: (String) -> Unit = {}) {
        val hs = currentHandshake() ?: throw IllegalStateException("请先完成蓝牙配对")
        if (!hs.canCompletePhonePairingConfirmation()) {
            throw IllegalStateException("相机端还没有完成识别号 ACK，不能确认配对")
        }

        onStatus("正在确认手机蓝牙配对已完成")
        if (!hs.waitForSystemBondSettled()) {
            throw IllegalStateException("手机系统蓝牙配对还没有完成，请先确认系统配对弹窗和相机屏幕提示")
        }
        onStatus("正在向相机确认配对结果")
        hs.confirmCameraPairingSucceeded()
        DiagnosticLog.append(context, TAG, "Camera pairing confirmed")
        pairingStore.save(rememberedRecordFor(hs))
        onStatus("配对成功")
    }

    @SuppressLint("MissingPermission")
    private fun ensureNoStaleSystemBondBeforeFreshPairing(device: BluetoothDevice) {
        if (!CameraBluetoothPermissionPolicy.canReadSystemBonds(context)) {
            DiagnosticLog.append(context, TAG, "Skipped stale BLE bond check: missing BLUETOOTH_CONNECT")
            return
        }
        if (!CameraVendorPairingForgetPolicy.shouldPromptSystemBondRemovalBeforeFreshPairing(device.bondState)) {
            return
        }
        val message = CameraVendorPairingForgetPolicy.systemBondRemovalMessage(device.name)
        DiagnosticLog.append(context, TAG, "Fresh pairing blocked by existing system BLE bond")
        throw IllegalStateException(message)
    }
}
