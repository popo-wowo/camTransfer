package com.camtransfer.service

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class CameraVendorOfficialCameraOpenAdapterTest {
    @Test
    fun retriesUsingKnownWorkingPtpOpenOrder() = runBlocking {
        val attempts = mutableListOf<Long>()
        val failures = mutableListOf<Int>()
        val waits = mutableListOf<String>()
        var calls = 0

        CameraVendorOfficialCameraOpenAdapter(
            attemptTimeoutsMs = listOf(1_500L, 1_500L, 1_500L),
            startupDelayMs = 0L,
            retryDelayMs = { attempt -> 500L * attempt },
        ).open(
            onFailure = { attempt, _, _ -> failures += attempt },
            onWaitingForRetry = { attempt, delayMs -> waits += "$attempt:$delayMs" },
            openOnce = { timeoutMs ->
                calls += 1
                attempts += timeoutMs
                if (calls < 3) throw IllegalStateException("not ready")
            },
        )

        assertEquals(listOf(1_500L, 1_500L, 1_500L), attempts)
        assertEquals(listOf(1, 2), failures)
        assertEquals(listOf("1:500", "2:1000"), waits)
    }
}
