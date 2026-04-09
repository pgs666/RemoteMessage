package com.remotemessage.gateway

import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import kotlin.math.abs

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION && action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return

        val first = messages.first()
        val phone = first.originatingAddress ?: "unknown"
        val fullContent = messages.joinToString(separator = "") { it.messageBody ?: "" }
        val timestamp = messages.minOfOrNull { it.timestampMillis } ?: first.timestampMillis
        val intentResolvedSim = GatewaySimSupport.resolveForIntent(context, intent)

        val resolvedSim = if (intentResolvedSim.slotIndex != null || !intentResolvedSim.simPhoneNumber.isNullOrBlank()) {
            intentResolvedSim
        } else {
            GatewaySimSupport.resolveForSmsRecord(
                context = context,
                phone = phone,
                content = fullContent,
                timestamp = timestamp,
                inbound = true
            )
        }

        if (PermissionAndRoleHelper.isDefaultSmsApp(context)) {
            runCatching {
                writeInboundSmsToSystemProvider(
                    context = context,
                    phone = phone,
                    content = fullContent,
                    timestamp = timestamp,
                    subscriptionId = resolvedSim.subscriptionId
                )
            }.onFailure {
                GatewayDebugLog.add(context, "System inbox insert failed: ${it.message}")
            }
        }

        val prefs = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val server = prefs.getString("server_base", "") ?: ""
        val deviceId = prefs.getString("device_id", "") ?: ""
        RuntimeConfig.password = prefs.getString("password", prefs.getString("api_key", ""))?.ifBlank { null }
        if (server.isBlank() || deviceId.isBlank()) return

        val cfg = GatewayConfig(serverBaseUrl = server, deviceId = deviceId)
        val direction = "inbound"
        val msgId = GatewayRuntime.buildMessageId(
            deviceId = cfg.deviceId,
            phone = phone,
            content = fullContent,
            timestamp = timestamp,
            direction = direction,
            simSlotIndex = resolvedSim.slotIndex
        )
        GatewayRuntime.uploadInboundSms(
            context = context,
            cfg = cfg,
            phone = phone,
            content = fullContent,
            timestamp = timestamp,
            direction = direction,
            messageId = msgId,
            simSlotIndex = resolvedSim.slotIndex,
            simPhoneNumber = resolvedSim.simPhoneNumber,
            simCount = resolvedSim.simCount.takeIf { it > 0 }
        )
    }

    private fun writeInboundSmsToSystemProvider(
        context: Context,
        phone: String,
        content: String,
        timestamp: Long,
        subscriptionId: Int?
    ) {
        if (isLikelyDuplicateInbound(context, phone, content, timestamp)) {
            GatewayDebugLog.add(context, "System inbox insert skipped (duplicate): $phone")
            return
        }

        val values = ContentValues().apply {
            put(Telephony.Sms.ADDRESS, phone)
            put(Telephony.Sms.BODY, content)
            put(Telephony.Sms.DATE, timestamp)
            put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_INBOX)
            put(Telephony.Sms.READ, 0)
            put(Telephony.Sms.SEEN, 0)
            if (subscriptionId != null) {
                put("subscription_id", subscriptionId)
                put("sub_id", subscriptionId)
            }
        }

        val insertedUri = context.contentResolver.insert(Telephony.Sms.Inbox.CONTENT_URI, values)
        if (insertedUri != null) {
            GatewayDebugLog.add(context, "System inbox insert success: $insertedUri")
        } else {
            GatewayDebugLog.add(context, "System inbox insert returned null")
        }
    }

    private fun isLikelyDuplicateInbound(
        context: Context,
        phone: String,
        content: String,
        timestamp: Long
    ): Boolean {
        val windowStart = (timestamp - 2 * 60 * 1000L).coerceAtLeast(0L)
        val windowEnd = timestamp + 2 * 60 * 1000L
        val selection = "${Telephony.Sms.TYPE} = ? AND ${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.DATE} BETWEEN ? AND ?"
        val selectionArgs = arrayOf(
            Telephony.Sms.MESSAGE_TYPE_INBOX.toString(),
            phone,
            windowStart.toString(),
            windowEnd.toString()
        )
        val projection = arrayOf(Telephony.Sms.BODY, Telephony.Sms.DATE)

        val cursor = context.contentResolver.query(
            Telephony.Sms.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            "${Telephony.Sms.DATE} DESC"
        ) ?: return false

        cursor.use {
            val bodyIdx = it.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = it.getColumnIndexOrThrow(Telephony.Sms.DATE)
            while (it.moveToNext()) {
                val candidateBody = it.getString(bodyIdx).orEmpty()
                val candidateTs = it.getLong(dateIdx)
                if (abs(candidateTs - timestamp) <= 2 * 60 * 1000L && candidateBody == content) {
                    return true
                }
            }
        }
        return false
    }
}
