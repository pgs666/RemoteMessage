package cn.ac.studio.rmg

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import java.io.ByteArrayOutputStream
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.net.Uri
import android.os.Build
import android.provider.Telephony
import android.telephony.SubscriptionManager
import android.telephony.SmsManager
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.Security
import java.security.interfaces.RSAKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import android.util.Base64
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

data class GatewayConfig(
    val serverBaseUrl: String,
    val deviceId: String
)

data class OutboundStatusUpdate(
    val messageId: String,
    val targetPhone: String,
    val status: String,
    val timestamp: Long = System.currentTimeMillis(),
    val content: String? = null,
    val simSlotIndex: Int? = null,
    val simPhoneNumber: String? = null,
    val simCount: Int? = null,
    val errorCode: Int? = null,
    val errorMessage: String? = null
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
    private const val HISTORY_FORCE_FULL_SYNC_ONCE_KEY = "history_force_full_sync_once"
    private const val SERVER_PUBLIC_KEY_CACHE_MS = 60 * 1000L
    private const val SEND_TRACKER_PREF = "gateway_send_tracker"

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

    fun isSmsSendingSupported(context: Context): Boolean {
        val pm = context.packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_TELEPHONY_MESSAGING) ||
            pm.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)
    }

    private fun getDb(context: Context): GatewayLocalDb {
        if (db == null) {
            db = GatewayLocalDb(context.applicationContext)
        }
        return db!!
    }

    fun registerGateway(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                GatewayDebugLog.add(context, "Register gateway: ${cfg.deviceId} -> ${cfg.serverBaseUrl}")
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
                runCatching { pushSimStateSync(context, cfg) }
            }.onSuccess {
                GatewayDebugLog.add(context, "Register gateway success")
                callback("Gateway registered")
            }.onFailure {
                GatewayDebugLog.add(context, "Register gateway failed: ${it.message}")
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
        return try {
            GatewayDebugLog.add(context, "Poll start: ${cfg.deviceId}")
            val (_, privatePem) = getOrCreateKeyPairPem(context)
            val req = Request.Builder()
                .url("${cfg.serverBaseUrl}/api/gateway/pull?deviceId=${Uri.encode(cfg.deviceId)}")
                .get()
                .build()

            httpClient(context, cfg).newCall(req).execute().use { resp ->
                if (resp.code == 204) {
                    GatewayDebugLog.add(context, "Poll result: no pending message")
                    flushPendingUploads(context, cfg)
                    return@use "No pending message"
                }
                if (!resp.isSuccessful) {
                    val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "no body"
                    GatewayDebugLog.add(context, "Poll failed: ${resp.code} $body")
                    error("pull failed: ${resp.code} $body")
                }
                val body = resp.body?.string() ?: error("empty body")
                val json = JSONObject(body)
                val outboxId = json.optLong("outboxId").takeIf { it > 0L }
                val ackToken = json.optString("ackToken", "").trim()
                    .takeIf { it.isNotBlank() && !it.equals("null", ignoreCase = true) }
                val encrypted = json.getString("encryptedPayloadBase64")
                val plain = runCatching {
                    decryptWithPrivateKey(privatePem, encrypted)
                }.getOrElse { decryptError ->
                    GatewayDebugLog.add(context, "Outbound decrypt failed: ${decryptError.debugSummary()}")
                    runCatching {
                        registerGatewayKeySync(context, cfg)
                        GatewayDebugLog.add(context, "Gateway key re-register triggered after decrypt failure")
                    }.onFailure {
                        GatewayDebugLog.add(context, "Gateway key re-register failed: ${it.debugSummary()}")
                    }
                    if (privatePem.startsWith("android-keystore:")) {
                        runCatching {
                            rotateToSoftwareKeyPair(context)
                            registerGatewayKeySync(context, cfg)
                            GatewayDebugLog.add(context, "Gateway key switched to software RSA and re-registered")
                        }.onFailure {
                            GatewayDebugLog.add(context, "Gateway software key fallback failed: ${it.debugSummary()}")
                        }
                    }
                    throw decryptError
                }
                val payload = JSONObject(plain)
                val messageId = payload.optString("messageId", "").trim()
                    .takeIf { it.isNotBlank() && !it.equals("null", ignoreCase = true) }
                val phone = payload.getString("targetPhone")
                val text = payload.getString("content")
                val preferredSimSlotIndex = payload.optNullableInt("simSlotIndex")
                GatewayDebugLog.add(
                    context,
                    "Poll got outbound request: outboxId=${outboxId ?: -1}, messageId=${messageId ?: "-"}, phone=$phone, chars=${text.length}, requestedSlot=${preferredSimSlotIndex ?: -1}"
                )
                val resolvedSim = GatewaySimSupport.resolveForSlotIndex(
                    snapshot = GatewaySimSupport.readSnapshot(context),
                    slotIndex = preferredSimSlotIndex
                )
                val resolvedSimCount = resolvedSim.simCount.takeIf { it > 0 }
                GatewayDebugLog.add(
                    context,
                    "Resolved send SIM: slot=${resolvedSim.slotIndex ?: -1}, subId=${resolvedSim.subscriptionId ?: -1}, simPhone=${resolvedSim.simPhoneNumber ?: ""}"
                )
                val sendResult = runCatching {
                    sendTextMessageCompat(
                        context = context,
                        cfg = cfg,
                        smsManager = smsManagerForSubscriptionId(resolvedSim.subscriptionId),
                        phone = phone,
                        text = text,
                        messageId = messageId,
                        simSlotIndex = resolvedSim.slotIndex,
                        simPhoneNumber = resolvedSim.simPhoneNumber,
                        simCount = resolvedSimCount
                    )
                }
                if (messageId != null) {
                    val sendError = sendResult.exceptionOrNull()
                    reportOutboundStatusAsync(
                        context = context,
                        cfg = cfg,
                        update = OutboundStatusUpdate(
                            messageId = messageId,
                            targetPhone = phone,
                            content = text,
                            status = if (sendError == null) "dispatched" else "failed",
                            simSlotIndex = resolvedSim.slotIndex,
                            simPhoneNumber = resolvedSim.simPhoneNumber,
                            simCount = resolvedSimCount,
                            errorCode = if (sendError == null) null else -1,
                            errorMessage = sendError?.smsFailureMessage(context)
                        )
                    )
                }
                sendResult
                    .onSuccess { GatewayDebugLog.add(context, "SMS dispatch invoked for $phone") }
                    .onFailure { GatewayDebugLog.add(context, "SMS dispatch failed for $phone: ${it.debugSummary()}") }
                if (outboxId != null && ackToken != null) {
                    ackOutboundSync(context, cfg, outboxId, ackToken)
                    GatewayDebugLog.add(context, "Outbound ack success: outboxId=$outboxId")
                } else {
                    GatewayDebugLog.add(context, "Outbound ack skipped: missing outboxId/ackToken")
                }
                flushPendingUploads(context, cfg)
                sendResult.exceptionOrNull()?.let {
                    return@use "SMS send failed to $phone: ${it.message ?: it.javaClass.simpleName}"
                }
                return@use "SMS sent to $phone"
            }
        } catch (t: Throwable) {
            GatewayDebugLog.add(context, "Poll/send failed: ${t.debugSummary()}")
            throw t
        }
    }

    fun uploadInboundSms(
        context: Context,
        cfg: GatewayConfig,
        phone: String,
        content: String,
        timestamp: Long,
        direction: String = "inbound",
        messageId: String? = null,
        simSlotIndex: Int? = null,
        simPhoneNumber: String? = null,
        simCount: Int? = null
    ) {
        getDb(context).enqueueUpload(phone, content, timestamp, direction, messageId, simSlotIndex, simPhoneNumber, simCount)
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
            var serverPublicPem = fetchServerPublicKey(context, cfg)
            repeat(20) {
                val pending = local.listPending(200)
                if (pending.isEmpty()) return

                GatewayDebugLog.add(context, "Flush pending uploads: ${pending.size} item(s)")

                val uploadedIds = ArrayList<Long>(pending.size)
                val droppedIds = ArrayList<Long>(pending.size)
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
                            simSlotIndex = item.simSlotIndex,
                            simPhoneNumber = item.simPhoneNumber,
                            simCount = item.simCount,
                            serverPublicPem = serverPublicPem
                        )
                        uploadedIds += item.id
                        GatewayDebugLog.add(context, "Uploaded sms: id=${item.messageId ?: item.id}, slot=${item.simSlotIndex ?: -1}, phone=${item.phone}")
                    }.onFailure { firstError ->
                        val shouldRetry = shouldRefreshServerPublicKey(firstError)
                        if (shouldRetry) {
                            runCatching {
                                GatewayDebugLog.add(context, "Upload failed with cached server key, refreshing key and retrying once")
                                invalidateServerPublicKeyCache(cfg.serverBaseUrl)
                                serverPublicPem = fetchServerPublicKey(context, cfg)
                                uploadInboundSmsSync(
                                    context = context,
                                    cfg = cfg,
                                    phone = item.phone,
                                    content = item.content,
                                    timestamp = item.timestamp,
                                    direction = item.direction,
                                    messageId = item.messageId,
                                    simSlotIndex = item.simSlotIndex,
                                    simPhoneNumber = item.simPhoneNumber,
                                    simCount = item.simCount,
                                    serverPublicPem = serverPublicPem
                                )
                                uploadedIds += item.id
                                GatewayDebugLog.add(context, "Uploaded sms after server key refresh: id=${item.messageId ?: item.id}")
                            }.onFailure { retryError ->
                                GatewayDebugLog.add(context, "Upload failed after key refresh: ${retryError.message}")
                                if (isPermanentUploadFailure(retryError)) {
                                    droppedIds += item.id
                                    GatewayDebugLog.add(context, "Dropped invalid pending sms after retry: id=${item.messageId ?: item.id}, phone=${item.phone}")
                                }
                            }
                        } else {
                            GatewayDebugLog.add(context, "Upload failed: ${firstError.message}")
                            if (isPermanentUploadFailure(firstError)) {
                                droppedIds += item.id
                                GatewayDebugLog.add(context, "Dropped invalid pending sms: id=${item.messageId ?: item.id}, phone=${item.phone}")
                            }
                        }
                    }
                }
                if (uploadedIds.isNotEmpty()) {
                    GatewayStatsStore.addForwarded(context, uploadedIds.size)
                }
                local.deletePending(uploadedIds)
                local.deletePending(droppedIds)
                // Avoid hot-looping the same permanently-invalid records in a single flush batch.
                if (droppedIds.isNotEmpty()) {
                    return
                }
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
                requireReadSmsPermission(context)
                val uri = Telephony.Sms.CONTENT_URI
                val baseProjection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE)
                val extendedProjection = arrayOf(Telephony.Sms._ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE, "sub_id", "subscription_id")
                val prefs = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
                val lastHistorySyncTs = prefs.getLong(HISTORY_LAST_SYNC_TS_KEY, 0L)
                val forceFullSyncByFlag = prefs.getBoolean(HISTORY_FORCE_FULL_SYNC_ONCE_KEY, false)
                val forceFullSyncByServerEmpty = !forceFullSyncByFlag && shouldForceFullHistorySyncByServerState(context, cfg, lastHistorySyncTs)
                val forceFullSync = forceFullSyncByFlag || forceFullSyncByServerEmpty
                if (forceFullSync) {
                    prefs.edit().remove(HISTORY_LAST_SYNC_TS_KEY).remove(HISTORY_FORCE_FULL_SYNC_ONCE_KEY).apply()
                    GatewayDebugLog.add(context, "History sync switched to full scan (force=$forceFullSyncByFlag, serverEmpty=$forceFullSyncByServerEmpty)")
                }
                val baseCursorTs = if (forceFullSync) 0L else lastHistorySyncTs
                val selection = if (baseCursorTs > 0L) "${Telephony.Sms.DATE} > ?" else null
                val selectionArgs = if (baseCursorTs > 0L) arrayOf(baseCursorTs.toString()) else null
                val simSnapshot = GatewaySimSupport.readSnapshot(context)
                val cursor = runCatching {
                    context.contentResolver.query(uri, extendedProjection, selection, selectionArgs, "${Telephony.Sms.DATE} ASC")
                }.getOrElse {
                    context.contentResolver.query(uri, baseProjection, selection, selectionArgs, "${Telephony.Sms.DATE} ASC")
                }
                    ?: error("query sms failed")

                val total = cursor.count
                if (total <= 0) {
                    onProgress?.invoke(0, 0)
                    callback("History sync complete: 0 messages")
                    return@runCatching
                }

                var count = 0
                var latestTimestamp = baseCursorTs
                val batch = ArrayList<PendingUploadInput>(200)
                var lastProgressAt = 0L
                onProgress?.invoke(0, total)
                cursor.use {
                    val idIdx = it.getColumnIndexOrThrow(Telephony.Sms._ID)
                    val addressIdx = it.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
                    val bodyIdx = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
                    val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
                    val typeIdx = it.getColumnIndexOrThrow(Telephony.Sms.TYPE)
                    val subIdIdx = it.getColumnIndex("sub_id")
                    val subscriptionIdIdx = it.getColumnIndex("subscription_id")

                    while (it.moveToNext()) {
                        val smsId = it.getString(idIdx) ?: continue
                        val phone = it.getString(addressIdx) ?: "unknown"
                        val content = it.getString(bodyIdx) ?: ""
                        val timestamp = it.getLong(dateIdx)
                        val type = it.getInt(typeIdx)
                        val subscriptionId = when {
                            subIdIdx >= 0 && !it.isNull(subIdIdx) -> it.getInt(subIdIdx)
                            subscriptionIdIdx >= 0 && !it.isNull(subscriptionIdIdx) -> it.getInt(subscriptionIdIdx)
                            else -> null
                        }
                        val simInfo = GatewaySimSupport.resolveForSubscriptionId(simSnapshot, subscriptionId)
                        val direction = if (type == Telephony.Sms.MESSAGE_TYPE_SENT) "outbound" else "inbound"
                        batch += PendingUploadInput(
                            phone = phone,
                            content = content,
                            timestamp = timestamp,
                            direction = direction,
                            messageId = "sms-$smsId",
                            simSlotIndex = simInfo.slotIndex,
                            simPhoneNumber = simInfo.simPhoneNumber,
                            simCount = simInfo.simCount.takeIf { simCount -> simCount > 0 }
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

                if (latestTimestamp > baseCursorTs) {
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

    fun pushSimState(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                callback(pushSimStateSync(context, cfg))
            }.onFailure {
                callback("SIM state sync error: ${it.message}")
            }
        }
    }

    fun resetHistorySyncCursor(context: Context, forceFullNextSync: Boolean = true) {
        val edit = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
            .edit()
            .remove(HISTORY_LAST_SYNC_TS_KEY)
        if (forceFullNextSync) {
            edit.putBoolean(HISTORY_FORCE_FULL_SYNC_ONCE_KEY, true)
        } else {
            edit.remove(HISTORY_FORCE_FULL_SYNC_ONCE_KEY)
        }
        edit.apply()
        GatewayDebugLog.add(context, "History sync cursor reset (forceFullNextSync=$forceFullNextSync)")
    }

    fun clearServerData(context: Context, cfg: GatewayConfig, callback: (String) -> Unit) {
        thread {
            runCatching {
                callback(clearServerDataSync(context, cfg))
            }.onFailure {
                callback("Clear server data error: ${it.message}")
            }
        }
    }

    fun clearServerDataSync(context: Context, cfg: GatewayConfig): String {
        val requestJson = JSONObject()
            .put("confirm", "CLEAR_SERVER_DATA")
        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/admin/clear-server-data")
            .post(requestJson.toString().toRequestBody("application/json".toMediaType()))
            .build()

        httpClient(context, cfg).newCall(req).execute().use { resp ->
            val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "{}"
            if (!resp.isSuccessful) {
                GatewayDebugLog.add(context, "Clear server data failed: ${resp.code} $body")
                error("clear-server-data failed: ${resp.code} $body")
            }

            val result = runCatching { JSONObject(body).optJSONObject("result") }.getOrNull()
            val messagesCleared = result?.optInt("messagesCleared", -1) ?: -1
            val outboxCleared = result?.optInt("outboxCleared", -1) ?: -1
            val pinnedCleared = result?.optInt("pinnedConversationsCleared", -1) ?: -1
            val simProfilesCleared = result?.optInt("gatewaySimProfilesCleared", -1) ?: -1
            val apiLogsCleared = result?.optInt("apiLogsCleared", -1) ?: -1

            GatewayDebugLog.add(
                context,
                "Clear server data success: messages=$messagesCleared, outbox=$outboxCleared, pinned=$pinnedCleared, simProfiles=$simProfilesCleared, apiLogs=$apiLogsCleared"
            )
            resetHistorySyncCursor(context, forceFullNextSync = true)

            runCatching {
                pushSimStateSync(context, cfg)
            }.onFailure {
                GatewayDebugLog.add(context, "Push SIM state after server clear failed: ${it.debugSummary()}")
            }

            return if (messagesCleared >= 0 && outboxCleared >= 0) {
                "Server data cleared: messages=$messagesCleared, outbox=$outboxCleared"
            } else {
                "Server data cleared"
            }
        }
    }

    private fun shouldForceFullHistorySyncByServerState(context: Context, cfg: GatewayConfig, lastHistorySyncTs: Long): Boolean {
        if (lastHistorySyncTs <= 0L) {
            return false
        }

        return runCatching {
            val req = Request.Builder()
                .url("${cfg.serverBaseUrl}/api/client/inbox?sinceTs=0&limit=1")
                .get()
                .build()
            httpClient(context, cfg).newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) {
                    return false
                }
                val body = resp.body?.string() ?: return false
                JSONArray(body).length() == 0
            }
        }.getOrElse {
            false
        }
    }

    fun pushSimStateSync(context: Context, cfg: GatewayConfig): String {
        val snapshot = GatewaySimSupport.readSnapshot(context)
        GatewayDebugLog.add(context, "Push SIM state: count=${snapshot.profiles.size}")
        val profiles = JSONArray()
        snapshot.profiles.sortedBy { it.slotIndex }.forEach { profile ->
            profiles.put(
                JSONObject()
                    .put("slotIndex", profile.slotIndex)
                    .put("subscriptionId", profile.subscriptionId)
                    .put("displayName", profile.displayName)
                    .put("phoneNumber", profile.effectivePhoneNumber)
                    .put("simCount", snapshot.simCount)
            )
        }

        val bodyJson = JSONObject()
            .put("deviceId", cfg.deviceId)
            .put("profiles", profiles)

        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/sim-state")
            .post(bodyJson.toString().toRequestBody("application/json".toMediaType()))
            .build()

        httpClient(context, cfg).newCall(req).execute().use {
            if (!it.isSuccessful) {
                val body = it.body?.string()?.takeIf { body -> body.isNotBlank() } ?: "no body"
                GatewayDebugLog.add(context, "Push SIM state failed: ${it.code} $body")
                error("sim-state failed: ${it.code} $body")
            }
        }
        GatewayDebugLog.add(context, "Push SIM state success")
        return "SIM state uploaded: ${snapshot.profiles.size}"
    }

    private fun readLocalSmsStats(context: Context): LocalSmsStats {
        requireReadSmsPermission(context)
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

    private fun requireReadSmsPermission(context: Context) {
        if (!GatewayPermissionCenter.hasAllRuntimePermissions(context, GatewayPermissionCenter.readSmsPermissions())) {
            error("missing permission: READ_SMS")
        }
    }

    private fun requireSendSmsPermission(context: Context) {
        if (!GatewayPermissionCenter.hasAllRuntimePermissions(context, GatewayPermissionCenter.sendSmsPermissions())) {
            error("missing permission: SEND_SMS")
        }
    }

    fun buildMessageId(deviceId: String, phone: String, content: String, timestamp: Long, direction: String, simSlotIndex: Int? = null): String {
        val raw = "$deviceId|$phone|$timestamp|$direction|${simSlotIndex ?: -1}|$content"
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
        simSlotIndex: Int? = null,
        simPhoneNumber: String? = null,
        simCount: Int? = null,
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
        if (simSlotIndex != null) {
            payload.put("simSlotIndex", simSlotIndex)
        }
        if (!simPhoneNumber.isNullOrBlank()) {
            payload.put("simPhoneNumber", simPhoneNumber)
        }
        if (simCount != null) {
            payload.put("simCount", simCount)
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

    private fun invalidateServerPublicKeyCache(baseUrl: String? = null) {
        if (baseUrl != null && cachedServerBaseUrl != baseUrl) {
            return
        }
        cachedServerPublicPem = null
        cachedServerBaseUrl = null
        cachedServerPublicPemAt = 0L
    }

    private fun shouldRefreshServerPublicKey(error: Throwable): Boolean {
        val message = error.message?.lowercase() ?: return false
        return message.contains("upload failed: 400") ||
            message.contains("invalid encrypted payload") ||
            message.contains("oaep") ||
            message.contains("failed to decrypt")
    }

    private fun isPermanentUploadFailure(error: Throwable): Boolean {
        val message = error.message?.lowercase() ?: return false
        return message.contains("phone invalid") ||
            message.contains("content too large") ||
            message.contains("messageid too long") ||
            message.contains("simslotindex invalid") ||
            message.contains("simphonenumber invalid") ||
            message.contains("simcount invalid") ||
            message.contains("deviceid/encryptedpayloadbase64 required") ||
            message.contains("deviceid too long")
    }

    private fun smsManagerForSubscriptionId(subscriptionId: Int?): SmsManager {
        return when (subscriptionId) {
            null -> SmsManager.getDefault()
            SubscriptionManager.INVALID_SUBSCRIPTION_ID -> SmsManager.getDefault()
            else -> SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        }
    }

    private fun sendTextMessageCompat(
        context: Context,
        cfg: GatewayConfig,
        smsManager: SmsManager,
        phone: String,
        text: String,
        messageId: String?,
        simSlotIndex: Int?,
        simPhoneNumber: String?,
        simCount: Int?
    ) {
        requireSendSmsPermission(context)
        requireSmsSendingSupported(context)
        val parts = runSmsManagerCall(context) { smsManager.divideMessage(text) }
        if (messageId.isNullOrBlank()) {
            if (parts.size <= 1) {
                runSmsManagerCall(context) { smsManager.sendTextMessage(phone, null, text, null, null) }
            } else {
                runSmsManagerCall(context) { smsManager.sendMultipartTextMessage(phone, null, parts, null, null) }
            }
            return
        }

        val sentIntents = ArrayList<PendingIntent>(parts.size)
        val requestBase = ((System.currentTimeMillis() and 0x7fffffff).toInt() xor (messageId.hashCode() and 0x7fffffff))
        for (index in parts.indices) {
            sentIntents += buildSentPendingIntent(
                context = context,
                cfg = cfg,
                messageId = messageId,
                phone = phone,
                content = text,
                simSlotIndex = simSlotIndex,
                simPhoneNumber = simPhoneNumber,
                simCount = simCount,
                requestCode = requestBase + index,
                partIndex = index,
                totalParts = parts.size
            )
        }

        if (parts.size <= 1) {
            runSmsManagerCall(context) { smsManager.sendTextMessage(phone, null, text, sentIntents[0], null) }
        } else {
            runSmsManagerCall(context) { smsManager.sendMultipartTextMessage(phone, null, parts, sentIntents, null) }
        }
    }

    fun requireSmsSendingSupported(context: Context) {
        if (!isSmsSendingSupported(context)) {
            throw IllegalStateException(context.getString(R.string.error_sms_not_supported))
        }
    }

    private inline fun <T> runSmsManagerCall(context: Context, block: () -> T): T {
        return try {
            block()
        } catch (e: UnsupportedOperationException) {
            val message = e.message.orEmpty()
            if (message.contains("sms is not supported", ignoreCase = true) ||
                message.contains("not supported", ignoreCase = true)
            ) {
                throw IllegalStateException(context.getString(R.string.error_sms_not_supported), e)
            }
            throw e
        }
    }

    private fun Throwable.smsFailureMessage(context: Context): String {
        val unsupported = context.getString(R.string.error_sms_not_supported)
        if (message == unsupported || cause?.message.orEmpty().contains("sms is not supported", ignoreCase = true)) {
            return unsupported
        }
        val detail = message?.takeIf { it.isNotBlank() } ?: this::class.java.simpleName
        return context.getString(R.string.error_sms_send_failed, detail)
    }

    private fun buildSentPendingIntent(
        context: Context,
        cfg: GatewayConfig,
        messageId: String,
        phone: String,
        content: String,
        simSlotIndex: Int?,
        simPhoneNumber: String?,
        simCount: Int?,
        requestCode: Int,
        partIndex: Int,
        totalParts: Int
    ): PendingIntent {
        val intent = Intent(context, SmsSendStatusReceiver::class.java).apply {
            action = GatewaySmsStatusContract.ACTION_SMS_SENT_STATUS
            putExtra(GatewaySmsStatusContract.EXTRA_SERVER_BASE_URL, cfg.serverBaseUrl)
            putExtra(GatewaySmsStatusContract.EXTRA_DEVICE_ID, cfg.deviceId)
            putExtra(GatewaySmsStatusContract.EXTRA_MESSAGE_ID, messageId)
            putExtra(GatewaySmsStatusContract.EXTRA_TARGET_PHONE, phone)
            putExtra(GatewaySmsStatusContract.EXTRA_CONTENT, content.take(2048))
            putExtra(GatewaySmsStatusContract.EXTRA_SIM_SLOT_INDEX, simSlotIndex ?: -1)
            putExtra(GatewaySmsStatusContract.EXTRA_SIM_PHONE_NUMBER, simPhoneNumber ?: "")
            putExtra(GatewaySmsStatusContract.EXTRA_SIM_COUNT, simCount ?: 0)
            putExtra(GatewaySmsStatusContract.EXTRA_PART_INDEX, partIndex)
            putExtra(GatewaySmsStatusContract.EXTRA_TOTAL_PARTS, totalParts)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    fun handleSmsSentResult(context: Context, intent: Intent, resultCode: Int) {
        if (intent.action != GatewaySmsStatusContract.ACTION_SMS_SENT_STATUS) {
            return
        }
        val messageId = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_MESSAGE_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return

        val phone = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_TARGET_PHONE)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return
        val content = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_CONTENT)
        val simSlotRaw = intent.getIntExtra(GatewaySmsStatusContract.EXTRA_SIM_SLOT_INDEX, -1)
        val simSlotIndex = simSlotRaw.takeIf { it >= 0 }
        val simPhoneNumber = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_SIM_PHONE_NUMBER)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val simCount = intent.getIntExtra(GatewaySmsStatusContract.EXTRA_SIM_COUNT, 0).takeIf { it > 0 }
        val partIndex = intent.getIntExtra(GatewaySmsStatusContract.EXTRA_PART_INDEX, 0).coerceAtLeast(0)
        val totalParts = intent.getIntExtra(GatewaySmsStatusContract.EXTRA_TOTAL_PARTS, 1).coerceAtLeast(1)
        val now = System.currentTimeMillis()
        val failureMessage = describeSmsResultCode(resultCode)

        if (totalParts <= 1) {
            val status = if (resultCode == Activity.RESULT_OK) "sent" else "failed"
            reportOutboundStatusFromIntent(
                context = context,
                intent = intent,
                update = OutboundStatusUpdate(
                    messageId = messageId,
                    targetPhone = phone,
                    content = content,
                    status = status,
                    timestamp = now,
                    simSlotIndex = simSlotIndex,
                    simPhoneNumber = simPhoneNumber,
                    simCount = simCount,
                    errorCode = if (status == "failed") resultCode else null,
                    errorMessage = if (status == "failed") failureMessage else null
                )
            )
            GatewayDebugLog.add(
                context,
                "SMS sent callback: messageId=$messageId, part=${partIndex + 1}/$totalParts, status=$status, resultCode=$resultCode"
            )
            return
        }

        val pref = context.getSharedPreferences(SEND_TRACKER_PREF, Context.MODE_PRIVATE)
        val keyBase = messageId.take(96)
        val doneKey = "${keyBase}_done"
        val failCodeKey = "${keyBase}_fail_code"
        val failMsgKey = "${keyBase}_fail_msg"
        val done = pref.getInt(doneKey, 0) + 1
        var failCode = pref.getInt(failCodeKey, Int.MIN_VALUE)
        var failMsg = pref.getString(failMsgKey, null)
        if (resultCode != Activity.RESULT_OK && failCode == Int.MIN_VALUE) {
            failCode = resultCode
            failMsg = failureMessage
        }

        if (done >= totalParts) {
            pref.edit().remove(doneKey).remove(failCodeKey).remove(failMsgKey).apply()
            val failed = failCode != Int.MIN_VALUE
            val status = if (failed) "failed" else "sent"
            reportOutboundStatusFromIntent(
                context = context,
                intent = intent,
                update = OutboundStatusUpdate(
                    messageId = messageId,
                    targetPhone = phone,
                    content = content,
                    status = status,
                    timestamp = now,
                    simSlotIndex = simSlotIndex,
                    simPhoneNumber = simPhoneNumber,
                    simCount = simCount,
                    errorCode = if (failed) failCode else null,
                    errorMessage = if (failed) failMsg else null
                )
            )
            GatewayDebugLog.add(
                context,
                "SMS sent callback (multipart done): messageId=$messageId, status=$status, parts=$totalParts"
            )
            return
        }

        pref.edit()
            .putInt(doneKey, done)
            .putInt(failCodeKey, failCode)
            .putString(failMsgKey, failMsg)
            .apply()
        GatewayDebugLog.add(
            context,
            "SMS sent callback (multipart progress): messageId=$messageId, part=${partIndex + 1}/$totalParts, resultCode=$resultCode"
        )
    }

    private fun describeSmsResultCode(resultCode: Int): String {
        return when (resultCode) {
            Activity.RESULT_OK -> "OK"
            SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "generic failure"
            SmsManager.RESULT_ERROR_RADIO_OFF -> "radio off"
            SmsManager.RESULT_ERROR_NULL_PDU -> "null PDU"
            SmsManager.RESULT_ERROR_NO_SERVICE -> "no service"
            SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "limit exceeded"
            SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "FDN check failure"
            SmsManager.RESULT_RIL_RADIO_NOT_AVAILABLE -> "RIL radio not available"
            SmsManager.RESULT_RIL_SMS_SEND_FAIL_RETRY -> "RIL send fail retry"
            SmsManager.RESULT_RIL_NETWORK_REJECT -> "RIL network reject"
            SmsManager.RESULT_RIL_INVALID_STATE -> "RIL invalid state"
            SmsManager.RESULT_RIL_INVALID_ARGUMENTS -> "RIL invalid arguments"
            SmsManager.RESULT_RIL_NO_MEMORY -> "RIL no memory"
            SmsManager.RESULT_RIL_REQUEST_RATE_LIMITED -> "RIL request rate limited"
            SmsManager.RESULT_RIL_INVALID_SMS_FORMAT -> "RIL invalid SMS format"
            SmsManager.RESULT_RIL_SYSTEM_ERR -> "RIL system error"
            SmsManager.RESULT_RIL_ENCODING_ERR -> "RIL encoding error"
            SmsManager.RESULT_RIL_INVALID_SMSC_ADDRESS -> "RIL invalid SMSC address"
            SmsManager.RESULT_RIL_MODEM_ERR -> "RIL modem error"
            SmsManager.RESULT_RIL_NETWORK_ERR -> "RIL network error"
            SmsManager.RESULT_RIL_INTERNAL_ERR -> "RIL internal error"
            SmsManager.RESULT_RIL_OPERATION_NOT_ALLOWED -> "RIL operation not allowed"
            SmsManager.RESULT_RIL_INVALID_MODEM_STATE -> "RIL invalid modem state"
            SmsManager.RESULT_RIL_INVALID_SIM_STATE -> "RIL invalid SIM state"
            SmsManager.RESULT_RIL_NO_RESOURCES -> "RIL no resources"
            SmsManager.RESULT_RIL_CANCELLED -> "RIL cancelled"
            SmsManager.RESULT_RIL_SIM_ABSENT -> "RIL SIM absent"
            SmsManager.RESULT_RIL_SIMULTANEOUS_SMS_AND_CALL_NOT_ALLOWED -> "RIL SMS/call not allowed"
            SmsManager.RESULT_RIL_ACCESS_BARRED -> "RIL access barred"
            SmsManager.RESULT_RIL_BLOCKED_DUE_TO_CALL -> "RIL blocked due to call"
            SmsManager.RESULT_RIL_SUBSCRIPTION_NOT_AVAILABLE -> "RIL subscription not available"
            else -> "code=$resultCode"
        }
    }

    private fun reportOutboundStatusFromIntent(context: Context, intent: Intent, update: OutboundStatusUpdate) {
        val serverFromIntent = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_SERVER_BASE_URL)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val deviceFromIntent = intent.getStringExtra(GatewaySmsStatusContract.EXTRA_DEVICE_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val configPref = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val serverBase = serverFromIntent ?: configPref.getString("server_base", "")?.trim().orEmpty()
        val deviceId = deviceFromIntent ?: configPref.getString("device_id", "")?.trim().orEmpty()
        if (serverBase.isBlank() || deviceId.isBlank()) {
            GatewayDebugLog.add(context, "Skip outbound status report: missing gateway config")
            return
        }
        RuntimeConfig.password = GatewaySecretStore.loadPassword(context)
        reportOutboundStatusAsync(
            context = context,
            cfg = GatewayConfig(serverBase, deviceId),
            update = update
        )
    }

    private fun reportOutboundStatusAsync(context: Context, cfg: GatewayConfig, update: OutboundStatusUpdate) {
        thread {
            runCatching {
                reportOutboundStatusSync(context, cfg, update)
            }.onFailure {
                GatewayDebugLog.add(context, "Outbound status report failed: ${it.debugSummary()}")
            }
        }
    }

    private fun reportOutboundStatusSync(context: Context, cfg: GatewayConfig, update: OutboundStatusUpdate) {
        val json = JSONObject()
            .put("deviceId", cfg.deviceId)
            .put("messageId", update.messageId)
            .put("targetPhone", update.targetPhone)
            .put("status", update.status)
            .put("timestamp", update.timestamp)
            .put("content", update.content ?: JSONObject.NULL)
            .put("simSlotIndex", update.simSlotIndex ?: JSONObject.NULL)
            .put("simPhoneNumber", update.simPhoneNumber ?: JSONObject.NULL)
            .put("simCount", update.simCount ?: JSONObject.NULL)
            .put("errorCode", update.errorCode ?: JSONObject.NULL)
            .put("errorMessage", update.errorMessage ?: JSONObject.NULL)
        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/outbound-status")
            .post(json.toString().toRequestBody("application/json".toMediaType()))
            .build()
        httpClient(context, cfg).newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "no body"
                error("outbound-status failed: ${resp.code} $body")
            }
        }
    }

    private fun ackOutboundSync(context: Context, cfg: GatewayConfig, outboxId: Long, ackToken: String) {
        val ackJson = JSONObject()
            .put("deviceId", cfg.deviceId)
            .put("outboxId", outboxId)
            .put("ackToken", ackToken)
        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/pull/ack")
            .post(ackJson.toString().toRequestBody("application/json".toMediaType()))
            .build()
        httpClient(context, cfg).newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                val body = resp.body?.string()?.takeIf { it.isNotBlank() } ?: "no body"
                error("ack failed: ${resp.code} $body")
            }
        }
    }

    private fun registerGatewayKeySync(context: Context, cfg: GatewayConfig) {
        val (pubPem, _) = getOrCreateKeyPairPem(context)
        val bodyJson = JSONObject()
            .put("deviceId", cfg.deviceId)
            .put("publicKeyPem", pubPem)
        val req = Request.Builder()
            .url("${cfg.serverBaseUrl}/api/gateway/register")
            .post(bodyJson.toString().toRequestBody("application/json".toMediaType()))
            .build()
        httpClient(context, cfg).newCall(req).execute().use {
            if (!it.isSuccessful) {
                val body = it.body?.string()?.takeIf { text -> text.isNotBlank() } ?: "no body"
                error("register failed: ${it.code} $body")
            }
        }
    }

    private fun rotateToSoftwareKeyPair(context: Context): Pair<String, String> {
        val keyPairGenerator = KeyPairGenerator.getInstance("RSA")
        keyPairGenerator.initialize(2048)
        val pair = keyPairGenerator.generateKeyPair()
        val pubPem = toPem("PUBLIC KEY", pair.public.encoded)
        val priPem = toPem("PRIVATE KEY", pair.private.encoded)
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_PUBLIC, pubPem)
            .putString(KEY_PRIVATE, priPem)
            .apply()
        return pubPem to priPem
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
                        req.header("X-Gateway-Token", password)
                    }
                    chain.proceed(req.build())
                })

            if (cfg.serverBaseUrl.startsWith("https://", ignoreCase = true)) {
                val trustManager = buildServerTrustManager(context)
                val sslContext = SSLContext.getInstance("TLS")
                sslContext.init(null, arrayOf(trustManager), null)
                builder.sslSocketFactory(sslContext.socketFactory, trustManager)
            }

            return builder.build().also {
                cachedHttpClient = it
                cachedHttpClientBaseUrl = cfg.serverBaseUrl
                cachedHttpClientCertStamp = certStamp
            }
        }
    }

    private fun buildServerTrustManager(context: Context): X509TrustManager {
        val systemTrust = systemTrustManager()
        val importedTrust = runCatching { importedCertificateTrustManager(context) }
            .onFailure { err ->
                GatewayDebugLog.add(
                    context,
                    "Ignored imported cert and fallback to system trust: ${err.message ?: "unknown"}"
                )
            }
            .getOrNull()

        return if (importedTrust == null) {
            systemTrust
        } else {
            CompositeX509TrustManager(listOf(importedTrust, systemTrust))
        }
    }

    private fun systemTrustManager(): X509TrustManager {
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(null as KeyStore?)
        return tmf.trustManagers.first { it is X509TrustManager } as X509TrustManager
    }

    private fun importedCertificateTrustManager(context: Context): X509TrustManager? {
        if (!GatewayCertificateStore.hasCertificate(context)) return null
        val cf = CertificateFactory.getInstance("X.509")
        GatewayCertificateStore.openInputStream(context).use { input ->
            val stream = input ?: return null
            val ca = cf.generateCertificate(stream)
            val keyStore = KeyStore.getInstance(KeyStore.getDefaultType())
            keyStore.load(null, null)
            keyStore.setCertificateEntry("server", ca)

            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(keyStore)
            return tmf.trustManagers.first { it is X509TrustManager } as X509TrustManager
        }
    }

    private class CompositeX509TrustManager(
        private val delegates: List<X509TrustManager>
    ) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
            checkAnyTrusted(chain, authType) { trustManager, certChain, type ->
                trustManager.checkClientTrusted(certChain, type)
            }
        }

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
            checkAnyTrusted(chain, authType) { trustManager, certChain, type ->
                trustManager.checkServerTrusted(certChain, type)
            }
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> {
            return delegates
                .flatMap { it.acceptedIssuers.asList() }
                .distinctBy { "${it.subjectX500Principal.name}|${it.serialNumber}" }
                .toTypedArray()
        }

        private fun checkAnyTrusted(
            chain: Array<X509Certificate>,
            authType: String,
            checker: (X509TrustManager, Array<X509Certificate>, String) -> Unit
        ) {
            var lastError: CertificateException? = null
            delegates.forEach { trustManager ->
                try {
                    checker(trustManager, chain, authType)
                    return
                } catch (e: CertificateException) {
                    lastError = e
                }
            }
            throw lastError ?: CertificateException("No trust manager accepted the certificate chain")
        }
    }

    private fun getOrCreateKeyPairPem(context: Context): Pair<String, String> {
        val pref = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val pub = pref.getString(KEY_PUBLIC, null)
        val pri = pref.getString(KEY_PRIVATE, null)
        if (!pub.isNullOrBlank() && !pri.isNullOrBlank()) {
            if (pri.startsWith("android-keystore:")) {
                val alias = pri.removePrefix("android-keystore:")
                val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                val cert = keyStore.getCertificate(alias)
                if (cert != null) {
                    val actualPubPem = toPem("PUBLIC KEY", cert.publicKey.encoded)
                    if (actualPubPem != pub) {
                        pref.edit().putString(KEY_PUBLIC, actualPubPem).putString(KEY_PRIVATE, pri).apply()
                        GatewayDebugLog.add(context, "Gateway key cache refreshed from AndroidKeyStore certificate")
                        return actualPubPem to pri
                    }
                    return pub to pri
                }

                pref.edit().remove(KEY_PUBLIC).remove(KEY_PRIVATE).apply()
            } else {
                return pub to pri
            }
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
        cipher.init(Cipher.ENCRYPT_MODE, key, oaepSha256Spec())
        return Base64.encodeToString(cipher.doFinal(plainBytes), Base64.NO_WRAP)
    }

    private fun decryptChunk(key: PrivateKey, encryptedBase64: String): ByteArray {
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(Cipher.DECRYPT_MODE, key, oaepSha256Spec())
        return cipher.doFinal(Base64.decode(encryptedBase64, Base64.NO_WRAP))
    }

    private fun oaepSha256Spec(): OAEPParameterSpec {
        return OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            MGF1ParameterSpec.SHA256,
            PSource.PSpecified.DEFAULT
        )
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
        val bytes = Base64.decode(publicPem.pemBody(), Base64.NO_WRAP)
        val keyFactory = rawRsaKeyFactory()
        return runCatching {
            keyFactory.generatePublic(X509EncodedKeySpec(bytes))
        }.getOrElse {
            keyFactory.generatePublic(X509EncodedKeySpec(wrapPkcs1PublicKey(bytes)))
        }
    }

    private fun loadPrivateKey(privatePem: String): PrivateKey {
        val bytes = Base64.decode(privatePem.pemBody(), Base64.NO_WRAP)
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
        val b64 = Base64.encodeToString(raw, Base64.NO_WRAP)
        val wrapped = wrapPemBase64Body(b64)
        return "-----BEGIN $title-----\n$wrapped\n-----END $title-----"
    }

    private fun wrapPemBase64Body(base64Text: String): String {
        if (base64Text.isEmpty()) {
            return base64Text
        }

        val out = StringBuilder(base64Text.length + (base64Text.length / 64) + 8)
        var offset = 0
        while (offset < base64Text.length) {
            val end = minOf(offset + 64, base64Text.length)
            out.append(base64Text, offset, end)
            if (end < base64Text.length) {
                out.append('\n')
            }
            offset = end
        }
        return out.toString()
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

    private fun JSONObject.optNullableInt(name: String): Int? {
        return if (has(name) && !isNull(name)) getInt(name) else null
    }

    private fun Throwable.debugSummary(): String {
        val type = this::class.java.simpleName
        val msg = message ?: "(no message)"
        val topFrames = stackTrace
            .take(4)
            .joinToString(" <- ") { frame ->
                "${frame.className.substringAfterLast('.')}.${frame.methodName}:${frame.lineNumber}"
            }
        return if (topFrames.isBlank()) "$type: $msg" else "$type: $msg @ $topFrames"
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
