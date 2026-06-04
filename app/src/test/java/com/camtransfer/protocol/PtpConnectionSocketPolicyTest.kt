package com.camtransfer.protocol

import org.junit.Assert.assertSame
import org.junit.Test
import java.net.Socket
import javax.net.SocketFactory

class PtpConnectionSocketPolicyTest {
    @Test
    fun createsSocketFromProvidedNetworkFactoryWhenAvailable() {
        val socket = Socket()
        val factory = RecordingSocketFactory(socket)

        assertSame(socket, PtpConnectionSocketPolicy.createSocket(factory))
    }

    private class RecordingSocketFactory(
        private val socket: Socket,
    ) : SocketFactory() {
        override fun createSocket(): Socket = socket
        override fun createSocket(host: String?, port: Int): Socket = socket
        override fun createSocket(host: String?, port: Int, localHost: java.net.InetAddress?, localPort: Int): Socket = socket
        override fun createSocket(host: java.net.InetAddress?, port: Int): Socket = socket
        override fun createSocket(
            address: java.net.InetAddress?,
            port: Int,
            localAddress: java.net.InetAddress?,
            localPort: Int,
        ): Socket = socket
    }
}
