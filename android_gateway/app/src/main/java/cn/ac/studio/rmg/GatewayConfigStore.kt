package cn.ac.studio.rmg

import android.content.Context
import android.os.Build
import org.json.JSONObject

object GatewayConfigStore {
    const val PREF_NAME = "gateway_config"
    private const val KEY_SYNC_ENABLED = "sync_enabled"

    data class Values(
        val serverBaseUrl: String,
        val deviceId: String,
        val password: String,
        val webUiPort: String
    )

    data class OnboardingQrPayload(
        val serverBaseUrl: String,
        val clientToken: String,
        val gatewayToken: String
    )

    fun load(context: Context): Values {
        val pref = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val storedDeviceId = pref.getString("device_id", null)?.trim().orEmpty()
        return Values(
            serverBaseUrl = pref.getString("server_base", "")?.trim().orEmpty(),
            deviceId = storedDeviceId.ifBlank { defaultGatewayDeviceId() },
            password = GatewaySecretStore.loadPassword(context).orEmpty(),
            webUiPort = pref.getString("webui_port", "8088")?.trim().orEmpty().ifBlank { "8088" }
        )
    }

    fun loadRuntimeConfig(context: Context): GatewayConfig {
        val values = load(context)
        RuntimeConfig.password = values.password.ifBlank { null }
        return GatewayConfig(
            serverBaseUrl = values.serverBaseUrl.trim(),
            deviceId = values.deviceId.trim()
        )
    }

    fun save(context: Context, values: Values): GatewayConfig {
        val server = values.serverBaseUrl.trim()
        val device = values.deviceId.trim()
        val password = values.password.trim()
        val port = normalizePort(values.webUiPort)
            ?: throw IllegalArgumentException("Port must be 1024-65535")

        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("server_base", server)
            .putString("device_id", device)
            .remove("sim_sub_id")
            .putString("webui_port", port.toString())
            .apply()

        GatewaySecretStore.savePassword(context, password)
        RuntimeConfig.password = password.ifBlank { null }
        if (isSyncEnabled(context)) {
            GatewaySyncWorker.schedule(context)
            GatewayForegroundService.start(context)
        }
        return GatewayConfig(serverBaseUrl = server, deviceId = device)
    }

    fun isSyncEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_SYNC_ENABLED, true)
    }

    fun setSyncEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SYNC_ENABLED, enabled)
            .apply()

        if (enabled) {
            GatewaySyncWorker.schedule(context)
            GatewayForegroundService.start(context)
        } else {
            GatewaySyncWorker.cancel(context)
            GatewayForegroundService.stop(context)
        }
    }

    fun webUiPort(context: Context): Int {
        return normalizePort(load(context).webUiPort) ?: 8088
    }

    fun normalizePort(raw: String): Int? {
        return raw.trim().toIntOrNull()?.takeIf { it in 1024..65535 }
    }

    fun defaultGatewayDeviceId(): String {
        val model = Build.MODEL?.trim().orEmpty()
        if (model.isNotBlank()) {
            return model.replace(Regex("\\s+"), "-").take(96)
        }
        return "android-gateway"
    }

    fun parseOnboardingPayload(raw: String): OnboardingQrPayload? {
        val text = raw.trim()
        if (text.isEmpty()) {
            return null
        }

        return runCatching {
            if (text.startsWith("{")) {
                val json = JSONObject(text)
                val server = json.optString("serverBaseUrl", "").trim()
                val clientToken = json.optString("clientToken", "").trim()
                val gatewayToken = json.optString("gatewayToken", "").trim()
                if (server.isBlank() || clientToken.isBlank() || gatewayToken.isBlank()) {
                    null
                } else {
                    OnboardingQrPayload(server, clientToken, gatewayToken)
                }
            } else {
                val parts = text.split('|')
                if (parts.size < 4 || parts[0].trim() != "RMS1") {
                    null
                } else {
                    val server = parts[1].trim()
                    val clientToken = parts[2].trim()
                    val gatewayToken = parts[3].trim()
                    if (server.isBlank() || clientToken.isBlank() || gatewayToken.isBlank()) {
                        null
                    } else {
                        OnboardingQrPayload(server, clientToken, gatewayToken)
                    }
                }
            }
        }.getOrNull()
    }
}
