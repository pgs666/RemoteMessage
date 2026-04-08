package com.remotemessage.gateway

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.telephony.SubscriptionManager
import android.telephony.SmsManager

class RespondViaMessageService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        runCatching {
            if (intent != null) {
                handleIntent(intent)
            }
        }
        stopSelf(startId)
        return START_NOT_STICKY
    }

    private fun handleIntent(intent: Intent) {
        val body = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: intent.getStringExtra("sms_body")?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: return

        val recipients = intent.data?.schemeSpecificPart
            ?.split(';', ',')
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            .orEmpty()

        if (recipients.isEmpty()) return

        val prefs = getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val simSubId = prefs.getString("sim_sub_id", "")?.toIntOrNull()
        val resolvedSim = GatewaySimSupport.resolveForIntent(this, intent, simSubId)
        val smsManager = when (val subId = resolvedSim.subscriptionId ?: simSubId) {
            null -> SmsManager.getDefault()
            SubscriptionManager.INVALID_SUBSCRIPTION_ID -> SmsManager.getDefault()
            else -> SmsManager.getSmsManagerForSubscriptionId(subId)
        }

        recipients.forEach { phone ->
            smsManager.sendTextMessage(phone, null, body, null, null)
        }
    }
}