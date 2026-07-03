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
    private var specifiedObjectCount: Int? = null
    private var specifiedObjectCountsByDate: List<CameraVendorObjectCountByDate> = emptyList()
    private var specifiedObjectHandlesByFormatMask: Map<Int, List<Int>> = emptyMap()

    val isConnected: Boolean get() = sessionOpen
    val cameraVendorSpecifiedObjectHandles: List<Int> get() = specifiedObjectHandles
    val cameraVendorSpecifiedObjectCount: Int? get() = specifiedObjectCount
    val cameraVendorSpecifiedObjectCountsByDate: List<CameraVendorObjectCountByDate> get() = specifiedObjectCountsByDate
    val cameraVendorSpecifiedObjectHandlesByFormatMask: Map<Int, List<Int>> get() = specifiedObjectHandlesByFormatMask
    val nextTransactionId: Int get() = ++transactionId

    suspend fun connect(
        host: String = CameraVendorConst.DEFAULT_CAMERA_IP,
        clientName: String = "CamTransfer",
        socketFactory: SocketFactory? = null,
        connectTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.OPEN_ATTEMPT_TIMEOUT_MS.toInt(),
        initReadTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.INIT_ACK_READ_TIMEOUT_MS.toInt(),
        commandReadTimeoutMs: Int = CameraVendorPtpConnectionStartupPolicy.COMMAND_READ_TIMEOUT_MS.toInt(),
        confirmGalleryMode: Boolean = true,
        onInitPacket: (label: String, socketLocalIp: String?, clientIp: String?, packet: ByteArray) -> Unit = { _, _, _, _ -> },
    ) {
        disconnect()
        transactionId = 0
        specifiedObjectHandles = emptyList()
        specifiedObjectCount = null
        specifiedObjectCountsByDate = emptyList()
        specifiedObjectHandlesByFormatMask = emptyMap()

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
                    onInitPacket(variant.label, socketLocalIp, initClientIp, initPacket)
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
                val traceLabel = legacyPacketTraceLabel(opCode, params)
                try {
                    if (traceLabel != null) {
                        Log.d(
                            TAG,
                            "Legacy command start label=$traceLabel op=0x${opCode.toString(16)} " +
                                "tid=$tid timeoutMs=${readTimeoutMs ?: originalTimeout} params=$params",
                        )
                    }
                    socket.getOutputStream().write(
                        PtpPacketBuilder.buildCameraVendorLegacyOperationRequest(opCode, tid, params)
                    )
                    socket.getOutputStream().flush()
                    readDataPhase(socket.getInputStream(), opCode, traceLabel)
                } catch (error: Throwable) {
                    if (traceLabel != null) {
                        Log.d(
                            TAG,
                            "Legacy command failed label=$traceLabel op=0x${opCode.toString(16)} " +
                                "tid=$tid timeoutMs=${readTimeoutMs ?: originalTimeout} error=${error.message}",
                        )
                    }
                    throw error
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
        specifiedObjectCount = null
        specifiedObjectCountsByDate = emptyList()
        specifiedObjectHandlesByFormatMask = emptyMap()
    }

    private suspend fun performOfficialImageViewModeSetup() {
        readDevicePropertyForDiagnostic(
            label = "Gallery setup D212 before DF01 set",
            code = CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT,
        )
        readDevicePropertyForDiagnostic(
            label = "Gallery setup DF01 current client state",
            code = CameraVendorDevicePropCode.INIT_SEQUENCE,
        )
        Log.d(
            TAG,
            "Gallery setup DF01 writing official function mode " +
                "value=${CameraVendorReferenceApp.REMOTE_IMAGE_VIEWER_CLIENT_STATE} width=uint16",
        )
        setDevicePropertyUInt16(
            CameraVendorDevicePropCode.INIT_SEQUENCE,
            CameraVendorReferenceApp.REMOTE_IMAGE_VIEWER_CLIENT_STATE,
        )
        val firstFunctionVersionData = readDevicePropertyForDiagnostic(
            label = "Gallery setup DF28 first function version read",
            code = CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST,
        )
        val firstFunctionVersion = CameraVendorOfficialGalleryStartupPolicy.functionVersion(firstFunctionVersionData)
        val secondFunctionVersionData = readDevicePropertyForDiagnostic(
            label = "Gallery setup DF28 second function version read",
            code = CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST,
        )
        val functionVersion = CameraVendorOfficialGalleryStartupPolicy.functionVersion(secondFunctionVersionData)
        val officialFunctionVersion = CameraVendorOfficialGalleryStartupPolicy.REMOTE_PHOTO_VIEW_EX_FUNCTION_VERSION
        Log.d(
            TAG,
            "Gallery setup DF28 writing official function version " +
                "first=$firstFunctionVersion second=$functionVersion write=$officialFunctionVersion",
        )
        setDevicePropertyUInt32(
            CameraVendorDevicePropCode.REFERENCE_APP_IMAGE_HOST,
            officialFunctionVersion,
        )
        readDevicePropertyForDiagnostic(
            label = "Gallery setup D244 after DF28 set",
            code = CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_ACCESS_STATE,
        )
    }

    suspend fun loadCameraVendorGalleryObjectHandles() {
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_ACCESS_STATE)
        resetOfficialCompressionModeForGalleryStartup()
        retrySearchModeDescAll()
        readCurrentObjectHandleSnapshot()
        val objectCountGroupData = sendCommandGetData(
            PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            listOf(0, CameraVendorReferenceApp.SPECIFIED_OBJECT_COUNT_LIMIT),
        )
        specifiedObjectCountsByDate = CameraVendorPtpDataParser.objectCountsByDate(objectCountGroupData)
        Log.d(
            TAG,
            "SpecifiedObjectCountsByDate " +
                CameraVendorGalleryDiagnosticPolicy.dateGroupSummary(specifiedObjectCountsByDate) + " " +
                "bytes=${objectCountGroupData.size} head=${objectCountGroupData.headHex()}",
        )
        readDeviceProperty(CameraVendorDevicePropCode.REFERENCE_APP_GALLERY_OBJECT_CONTEXT)
        val specifiedObjectCountData = readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_COUNT)
        specifiedObjectCount = specifiedObjectCountData.uint32OrNull()
        Log.d(
            TAG,
            "SpecifiedObjectCount expected=${specifiedObjectCount ?: "unknown"} " +
                "bytes=${specifiedObjectCountData.size} head=${specifiedObjectCountData.headHex()}",
        )
        val specifiedObjectHandlesData = readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_HANDLES)
        specifiedObjectHandles = CameraVendorPtpDataParser.uint32Array(
            specifiedObjectHandlesData
        )
        Log.d(
            TAG,
            "SpecifiedObjectHandles " +
                CameraVendorGalleryDiagnosticPolicy.handleSummary(
                    handles = specifiedObjectHandles,
                    expectedCount = specifiedObjectCount,
                ) + " bytes=${specifiedObjectHandlesData.size} head=${specifiedObjectHandlesData.headHex()}",
        )
        specifiedObjectHandlesByFormatMask = specifiedObjectHandlesByFormatMask +
            (CameraVendorOfficialGalleryStartupPolicy.initialObjectFormatMask() to specifiedObjectHandles)
        readExpandedStillSpecifiedHandlesForOfficialStartup()
    }

    private suspend fun retrySearchModeDescAll() {
        var lastError: Throwable? = null
        repeat(3) { index ->
            try {
                val data = sendCommandGetData(PtpOpCode.CAMERA_VENDOR_GET_SEARCH_MODE_DESC_ALL)
                Log.d(
                    TAG,
                    "SearchModeDescAll bytes=${data.size} head=${data.headHex()} " +
                        "snapshot=${CameraVendorPtpDataParser.searchModeSnapshot(data)}",
                )
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

    private suspend fun readDevicePropertyForDiagnostic(label: String, code: Int): ByteArray {
        val data = readDeviceProperty(code)
        Log.d(
            TAG,
            "$label prop=0x${code.toString(16)} bytes=${data.size} head=${data.headHex()}",
        )
        return data
    }

    private suspend fun resetOfficialCompressionModeForGalleryStartup() {
        runCatching {
            setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_FORCE_COMPRESSION, 0)
        }.onSuccess {
            Log.d(TAG, "Gallery setup D226 compression reset response=0x${it.responseCode.toString(16)}")
        }.onFailure {
            Log.d(TAG, "Gallery setup D226 compression reset failed: ${it.message}")
        }
        runCatching {
            setDevicePropertyUInt16(CameraVendorDevicePropCode.IMAGE_COMPRESSION_REAL_INFO, 0)
        }.onSuccess {
            Log.d(TAG, "Gallery setup D227 compression reset response=0x${it.responseCode.toString(16)}")
        }.onFailure {
            Log.d(TAG, "Gallery setup D227 compression reset failed: ${it.message}")
        }
    }

    private suspend fun readExpandedStillSpecifiedHandlesForOfficialStartup() {
        for (mask in CameraVendorOfficialGalleryStartupPolicy.expandedStillFormatMasks()) {
            val label = when (mask) {
                CameraVendorSearchMode.FORMAT_HEIF -> "HEIF"
                CameraVendorSearchMode.FORMAT_RAW -> "RAW"
                else -> "0x${mask.toString(16)}"
            }
            runCatching {
                val snapshot = readSpecifiedHandlesForFormatMask(label, mask)
                if (
                    snapshot.handles.size > specifiedObjectHandles.size &&
                    snapshot.groups.sumOf { it.numberOfImages } == snapshot.handles.size
                ) {
                    val previousCount = specifiedObjectHandles.size
                    specifiedObjectHandles = snapshot.handles
                    specifiedObjectCount = snapshot.count
                    specifiedObjectCountsByDate = snapshot.groups
                    Log.d(
                        TAG,
                        "FormatSpecifiedHandles $label promotedToInitial " +
                            "count=${snapshot.handles.size} previous=$previousCount",
                    )
                    return
                }
            }.onFailure {
                Log.d(TAG, "FormatSpecifiedHandles $label failed: ${it.message}")
            }
        }
    }

    private suspend fun readSpecifiedHandlesForFormatMask(label: String, mask: Int): SpecifiedHandleSnapshot {
        val payload = CameraVendorPtpDataParser.officialObjectFormatSearchModeAllPayload(mask)
        val response = sendCommandWithData(PtpOpCode.CAMERA_VENDOR_SET_SEARCH_MODE_ALL, data = payload)
        Log.d(
            TAG,
            "FormatSpecifiedHandles $label setSearchMode response=0x${response.responseCode.toString(16)} " +
                "mask=$mask payload=${payload.headHex()}",
        )
        val groupsData = sendCommandGetData(
            PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE,
            listOf(0, CameraVendorReferenceApp.SPECIFIED_OBJECT_COUNT_LIMIT),
        )
        val groups = CameraVendorPtpDataParser.objectCountsByDate(groupsData)
        val countData = readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_COUNT)
        val count = countData.uint32OrNull()
        val handlesData = readDeviceProperty(CameraVendorDevicePropCode.SPECIFIED_OBJECT_HANDLES)
        val handles = CameraVendorPtpDataParser.uint32Array(handlesData)
        specifiedObjectHandlesByFormatMask = specifiedObjectHandlesByFormatMask + (mask to handles)
        Log.d(
            TAG,
            "FormatSpecifiedHandles $label " +
                "${CameraVendorGalleryDiagnosticPolicy.dateGroupSummary(groups)} " +
                CameraVendorGalleryDiagnosticPolicy.handleSummary(
                    handles = handles,
                    expectedCount = count,
                ) + " countHead=${countData.headHex()} handlesHead=${handlesData.headHex()}",
        )
        return SpecifiedHandleSnapshot(
            groups = groups,
            count = count,
            handles = handles,
        )
    }

    private data class SpecifiedHandleSnapshot(
        val groups: List<CameraVendorObjectCountByDate>,
        val count: Int?,
        val handles: List<Int>,
    )

    suspend fun readDeviceProperty(code: Int, readTimeoutMs: Int? = null): ByteArray =
        sendCommandGetData(PtpOpCode.GET_DEVICE_PROP_VALUE, listOf(code), readTimeoutMs)

    private suspend fun readDevicePropertyForDiagnosticIfAvailable(label: String, code: Int): ByteArray? =
        runCatching { readDevicePropertyForDiagnostic(label, code) }
            .onFailure { Log.d(TAG, "$label prop=0x${code.toString(16)} read failed: ${it.message}") }
            .getOrNull()

    suspend fun setDevicePropertyUInt16(code: Int, value: Int): PtpOperationResponse =
        sendCommandWithData(PtpOpCode.SET_DEVICE_PROP_VALUE, listOf(code), littleEndianUInt16(value))

    suspend fun setDevicePropertyUInt32(code: Int, value: Int): PtpOperationResponse =
        sendCommandWithData(PtpOpCode.SET_DEVICE_PROP_VALUE, listOf(code), littleEndianUInt32(value))

    private fun readOperationResponse(input: InputStream, opCode: Int): PtpOperationResponse {
        val packet = readLegacyPacket(input, traceLabel = null, packetIndex = 0, opCode = opCode)
        if (packet.type != PtpPacketType.OPERATION_RESPONSE) {
            throw IllegalStateException("Expected OperationResponse, got 0x${packet.type.toString(16)}")
        }
        return parseOperationResponse(packet.payload, opCode)
    }

    private fun readDataPhase(input: InputStream, opCode: Int, traceLabel: String?): ByteArray {
        val chunks = mutableListOf<ByteArray>()
        var packetIndex = 0
        while (true) {
            val packet = readLegacyPacket(input, traceLabel, packetIndex++, opCode)
            when (packet.type) {
                PtpPacketType.START_DATA_PACKET -> {
                    if (traceLabel != null) {
                        Log.d(TAG, "Legacy packet decoded label=$traceLabel index=${packetIndex - 1} type=start")
                    }
                }
                PtpPacketType.DATA_PACKET, PtpPacketType.END_DATA_PACKET -> {
                    val normalizedPayload = CameraVendorLegacyPacketNormalizer.normalizeDataPayload(
                        opCode = opCode,
                        packetIndex = packetIndex - 1,
                        payload = packet.payload,
                    )
                    chunks.add(normalizedPayload)
                    if (traceLabel != null) {
                        Log.d(
                            TAG,
                            "Legacy packet decoded label=$traceLabel index=${packetIndex - 1} " +
                                "type=${if (packet.type == PtpPacketType.DATA_PACKET) "data" else "end"} " +
                                "payloadBytes=${packet.payload.size} normalizedBytes=${normalizedPayload.size} " +
                                "head=${normalizedPayload.headHex(48)}",
                        )
                    }
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
                    if (traceLabel != null) {
                        Log.d(
                            TAG,
                            "Legacy command complete label=$traceLabel packets=$packetIndex dataBytes=${data.size} " +
                                "head=${data.headHex(64)}",
                        )
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

    private fun readLegacyPacket(input: InputStream, traceLabel: String?, packetIndex: Int, opCode: Int): PtpPacket {
        val header = try {
            input.readExactly(4)
        } catch (error: Throwable) {
            if (traceLabel != null) {
                Log.d(TAG, "Legacy packet read failed label=$traceLabel index=$packetIndex stage=header error=${error.message}")
            }
            throw error
        }
        val length = ByteBuffer.wrap(header, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
        if (traceLabel != null) {
            Log.d(
                TAG,
                "Legacy packet header label=$traceLabel index=$packetIndex length=$length raw=${header.headHex(8)}",
            )
        }
        require(length >= 6) { "Invalid legacy PTP packet length: $length" }
        val remainingLength = length - 4
        val rest = try {
            input.readExactly(remainingLength)
        } catch (error: Throwable) {
            if (traceLabel != null) {
                Log.d(
                    TAG,
                    "Legacy packet read failed label=$traceLabel index=$packetIndex stage=body " +
                        "length=$length remaining=$remainingLength error=${error.message}",
                )
            }
            throw error
        }
        val raw = header + rest
        if (traceLabel != null) {
            val kind = ByteBuffer.wrap(raw, 4, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
            Log.d(
                TAG,
                "Legacy packet raw label=$traceLabel index=$packetIndex length=$length kind=0x${kind.toString(16)} " +
                    "head=${raw.headHex(64)}",
            )
        }
        val packet = CameraVendorLegacyPacketDecoder.decode(raw)
        if (packet.type == PtpPacketType.DATA_PACKET) {
            val additionalTailBytes = CameraVendorLegacyPacketNormalizer.additionalTailBytesForDataPayload(
                opCode = opCode,
                packetIndex = packetIndex,
                payload = packet.payload,
            )
            if (additionalTailBytes > 0) {
                val tail = try {
                    input.readExactly(additionalTailBytes)
                } catch (error: Throwable) {
                    if (traceLabel != null) {
                        Log.d(
                            TAG,
                            "Legacy packet read failed label=$traceLabel index=$packetIndex stage=tail " +
                                "length=$length remaining=$additionalTailBytes error=${error.message}",
                        )
                    }
                    throw error
                }
                if (traceLabel != null) {
                    Log.d(
                        TAG,
                        "Legacy packet tail label=$traceLabel index=$packetIndex bytes=$additionalTailBytes " +
                            "head=${tail.headHex(32)}",
                    )
                }
                return PtpPacket(packet.type, packet.payload + tail)
            }
        }
        return packet
    }

    private fun legacyPacketTraceLabel(opCode: Int, params: List<Int>): String? =
        when {
            opCode == PtpOpCode.CAMERA_VENDOR_GET_LATEST_OBJECT_INFO -> "9054-current-image-info"
            opCode == PtpOpCode.CAMERA_VENDOR_GET_EXTENSION_THUMB -> "9055-current-thumb"
            opCode == PtpOpCode.CAMERA_VENDOR_GET_SEARCH_MODE_DESC_ALL -> "9050-search-mode-desc-all"
            opCode == PtpOpCode.CAMERA_VENDOR_GET_SPECIFIED_OBJECT_COUNT_GROUP_BY_DATE -> "9053-count-group-by-date"
            opCode == PtpOpCode.GET_DEVICE_PROP_VALUE &&
                params.firstOrNull() == CameraVendorDevicePropCode.CURRENT_OBJECT_HANDLE -> "D22B-current-object-handle"
            opCode == PtpOpCode.GET_DEVICE_PROP_VALUE &&
                params.firstOrNull() == CameraVendorDevicePropCode.SPECIFIED_OBJECT_COUNT -> "D620-specified-object-count"
            opCode == PtpOpCode.GET_DEVICE_PROP_VALUE &&
                params.firstOrNull() == CameraVendorDevicePropCode.SPECIFIED_OBJECT_HANDLES -> "D621-specified-object-handles"
            else -> null
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

    private fun ByteArray.headHex(byteCount: Int = 96): String =
        take(byteCount).joinToString("") { "%02x".format(it) }

    private fun ByteArray.uint32OrNull(): Int? =
        if (size >= 4) ByteBuffer.wrap(this, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int else null
}

internal object CameraVendorGalleryDiagnosticPolicy {
    fun dateGroupSummary(groups: List<CameraVendorObjectCountByDate>): String {
        val total = groups.sumOf { it.numberOfImages }
        val summary = groups.take(12).joinToString { "${it.dateValue}:${it.numberOfImages}" }
        return "groups=${groups.size} total=$total summary=$summary"
    }

    fun handleSummary(handles: List<Int>, expectedCount: Int?): String {
        if (handles.isEmpty()) {
            return "count=0 expected=${expectedCount ?: "unknown"}"
        }
        val sorted = handles.distinct().sorted()
        val smallGaps = smallGapSummary(sorted)
        val mismatch = expectedCount != null && expectedCount != handles.size
        return "count=${handles.size} expected=${expectedCount ?: "unknown"} " +
            "countMismatch=$mismatch min=${sorted.first()} max=${sorted.last()} " +
            "first=${handles.take(16).joinToString(",")} " +
            "last=${handles.takeLast(16).joinToString(",")} " +
            "smallGaps=$smallGaps"
    }

    private fun smallGapSummary(sortedHandles: List<Int>): String {
        if (sortedHandles.size < 2) return "none"
        val gaps = mutableListOf<String>()
        for (index in 0 until sortedHandles.lastIndex) {
            val lower = sortedHandles[index]
            val upper = sortedHandles[index + 1]
            val missing = upper - lower - 1
            if (missing in 1..20) {
                gaps += "$lower-$upper:$missing"
                if (gaps.size >= 12) break
            }
        }
        return gaps.joinToString().ifBlank { "none" }
    }
}

internal object PtpConnectionSocketPolicy {
    fun createSocket(socketFactory: SocketFactory?): Socket =
        socketFactory?.createSocket() ?: Socket()
}
