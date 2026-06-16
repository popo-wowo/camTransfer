package com.camtransfer.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorCameraPairingConfirmationPolicyTest {

    @Test
    fun pairingFinishesOnlyAfterIdentifierWriteAndUserConfirmation() {
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
                hasWrittenIdentifier = false,
                hasUserConfirmedCameraSuccess = true,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
                hasWrittenIdentifier = true,
                hasUserConfirmedCameraSuccess = false,
            )
        )
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.canFinishPairing(
                hasWrittenIdentifier = true,
                hasUserConfirmedCameraSuccess = true,
            )
        )
    }

    @Test
    fun phoneConfirmationCanBeQueuedUntilAckAndSummaryAreReady() {
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.shouldQueuePhoneConfirmation(
                hasWrittenIdentifier = false,
                hasPendingHandshakeSummary = true,
                hasUserConfirmedCameraSuccess = true,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.shouldQueuePhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                hasUserConfirmedCameraSuccess = true,
            )
        )
    }

    @Test
    fun queuedPhoneConfirmationCompletesOnlyAfterAckAndSummaryAreReady() {
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
                hasWrittenIdentifier = false,
                hasPendingHandshakeSummary = true,
                hasQueuedPhoneConfirmation = true,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = false,
                hasQueuedPhoneConfirmation = true,
            )
        )
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.canCompleteQueuedPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                hasQueuedPhoneConfirmation = true,
            )
        )
    }

    @Test
    fun phoneConfirmationReplaysAckOnlyAfterSystemBondIsConfirmed() {
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                shouldBypassManualConfirmation = false,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDED,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                shouldBypassManualConfirmation = false,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDING,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                shouldBypassManualConfirmation = false,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_NONE,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.shouldReconnectAfterPhoneConfirmation(
                hasWrittenIdentifier = true,
                hasPendingHandshakeSummary = true,
                shouldBypassManualConfirmation = true,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDED,
            )
        )
    }

    @Test
    fun pairingCanBeSavedOnlyAfterSystemBondIsSettled() {
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canSaveConfirmedPairing(
                hasCompletedCameraAck = true,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDING,
            )
        )
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.canSaveConfirmedPairing(
                hasCompletedCameraAck = true,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDED,
            )
        )
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.canSaveConfirmedPairing(
                hasCompletedCameraAck = true,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_NONE,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.canSaveConfirmedPairing(
                hasCompletedCameraAck = false,
                systemBondState = CameraVendorCameraPairingConfirmationPolicy.SYSTEM_BOND_BONDED,
            )
        )
    }

    @Test
    fun waitsForPhoneConfirmationUnlessThisIsAlreadyPairedReconnect() {
        assertTrue(
            CameraVendorCameraPairingConfirmationPolicy.shouldWaitForPhoneConfirmationAfterIdentifierWrite(
                shouldBypassManualConfirmation = false,
            )
        )
        assertFalse(
            CameraVendorCameraPairingConfirmationPolicy.shouldWaitForPhoneConfirmationAfterIdentifierWrite(
                shouldBypassManualConfirmation = true,
            )
        )
    }
}
