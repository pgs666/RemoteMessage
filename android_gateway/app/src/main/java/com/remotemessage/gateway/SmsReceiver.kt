package com.remotemessage.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION && action != Telephony.Sms.Intents.SMS_DELIVER_ACTION) return

        val prefs = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val server = prefs.getString("server_base", "") ?: ""
        val deviceId = prefs.getString("device_id", "") ?: ""
        RuntimeConfig.password = prefs.getString("password", prefs.getString("api_key", ""))?.ifBlank { null }
        if (server.isBlank() || deviceId.isBlank()) return

        val cfg = GatewayConfig(serverBaseUrl = server, deviceId = deviceId)
        val intentResolvedSim = GatewaySimSupport.resolveForIntent(context, intent)
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) return

        val first = messages.first()
        val phone = first.originatingAddress ?: "unknown"
        val fullContent = messages.joinToString(separator = "") { it.messageBody ?: "" }
        val timestamp = messages.minOfOrNull { it.timestampMillis } ?: first.timestampMillis

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
}
