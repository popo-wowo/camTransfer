package com.camtransfer.service

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbManager
import android.mtp.MtpConstants
import android.mtp.MtpDevice
import android.mtp.MtpObjectInfo
import android.os.Build
import com.camtransfer.model.CameraFile
import com.camtransfer.model.ObjectInfo
import com.camtransfer.model.TransferDownloadMode
import com.camtransfer.protocol.PtpObjectFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private const val WIRED_USB_PERMISSION_ACTION = "com.camtransfer.USB_PERMISSION"

class WiredCameraService(override val context: Context) : CameraFileSource {
    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var mtpDevice: MtpDevice? = null
    private var objectHandleBySyntheticHandle: Map<Int, Int> = emptyMap()

    suspend fun connectFirstAvailableDevice() {
        withContext(Dispatchers.IO) {
            disconnect()
            val device = WiredCameraMtpPolicy.firstCandidateDevice(usbManager.deviceList.values)
                ?: throw IllegalStateException("没有发现 USB 相机。请用 OTG 数据线连接相机，并在相机上选择 USB / PC 连接或读卡模式。")
            ensurePermission(device)
            val connection = usbManager.openDevice(device)
                ?: throw IllegalStateException("无法打开 USB 相机，请拔插数据线后重试")
            val mtp = MtpDevice(device)
            if (!mtp.open(connection)) {
                connection.close()
                throw IllegalStateException("USB 相机没有以 MTP/PTP 文件模式响应，请检查相机 USB 设置")
            }
            mtpDevice = mtp
            DiagnosticLog.append(context, "WiredCamera", "USB MTP camera connected")
        }
    }

    override suspend fun listFiles(): List<CameraFile> = withContext(Dispatchers.IO) {
        val mtp = mtpDevice ?: throw IllegalStateException("请先连接 USB 相机")
        val files = mutableListOf<CameraFile>()
        val handleMap = mutableMapOf<Int, Int>()
        val storageIds = mtp.storageIds ?: intArrayOf()
        for (storageId in storageIds) {
            val handles = mtp.getObjectHandles(storageId, 0, 0) ?: intArrayOf()
            for (objectHandle in handles) {
                val mtpInfo = mtp.getObjectInfo(objectHandle) ?: continue
                if (!WiredCameraMtpPolicy.isSupportedFormat(mtpInfo.format, mtpInfo.name.orEmpty())) continue
                val syntheticHandle = WiredCameraMtpPolicy.syntheticHandle(storageId, objectHandle)
                handleMap[syntheticHandle] = objectHandle
                files.add(CameraFile(WiredCameraMtpPolicy.objectInfo(syntheticHandle, mtpInfo)))
            }
        }
        objectHandleBySyntheticHandle = handleMap
        DiagnosticLog.append(context, "WiredCamera", "USB MTP file list visible=${files.size}")
        files.sortedWith(compareByDescending<CameraFile> { it.info.captureDate }.thenByDescending { it.info.handle })
    }

    override suspend fun getThumbnail(handle: Int): ByteArray = withContext(Dispatchers.IO) {
        val mtp = mtpDevice ?: throw IllegalStateException("请先连接 USB 相机")
        val objectHandle = objectHandleBySyntheticHandle[handle] ?: handle
        mtp.getThumbnail(objectHandle) ?: ByteArray(0)
    }

    override suspend fun getFile(
        handle: Int,
        downloadMode: TransferDownloadMode,
    ): ByteArray = withContext(Dispatchers.IO) {
        val mtp = mtpDevice ?: throw IllegalStateException("请先连接 USB 相机")
        val objectHandle = objectHandleBySyntheticHandle[handle] ?: handle
        val info = mtp.getObjectInfo(objectHandle) ?: throw IllegalStateException("USB 相机文件已不可用")
        val size = info.compressedSizeLong.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
        mtp.getObject(objectHandle, size)
            ?: throw IllegalStateException("USB 相机读取文件失败，请确认相机仍保持有线连接")
    }

    override suspend fun disconnect() {
        withContext(Dispatchers.IO) {
            runCatching { mtpDevice?.close() }
            mtpDevice = null
            objectHandleBySyntheticHandle = emptyMap()
        }
    }

