package cn.ac.studio.rmg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i("RemoteMessageGateway", "Received WAP push action=${intent.action}")
    }
}