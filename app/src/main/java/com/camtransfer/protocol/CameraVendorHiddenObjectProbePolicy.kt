package com.camtransfer.protocol

object CameraVendorHiddenObjectProbePolicy {
    const val MAX_HANDLE_RANGE = 120
    private const val MAX_SPECIFIED_HANDLES_FOR_INITIAL_PROBE = 500
    private const val MAX_BACKGROUND_CANDIDATES = 96
    private const val MAX_RECENT_GAP_CANDIDATES = 60
    private const val FORWARD_PROBE_RANGE = 20

    fun shouldProbeHiddenHandles(specifiedHandles: List<Int>): Boolean {
        if (specifiedHandles.size > MAX_SPECIFIED_HANDLES_FOR_INITIAL_PROBE) return false
        val min = specifiedHandles.minOrNull() ?: return false
        val max = specifiedHandles.maxOrNull() ?: return false
        return max >= min && max - min <= MAX_HANDLE_RANGE
    }

    fun backgroundHiddenHandleCandidates(knownHandles: List<Int>): List<Int> {
        val sorted = knownHandles.distinct().sorted()
        if (sorted.size < 2) return emptyList()
        val candidates = mutableListOf<Int>()
        for (index in 0 until sorted.lastIndex) {
            val lower = sorted[index]
            val upper = sorted[index + 1]
            val gapSize = upper - lower - 1
            if (gapSize in 1..8) {
                for (candidate in (lower + 1) until upper) {
                    candidates.add(candidate)
                    if (candidates.size > MAX_BACKGROUND_CANDIDATES) return emptyList()
                }
            }
        }
        return candidates
    }

    /**
     * Returns gap candidates from the most recent (highest handle) end of the list.
     * This finds HEIF/RAW that are adjacent to recent JPEG handles without needing
     * to scan the entire gallery. Limited to MAX_RECENT_GAP_CANDIDATES.
     */
    fun recentGapCandidates(knownHandles: List<Int>): List<Int> {
        val sorted = knownHandles.distinct().sortedDescending()
        if (sorted.size < 2) return emptyList()
        val candidates = mutableListOf<Int>()
        for (index in 0 until sorted.lastIndex) {
            val upper = sorted[index]
            val lower = sorted[index + 1]
            val gapSize = upper - lower - 1
            if (gapSize in 1..20) {
                for (candidate in (upper - 1) downTo (lower + 1)) {
                    candidates.add(candidate)
                    if (candidates.size >= MAX_RECENT_GAP_CANDIDATES) return candidates
                }
            }
        }
        return candidates
    }

    fun forwardProbeCandidates(knownHandles: List<Int>): List<Int> {
        val maxHandle = knownHandles.maxOrNull() ?: return emptyList()
        if (maxHandle >= Int.MAX_VALUE - FORWARD_PROBE_RANGE) return emptyList()
        return ((maxHandle + 1)..(maxHandle + FORWARD_PROBE_RANGE)).toList()
    }
}
