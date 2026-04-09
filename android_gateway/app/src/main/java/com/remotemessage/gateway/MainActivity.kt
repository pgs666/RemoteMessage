package com.remotemessage.gateway

import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.animation.LinearInterpolator
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import fi.iki.elonen.NanoHTTPD

class MainActivity : ComponentActivity() {

    private lateinit var pref: SharedPreferences
    private var webUiServer: GatewayWebUiServer? = null
    private var statusTextView: TextView? = null
    private var syncProgressBar: ProgressBar? = null
    private val syncAnimHandler = Handler(Looper.getMainLooper())
    private var syncAnimRunnable: Runnable? = null
    private lateinit var permissionPref: SharedPreferences

    private val requestSmsRoleLauncher = registerForActivityResult(StartActivityForResult()) {
        statusTextView?.text = if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
            getString(R.string.status_sms_role_held)
        } else {
            getString(R.string.status_sms_role_requested)
        }
    }

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

    private val requestRuntimePermissionsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            val tv = statusTextView ?: return@registerForActivityResult
            markPermissionsRequested(result.keys)
            val denied = result.entries.filter { !it.value }.map { it.key }
            if (denied.isEmpty()) {
                tv.text = getString(R.string.status_runtime_permissions_granted)
                return@registerForActivityResult
            }
            val permanentlyDenied = permanentlyDeniedPermissions(denied)
            tv.text = if (permanentlyDenied.isEmpty()) {
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
            if (permanentlyDenied.isNotEmpty()) {
                showOpenAppSettingsDialog(tv, permanentlyDenied)
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        pref = getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        permissionPref = getSharedPreferences(PREF_PERMISSION_STATE, Context.MODE_PRIVATE)
        val editServer = findViewById<EditText>(R.id.editServer)
        val editDeviceId = findViewById<EditText>(R.id.editDeviceId)
        val editApiKey = findViewById<EditText>(R.id.editApiKey)
        val editWebUiPort = findViewById<EditText>(R.id.editWebUiPort)
        val textStatus = findViewById<TextView>(R.id.textStatus)
        val textSimInfo = findViewById<TextView>(R.id.textSimInfo)
        val progressSync = findViewById<ProgressBar>(R.id.progressSync)
        val btnSave = findViewById<Button>(R.id.btnSave)
        val btnRegister = findViewById<Button>(R.id.btnRegister)
        val btnPollOnce = findViewById<Button>(R.id.btnPollOnce)
        val btnSyncHistory = findViewById<Button>(R.id.btnSyncHistory)
        val btnTestLocalSms = findViewById<Button>(R.id.btnTestLocalSms)
        val btnFlushPending = findViewById<Button>(R.id.btnFlushPending)
        val btnImportCert = findViewById<Button>(R.id.btnImportCert)
        val btnPermissionTools = findViewById<Button>(R.id.btnPermissionTools)
        val btnOpenLogPage = findViewById<Button>(R.id.btnOpenLogPage)
        val btnGatewayDataTools = findViewById<Button>(R.id.btnGatewayDataTools)
        statusTextView = textStatus
        syncProgressBar = progressSync

        editServer.setText(pref.getString("server_base", "https://10.0.2.2:5001") ?: "")
        editDeviceId.setText(pref.getString("device_id", "android-arm64-gateway") ?: "")
        editApiKey.setText(GatewaySecretStore.loadPassword(this) ?: "")
        editWebUiPort.setText(pref.getString("webui_port", "8088") ?: "8088")
        textSimInfo.text = GatewaySimSupport.buildSummaryText(this, isZh = resources.configuration.locales[0].language.startsWith("zh"))

        RuntimeConfig.password = GatewaySecretStore.loadPassword(this)

        GatewaySyncWorker.schedule(this)
        startWebUiServer(editServer, editDeviceId, editApiKey, editWebUiPort, textStatus)
        GatewayForegroundService.start(this)

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
                .remove("sim_sub_id")
                .putString("webui_port", port.toString())
                .apply()
            GatewaySecretStore.savePassword(this, passwordText)
            RuntimeConfig.password = passwordText
            val cfg = GatewayConfig(
                serverBaseUrl = serverText,
                deviceId = deviceIdText
            )
            GatewaySyncWorker.schedule(this)
            GatewayForegroundService.start(this)
            restartWebUiServer(editServer, editDeviceId, editApiKey, editWebUiPort, textStatus)
            textSimInfo.text = GatewaySimSupport.buildSummaryText(this, isZh = resources.configuration.locales[0].language.startsWith("zh"))
            textStatus.text = getString(R.string.status_saved_auto_sync)
            GatewayRuntime.pushSimState(this, cfg) {
                runOnUiThread {
                    textStatus.text = getString(R.string.status_saved_auto_sync)
                }
            }
        }

        btnRegister.setOnClickListener {
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim()
            )
            GatewayRuntime.registerGateway(this, cfg) {
                runOnUiThread {
                    hideProgress()
                    textStatus.text = it
                    textSimInfo.text = GatewaySimSupport.buildSummaryText(this, isZh = resources.configuration.locales[0].language.startsWith("zh"))
                }
            }
            GatewaySyncWorker.schedule(this)
            GatewayForegroundService.start(this)
        }

        btnPollOnce.setOnClickListener {
            if (!ensureRuntimePermissionsForAction(textStatus, GatewayPermissionCenter.sendSmsPermissions())) {
                return@setOnClickListener
            }
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim()
            )
            GatewayRuntime.pollAndSend(this, cfg) {
                runOnUiThread {
                    hideProgress()
                    textStatus.text = it
                }
            }
        }

        btnSyncHistory.setOnClickListener {
            if (!ensureRuntimePermissionsForAction(textStatus, GatewayPermissionCenter.readSmsPermissions())) {
                return@setOnClickListener
            }
            showProgress(indeterminate = false, progress = 0, max = 1)
            textStatus.text = getString(R.string.status_history_sync_preparing)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim()
            )
            GatewayRuntime.syncHistoricalSms(this, cfg, onProgress = { processed, total ->
                runOnUiThread {
                    if (total > 0) {
                        showProgress(indeterminate = false, progress = processed, max = total, animate = true)
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
            if (!ensureRuntimePermissionsForAction(textStatus, GatewayPermissionCenter.readSmsPermissions())) {
                return@setOnClickListener
            }
            GatewayRuntime.inspectLocalSmsAccess(this) {
                runOnUiThread { textStatus.text = it }
            }
        }

        textSimInfo.setOnLongClickListener {
            textSimInfo.text = GatewaySimSupport.buildSummaryText(this, isZh = resources.configuration.locales[0].language.startsWith("zh"))
            Toast.makeText(this, getString(R.string.status_sim_info_refreshed), Toast.LENGTH_SHORT).show()
            true
        }

        btnFlushPending.setOnClickListener {
            showProgress(indeterminate = true)
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim()
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

        btnPermissionTools.setOnClickListener {
            showPermissionToolsDialog(textStatus)
        }

        btnOpenLogPage.setOnClickListener {
            startActivity(Intent(this, GatewayLogActivity::class.java))
        }

        btnGatewayDataTools.setOnClickListener {
            showGatewayDataToolsDialog(
                editServer = editServer,
                editDeviceId = editDeviceId,
                editApiKey = editApiKey,
                textSimInfo = textSimInfo,
                textStatus = textStatus
            )
        }
    }

    private fun showPermissionToolsDialog(textStatus: TextView) {
        val items = arrayOf(
            getString(R.string.item_request_runtime_permissions),
            getString(R.string.item_request_default_sms_role),
            getString(R.string.item_request_usage_access),
            getString(R.string.item_request_battery_optimization),
            getString(R.string.item_view_permission_status),
            getString(R.string.item_open_app_settings)
        )
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_permission_tools))
            .setItems(items) { _, which ->
                when (which) {
                    0 -> requestMissingRuntimePermissions(textStatus)
                    1 -> requestDefaultSmsRole(textStatus)
                    2 -> requestUsageAccess(textStatus)
                    3 -> requestIgnoreBatteryOptimizations(textStatus)
                    4 -> textStatus.text = buildPermissionStatusSummary()
                    5 -> openAppSettings(textStatus)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun ensureRuntimePermissionsForAction(textStatus: TextView, required: List<String>): Boolean {
        val missing = GatewayPermissionCenter.missingRuntimePermissions(this, required)
        if (missing.isEmpty()) {
            return true
        }
        val permanentlyDenied = permanentlyDeniedPermissions(missing)
        if (permanentlyDenied.isNotEmpty()) {
            textStatus.text = getString(
                R.string.status_runtime_permissions_permanently_denied,
                GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
            )
            showOpenAppSettingsDialog(textStatus, permanentlyDenied)
            return false
        }
        textStatus.text = getString(
            R.string.status_runtime_permissions_missing,
            GatewayPermissionCenter.summarizePermissions(missing)
        )
        launchRuntimePermissionRequest(missing)
        return false
    }

    private fun requestMissingRuntimePermissions(textStatus: TextView) {
        val missing = PermissionAndRoleHelper.missingRuntimePermissions(this)
        if (missing.isEmpty()) {
            textStatus.text = getString(R.string.status_runtime_permissions_granted)
            return
        }
        textStatus.text = getString(
            R.string.status_runtime_permission_request_started,
            GatewayPermissionCenter.summarizePermissions(missing)
        )
        val permanentlyDenied = permanentlyDeniedPermissions(missing)
        if (permanentlyDenied.isNotEmpty()) {
            textStatus.text = getString(
                R.string.status_runtime_permissions_permanently_denied,
                GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
            )
            showOpenAppSettingsDialog(textStatus, permanentlyDenied)
            return
        }
        launchRuntimePermissionRequest(missing)
    }

    private fun requestDefaultSmsRole(textStatus: TextView) {
        val intent = PermissionAndRoleHelper.buildRequestDefaultSmsRoleIntent(this)
        if (intent != null) {
            requestSmsRoleLauncher.launch(intent)
            textStatus.text = getString(R.string.status_sms_role_requested)
        } else {
            textStatus.text = if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
                getString(R.string.status_sms_role_held)
            } else {
                getString(R.string.status_sms_role_unavailable)
            }
        }
    }

    private fun requestUsageAccess(textStatus: TextView) {
        if (PermissionAndRoleHelper.hasUsageAccess(this)) {
            textStatus.text = getString(R.string.status_usage_access_granted)
            return
        }
        PermissionAndRoleHelper.openUsageAccessSettings(this)
        textStatus.text = getString(R.string.status_usage_access_requested)
    }

    private fun requestIgnoreBatteryOptimizations(textStatus: TextView) {
        PermissionAndRoleHelper.requestIgnoreBatteryOptimizations(this)
        textStatus.text = getString(R.string.status_battery_optimization_requested)
    }

    private fun openAppSettings(textStatus: TextView) {
        PermissionAndRoleHelper.openAppDetailsSettings(this)
        textStatus.text = getString(R.string.status_app_settings_opened)
    }

    private fun buildPermissionStatusSummary(): String {
        val missingRuntime = PermissionAndRoleHelper.missingRuntimePermissions(this)
        val runtimeSummary = if (missingRuntime.isEmpty()) {
            getString(R.string.status_runtime_permissions_granted)
        } else {
            getString(
                R.string.status_runtime_permissions_missing,
                GatewayPermissionCenter.summarizePermissions(missingRuntime)
            )
        }
        val smsRole = if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
            getString(R.string.status_sms_role_held)
        } else {
            getString(R.string.status_sms_role_not_held)
        }
        val usageAccess = if (PermissionAndRoleHelper.hasUsageAccess(this)) {
            getString(R.string.status_usage_access_granted)
        } else {
            getString(R.string.status_usage_access_not_granted)
        }
        return listOf(runtimeSummary, smsRole, usageAccess).joinToString("\n")
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

    private fun showOpenAppSettingsDialog(textStatus: TextView, permissions: Collection<String>) {
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_permission_settings_required))
            .setMessage(
                getString(
                    R.string.message_permission_settings_required,
                    GatewayPermissionCenter.summarizePermissions(permissions)
                )
            )
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(R.string.action_open_app_settings) { _, _ ->
                openAppSettings(textStatus)
            }
            .show()
    }

    private fun showGatewayDataToolsDialog(
        editServer: EditText,
        editDeviceId: EditText,
        editApiKey: EditText,
        textSimInfo: TextView,
        textStatus: TextView
    ) {
        val items = arrayOf(
            getString(R.string.item_edit_sim_numbers),
            getString(R.string.item_clear_gateway_database),
            getString(R.string.item_clear_server_database)
        )
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_gateway_data_tools))
            .setItems(items) { _, which ->
                when (which) {
                    0 -> showEditSimNumbersDialog(editServer, editDeviceId, textSimInfo, textStatus)
                    1 -> confirmClearGatewayDatabase(textStatus)
                    2 -> confirmClearServerDatabase(editServer, editDeviceId, editApiKey, textStatus)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun showEditSimNumbersDialog(
        editServer: EditText,
        editDeviceId: EditText,
        textSimInfo: TextView,
        textStatus: TextView
    ) {
        val contentView = layoutInflater.inflate(R.layout.dialog_edit_sim_numbers, null, false)
        val editSim1Phone = contentView.findViewById<EditText>(R.id.editSim1PhoneDialog)
        val editSim2Phone = contentView.findViewById<EditText>(R.id.editSim2PhoneDialog)
        editSim1Phone.setText(pref.getString("sim_custom_number_0", "") ?: "")
        editSim2Phone.setText(pref.getString("sim_custom_number_1", "") ?: "")

        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_edit_sim_numbers))
            .setView(contentView)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                pref.edit()
                    .putString("sim_custom_number_0", editSim1Phone.text.toString().trim())
                    .putString("sim_custom_number_1", editSim2Phone.text.toString().trim())
                    .apply()

                textSimInfo.text = GatewaySimSupport.buildSummaryText(
                    this,
                    isZh = resources.configuration.locales[0].language.startsWith("zh")
                )
                textStatus.text = getString(R.string.status_sim_numbers_saved)

                val cfg = GatewayConfig(
                    serverBaseUrl = editServer.text.toString().trim(),
                    deviceId = editDeviceId.text.toString().trim()
                )
                if (cfg.serverBaseUrl.isNotBlank() && cfg.deviceId.isNotBlank()) {
                    GatewayRuntime.pushSimState(this, cfg) {
                        GatewayDebugLog.add(this, "SIM custom numbers updated: $it")
                    }
                }
            }
            .show()
    }

    private fun confirmClearGatewayDatabase(textStatus: TextView) {
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_confirm_clear_database))
            .setMessage(getString(R.string.message_confirm_clear_database))
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                runCatching {
                    GatewayLocalDb(this).use { db ->
                        db.clearPendingUploads()
                    }
                    GatewayRuntime.resetHistorySyncCursor(this, forceFullNextSync = true)
                    GatewayDebugLog.add(this, "Gateway database cleared by user")
                    textStatus.text = getString(R.string.status_database_cleared)
                }.onFailure {
                    textStatus.text = getString(R.string.status_database_clear_failed, it.message ?: "unknown")
                }
            }
            .show()
    }

    private fun confirmClearServerDatabase(
        editServer: EditText,
        editDeviceId: EditText,
        editApiKey: EditText,
        textStatus: TextView
    ) {
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.title_confirm_clear_server_database))
            .setMessage(getString(R.string.message_confirm_clear_server_database))
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                showProgress(indeterminate = true)
                RuntimeConfig.password = editApiKey.text.toString().trim().ifBlank { null }
                val cfg = GatewayConfig(
                    serverBaseUrl = editServer.text.toString().trim(),
                    deviceId = editDeviceId.text.toString().trim()
                )
                GatewayRuntime.clearServerData(this, cfg) { result ->
                    runOnUiThread {
                        hideProgress()
                        if (result.startsWith("Clear server data error:")) {
                            val reason = result.removePrefix("Clear server data error: ").ifBlank { "unknown" }
                            textStatus.text = getString(R.string.status_server_database_clear_failed, reason)
                        } else {
                            textStatus.text = getString(R.string.status_server_database_cleared, result)
                        }
                    }
                }
            }
            .show()
    }

    private fun startWebUiServer(
        editServer: EditText,
        editDeviceId: EditText,
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
                    deviceId = editDeviceId.text.toString().trim()
                )
            },
            onAction = { action ->
                RuntimeConfig.password = editApiKey.text.toString().trim().ifBlank { null }
                val cfg = GatewayConfig(
                    serverBaseUrl = editServer.text.toString().trim(),
                    deviceId = editDeviceId.text.toString().trim()
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
        editApiKey: EditText,
        editWebUiPort: EditText,
        textStatus: TextView
    ) {
        webUiServer?.stop()
        webUiServer = null
        startWebUiServer(editServer, editDeviceId, editApiKey, editWebUiPort, textStatus)
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100) {
        showProgress(indeterminate, progress, max, animate = false)
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100, animate: Boolean = false) {
        syncProgressBar?.apply {
            visibility = View.VISIBLE
            isIndeterminate = indeterminate
            if (!indeterminate) {
                this.max = max.coerceAtLeast(1)
                val target = progress.coerceIn(0, this.max)
                if (animate && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    setProgress(target, true)
                } else {
                    this.progress = target
                }
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

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    progressBar.setProgress(value, true)
                } else {
                    progressBar.progress = value
                }
                syncAnimHandler.postDelayed(this, 120)
            }
        }
        syncAnimRunnable = runnable
        bar.interpolator = LinearInterpolator()
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
