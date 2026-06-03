package com.camtransfer.service

import android.os.Build
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraBluetoothPermissionPolicyTest {
    @Test
    fun preAndroid12CanReadSystemBondsWithoutBluetoothConnectPermission() {
        assertTrue(
            CameraBluetoothPermissionPolicy.canReadSystemBonds(
                sdkInt = Build.VERSION_CODES.R,
                hasBluetoothConnectPermission = false,
            )
        )
    }

    @Test
    fun android12AndAboveRequiresBluetoothConnectPermissionToReadSystemBonds() {
        assertFalse(
            CameraBluetoothPermissionPolicy.canReadSystemBonds(
                sdkInt = Build.VERSION_CODES.S,
                hasBluetoothConnectPermission = false,
            )
        )
        assertTrue(
            CameraBluetoothPermissionPolicy.canReadSystemBonds(
                sdkInt = Build.VERSION_CODES.S,
                hasBluetoothConnectPermission = true,
            )
        )
    }
}
