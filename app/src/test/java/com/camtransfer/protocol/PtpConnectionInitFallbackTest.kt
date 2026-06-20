package com.camtransfer.protocol

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.net.Socket
import java.net.SocketAddress
import javax.net.SocketFactory

class PtpConnectionInitFallbackTest {
    @Test
    fun connectUsesClientIpInitBeforePlainLegacyFallback() = runBlocking {
        val socket = FakeSocket(ByteArrayInputStream(initAck() + openSessionOk()))
        val factory = QueueSocketFactory(socket)

        PtpConnection().connect(
            host = CameraVendorConst.DEFAULT_CAMERA_IP,
            socketFactory = factory,
            connectTimeoutMs = 10,
            initReadTimeoutMs = 10,
            commandReadTimeoutMs = 10,
            confirmGalleryMode = false,
        )

        assertEquals(1, factory.createdSockets)
        assertArrayEquals(
            byteArrayOf(138.toByte(), 0x00, 168.toByte(), 192.toByte()),
            socket.output.toByteArray().copyOfRange(24, 28),
        )
    }

    @Test
    fun connectFallsBackToPlainLegacyWhenClientIpInitFails() = runBlocking {
        val clientIpSocket = FakeSocket(ByteArrayInputStream(ByteArray(0)), localAddress = "192.168.0.138")
        val plainSocket = FakeSocket(ByteArrayInputStream(initAck() + openSessionOk()), localAddress = "192.168.0.138")
        val factory = QueueSocketFactory(clientIpSocket, plainSocket)

        PtpConnection().connect(
            host = CameraVendorConst.DEFAULT_CAMERA_IP,
            socketFactory = factory,
            connectTimeoutMs = 10,
            initReadTimeoutMs = 10,
            commandReadTimeoutMs = 10,
            confirmGalleryMode = false,
        )

        assertEquals(2, factory.createdSockets)
        assertArrayEquals(
            byteArrayOf(138.toByte(), 0x00, 168.toByte(), 192.toByte()),
            clientIpSocket.output.toByteArray().copyOfRange(24, 28),
        )
        assertArrayEquals(
            byteArrayOf(0x00, 0x00, 0x00, 0x00),
            plainSocket.output.toByteArray().copyOfRange(24, 28),
        )
    }

    private class QueueSocketFactory(private vararg val sockets: FakeSocket) : SocketFactory() {
        var createdSockets: Int = 0
            private set

        override fun createSocket(): Socket = sockets[createdSockets++]
        override fun createSocket(host: String?, port: Int): Socket = createSocket()
        override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket =
            createSocket()

        override fun createSocket(host: InetAddress?, port: Int): Socket = createSocket()
        override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket =
            createSocket()
    }

    private class FakeSocket(
        private val input: InputStream,
        private val localAddress: String = "192.168.0.138",
    ) : Socket() {
        val output = ByteArrayOutputStream()
        var closed: Boolean = false
            private set

        override fun connect(endpoint: SocketAddress?, timeout: Int) = Unit
        override fun getInputStream(): InputStream = input
        override fun getOutputStream(): ByteArrayOutputStream = output
        override fun getLocalAddress(): InetAddress = InetAddress.getByName(localAddress)
        override fun close() {
            closed = true
        }

        override fun setTcpNoDelay(on: Boolean) = Unit
        override fun setReceiveBufferSize(size: Int) = Unit
        override fun setSendBufferSize(size: Int) = Unit
        override fun setSoTimeout(timeout: Int) = Unit
    }

    private fun initAck(): ByteArray =
        byteArrayOf(
            0x0C, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x2A, 0x00, 0x00, 0x00,
        )

    private fun openSessionOk(): ByteArray =
        byteArrayOf(
            0x0C, 0x00, 0x00, 0x00,
            0x03, 0x00,
            0x01, 0x20,
            0x01, 0x00, 0x00, 0x00,
        )
}
