package com.remotemessage.gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class SmsSendStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != GatewaySmsStatusContract.ACTION_SMS_SENT_STATUS) {
            return
        }
        GatewayRuntime.handleSmsSentResult(context.applicationContext, intent, resultCode)
    }
}
