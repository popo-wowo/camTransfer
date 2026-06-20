package com.camtransfer.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraConnectionEntryPolicyTest {
    @Test
    fun errorEntryWithRememberedPairingProbesExistingPtpBeforeBle() {
        assertTrue(
            CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(
                state = ConnectionState.ERROR,
                hasRememberedPairing = true,
            )
        )
    }

    @Test
    fun skipsExistingPtpProbeForFreshPairingSoItStaysOnSearchFlow() {
        assertFalse(
            CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(
                state = ConnectionState.IDLE,
                hasRememberedPairing = false,
            )
        )
        assertFalse(
            CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(
                state = ConnectionState.ERROR,
                hasRememberedPairing = false,
            )
        )
        assertFalse(
            CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(
                state = ConnectionState.SCANNING,
                hasRememberedPairing = true,
            )
        )
        assertFalse(
            CameraConnectionEntryPolicy.shouldProbeExistingPtpBeforeBle(
                state = ConnectionState.CONNECTED,
                hasRememberedPairing = true,
            )
        )
    }

}
