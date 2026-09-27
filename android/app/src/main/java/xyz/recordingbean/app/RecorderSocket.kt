package xyz.recordingbean.app

import android.net.Network
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Base64
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** Device-local WSS: fixed private endpoint and exact DER leaf pin. Never use for cloud HTTPS. */
class RecorderSocket(private val network: Network) : AutoCloseable {
    companion object {
        const val HOST = "192.168.43.1"
        const val PORT = 443
        private const val PIN = "3f2667135cafff135614944392d6b3bc0e991b2ca55dbe9e469caca44d5a0125"
        fun endpoint(payload: ByteArray): Pair<String, Int> {
            require(payload.size >= 6) { "D3200_WIFI_ENDPOINT_INVALID" }
            val host = (3 downTo 0).joinToString(".") { D3200Protocol.unsigned(payload[it]).toString() }
            val port = D3200Protocol.unsigned(payload[4]) + D3200Protocol.unsigned(payload[5]) * 256
            require(host == HOST && port == PORT) { "D3200_PIN_ENDPOINT_NOT_ALLOWED" }
            return host to port
        }
    }
    private val random = SecureRandom()
    private var socket: SSLSocket? = null
    private var input: BufferedInputStream? = null
    private var output: BufferedOutputStream? = null
    private var udp: DatagramSocket? = null
    private var keepAlive: Thread? = null
    @Volatile private var finished = false
    private var fragmentOpcode = 0
    private val fragments = ByteArrayOutputStream()

