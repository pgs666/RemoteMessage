package com.remotemessage.gateway

import android.content.Context
import android.provider.Telephony
import android.telephony.SmsManager
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
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
    private var db: GatewayLocalDb? = null
    private const val PREF = "gateway_crypto"
    private const val KEY_PUBLIC = "public_key"
    private const val KEY_PRIVATE = "private_key"

    private fun getDb(context: Context): GatewayLocalDb {
        if (db == null) {
            db = GatewayLocalDb(context.applicationContext)
        }
        return db!!
    }

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
                        flushPendingUploads(context, cfg)
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
                    flushPendingUploads(context, cfg)
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
        timestamp: Long,
        direction: String = "inbound",
        messageId: String? = null
    ) {
        getDb(context).enqueueUpload(phone, content, timestamp, direction, messageId)
        thread {
            runCatching {
                flushPendingUploads(context, cfg)
            }
        }
    }

    fun flushPendingUploads(context: Context, cfg: GatewayConfig) {
        val local = getDb(context)
        val pending = local.listPending(200)
        pending.forEach { item ->
            runCatching {
                uploadInboundSmsSync(
                    cfg = cfg,
                    phone = item.phone,
                    content = item.content,
                    timestamp = item.timestamp,
                    direction = item.direction,
                    messageId = item.messageId
                )
                local.deletePending(item.id)
            }
        }
    }

    fun syncHistoricalSms(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                val uri = Telephony.Sms.CONTENT_URI
                val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE)
                val cursor = context.contentResolver.query(uri, projection, null, null, "${Telephony.Sms.DATE} ASC")
                    ?: error("query sms failed")

                var count = 0
                cursor.use {
                    val idIdx = it.getColumnIndexOrThrow(Telephony.Sms._ID)
                    val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                    val bodyIdx = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
                    val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
                    val typeIdx = it.getColumnIndexOrThrow(Telephony.Sms.TYPE)

                    while (it.moveToNext()) {
                        val smsId = it.getString(idIdx) ?: continue
                        val phone = it.getString(addressIdx) ?: "unknown"
                        val content = it.getString(bodyIdx) ?: ""
                        val timestamp = it.getLong(dateIdx)
                        val type = it.getInt(typeIdx)
                        val direction = if (type == Telephony.Sms.MESSAGE_TYPE_SENT) "outbound" else "inbound"
                        uploadInboundSmsSync(
                            cfg = cfg,
                            phone = phone,
                            content = content,
                            timestamp = timestamp,
                            direction = direction,
                            messageId = "sms-$smsId"
                        )
                        count++
                    }
                }
                callback("History sync started: $count messages")
            }.onFailure {
                callback("History sync error: ${it.message}")
            }
        }
    }

    fun buildMessageId(deviceId: String, phone: String, content: String, timestamp: Long, direction: String): String {
        val raw = "$deviceId|$phone|$timestamp|$direction|$content"
        val hash = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        return hash.take(12).joinToString("") { "%02x".format(it) }
    }

    private fun uploadInboundSmsSync(
        cfg: GatewayConfig,
        phone: String,
        content: String,
        timestamp: Long,
        direction: String,
        messageId: String?
    ) {
        val serverPublicPem = fetchServerPublicKey(cfg)

        val payload = JSONObject()
            .put("phone", phone)
            .put("content", content)
            .put("timestamp", timestamp)
            .put("direction", direction)
        if (!messageId.isNullOrBlank()) {
            payload.put("messageId", messageId)
        }
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

    private fun fetchServerPublicKey(cfg: GatewayConfig): String {
        val serverKeyReq = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/crypto/server-public-key")
            .get()
            .build()
        return client.newCall(serverKeyReq).execute().use {
            val body = it.body?.string() ?: error("empty body")
            JSONObject(body).getString("publicKey")
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
