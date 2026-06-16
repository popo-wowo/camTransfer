package com.camtransfer.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBlePairingPolicyTest {

    @Test
    fun securePairingStartsByWritingConnectedDeviceName() {
        assertEquals(
            listOf(
                CameraVendorBleSecurePairingStep.WRITE_CONNECTED_DEVICE_NAME,
                CameraVendorBleSecurePairingStep.READ_IDENTIFICATION_NUMBER,
                CameraVendorBleSecurePairingStep.WRITE_IDENTIFICATION_ACK,
            ),
            CameraVendorBlePairingPolicy.secureSteps(hasConnectedDeviceNameCharacteristic = true),
        )
    }

    @Test
    fun securePairingCanFallbackToIdentificationAckWhenNameCharacteristicIsMissing() {
        assertEquals(
            listOf(
                CameraVendorBleSecurePairingStep.READ_IDENTIFICATION_NUMBER,
                CameraVendorBleSecurePairingStep.WRITE_IDENTIFICATION_ACK,
            ),
            CameraVendorBlePairingPolicy.secureSteps(hasConnectedDeviceNameCharacteristic = false),
        )
    }

    @Test
    fun identificationAckKeepsFirstThreeBytesAndSetsApplicationBit() {
        assertArrayEquals(
            byteArrayOf(0x2B, 0xA1.toByte(), 0x26, 0x20),
            CameraVendorBlePairingPolicy.identificationAckPayload(
                byteArrayOf(0x2B, 0xA1.toByte(), 0x26, 0x00)
            ),
        )
    }

    @Test
    fun identificationAckRejectsMalformedValues() {
        assertNull(CameraVendorBlePairingPolicy.identificationAckPayload(byteArrayOf(0x01, 0x02, 0x03)))
    }

    @Test
    fun recognizesAlreadyPairedIdentificationNumber() {
        assertTrue(
            CameraVendorBlePairingPolicy.isAlreadyPairedIdentificationNumber(
                byteArrayOf(0x53, 0xB3.toByte(), 0x27, 0x20)
            )
        )
        assertFalse(
            CameraVendorBlePairingPolicy.isAlreadyPairedIdentificationNumber(
                byteArrayOf(0x53, 0xB3.toByte(), 0x27, 0x00)
            )
        )
        assertFalse(
            CameraVendorBlePairingPolicy.isAlreadyPairedIdentificationNumber(
                byteArrayOf(0x53, 0xB3.toByte(), 0x27)
            )
        )
    }

    @Test
    fun secureIdentificationAckIsPartOfBleHandshakeBeforePhoneConfirmation() {
        assertTrue(CameraVendorBlePairingPolicy.shouldWriteIdentificationAckDuringHandshake(hasAckPayload = true))
        assertFalse(CameraVendorBlePairingPolicy.shouldWriteIdentificationAckDuringHandshake(hasAckPayload = false))
    }

    @Test
    fun secureIdentificationReadWaitsLongEnoughForSystemNumericComparison() {
        assertTrue(CameraVendorBlePairingPolicy.SECURE_IDENTIFICATION_READ_TIMEOUT_MS >= 35_000L)
    }

    @Test
    fun freshSecurePairingDoesNotRetryAfterAnUnconfirmedFailure() {
        assertEquals(
            1,
            CameraVendorBlePairingPolicy.maxSecureHandshakeAttempts(CameraVendorBleHandshakeMode.Pairing),
        )
    }
}