    fun connect(endpoint: ByteArray) {
        val (host, port) = endpoint(endpoint)
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw CertificateException("client auth disabled")
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw CertificateException("D3200_CERT_MISSING")
                val hash = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                    .joinToString("") { "%02x".format(it.toInt() and 255) }
                if (hash != PIN) throw CertificateException("D3200_CERT_PIN_MISMATCH")
            }
        }
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trust), random)
        val raw = network.socketFactory.createSocket(host, port)
        raw.soTimeout = 15_000
        val tls = try { context.socketFactory.createSocket(raw, host, port, true) as SSLSocket }
            catch (e: Exception) { raw.close(); throw e }
        socket = tls
        try {
            tls.enabledProtocols = arrayOf("TLSv1.2")
            tls.startHandshake()
            input = BufferedInputStream(tls.inputStream)
            output = BufferedOutputStream(tls.outputStream)
            startKeepAlive(host)
            val keyBytes = ByteArray(16).also { random.nextBytes(it) }
            val key = Base64.getEncoder().encodeToString(keyBytes)
            val accept = Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1")
                .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray()))
            val request = "GET / HTTP/1.1\r\nHost: $host:$port\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nAccept-Encoding: gzip\r\nUser-Agent: okhttp/3.12.13.18\r\n\r\n"
            output!!.write(request.toByteArray(Charsets.US_ASCII)); output!!.flush()
            val header = readHeader()
            val lines = header.split("\r\n")
            require(lines.firstOrNull()?.startsWith("HTTP/1.1 101") == true) { "D3200_WS_UPGRADE_STATUS" }
            val fields = mutableMapOf<String, String>()
            lines.drop(1).filter { it.isNotEmpty() }.forEach {
                val pos = it.indexOf(':'); require(pos > 0) { "D3200_WS_HEADER" }
                val name = it.substring(0, pos).lowercase()
                require(name !in fields) { "D3200_WS_DUPLICATE_HEADER" }
                fields[name] = it.substring(pos + 1).trim()
            }
            require(fields["sec-websocket-accept"] == accept && fields["upgrade"]?.lowercase() == "websocket" &&
                    fields["connection"]?.lowercase()?.split(',')?.any { it.trim() == "upgrade" } == true &&
                    fields["sec-websocket-extensions"] == null && fields["sec-websocket-protocol"] == null) { "D3200_WS_UPGRADE_INVALID" }
            tls.soTimeout = 90_000
        } catch (e: Exception) { close(); throw e }
    }

    private fun readHeader(): String {
        val bytes = ArrayList<Byte>()
        while (bytes.size < 16_384) {
            val value = input!!.read()
            if (value < 0) throw EOFException("D3200_WS_HEADER_CLOSED")
            bytes.add(value.toByte())
            if (bytes.size >= 4 && bytes.takeLast(4) == listOf(13.toByte(),10.toByte(),13.toByte(),10.toByte()))
                return bytes.toByteArray().copyOfRange(0, bytes.size - 4).toString(Charsets.US_ASCII)
        }
        error("D3200_WS_HEADERS_TOO_LARGE")
    }

    private fun startKeepAlive(host: String) {
        val address = InetAddress.getByName(host)
        val datagram = DatagramSocket()
        network.bindSocket(datagram)
        udp = datagram
        keepAlive = Thread({
            val bytes = "soundcore-keep-alive-unicast".toByteArray(Charsets.US_ASCII)
            while (!finished) {
                try { datagram.send(DatagramPacket(bytes, bytes.size, address, 32003)); Thread.sleep(1000) }
                catch (_: Exception) { if (!finished) finished = true }
            }
        }, "d3200-keepalive").also { it.isDaemon = true; it.start() }
    }

    fun request(fileId: Long) {
        require(fileId in 0..0xffff_ffffL) { "D3200_INVALID_FILE_ID" }
        val bytes = byteArrayOf(8, -18, 0, 0, 0, 26, 7, 18, 0) + D3200Protocol.le(0) +
            D3200Protocol.le(fileId) + byteArrayOf(27)
        sendText(bytes.joinToString("") { "%02x".format(D3200Protocol.unsigned(it)) })
    }

    fun nextPayload(): ByteArray {
        val stream = input ?: error("D3200_WS_NOT_CONNECTED")
        while (true) {
            val first = stream.read(); val second = stream.read()
            if (first < 0 || second < 0) throw EOFException("D3200_WS_CLOSED")
            val opcode = first and 15
            require(first and 112 == 0 && second and 128 == 0 && opcode in listOf(0,1,2,8,9,10)) { "D3200_WS_FRAME_INVALID" }
            var count = second and 127
            if (count == 126) {
                val high = stream.read(); val low = stream.read()
                if (high < 0 || low < 0) throw EOFException("D3200_WS_CLOSED")
                count = (high shl 8) or low
                require(count >= 126) { "D3200_WS_LENGTH" }
            }
            else if (count == 127) {
                val extended = readExact(stream, 8)
                require(extended.take(4).all { it.toInt() == 0 }) { "D3200_WS_SIZE" }
                count = ((D3200Protocol.unsigned(extended[4]) shl 24) or (D3200Protocol.unsigned(extended[5]) shl 16)
                    or (D3200Protocol.unsigned(extended[6]) shl 8) or D3200Protocol.unsigned(extended[7]))
                require(count >= 65_536) { "D3200_WS_LENGTH" }
            }
            require(count in 0..(4*1024*1024) && (opcode < 8 || ((first and 128 != 0) && count <= 125))) { "D3200_WS_SIZE" }
            val bytes = readExact(stream, count)
            if (opcode == 8) throw EOFException("D3200_WS_CLOSED")
            if (opcode == 9) { sendFrame(10, bytes); continue }
            if (opcode == 10) continue
            if (opcode == 0) require(fragmentOpcode != 0) { "D3200_WS_CONTINUATION" }
            else { require(fragmentOpcode == 0) { "D3200_WS_FRAGMENT_ORDER" }; fragmentOpcode = opcode }
            require(fragments.size() + bytes.size <= 4*1024*1024) { "D3200_WS_SIZE" }
            fragments.write(bytes)
            if (first and 128 == 0) continue
            val assembled = fragments.toByteArray()
            fragments.reset()
            val messageType = fragmentOpcode
            fragmentOpcode = 0
            if (messageType == 2) return assembled
            val text = assembled.toString(Charsets.US_ASCII)
            if (text == "OK" || text == "ACK") continue
            require(text.length % 2 == 0 && text.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) { "D3200_WIFI_MESSAGE_FORMAT" }
            return ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
    }

    private fun readExact(stream: BufferedInputStream, length: Int): ByteArray {
        val bytes = ByteArray(length)
        var position = 0
        while (position < length) {
            val count = stream.read(bytes, position, length - position)
            if (count < 0) throw EOFException("D3200_WS_CLOSED")
            position += count
        }
        return bytes
    }

    private fun sendText(text: String) = sendFrame(1, text.toByteArray(Charsets.US_ASCII))
    private fun sendFrame(opcode: Int, bytes: ByteArray) {
        val stream = output ?: error("D3200_WS_NOT_CONNECTED")
        require(bytes.size <= 65_535 && (opcode < 8 || bytes.size <= 125)) { "D3200_WS_CLIENT_SIZE" }
        val mask = ByteArray(4).also { random.nextBytes(it) }
        synchronized(stream) {
            stream.write(128 or opcode)
            if (bytes.size < 126) stream.write(128 or bytes.size)
            else { stream.write(254); stream.write(bytes.size ushr 8); stream.write(bytes.size and 255) }
            stream.write(mask)
            bytes.forEachIndexed { i, byte -> stream.write(D3200Protocol.unsigned(byte) xor D3200Protocol.unsigned(mask[i % 4])) }
            stream.flush()
        }
    }

    override fun close() {
        if (!finished) runCatching { sendText("FINISH") }
        finished = true
        udp?.close(); udp = null
        socket?.close(); socket = null
        input = null; output = null
        keepAlive?.interrupt(); keepAlive = null
    }
}
