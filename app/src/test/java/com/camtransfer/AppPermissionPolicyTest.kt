package com.camtransfer

import android.Manifest
import android.os.Build
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppPermissionPolicyTest {
    @Test
    fun android12RequestsNearbyBluetoothButNotLocationOrMediaRead() {
        val permissions = AppPermissionPolicy.requiredRuntimePermissions(Build.VERSION_CODES.S)

        assertTrue(Manifest.permission.BLUETOOTH_SCAN in permissions)
        assertTrue(Manifest.permission.BLUETOOTH_CONNECT in permissions)
        assertFalse(Manifest.permission.NEARBY_WIFI_DEVICES in permissions)
        assertFalse(Manifest.permission.ACCESS_FINE_LOCATION in permissions)
        assertFalse(Manifest.permission.READ_MEDIA_IMAGES in permissions)
        assertFalse(Manifest.permission.READ_MEDIA_VIDEO in permissions)
    }

    @Test
    fun android13AndAboveRequestsNearbyBluetoothAndWifiButNotLocationOrMediaRead() {
        val permissions = AppPermissionPolicy.requiredRuntimePermissions(Build.VERSION_CODES.TIRAMISU)

        assertTrue(Manifest.permission.BLUETOOTH_SCAN in permissions)
        assertTrue(Manifest.permission.BLUETOOTH_CONNECT in permissions)
        assertTrue(Manifest.permission.NEARBY_WIFI_DEVICES in permissions)
        assertFalse(Manifest.permission.ACCESS_FINE_LOCATION in permissions)
        assertFalse(Manifest.permission.READ_MEDIA_IMAGES in permissions)
        assertFalse(Manifest.permission.READ_MEDIA_VIDEO in permissions)
    }

    @Test
    fun preAndroid12RequestsLocationForBleScanCompatibility() {
        val permissions = AppPermissionPolicy.requiredRuntimePermissions(Build.VERSION_CODES.R)

        assertTrue(Manifest.permission.ACCESS_FINE_LOCATION in permissions)
        assertFalse(Manifest.permission.BLUETOOTH_SCAN in permissions)
        assertFalse(Manifest.permission.BLUETOOTH_CONNECT in permissions)
    }
}
