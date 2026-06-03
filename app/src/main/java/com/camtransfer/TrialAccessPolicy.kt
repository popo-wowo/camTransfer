package com.camtransfer

import java.time.Clock
import java.time.Instant
import java.time.temporal.ChronoUnit

data class TrialAccess(
    val canUse: Boolean,
    val remainingSeconds: Long,
    val expiresAt: Instant,
)

object TrialAccessPolicy {
    fun evaluate(startedAt: Instant, currentTime: Instant, durationMinutes: Long): TrialAccess {
        val expiresAt = startedAt.plus(durationMinutes, ChronoUnit.MINUTES)
        val remainingSeconds = ChronoUnit.SECONDS.between(currentTime, expiresAt)
            .coerceAtLeast(0L)
        return TrialAccess(
            canUse = currentTime.isBefore(expiresAt),
            remainingSeconds = remainingSeconds,
            expiresAt = expiresAt,
        )
    }

    fun evaluateBuildStart(
        startEpochMillis: Long,
        durationMinutes: Long,
        clock: Clock = Clock.systemDefaultZone(),
    ): TrialAccess {
        return evaluate(
            startedAt = Instant.ofEpochMilli(startEpochMillis),
            currentTime = Instant.now(clock),
            durationMinutes = durationMinutes,
        )
    }
}
