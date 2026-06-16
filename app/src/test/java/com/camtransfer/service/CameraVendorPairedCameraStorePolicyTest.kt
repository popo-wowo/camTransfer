package com.camtransfer.service

import com.camtransfer.wifi.CameraVendorWifiNetworkConfiguration
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorPairedCameraStorePolicyTest {
    @Test
    fun savesMultiplePairedCamerasWithoutOverwritingExistingRecords() {
        val first = record("111_X-T5", "X-T5")
        val second = record("222_X100VI", "X100VI")

        val records = CameraVendorPairedCameraStorePolicy.upsert(
            records = CameraVendorPairedCameraStorePolicy.upsert(emptyList(), first),
            record = second,
        )

        assertEquals(listOf(first, second), records)
    }

    @Test
    fun upsertingExistingCameraIdReplacesOnlyThatCamera() {
        val original = record("111_X-T5", "X-T5")
        val updated = original.copy(
            wifiConfigurations = listOf(CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-0001", "12345678", false)),
        )
        val other = record("222_X100VI", "X100VI")

        val records = CameraVendorPairedCameraStorePolicy.upsert(listOf(original, other), updated)

        assertEquals(listOf(updated, other), records)
    }

    @Test
    fun selectedRecordUsesSelectedCameraIdOrFallsBackToMostRecentRecord() {
        val older = record("111_X-T5", "X-T5", lastConnectedAtMillis = 100)
        val newer = record("222_X100VI", "X100VI", lastConnectedAtMillis = 200)

        assertEquals(
            newer,
            CameraVendorPairedCameraStorePolicy.selectedRecord(
                records = listOf(older, newer),
                selectedCameraId = null,
            ),
        )
        assertEquals(
            older,
            CameraVendorPairedCameraStorePolicy.selectedRecord(
                records = listOf(older, newer),
                selectedCameraId = "111_X-T5",
            ),
        )
    }

    @Test
    fun encodedRecordsRoundTripMultipleCamerasAndWifiConfigurations() {
        val records = listOf(
            record(
                cameraId = "111_X-T5",
                deviceName = "X-T5",
                wifiConfigurations = listOf(CameraVendorWifiNetworkConfiguration("FUJIFILM-X-T5-0001", "12345678", false, "aa:bb:cc:dd:ee:ff")),
            ),
            record("222_X100VI", "X100VI"),
        )

        val decoded = CameraVendorPairedCameraStorePolicy.decodeRecords(
            CameraVendorPairedCameraStorePolicy.encodeRecords(records),
        )

        assertEquals(records, decoded)
    }

    private fun record(
        cameraId: String,
        deviceName: String,
        lastConnectedAtMillis: Long = 0,
        wifiConfigurations: List<CameraVendorWifiNetworkConfiguration> = emptyList(),
    ): CameraVendorPairedCameraRecord =
        CameraVendorPairedCameraRecord(
            cameraId = cameraId,
            deviceName = deviceName,
            serialNumber = cameraId.substringBefore("_"),
            wifiConfigurations = wifiConfigurations,
            bluetoothAddress = "AA:BB:CC:DD:EE:${cameraId.take(2)}",
            lastConnectedAtMillis = lastConnectedAtMillis,
        )
}
