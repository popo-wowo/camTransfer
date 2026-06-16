package com.camtransfer.protocol

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.net.SocketFactory

private const val TAG = "PtpConnection"

data class PtpOperationResponse(
    val responseCode: Int,
    val transactionId: Int,
    val params: List<Int> = emptyList(),
)

class PtpConnection {
    private var cmdSocket: Socket? = null
    private var transactionId = 0
    private var sessionOpen = false
    private val commandMutex = Mutex()
    private var specifiedObjectHandles: List<Int> = emptyList()

    val isConnected: Boolean get() = sessionOpen
    val cameraVendorSpecifiedObjectHandles: List<Int> get() = specifiedObjectHandles
    val nextTransactionId: Int get() = ++transactionId

    suspend fun connect(
        host: String = CameraVendorConst.DEFAULT_CAMERA_IP,
        clientName: String = "CamTransfer",
        socketFactory: SocketFactory? = null,
        connectTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.OPEN_ATTEMPT_TIMEOUT_MS.toInt(),
        initReadTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.INIT_ACK_READ_TIMEOUT_MS.toInt(),
        commandReadTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.COMMAND_READ_TIMEOUT_MS.toInt(),
        confirmGalleryMode: Boolean = true,
    ) {
        disconnect()
        transactionId = 0
        specifiedObjectHandles = emptyList()

        withContext(Dispatchers.IO) {
            var lastError: Throwable? = null
            for (variant in CameraVendorPtpInitPolicy.legacyInitVariants()) {
                val cmd = PtpConnectionSocketPolicy.createSocket(socketFactory)
                try {
                    cmd.tcpNoDelay = true
                    cmd.receiveBufferSize = 2 * 1024 * 1024
                    cmd.sendBufferSize = 2 * 1024 * 1024
                    cmd.connect(InetSocketAddress(host, CameraVendorConst.COMMAND_PORT), connectTimeoutMs)
                    cmd.soTimeout = initReadTimeoutMs
                    cmdSocket = cmd

                    val socketLocalIp = cmd.localAddress?.hostAddress
                    val initClientIp = CameraVendorPtpInitPolicy.clientIpForVariant(variant, socketLocalIp)
                    val initPacket = PtpPacketBuilder.buildCameraVendorLegacyInitCommandRequest(
                        friendlyName = clientName,
                        clientIp = initClientIp,
                    )
                    Log.d(
                        TAG,
                        "Sending ${variant.label} INIT socketLocalIp=$socketLocalIp clientIp=$initClientIp bytes=${initPacket.size}",
                    )
                    cmd.getOutputStream().write(initPacket)
                    cmd.getOutputStream().flush()
                    delay(50)

                    val ack = readStandardPacket(cmd.getInputStream())
                    if (ack.type == PtpPacketType.INIT_COMMAND_ACK && ack.payload.size >= 4) {
                        val connectionNumber = ByteBuffer.wrap(ack.payload, 0, 4)
                            .order(ByteOrder.LITTLE_ENDIAN)
                            .int
                        Log.d(TAG, "INIT ack connectionNumber=$connectionNumber variant=${variant.label}")
                        cmd.soTimeout = commandReadTimeoutMs
                        lastError = null
                        break
                    } else {
                        throw IllegalStateException("PTP INIT failed: packetType=0x${ack.type.toString(16)}")
                    }
                } catch (error: Throwable) {
                    if (error is CancellationException) throw error
                    lastError = error
                    Log.w(TAG, "PTP INIT variant failed: ${variant.label}: $error")
                    runCatching { cmd.close() }
                    if (cmdSocket === cmd) cmdSocket = null
                }
            }
            if (lastError != null || cmdSocket == null) {
                throw lastError ?: IllegalStateException("PTP INIT failed")
            }
        }

        sendCommand(PtpOpCode.OPEN_SESSION, listOf(1))
        if (confirmGalleryMode) {
            confirmCameraVendorGalleryMode()
        }
        sessionOpen = true
    }

    suspend fun confirmCameraVendorGalleryMode() {
        performOfficialImageViewModeSetup()
        sessionOpen = true
    }

    suspend fun sendCommand(opCode: Int, params: List<Int> = emptyList()): PtpOperationResponse {
        val socket = cmdSocket ?: throw IllegalStateException("Not connected to camera")
        return commandMutex.withLock {
            withContext(Dispatchers.IO) {
                val tid = nextTransactionId
                val packet = PtpPacketBuilder.buildCameraVendorLegacyOperationRequest(opCode, tid, params)
                socket.getOutputStream().write(packet)
                socket.getOutputStream().flush()
                readOperationResponse(socket.getInputStream(), opCode)
            }
        }
    }

