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

    private fun sourceFile(path: String): File =
        listOf(
            File("src/main/java/com/camtransfer/$path"),
            File("app/src/main/java/com/camtransfer/$path"),
        ).first { it.exists() }
}
