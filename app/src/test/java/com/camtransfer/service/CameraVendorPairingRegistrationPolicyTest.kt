package com.camtransfer.service

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPairingRegistrationPolicyTest {
    @Test
    fun savedAppRegistrationWithoutSystemBondRequiresRegistrationReset() {
        val saved = pairedCamera(
            deviceName = "X-T5",
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
        )

        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = saved,
            systemBonds = emptyList(),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.PairingRegistrationOutOfSync, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
        assertTrue(issue?.detail.orEmpty().contains("删除注册"))
        assertTrue(issue?.detail.orEmpty().contains("重新配对"))
    }

    @Test
    fun staleSystemCameraBondWithoutAppRegistrationRequiresConnectionReset() {
        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = null,
            systemBonds = listOf(systemBond(name = "X-T5", address = "AA:BB:CC:DD:EE:FF")),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.StaleSystemBond, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
        assertEquals(CameraConnectionAction.OpenSystemBluetoothSettings, issue?.secondaryAction)
        assertTrue(issue?.detail.orEmpty().contains("重置连接"))
        assertTrue(issue?.detail.orEmpty().contains("X-T5"))
    }

    @Test
    fun staleSystemCameraBondAddressesAreAvailableForOneTapCleanup() {
        val addresses = CameraVendorPairingRegistrationPolicy.systemCameraBondAddresses(
            systemBonds = listOf(
                systemBond(name = "X-T5", address = "AA:BB:CC:DD:EE:FF"),
                systemBond(name = "FUJIFILM X-H2", address = "11:22:33:44:55:66"),
                systemBond(name = "Keyboard", address = "22:33:44:55:66:77"),
                systemBond(
                    name = "GFX100",
                    address = "33:44:55:66:77:88",
                    bondState = BluetoothDevice.BOND_NONE,
                ),
            ),
        )

        assertEquals(
            listOf("AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"),
            addresses,
        )
    }

    @Test
    fun matchingSavedRegistrationAndSystemBondIsConsistent() {
        val saved = pairedCamera(
            deviceName = "X-T5",
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
            registeredTerminalName = "23127PN0CC-1457",
        )

        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = saved,
            systemBonds = listOf(systemBond(name = "X-T5", address = "aa:bb:cc:dd:ee:ff")),
            canReadSystemBonds = true,
        )

        assertNull(issue)
    }

    @Test
    fun matchingSystemBondWithoutSavedTerminalNameRequiresRegistrationReset() {
        val saved = pairedCamera(
            deviceName = "X-T5",
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
            registeredTerminalName = null,
        )

        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = saved,
            systemBonds = listOf(systemBond(name = "X-T5", address = "aa:bb:cc:dd:ee:ff")),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.PairingRegistrationOutOfSync, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
        assertTrue(issue?.detail.orEmpty().contains("重新配对"))
    }

    @Test
    fun sameCameraNameWithDifferentSavedAddressRequiresRegistrationReset() {
        val saved = pairedCamera(
            deviceName = "X-T5",
            bluetoothAddress = "AA:BB:CC:DD:EE:FF",
        )

        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = saved,
            systemBonds = listOf(systemBond(name = "X-T5", address = "11:22:33:44:55:66")),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.PairingRegistrationOutOfSync, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
    }

    @Test
    fun savedRegistrationWithoutAddressCannotBeProvenConsistentByNameOnly() {
        val saved = pairedCamera(
            deviceName = "X-T5",
            bluetoothAddress = null,
        )

        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = saved,
            systemBonds = listOf(systemBond(name = "X-T5", address = "AA:BB:CC:DD:EE:FF")),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.PairingRegistrationOutOfSync, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
    }

    @Test
    fun missingBluetoothPermissionDoesNotInventRegistrationIssue() {
        val issue = CameraVendorPairingRegistrationPolicy.issueFor(
            savedRegistration = pairedCamera(),
            systemBonds = emptyList(),
            canReadSystemBonds = false,
        )

        assertNull(issue)
    }

    @Test
    fun freshPairingScanBlocksWhenScannedCameraAddressAlreadyExistsInSystemBonds() {
        val issue = CameraVendorPairingRegistrationPolicy.freshPairingIssueForScannedCamera(
            scannedDeviceName = "X-T5",
            scannedDeviceAddress = "aa:bb:cc:dd:ee:ff",
            systemBonds = listOf(systemBond(name = "X-T5", address = "AA:BB:CC:DD:EE:FF")),
            canReadSystemBonds = true,
        )

        assertEquals(CameraConnectionFailure.StaleSystemBond, issue?.failure)
        assertEquals(CameraConnectionAction.ResetConnection, issue?.primaryAction)
        assertEquals(CameraConnectionAction.OpenSystemBluetoothSettings, issue?.secondaryAction)
        assertTrue(issue?.detail.orEmpty().contains("X-T5"))
    }

    @Test
    fun freshPairingScanDoesNotTreatSameNameDifferentAddressAsOfficialBondConflict() {
        val issue = CameraVendorPairingRegistrationPolicy.freshPairingIssueForScannedCamera(
            scannedDeviceName = "X-T5",
            scannedDeviceAddress = "AA:BB:CC:DD:EE:FF",
            systemBonds = listOf(systemBond(name = "X-T5", address = "11:22:33:44:55:66")),
            canReadSystemBonds = true,
        )

        assertNull(issue)
    }

    @Test
    fun freshPairingScanWithoutBluetoothPermissionDoesNotInventConflict() {
        val issue = CameraVendorPairingRegistrationPolicy.freshPairingIssueForScannedCamera(
            scannedDeviceName = "X-T5",
            scannedDeviceAddress = "AA:BB:CC:DD:EE:FF",
            systemBonds = listOf(systemBond(name = "X-T5", address = "AA:BB:CC:DD:EE:FF")),
            canReadSystemBonds = false,
        )

        assertNull(issue)
    }

    private fun pairedCamera(
        deviceName: String = "X-T5",
        bluetoothAddress: String? = "AA:BB:CC:DD:EE:FF",
        registeredTerminalName: String? = "23127PN0CC-1457",
    ) = CameraVendorPairedCameraRecord(
        deviceName = deviceName,
        serialNumber = "221019F1932011003B",
        wifiConfigurations = emptyList(),
        bluetoothAddress = bluetoothAddress,
        cameraId = "221019F1932011003B_$deviceName",
        registeredTerminalName = registeredTerminalName,
    )

    private fun systemBond(
        name: String,
        address: String,
        bondState: Int = BluetoothDevice.BOND_BONDED,
    ) = CameraVendorSystemBluetoothBond(
        name = name,
        address = address,
        bondState = bondState,
    )
}
