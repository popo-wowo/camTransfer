package com.camtransfer.ble

class CameraVendorBleHandshakeCoordinator {
    private val pendingCharacteristicServices = linkedSetOf<String>()
    private val pendingMetadataCharacteristics = linkedSetOf<String>()
    private val pendingNotificationSubscriptions = linkedSetOf<String>()
    var didStartHandshake: Boolean = false
        private set

    fun registerServiceForCharacteristicDiscovery(uuid: String) {
        pendingCharacteristicServices += uuid.normalizedUuid()
    }

    fun completeCharacteristicDiscovery(uuid: String) {
        pendingCharacteristicServices -= uuid.normalizedUuid()
    }

    fun registerMetadataRead(uuid: String) {
        pendingMetadataCharacteristics += uuid.normalizedUuid()
    }

    fun completeMetadataRead(uuid: String) {
        pendingMetadataCharacteristics -= uuid.normalizedUuid()
    }

    fun registerNotificationSubscription(uuid: String) {
        pendingNotificationSubscriptions += uuid.normalizedUuid()
    }

    fun completeNotificationSubscription(uuid: String) {
        pendingNotificationSubscriptions -= uuid.normalizedUuid()
    }

    fun markHandshakeStarted() {
        didStartHandshake = true
    }

    fun canStartHandshake(hasIdentifierCharacteristic: Boolean): Boolean {
        return hasIdentifierCharacteristic &&
            pendingCharacteristicServices.isEmpty() &&
            pendingMetadataCharacteristics.isEmpty() &&
            pendingNotificationSubscriptions.isEmpty() &&
            !didStartHandshake
    }

    fun canStartSecureHandshake(
        hasConnectedDeviceNameCharacteristic: Boolean,
        hasConnectedDeviceIdentificationCharacteristic: Boolean,
    ): Boolean {
        return hasConnectedDeviceNameCharacteristic &&
            hasConnectedDeviceIdentificationCharacteristic &&
            pendingCharacteristicServices.isEmpty() &&
            pendingMetadataCharacteristics.isEmpty() &&
            pendingNotificationSubscriptions.isEmpty() &&
            !didStartHandshake
    }

    fun waitReason(isSecure: Boolean, hasConnectedDeviceName: Boolean, hasConnectedDeviceIdentification: Boolean): String {
        return when {
            isSecure && !hasConnectedDeviceIdentification -> "等待已连接设备识别号特征"
            !hasConnectedDeviceName -> "等待已连接设备名称特征"
            pendingCharacteristicServices.isNotEmpty() ->
                "等待服务特征发现完成: ${pendingCharacteristicServices.sorted().joinToString(",")}"
            pendingMetadataCharacteristics.isNotEmpty() ->
                "等待基础信息读取完成: ${pendingMetadataCharacteristics.sorted().joinToString(",")}"
            pendingNotificationSubscriptions.isNotEmpty() ->
                "等待通知订阅完成: ${pendingNotificationSubscriptions.sorted().joinToString(",")}"
            else -> "等待握手前置条件"
        }
    }

    private fun String.normalizedUuid(): String = trim().uppercase()
}
