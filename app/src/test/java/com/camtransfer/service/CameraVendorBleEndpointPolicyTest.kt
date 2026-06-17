package com.camtransfer.service

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorBleEndpointPolicyTest {
    @Test
    fun identityVerifiedCandidatesUseSystemBondAddressesBeforeSavedAddress() {
        val remembered = record(
            cameraId = "221019F1932011003B_X-T5",
            bluetoothAddress = "6D:4B:DB:DD:B3:80",
        )
        val candidates = CameraVendorBleEndpointPolicy.identityVerifiedCandidates(
            remembered = remembered,
            systemBonds = listOf(
                CameraVendorBleEndpointPolicy.SystemBond(name = "X-T5", address = "04:7B:CB:83:E3:A7"),
                CameraVendorBleEndpointPolicy.SystemBond(name = "X100VI", address = "AA:BB:CC:DD:EE:FF"),
            ),
        )

        assertEquals(
            listOf(
                CameraVendorBleEndpointPolicy.Candidate(
                    address = "04:7B:CB:83:E3:A7",
                    source = CameraVendorBleEndpointPolicy.CandidateSource.SystemBond,
                ),
                CameraVendorBleEndpointPolicy.Candidate(
                    address = "6D:4B:DB:DD:B3:80",
                    source = CameraVendorBleEndpointPolicy.CandidateSource.SavedRecord,
                ),
            ),
            candidates,
        )
    }

    @Test
    fun identityVerifiedCandidatesDeduplicateAddresses() {
        val remembered = record(
            cameraId = "221019F1932011003B_X-T5",
            bluetoothAddress = "6D:4B:DB:DD:B3:80",
        )

        val candidates = CameraVendorBleEndpointPolicy.identityVerifiedCandidates(
            remembered = remembered,
            systemBonds = listOf(
                CameraVendorBleEndpointPolicy.SystemBond(name = "X-T5", address = "6D:4B:DB:DD:B3:80"),
            ),
        )

        assertEquals(
            listOf(
                CameraVendorBleEndpointPolicy.Candidate(
                    address = "6D:4B:DB:DD:B3:80",
                    source = CameraVendorBleEndpointPolicy.CandidateSource.SystemBond,
                ),
            ),
            candidates,
        )
    }

    private fun record(
        cameraId: String,
        bluetoothAddress: String?,
    ): CameraVendorPairedCameraRecord =
        CameraVendorPairedCameraRecord(
            cameraId = cameraId,
            deviceName = cameraId.substringAfter("_"),
            serialNumber = cameraId.substringBefore("_"),
            bluetoothAddress = bluetoothAddress,
            wifiConfigurations = emptyList(),
        )
}
