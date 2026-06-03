package com.camtransfer.ble

object CameraVendorCameraPairingConfirmationPolicy {
    const val WAITING_FOR_PHONE_CONFIRMATION_STATUS = "相机确认后，请在手机上确认"

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
    ): Boolean {
        return hasWrittenIdentifier && hasPendingHandshakeSummary && !shouldBypassManualConfirmation
    }
}
