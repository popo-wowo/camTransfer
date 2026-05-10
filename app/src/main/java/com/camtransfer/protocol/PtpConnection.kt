package com.camtransfer.protocol

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random

class PtpConnection {
    private var cmdSocket: Socket? = null
    private var evtSocket: Socket? = null
    private var connectionNumber = 0
    private var transactionId = 0
    private var sessionOpen = false
    private val cmdBuffer = PtpBuffer()
    private val evtBuffer = PtpBuffer()
    private var cmdJob: Job? = null
    private var evtJob: Job? = null

    private val _cmdPackets = MutableSharedFlow<PtpPacket>(extraBufferCapacity = 64)
    private val _evtPackets = MutableSharedFlow<PtpPacket>(extraBufferCapacity = 64)
    private val _events = MutableSharedFlow<PtpPacket>(extraBufferCapacity = 16)

    val isConnected: Boolean get() = sessionOpen
    val events: SharedFlow<PtpPacket> get() = _events

    val nextTransactionId: Int get() = ++transactionId

    suspend fun connect(host: String = CameraVendorConst.DEFAULT_CAMERA_IP) {
        disconnect()
        transactionId = 0

        withContext(Dispatchers.IO) {
            val cmd = Socket()
            cmd.tcpNoDelay = true
            cmd.connect(InetSocketAddress(host, CameraVendorConst.COMMAND_PORT), 10_000)
            cmdSocket = cmd

            cmdJob = CoroutineScope(Dispatchers.IO).launch {
                readLoop(cmd.getInputStream(), cmdBuffer, _cmdPackets)
            }

            val guid = Random.nextBytes(16)
            val initCmd = PtpPacketBuilder.buildInitCommandRequest(guid, "CamTransfer")
            cmd.getOutputStream().write(initCmd)
            cmd.getOutputStream().flush()

            val ack = waitForPacketFrom(_cmdPackets, PtpPacketType.INIT_COMMAND_ACK)
            if (ack.payload.size >= 4) {
                connectionNumber = ByteBuffer.wrap(ack.payload, 0, 4)
                    .order(ByteOrder.LITTLE_ENDIAN).getInt()
            }

            val evt = Socket()
            evt.tcpNoDelay = true
            evt.connect(InetSocketAddress(host, CameraVendorConst.EVENT_PORT), 10_000)
            evtSocket = evt

            evtJob = CoroutineScope(Dispatchers.IO).launch {
                readLoop(evt.getInputStream(), evtBuffer, _evtPackets)
            }

            val initEvt = PtpPacketBuilder.buildInitEventRequest(connectionNumber)
            evt.getOutputStream().write(initEvt)
            evt.getOutputStream().flush()

            waitForPacketFrom(_evtPackets, PtpPacketType.INIT_EVENT_ACK)
        }

        openSession()
        sessionOpen = true
    }

    private suspend fun openSession() {
        val tid = nextTransactionId
        val packet = PtpPacketBuilder.buildOperationRequest(PtpOpCode.OPEN_SESSION, tid, listOf(1))
        withContext(Dispatchers.IO) {
            cmdSocket!!.getOutputStream().write(packet)
            cmdSocket!!.getOutputStream().flush()
        }
        waitForResponse()
    }

    suspend fun sendCommand(opCode: Int, params: List<Int> = emptyList()): PtpPacket {
        ensureConnected()
        val tid = nextTransactionId
        val packet = PtpPacketBuilder.buildOperationRequest(opCode, tid, params)
        withContext(Dispatchers.IO) {
            cmdSocket!!.getOutputStream().write(packet)
            cmdSocket!!.getOutputStream().flush()
        }
        return waitForResponse()
    }

    suspend fun sendCommandGetData(opCode: Int, params: List<Int> = emptyList()): ByteArray {
        ensureConnected()
        val tid = nextTransactionId
        val packet = PtpPacketBuilder.buildOperationRequest(opCode, tid, params)
        withContext(Dispatchers.IO) {
            cmdSocket!!.getOutputStream().write(packet)
            cmdSocket!!.getOutputStream().flush()
        }
        return receiveDataPhase()
    }

