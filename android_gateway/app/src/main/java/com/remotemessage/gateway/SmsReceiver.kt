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
        messages.forEach { sms ->
            val resolvedSim = if (intentResolvedSim.slotIndex != null || !intentResolvedSim.simPhoneNumber.isNullOrBlank()) {
                intentResolvedSim
            } else {
                GatewaySimSupport.resolveForSmsRecord(
                    context = context,
                    phone = sms.originatingAddress ?: "unknown",
                    content = sms.messageBody ?: "",
                    timestamp = sms.timestampMillis,
                    inbound = true
                )
            }
            val direction = "inbound"
            val msgId = GatewayRuntime.buildMessageId(
                deviceId = cfg.deviceId,
                phone = sms.originatingAddress ?: "unknown",
                content = sms.messageBody ?: "",
                timestamp = sms.timestampMillis,
                direction = direction,
                simSlotIndex = resolvedSim.slotIndex
            )
            GatewayRuntime.uploadInboundSms(
                context = context,
                cfg = cfg,
                phone = sms.originatingAddress ?: "unknown",
                content = sms.messageBody ?: "",
                timestamp = sms.timestampMillis,
                direction = direction,
                messageId = msgId,
                simSlotIndex = resolvedSim.slotIndex,
                simPhoneNumber = resolvedSim.simPhoneNumber,
                simCount = resolvedSim.simCount.takeIf { it > 0 }
            )
        }
    }
}
