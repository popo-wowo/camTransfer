package com.camtransfer

import android.Manifest
import android.os.Build

object AppPermissionPolicy {
    fun requiredRuntimePermissions(sdkInt: Int = Build.VERSION.SDK_INT): List<String> =
        if (sdkInt >= Build.VERSION_CODES.S) {
            buildList {
                add(Manifest.permission.BLUETOOTH_SCAN)
                add(Manifest.permission.BLUETOOTH_CONNECT)
                if (sdkInt >= Build.VERSION_CODES.TIRAMISU) {
                    add(Manifest.permission.NEARBY_WIFI_DEVICES)
                    add(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
}
