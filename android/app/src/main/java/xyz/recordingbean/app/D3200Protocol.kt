package xyz.recordingbean.app

import java.util.UUID

data class BeanFrame(val type: Int, val command: Int, val status: Int, val payload: ByteArray) {
    val accepted: Boolean get() = status and 15 == 1
}
data class DeviceFile(val id: Long, val durationMs: Long)
data class AudioSlice(val sequence: Long, val encrypted: ByteArray)

object D3200Protocol {
    val service: UUID = UUID.fromString("020cf5da-0000-1000-8000-00805f9b34fb")
    val write: UUID = UUID.fromString("00007777-0000-1000-8000-00805f9b34fb")
    val notify: UUID = UUID.fromString("00008888-0000-1000-8000-00805f9b34fb")
    private val permitted = setOf("1:1", "46:1", "26:14", "26:7", "26:5", "26:2", "26:15", "26:17")
    fun unsigned(b: Byte): Int = b.toInt() and 255
    fun le(value: Long, count: Int = 4): ByteArray = ByteArray(count) { ((value ushr (it * 8)) and 255).toByte() }
    fun u32(bytes: ByteArray, at: Int): Long {
        require(at >= 0 && bytes.size - at >= 4) { "D3200_TRUNCATED_FIELD" }
        return (0..3).fold(0L) { n, i -> n or (unsigned(bytes[at + i]).toLong() shl (i * 8)) }
    }
    fun command(type: Int, id: Int, payload: ByteArray = byteArrayOf()): ByteArray {
        require("$type:$id" in permitted && payload.size <= 1024) { "D3200_COMMAND_NOT_ALLOWED" }
        val bytes = byteArrayOf(8, 238.toByte(), 0, 0, 0, type.toByte(), id.toByte()) + le((payload.size + 10).toLong(), 2) + payload
        return bytes + byteArrayOf((bytes.sumOf { unsigned(it) } and 255).toByte())
    }
    fun files(payload: ByteArray): List<DeviceFile> {
        require(payload.size >= 2) { "D3200_INVALID_LIST" }
        val count = unsigned(payload[0]) + unsigned(payload[1]) * 256
        require(count <= 4096 && payload.size >= 2 + count * 8) { "D3200_TRUNCATED_LIST" }
        return (0 until count).map { DeviceFile(u32(payload, 2 + it * 8), u32(payload, 6 + it * 8)) }
    }
    fun slices(payload: ByteArray): List<AudioSlice> {
        require(payload.isNotEmpty() && payload.size % 166 == 0) { "D3200_SLICE_LAYOUT_UNVERIFIED" }
        return (payload.indices step 166).map { AudioSlice(u32(payload, it), payload.copyOfRange(it + 5, it + 165)) }
    }
    fun counter(nonce: ByteArray, sequence: Long): ByteArray {
        require(nonce.size == 16 && sequence in 0..429_496_729) { "D3200_COUNTER_INVALID" }
        val out = nonce.copyOf()
        val block = sequence * 10
        for (i in 0..3) out[12 + i] = ((block ushr (24 - 8 * i)) and 255).toByte()
        return out
    }
    fun offlineSize(size: Long): Long {
        require(size != 0xffff_ffffL) { "D3200_RECORDING_NOT_FINALIZED" }
        require(size in 1..0xffff_fffeL) { "D3200_FILE_SIZE_INVALID" }
        return size
    }
    fun serial(payload: ByteArray): String {
        require(payload.size >= 24) { "D3200_STABLE_ID_UNAVAILABLE" }
        val value = payload.copyOfRange(8, 24).toString(Charsets.US_ASCII).trimEnd('\u0000', ' ').lowercase()
        require(value.length in 8..16 && value.all { it in 'a'..'z' || it in '0'..'9' }
                && value.toSet().size > 1 && value !in setOf("unknown", "undefined", "default", "12345678", "1234567890123456")) {
            "D3200_STABLE_ID_UNAVAILABLE"
        }
        return value
    }
    fun battery(raw: Int?): Int? = raw?.takeIf { it in 0..100 }?.let { if (it <= 9) (it + 1) * 10 else it }
    fun recordingState(payload: ByteArray): Int = if (payload.size >= 51 && unsigned(payload[50]) <= 1) unsigned(payload[50]) else -1
    fun oggPage(packet: ByteArray, sequence: Long, granule: Long, flags: Int): ByteArray {
        val segments = packet.size / 255 + 1
        require(segments <= 255) { "OGG_PACKET_TOO_LARGE" }
        val out = ByteArray(27 + segments + packet.size)
        byteArrayOf(79, 103, 103, 83, 0, flags.toByte()).copyInto(out)
        for (i in 0..7) out[6 + i] = ((granule ushr (i * 8)) and 255).toByte()
        le(0x4245414e).copyInto(out, 14)
        le(sequence).copyInto(out, 18)
        out[26] = segments.toByte()
        for (i in 0 until segments) out[27 + i] = minOf(255, packet.size - 255 * i).toByte()
        packet.copyInto(out, 27 + segments)
        var crc = 0
        out.forEach { byte ->
            crc = crc xor (unsigned(byte) shl 24)
            repeat(8) { crc = if (crc < 0) (crc shl 1) xor 0x04c11db7 else crc shl 1 }
        }
        le(crc.toLong()).copyInto(out, 22)
        return out
    }
    fun opusHeaders(preSkip: Int = 312): ByteArray {
        val head = byteArrayOf(79,112,117,115,72,101,97,100,1,2,56,1,-128,62,0,0,0,0,0)
        head[10] = (preSkip and 255).toByte(); head[11] = (preSkip ushr 8).toByte()
        val tags = byteArrayOf(79,112,117,115,84,97,103,115,4,0,0,0,66,101,97,110,0,0,0,0)
        return oggPage(head, 0, 0, 2) + oggPage(tags, 1, 0, 0)
    }
    /** A standalone draft window, not proof that the device recording finished. */
    fun liveWindow(packets: List<ByteArray>): ByteArray {
        require(packets.size in 1..1000 && packets.all { it.size == 160 }) { "LIVE_WINDOW_INVALID" }
        val pieces = ArrayList<ByteArray>(packets.size + 1)
        pieces.add(opusHeaders(0))
        packets.forEachIndexed { index, packet ->
            pieces.add(oggPage(packet, index.toLong() + 2, (index.toLong() + 1) * 960,
                if (index == packets.lastIndex) 4 else 0))
        }
        val result = ByteArray(pieces.sumOf { it.size })
        var offset = 0
        pieces.forEach { it.copyInto(result, offset); offset += it.size }
        return result
    }
}

