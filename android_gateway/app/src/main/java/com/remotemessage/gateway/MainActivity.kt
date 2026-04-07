package com.remotemessage.gateway

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import fi.iki.elonen.NanoHTTPD

class MainActivity : ComponentActivity() {

    private lateinit var pref: SharedPreferences
    private var webUiServer: GatewayWebUiServer? = null
    private var statusTextView: TextView? = null
    private var syncProgressBar: ProgressBar? = null
    private val realtimeSyncHandler = Handler(Looper.getMainLooper())
    private var realtimeSyncRunnable: Runnable? = null

    @Volatile
    private var realtimeSyncBusy = false

    private val importCertLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val tv = statusTextView ?: return@registerForActivityResult
        if (uri == null) return@registerForActivityResult

        runCatching {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        runCatching {
            GatewayCertificateStore.importFromUri(this, uri)
            tv.text = getString(R.string.status_cert_imported)
        }.onFailure {
            tv.text = getString(R.string.status_cert_import_failed, it.message ?: "unknown")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        pref = getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val editServer = findViewById<EditText>(R.id.editServer)
        val editDeviceId = findViewById<EditText>(R.id.editDeviceId)
        val editSimSubId = findViewById<EditText>(R.id.editSimSubId)
        val editApiKey = findViewById<EditText>(R.id.editApiKey)
        val editWebUiPort = findViewById<EditText>(R.id.editWebUiPort)
        val textStatus = findViewById<TextView>(R.id.textStatus)
        val progressSync = findViewById<ProgressBar>(R.id.progressSync)
        val btnSave = findViewById<Button>(R.id.btnSave)
        val btnRegister = findViewById<Button>(R.id.btnRegister)
        val btnPollOnce = findViewById<Button>(R.id.btnPollOnce)
        val btnSyncHistory = findViewById<Button>(R.id.btnSyncHistory)
        val btnTestLocalSms = findViewById<Button>(R.id.btnTestLocalSms)
        val btnFlushPending = findViewById<Button>(R.id.btnFlushPending)
        val btnImportCert = findViewById<Button>(R.id.btnImportCert)
        val btnRequestSmsRole = findViewById<Button>(R.id.btnRequestSmsRole)
        statusTextView = textStatus
        syncProgressBar = progressSync

        editServer.setText(pref.getString("server_base", "https://10.0.2.2:5001") ?: "")
        editDeviceId.setText(pref.getString("device_id", "android-arm64-gateway") ?: "")
        editSimSubId.setText(pref.getString("sim_sub_id", "") ?: "")
        editApiKey.setText(pref.getString("password", pref.getString("api_key", "")) ?: "")
        editWebUiPort.setText(pref.getString("webui_port", "8088") ?: "8088")

        RuntimeConfig.password = editApiKey.text.toString().trim().ifBlank { null }

        requestPermissionsIfNeeded()
        PermissionAndRoleHelper.requestDefaultSmsRole(this)
        PermissionAndRoleHelper.requestIgnoreBatteryOptimizations(this)
        PermissionAndRoleHelper.openUsageAccessSettings(this)
        GatewaySyncWorker.schedule(this)
        startWebUiServer(editServer, editDeviceId, editSimSubId, editApiKey, editWebUiPort, textStatus)
        startRealtimeSyncLoop(editServer, editDeviceId, editSimSubId, editApiKey, textStatus)

        btnSave.setOnClickListener {
            val serverText = editServer.text.toString().trim()
            val deviceIdText = editDeviceId.text.toString().trim()
            val passwordText = editApiKey.text.toString().trim()
            val port = editWebUiPort.text.toString().trim().toIntOrNull()
            if (serverText.isBlank()) {
                textStatus.text = getString(R.string.status_invalid_server)
                return@setOnClickListener
            }
            if (deviceIdText.isBlank()) {
                textStatus.text = getString(R.string.status_invalid_device)
                return@setOnClickListener
            }
            if (passwordText.isBlank()) {
                textStatus.text = getString(R.string.status_invalid_password)
                return@setOnClickListener
            }
            if (port == null || port !in 1024..65535) {
                textStatus.text = getString(R.string.status_invalid_port)
                return@setOnClickListener
            }

            pref.edit()
                .putString("server_base", serverText)
                .putString("device_id", deviceIdText)
                .putString("sim_sub_id", editSimSubId.text.toString().trim())
                .putString("password", passwordText)
                .putString("webui_port", port.toString())
                .apply()
            RuntimeConfig.password = passwordText
            GatewaySyncWorker.schedule(this)
            restartWebUiServer(editServer, editDeviceId, editSimSubId, editApiKey, editWebUiPort, textStatus)
            textStatus.text = getString(R.string.status_saved_auto_sync)
        }

        btnRegister.setOnClickListener {
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            GatewayRuntime.registerGateway(this, cfg) {
                runOnUiThread {
                    hideProgress()
                    textStatus.text = it
                }
            }
            GatewaySyncWorker.schedule(this)
        }

        btnPollOnce.setOnClickListener {
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            GatewayRuntime.pollAndSend(this, cfg) {
                runOnUiThread {
                    hideProgress()
                    textStatus.text = it
                }
            }
        }

        btnSyncHistory.setOnClickListener {
            showProgress(indeterminate = false, progress = 0, max = 1)
            textStatus.text = getString(R.string.status_history_sync_preparing)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            GatewayRuntime.syncHistoricalSms(this, cfg, onProgress = { processed, total ->
                runOnUiThread {
                    if (total > 0) {
                        showProgress(indeterminate = false, progress = processed, max = total)
                        textStatus.text = getString(R.string.status_history_sync_progress, processed, total)
                    } else {
                        showProgress(indeterminate = true)
                    }
                }
            }) {
                runOnUiThread {
                    hideProgress()
                    textStatus.text = it
                }
            }
        }

        btnTestLocalSms.setOnClickListener {
            GatewayRuntime.inspectLocalSmsAccess(this) {
                runOnUiThread { textStatus.text = it }
            }
        }

        btnFlushPending.setOnClickListener {
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            Thread {
                GatewayRuntime.flushPendingUploads(this, cfg)
                runOnUiThread {
                    hideProgress()
                    textStatus.text = getString(R.string.status_pending_flushed)
                }
            }.start()
        }

        btnImportCert.setOnClickListener {
            importCertLauncher.launch(arrayOf("application/x-x509-ca-cert", "application/pkix-cert", "*/*"))
        }

        btnRequestSmsRole.setOnClickListener {
            PermissionAndRoleHelper.requestDefaultSmsRole(this)
            textStatus.text = if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
                getString(R.string.status_sms_role_held)
            } else {
                getString(R.string.status_sms_role_requested)
            }
        }
    }

