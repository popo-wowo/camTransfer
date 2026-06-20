package com.camtransfer.ble

import android.content.Context
import android.os.Build
import java.util.Locale

data class CameraVendorConnectedDeviceNameDecision(
    val name: String,
    val source: String,
    val rawLength: Int,
    val normalizedLength: Int,
)

object CameraVendorHandshakeIdentityPolicy {
    private const val FALLBACK_CONNECTED_DEVICE_NAME = "Android"
    private const val MAX_OFFICIAL_MODEL_LENGTH = 21
    private const val OFFICIAL_TRUNCATED_MODEL_LENGTH = 19
    private val OfficialTerminalNameUnsupportedChars = Regex("[^A-Za-z0-9*,-./:=_]")

    fun currentConnectedDeviceName(): String = currentConnectedDeviceNameDecision().name

    fun currentConnectedDeviceNameDecision(): CameraVendorConnectedDeviceNameDecision =
        connectedDeviceNameDecision(Build.MODEL)

    fun connectedDeviceName(
        preferredDeviceName: String?,
        suffix: Long = officialTerminalNameSuffix(),
    ): String =
        connectedDeviceNameDecision(preferredDeviceName, suffix).name

    fun connectedDeviceNameDecision(
        preferredDeviceName: String?,
        suffix: Long = officialTerminalNameSuffix(),
        savedRegistrationName: String? = null,
    ): CameraVendorConnectedDeviceNameDecision {
        val saved = savedRegistrationName.orEmpty().trim()
        if (saved.isNotBlank()) {
            return CameraVendorConnectedDeviceNameDecision(
                name = saved,
                source = "official_android_terminal_name_saved",
                rawLength = preferredDeviceName?.length ?: 0,
                normalizedLength = officialModelName(preferredDeviceName.orEmpty()).length,
            )
        }
        val raw = preferredDeviceName.orEmpty()
        val normalized = officialModelName(raw)
        return CameraVendorConnectedDeviceNameDecision(
            name = String.format(Locale.US, "%s-%04d", normalized, suffix.coerceIn(0, 9_999)),
            source = "official_android_terminal_name",
            rawLength = raw.length,
            normalizedLength = normalized.length,
        )
    }

    private fun officialModelName(modelName: String): String {
        val sanitized = OfficialTerminalNameUnsupportedChars
            .replace(modelName.trim(), "-")
            .ifBlank { FALLBACK_CONNECTED_DEVICE_NAME }
        return if (sanitized.length <= MAX_OFFICIAL_MODEL_LENGTH) {
            sanitized
        } else {
            sanitized.take(OFFICIAL_TRUNCATED_MODEL_LENGTH) + ".."
        }
    }

    private fun officialTerminalNameSuffix(): Long =
        (System.currentTimeMillis() / 1000L) % 10_000L
}

class CameraVendorConnectedDeviceNameStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun currentDecision(): CameraVendorConnectedDeviceNameDecision {
        val existing = prefs.getString(KEY_REGISTERED_TERMINAL_NAME, null)
        val decision = CameraVendorHandshakeIdentityPolicy.connectedDeviceNameDecision(
            preferredDeviceName = Build.MODEL,
            savedRegistrationName = existing,
        )
        if (existing.orEmpty().trim() != decision.name) {
            prefs.edit().putString(KEY_REGISTERED_TERMINAL_NAME, decision.name).apply()
        }
        return decision
    }

    fun rememberRegisteredTerminalName(registeredTerminalName: String): Boolean {
        val normalized = registeredTerminalName.trim()
        if (normalized.isBlank()) return false
        val existing = prefs.getString(KEY_REGISTERED_TERMINAL_NAME, null).orEmpty().trim()
        if (existing == normalized) return false
        prefs.edit().putString(KEY_REGISTERED_TERMINAL_NAME, normalized).apply()
        return true
    }

    private companion object {
        const val PREFS_NAME = "camera_vendor_terminal_identity"
        const val KEY_REGISTERED_TERMINAL_NAME = "registered_terminal_name"
    }
}
