package com.camtransfer.service

import android.bluetooth.BluetoothDevice
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorPairingForgetPolicyTest {
    @Test
    fun deletedSystemBondAddressIsNotEligibleForRememberedPairingFallback() {
        assertFalse(
            CameraVendorPairingForgetPolicy.canUseSystemBondAsRememberedPairing(
                bluetoothAddress = "AA:BB:CC:DD:EE:FF",
                deletedBluetoothAddresses = setOf("aa:bb:cc:dd:ee:ff"),
            )
        )
    }

    @Test
    fun otherSystemBondAddressesRemainEligibleForRememberedPairingFallback() {
        assertTrue(
            CameraVendorPairingForgetPolicy.canUseSystemBondAsRememberedPairing(
                bluetoothAddress = "AA:BB:CC:DD:EE:FF",
                deletedBluetoothAddresses = setOf("11:22:33:44:55:66"),
            )
        )
    }

    @Test
    fun promptsSystemBondRemovalBeforeFreshPairing() {
        assertTrue(
            CameraVendorPairingForgetPolicy.shouldPromptSystemBondRemovalBeforeFreshPairing(
                BluetoothDevice.BOND_BONDED,
            )
        )
        assertTrue(
            CameraVendorPairingForgetPolicy.shouldPromptSystemBondRemovalBeforeFreshPairing(
                BluetoothDevice.BOND_BONDING,
            )
        )
        assertFalse(
            CameraVendorPairingForgetPolicy.shouldPromptSystemBondRemovalBeforeFreshPairing(
                BluetoothDevice.BOND_NONE,
            )
        )
    }

    @Test
    fun reportsRequestedSystemBondAddressesThatRemainAfterRemoval() {
        val remaining = CameraVendorPairingForgetPolicy.remainingSystemBondAddresses(
            requestedAddresses = listOf("aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"),
            systemBonds = listOf(
                CameraVendorSystemBluetoothBond(
                    name = "X-T5",
                    address = "AA:BB:CC:DD:EE:FF",
                    bondState = BluetoothDevice.BOND_BONDED,
                ),
                CameraVendorSystemBluetoothBond(
                    name = "GFX",
                    address = "11:22:33:44:55:66",
                    bondState = BluetoothDevice.BOND_NONE,
                ),
                CameraVendorSystemBluetoothBond(
                    name = "Keyboard",
                    address = "22:33:44:55:66:77",
                    bondState = BluetoothDevice.BOND_BONDED,
                ),
            ),
        )

        assertTrue("AA:BB:CC:DD:EE:FF" in remaining)
        assertFalse("11:22:33:44:55:66" in remaining)
        assertFalse("22:33:44:55:66:77" in remaining)
    }
}