    suspend fun sendCommandWithData(
        opCode: Int,
        params: List<Int> = emptyList(),
        data: ByteArray,
    ): PtpOperationResponse {
        val socket = cmdSocket ?: throw IllegalStateException("Not connected to camera")
        return commandMutex.withLock {
            withContext(Dispatchers.IO) {
                val tid = nextTransactionId
                socket.getOutputStream().write(
                    PtpPacketBuilder.buildCameraVendorLegacyOperationRequest(opCode, tid, params)
                )
                socket.getOutputStream().write(
                    PtpPacketBuilder.buildCameraVendorLegacyDataOutRequest(opCode, tid, data)
                )
                socket.getOutputStream().flush()
                readOperationResponse(socket.getInputStream(), opCode)
            }
        }
    }

    suspend fun sendCommandGetData(
        opCode: Int,
        params: List<Int> = emptyList(),
        readTimeoutMs: Int? = null,
    ): ByteArray {
        val socket = cmdSocket ?: throw IllegalStateException("Not connected to camera")
        return commandMutex.withLock {
            withContext(Dispatchers.IO) {
                val originalTimeout = socket.soTimeout
                if (readTimeoutMs != null) socket.soTimeout = readTimeoutMs
                val tid = nextTransactionId
                try {
                    socket.getOutputStream().write(
                        PtpPacketBuilder.buildCameraVendorLegacyOperationRequest(opCode, tid, params)
                    )
                    socket.getOutputStream().flush()
                    readDataPhase(socket.getInputStream(), opCode)
                } finally {
                    if (readTimeoutMs != null) socket.soTimeout = originalTimeout
                }
            }
        }
    }

    fun sendCommandStreamData(opCode: Int, params: List<Int> = emptyList()): Flow<ByteArray> = flow {
        emit(sendCommandGetData(opCode, params))
    }

    suspend fun disconnect() {
        val socket = cmdSocket
        if (sessionOpen && socket != null) {
            runCatching { sendCommand(PtpOpCode.CLOSE_SESSION) }
        }
        sessionOpen = false
        withContext(Dispatchers.IO) {
            runCatching { socket?.close() }
        }
        cmdSocket = null
        transactionId = 0
        specifiedObjectHandles = emptyList()
    }

