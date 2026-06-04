package com.camtransfer.service

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraConnectionCancellationPolicyTest {
    @Test
    fun userCancellationPropagatesInsteadOfBecomingConnectionFailure() {
        assertTrue(
            CameraConnectionCancellationPolicy.shouldPropagate(
                CancellationException("user started a new connection action"),
            ),
        )
    }

    @Test
    fun operationTimeoutRemainsARecoverableConnectionFailure() {
        val timeout = runCatching {
            runBlocking {
                withTimeout(1) {
                    delay(10)
                }
            }
        }.exceptionOrNull()!!

        assertFalse(
            CameraConnectionCancellationPolicy.shouldPropagate(
                timeout,
            ),
        )
    }
}
