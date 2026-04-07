package com.remotemessage.gateway

import android.content.Context
import android.telephony.SmsManager
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import kotlin.concurrent.thread

data class GatewayConfig(
    val serverBaseUrl: String,
    val deviceId: String
)

object GatewayRuntime {
    private val client = OkHttpClient()
    private const val PREF = "gateway_crypto"
    private const val KEY_PUBLIC = "public_key"
    private const val KEY_PRIVATE = "private_key"

    fun registerGateway(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                val (pubPem, _) = getOrCreateKeyPairPem(context)
                val bodyJson = JSONObject()
                    .put("deviceId", cfg.deviceId)
                    .put("publicKeyPem", pubPem)
                val req = Request.Builder()
                    .url("${cfg.serverBaseUrl}/api/gateway/register")
                    .post(bodyJson.toString().toRequestBody("application/json".toMediaType()))
                    .build()
                client.newCall(req).execute().use {
                    if (!it.isSuccessful) error("register failed: ${it.code}")
                }
            }.onSuccess {
                callback("Gateway registered")
            }.onFailure {
                callback("Register error: ${it.message}")
            }
        }
    }

    fun pollAndSend(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                val (_, privatePem) = getOrCreateKeyPairPem(context)
                val req = Request.Builder()
                    .url("${cfg.serverBaseUrl}/api/gateway/pull?deviceId=${cfg.deviceId}")
                    .get()
                    .build()
                client.newCall(req).execute().use { resp ->
                    if (resp.code == 204) {
                        callback("No pending message")
                        return@thread
                    }
                    if (!resp.isSuccessful) error("pull failed: ${resp.code}")
                    val body = resp.body?.string() ?: error("empty body")
                    val json = JSONObject(body)
                    val encrypted = json.getString("encryptedPayloadBase64")
                    val plain = decryptWithPrivateKey(privatePem, encrypted)
                    val payload = JSONObject(plain)
                    val phone = payload.getString("targetPhone")
                    val text = payload.getString("content")
                    SmsManager.getDefault().sendTextMessage(phone, null, text, null, null)
                    callback("SMS sent to $phone")
                }
            }.onFailure {
                callback("Poll error: ${it.message}")
            }
        }
    }

    fun uploadInboundSms(
        context: Context,
        cfg: GatewayConfig,
        phone: String,
        content: String,
        timestamp: Long
    ) {
        thread {
            runCatching {
                val serverKeyReq = Request.Builder()
                    .url("${cfg.serverBaseUrl}/api/crypto/server-public-key")
                    .get()
                    .build()
                val serverPublicPem = client.newCall(serverKeyReq).execute().use {
                    val body = it.body?.string() ?: error("empty body")
                    JSONObject(body).getString("publicKey")
                }

                val payload = JSONObject()
                    .put("phone", phone)
                    .put("content", content)
                    .put("timestamp", timestamp)
                val encrypted = encryptByPublicKey(serverPublicPem, payload.toString())
                val up = JSONObject()
                    .put("deviceId", cfg.deviceId)
                    .put("encryptedPayloadBase64", encrypted)

                val req = Request.Builder()
                    .url("${cfg.serverBaseUrl}/api/gateway/sms/upload")
                    .post(up.toString().toRequestBody("application/json".toMediaType()))
                    .build()
                client.newCall(req).execute().close()
            }
        }
    }

    private fun getOrCreateKeyPairPem(context: Context): Pair<String, String> {
        val pref = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val pub = pref.getString(KEY_PUBLIC, null)
        val pri = pref.getString(KEY_PRIVATE, null)
        if (!pub.isNullOrBlank() && !pri.isNullOrBlank()) {
            return pub to pri
        }

        val kpg = KeyPairGenerator.getInstance("RSA")
        kpg.initialize(2048)
        val pair = kpg.generateKeyPair()
        val pubPem = toPem("PUBLIC KEY", pair.public.encoded)
        val priPem = toPem("PRIVATE KEY", pair.private.encoded)
        pref.edit().putString(KEY_PUBLIC, pubPem).putString(KEY_PRIVATE, priPem).apply()
        return pubPem to priPem
    }

    private fun encryptByPublicKey(publicPem: String, plain: String): String {
        val key = loadPublicKey(publicPem)
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return Base64.getEncoder().encodeToString(cipher.doFinal(plain.toByteArray(Charsets.UTF_8)))
    }

    private fun decryptWithPrivateKey(privatePem: String, encryptedBase64: String): String {
        val key = loadPrivateKey(privatePem)
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(Cipher.DECRYPT_MODE, key)
        val plain = cipher.doFinal(Base64.getDecoder().decode(encryptedBase64))
        return plain.toString(Charsets.UTF_8)
    }

    private fun loadPublicKey(publicPem: String): PublicKey {
        val bytes = Base64.getDecoder().decode(publicPem.pemBody())
        val spec = X509EncodedKeySpec(bytes)
        return KeyFactory.getInstance("RSA").generatePublic(spec)
    }

    private fun loadPrivateKey(privatePem: String): PrivateKey {
        val bytes = Base64.getDecoder().decode(privatePem.pemBody())
        val spec = PKCS8EncodedKeySpec(bytes)
        return KeyFactory.getInstance("RSA").generatePrivate(spec)
    }

    private fun toPem(title: String, raw: ByteArray): String {
        val b64 = Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(raw)
        return "-----BEGIN $title-----\n$b64\n-----END $title-----"
    }

    private fun String.pemBody(): String {
        return this
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("-----BEGIN PRIVATE KEY-----", "")
            .replace("-----END PRIVATE KEY-----", "")
            .replace("\n", "")
            .trim()
    }
}
