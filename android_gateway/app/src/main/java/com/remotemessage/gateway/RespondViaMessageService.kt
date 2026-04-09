package com.remotemessage.gateway

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.telephony.SmsManager

class RespondViaMessageService : Service() {
    private val invalidSubscriptionId = -1

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
        if (!GatewayPermissionCenter.hasAllRuntimePermissions(this, GatewayPermissionCenter.sendSmsPermissions())) {
            GatewayDebugLog.add(this, "RespondViaMessage skipped: missing SEND_SMS permission")
            return
        }

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

        val resolvedSim = GatewaySimSupport.resolveForIntent(this, intent)
        val smsManager = smsManagerForSubscriptionId(resolvedSim.subscriptionId)

        recipients.forEach { phone ->
            val parts = smsManager.divideMessage(body)
            if (parts.size <= 1) {
                smsManager.sendTextMessage(phone, null, body, null, null)
            } else {
                smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
            }
        }
    }

    private fun smsManagerForSubscriptionId(subscriptionId: Int?): SmsManager {
        if (subscriptionId == null || subscriptionId == invalidSubscriptionId) {
            return SmsManager.getDefault()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            val specificManager = runCatching {
                val method = SmsManager::class.java.getMethod("getSmsManagerForSubscriptionId", Int::class.javaPrimitiveType!!)
                method.invoke(null, subscriptionId) as? SmsManager
            }.getOrNull()
            if (specificManager != null) {
                return specificManager
            }
        }
        return SmsManager.getDefault()
    }
}
