package com.camtransfer.service

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class CameraSessionKeepAliveArchitectureTest {
    @Test
    fun manifestDeclaresForegroundWifiAndWakeLockSupport() {
        val manifest = File("src/main/AndroidManifest.xml").readText()

        assertTrue(manifest.contains("android.permission.WAKE_LOCK"))
        assertTrue(manifest.contains("android.permission.FOREGROUND_SERVICE"))
        assertTrue(manifest.contains("android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"))
        assertTrue(manifest.contains("CameraSessionKeepAliveService"))
        assertTrue(manifest.contains("android:foregroundServiceType=\"connectedDevice\""))
    }

    @Test
    fun manifestDeclaresNotificationPermissionForForegroundServiceVisibility() {
        val manifest = File("src/main/AndroidManifest.xml").readText()

        assertTrue(manifest.contains("android.permission.POST_NOTIFICATIONS"))
    }

    @Test
    fun cameraServiceStartsKeepAliveOnlyAfterGalleryConnectionAndStopsItOnFailure() {
        val source = sourceFile("service/CameraService.kt").readText()
        val method = source.substring(
            source.indexOf("suspend fun connectPairedCameraToGallery"),
            source.indexOf("private fun cameraVendorPtpClientName"),
        )

        assertTrue(method.contains("CameraSessionKeepAlive.start(context)"))
        assertTrue(method.contains("CameraSessionKeepAlive.stop(context)"))
        assertTrue(method.indexOf("CameraSessionKeepAlive.start(context)") >
            method.indexOf("galleryConnectionCoordinator.connectToGallery(onStatus)"))
        assertTrue(method.indexOf("CameraSessionKeepAlive.stop(context)") >
            method.indexOf("galleryConnectionCoordinator.connectToGallery(onStatus)"))
    }

    @Test
    fun connectionViewModelLifecycleDoesNotDisconnectCameraSession() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val method = source.substring(
            source.indexOf("override fun onCleared()"),
            source.indexOf("enum class CameraConnectionRetryTarget"),
        )

        assertTrue(method.contains("cancelConnectionJob()"))
        assertTrue(!method.contains("cameraService.disconnect()"))
    }

    @Test
    fun cameraServiceStopsKeepAliveDuringExplicitDisconnect() {
        val source = sourceFile("service/CameraService.kt").readText()
        val method = source.substring(
            source.indexOf("override suspend fun disconnect()"),
            source.indexOf("suspend fun forgetPairing()"),
        )

        assertTrue(method.contains("CameraSessionKeepAlive.stop(context)"))
        assertTrue(method.indexOf("CameraSessionKeepAlive.stop(context)") <
            method.indexOf("connection.disconnect()"))
    }

    @Test
    fun cameraServiceClearsGallerySessionBeforeRetry() {
        val source = sourceFile("service/CameraService.kt").readText()
        val method = source.substring(
            source.indexOf("suspend fun resetGalleryConnectionBeforeRetry"),
            source.indexOf("private fun cameraVendorPtpClientName"),
        )

        assertTrue(method.contains("CameraSessionKeepAlive.stop(context)"))
        assertTrue(method.contains("connection.disconnect()"))
        assertTrue(method.contains("wifiConnector.disconnect()"))
        assertTrue(method.contains("handshake?.disconnect()"))
        assertTrue(method.contains("clearHandshake()"))
    }

    @Test
    fun galleryRetryResetsSessionBeforeRestartingOfficialEntry() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val method = source.substring(
            source.indexOf("private fun enterCameraAlbum"),
            source.indexOf("fun confirmWifiJoinedAndOpenGallery"),
        )

        assertTrue(method.contains("resetBeforeStart"))
        assertTrue(method.contains("cameraService.resetGalleryConnectionBeforeRetry()"))
        assertTrue(
            method.indexOf("cameraService.resetGalleryConnectionBeforeRetry()") <
                method.indexOf("cameraService.connectPairedCameraToGallery")
        )
    }

    @Test
    fun resetConnectionForFreshPairingClearsConnectionAndPairingState() {
        val source = sourceFile("service/CameraService.kt").readText()
        val method = source.substring(
            source.indexOf("suspend fun resetConnectionForFreshPairing"),
            source.indexOf("private fun removeSystemBluetoothBonds"),
        )

        assertTrue(method.contains("disconnect()"))
        assertTrue(method.contains("listOfNotNull(it.bluetoothAddress)"))
        assertTrue(method.contains("CameraVendorPairingRegistrationPolicy.systemCameraBondAddresses(systemBluetoothBonds())"))
        assertTrue(method.contains("pairingStore.rememberDeletedBluetoothAddresses"))
        assertTrue(method.contains("removeSystemBluetoothBonds"))
        assertTrue(method.contains("pairingStore.clear()"))
        assertTrue(method.contains("CameraVendorTerminalIdentityStore(context).clearRegisteredTerminalName()"))
    }

    @Test
    fun cameraServiceExposesRegistrationConsistencyCheckWithoutSystemBondFallback() {
        val source = sourceFile("service/CameraService.kt").readText()
        val rememberedMethod = source.substring(
            source.indexOf("fun rememberedPairing()"),
            source.indexOf("fun pairedCameras()"),
        )
        val consistencyMethod = source.substring(
            source.indexOf("fun registrationConsistencyIssue()"),
            source.indexOf("suspend fun connectToCamera"),
        )

        assertTrue(rememberedMethod.contains("pairingStore.load()"))
        assertTrue(!rememberedMethod.contains("bondedDevices"))
        assertTrue(consistencyMethod.contains("CameraVendorPairingRegistrationPolicy.issueFor"))
        assertTrue(consistencyMethod.contains("pairingStore.load()"))
        assertTrue(consistencyMethod.contains("systemBluetoothBonds()"))
        assertTrue(consistencyMethod.contains("CameraVendorConnectedDeviceNameStore(context).rememberRegisteredTerminalName"))
    }

    @Test
    fun connectionViewModelBlocksConnectionWhenRegistrationIsInconsistent() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val connectMethod = source.substring(
            source.indexOf("private fun startPairingFlow"),
            source.indexOf("fun confirmCameraPairingSucceeded"),
        )
        val galleryMethod = source.substring(
            source.indexOf("private fun enterCameraAlbum"),
            source.indexOf("fun confirmWifiJoinedAndOpenGallery"),
        )

        assertTrue(connectMethod.contains("publishRegistrationConsistencyIssueIfNeeded()"))
        assertTrue(connectMethod.indexOf("publishRegistrationConsistencyIssueIfNeeded()") <
            connectMethod.indexOf("_state.value = ConnectionState.SCANNING"))
        assertTrue(galleryMethod.contains("publishRegistrationConsistencyIssueIfNeeded()"))
        assertTrue(galleryMethod.indexOf("publishRegistrationConsistencyIssueIfNeeded()") <
            galleryMethod.indexOf("cameraService.connectPairedCameraToGallery"))
    }

    @Test
    fun connectionViewModelRunsBleOnlineRefreshAtStartupAfterConsistencyCheck() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val initBlock = source.substring(
            source.indexOf("init {"),
            source.indexOf("fun connect()"),
        )
        val galleryMethod = source.substring(
            source.indexOf("private fun enterCameraAlbum"),
            source.indexOf("fun confirmWifiJoinedAndOpenGallery"),
        )

        assertTrue(initBlock.contains("cameraService.rememberedPairing()?.let { remembered ->"))
        assertTrue(initBlock.indexOf("publishRegistrationConsistencyIssueIfNeeded()") <
            initBlock.indexOf("startPairedCameraOnlineRefresh"))
        assertTrue(initBlock.contains("startPairedCameraOnlineRefresh(remembered.deviceName)"))
        assertTrue(galleryMethod.contains("awaitPairedCameraOnlineRefreshBeforeGalleryStart()"))
        assertTrue(
            galleryMethod.indexOf("awaitPairedCameraOnlineRefreshBeforeGalleryStart()") <
                galleryMethod.indexOf("cameraService.connectPairedCameraToGallery")
        )
        assertTrue(
            galleryMethod.indexOf("cancelPairedCameraOnlineRefreshAndWait()") >
                galleryMethod.indexOf("if (resetBeforeStart)")
        )
        assertTrue(
            galleryMethod.indexOf("cancelPairedCameraOnlineRefreshAndWait()") <
                galleryMethod.indexOf("cameraService.resetGalleryConnectionBeforeRetry()")
        )
    }

    @Test
    fun startupOnlineRefreshKeepsBleSessionForNextGalleryClick() {
        val serviceSource = sourceFile("service/CameraService.kt").readText()
        val serviceMethod = serviceSource.substring(
            serviceSource.indexOf("suspend fun refreshPairedCameraOnlineStatus"),
            serviceSource.indexOf("suspend fun connectPairedCameraToGallery"),
        )
        val coordinatorSource = sourceFile("service/connection/CameraGalleryConnectionCoordinator.kt").readText()
        val coordinatorMethod = coordinatorSource.substring(
            coordinatorSource.indexOf("suspend fun refreshRememberedCameraBleOnlineStatus"),
            coordinatorSource.indexOf("fun connectToGallery"),
        )

        assertTrue(serviceMethod.contains("galleryConnectionCoordinator.refreshRememberedCameraBleOnlineStatus(onStatus)"))
        assertTrue(!serviceMethod.contains("CameraSessionKeepAlive.start(context)"))
        assertTrue(!serviceMethod.contains("connection.connect"))
        assertTrue(!serviceMethod.contains("wifiConnector"))

        assertTrue(coordinatorMethod.contains("reconnectRememberedCamera"))
        assertTrue(coordinatorMethod.contains("Keeping startup BLE online refresh handshake for gallery flow"))
        assertTrue(!coordinatorMethod.contains("refreshedHandshake.disconnect()"))
        assertTrue(!coordinatorMethod.contains("clearHandshake()"))
        assertTrue(!coordinatorMethod.contains("writeTransferActivationRequest"))
        assertTrue(!coordinatorMethod.contains("connectWifiAndPtp"))
        assertTrue(!coordinatorMethod.contains("connectPtpWithRetry"))
        assertTrue(!coordinatorMethod.contains("confirmCameraPairingSucceeded"))
    }

    @Test
    fun galleryTransferAuthorizationDoesNotReplayPairingConfirmationAck() {
        val coordinatorSource = sourceFile("service/connection/CameraGalleryConnectionCoordinator.kt").readText()
        val transferAuthorizationBlock = coordinatorSource.substring(
            coordinatorSource.indexOf("transferAuthorization = TransferAuthorizationStep"),
            coordinatorSource.indexOf("activateCameraWifi = ActivateCameraWifiStep"),
        )

        assertTrue(transferAuthorizationBlock.contains("refreshReferenceAppWifiConfiguration()"))
        assertTrue(!transferAuthorizationBlock.contains("confirmCameraPairingSucceeded"))
        assertTrue(!transferAuthorizationBlock.contains("Gallery transfer authorization replay confirmed"))
    }

    @Test
    fun galleryConnectionDoesNotPersistentlyOverwritePairingRegistration() {
        val coordinatorSource = sourceFile("service/connection/CameraGalleryConnectionCoordinator.kt").readText()

        assertTrue(!coordinatorSource.contains("saveRememberedHandshake"))
        assertTrue(!coordinatorSource.contains("pairingStore.save"))
    }

    @Test
    fun startupOnlineRefreshFailureDoesNotInventRegistrationIssue() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val method = source.substring(
            source.indexOf("private fun startPairedCameraOnlineRefresh"),
            source.indexOf("private fun publishIssue"),
        )

        assertTrue(method.contains("cameraService.refreshPairedCameraOnlineStatus"))
        assertTrue(method.contains("已保存配对，未连接相机"))
        assertTrue(!method.contains("publishIssue("))
        assertTrue(!method.contains("ConnectionState.ERROR"))
        assertTrue(!method.contains("注册记录可能"))
    }

    @Test
    fun connectionViewModelExposesResetConnectionAction() {
        val source = sourceFile("viewmodel/ConnectionViewModel.kt").readText()
        val method = source.substring(
            source.indexOf("fun resetConnectionForFreshPairing()"),
            source.indexOf("fun selectPairedCamera"),
        )

        assertTrue(method.contains("cameraService.resetConnectionForFreshPairing()"))
        assertTrue(method.contains("refreshPairedCameras()"))
        assertTrue(method.contains("ConnectionState.IDLE"))
        assertTrue(method.contains("CameraConnectionStep.CameraPairingMode"))
    }

    private fun sourceFile(path: String): File =
        listOf(
            File("src/main/java/com/camtransfer/$path"),
            File("app/src/main/java/com/camtransfer/$path"),
        ).first { it.exists() }
}
