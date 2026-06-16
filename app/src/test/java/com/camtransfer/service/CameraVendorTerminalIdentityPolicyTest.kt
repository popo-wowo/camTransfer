package com.camtransfer.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraVendorTerminalIdentityPolicyTest {
    @Test
    fun keepsExistingUuidTerminalUserIdStable() {
        val existing = "123e4567-e89b-12d3-a456-426614174000"

        val resolved = CameraVendorTerminalIdentityPolicy.resolveTerminalUserId(
            existing = existing,
            generate = { error("should not generate") },
        )

        assertEquals(existing, resolved)
    }

    @Test
    fun generatesUuidTerminalUserIdWhenMissingOrInvalid() {
        val generated = "123e4567-e89b-12d3-a456-426614174001"

        val resolved = CameraVendorTerminalIdentityPolicy.resolveTerminalUserId(
            existing = "CamTransfer",
            generate = { generated },
        )

        assertEquals(generated, resolved)
        assertTrue(CameraVendorTerminalIdentityPolicy.isValidTerminalUserId(resolved))
    }

    @Test
    fun terminalUserIdLogLabelDoesNotExposeFullIdentifier() {
        assertEquals(
            "present length=36",
            CameraVendorTerminalIdentityPolicy.logLabel("123e4567-e89b-12d3-a456-426614174000"),
        )
    }
}
