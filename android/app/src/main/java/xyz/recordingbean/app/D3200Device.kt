@file:Suppress("DEPRECATION", "MissingPermission")
package xyz.recordingbean.app

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.bluetooth.BluetoothManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.ParcelUuid
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

data class BeanStatus(val deviceId: String, val battery: Int?, val charging: Boolean?,
                      val caseBattery: Int?, val caseCharging: Boolean?, val recording: Int)
data class LocalAudio(val file: File, val size: Long, val sha256: String)
data class LiveDraftSegment(val index: Int, val frames: Int, val fromSequence: Long, val audio: File)
data class LiveCapture(val audio: File, val fromSequence: Long, val segmentCount: Int)

/** Must be called on a background thread; BLE callbacks are delivered by Android. */
class D3200Device(private val context: Context) : AutoCloseable {
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val frames = ArrayBlockingQueue<BeanFrame>(1024)
    private var bleDecoder = BeanFrameDecoder()
    private var wifiDecoder = BeanFrameDecoder()
    private val fault = AtomicReference<Throwable?>()
    private val crypto = DeviceCrypto()
    private var gatt: BluetoothGatt? = null
    @Volatile private var bleConnected = false
    private var write: BluetoothGattCharacteristic? = null
    private var connected = CountDownLatch(1)
    private var services = CountDownLatch(1)
    private var descriptor = CountDownLatch(1)
    private var mtuReady = CountDownLatch(1)
    private var writeReady: CountDownLatch? = null
    private var mtu = 23
    private var hotspot: DeviceHotspot? = null
    private var fastLink: RecorderSocket? = null
    var status: BeanStatus? = null
        private set
    var onDisconnected: (() -> Unit)? = null
    var currentRecordingId: Long? = null
        private set
    private var batch = false
    @Volatile private var cancelled = false

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (this@D3200Device.gatt != null && gatt !== this@D3200Device.gatt) return
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                bleConnected = false
                if (batch && hotspot != null) return
                fault.compareAndSet(null, IllegalStateException("D3200_DISCONNECTED_$status"))
                this@D3200Device.status = null
                currentRecordingId = null
                onDisconnected?.invoke()
                connected.countDown(); services.countDown(); descriptor.countDown(); mtuReady.countDown()
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                bleConnected = true
                connected.countDown()
                if (!gatt.discoverServices()) fault.compareAndSet(null, IllegalStateException("D3200_SERVICE_START_FAILED"))
            }
        }
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) fault.compareAndSet(null, IllegalStateException("D3200_SERVICE_FAILED_$status"))
            services.countDown()
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) fault.compareAndSet(null, IllegalStateException("D3200_NOTIFY_FAILED_$status"))
            this@D3200Device.descriptor.countDown()
        }
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this@D3200Device.mtu = mtu
            mtuReady.countDown()
        }
        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) fault.compareAndSet(null, IllegalStateException("D3200_WRITE_FAILED_$status"))
            writeReady?.countDown()
        }
        @Deprecated("Android API below 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (gatt !== this@D3200Device.gatt) return
            onNotify(characteristic.uuid, characteristic.value)
        }
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (gatt !== this@D3200Device.gatt) return
            onNotify(characteristic.uuid, value)
        }
    }

    private fun onNotify(uuid: java.util.UUID, value: ByteArray) {
        if (uuid != D3200Protocol.notify) return
        try {
            for (frame in bleDecoder.push(value)) if (!frames.offer(frame)) error("D3200_RECEIVER_OVERFLOW")
        } catch (e: Exception) { fault.compareAndSet(null, e) }
    }

    fun scan(seconds: Long = 5): List<BluetoothDevice> {
        val scanner = manager.adapter.bluetoothLeScanner ?: error("D3200_BLE_DISABLED")
        val found = linkedMapOf<String, BluetoothDevice>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) { synchronized(found) { found[result.device.address] = result.device } }
            override fun onScanFailed(errorCode: Int) { fault.compareAndSet(null, IllegalStateException("D3200_SCAN_FAILED_$errorCode")) }
        }
        fault.set(null)
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(D3200Protocol.service)).build()
        scanner.startScan(listOf(filter), ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        try { Thread.sleep(seconds * 1000); fault.get()?.let { throw it } }
        finally { scanner.stopScan(callback) }
        return synchronized(found) { found.values.toList() }
    }

    fun connect(device: BluetoothDevice): BeanStatus {
        close()
        cancelled = false
        fault.set(null)
        connected = CountDownLatch(1); services = CountDownLatch(1)
        descriptor = CountDownLatch(1); mtuReady = CountDownLatch(1)
        try {
        val client = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        gatt = client ?: error("D3200_CONNECT_START_FAILED")
        await(connected, 15, "D3200_CONNECT_TIMEOUT")
        await(services, 15, "D3200_SERVICE_TIMEOUT")
        val service = client.getService(D3200Protocol.service) ?: error("D3200_SERVICE_NOT_FOUND")
        write = service.getCharacteristic(D3200Protocol.write) ?: error("D3200_WRITE_NOT_FOUND")
        val notify = service.getCharacteristic(D3200Protocol.notify) ?: error("D3200_NOTIFY_NOT_FOUND")
        check(client.setCharacteristicNotification(notify, true)) { "D3200_NOTIFY_START_FAILED" }
        val ccc = notify.getDescriptor(java.util.UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
            ?: error("D3200_CCCD_NOT_FOUND")
        if (Build.VERSION.SDK_INT >= 33) check(client.writeDescriptor(ccc, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS)
        else { ccc.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; check(client.writeDescriptor(ccc)) }
        await(descriptor, 15, "D3200_NOTIFY_TIMEOUT")
        check(client.requestMtu(185)) { "D3200_MTU_REQUEST_FAILED" }
        await(mtuReady, 10, "D3200_MTU_TIMEOUT")
        check(mtu >= 78) { "D3200_MTU_TOO_SMALL_FOR_HANDSHAKE" }
        send(D3200Protocol.command(46, 1, crypto.publicKey()))
        crypto.handshake(next(46, 1).payload)
        return refreshStatus()
        } catch (e: Exception) { close(); throw e }
    }

    fun refreshStatus(): BeanStatus {
        send(D3200Protocol.command(1, 1))
        val payload = next(1, 1).payload
        val serial = D3200Protocol.serial(payload)
        val id = "d3200-sn-" + MessageDigest.getInstance("SHA-256").digest(serial.toByteArray(Charsets.US_ASCII))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        require(status == null || status!!.deviceId == id) { "D3200_STABLE_ID_CHANGED" }
        val result = BeanStatus(id, D3200Protocol.battery(payload.getOrNull(1)?.let(D3200Protocol::unsigned)),
            payload.getOrNull(2)?.let { D3200Protocol.unsigned(it).takeIf { n -> n <= 1 }?.let { n -> n == 1 } },
            D3200Protocol.battery(payload.getOrNull(38)?.let(D3200Protocol::unsigned)),
            payload.getOrNull(32)?.let { D3200Protocol.unsigned(it).takeIf { n -> n <= 1 }?.let { n -> n == 1 } },
            D3200Protocol.recordingState(payload))
        status = result
        return result
    }

    fun list(): List<DeviceFile> {
        val all = mutableListOf<DeviceFile>()
        currentRecordingId = null
        repeat(4096) { page ->
            send(D3200Protocol.command(26, 14, D3200Protocol.le(page.toLong(), 2)))
            val payload = next(26, 14).payload
            val batch = D3200Protocol.files(payload)
            if (page == 0 && payload.size >= 2 + batch.size * 8 + 8) {
                currentRecordingId = D3200Protocol.u32(payload, 2 + batch.size * 8).takeIf { it != 0L }
            }
            if (batch.isEmpty()) return all
            require(batch.none { file -> all.any { it.id == file.id } }) { "D3200_REPEATED_LIST_PAGE" }
            all += batch
        }
        error("D3200_LIST_LIMIT")
    }

    fun beginBatch() {
        cancelled = false
        check(!batch) { "SYNC_ALREADY_RUNNING" }
        check(refreshStatus().recording != 1) { "D3200_RECORDING_NOT_FINALIZED" }
        batch = true
    }

    fun download(file: DeviceFile, cacheDirectory: File, progress: (Long, Long) -> Unit): LocalAudio {
        check(batch && status != null) { "D3200_BATCH_REQUIRED" }
        if (fastLink == null) check(refreshStatus().recording != 1) { "D3200_RECORDING_NOT_FINALIZED" }
        cacheDirectory.mkdirs()
        if (fastLink == null) {
            val hotspot = DeviceHotspot(context)
            this.hotspot = hotspot
            send(D3200Protocol.command(26, 5, hotspot.credentials()))
            val endpoint = next(26, 5).payload
            val network = hotspot.join()
            val deadline = System.currentTimeMillis() + 45_000
            var link: RecorderSocket? = null
            while (link == null) {
                if (cancelled) error("SYNC_CANCELLED")
                val candidate = RecorderSocket(network)
                try { candidate.connect(endpoint); link = candidate }
                catch (e: Exception) {
                    candidate.close()
                    val pinRejected = generateSequence<Throwable>(e) { it.cause }
                        .any { it.message?.contains("CERT_PIN_MISMATCH") == true || it.message?.contains("CERT_MISSING") == true }
                    if (System.currentTimeMillis() >= deadline || pinRejected) throw e
                    Thread.sleep(700)
                }
            }
            fastLink = link
        }
        val partial = File(cacheDirectory, "${file.id}-${System.currentTimeMillis()}.ogg.partial")
        var framesReceived = 0L
        var pending: ByteArray? = null
        try {
            fastLink!!.request(file.id)
            val head = next(26, 7)
            require(D3200Protocol.u32(head.payload, 0) == file.id) { "D3200_FILE_ID_MISMATCH" }
            // The list count is only a preview; the file header declares the exact wire length.
            val total = D3200Protocol.offlineSize(D3200Protocol.u32(head.payload, 4))
            if (file.durationMs * 83 / 10 != total) Log.i("RecordingBeanDevice", "list duration ms=${file.durationMs}, header bytes=$total")
            val free = cacheDirectory.usableSpace
            check(free >= total * 3 + 64L * 1024 * 1024) { "PHONE_INSUFFICIENT_STORAGE" }
            crypto.openFile(head.payload)
            FileOutputStream(partial).use { stream ->
                stream.write(D3200Protocol.opusHeaders())
                while (true) {
                    val frame = next(26, -1)
                    if (frame.command == 10) break
                    if (frame.command != 8 && frame.command != 18) continue
                    val slices = D3200Protocol.slices(frame.payload)
                    require(slices.first().sequence == framesReceived) { "D3200_SEQUENCE_GAP_OR_DUPLICATE" }
                    for (group in slices.chunked(400)) {
                        val plain = crypto.decryptBatch(group)
                        group.forEachIndexed { index, _ ->
                            val clear = plain.copyOfRange(index * 160, (index + 1) * 160)
                            pending?.let { stream.write(D3200Protocol.oggPage(it, framesReceived + 1, framesReceived * 960, 0)) }
                            pending = clear
                            framesReceived++
                            progress(framesReceived * 166, total)
                            require(framesReceived * 166 <= total) { "D3200_SIZE_PROFILE_MISMATCH" }
                        }
                    }
                }
                require(pending != null && framesReceived * 166 == total) { "D3200_INCOMPLETE_TRANSFER" }
                stream.write(D3200Protocol.oggPage(pending!!, framesReceived + 1, framesReceived * 960, 4))
                stream.fd.sync()
            }
            val ready = File(partial.path.removeSuffix(".partial"))
            check(partial.renameTo(ready)) { "D3200_CACHE_RENAME_FAILED" }
            val hash = MessageDigest.getInstance("SHA-256")
            ready.inputStream().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
            }
            return LocalAudio(ready, ready.length(), hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
        } catch (e: Exception) {
            // Keep partial data for diagnosis. Never claim it as verified audio.
            throw e
        }
    }

    fun captureRealtime(fileId: Long, cacheDirectory: File, windowSeconds: Int,
                        onSegment: (LiveDraftSegment) -> Unit): LiveCapture {
        require(windowSeconds in listOf(2, 5, 10, 20) && currentRecordingId == fileId) { "D3200_NO_ACTIVE_RECORDING" }
        check(refreshStatus().recording == 1 && fastLink == null) { "D3200_NO_ACTIVE_RECORDING" }
        check(cacheDirectory.mkdirs() || cacheDirectory.isDirectory) { "CACHE_DIRECTORY_UNAVAILABLE" }
        cancelled = false
        frames.clear()
        val partial = File(cacheDirectory, "$fileId-live-${System.currentTimeMillis()}.ogg.partial")
        var count = 0L
        var index = 0
        var fromSequence: Long? = null
        var pending: ByteArray? = null
        val window = ArrayList<ByteArray>(windowSeconds * 50)
        try {
            val request = D3200Protocol.le(0) + D3200Protocol.le(fileId) + byteArrayOf(1)
            send(D3200Protocol.command(26, 7, request))
            val header = next(26, 7)
            require(D3200Protocol.u32(header.payload, 0) == fileId) { "D3200_LIVE_FILE_CHANGED" }
            crypto.openFile(header.payload)
            FileOutputStream(partial).use { stream ->
                stream.write(D3200Protocol.opusHeaders())
                fun saveWindow() {
                    val start = fromSequence ?: error("D3200_LIVE_SEQUENCE_MISSING")
                    stream.fd.sync()
                    val bytes = D3200Protocol.liveWindow(window)
                    require(bytes.size <= 1_048_576) { "LIVE_WINDOW_TOO_LARGE" }
                    val file = File(cacheDirectory, "${partial.name}-window-$index.ogg")
                    val temp = File(cacheDirectory, "${file.name}.partial")
                    FileOutputStream(temp).use { out -> out.write(bytes); out.fd.sync() }
                    check(temp.renameTo(file)) { "LIVE_WINDOW_CACHE_RENAME_FAILED" }
                    onSegment(LiveDraftSegment(index, window.size, start, file))
                    window.clear()
                    index++
                }
                while (true) {
                    if (cancelled) error("SYNC_CANCELLED")
                    val frame = next(26, -1)
                    if (frame.command == 10) break
                    if (frame.command == 6 || frame.command == 7) error("D3200_LIVE_FILE_CHANGED")
                    if (frame.command != 8 && frame.command != 18) continue
                    for (slice in D3200Protocol.slices(frame.payload)) {
                        if (fromSequence == null) fromSequence = slice.sequence
                        require(slice.sequence == fromSequence!! + count) { "D3200_SEQUENCE_GAP_OR_DUPLICATE" }
                        val clear = crypto.decrypt(slice.sequence, slice.encrypted)
                        pending?.let { stream.write(D3200Protocol.oggPage(it, count + 1, count * 960, 0)) }
                        pending = clear
                        count++
                        window.add(clear)
                        if (window.size == windowSeconds * 50) saveWindow()
                    }
                }
                val finalPacket = pending ?: error("D3200_EMPTY_LIVE_CAPTURE")
                stream.write(D3200Protocol.oggPage(finalPacket, count + 1, count * 960, 4))
                stream.fd.sync()
                if (window.isNotEmpty()) saveWindow()
            }
            val ready = File(partial.path.removeSuffix(".partial"))
            check(partial.renameTo(ready)) { "D3200_CACHE_RENAME_FAILED" }
            return LiveCapture(ready, fromSequence ?: error("D3200_LIVE_SEQUENCE_MISSING"), index)
        } catch (e: Exception) {
            // Interrupted audio remains incomplete and must never be uploaded as a full recording.
            throw e
        }
    }

    fun cancel() { cancelled = true }

    fun endBatch() {
        val hadHotspot = fastLink != null || hotspot != null
        fastLink?.close(); fastLink = null
        hotspot?.close(); hotspot = null
        wifiDecoder = BeanFrameDecoder()
        batch = false
        if (hadHotspot && bleConnected) runCatching { send(D3200Protocol.command(26, 2)) }
        if (hadHotspot && !bleConnected) {
            status = null
            currentRecordingId = null
            onDisconnected?.invoke()
        }
    }

    fun awaitInternet() {
        val until = System.currentTimeMillis() + 45_000
        while (System.currentTimeMillis() < until) {
            val active = connectivity.activeNetwork
            val capabilities = active?.let { connectivity.getNetworkCapabilities(it) }
            if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) return
            Thread.sleep(500)
        }
        error("RESTORE_INTERNET_REQUIRED_RETRY_FROM_CACHE")
    }

    private fun send(bytes: ByteArray) {
        check(bleConnected) { "D3200_NOT_CONNECTED" }
        val gatt = gatt ?: error("D3200_NOT_CONNECTED")
        val characteristic = write ?: error("D3200_WRITE_NOT_FOUND")
        require(bytes.size <= mtu - 3) { "D3200_FRAME_EXCEEDS_MTU" }
        val latch = CountDownLatch(1)
        writeReady = latch
        try {
            if (Build.VERSION.SDK_INT >= 33) check(gatt.writeCharacteristic(characteristic, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS)
            else { characteristic.value = bytes; check(gatt.writeCharacteristic(characteristic)) }
            await(latch, 15, "D3200_WRITE_TIMEOUT")
        } finally { writeReady = null }
    }

    private fun next(type: Int, id: Int): BeanFrame {
        val until = System.currentTimeMillis() + 90_000
        while (System.currentTimeMillis() < until) {
            if (cancelled) error("SYNC_CANCELLED")
            fault.get()?.let { throw it }
            val frame = frames.poll()
            if (frame != null) {
                if ((type < 0 || frame.type == type) && (id < 0 || frame.command == id)) {
                    require(frame.accepted) { "D3200_COMMAND_REJECTED" }
                    return frame
                }
                continue
            }
            if (fastLink != null) fastLink!!.nextPayload().asList().chunked(16 * 1024).forEach { chunk ->
                wifiDecoder.push(chunk.toByteArray()).forEach { check(frames.offer(it)) { "D3200_RECEIVER_OVERFLOW" } }
            }
            else Thread.sleep(10)
        }
        error("D3200_RECEIVE_TIMEOUT")
    }

    private fun await(latch: CountDownLatch, seconds: Long, code: String) {
        check(latch.await(seconds, TimeUnit.SECONDS)) { code }
        fault.get()?.let { throw it }
    }

    override fun close() {
        cancelled = true
        endBatch()
        crypto.clear()
        gatt?.disconnect(); gatt?.close(); gatt = null
        bleConnected = false
        write = null; status = null; frames.clear(); fault.set(null)
        bleDecoder = BeanFrameDecoder()
        wifiDecoder = BeanFrameDecoder()
        currentRecordingId = null
    }
}
