package com.camtransfer.wifi

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorWifiJoinPolicyTest {
    @Test
    fun autoJoinTimeoutAllowsAndroidHiddenNetworkMatchingToComplete() {
        assertEquals(30_000L, CameraVendorWifiJoinPolicy.AUTO_JOIN_TIMEOUT_MS)
    }
}
