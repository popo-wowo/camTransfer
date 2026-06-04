package com.camtransfer.protocol

object CameraVendorHiddenObjectProbePolicy {
    const val MAX_HANDLE_RANGE = 120
    private const val MAX_SPECIFIED_HANDLES_FOR_INITIAL_PROBE = 500

    fun shouldProbeHiddenHandles(specifiedHandles: List<Int>): Boolean {
        if (specifiedHandles.size > MAX_SPECIFIED_HANDLES_FOR_INITIAL_PROBE) return false
        val min = specifiedHandles.minOrNull() ?: return false
        val max = specifiedHandles.maxOrNull() ?: return false
        return max >= min && max - min <= MAX_HANDLE_RANGE
    }
}
