package com.remotemessage.gateway

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

class GatewaySyncWorker(
    appContext: Context,
    params: WorkerParameters
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val server = prefs.getString("server_base", "") ?: ""
        val deviceId = prefs.getString("device_id", "") ?: ""
        val simSubId = prefs.getString("sim_sub_id", "")?.toIntOrNull()
        RuntimeConfig.password = prefs.getString("password", prefs.getString("api_key", ""))?.ifBlank { null }
        if (server.isBlank() || deviceId.isBlank()) return Result.success()

        val cfg = GatewayConfig(serverBaseUrl = server, deviceId = deviceId, simSubId = simSubId)
        return runCatching {
            GatewayRuntime.flushPendingUploads(applicationContext, cfg)
            GatewayRuntime.pollAndSendSync(applicationContext, cfg)
            Result.success()
        }.getOrElse {
            Result.retry()
        }
    }

    companion object {
        private const val WORK_NAME = "gateway-periodic-sync"

        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<GatewaySyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()

            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }
}
