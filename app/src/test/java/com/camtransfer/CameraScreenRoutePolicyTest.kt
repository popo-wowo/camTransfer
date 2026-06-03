package com.camtransfer

import com.camtransfer.viewmodel.ConnectionState
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraScreenRoutePolicyTest {
    @Test
    fun keepsGalleryOpenWhenCameraSourceIsActive() {
        assertFalse(
            CameraScreenRoutePolicy.shouldReturnToConnect(
                isWiredImport = false,
                hasActiveCameraSource = true,
                connectionState = ConnectionState.PAIRED,
                currentScreen = Screen.BROWSE,
            )
        )
    }

    @Test
    fun returnsToConnectWhenNoActiveSourceAndWirelessStateIsNoLongerConnected() {
        assertTrue(
            CameraScreenRoutePolicy.shouldReturnToConnect(
                isWiredImport = false,
                hasActiveCameraSource = false,
                connectionState = ConnectionState.PAIRED,
                currentScreen = Screen.BROWSE,
            )
        )
    }

    @Test
    fun neverForcesWiredImportBackToConnect() {
        assertFalse(
            CameraScreenRoutePolicy.shouldReturnToConnect(
                isWiredImport = true,
                hasActiveCameraSource = true,
                connectionState = ConnectionState.IDLE,
                currentScreen = Screen.BROWSE,
            )
        )
    }
}