class BeanFrameDecoder {
    private var pending = byteArrayOf()
    fun push(input: ByteArray): List<BeanFrame> {
        require(pending.size + input.size <= 131072) { "D3200_RX_OVERFLOW" }
        pending += input
        val output = mutableListOf<BeanFrame>()
        while (pending.size >= 10) {
            if (D3200Protocol.unsigned(pending[0]) != 9 || D3200Protocol.unsigned(pending[1]) != 255 ||
                pending[2].toInt() != 0 || pending[3].toInt() != 0) { pending = pending.copyOfRange(1, pending.size); continue }
            val size = D3200Protocol.unsigned(pending[7]) + D3200Protocol.unsigned(pending[8]) * 256
            require(size in 10..65535) { "D3200_INVALID_FRAME_SIZE" }
            if (pending.size < size) break
            val frame = pending.copyOfRange(0, size)
            require((frame.dropLast(1).sumOf { D3200Protocol.unsigned(it) } and 255) == D3200Protocol.unsigned(frame.last())) { "D3200_CHECKSUM_MISMATCH" }
            output += BeanFrame(D3200Protocol.unsigned(frame[5]), D3200Protocol.unsigned(frame[6]), D3200Protocol.unsigned(frame[4]), frame.copyOfRange(9, size - 1))
            pending = pending.copyOfRange(size, pending.size)
        }
        return output
    }
}
