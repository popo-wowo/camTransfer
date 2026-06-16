package com.camtransfer.ble

enum class CameraVendorBleHandshakeMode(
    val shouldRunPairingHandshake: Boolean,
) {
    Pairing(shouldRunPairingHandshake = true),
    RememberedGallery(shouldRunPairingHandshake = true),
}
