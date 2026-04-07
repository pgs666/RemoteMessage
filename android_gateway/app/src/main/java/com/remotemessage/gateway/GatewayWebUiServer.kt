package com.remotemessage.gateway

import android.content.Context
import fi.iki.elonen.NanoHTTPD

class GatewayWebUiServer(
    context: Context,
    port: Int,
    private val readConfig: () -> GatewayConfig,
    private val onAction: (String) -> String
) : NanoHTTPD("0.0.0.0", port) {

    @Suppress("unused")
    private val appContext = context.applicationContext

    override fun serve(session: IHTTPSession): Response {
        val remote = session.remoteIpAddress ?: ""
        if (!isLanOrLocal(remote)) {
            return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "LAN only")
        }

        if (session.uri == "/api/action") {
            val action = session.parameters["name"]?.firstOrNull() ?: ""
            val result = onAction(action)
            return newFixedLengthResponse(Response.Status.OK, "application/json", "{\"result\":\"$result\"}")
        }

        val cfg = readConfig()
        val isZh = session.headers["accept-language"]?.contains("zh", ignoreCase = true) == true
        val title = if (isZh) "RemoteMessage 网关" else "RemoteMessage Gateway"
        val serverLabel = if (isZh) "服务器" else "Server"
        val deviceLabel = if (isZh) "设备" else "Device"
        val simLabel = if (isZh) "SIM 子卡" else "SIM SubId"
        val registerText = if (isZh) "注册" else "Register"
        val pollText = if (isZh) "轮询一次" else "Poll Once"
        val syncText = if (isZh) "同步历史短信" else "Sync History"
        val flushText = if (isZh) "补传待发送队列" else "Flush Pending"
        val html = """
            <html><head><meta name='viewport' content='width=device-width,initial-scale=1' />
            <title>$title</title></head>
            <body style='font-family: sans-serif; margin: 16px;'>
              <h2>$title</h2>
              <p>$serverLabel: ${cfg.serverBaseUrl}</p>
              <p>$deviceLabel: ${cfg.deviceId}</p>
              <p>$simLabel: ${cfg.simSubId ?: if (isZh) "默认" else "default"}</p>
              <button onclick="doAct('register')">$registerText</button>
              <button onclick="doAct('poll')">$pollText</button>
              <button onclick="doAct('syncHistory')">$syncText</button>
              <button onclick="doAct('flushPending')">$flushText</button>
              <pre id='out'></pre>
              <script>
                async function doAct(name){
                  const r = await fetch('/api/action?name='+encodeURIComponent(name));
                  const t = await r.text();
                  document.getElementById('out').textContent = t;
                }
              </script>
            </body></html>
        """.trimIndent()

        return newFixedLengthResponse(Response.Status.OK, "text/html", html)
    }

    private fun isLanOrLocal(ip: String): Boolean {
        return ip == "127.0.0.1" ||
            ip == "::1" ||
            ip.startsWith("192.168.") ||
            ip.startsWith("10.") ||
            ip.startsWith("172.16.") ||
            ip.startsWith("172.17.") ||
            ip.startsWith("172.18.") ||
            ip.startsWith("172.19.") ||
            ip.startsWith("172.2") ||
            ip.startsWith("172.30.") ||
            ip.startsWith("172.31.")
    }
}
