package com.camtransfer.wifi

import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorWifiJoinPolicyTest {
    @Test
    fun autoJoinTimeoutAllowsAndroidHiddenNetworkMatchingToComplete() {
        assertEquals(30_000L, CameraVendorWifiJoinPolicy.AUTO_JOIN_TIMEOUT_MS)
    }

    @Test
    fun exactWifiRequestSurfacesUnavailableWithoutInternalRetryLoop() {
        assertEquals(1, CameraVendorWifiJoinPolicy.AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK)
        assertEquals(1_500L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 1))
        assertEquals(3_000L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 2))
        assertEquals(4_000L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 3))
        assertEquals(6_000L, CameraVendorWifiJoinPolicy.retryDelayMs(afterFailedAttempt = 4))
    }

    @Test
    fun probesExistingPtpBeforeRequestingWifiAgain() {
        assertEquals(true, CameraVendorWifiJoinPolicy.SHOULD_PROBE_EXISTING_PTP_BEFORE_WIFI_REQUEST)
    }
}
