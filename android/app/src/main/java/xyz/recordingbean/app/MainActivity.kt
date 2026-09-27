package xyz.recordingbean.app

import android.Manifest
import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.content.Intent
import android.content.ComponentName
import android.content.pm.PackageManager
import android.net.Uri
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.Switch
import android.widget.TextView
import android.bluetooth.BluetoothDevice
import org.json.JSONObject
import java.io.File
import java.text.DateFormat
import java.net.URI
import java.util.Date
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var device: D3200Device
    private lateinit var config: PrivateConfig
    private lateinit var content: LinearLayout
    private lateinit var pageContent: LinearLayout
    private var settingsSection = ""
    private val settingsPanels = mutableMapOf<String, LinearLayout>()
    private var backCallback: OnBackInvokedCallback? = null
    private lateinit var state: TextView
    private var tab = 0
    private var devices = listOf<BluetoothDevice>()
    private var deviceFiles = listOf<DeviceFile>()
    @Volatile private var status: BeanStatus? = null
    private var live: LiveController? = null
    @Volatile private var liveText = ""
    @Volatile private var liveStatus = "尚未开始实时记录"
    @Volatile private var liveRunning = false
    @Volatile private var devicePolling = false
    private var recordings: JSONObject? = null
    private var selectedRecording: JSONObject? = null
    private var transcriptText = ""
    private var summaryText = ""
    private var transcriptPage = 0
    private var providerSettings: JSONObject? = null
    private var settingsLoadAttempted = false
    private var audioPlayer: MediaPlayer? = null
    private var playingRecordingId: String? = null
    private var playbackReady = false
    private var playbackPaused = false
    private var playbackDragging = false
    private var playbackSeek: SeekBar? = null
    private var playbackClock: TextView? = null
    private val playbackHandler = Handler(Looper.getMainLooper())
    private val playbackTicker = object : Runnable {
        override fun run() {
            val player = audioPlayer ?: return
            if (playbackReady) {
                runCatching {
                    val duration = player.duration.coerceAtLeast(0)
                    val position = player.currentPosition.coerceIn(0, duration.coerceAtLeast(1))
                    playbackSeek?.max = duration.coerceAtLeast(1)
                    playbackSeek?.isEnabled = duration > 0
                    if (!playbackDragging) playbackSeek?.progress = position
                    playbackClock?.text = "${formatPlaybackTime(position)} / ${formatPlaybackTime(duration)}"
                }
            }
            playbackHandler.postDelayed(this, 500)
        }
    }
    private var lastMessage = ""
    @Volatile private var busy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        config = PrivateConfig(this)
        when (config.themeMode) {
            "light" -> setTheme(R.style.RecordingBeanThemeLight)
            "dark" -> setTheme(R.style.RecordingBeanThemeDark)
        }
        super.onCreate(savedInstanceState)
        tab = savedInstanceState?.getInt("tab") ?: 0
        settingsSection = savedInstanceState?.getString("settingsSection") ?: ""
        if (Build.VERSION.SDK_INT >= 33) {
            val callback = OnBackInvokedCallback { if (!handleBack()) finish() }
            backCallback = callback
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
        }
        device = D3200Device(this)
        applyKeepAwake()
        runCatching { applyIconColor(config.iconColor) }
            .onFailure { lastMessage = "桌面图标同步失败：${it.message ?: it.javaClass.simpleName}" }
        device.onDisconnected = {
            runOnUiThread {
                status = null
                if (!busy) lastMessage = "录音豆已断开，云端上传会继续"
                render()
            }
        }
        render()
        refreshCloud()
        Executors.newSingleThreadScheduledExecutor().also { livePoller = it }
            .scheduleWithFixedDelay({
                try {
                    val state = live?.status() ?: return@scheduleWithFixedDelay
                    liveText = state.optString("text")
                    val segments = state.getJSONArray("segments")
                    val waiting = (0 until segments.length()).count {
                        segments.getJSONObject(it).getString("status") in listOf("queued", "running")
                    }
                    liveStatus = "已上传 ${state.getInt("received_ms") / 1000.0} 秒 · 待转写 $waiting 段"
                    runOnUiThread { if (tab == 1) render() }
                } catch (_: Exception) { /* Keep locally saved draft; next poll can recover. */ }
            }, 3, 3, TimeUnit.SECONDS)
        livePoller?.scheduleWithFixedDelay({
            if (status == null || busy || liveRunning || devicePolling) return@scheduleWithFixedDelay
            devicePolling = true
            worker.execute {
                try {
                    if (busy || liveRunning || status == null) return@execute
                    val wasRecording = status?.recording == 1
                    val previous = deviceFiles.map { it.id }.toSet()
                    status = device.refreshStatus()
                    deviceFiles = device.list()
                    val newFile = deviceFiles.any { it.id !in previous }
                    if (config.autoUpload && status?.recording != 1 && (wasRecording || newFile)) {
                        try { syncInternal() }
                        catch (e: Exception) { message("自动上传暂停：${e.message ?: e.javaClass.simpleName}") }
                    }
                    runOnUiThread { if (tab != 2) render() }
                } catch (e: Exception) {
                    status = null
                    message("设备连接已中断：${e.message ?: e.javaClass.simpleName}")
                    runOnUiThread { if (tab != 2) render() }
                } finally { devicePolling = false }
            }
        }, 15, 15, TimeUnit.SECONDS)
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= 33) backCallback?.let {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)
        }
        stopPlayback()
        device.cancel()
        livePoller?.shutdownNow()
        live?.close()
        worker.execute { device.close() }
        worker.shutdown()
        super.onDestroy()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putInt("tab", tab)
        outState.putString("settingsSection", settingsSection)
        super.onSaveInstanceState(outState)
    }

    private fun handleBack(): Boolean {
        when {
            selectedRecording != null -> {
                stopPlayback(); selectedRecording = null; render()
            }
            tab == 2 && settingsSection.isNotEmpty() -> {
                settingsSection = ""; render()
            }
            tab != 0 -> {
                tab = 0; render()
            }
            else -> return false
        }
        return true
    }

    @Suppress("DEPRECATION", "GestureBackNavigation")
    override fun onBackPressed() {
        if (!handleBack()) super.onBackPressed()
    }

    override fun onResume() {
        super.onResume()
        if (::config.isInitialized) applyKeepAwake()
    }

    override fun onPause() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        super.onPause()
    }

    private fun applyKeepAwake() {
        if (config.keepAwake || BuildConfig.DEBUG) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private var livePoller: java.util.concurrent.ScheduledExecutorService? = null

    private fun runJob(label: String, action: () -> Unit) {
        if (busy) return
        busy = true
        message(label)
        worker.execute {
            try { action() } catch (e: Exception) {
                message(when (e.message) {
                    "D3200_BLE_DISABLED" -> "手机蓝牙已关闭，打开蓝牙后重新扫描录音豆"
                    else -> "未完成：${e.message ?: e.javaClass.simpleName}"
                })
            }
            finally { busy = false; runOnUiThread { render() } }
        }
    }

    private fun message(text: String) = runOnUiThread { lastMessage = text; state.text = text }
    private fun client(): CloudApi = CloudApi(config.origin, config.token())

    private fun stopPlayback() {
        playbackHandler.removeCallbacks(playbackTicker)
        playingRecordingId = null
        playbackReady = false
        playbackPaused = false
        playbackSeek = null
        playbackClock = null
        audioPlayer?.release()
        audioPlayer = null
    }

    private fun formatPlaybackTime(milliseconds: Int): String {
        val total = milliseconds.coerceAtLeast(0) / 1000
        return if (total >= 3600) "%d:%02d:%02d".format(total / 3600, total / 60 % 60, total % 60)
            else "%d:%02d".format(total / 60, total % 60)
    }

    private fun applyIconColor(color: String) {
        require(color in setOf("white", "black"))
        val white = ComponentName(this, "$packageName.LauncherWhite")
        val black = ComponentName(this, "$packageName.LauncherBlack")
        val chosen = if (color == "black") black else white
        val other = if (color == "black") white else black
        val manager = packageManager
        val enabled = PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        val disabled = PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        val flags = PackageManager.DONT_KILL_APP
        if (manager.getComponentEnabledSetting(chosen) != enabled) {
            manager.setComponentEnabledSetting(chosen, enabled, flags)
        }
        if (manager.getComponentEnabledSetting(other) != disabled) {
            manager.setComponentEnabledSetting(other, disabled, flags)
        }
    }

    private fun selectIconColor(color: String) {
        if (color == config.iconColor) return
        try {
            applyIconColor(color)
            config.iconColor = color
            message("已选择${if (color == "black") "黑色" else "白色"}桌面图标，桌面可能需要片刻刷新")
        } catch (error: Exception) {
            runCatching { applyIconColor(config.iconColor) }
            message("桌面图标切换失败：${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun togglePlayback(recordingId: String) {
        if (playingRecordingId == recordingId) {
            val current = audioPlayer
            if (!playbackReady || current == null) {
                stopPlayback()
                lastMessage = "回听已取消"
            } else if (playbackPaused) {
                current.start()
                playbackPaused = false
                lastMessage = "继续回听"
            } else {
                current.pause()
                playbackPaused = true
                lastMessage = "回听已暂停"
            }
            render()
            return
        }
        stopPlayback()
        try {
            val (url, headers) = client().audioSource(recordingId)
            val player = MediaPlayer()
            audioPlayer = player
            playingRecordingId = recordingId
            player.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            player.setOnPreparedListener { ready ->
                if (audioPlayer === ready) {
                    playbackReady = true
                    ready.start()
                    playbackHandler.post(playbackTicker)
                    lastMessage = "正在回听云端录音"
                    render()
                }
            }
            player.setOnCompletionListener { completed ->
                if (audioPlayer === completed) {
                    stopPlayback()
                    lastMessage = "回听结束"
                    render()
                }
            }
            player.setOnErrorListener { failed, _, _ ->
                if (audioPlayer === failed) {
                    stopPlayback()
                    lastMessage = "回听失败，请检查云端录音和网络"
                    render()
                }
                true
            }
            player.setDataSource(this, Uri.parse(url), headers)
            lastMessage = "正在加载云端录音"
            render()
            player.prepareAsync()
        } catch (error: Exception) {
            stopPlayback()
            lastMessage = "回听未启动：${error.message ?: error.javaClass.simpleName}"
            render()
        }
    }
    private fun refreshCloud() = runJob("正在读取云端") {
        if (config.origin.isNotBlank() && config.token().isNotBlank()) {
            recordings = client().recordings()
            providerSettings = client().settings()
            settingsLoadAttempted = true
            message("云端已连接")
            if (config.autoUpload) {
                runCatching { resumeCachedInternal() }
                    .onFailure { message("完整录音缓存待重试：${it.message ?: it.javaClass.simpleName}") }
                val liveRoot = File(filesDir, "live")
                if (liveRoot.listFiles()?.any { it.name.matches(Regex("live-journal-[0-9]+\\.json")) } == true) {
                    live?.close()
                    live = LiveController(device, client(), config.origin.trim().trimEnd('/'), liveRoot) {
                        liveStatus = it; message(it)
                    }
                    runCatching { live!!.recoverPending() }
                        .onFailure { message("实时草稿待重试：${it.message ?: it.javaClass.simpleName}") }
                }
            }
        }
    }

    private fun loadDetails(recordingId: String) {
        val cloud = client()
        val detail = cloud.recording(recordingId)
        val jobs = detail.optJSONArray("jobs")
        fun completed(stage: String): Boolean = (0 until (jobs?.length() ?: 0)).any { index ->
            val job = jobs!!.getJSONObject(index)
            job.optString("stage") == stage && job.optString("status") == "completed"
        }
        var transcript = ""
        var summary = ""
        if (completed("asr")) {
            val result = cloud.result(recordingId, "asr")
            transcript = result.optString("text")
            if (result.optJSONObject("coverage")?.optString("status") == "partial") {
                summary = "转写不完整：部分时段没有识别文字，请结合原音核对。\n\n"
            }
        }
        if (completed("summary")) {
            val result = cloud.result(recordingId, "summary")
            fun lines(name: String): String = result.optJSONArray(name)?.let { array ->
                (0 until array.length()).joinToString("\n") { array.optString(it) }
            } ?: ""
            val actions = result.optJSONArray("actions")?.let { array ->
                (0 until array.length()).joinToString("\n") { index ->
                    val action = array.getJSONObject(index)
                    "${action.optString("task")} · 责任人：${action.optString("owner").takeIf { it.isNotBlank() && it != "null" } ?: "待确认"} · 日期：${action.optString("due_date").takeIf { it.isNotBlank() && it != "null" } ?: "待确认"}"
                }
            } ?: ""
            summary += result.optString("summary") + "\n\n结论\n" + lines("decisions") +
                "\n\n待办\n" + actions + "\n\n待确认\n" + lines("uncertainties")
        }
        selectedRecording = detail
        transcriptText = transcript
        summaryText = summary
        message("处理结果已更新；说话人准确性仍需核验")
    }

    private fun selectRecording(recordingId: String) = runJob("正在读取录音详情") {
        transcriptPage = 0
        loadDetails(recordingId)
    }

    private fun resumeCached() = runJob("正在恢复本机缓存") { resumeCachedInternal() }

    private fun resumeCachedInternal() {
        check(config.origin.isNotBlank() && config.token().isNotBlank()) { "CLOUD_NOT_CONFIGURED" }
        val root = File(filesDir, "recordings")
        val directories = root.listFiles()?.filter { it.isDirectory && it.name.matches(Regex("d3200-sn-[0-9a-f]{64}")) }
            ?: emptyList()
        val cloud = client()
        var completed = 0
        var processingFailures = 0
        for (directory in directories) {
            for (audio in directory.listFiles() ?: emptyArray()) {
                val match = Regex("([0-9]{9,10})-[0-9]+\\.ogg").matchEntire(audio.name) ?: continue
                if (!audio.isFile) continue
                val id = match.groupValues[1]
                val epoch = id.toLongOrNull()?.takeIf { it in 946_684_800L..4_102_444_800L } ?: continue
                val title = "录音 " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(epoch * 1000))
                message("正在恢复缓存上传 $id")
                val receipt = cloud.upload(audio, RecordingRef(directory.name, id, title)) { bytes, total ->
                    message(if (total > 0) "缓存上传 · ${bytes * 100 / total}%"
                        else "缓存上传 · ${bytes / 1024} KB 已发送")
                }
                check(receipt.verified && receipt.stored) { "CLOUD_RECEIPT_MISMATCH" }
                check(audio.delete()) { "CACHE_CLEANUP_PENDING" }
                completed++
                runCatching { cloud.startPipeline(receipt.recordingId) }.onFailure { processingFailures++ }
            }
        }
        recordings = cloud.recordings()
        message(if (completed == 0) "没有待上传的完整缓存" else if (processingFailures == 0)
            "已恢复上传 $completed 条录音" else "已恢复上传 $completed 条，$processingFailures 条待重试处理")
    }

    private fun permissions(): Boolean {
        val required = if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.NEARBY_WIFI_DEVICES)
        else if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.ACCESS_FINE_LOCATION)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = required.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return true
        requestPermissions(missing.toTypedArray(), 101)
        message("请允许蓝牙与 Wi-Fi 权限，再点扫描")
        return false
    }

    private fun scan() {
        if (!permissions()) return
        runJob("正在扫描录音豆") {
            devices = device.scan()
            message(if (devices.isEmpty()) "未发现设备，请唤醒录音豆" else "请选择录音豆连接")
        }
    }

    private fun connect(target: BluetoothDevice) = runJob("正在连接录音豆") {
        status = device.connect(target)
        deviceFiles = device.list()
        message("已连接，读取到 ${deviceFiles.size} 条录音")
        if (config.autoUpload && config.origin.isNotBlank() && status?.recording != 1) {
            try { syncInternal() }
            catch (e: Exception) {
                message("蓝牙已读取 ${deviceFiles.size} 条录音；自动上传未完成：${e.message ?: e.javaClass.simpleName}")
            }
        }
    }

    private fun sync() = runJob("正在高速传输") { syncInternal() }
    private fun syncOne(file: DeviceFile) = runJob("正在传输该录音") { syncInternal(file.id) }

    private fun downloadOnly(file: DeviceFile) = runJob("正在下载到手机") {
        val identity = status ?: error("D3200_NOT_CONNECTED")
        val fresh = device.refreshStatus().also { status = it }
        check(fresh.recording != 1) { "D3200_RECORDING_NOT_FINALIZED" }
        check(fresh.deviceId == identity.deviceId) { "D3200_IDENTITY_CHANGED" }
        val cache = File(filesDir, "recordings/${identity.deviceId}").also { it.mkdirs() }
        if (cache.listFiles()?.any { it.name.startsWith("${file.id}-") && it.extension == "ogg" } == true) {
            message("手机已有完整录音缓存，可继续上传")
            return@runJob
        }
        device.beginBatch()
        var lastBytes = 0L; var lastTime = System.nanoTime()
        try { device.download(file, cache) { bytes, total ->
            val now = System.nanoTime()
            if (now - lastTime > 500_000_000) {
                val rate = (bytes - lastBytes) / ((now - lastTime) / 1e9)
                message("高速下载 · ${formatSpeed(rate)} · ${if (total > 0) bytes * 100 / total else 0}%")
                lastBytes = bytes; lastTime = now
            }
        } } finally { device.endBatch() }
        message("已下载并校验到手机，设备原件保留；可继续上传")
    }

    private fun startLive() = runJob("正在接收实时音频") {
        val identity = status ?: error("D3200_NOT_CONNECTED")
        val fileId = device.currentRecordingId ?: error("D3200_NO_ACTIVE_RECORDING")
        check(identity.recording == 1 && config.origin.isNotBlank() && config.token().isNotBlank()) {
            "LIVE_DEVICE_OR_CLOUD_NOT_READY"
        }
        live?.close()
        val controller = LiveController(device, client(), config.origin.trim().trimEnd('/'), File(filesDir, "live")) { liveStatus = it; message(it) }
        live = controller
        liveRunning = true
        runOnUiThread { render() }
        try {
            val captured = controller.start(identity.deviceId, fileId, config.liveWindowSeconds)
            liveStatus = "设备录音已结束，正在归档完整音频"
            status = device.refreshStatus()
            deviceFiles = device.list()
            syncInternal()
            val list = client().recordings().getJSONArray("recordings")
            val archived = (0 until list.length()).map { list.getJSONObject(it) }.firstOrNull { row ->
                val sourceDevices = row.optJSONArray("source_devices")
                row.optInt("stored") == 1 && row.optString("source_id") == fileId.toString() &&
                    (row.optString("device_id") == identity.deviceId ||
                    (sourceDevices != null && (0 until sourceDevices.length()).any { sourceDevices.optString(it) == identity.deviceId }))
            } ?: error("LIVE_FINAL_RECORDING_NOT_ARCHIVED")
            controller.finish(archived.getString("id"))
            check(captured.audio.delete()) { "LIVE_CAPTURE_CACHE_CLEANUP_PENDING" }
            liveStatus = "实时草稿完成；完整录音已归档并开始生成纪要"
        } finally { liveRunning = false }
    }

    private fun syncInternal(onlyId: Long? = null) {
        check(status != null) { "D3200_NOT_CONNECTED" }
        val identity = device.refreshStatus().also { status = it }
        check(config.origin.isNotBlank() && config.token().isNotBlank()) { "CLOUD_NOT_CONFIGURED" }
        check(identity.recording != 1) { "D3200_RECORDING_NOT_FINALIZED" }
        val cloud = client()
        val previous = cloud.recordings().getJSONArray("recordings")
        val pending = deviceFiles.filter { file ->
            (onlyId == null || file.id == onlyId) &&
            !(0 until previous.length()).any { index ->
                val row = previous.getJSONObject(index)
                val sourceDevices = row.optJSONArray("source_devices")
                val sameDevice = row.optString("device_id") == identity.deviceId ||
                    (sourceDevices != null && (0 until sourceDevices.length()).any { sourceDevices.optString(it) == identity.deviceId })
                sameDevice && row.optString("source_id") == file.id.toString() && row.optInt("stored", 0) == 1
            }
        }
        if (pending.isEmpty()) { message("录音已全部归档"); return }
        val cache = File(filesDir, "recordings/${identity.deviceId}").also { it.mkdirs() }
        fun cached(file: DeviceFile): File? = cache.listFiles()?.firstOrNull { it.name.startsWith("${file.id}-") && it.extension == "ogg" }
        val missing = pending.filter { cached(it) == null }
        if (missing.isNotEmpty()) {
            device.beginBatch()
            try {
                missing.forEachIndexed { index, file ->
                    message("高速下载 ${index + 1}/${missing.size}")
                    var lastBytes = 0L; var lastTime = System.nanoTime()
                    device.download(file, cache) { bytes, total ->
                        val now = System.nanoTime()
                        if (now - lastTime > 500_000_000) {
                            val rate = (bytes - lastBytes) / ((now - lastTime) / 1e9)
                            message("高速下载 ${index + 1}/${missing.size} · ${formatSpeed(rate)}" +
                                if (total > 0) " · ${bytes * 100 / total}%" else " · ${bytes / 1024} KB")
                            lastBytes = bytes; lastTime = now
                        }
                    }
                }
            } finally { device.endBatch() }
        }
        device.awaitInternet()
        var processingFailures = 0
        pending.forEachIndexed { index, file ->
            val audio = cached(file) ?: error("CACHED_AUDIO_REQUIRED")
            message("云端上传 ${index + 1}/${pending.size}")
            val title = "录音 " + DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(file.id * 1000))
            val ref = RecordingRef(identity.deviceId, file.id.toString(), title)
            var lastBytes = 0L; var lastTime = System.nanoTime()
            val receipt = cloud.upload(audio, ref) { bytes, total ->
                val now = System.nanoTime()
                if (now - lastTime > 500_000_000) {
                    val rate = (bytes - lastBytes) / ((now - lastTime) / 1e9)
                    message("云端上传 ${index + 1}/${pending.size} · ${formatSpeed(rate)}" +
                        if (total > 0) " · ${bytes * 100 / total}%" else " · ${bytes / 1024} KB")
                    lastBytes = bytes; lastTime = now
                }
            }
            check(receipt.verified && receipt.stored) { "CLOUD_RECEIPT_MISMATCH" }
            check(audio.delete()) { "CACHE_CLEANUP_PENDING" }
            runCatching { cloud.startPipeline(receipt.recordingId) }
                .onFailure { processingFailures++ }
        }
        recordings = cloud.recordings()
        message(if (processingFailures == 0) "${pending.size} 条录音已保存并开始处理"
            else "${pending.size} 条录音已保存，${processingFailures} 条待重试处理")
    }

    private fun formatSpeed(bytes: Double): String = if (bytes >= 1024 * 1024) "%.1f MB/s".format(bytes / (1024 * 1024))
        else "%.0f KB/s".format(bytes / 1024)

    private fun documentId(row: JSONObject): String? {
        val parts = row.optJSONArray("publications") ?: return null
        return (0 until parts.length()).map { parts.getJSONObject(it) }
            .firstOrNull { it.optInt("part") == 0 && it.optString("status") == "verified" }
            ?.optString("document_id")?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{8,100}")) }
    }

    private fun openDocument(document: String) {
        try {
            val configured = providerSettings?.optJSONObject("values")?.optString("FEISHU_DOCS_ORIGIN")
                ?.takeIf { it.isNotBlank() } ?: "https://www.feishu.cn"
            val origin = URI(configured)
            val host = origin.host ?: error("FEISHU_ORIGIN_INVALID")
            check(origin.scheme == "https" && origin.port == -1 && origin.userInfo == null && origin.rawQuery == null &&
                origin.rawFragment == null && (origin.path.isNullOrEmpty() || origin.path == "/") &&
                (host == "feishu.cn" || host.endsWith(".feishu.cn") || host == "larksuite.com" || host.endsWith(".larksuite.com"))) {
                "FEISHU_ORIGIN_INVALID"
            }
            val destination = origin.toString().trimEnd('/') + "/docx/" + document
            val link = Uri.parse("https://applink.feishu.cn/client/docs/open").buildUpon()
                .appendQueryParameter("url", destination).build()
            startActivity(Intent(Intent.ACTION_VIEW, link))
        } catch (error: Exception) {
            message("打开飞书失败：${error.message ?: error.javaClass.simpleName}")
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density + 0.5f).toInt()
    private fun dark(): Boolean = when (config.themeMode) {
        "dark" -> true
        "light" -> false
        else -> (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
    }
    private fun color(light: String, dark: String): Int = Color.parseColor(if (dark()) dark else light)
    private fun backgroundColor() = color("#F5F7F6", "#101715")
    private fun surfaceColor() = color("#FFFFFF", "#1C2623")
    private fun inkColor() = color("#142520", "#EDF5F0")
    private fun mutedColor() = color("#52645D", "#B0C2B8")
    private fun accentColor() = color("#176B5D", "#75D7B8")
    private fun shape(fill: Int, radius: Int = 16): GradientDrawable = GradientDrawable().apply {
        setColor(fill); cornerRadius = dp(radius).toFloat()
    }

    private fun render() {
        playbackSeek = null
        playbackClock = null
        window.statusBarColor = backgroundColor()
        window.navigationBarColor = surfaceColor()
        window.decorView.systemUiVisibility = if (dark()) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(backgroundColor()) }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(10), dp(16), dp(8))
            setBackgroundColor(surfaceColor())
            val line = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER_VERTICAL }
            line.addView(TextView(this@MainActivity).apply {
                text = "录音豆"; textSize = 17f; setTextColor(inkColor()); setTypeface(null, Typeface.BOLD)
            }, LinearLayout.LayoutParams(0, dp(48), 1f).apply { gravity = android.view.Gravity.CENTER_VERTICAL })
            line.addView(TextView(this@MainActivity).apply {
                text = if (status == null) "未连接" else if (status?.recording == 1) "正在录音" else "已连接"
                textSize = 13f; setTextColor(accentColor()); gravity = android.view.Gravity.CENTER
            }, LinearLayout.LayoutParams(dp(68), dp(48)))
            line.addView(TextView(this@MainActivity).apply {
                text = if (status == null) "连接" else "管理"
                textSize = 14f; setTextColor(accentColor()); gravity = android.view.Gravity.CENTER
                setOnClickListener { tab = 0; render(); if (status == null) scan() }
            }, LinearLayout.LayoutParams(dp(56), dp(48)))
            addView(line)
            addView(TextView(this@MainActivity).apply {
                text = status?.let { "设备 ${it.battery?.let { n -> "$n%" } ?: "--"}${if (it.charging == true) " · 充电中" else ""}     充电盒 ${it.caseBattery?.let { n -> "$n%" } ?: "--"}${if (it.caseCharging == true) " · 充电中" else ""}" }
                    ?: "连接后显示设备与充电盒电量"
                textSize = 12f; setTextColor(mutedColor()); minHeight = dp(28)
            })
        })
        state = TextView(this).apply {
            textSize = 13f; setTextColor(mutedColor()); text = lastMessage
            visibility = if (lastMessage.isBlank()) View.GONE else View.VISIBLE
            setPadding(dp(20), dp(10), dp(20), dp(6))
        }
        root.addView(state)
        val scroll = ScrollView(this).apply { clipToPadding = false; isFillViewport = true }
        pageContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(18), dp(16), dp(24))
        }
        content = pageContent
        scroll.addView(pageContent)
        root.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
        val nav = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(dp(12), dp(4), dp(12), dp(4)); setBackgroundColor(surfaceColor())
        }
        listOf("录音", "实时", "设置").forEachIndexed { index, name ->
            nav.addView(TextView(this).apply {
                text = name; textSize = 14f; gravity = android.view.Gravity.CENTER
                setTypeface(null, if (index == tab) Typeface.BOLD else Typeface.NORMAL)
                setTextColor(if (index == tab) accentColor() else mutedColor())
                background = if (index == tab) shape(color("#E6F4EE", "#26443A"), 12) else null
                minHeight = dp(52); setOnClickListener { if (tab != index) { tab = index; render() } }
            }, LinearLayout.LayoutParams(0, dp(52), 1f))
        }
        root.addView(nav)
        if (Build.VERSION.SDK_INT >= 30) root.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            view.setPadding(0, bars.top, 0, bars.bottom)
            insets
        }
        setContentView(root)
        when (tab) { 0 -> renderRecordings(); 1 -> renderLive(); else -> renderSettings() }
    }

    private fun heading(text: String) {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
            background = shape(surfaceColor())
        }
        pageContent.addView(panel, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(14) })
        content = panel
        content.addView(TextView(this).apply {
            this.text = text; textSize = 20f; setTypeface(null, Typeface.BOLD); setTextColor(inkColor())
            setPadding(0, 0, 0, dp(10))
        })
    }
    private fun detail(text: String) {
        content.addView(TextView(this).apply {
            this.text = text; textSize = 14f; setTextColor(mutedColor()); setLineSpacing(dp(4).toFloat(), 1f)
            setPadding(0, dp(4), 0, dp(8))
        })
    }
    private fun action(text: String, enabled: Boolean = true, run: () -> Unit) {
        content.addView(Button(this).apply {
            this.text = text; textSize = 14f; isAllCaps = false; isEnabled = enabled && !busy
            setTextColor(if (isEnabled) accentColor() else mutedColor())
            background = shape(color("#E6F4EE", "#26443A"), 12)
            minHeight = dp(48); elevation = 0f; stateListAnimator = null; setOnClickListener { run() }
        }, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(8) })
    }

    private fun settingsHeading(title: String, key: String) {
        heading(title)
        settingsPanels[key] = content
        content.visibility = if (settingsSection == key) View.VISIBLE else View.GONE
    }

    private fun settingsRow(title: String, subtitle: String, key: String) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(12), 0, dp(12))
            minimumHeight = dp(68)
            setOnClickListener { settingsSection = key; render() }
        }
        row.addView(TextView(this).apply {
            text = title; textSize = 16f; setTextColor(inkColor()); setTypeface(null, Typeface.BOLD)
        })
        row.addView(TextView(this).apply {
            text = subtitle; textSize = 13f; setTextColor(mutedColor()); setPadding(0, dp(4), 0, 0)
        })
        content.addView(row)
    }

    private fun renderPlaybackControls(recordingId: String) {
        action(if (playingRecordingId == recordingId && !playbackPaused) "暂停" else "播放") {
            togglePlayback(recordingId)
        }
        if (playingRecordingId != recordingId) return
        action("停止") { stopPlayback(); render() }
        val player = audioPlayer
        val duration = if (playbackReady) runCatching { player?.duration ?: 0 }.getOrDefault(0) else 0
        val position = if (playbackReady) runCatching { player?.currentPosition ?: 0 }.getOrDefault(0) else 0
        playbackSeek = SeekBar(this).apply {
            max = duration.coerceAtLeast(1)
            progress = position.coerceIn(0, max)
            isEnabled = playbackReady && duration > 0
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onStartTrackingTouch(seekBar: SeekBar) { playbackDragging = true }
                override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                    if (fromUser) playbackClock?.text = "${formatPlaybackTime(progress)} / ${formatPlaybackTime(duration)}"
                }
                override fun onStopTrackingTouch(seekBar: SeekBar) {
                    playbackDragging = false
                    if (playbackReady && audioPlayer === player) player?.seekTo(seekBar.progress)
                }
            })
        }
        content.addView(playbackSeek)
        playbackClock = TextView(this).apply {
            text = "${formatPlaybackTime(position)} / ${formatPlaybackTime(duration)}"
            textSize = 13f
        }
        content.addView(playbackClock)
        val navigation = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        listOf(-15_000 to "后退 15 秒", 30_000 to "前进 30 秒").forEach { (offset, label) ->
            navigation.addView(Button(this).apply {
                text = label
                isAllCaps = false
                isEnabled = playbackReady
                setOnClickListener {
                    val active = audioPlayer ?: return@setOnClickListener
                    if (!playbackReady) return@setOnClickListener
                    val end = active.duration.coerceAtLeast(0)
                    active.seekTo((active.currentPosition + offset).coerceIn(0, end))
                }
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
        content.addView(navigation)
    }

    private fun renderRecordings() {
        if (selectedRecording != null) {
            renderRecordingDetail()
            return
        }
        heading("设备")
        action("扫描录音豆") { scan() }
        devices.forEachIndexed { index, found ->
            val name = try {
                if (Build.VERSION.SDK_INT >= 31 &&
                    checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) null
                else found.name
            } catch (_: SecurityException) { null }
            action(name?.takeIf { it.isNotBlank() } ?: "录音豆 ${index + 1}") { connect(found) }
        }
        content.addView(Switch(this).apply { text = "连接后自动上传"; isChecked = config.autoUpload
            setOnCheckedChangeListener { _, value -> config.autoUpload = value } })
        action("高速传输全部未归档录音", status != null) { sync() }
        action("恢复本机缓存上传") { resumeCached() }
        val deviceId = status?.deviceId
        val cloudList = recordings?.optJSONArray("recordings")
        val pendingFiles = deviceFiles.filter { file ->
            deviceId == null || !(0 until (cloudList?.length() ?: 0)).any { index ->
                val row = cloudList!!.getJSONObject(index)
                val sources = row.optJSONArray("source_devices")
                row.optInt("stored") == 1 && row.optString("source_id") == file.id.toString() &&
                    (row.optString("device_id") == deviceId ||
                        (sources != null && (0 until sources.length()).any { sources.optString(it) == deviceId }))
            }
        }
        if (pendingFiles.isNotEmpty()) {
            heading("待同步录音 · ${pendingFiles.size}")
            pendingFiles.forEach { file ->
                detail("${DateFormat.getDateTimeInstance().format(Date(file.id * 1000))} · 时长 ${android.text.format.DateUtils.formatElapsedTime(file.durationMs / 1000)}")
                action("下载到手机", status != null) { downloadOnly(file) }
                action("上传云端", status != null && config.origin.isNotBlank() && config.token().isNotBlank()) { syncOne(file) }
            }
        }
        heading("云端录音")
        action("刷新云端") { refreshCloud() }
        val list = recordings?.optJSONArray("recordings")
        if (list == null || list.length() == 0) detail("暂无录音")
        else for (i in 0 until list.length()) {
            val row = list.getJSONObject(i)
            val item = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = android.view.Gravity.CENTER_VERTICAL
                setPadding(0, dp(10), 0, dp(10))
            }
            val meta = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            meta.addView(TextView(this).apply {
                text = row.optString("title").ifBlank { "未命名录音" }
                textSize = 16f; setTextColor(inkColor()); maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
            })
            val recordedAt = row.optLong("recorded_at", 0).takeIf { it > 0 } ?: row.optLong("created", 0)
            meta.addView(TextView(this).apply {
                text = (if (recordedAt > 0) DateFormat.getDateTimeInstance().format(Date(recordedAt * 1000)) + " · " else "") +
                    if (row.optInt("stored") == 1) "云端已保存" else "上传中"
                textSize = 12f; setTextColor(mutedColor()); setPadding(0, dp(5), 0, 0)
            })
            item.addView(meta, LinearLayout.LayoutParams(0, -2, 1f))
            val document = documentId(row)
            item.addView(TextView(this).apply {
                text = if (document != null) "飞书" else "详情"
                textSize = 14f; setTextColor(accentColor()); gravity = android.view.Gravity.CENTER
                setOnClickListener { if (document != null) openDocument(document) else selectRecording(row.getString("id")) }
            }, LinearLayout.LayoutParams(dp(54), dp(48)))
            content.addView(item)
            if (i < list.length() - 1) content.addView(View(this).apply {
                setBackgroundColor(color("#E7ECE9", "#33423B"))
            }, LinearLayout.LayoutParams(-1, dp(1)))
        }
    }

    private fun renderRecordingDetail() {
        val row = selectedRecording ?: return
        val id = row.optString("id")
        action("返回录音列表") {
            stopPlayback()
            selectedRecording = null
            transcriptText = ""
            summaryText = ""
            render()
        }
        heading(row.optString("title", "录音详情"))
        val recordedAt = row.optLong("recorded_at", 0).takeIf { it > 0 } ?: row.optLong("created", 0)
        if (recordedAt > 0) detail("录于 ${DateFormat.getDateTimeInstance().format(Date(recordedAt * 1000))}")
        detail("%.1f MB · %s".format(row.optLong("size") / 1_048_576.0,
            if (row.optInt("stored") == 1) "云端已保存" else "上传未完成"))
        if (row.optInt("stored") == 1) {
            renderPlaybackControls(id)
        }
        documentId(row)?.let { document -> action("打开飞书文档") { openDocument(document) } }
        action("刷新处理结果") { runJob("正在读取处理结果") { loadDetails(id) } }
        heading("总结")
        detail(summaryText.ifBlank { "总结尚未生成，可在处理状态中继续任务。" })
        heading("转写")
        detail(if (transcriptText.isBlank()) "转写尚未生成。"
            else transcriptText.drop(transcriptPage * 4000).take(4000))
        if (transcriptText.length > 4000) {
            action("上一页", transcriptPage > 0) { transcriptPage--; render() }
            detail("第 ${transcriptPage + 1} 页")
            action("下一页", (transcriptPage + 1) * 4000 < transcriptText.length) { transcriptPage++; render() }
        }
        heading("处理状态")
        val jobs = row.optJSONArray("jobs")
        for (index in 0 until (jobs?.length() ?: 0)) {
            val job = jobs!!.getJSONObject(index)
            detail("${job.optString("stage")}：${job.optString("status")}${job.optString("error").takeIf { it.isNotBlank() && it != "null" }?.let { " · $it" } ?: ""}")
        }
        action("继续处理 / 重试", row.optInt("stored") == 1) {
            runJob("正在启动处理") { client().startPipeline(id); loadDetails(id) }
        }
    }

    private fun renderLive() {
        heading("设备实时录音")
        detail(liveStatus)
        val options = listOf(2, 5, 10, 20)
        val spinner = Spinner(this)
        spinner.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            options.map { "$it 秒" })
        spinner.setSelection(options.indexOf(config.liveWindowSeconds))
        spinner.isEnabled = !liveRunning
        spinner.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                config.liveWindowSeconds = options[position]
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        content.addView(spinner)
        if (liveRunning) content.addView(Button(this).apply {
            text = "停止接收并保留草稿"; isAllCaps = false; setOnClickListener { device.cancel() }
        })
        else action("实时记录当前录音", status?.recording == 1 && device.currentRecordingId != null) { startLive() }
        action("恢复草稿上传", !liveRunning) {
            runJob("正在恢复实时草稿") {
                live?.close()
                live = LiveController(device, client(), config.origin.trim().trimEnd('/'), File(filesDir, "live")) { liveStatus = it; message(it) }
                val restored = live!!.recoverPending()
                liveStatus = "已恢复 $restored 段；最终归档仍以录音豆完整原件为准"
            }
        }
        if (liveText.isNotBlank()) { heading("实时转写草稿"); detail(liveText) }
    }

    private fun renderSettings() {
        settingsPanels.clear()
        if (settingsSection.isEmpty()) {
            heading("设置")
            detail("管理服务、外观和同步偏好")
            settingsRow("服务连接", if (config.origin.isBlank()) "连接你部署的录音豆服务" else "已设置私有服务", "server")
            settingsRow("外观", "跟随系统、浅色或深色", "appearance")
            settingsRow("应用图标", "白色与黑色录音豆", "icons")
            heading("服务与处理")
            settingsRow("语音转写", "ASR 服务、语言与模型", "asr")
            settingsRow("智能总结", "LLM 接口与模型", "llm")
            settingsRow("飞书文档", "写入身份与保存位置", "feishu")
            settingsRow("处理与传输", "自动上传、屏幕常亮与高级参数", "advanced")
            return
        }
        content.addView(TextView(this).apply {
            text = "返回设置"; textSize = 15f; setTextColor(accentColor()); gravity = android.view.Gravity.CENTER_VERTICAL
            minHeight = dp(48); setOnClickListener { settingsSection = ""; render() }
        })
        settingsHeading("外观", "appearance")
        val themeModes = listOf("system", "light", "dark")
        val theme = Spinner(this)
        theme.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            listOf("跟随系统", "浅色", "深色"))
        theme.setSelection(themeModes.indexOf(config.themeMode))
        theme.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                val chosen = themeModes[position]
                if (chosen != config.themeMode && !busy && !liveRunning) {
                    config.themeMode = chosen
                    recreate()
                }
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        content.addView(theme)
        content.addView(Switch(this).apply {
            text = "前台时保持屏幕常亮"
            isChecked = config.keepAwake
            setOnCheckedChangeListener { _, enabled -> config.keepAwake = enabled; applyKeepAwake() }
        })
        settingsHeading("桌面图标", "icons")
        val iconPreview = ImageView(this).apply {
            setImageResource(if (config.iconColor == "black") R.drawable.recordingbean_icon_black
                else R.drawable.recordingbean_icon)
            adjustViewBounds = true
        }
        val previewSize = (112 * resources.displayMetrics.density).toInt()
        content.addView(iconPreview, LinearLayout.LayoutParams(previewSize, previewSize))
        val iconColors = listOf("white", "black")
        val iconChoice = Spinner(this)
        iconChoice.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            listOf("白色录音豆", "黑色录音豆"))
        iconChoice.setSelection(iconColors.indexOf(config.iconColor))
        iconChoice.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                val color = iconColors[position]
                if (color != config.iconColor) {
                    selectIconColor(color)
                    iconPreview.setImageResource(if (config.iconColor == "black")
                        R.drawable.recordingbean_icon_black else R.drawable.recordingbean_icon)
                }
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        content.addView(iconChoice)
        settingsHeading("服务连接", "server")
        val origin = field("HTTPS 地址", config.origin)
        val token = field("访问口令", config.token(), true)
        action("保存并验证连接") {
            runJob("正在验证服务器") {
                CloudApi(origin.text.toString(), token.text.toString()).recordings()
                config.saveConnection(origin.text.toString(), token.text.toString())
                recordings = client().recordings()
                providerSettings = client().settings()
                settingsLoadAttempted = true
                message("服务器已连接")
            }
        }
        settingsHeading("语音转写", "asr")
        val provider = Spinner(this)
        val providers = listOf("NVIDIA Parakeet 中文", "NVIDIA Whisper", "OpenAI 兼容接口")
        val ids = listOf("nvidia_parakeet", "nvidia_whisper", "openai_compatible")
        provider.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, providers)
        content.addView(provider)
        val values = providerSettings?.optJSONObject("values")
        val configuredSecrets = providerSettings?.optJSONObject("secrets_configured")
        val clearSecrets = linkedSetOf<String>()
        fun clearSecret(key: String, label: String, input: EditText) {
            if (configuredSecrets?.optBoolean(key) != true) return
            content.addView(Switch(this).apply {
                text = label
                setOnCheckedChangeListener { _, checked ->
                    if (checked) { clearSecrets.add(key); input.setText("") }
                    else clearSecrets.remove(key)
                }
            })
        }
        provider.setSelection(ids.indexOf(values?.optString("ASR_PROVIDER", "nvidia_parakeet")).coerceAtLeast(0))
        val asrUrl = field("ASR API 地址（兼容接口）", values?.optString("ASR_BASE_URL") ?: "")
        val asrModel = field("ASR 模型 ID", values?.optString("ASR_MODEL") ?: "")
        val asrLanguage = field("识别语言", values?.optString("ASR_LANGUAGE", "zh-CN") ?: "zh-CN")
        val asrHotwords = field("热词（接口支持时生效）", values?.optString("ASR_HOTWORDS") ?: "")
        val asrResponseFormat = Spinner(this)
        asrResponseFormat.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            listOf("含时间戳", "纯文本 JSON"))
        asrResponseFormat.setSelection(if (values?.optString("ASR_RESPONSE_FORMAT") == "json") 1 else 0)
        content.addView(asrResponseFormat)
        val asrKey = field("ASR API Key（留空保留）", "", true)
        clearSecret("NVIDIA_API_KEY", "清除已保存的 NVIDIA Key", asrKey)
        clearSecret("ASR_API_KEY", "清除已保存的兼容 ASR Key", asrKey)
        var lastAsr = ids[provider.selectedItemPosition]
        provider.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                if (ids[position] != lastAsr) { asrKey.setText(""); lastAsr = ids[position] }
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        settingsHeading("智能总结", "llm")
        val llmUrl = field("LLM API 地址", values?.optString("LLM_BASE_URL") ?: "")
        val llmModel = field("LLM 模型 ID", values?.optString("LLM_MODEL") ?: "")
        val llmKey = field("LLM API Key（留空保留）", "", true)
        clearSecret("LLM_API_KEY", "清除已保存的 LLM Key", llmKey)
        settingsHeading("飞书文档", "feishu")
        val feishuModes = listOf("lark_cli", "app", "user_token")
        val feishuMode = Spinner(this)
        feishuMode.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            listOf("服务器飞书 CLI", "应用凭据", "用户令牌"))
        var lastAuthMode = values?.optString("FEISHU_AUTH_MODE", "lark_cli") ?: "lark_cli"
        feishuMode.setSelection(feishuModes.indexOf(lastAuthMode).coerceAtLeast(0))
        content.addView(feishuMode)
        val cliProfile = field("CLI Profile（可留空）", values?.optString("FEISHU_CLI_PROFILE") ?: "")
        val appId = field("App ID", values?.optString("FEISHU_APP_ID") ?: "")
        val appSecret = field("App Secret（留空保留）", "", true)
        clearSecret("FEISHU_APP_SECRET", "清除已保存的 App Secret", appSecret)
        val userToken = field("用户访问令牌（留空保留）", "", true)
        clearSecret("FEISHU_USER_ACCESS_TOKEN", "清除已保存的用户令牌", userToken)
        val expectedOpenId = field("预期 Open ID", values?.optString("FEISHU_EXPECTED_OPEN_ID") ?: "")
        val folder = field("文件夹 Token（可留空）", values?.optString("FEISHU_FOLDER_TOKEN") ?: "")
        val docsOrigin = field("文档域名", values?.optString("FEISHU_DOCS_ORIGIN") ?: "https://www.feishu.cn")
        val confirmed = Switch(this).apply {
            text = "确认写入这个飞书身份"
            isChecked = values?.optString("FEISHU_PERSONAL_CONFIRMED") == "1"
        }
        content.addView(confirmed)
        val autoPipeline = Switch(this).apply {
            text = "上传后自动转写、总结并写入飞书"
            isChecked = values?.optString("AUTO_PIPELINE") == "1"
        }
        content.addView(autoPipeline)
        settingsHeading("处理与传输", "advanced")
        val asrChunk = field("转写分段时长（10–300 秒）", values?.optString("ASR_CHUNK_SECONDS", "120") ?: "120")
        val maxSpeakers = field("最大说话人数（1–8）", values?.optString("NVIDIA_MAX_SPEAKERS", "8") ?: "8")
        val nvidiaTimeout = field("NVIDIA 超时（10–3600 秒）", values?.optString("NVIDIA_TIMEOUT_SECONDS", "1800") ?: "1800")
        val speakerPolicy = Spinner(this)
        speakerPolicy.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item,
            listOf("说话人 0：未知（保守）", "说话人 0：接受零起始编号"))
        speakerPolicy.setSelection(if (values?.optString("NVIDIA_SPEAKER_ZERO_POLICY") == "zero_based") 1 else 0)
        content.addView(speakerPolicy)
        val documentTimezone = field("文档时区", values?.optString("DOCUMENT_TIMEZONE", "Asia/Shanghai") ?: "Asia/Shanghai")
        feishuMode.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(parent: android.widget.AdapterView<*>?, view: View?, position: Int, id: Long) {
                val mode = feishuModes[position]
                if (mode != lastAuthMode) { confirmed.isChecked = false; lastAuthMode = mode }
            }
            override fun onNothingSelected(parent: android.widget.AdapterView<*>?) {}
        }
        if (config.origin.isNotBlank() && providerSettings == null && !settingsLoadAttempted && !busy) {
            settingsLoadAttempted = true
            runJob("正在读取模型设置") {
            providerSettings = client().settings()
            }
        }
        content = settingsPanels[settingsSection] ?: content
        if (settingsSection in setOf("asr", "llm", "feishu", "advanced")) {
        action("保存服务设置", providerSettings != null) {
            val name = ids[provider.selectedItemPosition]
            val values = JSONObject().put("ASR_PROVIDER", name)
                .put("ASR_BASE_URL", asrUrl.text.toString()).put("ASR_MODEL", asrModel.text.toString())
                .put("ASR_LANGUAGE", asrLanguage.text.toString()).put("ASR_HOTWORDS", asrHotwords.text.toString())
                .put("ASR_RESPONSE_FORMAT", if (asrResponseFormat.selectedItemPosition == 1) "json" else "verbose_json")
                .put("ASR_CHUNK_SECONDS", asrChunk.text.toString())
                .put("NVIDIA_MAX_SPEAKERS", maxSpeakers.text.toString())
                .put("NVIDIA_TIMEOUT_SECONDS", nvidiaTimeout.text.toString())
                .put("NVIDIA_SPEAKER_ZERO_POLICY", if (speakerPolicy.selectedItemPosition == 1) "zero_based" else "unknown")
                .put("LLM_BASE_URL", llmUrl.text.toString()).put("LLM_MODEL", llmModel.text.toString())
                .put("FEISHU_AUTH_MODE", feishuModes[feishuMode.selectedItemPosition])
                .put("FEISHU_CLI_PROFILE", cliProfile.text.toString())
                .put("FEISHU_APP_ID", appId.text.toString())
                .put("FEISHU_EXPECTED_OPEN_ID", expectedOpenId.text.toString())
                .put("FEISHU_FOLDER_TOKEN", folder.text.toString())
                .put("FEISHU_DOCS_ORIGIN", docsOrigin.text.toString())
                .put("FEISHU_PERSONAL_CONFIRMED", if (confirmed.isChecked) "1" else "0")
                .put("AUTO_PIPELINE", if (autoPipeline.isChecked) "1" else "0")
                .put("DOCUMENT_TIMEZONE", documentTimezone.text.toString())
            val activeAsrSecret = if (name == "openai_compatible") "ASR_API_KEY" else "NVIDIA_API_KEY"
            if (asrKey.text.isNotEmpty()) { values.put(activeAsrSecret, asrKey.text.toString()); clearSecrets.remove(activeAsrSecret) }
            if (llmKey.text.isNotEmpty()) { values.put("LLM_API_KEY", llmKey.text.toString()); clearSecrets.remove("LLM_API_KEY") }
            if (appSecret.text.isNotEmpty()) { values.put("FEISHU_APP_SECRET", appSecret.text.toString()); clearSecrets.remove("FEISHU_APP_SECRET") }
            if (userToken.text.isNotEmpty()) { values.put("FEISHU_USER_ACCESS_TOKEN", userToken.text.toString()); clearSecrets.remove("FEISHU_USER_ACCESS_TOKEN") }
            val revision = providerSettings?.getInt("revision") ?: return@action
            val secretsToClear = clearSecrets.toList()
            runJob("正在保存模型设置") {
                val cloud = client()
                providerSettings = cloud.saveSettings(revision, values, secretsToClear)
                message("模型设置已保存")
            }
        }
        action("重新读取服务设置") { runJob("正在读取服务设置") { providerSettings = client().settings() } }
        }
    }

    private fun field(label: String, value: String, secret: Boolean = false): EditText {
        content.addView(TextView(this).apply {
            text = label; textSize = 14f; setTextColor(inkColor()); setTypeface(null, Typeface.BOLD)
            setPadding(0, dp(8), 0, dp(6))
        })
        val input = EditText(this).apply {
            hint = if (secret) "留空保留已保存的密钥" else label
            setText(value); textSize = 15f; isSingleLine = true
            setTextColor(inkColor()); setHintTextColor(mutedColor())
            background = shape(backgroundColor(), 10).apply { setStroke(dp(1), color("#D4DFD9", "#43564C")) }
            setPadding(dp(14), 0, dp(14), 0)
            if (secret) inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        content.addView(input, LinearLayout.LayoutParams(-1, dp(50)).apply { bottomMargin = dp(10) })
        return input
    }
}
