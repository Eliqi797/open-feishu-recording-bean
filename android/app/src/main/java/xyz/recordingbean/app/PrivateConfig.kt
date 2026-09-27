package xyz.recordingbean.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Cloud bearer token is bound to this app install and never backed up or committed. */
class PrivateConfig(context: Context) {
    private val preferences = context.getSharedPreferences("recordingbean-private", Context.MODE_PRIVATE)
    private val alias = "recordingbean-cloud-access"
    private fun decoded(value: String): String = try {
        Base64.decode(value, Base64.NO_WRAP).toString(Charsets.UTF_8)
    } catch (_: Exception) { "" }
    init {
        if (!preferences.contains("token")) {
            val origin = decoded(BuildConfig.PERSONAL_ORIGIN_BASE64)
            val token = decoded(BuildConfig.PERSONAL_TOKEN_BASE64)
            if (origin.isNotBlank() && token.isNotBlank()) saveConnection(origin, token)
        }
    }
    var origin: String
        get() = preferences.getString("origin", "") ?: ""
        private set(value) { preferences.edit().putString("origin", value).apply() }
    var autoUpload: Boolean
        get() = preferences.getBoolean("autoUpload", true)
        set(value) { preferences.edit().putBoolean("autoUpload", value).apply() }
    var keepAwake: Boolean
        get() = preferences.getBoolean("keepAwake", false)
        set(value) { preferences.edit().putBoolean("keepAwake", value).apply() }
    var themeMode: String
        get() = preferences.getString("themeMode", "system")?.takeIf { it in setOf("system", "light", "dark") } ?: "system"
        set(value) {
            require(value in setOf("system", "light", "dark"))
            preferences.edit().putString("themeMode", value).apply()
        }
    var iconColor: String
        get() = preferences.getString("iconColor", "white")?.takeIf { it in setOf("white", "black") } ?: "white"
        set(value) {
            require(value in setOf("white", "black"))
            preferences.edit().putString("iconColor", value).apply()
        }
    var liveWindowSeconds: Int
        get() = preferences.getInt("liveWindowSeconds", 5).takeIf { it in listOf(2,5,10,20) } ?: 5
        set(value) {
            require(value in listOf(2,5,10,20))
            preferences.edit().putInt("liveWindowSeconds", value).apply()
        }

    fun token(): String {
        val saved = preferences.getString("token", null) ?: return ""
        return try {
            val bytes = Base64.decode(saved, Base64.NO_WRAP)
            require(bytes.size > 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
        } catch (_: Exception) { "" }
    }

    fun saveConnection(origin: String, token: String) {
        CloudApi(origin, token)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        preferences.edit().putString("origin", origin).putString("token", Base64.encodeToString(encrypted, Base64.NO_WRAP)).apply()
    }

    private fun key(): SecretKey {
        val storage = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (storage.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val parameters = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(false).build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply { init(parameters) }.generateKey()
    }
}
