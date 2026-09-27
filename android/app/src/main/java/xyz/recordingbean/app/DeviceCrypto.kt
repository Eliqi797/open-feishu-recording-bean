package xyz.recordingbean.app

import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class DeviceCrypto {
    private var pair: KeyPair? = null
    private var session = byteArrayOf()
    private var fileKey = byteArrayOf()
    private var nonce = byteArrayOf()

    fun publicKey(): ByteArray {
        clear()
        pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), SecureRandom()) }.generateKeyPair()
        val point = (pair!!.public as ECPublicKey).w
        return byteArrayOf(4) + point.affineX.fixed32() + point.affineY.fixed32()
    }

    fun handshake(payload: ByteArray) {
        val local = pair ?: error("D3200_HANDSHAKE_INVALID")
        require(payload.size >= 97 && payload[0].toInt() == 4) { "D3200_HANDSHAKE_INVALID" }
        val spec = (local.public as ECPublicKey).params
        val point = ECPoint(BigInteger(1, payload.copyOfRange(1, 33)), BigInteger(1, payload.copyOfRange(33, 65)))
        val peer = java.security.KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(point, spec))
        val secret = KeyAgreement.getInstance("ECDH").apply { init(local.private); doPhase(peer, true) }.generateSecret()
        try {
            require(secret.size == 32 && MessageDigest.isEqual(secret, payload.copyOfRange(65, 97))) { "D3200_SHARED_SECRET_MISMATCH" }
            session = hmac(hmac(byteArrayOf(1,2,3), secret), byteArrayOf(1,2,3,1))
            pair = null
        } finally { secret.fill(0) }
    }

    fun openFile(header: ByteArray) {
        require(session.size == 32 && header.size >= 87) { "D3200_FILE_KEY_MISSING" }
        require(header[86].toInt() == 0 || D3200Protocol.unsigned(header[86]) == 255) { "D3200_FILE_UNAVAILABLE" }
        val plain = aesCTR(session, header.copyOfRange(70, 86), header.copyOfRange(24, 70))
        try {
            val magic = "soundcored3200".toByteArray(Charsets.US_ASCII)
            require(plain.size == magic.size + 32 && plain.copyOfRange(0, magic.size).contentEquals(magic)) { "D3200_FILE_KEY_INVALID" }
            fileKey.fill(0)
            fileKey = plain.copyOfRange(magic.size, plain.size)
            nonce = header.copyOfRange(8, 24)
        } finally { plain.fill(0) }
    }

    fun decrypt(sequence: Long, encrypted: ByteArray): ByteArray {
        require(fileKey.size == 32 && encrypted.size == 160) { "D3200_FILE_KEY_MISSING" }
        return aesCTR(fileKey, D3200Protocol.counter(nonce, sequence), encrypted)
    }

    fun decryptBatch(slices: List<AudioSlice>): ByteArray {
        require(fileKey.size == 32 && slices.size in 1..400) { "D3200_DECRYPT_BATCH_INVALID" }
        val start = slices.first().sequence
        D3200Protocol.counter(nonce, start + slices.size - 1)
        val encrypted = ByteArray(slices.size * 160)
        slices.forEachIndexed { i, slice ->
            require(slice.sequence == start + i && slice.encrypted.size == 160) { "D3200_SEQUENCE_GAP_OR_DUPLICATE" }
            slice.encrypted.copyInto(encrypted, i * 160)
        }
        return aesCTR(fileKey, D3200Protocol.counter(nonce, start), encrypted)
    }

    fun clear() {
        session.fill(0); fileKey.fill(0); nonce.fill(0)
        session = byteArrayOf(); fileKey = byteArrayOf(); nonce = byteArrayOf(); pair = null
    }

    private fun BigInteger.fixed32(): ByteArray = toByteArray().let { bytes ->
        require(bytes.size <= 33)
        bytes.takeLast(32).toByteArray().let { ByteArray(32 - it.size) + it }
    }
    private fun hmac(key: ByteArray, value: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run {
        init(SecretKeySpec(key, "HmacSHA256")); doFinal(value)
    }
    private fun aesCTR(key: ByteArray, iv: ByteArray, bytes: ByteArray): ByteArray = Cipher.getInstance("AES/CTR/NoPadding").run {
        init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv)); doFinal(bytes)
    }
}