    private fun startWebUiServer(
        editServer: EditText,
        editDeviceId: EditText,
        editSimSubId: EditText,
        editApiKey: EditText,
        editWebUiPort: EditText,
        textStatus: TextView
    ) {
        if (webUiServer != null) return
        val port = editWebUiPort.text.toString().trim().toIntOrNull()?.takeIf { it in 1024..65535 } ?: 8088
        webUiServer = GatewayWebUiServer(
            context = this,
            port = port,
            readConfig = {
                GatewayConfig(
                    serverBaseUrl = editServer.text.toString().trim(),
                    deviceId = editDeviceId.text.toString().trim(),
                    simSubId = editSimSubId.text.toString().trim().toIntOrNull()
                )
            },
            onAction = { action ->
                RuntimeConfig.password = editApiKey.text.toString().trim().ifBlank { null }
                val cfg = GatewayConfig(
                    serverBaseUrl = editServer.text.toString().trim(),
                    deviceId = editDeviceId.text.toString().trim(),
                    simSubId = editSimSubId.text.toString().trim().toIntOrNull()
                )
                when (action) {
                    "register" -> {
                        GatewayRuntime.registerGateway(this, cfg) {
                            runOnUiThread { textStatus.text = it }
                        }
                        "register triggered"
                    }

                    "poll" -> {
                        GatewayRuntime.pollAndSend(this, cfg) {
                            runOnUiThread { textStatus.text = it }
                        }
                        "poll triggered"
                    }

                    "syncHistory" -> {
                        GatewayRuntime.syncHistoricalSms(this, cfg) {
                            runOnUiThread { textStatus.text = it }
                        }
                        "history sync triggered"
                    }

                    "flushPending" -> {
                        GatewayRuntime.flushPendingUploads(this, cfg)
                        "pending flushed"
                    }

                    else -> "unknown action"
                }
            }
        )

        runCatching {
            webUiServer?.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
            textStatus.text = getString(R.string.status_webui_lan, port)
        }.onFailure {
            textStatus.text = getString(R.string.status_webui_failed, it.message ?: "unknown")
        }
    }

