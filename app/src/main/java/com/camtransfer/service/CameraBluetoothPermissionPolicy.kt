package com.camtransfer.service

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

object CameraBluetoothPermissionPolicy {
    fun canReadSystemBonds(
        sdkInt: Int,
        hasBluetoothConnectPermission: Boolean,
    ): Boolean =
        sdkInt < Build.VERSION_CODES.S || hasBluetoothConnectPermission

    fun canReadSystemBonds(context: Context): Boolean =
        canReadSystemBonds(
            sdkInt = Build.VERSION.SDK_INT,
            hasBluetoothConnectPermission = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT,
            ) == PackageManager.PERMISSION_GRANTED,
        )
}
