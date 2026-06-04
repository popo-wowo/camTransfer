package com.camtransfer.wifi

data class CameraVendorWifiNetworkConfiguration(
    val ssid: String,
    val passphrase: String,
    val isHidden: Boolean,
)

object CameraVendorWifiNetworkConfigurationPolicy {
    fun referenceAppConfiguration(
        ssid: String,
        passphrase: String,
    ): CameraVendorWifiNetworkConfiguration =
        CameraVendorWifiNetworkConfiguration(
            ssid = ssid,
            passphrase = passphrase,
            isHidden = true,
        ).normalized()

    fun configurations(
        deviceName: String?,
        serialNumber: String?,
        preferredWifiNetwork: CameraVendorWifiNetworkConfiguration?,
    ): List<CameraVendorWifiNetworkConfiguration> {
        val candidates = mutableListOf<CameraVendorWifiNetworkConfiguration>()
        if (preferredWifiNetwork != null) {
            return listOf(preferredWifiNetwork.normalized())
        }

        val cleanedName = deviceName?.trim().orEmpty()
        if (cleanedName.isNotEmpty()) {
            val suffix = cameraWifiSuffix(serialNumber)
            if (suffix != null) {
                val normalizedName = cleanedName.uppercase()
                val normalizedSuffix = "-${suffix.uppercase()}"
                val baseName = if (normalizedName.endsWith(normalizedSuffix)) {
                    cleanedName.dropLast(normalizedSuffix.length)
                } else {
                    cleanedName
                }
                val fujifilmSuffixedSsid = "FUJIFILM-$baseName-$suffix"
                val hasExistingFujifilmSuffixedSsid = candidates.any {
                    it.ssid.equals(fujifilmSuffixedSsid, ignoreCase = true)
                }
                if (!normalizedName.startsWith("FUJIFILM-") && !hasExistingFujifilmSuffixedSsid) {
                    candidates += CameraVendorWifiNetworkConfiguration(
                        ssid = fujifilmSuffixedSsid,
                        passphrase = DEFAULT_CAMERA_WIFI_PASSPHRASE,
                        isHidden = false,
                    )
                }

                val suffixedSsid = "$baseName-$suffix"
                val hasExistingSuffixedSsid = candidates.any {
                    it.ssid.equals(suffixedSsid, ignoreCase = true)
                }
                if (!normalizedName.endsWith(normalizedSuffix) && !hasExistingSuffixedSsid) {
                    candidates += CameraVendorWifiNetworkConfiguration(
                        ssid = suffixedSsid,
                        passphrase = DEFAULT_CAMERA_WIFI_PASSPHRASE,
                        isHidden = false,
                    )
                }
            }
            candidates += CameraVendorWifiNetworkConfiguration(
                ssid = cleanedName,
                passphrase = DEFAULT_CAMERA_WIFI_PASSPHRASE,
                isHidden = false,
            )
        }

        val seen = linkedSetOf<String>()
        return candidates.mapNotNull { configuration ->
            val trimmedSsid = configuration.ssid.trim()
            if (trimmedSsid.isEmpty()) return@mapNotNull null
            val key = "$trimmedSsid|${configuration.passphrase}|${configuration.isHidden}"
            if (!seen.add(key)) return@mapNotNull null
            configuration.normalized(trimmedSsid)
        }
    }

    fun cameraWifiSuffix(serialNumber: String?): String? {
        val trimmed = serialNumber?.trim()?.uppercase().orEmpty()
        if (trimmed.length < 4) return null
        return trimmed.takeLast(4)
    }

    private const val DEFAULT_CAMERA_WIFI_PASSPHRASE = "00000000"

    private fun CameraVendorWifiNetworkConfiguration.normalized(
        trimmedSsid: String = ssid.trim(),
    ): CameraVendorWifiNetworkConfiguration =
        copy(ssid = trimmedSsid)
}

object CameraVendorWifiJoinPolicy {
    const val AUTO_JOIN_TIMEOUT_MS = 30_000L
}
