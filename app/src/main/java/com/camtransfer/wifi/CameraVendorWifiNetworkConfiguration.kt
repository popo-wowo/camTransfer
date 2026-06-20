package com.camtransfer.wifi

data class CameraVendorWifiNetworkConfiguration(
    val ssid: String,
    val passphrase: String,
    val isHidden: Boolean,
    val bssid: String? = null,
)

object CameraVendorWifiNetworkConfigurationPolicy {
    fun referenceAppConfiguration(
        ssid: String,
        passphrase: String,
        macAddress: String? = null,
    ): CameraVendorWifiNetworkConfiguration =
        CameraVendorWifiNetworkConfiguration(
            ssid = ssid,
            passphrase = passphrase,
            isHidden = false,
            bssid = normalizeBssid(macAddress),
        ).normalized()

    fun configurations(
        deviceName: String?,
        serialNumber: String?,
        preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?,
    ): List<CameraVendorWifiNetworkConfiguration> {
        return preferredWifiNetwork?.normalized()?.let(::listOf).orEmpty()
    }

    fun normalizeBssid(raw: String?): String? {
        val hex = raw
            ?.trim()
            ?.filter { it.isLetterOrDigit() }
            ?.lowercase()
            .orEmpty()
        if (hex.length != 12 || !hex.all { it in '0'..'9' || it in 'a'..'f' }) return null
        return hex.chunked(2).joinToString(":")
    }

    private fun CameraVendorWifiNetworkConfiguration.normalized(
        trimmedSsid: String = ssid.trim(),
    ): CameraVendorWifiNetworkConfiguration =
        copy(ssid = trimmedSsid, bssid = normalizeBssid(bssid))
}

object CameraVendorWifiJoinPolicy {
    const val AUTO_JOIN_TIMEOUT_MS = 30_000L
    const val AUTO_JOIN_ATTEMPTS_PER_EXACT_NETWORK = 1
    const val SHOULD_PROBE_EXISTING_PTP_BEFORE_WIFI_REQUEST = true

    fun retryDelayMs(afterFailedAttempt: Int): Long =
        when (afterFailedAttempt) {
            1 -> 1_500L
            2 -> 3_000L
            3 -> 4_000L
            else -> 6_000L
        }
}
