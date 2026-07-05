package com.camtransfer

import com.camtransfer.viewmodel.ConnectionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraScreenRoutePolicyTest {
    @Test
    fun keepsGalleryOpenWhenWirelessCameraSourceIsActiveAndConnected() {
        assertFalse(
            CameraScreenRoutePolicy.shouldReturnToConnect(
                isWiredImport = false,
                hasActiveCameraSource = true,
                connectionState = ConnectionState.CONNECTED,
                currentScreen = Screen.BROWSE,
            )
        )
    }

    @Test
    fun returnsToConnectWhenWirelessCameraSourceIsStaleAfterConnectionFailure() {
        assertTrue(
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

    @Test
    fun doesNotOpenGalleryForAlreadyHandledGalleryConnectionEvent() {
        assertFalse(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 7L,
                isReturningToConnect = true,
                connectionState = ConnectionState.CONNECTED,
                currentScreen = Screen.CONNECT,
            )
        )
    }

    @Test
    fun opensGalleryForNewGalleryConnectionEventOnlyOnConnectScreen() {
        assertTrue(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 8L,
                isReturningToConnect = false,
                connectionState = ConnectionState.CONNECTED,
                currentScreen = Screen.CONNECT,
            )
        )
    }

    @Test
    fun doesNotOpenGalleryFromNewEventWhileReturningToConnect() {
        assertFalse(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 8L,
                isReturningToConnect = true,
                connectionState = ConnectionState.CONNECTED,
                currentScreen = Screen.CONNECT,
            )
        )
    }

    @Test
    fun doesNotOpenGalleryWhileManualWifiPtpProbeIsStillRunning() {
        assertFalse(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 8L,
                isReturningToConnect = false,
                connectionState = ConnectionState.CONNECTING_PTP,
                currentScreen = Screen.CONNECT,
            )
        )
    }

    @Test
    fun doesNotOpenGalleryAfterManualWifiPtpProbeFailsBackToPaired() {
        assertFalse(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 8L,
                isReturningToConnect = false,
                connectionState = ConnectionState.PAIRED,
                currentScreen = Screen.CONNECT,
            )
        )
    }

    @Test
    fun doesNotOpenGalleryFromConnectionEventWhileBrowseIsAlreadyVisible() {
        assertFalse(
            CameraScreenRoutePolicy.shouldOpenBrowseFromGalleryConnectionEvent(
                lastHandledGalleryConnectionEvent = 7L,
                galleryConnectionEvent = 8L,
                isReturningToConnect = false,
                connectionState = ConnectionState.CONNECTED,
                currentScreen = Screen.BROWSE,
            )
        )
    }

    @Test
    fun downloadStartOpensTransferScreen() {
        assertEquals(
            Screen.TRANSFER,
            CameraScreenRoutePolicy.screenAfterDownloadStarted(currentScreen = Screen.BROWSE),
        )
    }
}