    fun sendCommandStreamData(opCode: Int, params: List<Int> = emptyList()): Flow<ByteArray> = flow {
        ensureConnected()
        val tid = nextTransactionId
        val packet = PtpPacketBuilder.buildOperationRequest(opCode, tid, params)
        withContext(Dispatchers.IO) {
            cmdSocket!!.getOutputStream().write(packet)
            cmdSocket!!.getOutputStream().flush()
        }
        emitAll(receiveDataPhaseStream())
    }

    private suspend fun receiveDataPhase(): ByteArray {
        val chunks = mutableListOf<ByteArray>()
        receiveDataPhaseStream().collect { chunks.add(it) }
        val totalLen = chunks.sumOf { it.size }
        val result = ByteArray(totalLen)
        var offset = 0
        for (c in chunks) {
            c.copyInto(result, offset)
            offset += c.size
        }
        return result
    }

    private fun receiveDataPhaseStream(): Flow<ByteArray> = flow {
        var receiving = true
        while (receiving) {
            val pkt = waitForAnyPacket()
            when (pkt.type) {
                PtpPacketType.START_DATA_PACKET -> { /* continue */ }
                PtpPacketType.DATA_PACKET -> {
                    if (pkt.payload.size > 4) emit(pkt.payload.copyOfRange(4, pkt.payload.size))
                }
                PtpPacketType.END_DATA_PACKET -> {
                    if (pkt.payload.size > 4) emit(pkt.payload.copyOfRange(4, pkt.payload.size))
                    receiving = false
                }
                PtpPacketType.OPERATION_RESPONSE -> receiving = false
                else -> receiving = false
            }
        }
    }

    suspend fun disconnect() {
        if (sessionOpen) {
            try {
                val tid = nextTransactionId
                val packet = PtpPacketBuilder.buildOperationRequest(PtpOpCode.CLOSE_SESSION, tid)
                withContext(Dispatchers.IO) {
                    cmdSocket?.getOutputStream()?.write(packet)
                    cmdSocket?.getOutputStream()?.flush()
                }
                delay(200)
            } catch (_: Exception) {}
        }
        sessionOpen = false
        cmdJob?.cancel()
        evtJob?.cancel()
        withContext(Dispatchers.IO) {
            runCatching { cmdSocket?.close() }
            runCatching { evtSocket?.close() }
        }
        cmdSocket = null
        evtSocket = null
        cmdBuffer.clear()
        evtBuffer.clear()
        transactionId = 0
    }

    private fun ensureConnected() {
        if (!sessionOpen || cmdSocket == null) throw IllegalStateException("Not connected to camera")
    }

    private suspend fun readLoop(input: InputStream, buffer: PtpBuffer, flow: MutableSharedFlow<PtpPacket>) {
        val buf = ByteArray(65536)
        try {
            while (currentCoroutineContext().isActive) {
                val n = input.read(buf)
                if (n <= 0) break
                buffer.add(buf.copyOfRange(0, n))
                for (pkt in buffer.drain()) {
                    flow.emit(pkt)
                }
            }
        } catch (_: Exception) {}
    }

    private suspend fun waitForResponse(): PtpPacket {
        return withTimeout(30_000) { _cmdPackets.first() }
    }

    private suspend fun waitForAnyPacket(): PtpPacket {
        return withTimeout(60_000) { _cmdPackets.first() }
    }

    private suspend fun waitForPacketFrom(flow: SharedFlow<PtpPacket>, expectedType: Int): PtpPacket {
        return withTimeout(10_000) {
            flow.first { pkt ->
                if (pkt.type != expectedType) {
                    throw Exception("Expected 0x${expectedType.toString(16)}, got 0x${pkt.type.toString(16)}")
                }
                true
            }
        }
    }
}
