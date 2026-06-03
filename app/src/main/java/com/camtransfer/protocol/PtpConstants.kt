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
    const val GET_DEVICE_PROP_VALUE = 0x1015
    const val SET_DEVICE_PROP_VALUE = 0x1016
    const val GET_PARTIAL_OBJECT = 0x101B
    const val MTP_GET_OBJECT_PROP_LIST = 0x9805
    const val CAMERA_VENDOR_GET_SEARCH_MODE_DESC_ALL = 0x9050
    const val CAMERA_VENDOR_SET_SEARCH_MODE_ALL = 0x9051
    const val CAMERA_VENDOR_GET_SEARCH_MODE_ALL = 0x9052
    const val CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE = 0x9053
    const val CAMERA_VENDOR_GET_LATEST_OBJECT_INFO = 0x9054
    const val CAMERA_VENDOR_GET_EXTENSION_THUMB = 0x9055
    const val CAMERA_VENDOR_GET_EXTENSION_PARTIAL_OBJECT = 0x9056
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
    const val HEIF = 0x3812
    const val TIFF = 0x380D
    const val MOV = 0x300B
    const val MP4 = 0x300D
    const val CAMERA_VENDOR_RAF = 0xB101
    const val CAMERA_VENDOR_RAF_ALT = 0xB103
}

object CameraVendorConst {
    const val DEFAULT_CAMERA_IP = "192.168.0.1"
    const val COMMAND_PORT = 55740
    const val EVENT_PORT = 55741
    const val STANDARD_PTP_IP_PROTOCOL_VERSION = 0x00010000
    const val CAMERA_VENDOR_LEGACY_PROTOCOL_VERSION = 0x8F53E4F2L
    const val ALL_FORMATS = 0x00000000
    const val ALL_HANDLES = 0xFFFFFFFF.toInt()
    const val INIT_DEVICE_NAME_BYTE_COUNT = 54
    val INIT_GUID_BASE_WORDS = longArrayOf(
        0x5D48A5ADL,
        0x0B7FB287L,
        0xD0DED5D3L,
    )
}

object CameraVendorDevicePropCode {
    const val CAMERA_STATE = 0xDF00
    const val INIT_SEQUENCE = 0xDF01
    const val IMAGE_GET_VERSION = 0xDF21
    const val GET_OBJECT_VERSION = 0xDF22
    const val APP_VERSION = 0xDF24
    const val REMOTE_GET_OBJECT_VERSION = 0xDF25
    const val IMAGE_FORCE_COMPRESSION = 0xD226
    const val IMAGE_COMPRESSION_REAL_INFO = 0xD227
    const val REFERENCE_APP_IMAGE_HOST = 0xDF28
    const val REFERENCE_APP_RESERVED_RECEIVE = 0xDF29
    const val REFERENCE_APP_GALLERY_OBJECT_CONTEXT = 0xD212
    const val REFERENCE_APP_GALLERY_READY_MARKER = 0xD222
    const val CURRENT_OBJECT_HANDLE = 0xD22B
    const val COMPRESSION_CUT_OFF = 0xD235
    const val REFERENCE_APP_GALLERY_ACCESS_STATE = 0xD244
    const val DUAL_SLOT_STATUS = 0xD244
    const val SPECIFIED_OBJECT_COUNT = 0xD620
    const val SPECIFIED_OBJECT_HANDLES = 0xD621
}

object CameraVendorReferenceApp {
    const val REMOTE_IMAGE_VIEWER_CLIENT_STATE = 20
    const val IMAGE_HOST_VERSION = 3
    const val CURRENT_IMAGE_HANDLE = 0x10000001
    const val SPECIFIED_OBJECT_COUNT_LIMIT = 30000
    const val PARTIAL_PREVIEW_READ_SIZE = 256 * 1024
    const val PARTIAL_INITIAL_READ_SIZE = 1 * 1024 * 1024
    const val PARTIAL_FILE_READ_SIZE = 4 * 1024 * 1024
    const val PARTIAL_FILE_READ_TIMEOUT_MS = 60_000
    const val PARTIAL_MAX_BYTES_WITHOUT_KNOWN_SIZE = 128 * 1024 * 1024
}
