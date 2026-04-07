package com.remotemessage.gateway

import android.content.Context
import java.io.ByteArrayOutputStream
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.telephony.SmsManager
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.KeyStore
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Security
import java.security.interfaces.RSAKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.security.cert.CertificateFactory
import java.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

data class GatewayConfig(
    val serverBaseUrl: String,
    val deviceId: String,
    val simSubId: Int? = null
)

data class LocalSmsStats(
    val total: Int,
    val inbound: Int,
    val outbound: Int,
    val oldestTimestamp: Long?,
    val latestTimestamp: Long?
)

object GatewayRuntime {
    private var db: GatewayLocalDb? = null
    private const val PREF = "gateway_crypto"
    private const val KEY_PUBLIC = "public_key"
    private const val KEY_PRIVATE = "private_key"
    private const val KEYSTORE_ALIAS = "remote_message_gateway_rsa"
    private const val HISTORY_LAST_SYNC_TS_KEY = "history_last_sync_ts"
    private const val SERVER_PUBLIC_KEY_CACHE_MS = 10 * 60 * 1000L

    @Volatile
    private var cachedServerPublicPem: String? = null

    @Volatile
    private var cachedServerBaseUrl: String? = null

    @Volatile
    private var cachedServerPublicPemAt: Long = 0L

    private val flushLock = Any()

    @Volatile
    private var flushInProgress = false

    private val historySyncInProgress = AtomicBoolean(false)
    private val httpClientLock = Any()

    @Volatile
    private var cachedHttpClient: OkHttpClient? = null

    @Volatile
    private var cachedHttpClientBaseUrl: String? = null

    @Volatile
    private var cachedHttpClientCertStamp: Long = -1L

