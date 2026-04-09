package cn.ac.studio.rmg

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
        val title = "RemoteMessage Gateway"
        val serverLabel = "Server"
        val deviceLabel = "Device"
        val simLabel = "SIM Info"
        val registerText = "Register"
        val pollText = "Poll Once"
        val syncText = "Sync History"
        val flushText = "Flush Pending"
        val simSummary = GatewaySimSupport.buildSummaryText(appContext, isZh = false).replace("\n", "<br/>")
        val html = """
            <html><head><meta name='viewport' content='width=device-width,initial-scale=1' />
            <title>$title</title></head>
            <body style='font-family: sans-serif; margin: 16px;'>
              <h2>$title</h2>
              <p>$serverLabel: ${cfg.serverBaseUrl}</p>
              <p>$deviceLabel: ${cfg.deviceId}</p>
              <p>$simLabel: $simSummary</p>
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
