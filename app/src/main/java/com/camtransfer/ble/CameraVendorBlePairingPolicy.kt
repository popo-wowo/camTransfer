package com.camtransfer.ble

enum class CameraVendorBleSecurePairingStep {
    WRITE_CONNECTED_DEVICE_NAME,
    READ_IDENTIFICATION_NUMBER,
    WRITE_IDENTIFICATION_ACK,
}

object CameraVendorBlePairingPolicy {
    const val SECURE_IDENTIFICATION_READ_TIMEOUT_MS = 40_000L

    fun maxSecureHandshakeAttempts(mode: CameraVendorBleHandshakeMode): Int {
        return when (mode) {
            CameraVendorBleHandshakeMode.Pairing -> 1
            CameraVendorBleHandshakeMode.RememberedGallery -> 1
        }
    }

    fun secureSteps(hasConnectedDeviceNameCharacteristic: Boolean): List<CameraVendorBleSecurePairingStep> {
        val steps = mutableListOf<CameraVendorBleSecurePairingStep>()
        if (hasConnectedDeviceNameCharacteristic) {
            steps += CameraVendorBleSecurePairingStep.WRITE_CONNECTED_DEVICE_NAME
        }
        steps += CameraVendorBleSecurePairingStep.READ_IDENTIFICATION_NUMBER
        steps += CameraVendorBleSecurePairingStep.WRITE_IDENTIFICATION_ACK
        return steps
    }

    fun identificationAckPayload(identificationNumber: ByteArray): ByteArray? {
        if (identificationNumber.size != 4) return null
        return byteArrayOf(
            identificationNumber[0],
            identificationNumber[1],
            identificationNumber[2],
            0x20,
        )
    }

    fun isAlreadyPairedIdentificationNumber(identificationNumber: ByteArray): Boolean {
        return identificationNumber.size == 4 && (identificationNumber[3].toInt() and 0x20) == 0x20
    }

    fun shouldWriteIdentificationAckDuringHandshake(hasAckPayload: Boolean): Boolean {
        return hasAckPayload
    }
}