    fun isHistorySyncRunning(): Boolean = historySyncInProgress.get()

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
                httpClient(context, cfg).newCall(req).execute().use {
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
                callback(pollAndSendSync(context, cfg))
            }.onFailure {
                callback("Poll error: ${it.message}")
            }
        }
    }

    fun pollAndSendSync(context: Context, cfg: GatewayConfig): String {
        val (_, privatePem) = getOrCreateKeyPairPem(context)
        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/pull?deviceId=${cfg.deviceId}")
            .get()
            .build()

        httpClient(context, cfg).newCall(req).execute().use { resp ->
            if (resp.code == 204) {
                flushPendingUploads(context, cfg)
                return "No pending message"
            }
            if (!resp.isSuccessful) {
                val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "no body"
                error("pull failed: ${resp.code} $body")
            }
            val body = resp.body?.string() ?: error("empty body")
            val json = JSONObject(body)
            val encrypted = json.getString("encryptedPayloadBase64")
            val plain = decryptWithPrivateKey(privatePem, encrypted)
            val payload = JSONObject(plain)
            val phone = payload.getString("targetPhone")
            val text = payload.getString("content")
            val smsManager = when (val subId = cfg.simSubId) {
                null -> SmsManager.getDefault()
                SubscriptionManager.INVALID_SUBSCRIPTION_ID -> SmsManager.getDefault()
                else -> SmsManager.getSmsManagerForSubscriptionId(subId)
            }
            smsManager.sendTextMessage(phone, null, text, null, null)
            flushPendingUploads(context, cfg)
            return "SMS sent to $phone"
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
        synchronized(flushLock) {
            if (flushInProgress) return
            flushInProgress = true
        }

        val local = getDb(context)
        try {
            val serverPublicPem = fetchServerPublicKey(context, cfg)
            repeat(20) {
                val pending = local.listPending(200)
                if (pending.isEmpty()) return

                val uploadedIds = ArrayList<Long>(pending.size)
                pending.forEach { item ->
                    runCatching {
                        uploadInboundSmsSync(
                            context = context,
                            cfg = cfg,
                            phone = item.phone,
                            content = item.content,
                            timestamp = item.timestamp,
                            direction = item.direction,
                            messageId = item.messageId,
                            serverPublicPem = serverPublicPem
                        )
                        uploadedIds += item.id
                    }
                }
                local.deletePending(uploadedIds)
            }
        } finally {
            flushInProgress = false
        }
    }

    fun syncHistoricalSms(
        context: Context,
        cfg: GatewayConfig,
        onProgress: ((Int, Int) -> Unit)? = null,
        callback: (String) -> Unit
    ) {
        if (!historySyncInProgress.compareAndSet(false, true)) {
            callback("History sync already running")
            return
        }

        thread {
            runCatching {
                val uri = Telephony.Sms.CONTENT_URI
                val projection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE)
                val prefs = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
                val lastHistorySyncTs = prefs.getLong(HISTORY_LAST_SYNC_TS_KEY, 0L)
                val selection = if (lastHistorySyncTs > 0L) "${Telephony.Sms.DATE} > ?" else null
                val selectionArgs = if (lastHistorySyncTs > 0L) arrayOf(lastHistorySyncTs.toString()) else null
                val cursor = context.contentResolver.query(uri, projection, selection, selectionArgs, "${Telephony.Sms.DATE} ASC")
                    ?: error("query sms failed")

                val total = cursor.count
                if (total <= 0) {
                    onProgress?.invoke(0, 0)
                    callback("History sync complete: 0 messages")
                    return@runCatching
                }

                var count = 0
                var latestTimestamp = lastHistorySyncTs
                val batch = ArrayList<PendingUploadInput>(200)
                var lastProgressAt = 0L
                onProgress?.invoke(0, total)
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
                        batch += PendingUploadInput(
                            phone = phone,
                            content = content,
                            timestamp = timestamp,
                            direction = direction,
                            messageId = "sms-$smsId"
                        )

                        if (batch.size >= 200) {
                            getDb(context).enqueueUploads(batch)
                            batch.clear()
                        }

                        count++
                        if (timestamp > latestTimestamp) {
                            latestTimestamp = timestamp
                        }
                        val now = System.currentTimeMillis()
                        if (count == total || now - lastProgressAt >= 250L) {
                            lastProgressAt = now
                            onProgress?.invoke(count, total)
                        }
                    }
                }

                if (batch.isNotEmpty()) {
                    getDb(context).enqueueUploads(batch)
                    batch.clear()
                }

                if (latestTimestamp > lastHistorySyncTs) {
                    prefs.edit().putLong(HISTORY_LAST_SYNC_TS_KEY, latestTimestamp).apply()
                }
                onProgress?.invoke(total, total)
                thread {
                    runCatching {
                        flushPendingUploads(context, cfg)
                    }
                }
                callback("History sync complete: $count messages, uploading in background")
            }.onFailure {
                callback("History sync error: ${it.message}")
            }.also {
                historySyncInProgress.set(false)
            }
        }
    }

    fun inspectLocalSmsAccess(context: Context, callback: (String) -> Unit) {
        thread {
            runCatching {
                val stats = readLocalSmsStats(context)
                callback(
                    "Local SMS readable: total=${stats.total}, inbound=${stats.inbound}, outbound=${stats.outbound}, oldest=${stats.oldestTimestamp ?: 0}, latest=${stats.latestTimestamp ?: 0}"
                )
            }.onFailure {
                callback("Local SMS test error: ${it.message}")
            }
        }
    }

    private fun readLocalSmsStats(context: Context): LocalSmsStats {
        val uri = Telephony.Sms.CONTENT_URI
        val projection = arrayOf(Telephony.Sms.DATE, Telephony.Sms.TYPE)
        val cursor = context.contentResolver.query(uri, projection, null, null, null)
            ?: error("query sms failed")

        var total = 0
        var inbound = 0
        var outbound = 0
        var oldest: Long? = null
        var latest: Long? = null

        cursor.use {
            val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val typeIdx = it.getColumnIndexOrThrow(Telephony.Sms.TYPE)
            while (it.moveToNext()) {
                total++
                val ts = it.getLong(dateIdx)
                val type = it.getInt(typeIdx)
                if (type == Telephony.Sms.MESSAGE_TYPE_SENT) {
                    outbound++
                } else {
                    inbound++
                }
                oldest = oldest?.let { current -> minOf(current, ts) } ?: ts
                latest = latest?.let { current -> maxOf(current, ts) } ?: ts
            }
        }

        return LocalSmsStats(
            total = total,
            inbound = inbound,
            outbound = outbound,
            oldestTimestamp = oldest,
            latestTimestamp = latest
        )
    }

    fun buildMessageId(deviceId: String, phone: String, content: String, timestamp: Long, direction: String): String {
        val raw = "$deviceId|$phone|$timestamp|$direction|$content"
        val hash = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
        return hash.take(12).joinToString("") { "%02x".format(it) }
    }

    private fun uploadInboundSmsSync(
        context: Context,
        cfg: GatewayConfig,
        phone: String,
        content: String,
        timestamp: Long,
        direction: String,
        messageId: String?,
        serverPublicPem: String? = null
    ) {
        val resolvedServerPublicPem = serverPublicPem ?: fetchServerPublicKey(context, cfg)

        val payload = JSONObject()
            .put("phone", phone)
            .put("content", content)
            .put("timestamp", timestamp)
            .put("direction", direction)
        if (!messageId.isNullOrBlank()) {
            payload.put("messageId", messageId)
        }
        val encrypted = encryptByPublicKey(resolvedServerPublicPem, payload.toString())
        val up = JSONObject()
            .put("deviceId", cfg.deviceId)
            .put("encryptedPayloadBase64", encrypted)

        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/sms/upload")
            .post(up.toString().toRequestBody("application/json".toMediaType()))
            .build()
        httpClient(context, cfg).newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "no body"
                error("upload failed: ${resp.code} $body")
            }
        }
    }

    private fun fetchServerPublicKey(context: Context, cfg: GatewayConfig): String {
        val now = System.currentTimeMillis()
        val cachedPem = cachedServerPublicPem
        if (
            !cachedPem.isNullOrBlank() &&
            cachedServerBaseUrl == cfg.serverBaseUrl &&
            now - cachedServerPublicPemAt <= SERVER_PUBLIC_KEY_CACHE_MS
        ) {
            return cachedPem
        }

        val serverKeyReq = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/crypto/server-public-key")
            .get()
            .build()
        return httpClient(context, cfg).newCall(serverKeyReq).execute().use {
            if (!it.isSuccessful) {
                val body = it.body?.string()?.takeIf { body -> body.isNotBlank() } ?: "no body"
                error("server public key fetch failed: ${it.code} $body")
            }
            val body = it.body?.string() ?: error("empty body")
            JSONObject(body).getString("publicKey").also { publicKey ->
                cachedServerPublicPem = publicKey
                cachedServerBaseUrl = cfg.serverBaseUrl
                cachedServerPublicPemAt = now
            }
        }
    }

    private fun httpClient(context: Context, cfg: GatewayConfig): OkHttpClient {
        val certStamp = GatewayCertificateStore.certFile(context).let { file ->
            if (file.exists()) file.lastModified() else -1L
        }
        cachedHttpClient?.let { existing ->
            if (cachedHttpClientBaseUrl == cfg.serverBaseUrl && cachedHttpClientCertStamp == certStamp) {
                return existing
            }
        }

        synchronized(httpClientLock) {
            cachedHttpClient?.let { existing ->
                if (cachedHttpClientBaseUrl == cfg.serverBaseUrl && cachedHttpClientCertStamp == certStamp) {
                    return existing
                }
            }

            val builder = OkHttpClient.Builder()
                .retryOnConnectionFailure(true)
                .addInterceptor(Interceptor { chain ->
                    val original = chain.request()
                    val req = original.newBuilder()
                    val password = RuntimeConfig.password?.trim()
                    if (!password.isNullOrEmpty()) {
                        req.header("X-Password", password)
                    }
                    chain.proceed(req.build())
                })

            if (cfg.serverBaseUrl.startsWith("https://", ignoreCase = true) && !GatewayCertificateStore.hasCertificate(context)) {
                error("HTTPS requires an imported server certificate")
            }

            if (cfg.serverBaseUrl.startsWith("https://", ignoreCase = true) && GatewayCertificateStore.hasCertificate(context)) {
                val cf = CertificateFactory.getInstance("X.509")
                GatewayCertificateStore.openInputStream(context).use { input ->
                    if (input != null) {
                        val ca = cf.generateCertificate(input)
                        val keyStore = KeyStore.getInstance(KeyStore.getDefaultType())
                        keyStore.load(null, null)
                        keyStore.setCertificateEntry("server", ca)

                        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
                        tmf.init(keyStore)
                        val trustManager = tmf.trustManagers.first { it is X509TrustManager } as X509TrustManager

                        val sslContext = SSLContext.getInstance("TLS")
                        sslContext.init(null, arrayOf(trustManager), null)
                        builder.sslSocketFactory(sslContext.socketFactory, trustManager)
                    }
                }
            }

            return builder.build().also {
                cachedHttpClient = it
                cachedHttpClientBaseUrl = cfg.serverBaseUrl
                cachedHttpClientCertStamp = certStamp
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

        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!keyStore.containsAlias(KEYSTORE_ALIAS)) {
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
            val spec = KeyGenParameterSpec.Builder(
                KEYSTORE_ALIAS,
                KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT
            )
                .setKeySize(2048)
                .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .build()
            kpg.initialize(spec)
            kpg.generateKeyPair()
        }

        val cert = keyStore.getCertificate(KEYSTORE_ALIAS) ?: error("android keystore certificate missing")
        val pubPem = toPem("PUBLIC KEY", cert.publicKey.encoded)
        val priPem = "android-keystore:$KEYSTORE_ALIAS"
        pref.edit().putString(KEY_PUBLIC, pubPem).putString(KEY_PRIVATE, priPem).apply()
        return pubPem to priPem
    }

    private fun encryptByPublicKey(publicPem: String, plain: String): String {
        val key = loadPublicKey(publicPem)
        val plainBytes = plain.toByteArray(Charsets.UTF_8)
        val maxChunkSize = maxOaepSha256PlaintextSize(key)
        if (plainBytes.size <= maxChunkSize) {
            return encryptChunk(key, plainBytes)
        }

        val chunks = ArrayList<String>()
        var offset = 0
        while (offset < plainBytes.size) {
            val end = minOf(offset + maxChunkSize, plainBytes.size)
            chunks += encryptChunk(key, plainBytes.copyOfRange(offset, end))
            offset = end
        }
        return chunks.joinToString(".")
    }

    private fun decryptWithPrivateKey(privatePem: String, encryptedBase64: String): String {
        val key = if (privatePem.startsWith("android-keystore:")) {
            loadPrivateKeyFromAndroidKeystore(privatePem.removePrefix("android-keystore:"))
        } else {
            loadPrivateKey(privatePem)
        }
        if (!encryptedBase64.contains('.')) {
            return decryptChunk(key, encryptedBase64).toString(Charsets.UTF_8)
        }

        val output = ByteArrayOutputStream()
        encryptedBase64
            .split('.')
            .filter { it.isNotBlank() }
            .forEach { chunk ->
                output.write(decryptChunk(key, chunk))
            }
        return output.toByteArray().toString(Charsets.UTF_8)
    }

    private fun encryptChunk(key: PublicKey, plainBytes: ByteArray): String {
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        return Base64.getEncoder().encodeToString(cipher.doFinal(plainBytes))
    }

    private fun decryptChunk(key: PrivateKey, encryptedBase64: String): ByteArray {
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(Cipher.DECRYPT_MODE, key)
        return cipher.doFinal(Base64.getDecoder().decode(encryptedBase64))
    }

    private fun maxOaepSha256PlaintextSize(key: PublicKey): Int {
        val keyBytes = ((key as? RSAKey)?.modulus?.bitLength()?.plus(7)?.div(8)) ?: 256
        val hashBytes = 32
        return keyBytes - (2 * hashBytes) - 2
    }

    private fun loadPrivateKeyFromAndroidKeystore(alias: String): PrivateKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val entry = keyStore.getEntry(alias, null) as? KeyStore.PrivateKeyEntry
            ?: error("android keystore private key missing")
        return entry.privateKey
    }

    private fun loadPublicKey(publicPem: String): PublicKey {
        val bytes = Base64.getMimeDecoder().decode(publicPem.pemBody())
        val keyFactory = rawRsaKeyFactory()
        return runCatching {
            keyFactory.generatePublic(X509EncodedKeySpec(bytes))
        }.getOrElse {
            keyFactory.generatePublic(X509EncodedKeySpec(wrapPkcs1PublicKey(bytes)))
        }
    }

    private fun loadPrivateKey(privatePem: String): PrivateKey {
        val bytes = Base64.getDecoder().decode(privatePem.pemBody())
        val spec = PKCS8EncodedKeySpec(bytes)
        return rawRsaKeyFactory().generatePrivate(spec)
    }

    private fun rawRsaKeyFactory(): KeyFactory {
        val preferredProviders = linkedSetOf("BC", "AndroidOpenSSL", "Conscrypt")
        preferredProviders.forEach { providerName ->
            runCatching {
                return KeyFactory.getInstance("RSA", providerName)
            }
        }

        Security.getProviders().forEach { provider ->
            val name = provider.name ?: return@forEach
            if (name.contains("AndroidKeyStore", ignoreCase = true)) return@forEach
            runCatching {
                return KeyFactory.getInstance("RSA", provider)
            }
        }

        return KeyFactory.getInstance("RSA")
    }

    private fun toPem(title: String, raw: ByteArray): String {
        val b64 = Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(raw)
        return "-----BEGIN $title-----\n$b64\n-----END $title-----"
    }

    private fun String.pemBody(): String {
        return this
            .replace("-----BEGIN PUBLIC KEY-----", "")
            .replace("-----END PUBLIC KEY-----", "")
            .replace("-----BEGIN RSA PUBLIC KEY-----", "")
            .replace("-----END RSA PUBLIC KEY-----", "")
            .replace("-----BEGIN PRIVATE KEY-----", "")
            .replace("-----END PRIVATE KEY-----", "")
            .replace("\r", "")
            .replace("\n", "")
            .trim()
    }

    private fun wrapPkcs1PublicKey(pkcs1: ByteArray): ByteArray {
        val rsaAlgorithmIdentifier = byteArrayOf(
            0x30, 0x0D,
            0x06, 0x09,
            0x2A, 0x86.toByte(), 0x48, 0x86.toByte(), 0xF7.toByte(), 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00
        )
        val bitString = derEncode(0x03, byteArrayOf(0x00) + pkcs1)
        return derEncode(0x30, rsaAlgorithmIdentifier + bitString)
    }

    private fun derEncode(tag: Int, content: ByteArray): ByteArray {
        return byteArrayOf(tag.toByte()) + derLength(content.size) + content
    }

    private fun derLength(length: Int): ByteArray {
        return when {
            length < 0x80 -> byteArrayOf(length.toByte())
            length <= 0xFF -> byteArrayOf(0x81.toByte(), length.toByte())
            length <= 0xFFFF -> byteArrayOf(0x82.toByte(), (length shr 8).toByte(), length.toByte())
            else -> throw IllegalArgumentException("length too large")
        }
    }
}

object RuntimeConfig {
    @Volatile
    var password: String? = null
}
