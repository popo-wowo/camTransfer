package com.camtransfer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.temporal.ChronoUnit

class TrialAccessPolicyTest {
    @Test
    fun allowsUseBeforeConfiguredMinutesHaveElapsed() {
        val startedAt = Instant.parse("2026-01-01T00:00:00Z")

        val firstSecond = TrialAccessPolicy.evaluate(
            startedAt = startedAt,
            currentTime = startedAt,
            durationMinutes = 10,
        )
        val finalSecond = TrialAccessPolicy.evaluate(
            startedAt = startedAt,
            currentTime = startedAt.plus(9, ChronoUnit.MINUTES).plus(59, ChronoUnit.SECONDS),
            durationMinutes = 10,
        )

        assertTrue(firstSecond.canUse)
        assertEquals(600, firstSecond.remainingSeconds)
        assertTrue(finalSecond.canUse)
        assertEquals(1, finalSecond.remainingSeconds)
    }

    @Test
    fun blocksUseOnceConfiguredMinutesHaveElapsed() {
        val startedAt = Instant.parse("2026-01-01T00:00:00Z")

        val trialAccess = TrialAccessPolicy.evaluate(
            startedAt = startedAt,
            currentTime = startedAt.plus(10, ChronoUnit.MINUTES),
            durationMinutes = 10,
        )

        assertFalse(trialAccess.canUse)
        assertEquals(0, trialAccess.remainingSeconds)
    }

    @Test
    fun reportsTheExpirationTime() {
        val startedAt = Instant.parse("2026-05-31T02:30:00Z")

        val trialAccess = TrialAccessPolicy.evaluate(
            startedAt = startedAt,
            currentTime = startedAt.plus(3, ChronoUnit.MINUTES),
            durationMinutes = 10,
        )

        assertEquals(Instant.parse("2026-05-31T02:40:00Z"), trialAccess.expiresAt)
    }
}
