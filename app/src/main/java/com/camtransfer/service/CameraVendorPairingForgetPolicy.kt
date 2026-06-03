package com.camtransfer.service

object CameraVendorPairingForgetPolicy {
    fun canUseSystemBondAsRememberedPairing(
        bluetoothAddress: String,
        deletedBluetoothAddresses: Set<String>,
    ): Boolean {
        return normalizeBluetoothAddress(bluetoothAddress) !in deletedBluetoothAddresses.mapTo(mutableSetOf()) {
            normalizeBluetoothAddress(it)
        }
    }

    fun shouldPromptSystemBondRemovalBeforeFreshPairing(bondState: Int): Boolean =
        bondState != android.bluetooth.BluetoothDevice.BOND_NONE

    fun systemBondRemovalMessage(deviceName: String?): String {
        val name = deviceName?.takeIf { it.isNotBlank() } ?: "这台相机"
        return "手机系统里还保留着 $name 的蓝牙配对记录。\n" +
            "请先到 系统设置 > 蓝牙 > $name，点“取消配对/忽略此设备”，然后回到 App 重新配对。"
    }

    fun normalizeBluetoothAddress(bluetoothAddress: String): String =
        bluetoothAddress.trim().uppercase()
}
