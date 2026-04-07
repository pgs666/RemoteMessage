package com.remotemessage.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val prefs = context.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val server = prefs.getString("server_base", "") ?: ""
        val deviceId = prefs.getString("device_id", "") ?: ""
        if (server.isBlank() || deviceId.isBlank()) return

        val cfg = GatewayConfig(serverBaseUrl = server, deviceId = deviceId)
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        messages.forEach { sms ->
            val direction = "inbound"
            val msgId = GatewayRuntime.buildMessageId(
                deviceId = cfg.deviceId,
                phone = sms.originatingAddress ?: "unknown",
                content = sms.messageBody ?: "",
                timestamp = sms.timestampMillis,
                direction = direction
            )
            GatewayRuntime.uploadInboundSms(
                context = context,
                cfg = cfg,
                phone = sms.originatingAddress ?: "unknown",
                content = sms.messageBody ?: "",
                timestamp = sms.timestampMillis,
                direction = direction,
                messageId = msgId
            )
        }
    }
}
