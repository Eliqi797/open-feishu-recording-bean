package xyz.recordingbean.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.util.Log
import java.security.SecureRandom
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One consented Wi-Fi association is retained for the whole D3200 download batch. */
class DeviceHotspot(context: Context) : AutoCloseable {
    private val tag = "RecordingBeanWifi"
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val random = ByteArray(16).also { SecureRandom().nextBytes(it) }
    val ssid = "Bean-" + random.copyOfRange(0, 4).hex()
    private val password = random.copyOfRange(4, 16).hex()
    private var callback: ConnectivityManager.NetworkCallback? = null
    var network: Network? = null
        private set

    fun credentials(): ByteArray {
        val name = ssid.toByteArray(Charsets.US_ASCII)
        val pass = password.toByteArray(Charsets.US_ASCII)
        return byteArrayOf(name.size.toByte()) + name + byteArrayOf(pass.size.toByte()) + pass
    }

    fun join(): Network {
        check(callback == null) { "D3200_WIFI_ALREADY_REQUESTED" }
        val request = try {
            val wifi = WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(password).build()
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(wifi).build()
        } catch (e: Exception) {
            Log.e(tag, "build request: ${e.javaClass.simpleName}: ${redact(e.message)}")
            throw IllegalStateException("D3200_WIFI_REQUEST_BUILD_${e.javaClass.simpleName}", e)
        }
        val ready = CountDownLatch(1)
        var failure = "D3200_WIFI_JOIN_TIMEOUT"
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(value: Network) {
                Log.i(tag, "local Wi-Fi available")
                network = value; ready.countDown()
            }
            override fun onUnavailable() {
                Log.w(tag, "local Wi-Fi unavailable")
                failure = "D3200_WIFI_UNAVAILABLE"; ready.countDown()
            }
            override fun onLost(value: Network) {
                Log.w(tag, "local Wi-Fi lost")
                if (network == value) network = null
            }
        }
        callback = cb
        try {
            try {
                manager.requestNetwork(request, cb, 45_000)
                Log.i(tag, "local Wi-Fi requested")
            } catch (e: Exception) {
                Log.e(tag, "requestNetwork: ${e.javaClass.simpleName}: ${redact(e.message)}")
                throw IllegalStateException("D3200_WIFI_REQUEST_${e.javaClass.simpleName}", e)
            }
            check(ready.await(50, TimeUnit.SECONDS) && network != null) { failure }
            return network!!
        } catch (e: Exception) { close(); throw e }
    }

    private fun redact(value: String?): String = (value ?: "")
        .replace(ssid, "<device hotspot>").replace(password, "<redacted>")

    override fun close() {
        callback?.let { runCatching { manager.unregisterNetworkCallback(it) } }
        callback = null
        network = null
        random.fill(0)
    }

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 255) }
}