    private fun restartWebUiServer(
        editServer: EditText,
        editDeviceId: EditText,
        editSimSubId: EditText,
        editApiKey: EditText,
        editWebUiPort: EditText,
        textStatus: TextView
    ) {
        webUiServer?.stop()
        webUiServer = null
        startWebUiServer(editServer, editDeviceId, editSimSubId, editApiKey, editWebUiPort, textStatus)
    }

    private fun startRealtimeSyncLoop(
        editServer: EditText,
        editDeviceId: EditText,
        editSimSubId: EditText,
        editApiKey: EditText,
        textStatus: TextView
    ) {
        stopRealtimeSyncLoop()

        val runnable = object : Runnable {
            override fun run() {
                if (!realtimeSyncBusy && !isFinishing && !isDestroyed) {
                    val cfg = GatewayConfig(
                        serverBaseUrl = editServer.text.toString().trim(),
                        deviceId = editDeviceId.text.toString().trim(),
                        simSubId = editSimSubId.text.toString().trim().toIntOrNull()
                    )
                    RuntimeConfig.password = editApiKey.text.toString().trim().ifBlank { null }

                    if (cfg.serverBaseUrl.isNotBlank() && cfg.deviceId.isNotBlank()) {
                        realtimeSyncBusy = true
                        Thread {
                            runCatching {
                                GatewayRuntime.flushPendingUploads(this@MainActivity, cfg)
                                GatewayRuntime.pollAndSendSync(this@MainActivity, cfg)
                            }.onSuccess { result ->
                                if (result != "No pending message") {
                                    runOnUiThread { textStatus.text = result }
                                }
                            }
                            realtimeSyncBusy = false
                        }.start()
                    }
                }

                realtimeSyncHandler.postDelayed(this, 5_000)
            }
        }

        realtimeSyncRunnable = runnable
        realtimeSyncHandler.postDelayed(runnable, 3_000)
    }

    private fun stopRealtimeSyncLoop() {
        realtimeSyncRunnable?.let { realtimeSyncHandler.removeCallbacks(it) }
        realtimeSyncRunnable = null
        realtimeSyncBusy = false
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100) {
        syncProgressBar?.apply {
            visibility = View.VISIBLE
            isIndeterminate = indeterminate
            if (!indeterminate) {
                this.max = max.coerceAtLeast(1)
                this.progress = progress.coerceIn(0, this.max)
            }
        }
    }

    private fun hideProgress() {
        syncProgressBar?.visibility = View.GONE
    }

    override fun onDestroy() {
        stopRealtimeSyncLoop()
        webUiServer?.stop()
        webUiServer = null
        super.onDestroy()
    }

    private fun requestPermissionsIfNeeded() {
        val perms = mutableListOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        val need = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (need.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, need.toTypedArray(), 1001)
        }
    }
}
