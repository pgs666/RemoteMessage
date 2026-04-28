package cn.ac.studio.rmg

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import cn.ac.studio.rmg.ui.LargeActionCard
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.LinearProgressIndicator
import fi.iki.elonen.NanoHTTPD

class MainActivity : AppCompatActivity() {
    private var webUiServer: GatewayWebUiServer? = null
    private var currentWebUiPort: Int? = null
    private var statusCard: LargeActionCard? = null
    private var connectionCard: LargeActionCard? = null
    private var gatewayCard: LargeActionCard? = null
    private var syncProgressBar: LinearProgressIndicator? = null
    private val syncAnimHandler = Handler(Looper.getMainLooper())
    private var syncAnimRunnable: Runnable? = null
    private lateinit var permissionPref: SharedPreferences

    private val requestRuntimePermissionsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            markPermissionsRequested(result.keys)
            val denied = result.entries.filter { !it.value }.map { it.key }
            if (denied.isEmpty()) {
                setStatus(getString(R.string.status_runtime_permissions_granted))
                return@registerForActivityResult
            }
            val permanentlyDenied = permanentlyDeniedPermissions(denied)
            setStatus(
                if (permanentlyDenied.isEmpty()) {
                    getString(
                        R.string.status_runtime_permissions_denied,
                        GatewayPermissionCenter.summarizePermissions(denied)
                    )
                } else {
                    getString(
                        R.string.status_runtime_permissions_permanently_denied,
                        GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
                    )
                }
            )
            if (permanentlyDenied.isNotEmpty()) {
                showOpenAppSettingsDialog(permanentlyDenied)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        GatewayTheme.apply(this)
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.rootScroll))

        permissionPref = getSharedPreferences(PREF_PERMISSION_STATE, Context.MODE_PRIVATE)
        statusCard = findViewById(R.id.btnPollOnce)
        connectionCard = findViewById(R.id.btnSave)
        gatewayCard = findViewById(R.id.btnRegister)
        syncProgressBar = findViewById(R.id.progressSync)
        setStatus(getString(R.string.status_ready))

        findViewById<View>(R.id.btnSave).setOnClickListener {
            startActivity(Intent(this, ConnectionActivity::class.java))
        }
        findViewById<View>(R.id.btnRegister).setOnClickListener { registerGateway() }
        findViewById<View>(R.id.btnPollOnce).setOnClickListener { pollOnce() }
        findViewById<View>(R.id.btnOpenLogPage).setOnClickListener {
            startActivity(Intent(this, GatewayLogActivity::class.java))
        }
        findViewById<View>(R.id.btnPermissionTools).setOnClickListener {
            startActivity(Intent(this, GatewaySettingsActivity::class.java))
        }

        GatewaySyncWorker.schedule(this)
        GatewayForegroundService.start(this)
    }

    override fun onResume() {
        super.onResume()
        RuntimeConfig.password = GatewaySecretStore.loadPassword(this)
        refreshDashboardSummaries()
        restartWebUiServerIfPortChanged()
    }

    private fun registerGateway() {
        val cfg = validSavedConfigOrNull() ?: return
        showProgress(indeterminate = true)
        GatewayRuntime.registerGateway(this, cfg) {
            runOnUiThread {
                hideProgress()
                setStatus(it)
                refreshDashboardSummaries()
            }
        }
        GatewaySyncWorker.schedule(this)
        GatewayForegroundService.start(this)
    }

    private fun pollOnce() {
        if (!ensureRuntimePermissionsForAction(GatewayPermissionCenter.sendSmsPermissions())) {
            return
        }
        val cfg = validSavedConfigOrNull() ?: return
        showProgress(indeterminate = true)
        GatewayRuntime.pollAndSend(this, cfg) {
            runOnUiThread {
                hideProgress()
                setStatus(it)
            }
        }
    }

    private fun validSavedConfigOrNull(): GatewayConfig? {
        val values = GatewayConfigStore.load(this)
        if (values.serverBaseUrl.isBlank()) {
            setStatus(getString(R.string.status_invalid_server))
            return null
        }
        if (values.deviceId.isBlank()) {
            setStatus(getString(R.string.status_invalid_device))
            return null
        }
        RuntimeConfig.password = values.password.ifBlank { null }
        return GatewayConfig(values.serverBaseUrl, values.deviceId)
    }

    private fun refreshDashboardSummaries() {
        val values = GatewayConfigStore.load(this)
        connectionCard?.subtext = if (values.serverBaseUrl.isBlank()) {
            getString(R.string.summary_connection_unconfigured)
        } else {
            getString(R.string.summary_connection_configured, values.serverBaseUrl, values.webUiPort)
        }
        gatewayCard?.subtext = values.deviceId.ifBlank { getString(R.string.summary_gateway_unregistered) }
    }

    private fun ensureRuntimePermissionsForAction(required: List<String>): Boolean {
        val missing = GatewayPermissionCenter.missingRuntimePermissions(this, required)
        if (missing.isEmpty()) {
            return true
        }
        val permanentlyDenied = permanentlyDeniedPermissions(missing)
        if (permanentlyDenied.isNotEmpty()) {
            setStatus(
                getString(
                    R.string.status_runtime_permissions_permanently_denied,
                    GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
                )
            )
            showOpenAppSettingsDialog(permanentlyDenied)
            return false
        }
        setStatus(
            getString(
                R.string.status_runtime_permissions_missing,
                GatewayPermissionCenter.summarizePermissions(missing)
            )
        )
        launchRuntimePermissionRequest(missing)
        return false
    }

    private fun launchRuntimePermissionRequest(permissions: Collection<String>) {
        val uniquePermissions = permissions.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (uniquePermissions.isEmpty()) {
            return
        }
        markPermissionsRequested(uniquePermissions)
        requestRuntimePermissionsLauncher.launch(uniquePermissions.toTypedArray())
    }

    private fun permanentlyDeniedPermissions(permissions: Collection<String>): List<String> {
        return permissions
            .filter { permission ->
                ContextCompat.checkSelfPermission(this, permission) != PackageManager.PERMISSION_GRANTED
            }
            .filter { permission ->
                wasPermissionRequested(permission) && !shouldShowRequestPermissionRationale(permission)
            }
    }

    private fun markPermissionsRequested(permissions: Collection<String>) {
        val filtered = permissions.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        if (filtered.isEmpty()) {
            return
        }
        val editor = permissionPref.edit()
        filtered.forEach { permission ->
            editor.putBoolean(permissionRequestedKey(permission), true)
        }
        editor.apply()
    }

    private fun wasPermissionRequested(permission: String): Boolean {
        return permissionPref.getBoolean(permissionRequestedKey(permission), false)
    }

    private fun permissionRequestedKey(permission: String): String {
        return "requested_" + permission.replace('.', '_')
    }

    private fun showOpenAppSettingsDialog(permissions: Collection<String>) {
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.title_permission_settings_required))
            .setMessage(
                getString(
                    R.string.message_permission_settings_required,
                    GatewayPermissionCenter.summarizePermissions(permissions)
                )
            )
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.action_open_app_settings) { _, _ ->
                PermissionAndRoleHelper.openAppDetailsSettings(this)
                setStatus(getString(R.string.status_app_settings_opened))
            }
            .show()
    }

    private fun startWebUiServer() {
        if (webUiServer != null) return
        val port = GatewayConfigStore.webUiPort(this)
        currentWebUiPort = port
        webUiServer = GatewayWebUiServer(
            context = this,
            port = port,
            readConfig = { GatewayConfigStore.loadRuntimeConfig(this) },
            onAction = { action ->
                val cfg = GatewayConfigStore.loadRuntimeConfig(this)
                when (action) {
                    "register" -> {
                        GatewayRuntime.registerGateway(this, cfg) {
                            runOnUiThread { setStatus(it) }
                        }
                        "register triggered"
                    }

                    "poll" -> {
                        GatewayRuntime.pollAndSend(this, cfg) {
                            runOnUiThread { setStatus(it) }
                        }
                        "poll triggered"
                    }

                    "syncHistory" -> {
                        GatewayRuntime.syncHistoricalSms(this, cfg) {
                            runOnUiThread { setStatus(it) }
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
            setStatus(getString(R.string.status_webui_lan, port))
        }.onFailure {
            setStatus(getString(R.string.status_webui_failed, it.message ?: "unknown"))
        }
    }

    private fun restartWebUiServerIfPortChanged() {
        val desiredPort = GatewayConfigStore.webUiPort(this)
        if (webUiServer != null && currentWebUiPort == desiredPort) {
            return
        }
        webUiServer?.stop()
        webUiServer = null
        startWebUiServer()
    }

    private fun setStatus(text: CharSequence) {
        statusCard?.subtext = text
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100) {
        showProgress(indeterminate, progress, max, animate = false)
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100, animate: Boolean = false) {
        syncProgressBar?.apply {
            visibility = View.VISIBLE
            this.isIndeterminate = indeterminate
            if (!indeterminate) {
                this.max = max.coerceAtLeast(1)
                val target = progress.coerceIn(0, this.max)
                setProgressCompat(target, animate)
            }
        }

        if (indeterminate) {
            startProgressPulse()
        } else {
            stopProgressPulse()
        }
    }

    private fun hideProgress() {
        stopProgressPulse()
        syncProgressBar?.visibility = View.GONE
    }

    private fun startProgressPulse() {
        if (syncAnimRunnable != null) return
        val bar = syncProgressBar ?: return
        bar.isIndeterminate = false
        bar.max = 100
        val runnable = object : Runnable {
            private var value = 0
            private var direction = 1

            override fun run() {
                val progressBar = syncProgressBar ?: return
                if (progressBar.visibility != View.VISIBLE) return
                value += 8 * direction
                if (value >= 90) {
                    value = 90
                    direction = -1
                } else if (value <= 10) {
                    value = 10
                    direction = 1
                }

                progressBar.setProgressCompat(value, true)
                syncAnimHandler.postDelayed(this, 120)
            }
        }
        syncAnimRunnable = runnable
        syncAnimHandler.post(runnable)
    }

    private fun stopProgressPulse() {
        syncAnimRunnable?.let { syncAnimHandler.removeCallbacks(it) }
        syncAnimRunnable = null
    }

    override fun onDestroy() {
        stopProgressPulse()
        webUiServer?.stop()
        webUiServer = null
        super.onDestroy()
    }

    companion object {
        private const val PREF_PERMISSION_STATE = "gateway_permission_state"
    }
}
