package com.camtransfer.localproofing

import java.io.ByteArrayOutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean

data class LocalProofingStartedSession(
    val url: String,
    val address: String,
    val port: Int,
    val token: String,
)

class LocalProofingServer(
    private val router: LocalProofingRequestRouter,
    private val token: String,
    private val logger: (String) -> Unit = {},
) {
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    fun start(preferredPort: Int = 8080): LocalProofingStartedSession {
        val interfaces = currentIPv4Interfaces()
        logger("start interfaces=${interfaces.joinToString { "${it.name}:${it.address}" }} preferredPort=$preferredPort")
        val networkInterface = LocalProofingNetworkPolicy.preferredAddress(interfaces)
            ?: throw IllegalStateException("没有检测到可供客户手机访问的 Wi-Fi 地址。请让两台手机连接同一个相机 Wi-Fi 后再打开分享。")
        val address = InetAddress.getByName(networkInterface.address)
        val socket = bindServerSocket(address, preferredPort)
        serverSocket = socket
        running.set(true)
        acceptThread = Thread({ acceptLoop(socket) }, "camtransfer-local-proofing").apply {
            isDaemon = true
            start()
        }
        val session = LocalProofingStartedSession(
            url = LocalProofingNetworkPolicy.shareUrl(networkInterface.address, socket.localPort, token),
            address = networkInterface.address,
            port = socket.localPort,
            token = token,
        )
        logger("started address=${session.address} port=${session.port} url=${session.url}")
        return session
    }

    fun stop() {
        logger("stop")
        running.set(false)
        runCatching { serverSocket?.close() }
        serverSocket = null
        acceptThread = null
    }

    private fun bindServerSocket(address: InetAddress, preferredPort: Int): ServerSocket =
        runCatching {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(address, preferredPort))
            }
        }.getOrElse {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(address, 0))
            }
        }

    private fun acceptLoop(socket: ServerSocket) {
        while (running.get()) {
            val client = try {
                socket.accept()
            } catch (_: SocketException) {
                break
            } catch (_: Exception) {
                continue
            }
            Thread({ handleClient(client) }, "camtransfer-local-proofing-client").apply {
                isDaemon = true
                start()
            }
        }
    }

    private fun handleClient(socket: Socket) {
        socket.use { client ->
            val remote = client.remoteSocketAddress?.toString().orEmpty()
            val response = runCatching {
                val request = readRequest(client) ?: return@runCatching LocalProofingHttpResponse.badRequest().also {
                    logger("request bad remote=$remote")
                }
                logger("request method=${request.method} path=${request.path} remote=$remote bytes=${request.body.size}")
                router.responseFor(request)
            }.getOrElse { error ->
                logger("request failed remote=$remote error=${error.message}")
                LocalProofingHttpResponse.badRequest()
            }
            logger("response status=${response.statusCode} type=${response.contentType} bodyBytes=${response.body.size} remote=$remote")
            client.getOutputStream().use { output ->
                output.write(response.wireBytes)
                output.flush()
            }
        }
    }

    private fun readRequest(socket: Socket): LocalProofingHttpRequest? {
        socket.soTimeout = 4_000
        val input = socket.getInputStream()
        val buffer = ByteArray(4096)
        val data = ByteArrayOutputStream()
        while (data.size() <= MAX_REQUEST_BYTES) {
            val read = input.read(buffer)
            if (read <= 0) break
            data.write(buffer, 0, read)
            val bytes = data.toByteArray()
            val headerEnd = headerEndIndex(bytes)
            if (headerEnd >= 0) {
                val headerText = bytes.copyOfRange(0, headerEnd).toString(Charsets.UTF_8)
                val contentLength = contentLength(headerText)
                val bodyStart = headerEnd + 4
                if (bytes.size >= bodyStart + contentLength) {
                    return parseRequest(bytes.copyOfRange(0, bodyStart + contentLength))
                }
            }
        }
        return null
    }

    private fun parseRequest(bytes: ByteArray): LocalProofingHttpRequest? {
        val headerEnd = headerEndIndex(bytes)
        if (headerEnd < 0) return null
        val headerText = bytes.copyOfRange(0, headerEnd).toString(Charsets.UTF_8)
        val requestLine = headerText.lineSequence().firstOrNull() ?: return null
        val parts = requestLine.split(" ")
        if (parts.size < 2) return null
        val bodyStart = headerEnd + 4
        return LocalProofingHttpRequest(
            method = parts[0],
            path = parts[1],
            body = bytes.copyOfRange(bodyStart, bytes.size),
        )
    }

    private fun headerEndIndex(bytes: ByteArray): Int {
        for (index in 0..bytes.size - 4) {
            if (
                bytes[index] == '\r'.code.toByte() &&
                bytes[index + 1] == '\n'.code.toByte() &&
                bytes[index + 2] == '\r'.code.toByte() &&
                bytes[index + 3] == '\n'.code.toByte()
            ) {
                return index
            }
        }
        return -1
    }

    private fun contentLength(headerText: String): Int =
        headerText.lineSequence()
            .mapNotNull { line ->
                val parts = line.split(":", limit = 2)
                if (parts.size == 2 && parts[0].equals("Content-Length", ignoreCase = true)) {
                    parts[1].trim().toIntOrNull()
                } else {
                    null
                }
            }
            .firstOrNull() ?: 0

    companion object {
        private const val MAX_REQUEST_BYTES = 1_048_576

        fun currentIPv4Interfaces(): List<LocalProofingNetworkInterface> =
            NetworkInterface.getNetworkInterfaces()
                ?.toList()
                .orEmpty()
                .flatMap { networkInterface ->
                    networkInterface.inetAddresses.toList().mapNotNull { address ->
                        if (address is Inet4Address && !address.isLoopbackAddress) {
                            LocalProofingNetworkInterface(networkInterface.name, address.hostAddress ?: return@mapNotNull null)
                        } else {
                            null
                        }
                    }
                }
    }
}
