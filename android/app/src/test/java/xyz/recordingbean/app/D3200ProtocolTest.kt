package xyz.recordingbean.app

import org.junit.Assert.*
import org.junit.Test

class D3200ProtocolTest {
    @Test fun commandAndFrame() {
        assertEquals(12, D3200Protocol.command(26, 14, D3200Protocol.le(0, 2)).size)
        assertThrows(IllegalArgumentException::class.java) { D3200Protocol.command(26, 16) }
        val payload = D3200Protocol.le(1, 2) + D3200Protocol.le(123) + D3200Protocol.le(7200)
        val frame = byteArrayOf(9, -1, 0, 0, 1, 26, 14) + D3200Protocol.le((payload.size + 10).toLong(), 2) + payload
        val packet = frame + byteArrayOf((frame.sumOf { D3200Protocol.unsigned(it) } and 255).toByte())
        val decoder = BeanFrameDecoder()
        assertTrue(decoder.push(packet.copyOfRange(0, 8)).isEmpty())
        val result = decoder.push(packet.copyOfRange(8, packet.size) + packet)
        assertEquals(2, result.size)
        assertEquals(DeviceFile(123, 7200), D3200Protocol.files(result[0].payload).first())
        assertEquals(7200, D3200Protocol.files(result[0].payload).first().durationMs)
    }
    @Test fun slicesAndOgg() {
        assertThrows(IllegalArgumentException::class.java) { D3200Protocol.slices(ByteArray(165)) }
        assertArrayEquals(byteArrayOf(0,0,0,70), D3200Protocol.counter(ByteArray(16), 7).copyOfRange(12, 16))
        assertThrows(IllegalArgumentException::class.java) { D3200Protocol.offlineSize(0xffff_ffffL) }
        assertEquals(188, D3200Protocol.oggPage(ByteArray(160), 2, 960, 4).size)
        val window = D3200Protocol.liveWindow(listOf(ByteArray(160), ByteArray(160)))
        assertArrayEquals("OggS".toByteArray(), window.copyOfRange(0, 4))
        assertThrows(IllegalArgumentException::class.java) { D3200Protocol.liveWindow(emptyList()) }
    }
}
