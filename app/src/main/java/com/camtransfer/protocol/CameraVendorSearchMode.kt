package com.camtransfer.protocol

object CameraVendorSearchMode {
    const val OBJECT_FORMAT_PROPERTY = 0xD604
    const val DATA_TYPE_UINT16 = 1
    const val FORMAT_JPEG = 1
    const val FORMAT_HEIF = 2
    const val FORMAT_MOV = 4
    const val FORMAT_MP4 = 8
    const val FORMAT_RAW = 16
    const val ALL_FORMATS = FORMAT_JPEG or FORMAT_HEIF or FORMAT_MOV or FORMAT_MP4 or FORMAT_RAW
    const val VIDEO_FORMATS = FORMAT_MOV or FORMAT_MP4
}
