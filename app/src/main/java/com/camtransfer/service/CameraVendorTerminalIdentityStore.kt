package com.camtransfer.service

import android.content.Context
import java.util.UUID

object CameraVendorTerminalIdentityPolicy {
    private val UuidRegex = Regex(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
    )

    fun resolveTerminalUserId(
        existing: String?,
        generate: () -> String = { UUID.randomUUID().toString() },
    ): String {
        val trimmed = existing?.trim().orEmpty()
        if (isValidTerminalUserId(trimmed)) return trimmed

        val generated = generate().trim()
        require(isValidTerminalUserId(generated)) { "Generated terminal user id is not a UUID" }
        return generated
    }

    fun isValidTerminalUserId(value: String?): Boolean =
        !value.isNullOrBlank() && UuidRegex.matches(value.trim())

    fun logLabel(value: String?): String =
        if (isValidTerminalUserId(value)) {
            "present length=${value!!.trim().length}"
        } else {
            "missing"
        }
}

class CameraVendorTerminalIdentityStore(context: Context) {
    private val prefs = context.getSharedPreferences("camera_vendor_terminal_identity", Context.MODE_PRIVATE)

    fun terminalUserId(): String {
        val resolved = CameraVendorTerminalIdentityPolicy.resolveTerminalUserId(
            existing = prefs.getString(KEY_TERMINAL_USER_ID, null),
        )
        if (resolved != prefs.getString(KEY_TERMINAL_USER_ID, null)) {
            prefs.edit().putString(KEY_TERMINAL_USER_ID, resolved).apply()
        }
        return resolved
    }

    private companion object {
        const val KEY_TERMINAL_USER_ID = "terminal_user_id"
    }
}
