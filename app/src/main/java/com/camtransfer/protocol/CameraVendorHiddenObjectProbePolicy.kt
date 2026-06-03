package com.camtransfer.protocol

object CameraVendorHiddenObjectProbePolicy {
    const val MAX_HANDLE_RANGE = 120

    fun shouldProbeHiddenHandles(specifiedHandles: List<Int>): Boolean {
        val min = specifiedHandles.minOrNull() ?: return false
        val max = specifiedHandles.maxOrNull() ?: return false
        return max >= min && max - min <= MAX_HANDLE_RANGE
    }
}
