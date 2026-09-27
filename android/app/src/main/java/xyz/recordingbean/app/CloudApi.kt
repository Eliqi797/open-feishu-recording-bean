package xyz.recordingbean.app

import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest

data class RecordingRef(val deviceId: String, val sourceId: String, val title: String)
data class UploadReceipt(val recordingId: String, val size: Long, val sha256: String, val stored: Boolean, val verified: Boolean)

/** The recorder's expired device-local TLS pin is never used for cloud traffic. */
class CloudApi(origin: String, private val token: String) {
    private val base: String
    init {
        val url = URI(origin.trim())
        require(url.scheme == "https" && !url.host.isNullOrBlank() && url.userInfo == null && url.rawQuery == null &&
                url.rawFragment == null && (url.path.isNullOrEmpty() || url.path == "/")) { "CLOUD_HTTPS_REQUIRED" }
        base = url.toString().trimEnd('/')
    }

    private fun call(path: String, method: String = "GET", body: ByteArray? = null, headers: Map<String, String> = emptyMap()): JSONObject {
        require(path.startsWith("/api/") && !path.contains("..")) { "CLOUD_PATH_INVALID" }
        val connection = URL(base + path).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 90_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            if (body != null) {
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            val response = (if (status in 200..299) connection.inputStream else connection.errorStream)?.use { it.readBytes() }
                ?: throw IllegalStateException("CLOUD_EMPTY_RESPONSE")
            if (status == 401 || status == 403) error("CLOUD_AUTH_REQUIRED")
            val json = JSONObject(response.toString(Charsets.UTF_8))
            if (status !in 200..299) error(json.optString("error", "CLOUD_HTTP_$status"))
            return json
        } finally { connection.disconnect() }
    }

    fun recordings(): JSONObject = call("/api/recordings")
    fun recording(recordingId: String): JSONObject {
        require(recordingId.matches(Regex("[0-9a-f]{32}"))) { "RECORDING_ID_INVALID" }
        return call("/api/recordings/$recordingId")
    }
    fun result(recordingId: String, stage: String): JSONObject {
        require(recordingId.matches(Regex("[0-9a-f]{32}")) && stage in setOf("asr", "summary")) {
            "RESULT_PATH_INVALID"
        }
        return call("/api/recordings/$recordingId/result/$stage")
    }
    fun audioSource(recordingId: String): Pair<String, Map<String, String>> {
        require(recordingId.matches(Regex("[0-9a-f]{32}"))) { "RECORDING_ID_INVALID" }
        require(token.isNotBlank()) { "CLOUD_AUTH_REQUIRED" }
        return Pair(base + "/api/recordings/$recordingId/audio", mapOf(
            "Authorization" to "Bearer $token",
            "android-allow-cross-domain-redirect" to "0"
        ))
    }
    fun liveBegin(source: RecordingRef, originalId: String, startMs: Long, windowMs: Int): JSONObject {
        require(windowMs in listOf(2000, 5000, 10000, 20000) && startMs >= 0) { "LIVE_WINDOW_INVALID" }
        val body = JSONObject().put("device_id", source.deviceId).put("source_id", source.sourceId)
            .put("title", source.title).put("original_source_id", originalId)
            .put("start_ms", startMs).put("window_ms", windowMs)
        return call("/api/live", "POST", body.toString().toByteArray(), mapOf("Content-Type" to "application/json"))
    }
    fun liveStatus(sessionId: String): JSONObject {
        require(sessionId.matches(Regex("[0-9a-f]{32}"))) { "LIVE_ID_INVALID" }
        return call("/api/live/$sessionId")
    }
    fun livePut(sessionId: String, index: Int, audio: ByteArray, durationMs: Int) {
        require(sessionId.matches(Regex("[0-9a-f]{32}")) && index in 0..54000 && durationMs in 20..20000 &&
            durationMs % 20 == 0 && audio.size in 1..1_048_576 && audio.take(4).toByteArray().contentEquals("OggS".toByteArray())) {
            "LIVE_SEGMENT_INVALID"
        }
        val sha = sha256(audio)
        val receipt = call("/api/live/$sessionId/segments/$index", "PUT", audio,
            mapOf("Content-Type" to "audio/ogg", "X-Chunk-SHA256" to sha, "X-Audio-Duration-Ms" to durationMs.toString()))
        require(receipt.getBoolean("verified") && receipt.getString("sha256") == sha &&
            receipt.getInt("idx") == index && receipt.getInt("size") == audio.size) { "LIVE_RECEIPT_MISMATCH" }
    }
    fun liveFinish(sessionId: String, recordingId: String, count: Int): JSONObject {
        require(sessionId.matches(Regex("[0-9a-f]{32}")) && recordingId.matches(Regex("[0-9a-f]{32}")) && count > 0)
        val body = JSONObject().put("recording_id", recordingId).put("segment_count", count).put("device_end_observed", true)
        return call("/api/live/$sessionId/finish", "POST", body.toString().toByteArray(), mapOf("Content-Type" to "application/json"))
    }
    fun startPipeline(recordingId: String): JSONObject {
        require(recordingId.matches(Regex("[0-9a-f]{32}"))) { "RECORDING_ID_INVALID" }
        return call("/api/recordings/$recordingId/pipeline", "POST", "{}".toByteArray(), mapOf("Content-Type" to "application/json"))
    }
    fun settings(): JSONObject = call("/api/settings")
    fun saveSettings(revision: Int, values: JSONObject, clearSecrets: List<String> = emptyList()): JSONObject {
        val change = JSONObject().put("revision", revision).put("values", values)
            .put("clear_secrets", org.json.JSONArray(clearSecrets))
        return call("/api/settings", "POST", change.toString().toByteArray(), mapOf("Content-Type" to "application/json"))
    }

