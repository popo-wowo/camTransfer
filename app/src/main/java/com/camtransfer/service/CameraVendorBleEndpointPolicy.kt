package com.camtransfer.service

import android.bluetooth.BluetoothDevice

object CameraVendorBleEndpointPolicy {
    data class SystemBond(
        val name: String,
        val address: String,
        val type: Int? = null,
    )

    data class Candidate(
        val address: String,
        val source: CandidateSource,
    )

    enum class CandidateSource {
        SystemBond,
        SavedRecord,
    }

    fun identityVerifiedCandidates(
        remembered: CameraVendorPairedCameraRecord,
        systemBonds: List<SystemBond>,
    ): List<Candidate> {
        val candidates = linkedMapOf<String, Candidate>()
        val matchedNameBonds = systemBonds
            .filter { it.address.isNotBlank() && nameMatches(it.name, remembered.deviceName) }
        matchedNameBonds.forEach { bond ->
            val normalized = bond.address.normalizedAddress()
            candidates.putIfAbsent(
                normalized,
                Candidate(
                    address = normalized,
                    source = CandidateSource.SystemBond,
                ),
            )
        }

        if (matchedNameBonds.isEmpty() && remembered.cameraId.contains("_")) {
            val soleLeBond = systemBonds
                .filter { it.address.isNotBlank() && it.type == BluetoothDevice.DEVICE_TYPE_LE }
                .distinctBy { it.address.normalizedAddress() }
                .singleOrNull()
            if (soleLeBond != null) {
                val normalized = soleLeBond.address.normalizedAddress()
                candidates.putIfAbsent(
                    normalized,
                    Candidate(
                        address = normalized,
                        source = CandidateSource.SystemBond,
                    ),
                )
            }
        }

        remembered.bluetoothAddress
            ?.takeIf { it.isNotBlank() }
            ?.normalizedAddress()
            ?.let { address ->
                candidates.putIfAbsent(
                    address,
                    Candidate(
                        address = address,
                        source = CandidateSource.SavedRecord,
                    ),
                )
            }

        return candidates.values.toList()
    }

    private fun nameMatches(candidateName: String, rememberedName: String): Boolean {
        val candidate = candidateName.trim()
        val remembered = rememberedName.trim()
        if (candidate.isBlank() || remembered.isBlank()) return false
        return candidate == remembered ||
            candidate.contains(remembered, ignoreCase = true) ||
            remembered.contains(candidate, ignoreCase = true)
    }

    private fun String.normalizedAddress(): String =
        trim().uppercase()
}
