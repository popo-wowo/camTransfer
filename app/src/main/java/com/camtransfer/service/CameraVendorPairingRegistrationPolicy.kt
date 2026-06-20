package com.camtransfer.service

import android.bluetooth.BluetoothDevice

data class CameraVendorSystemBluetoothBond(
    val name: String,
    val address: String,
    val bondState: Int,
)

object CameraVendorPairingRegistrationPolicy {
    fun freshPairingIssueForScannedCamera(
        scannedDeviceName: String?,
        scannedDeviceAddress: String?,
        systemBonds: List<CameraVendorSystemBluetoothBond>,
        canReadSystemBonds: Boolean,
    ): CameraConnectionIssue? {
        if (!canReadSystemBonds) return null
        val scannedAddress = scannedDeviceAddress
            ?.takeIf { it.isNotBlank() }
            ?.let(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
            ?: return null

        val matchingBond = systemBonds
            .filter { it.bondState != BluetoothDevice.BOND_NONE }
            .firstOrNull { bond ->
                bond.address
                    .takeIf { it.isNotBlank() }
                    ?.let(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress) == scannedAddress
            }
            ?: return null

        return CameraConnectionIssue.staleSystemBond(
            matchingBond.name.takeIf { it.isNotBlank() } ?: scannedDeviceName,
        )
    }

    fun issueFor(
        savedRegistration: CameraVendorPairedCameraRecord?,
        systemBonds: List<CameraVendorSystemBluetoothBond>,
        canReadSystemBonds: Boolean,
    ): CameraConnectionIssue? {
        if (!canReadSystemBonds) return null

        val activeBonds = systemBonds.filter { it.bondState != BluetoothDevice.BOND_NONE }
        if (savedRegistration != null) {
            if (savedRegistration.registeredTerminalName.isNullOrBlank()) {
                return CameraConnectionIssue.pairingRegistrationOutOfSync(savedRegistration.deviceName)
            }
            return if (savedRegistration.matchesAny(activeBonds)) {
                null
            } else {
                CameraConnectionIssue.pairingRegistrationOutOfSync(savedRegistration.deviceName)
            }
        }

        val staleCameraBond = activeBonds.firstOrNull { it.looksLikeCamera() }
        return staleCameraBond?.let { CameraConnectionIssue.staleSystemBond(it.name) }
    }

    fun systemCameraBondAddresses(systemBonds: List<CameraVendorSystemBluetoothBond>): List<String> =
        systemBonds
            .filter { it.bondState != BluetoothDevice.BOND_NONE }
            .filter { it.looksLikeCamera() }
            .map { it.address }
            .filter { it.isNotBlank() }

    private fun CameraVendorPairedCameraRecord.matchesAny(
        systemBonds: List<CameraVendorSystemBluetoothBond>,
    ): Boolean {
        val savedAddress = bluetoothAddress
            ?.takeIf { it.isNotBlank() }
            ?.let(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
            ?: return false

        return systemBonds.any { bond ->
            val bondAddress = bond.address
                .takeIf { it.isNotBlank() }
                ?.let(CameraVendorPairingForgetPolicy::normalizeBluetoothAddress)
            savedAddress == bondAddress
        }
    }

    private fun CameraVendorSystemBluetoothBond.looksLikeCamera(): Boolean {
        val upperName = name.uppercase()
        return upperName.startsWith("X-") ||
            upperName.startsWith("FUJIFILM") ||
            upperName.startsWith("GFX")
    }
}