    private suspend fun performOfficialImageViewModeSetup() {
        readDeviceProperty(CameraVendorDevicePropCode.INIT_SEQUENCE)
        setDevicePropertyUInt16(
            CameraVendorDevicePropCode.INIT_SEQUENCE,
            CameraVendorReferenceApp.REMOTE_IMAGE_VIEWER_CLIENT_STATE,
        )
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST)
        val functionVersion = CameraVendorOfficialGalleryStartupPolicy.functionVersion(
            readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST)
        )
        setDevicePropertyUInt32(
            CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST,
            functionVersion,
        )
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_ACCESS_STATE)
    }

    suspend fun loadCameraVendorGalleryObjectHandles() {
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_ACCESS_STATE)
        runCatching {
            sendCommandGetData(
                PtpOpCode.CAMERA_VENDOR_GET_LATEST_OBJECT_INFO,
                listOf(CameraVendorReferenceApp.CURRENT_IMAGE_HANDLE),
            )
        }.onFailure { Log.d(TAG, "Current image context prime failed: ${it.message}") }
        runCatching {
            sendCommandGetData(
                PtpOpCode.CAMERA_VENDOR_GET_EXTENSION_THUMB,
                listOf(CameraVendorReferenceApp.CURRENT_IMAGE_HANDLE),
            )
        }.onFailure { Log.d(TAG, "Current thumbnail context prime failed: ${it.message}") }
        retrySearchModeDescAll()
        readCurrentObjectHandleSnapshot()
        sendCommandGetData(
            PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            listOf(0, CameraVendorReferenceApp.SPECIFIED_OBJECT_COUNT_LIMIT),
        )
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
        readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_COUNT)
        specifiedObjectHandles = CameraVendorPtpDataParser.uint32Array(
            readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_HANDLES)
        )
        Log.d(TAG, "SpecifiedObjectHandles=${specifiedObjectHandles.size}")
    }

    private suspend fun retrySearchModeDescAll() {
        var lastError: Throwable? = null
        repeat(3) { index ->
            try {
                sendCommandGetData(PtpOpCode.CAMERA_VENDOR_GET_SEARCH_MODE_DESC_ALL)
                return
            } catch (e: Throwable) {
                lastError = e
                if (index == 2 || !e.message.orEmpty().contains("0x2019")) throw e
                delay(500L * (index + 1))
            }
        }
        throw lastError ?: IllegalStateException("SearchModeDescAll failed")
    }

    private suspend fun readCurrentObjectHandleSnapshot() {
        runCatching { readDeviceProperty(CameraVendorDevicePropCode.CURRENT_OBJECT_HANDLE) }
            .onFailure { Log.d(TAG, "Current object handle read failed: ${it.message}") }
    }

    suspend fun readDeviceProperty(code: Int): ByteArray =
        sendCommandGetData(PtpOpCode.GET_DEVICE_PROP_VALUE, listOf(code))

    suspend fun setDevicePropertyUInt16(code: Int, value: Int): PtpOperationResponse =
        sendCommandWithData(PtpOpCode.SET_DEVICE_PROP_VALUE, listOf(code), littleEndianUInt16(value))

    suspend fun setDevicePropertyUInt32(code: Int, value: Int): PtpOperationResponse =
        sendCommandWithData(PtpOpCode.SET_DEVICE_PROP_VALUE, listOf(code), littleEndianUInt32(value))

    private fun readOperationResponse(input: InputStream, opCode: Int): PtpOperationResponse {
        val packet = readLegacyPacket(input)
        if (packet.type != PtpPacketType.OPERATION_RESPONSE) {
            throw IllegalStateException("Expected OperationResponse, got 0x${packet.type.toString(16)}")
        }
        return parseOperationResponse(packet.payload, opCode)
    }

    private fun readDataPhase(input: InputStream, opCode: Int): ByteArray {
        val chunks = mutableListOf<ByteArray>()
        while (true) {
            val packet = readLegacyPacket(input)
            when (packet.type) {
                PtpPacketType.START_DATA_PACKET -> Unit
                PtpPacketType.DATA_PACKET, PtpPacketType.END_DATA_PACKET -> {
                    chunks.add(packet.payload)
                }
                PtpPacketType.OPERATION_RESPONSE -> {
                    parseOperationResponse(packet.payload, opCode)
                    val total = chunks.sumOf { it.size }
                    val data = ByteArray(total)
                    var offset = 0
                    for (chunk in chunks) {
                        chunk.copyInto(data, offset)
                        offset += chunk.size
                    }
                    return data
                }
                else -> throw IllegalStateException("Unexpected packet 0x${packet.type.toString(16)}")
            }
        }
    }

    private fun parseOperationResponse(payload: ByteArray, opCode: Int): PtpOperationResponse {
        if (payload.size < 6) {
            throw IllegalStateException("PTP response too short: ${payload.size}")
        }
        val responseCode = ByteBuffer.wrap(payload, 0, 2)
            .order(ByteOrder.LITTLE_ENDIAN)
            .short.toInt() and 0xFFFF
        val tid = ByteBuffer.wrap(payload, 2, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
        val params = mutableListOf<Int>()
        var offset = 6
        while (offset + 4 <= payload.size) {
            params.add(ByteBuffer.wrap(payload, offset, 4).order(ByteOrder.LITTLE_ENDIAN).int)
            offset += 4
        }
        if (responseCode != PtpResponseCode.OK) {
            throw IllegalStateException(
                "PTP operation 0x${opCode.toString(16)} returned 0x${responseCode.toString(16)}"
            )
        }
        return PtpOperationResponse(responseCode, tid, params)
    }

    private fun readStandardPacket(input: InputStream): PtpPacket {
        val header = input.readExactly(8)
        val length = ByteBuffer.wrap(header, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
        val type = ByteBuffer.wrap(header, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
        require(length >= 8) { "Invalid PTP packet length: $length" }
        val payload = input.readExactly(length - 8)
        return PtpPacket(type, payload)
    }

    private fun readLegacyPacket(input: InputStream): PtpPacket {
        val header = input.readExactly(4)
        val length = ByteBuffer.wrap(header, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
        require(length >= 6) { "Invalid legacy PTP packet length: $length" }
        val rest = input.readExactly(length - 4)
        return CameraVendorLegacyPacketDecoder.decode(header + rest)
    }

    private fun InputStream.readExactly(length: Int): ByteArray {
        val data = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = read(data, offset, length - offset)
            if (read < 0) throw EOFException("Socket closed after $offset/$length bytes")
            offset += read
        }
        return data
    }

    private fun littleEndianUInt16(value: Int): ByteArray =
        ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(value.toShort()).array()

    private fun littleEndianUInt32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()
}

internal object PtpConnectionSocketPolicy {
    fun createSocket(socketFactory: SocketFactory?): Socket =
        socketFactory?.createSocket() ?: Socket()
}