    fun upload(file: File, source: RecordingRef, progress: (Long, Long) -> Unit): UploadReceipt {
        require(file.isFile && file.length() > 0) { "LOCAL_AUDIO_MISSING" }
        val size = file.length()
        val sha = sha256(file)
        val body = JSONObject().put("device_id", source.deviceId).put("source_id", source.sourceId)
            .put("title", source.title).put("size", size).put("sha256", sha).put("mime", "audio/ogg")
        val recordedAt = source.sourceId.toLongOrNull()?.takeIf {
            source.sourceId.length in 9..10 && it in 946_684_800L..4_102_444_800L
        }
        body.put("recorded_at", recordedAt ?: JSONObject.NULL)
        val session = call("/api/uploads", "POST", body.toString().toByteArray(), mapOf("Content-Type" to "application/json"))
        val chunkSize = session.getInt("chunk_size")
        require(session.getLong("size") == size && session.getString("sha256") == sha && chunkSize in 1..16_777_216) {
            "UPLOAD_SESSION_MISMATCH"
        }
        if (!session.getBoolean("stored")) {
            val received = mutableMapOf<Int, String>()
            val chunks = session.getJSONArray("chunks")
            for (i in 0 until chunks.length()) {
                val chunk = chunks.getJSONObject(i)
                received[chunk.getInt("idx")] = chunk.getString("sha256")
            }
            FileInputStream(file).use { input ->
                var offset = 0L
                var index = 0
                while (offset < size) {
                    val expected = minOf(chunkSize.toLong(), size - offset).toInt()
                    val bytes = ByteArray(expected)
                    var count = 0
                    while (count < expected) {
                        val n = input.read(bytes, count, expected - count)
                        require(n > 0) { "LOCAL_AUDIO_CHANGED" }
                        count += n
                    }
                    val chunkHash = sha256(bytes)
                    if (received[index] != chunkHash) {
                        call("/api/uploads/${session.getString("upload_id")}/chunks/$index", "PUT", bytes,
                            mapOf("Content-Type" to "application/octet-stream", "X-Chunk-SHA256" to chunkHash))
                    }
                    offset += expected
                    index++
                    progress(offset, size)
                }
            }
        }
        require(file.length() == size && sha256(file) == sha) { "LOCAL_AUDIO_CHANGED" }
        val receipt = call("/api/uploads/${session.getString("upload_id")}/complete", "POST", "{}".toByteArray(),
            mapOf("Content-Type" to "application/json"))
        val result = UploadReceipt(receipt.getString("recording_id"), receipt.getLong("size"), receipt.getString("sha256"),
            receipt.getBoolean("stored"), receipt.getBoolean("verified"))
        require(result.stored && result.verified && result.recordingId == session.getString("recording_id") &&
                result.size == size && result.sha256 == sha) { "CLOUD_RECEIPT_MISMATCH" }
        return result
    }

    private fun sha256(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                md.update(buffer, 0, n)
            }
        }
        return hex(md.digest())
    }
    private fun sha256(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
