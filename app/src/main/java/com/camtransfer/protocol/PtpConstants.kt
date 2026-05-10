package com.camtransfer.protocol

object PtpPacketType {
    const val INIT_COMMAND_REQUEST = 0x00000001
    const val INIT_COMMAND_ACK = 0x00000002
    const val INIT_EVENT_REQUEST = 0x00000003
    const val INIT_EVENT_ACK = 0x00000004
    const val OPERATION_REQUEST = 0x00000006
    const val OPERATION_RESPONSE = 0x00000007
    const val EVENT = 0x00000008
    const val START_DATA_PACKET = 0x00000009
    const val DATA_PACKET = 0x0000000A
    const val CANCEL_TRANSACTION = 0x0000000B
    const val END_DATA_PACKET = 0x0000000C
}

object PtpOpCode {
    const val GET_DEVICE_INFO = 0x1001
    const val OPEN_SESSION = 0x1002
    const val CLOSE_SESSION = 0x1003
    const val GET_STORAGE_IDS = 0x1004
    const val GET_STORAGE_INFO = 0x1005
    const val GET_NUM_OBJECTS = 0x1006
    const val GET_OBJECT_HANDLES = 0x1007
    const val GET_OBJECT_INFO = 0x1008
    const val GET_OBJECT = 0x1009
    const val GET_THUMB = 0x100A
    const val GET_PARTIAL_OBJECT = 0x101B
}

object PtpResponseCode {
    const val OK = 0x2001
    const val GENERAL_ERROR = 0x2002
    const val SESSION_NOT_OPEN = 0x2003
    const val INVALID_TRANSACTION_ID = 0x2004
    const val OPERATION_NOT_SUPPORTED = 0x2005
    const val PARAMETER_NOT_SUPPORTED = 0x2006
    const val INCOMPLETE_TRANSFER = 0x2007
    const val INVALID_STORAGE_ID = 0x2008
    const val INVALID_OBJECT_HANDLE = 0x2009
    const val STORE_READ_ONLY = 0x200A
    const val NO_THUMBNAIL_PRESENT = 0x2010
}

object PtpObjectFormat {
    const val UNDEFINED = 0x3000
    const val ASSOCIATION = 0x3001
    const val JPEG = 0x3801
    const val TIFF = 0x380D
    const val MOV = 0x300B
    const val MP4 = 0x300D
    const val CAMERA_VENDOR_RAF = 0xB101
}

object CameraVendorConst {
    const val DEFAULT_CAMERA_IP = "192.168.0.1"
    const val COMMAND_PORT = 55740
    const val EVENT_PORT = 55741
    const val PROTOCOL_VERSION = 0x00010000
    const val ALL_FORMATS = 0x00000000
    const val ALL_HANDLES = 0xFFFFFFFF.toInt()
}