    private suspend fun ensurePermission(device: UsbDevice) {
        if (usbManager.hasPermission(device)) return
        suspendCancellableCoroutine { continuation ->
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action != WIRED_USB_PERMISSION_ACTION) return
                    runCatching { context.unregisterReceiver(this) }
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    if (granted) {
                        continuation.resume(Unit)
                    } else {
                        continuation.resumeWithException(IllegalStateException("没有 USB 相机访问权限"))
                    }
                }
            }
            val filter = IntentFilter(WIRED_USB_PERMISSION_ACTION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(receiver, filter)
            }
            continuation.invokeOnCancellation { runCatching { context.unregisterReceiver(receiver) } }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            val permissionIntent = PendingIntent.getBroadcast(
                context,
                0,
                Intent(WIRED_USB_PERMISSION_ACTION).setPackage(context.packageName),
                flags,
            )
            usbManager.requestPermission(device, permissionIntent)
        }
    }
}

object WiredCameraMtpPolicy {
    fun firstCandidateDevice(devices: Collection<UsbDevice>): UsbDevice? =
        devices.firstOrNull { device ->
            device.deviceClass == UsbConstants.USB_CLASS_STILL_IMAGE ||
                (0 until device.interfaceCount).any { index ->
                    val usbInterface = device.getInterface(index)
                    usbInterface.interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE ||
                        usbInterface.interfaceClass == UsbConstants.USB_CLASS_MASS_STORAGE
                }
        } ?: devices.firstOrNull()

    fun isSupportedFormat(format: Int, filename: String): Boolean {
        if (format == PtpObjectFormat.ASSOCIATION || format == MtpConstants.FORMAT_ASSOCIATION) return false
        val upper = filename.uppercase()
        return format == PtpObjectFormat.JPEG ||
            format == PtpObjectFormat.HEIF ||
            format == PtpObjectFormat.CAMERA_VENDOR_RAF ||
            format == PtpObjectFormat.CAMERA_VENDOR_RAF_ALT ||
            format == PtpObjectFormat.MP4 ||
            format == PtpObjectFormat.MOV ||
            upper.endsWith(".JPG") ||
            upper.endsWith(".JPEG") ||
            upper.endsWith(".HEIF") ||
            upper.endsWith(".HEIC") ||
            upper.endsWith(".HIF") ||
            upper.endsWith(".RAF") ||
            upper.endsWith(".RAW") ||
            upper.endsWith(".MOV") ||
            upper.endsWith(".MP4")
    }

    fun objectInfo(handle: Int, mtpInfo: MtpObjectInfo): ObjectInfo =
        ObjectInfo(
            handle = handle,
            storageId = mtpInfo.storageId,
            format = normalizedFormat(mtpInfo.format, mtpInfo.name.orEmpty()),
            compressedSize = mtpInfo.compressedSizeLong.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt(),
            thumbFormat = 0,
            thumbCompressedSize = 0,
            thumbPixWidth = 0,
            thumbPixHeight = 0,
            imagePixWidth = mtpInfo.imagePixWidth,
            imagePixHeight = mtpInfo.imagePixHeight,
            parentObject = mtpInfo.parent,
            filename = mtpInfo.name.orEmpty().ifBlank { "USB-$handle" },
            captureDate = captureDateText(mtpInfo.dateCreated.toLong()),
        )

    fun syntheticHandle(storageId: Int, objectHandle: Int): Int =
        ((storageId and 0xFFFF) shl 16) or (objectHandle and 0xFFFF)

    private fun normalizedFormat(format: Int, filename: String): Int {
        val upper = filename.uppercase()
        return when {
            upper.endsWith(".JPG") || upper.endsWith(".JPEG") -> PtpObjectFormat.JPEG
            upper.endsWith(".HEIF") || upper.endsWith(".HEIC") || upper.endsWith(".HIF") -> PtpObjectFormat.HEIF
            upper.endsWith(".RAF") -> PtpObjectFormat.CAMERA_VENDOR_RAF
            upper.endsWith(".MOV") -> PtpObjectFormat.MOV
            upper.endsWith(".MP4") -> PtpObjectFormat.MP4
            else -> format
        }
    }

    fun captureDateText(dateCreatedSeconds: Long): String {
        if (dateCreatedSeconds <= 0L) return ""
        return Instant.ofEpochSecond(dateCreatedSeconds)
            .atZone(ZoneId.systemDefault())
            .format(DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss"))
    }
}
