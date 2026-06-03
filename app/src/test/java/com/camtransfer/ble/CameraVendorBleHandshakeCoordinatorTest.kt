package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorBleHandshakeCoordinatorTest {

    @Test
    fun handshakeWaitsForMetadataReadToFinish() {
        val coordinator = CameraVendorBleHandshakeCoordinator()
        coordinator.registerServiceForCharacteristicDiscovery("91F1")
        coordinator.registerServiceForCharacteristicDiscovery("180A")

        coordinator.completeCharacteristicDiscovery("91F1")
        coordinator.registerMetadataRead("2A25")

        assertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic = true))

        coordinator.completeCharacteristicDiscovery("180A")
        assertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic = true))

        coordinator.completeMetadataRead("2A25")
        assertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic = true))
    }

    @Test
    fun handshakeDoesNotRestartAfterBeginning() {
        val coordinator = CameraVendorBleHandshakeCoordinator()
        coordinator.registerServiceForCharacteristicDiscovery("91F1")
        coordinator.completeCharacteristicDiscovery("91F1")

        assertTrue(coordinator.canStartHandshake(hasIdentifierCharacteristic = true))

        coordinator.markHandshakeStarted()
        assertFalse(coordinator.canStartHandshake(hasIdentifierCharacteristic = true))
    }

    @Test
    fun secureHandshakeWaitsForAllServicesBeforeWritingConnectedDeviceName() {
        val coordinator = CameraVendorBleHandshakeCoordinator()
        coordinator.registerServiceForCharacteristicDiscovery("123D8F06-62A1-4935-9322-833C531EE225")
        coordinator.registerServiceForCharacteristicDiscovery("4E941240-D01D-46B9-A5EA-67636806830B")

        coordinator.completeCharacteristicDiscovery("123D8F06-62A1-4935-9322-833C531EE225")

        assertFalse(
            coordinator.canStartSecureHandshake(
                hasConnectedDeviceNameCharacteristic = true,
                hasConnectedDeviceIdentificationCharacteristic = true,
            )
        )

        coordinator.completeCharacteristicDiscovery("4E941240-D01D-46B9-A5EA-67636806830B")

        assertTrue(
            coordinator.canStartSecureHandshake(
                hasConnectedDeviceNameCharacteristic = true,
                hasConnectedDeviceIdentificationCharacteristic = true,
            )
        )
    }

    @Test
    fun secureHandshakeWaitsForNotificationSubscriptionsBeforeWritingConnectedDeviceName() {
        val coordinator = CameraVendorBleHandshakeCoordinator()
        coordinator.registerNotificationSubscription("A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

        assertFalse(
            coordinator.canStartSecureHandshake(
                hasConnectedDeviceNameCharacteristic = true,
                hasConnectedDeviceIdentificationCharacteristic = true,
            )
        )

        coordinator.completeNotificationSubscription("A68E3F66-0FCC-4395-8D4C-AA980B5877FA")

        assertTrue(
            coordinator.canStartSecureHandshake(
                hasConnectedDeviceNameCharacteristic = true,
                hasConnectedDeviceIdentificationCharacteristic = true,
            )
        )
    }
}
