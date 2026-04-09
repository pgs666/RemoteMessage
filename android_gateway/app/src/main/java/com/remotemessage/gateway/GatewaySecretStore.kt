package com.remotemessage.gateway

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object GatewaySecretStore {
    private const val PREF_NAME = "gateway_config"
    private const val LEGACY_PASSWORD_KEY = "password"
    private const val LEGACY_API_KEY_KEY = "api_key"
    private const val ENCRYPTED_PASSWORD_KEY = "password_encrypted_v1"
    private const val KEY_ALIAS = "remotemessage_gateway_secret_v1"

    private const val AES_MODE = "AES/GCM/NoPadding"
    private const val GCM_TAG_LENGTH_BITS = 128
    private const val IV_LENGTH_BYTES = 12

    fun loadPassword(context: Context): String? {
        val appContext = context.applicationContext
        val prefs = appContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        migrateLegacyPassword(appContext, prefs)

        val encrypted = prefs.getString(ENCRYPTED_PASSWORD_KEY, null)?.trim()
        if (!encrypted.isNullOrEmpty()) {
            runCatching { decrypt(encrypted) }
                .onSuccess { plain ->
                    val normalized = plain.trim()
                    if (normalized.isNotEmpty()) {
                        return normalized
                    }
                }
                .onFailure {
                    GatewayDebugLog.add(appContext, "Secure password decrypt failed: ${it.message}")
                }
        }

        return prefs.getString(LEGACY_PASSWORD_KEY, prefs.getString(LEGACY_API_KEY_KEY, ""))
            ?.trim()
            ?.ifEmpty { null }
    }

    fun savePassword(context: Context, password: String?) {
        val appContext = context.applicationContext
        val prefs = appContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val normalized = password?.trim().orEmpty()

        if (normalized.isEmpty()) {
            prefs.edit()
                .remove(ENCRYPTED_PASSWORD_KEY)
                .remove(LEGACY_PASSWORD_KEY)
                .remove(LEGACY_API_KEY_KEY)
                .apply()
            return
        }

        runCatching {
            val encrypted = encrypt(normalized)
            prefs.edit()
                .putString(ENCRYPTED_PASSWORD_KEY, encrypted)
                .remove(LEGACY_PASSWORD_KEY)
                .remove(LEGACY_API_KEY_KEY)
                .apply()
        }.onFailure {
            // Last-resort fallback keeps old behavior if keystore fails unexpectedly.
            GatewayDebugLog.add(appContext, "Secure password save fallback to legacy storage: ${it.message}")
            prefs.edit()
                .putString(LEGACY_PASSWORD_KEY, normalized)
                .remove(LEGACY_API_KEY_KEY)
                .apply()
        }
    }

    private fun migrateLegacyPassword(context: Context, prefs: android.content.SharedPreferences) {
        val encrypted = prefs.getString(ENCRYPTED_PASSWORD_KEY, null)?.trim()
        if (!encrypted.isNullOrEmpty()) {
            if (prefs.contains(LEGACY_API_KEY_KEY)) {
                prefs.edit().remove(LEGACY_API_KEY_KEY).apply()
            }
            return
        }

        val legacy = prefs.getString(LEGACY_PASSWORD_KEY, prefs.getString(LEGACY_API_KEY_KEY, ""))
            ?.trim()
            .orEmpty()
        if (legacy.isEmpty()) {
            return
        }

        savePassword(context, legacy)
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(false)
            .build()
        generator.init(spec)
        return generator.generateKey()
    }

    private fun encrypt(plain: String): String {
        val key = getOrCreateSecretKey()
        val cipher = Cipher.getInstance(AES_MODE)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        require(iv.size == IV_LENGTH_BYTES) { "unexpected iv length" }
        val encrypted = cipher.doFinal(plain.toByteArray(StandardCharsets.UTF_8))
        val combined = ByteArray(iv.size + encrypted.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(encrypted, 0, combined, iv.size, encrypted.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(base64: String): String {
        val key = getOrCreateSecretKey()
        val combined = Base64.decode(base64, Base64.DEFAULT)
        require(combined.size > IV_LENGTH_BYTES) { "invalid payload" }
        val iv = combined.copyOfRange(0, IV_LENGTH_BYTES)
        val cipherBytes = combined.copyOfRange(IV_LENGTH_BYTES, combined.size)
        val cipher = Cipher.getInstance(AES_MODE)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        val plain = cipher.doFinal(cipherBytes)
        return String(plain, StandardCharsets.UTF_8)
    }
}
