package com.camtransfer.protocol

object CameraVendorGalleryDiscoveryPolicy {
    fun shouldIncludeStandardEnumeration(specifiedHandleCount: Int): Boolean =
        specifiedHandleCount > 0
}
