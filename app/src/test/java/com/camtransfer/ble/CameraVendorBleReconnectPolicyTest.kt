package com.camtransfer.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorBleReconnectPolicyTest {
    @Test
    fun rememberedCameraReconnectUsesOnlyDocumentedOfficialStages() {
        assertEquals(5_000L, CameraVendorBleReconnectPolicy.REMEMBERED_DIRECT_CONNECT_TIMEOUT_MS)
        assertEquals(
            setOf(
                CameraVendorBleReconnectStage.DirectAddress,
                CameraVendorBleReconnectStage.OfficialReconnectScan,
            ),
            CameraVendorBleReconnectStage.entries.toSet(),
        )
    }

    @Test
    fun rememberedBluetoothAddressWithoutStableIdentityUsesOnlyDirectConnect() {
        val stages = CameraVendorBleReconnectPolicy.reconnectStages(
            hasRememberedBluetoothAddress = true,
            hasStableCameraIdentity = false,
        )

        assertEquals(
            listOf(
                CameraVendorBleReconnectStage.DirectAddress,
            ),
            stages,
        )
    }

    @Test
    fun missingRememberedBluetoothAddressAndIdentityStopsInsteadOfScanning() {
        val stages = CameraVendorBleReconnectPolicy.reconnectStages(
            hasRememberedBluetoothAddress = false,
            hasStableCameraIdentity = false,
        )

        assertEquals(emptyList<CameraVendorBleReconnectStage>(), stages)
    }

    @Test
    fun stableCameraIdentityWithAddressUsesDirectConnectThenOfficialReconnectScan() {
        val stages = CameraVendorBleReconnectPolicy.reconnectStages(
            hasRememberedBluetoothAddress = true,
            hasStableCameraIdentity = true,
        )

        assertEquals(
            listOf(
                CameraVendorBleReconnectStage.DirectAddress,
                CameraVendorBleReconnectStage.OfficialReconnectScan,
            ),
            stages,
        )
    }

    @Test
    fun stableCameraIdentityWithoutAddressUsesOfficialReconnectScan() {
        val stages = CameraVendorBleReconnectPolicy.reconnectStages(
            hasRememberedBluetoothAddress = false,
            hasStableCameraIdentity = true,
        )

        assertEquals(
            listOf(
                CameraVendorBleReconnectStage.OfficialReconnectScan,
            ),
            stages,
        )
    }
}
