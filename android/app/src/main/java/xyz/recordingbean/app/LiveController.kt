package xyz.recordingbean.app

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Durable draft windows. A live session is never final until a complete device recording is archived. */
class LiveController(private val device: D3200Device, private val cloud: CloudApi,
                     private val endpoint: String, private val root: File,
                     private val notify: (String) -> Unit) : AutoCloseable {
    private val lock = Object()
    private val uploader = Executors.newSingleThreadExecutor()
    private var journalFile: File? = null
    private var journal: JSONObject? = null
    private var uploading = false
    private var uploadError: String? = null

    fun start(deviceId: String, originalId: Long, windowSeconds: Int): LiveCapture {
        require(windowSeconds in listOf(2, 5, 10, 20)) { "LIVE_WINDOW_INVALID" }
        check(root.mkdirs() || root.isDirectory) { "LIVE_CACHE_UNAVAILABLE" }
        val stamp = System.currentTimeMillis()
        synchronized(lock) {
            journalFile = File(root, "live-journal-$stamp.json")
            journal = JSONObject().put("version", 1).put("endpoint", endpoint)
                .put("device_id", deviceId).put("original_id", originalId.toString())
                .put("capture_id", "$originalId:capture:$stamp")
                .put("title", "实时录音 $originalId").put("window_seconds", windowSeconds)
                .put("from_sequence", JSONObject.NULL).put("session_id", "")
                .put("pending", JSONArray()).put("uploaded", 0)
                .put("device_ended", false).put("completed", false)
            persist()
        }
        val captured = device.captureRealtime(originalId, root, windowSeconds) { segment ->
            synchronized(lock) {
                val state = journal ?: error("LIVE_JOURNAL_MISSING")
                if (state.isNull("from_sequence")) state.put("from_sequence", segment.fromSequence)
                state.getJSONArray("pending").put(JSONObject().put("index", segment.index)
                    .put("frames", segment.frames).put("path", segment.audio.canonicalPath))
                persist()
                scheduleUpload()
            }
        }
        synchronized(lock) { journal!!.put("device_ended", true); persist() }
        waitForUpload()
        return captured
    }

    private fun scheduleUpload() {
        if (uploading) return
        uploading = true
        uploader.execute { drain() }
    }

    private fun drain() {
        try {
            while (true) {
                val row: JSONObject
                var state: JSONObject
                synchronized(lock) {
                    state = JSONObject((journal ?: error("LIVE_JOURNAL_MISSING")).toString())
                    val pending = state.getJSONArray("pending")
                    if (pending.length() == 0) { uploading = false; lock.notifyAll(); return }
                    row = pending.getJSONObject(0)
                }
                val index = row.getInt("index")
                val frames = row.getInt("frames")
                val file = File(row.getString("path"))
                require(file.canonicalFile.parentFile == root.canonicalFile && file.isFile &&
                    index == state.getInt("uploaded") && frames in 1..state.getInt("window_seconds") * 50 &&
                    state.getString("endpoint") == endpoint) { "LIVE_JOURNAL_INVALID" }
                val audio = file.readBytes()
                require(audio.size <= 1_048_576) { "LIVE_WINDOW_TOO_LARGE" }
                var sessionId = state.getString("session_id")
                if (sessionId.isEmpty()) {
                    val source = RecordingRef(state.getString("device_id"), state.getString("capture_id"), state.getString("title"))
                    val session = cloud.liveBegin(source, state.getString("original_id"),
                        state.getLong("from_sequence") * 20, state.getInt("window_seconds") * 1000)
                    sessionId = session.getString("session_id")
                    synchronized(lock) { journal!!.put("session_id", sessionId); persist() }
                }
                cloud.livePut(sessionId, index, audio, frames * 20)
                synchronized(lock) {
                    state = journal ?: error("LIVE_JOURNAL_MISSING")
                    val rest = JSONArray()
                    val pending = state.getJSONArray("pending")
                    for (i in 1 until pending.length()) rest.put(pending.getJSONObject(i))
                    state.put("pending", rest).put("uploaded", index + 1)
                    persist()
                    lock.notifyAll()
                }
                check(file.delete()) { "LIVE_CACHE_CLEANUP_PENDING" }
                notify("实时音频已上传 ${index + 1} 段，转写在后台继续")
            }
        } catch (e: Exception) {
            synchronized(lock) { uploadError = e.message ?: e.javaClass.simpleName; uploading = false; lock.notifyAll() }
            notify("实时上传暂时中断；片段已保留：${uploadError}")
        }
    }

    private fun waitForUpload() {
        val deadline = System.currentTimeMillis() + 120_000
        synchronized(lock) {
            while (uploading && System.currentTimeMillis() < deadline) lock.wait(500)
            check(!uploading && journal?.getJSONArray("pending")?.length() == 0) {
                "LIVE_UPLOAD_PENDING_${uploadError ?: "TIMEOUT"}"
            }
        }
    }

    fun status(): JSONObject? {
        val id = synchronized(lock) { journal?.optString("session_id") } ?: return null
        return if (id.isEmpty()) null else cloud.liveStatus(id)
    }

    fun finish(recordingId: String) {
        val state = synchronized(lock) { JSONObject((journal ?: error("LIVE_JOURNAL_MISSING")).toString()) }
        check(state.getBoolean("device_ended") && state.getJSONArray("pending").length() == 0 &&
            state.getInt("uploaded") > 0) { "LIVE_NOT_READY_FOR_FINISH" }
        cloud.liveFinish(state.getString("session_id"), recordingId, state.getInt("uploaded"))
        synchronized(lock) { journal!!.put("completed", true); persist() }
    }

    fun recoverPending(): Int {
        check(root.mkdirs() || root.isDirectory) { "LIVE_CACHE_UNAVAILABLE" }
        var recovered = 0
        root.listFiles { file -> file.name.matches(Regex("live-journal-[0-9]+\\.json")) }
            ?.sortedBy { it.name }?.forEach { file ->
                val state = JSONObject(file.readText())
                if (state.optString("endpoint") != endpoint || state.optBoolean("completed")) return@forEach
                require(state.getInt("version") == 1 && state.getInt("window_seconds") in listOf(2,5,10,20)) {
                    "LIVE_JOURNAL_INVALID"
                }
                synchronized(lock) { journalFile = file; journal = state; uploadError = null }
                val before = state.getJSONArray("pending").length()
                synchronized(lock) { if (before > 0) scheduleUpload() }
                waitForUpload()
                recovered += before
                if (state.getBoolean("device_ended") && state.getInt("uploaded") > 0) {
                    val previous = cloud.recordings().getJSONArray("recordings")
                    val archived = (0 until previous.length()).map { previous.getJSONObject(it) }.firstOrNull { row ->
                        val sources = row.optJSONArray("source_devices")
                        row.optInt("stored") == 1 && row.optString("source_id") == state.getString("original_id") &&
                            (row.optString("device_id") == state.getString("device_id") ||
                            (sources != null && (0 until sources.length()).any { sources.optString(it) == state.getString("device_id") }))
                    }
                    if (archived != null) finish(archived.getString("id"))
                }
            }
        return recovered
    }

    private fun persist() {
        val file = journalFile ?: error("LIVE_JOURNAL_MISSING")
        val bytes = (journal ?: error("LIVE_JOURNAL_MISSING")).toString().toByteArray(Charsets.UTF_8)
        val atomic = AtomicFile(file)
        val stream = atomic.startWrite()
        try { stream.write(bytes); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
    }

    override fun close() { uploader.shutdown() }
}
