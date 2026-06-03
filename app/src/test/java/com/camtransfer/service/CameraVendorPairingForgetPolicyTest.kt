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
}
