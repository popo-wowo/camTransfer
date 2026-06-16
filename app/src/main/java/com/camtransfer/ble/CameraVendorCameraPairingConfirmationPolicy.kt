package com.camtransfer.ble

object CameraVendorCameraPairingConfirmationPolicy {
    const val WAITING_FOR_PHONE_CONFIRMATION_STATUS = "相机确认后，请在手机上确认"
    const val SYSTEM_BOND_NONE = 10
    const val SYSTEM_BOND_BONDING = 11
    const val SYSTEM_BOND_BONDED = 12

    fun canFinishPairing(
        hasWrittenIdentifier: Boolean,
        hasUserConfirmedCameraSuccess: Boolean,
    ): Boolean {
        return hasWrittenIdentifier && hasUserConfirmedCameraSuccess
    }

    fun shouldQueuePhoneConfirmation(
        hasWrittenIdentifier: Boolean,
        hasPendingHandshakeSummary: Boolean,
        hasUserConfirmedCameraSuccess: Boolean,
    ): Boolean {
        return hasUserConfirmedCameraSuccess && !canCompleteQueuedPhoneConfirmation(
            hasWrittenIdentifier = hasWrittenIdentifier,
            hasPendingHandshakeSummary = hasPendingHandshakeSummary,
            hasQueuedPhoneConfirmation = true,
        )
    }

    fun canCompleteQueuedPhoneConfirmation(
        hasWrittenIdentifier: Boolean,
        hasPendingHandshakeSummary: Boolean,
        hasQueuedPhoneConfirmation: Boolean,
    ): Boolean {
        return hasQueuedPhoneConfirmation && hasWrittenIdentifier && hasPendingHandshakeSummary
    }

    fun shouldWaitForPhoneConfirmationAfterIdentifierWrite(
        shouldBypassManualConfirmation: Boolean,
    ): Boolean {
        return !shouldBypassManualConfirmation
    }

    fun shouldReconnectAfterPhoneConfirmation(
        hasWrittenIdentifier: Boolean,
        hasPendingHandshakeSummary: Boolean,
        shouldBypassManualConfirmation: Boolean,
        systemBondState: Int,
    ): Boolean {
        return hasWrittenIdentifier &&
            hasPendingHandshakeSummary &&
            !shouldBypassManualConfirmation &&
            systemBondState == SYSTEM_BOND_BONDED
    }

    fun canSaveConfirmedPairing(
        hasCompletedCameraAck: Boolean,
        systemBondState: Int,
    ): Boolean {
        if (!hasCompletedCameraAck) return false
        return systemBondState != SYSTEM_BOND_BONDING
    }
}
