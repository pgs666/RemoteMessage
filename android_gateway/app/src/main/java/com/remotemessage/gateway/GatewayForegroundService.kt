package com.remotemessage.gateway

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean

class GatewayForegroundService : Service() {

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var syncLoopJob: Job? = null
    private val syncInProgress = AtomicBoolean(false)

    @Volatile
    private var missingPermissionLogged = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification(getString(R.string.fg_sync_starting)))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> startSyncLoopIfNeeded()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        syncLoopJob?.cancel()
        syncLoopJob = null
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun startSyncLoopIfNeeded() {
        if (syncLoopJob?.isActive == true) {
            return
        }
        syncLoopJob = serviceScope.launch {
            while (isActive) {
                runSyncCycle()
                delay(SYNC_INTERVAL_MS)
            }
        }
    }

    private fun runSyncCycle() {
        if (!syncInProgress.compareAndSet(false, true)) {
            return
        }
        try {
            val prefs = getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
            val server = prefs.getString("server_base", "")?.trim().orEmpty()
            val deviceId = prefs.getString("device_id", "")?.trim().orEmpty()
            RuntimeConfig.password = prefs.getString("password", prefs.getString("api_key", ""))?.ifBlank { null }

            if (server.isBlank() || deviceId.isBlank()) {
                updateNotification(getString(R.string.fg_sync_waiting_config))
                return
            }

            val cfg = GatewayConfig(serverBaseUrl = server, deviceId = deviceId)
            runCatching {
                GatewayRuntime.pushSimStateSync(this, cfg)
            }.onFailure {
                GatewayDebugLog.add(this, "Foreground sync step failed: pushSimStateSync: ${it.message}")
            }

            runCatching {
                GatewayRuntime.flushPendingUploads(this, cfg)
            }.onFailure {
                GatewayDebugLog.add(this, "Foreground sync step failed: flushPendingUploads: ${it.message}")
            }

            if (!GatewayPermissionCenter.hasAllRuntimePermissions(this, GatewayPermissionCenter.sendSmsPermissions())) {
                if (!missingPermissionLogged) {
                    GatewayDebugLog.add(this, "Foreground sync skipped poll/send: missing SEND_SMS permission")
                    missingPermissionLogged = true
                }
                updateNotification(getString(R.string.fg_sync_missing_send_permission))
                return
            }

            missingPermissionLogged = false
            runCatching {
                GatewayRuntime.pollAndSendSync(this, cfg)
            }.onSuccess { result ->
                if (result == "No pending message") {
                    updateNotification(getString(R.string.fg_sync_running))
                } else {
                    updateNotification(result)
                }
            }.onFailure {
                GatewayDebugLog.add(this, "Foreground sync step failed: pollAndSendSync: ${it.message}")
                updateNotification(getString(R.string.fg_sync_error, it.message ?: "unknown"))
            }
        } finally {
            syncInProgress.set(false)
        }
    }

    private fun updateNotification(content: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        manager.notify(NOTIFICATION_ID, buildNotification(content))
    }

    private fun buildNotification(content: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, flags)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(getString(R.string.fg_sync_title))
            .setContentText(content.take(120))
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.fg_sync_channel_name),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = getString(R.string.fg_sync_channel_desc)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val ACTION_START = "com.remotemessage.gateway.action.START_SYNC"
        private const val ACTION_STOP = "com.remotemessage.gateway.action.STOP_SYNC"
        private const val NOTIFICATION_ID = 10010
        private const val CHANNEL_ID = "gateway_foreground_sync"
        private const val SYNC_INTERVAL_MS = 5_000L

        fun start(context: Context) {
            val intent = Intent(context, GatewayForegroundService::class.java).setAction(ACTION_START)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, GatewayForegroundService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
