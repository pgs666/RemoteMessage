package cn.ac.studio.rmg

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.MenuItem
import android.view.View
import android.widget.EditText
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.progressindicator.LinearProgressIndicator

class GatewaySettingsActivity : AppCompatActivity() {
    private lateinit var pref: SharedPreferences
    private lateinit var permissionPref: SharedPreferences
    private lateinit var progressBar: LinearProgressIndicator

    private val requestSmsRoleLauncher = registerForActivityResult(StartActivityForResult()) {
        showStatus(
            if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
                getString(R.string.status_sms_role_held)
            } else {
                getString(R.string.status_sms_role_requested)
            }
        )
    }

    private val importCertLauncher = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@registerForActivityResult

        runCatching {
            contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        runCatching {
            GatewayCertificateStore.importFromUri(this, uri)
            showStatus(getString(R.string.status_cert_imported))
        }.onFailure {
            showStatus(getString(R.string.status_cert_import_failed, it.message ?: "unknown"))
        }
    }

    private val requestRuntimePermissionsLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            markPermissionsRequested(result.keys)
            val denied = result.entries.filter { !it.value }.map { it.key }
            if (denied.isEmpty()) {
                showStatus(getString(R.string.status_runtime_permissions_granted))
                return@registerForActivityResult
            }
            val permanentlyDenied = permanentlyDeniedPermissions(denied)
            showStatus(
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
        setContentView(R.layout.activity_gateway_settings)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.appBar), includeTop = true, includeBottom = false)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.settingsScroll), includeTop = false, includeBottom = true)
        setSupportActionBar(findViewById(R.id.toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        pref = getSharedPreferences(GatewayConfigStore.PREF_NAME, Context.MODE_PRIVATE)
        permissionPref = getSharedPreferences(PREF_PERMISSION_STATE, Context.MODE_PRIVATE)
        progressBar = findViewById(R.id.progressSettings)
        title = getString(R.string.title_settings)

        findViewById<View>(R.id.btnRequestRuntimePermissions).setOnClickListener { requestMissingRuntimePermissions() }
        findViewById<View>(R.id.btnRequestDefaultSmsRole).setOnClickListener { requestDefaultSmsRole() }
        findViewById<View>(R.id.btnRequestUsageAccess).setOnClickListener { requestUsageAccess() }
        findViewById<View>(R.id.btnRequestBatteryOptimization).setOnClickListener { requestIgnoreBatteryOptimizations() }
        findViewById<View>(R.id.btnViewPermissionStatus).setOnClickListener { showStatus(buildPermissionStatusSummary()) }
        findViewById<View>(R.id.btnOpenAppSettings).setOnClickListener { openAppSettings() }
        findViewById<View>(R.id.btnPollOnce).setOnClickListener { pollOnce() }
        findViewById<View>(R.id.btnSyncHistory).setOnClickListener { syncHistory() }
        findViewById<View>(R.id.btnTestLocalSms).setOnClickListener { testLocalSms() }
        findViewById<View>(R.id.btnFlushPending).setOnClickListener { flushPendingUploads() }
        findViewById<View>(R.id.btnImportCert).setOnClickListener {
            importCertLauncher.launch(arrayOf("application/x-x509-ca-cert", "application/pkix-cert", "*/*"))
        }
        findViewById<View>(R.id.btnEditSimNumbers).setOnClickListener { showEditSimNumbersDialog() }
        findViewById<View>(R.id.btnClearGatewayDatabase).setOnClickListener { confirmClearGatewayDatabase() }
        findViewById<View>(R.id.btnClearServerDatabase).setOnClickListener { confirmClearServerDatabase() }
        findViewById<View>(R.id.btnOpenLogPage).setOnClickListener {
            startActivity(Intent(this, GatewayLogActivity::class.java))
        }
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
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
                showStatus(it)
            }
        }
    }

    private fun validSavedConfigOrNull(): GatewayConfig? {
        val values = GatewayConfigStore.load(this)
        if (values.serverBaseUrl.isBlank()) {
            showStatus(getString(R.string.status_invalid_server))
            return null
        }
        if (values.deviceId.isBlank()) {
            showStatus(getString(R.string.status_invalid_device))
            return null
        }
        RuntimeConfig.password = values.password.ifBlank { null }
        return GatewayConfig(values.serverBaseUrl, values.deviceId)
    }

    private fun syncHistory() {
        if (!ensureRuntimePermissionsForAction(GatewayPermissionCenter.readSmsPermissions())) {
            return
        }
        showProgress(indeterminate = false, progress = 0, max = 1)
        showStatus(getString(R.string.status_history_sync_preparing))
        val cfg = GatewayConfigStore.loadRuntimeConfig(this)
        GatewayRuntime.syncHistoricalSms(this, cfg, onProgress = { processed, total ->
            runOnUiThread {
                if (total > 0) {
                    showProgress(indeterminate = false, progress = processed, max = total)
                    showStatus(getString(R.string.status_history_sync_progress, processed, total))
                } else {
                    showProgress(indeterminate = true)
                }
            }
        }) {
            runOnUiThread {
                hideProgress()
                showStatus(it)
            }
        }
    }

    private fun testLocalSms() {
        if (!ensureRuntimePermissionsForAction(GatewayPermissionCenter.readSmsPermissions())) {
            return
        }
        GatewayRuntime.inspectLocalSmsAccess(this) {
            runOnUiThread { showStatus(it) }
        }
    }

    private fun flushPendingUploads() {
        showProgress(indeterminate = true)
        val cfg = GatewayConfigStore.loadRuntimeConfig(this)
        Thread {
            GatewayRuntime.flushPendingUploads(this, cfg)
            runOnUiThread {
                hideProgress()
                showStatus(getString(R.string.status_pending_flushed))
            }
        }.start()
    }

    private fun showEditSimNumbersDialog() {
        val contentView = layoutInflater.inflate(R.layout.dialog_edit_sim_numbers, null, false)
        val editSim1Phone = contentView.findViewById<EditText>(R.id.editSim1PhoneDialog)
        val editSim2Phone = contentView.findViewById<EditText>(R.id.editSim2PhoneDialog)
        editSim1Phone.setText(pref.getString("sim_custom_number_0", "") ?: "")
        editSim2Phone.setText(pref.getString("sim_custom_number_1", "") ?: "")

        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.title_edit_sim_numbers))
            .setView(contentView)
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                pref.edit()
                    .putString("sim_custom_number_0", editSim1Phone.text.toString().trim())
                    .putString("sim_custom_number_1", editSim2Phone.text.toString().trim())
                    .apply()

                showStatus(getString(R.string.status_sim_numbers_saved))
                val cfg = GatewayConfigStore.loadRuntimeConfig(this)
                if (cfg.serverBaseUrl.isNotBlank() && cfg.deviceId.isNotBlank()) {
                    GatewayRuntime.pushSimState(this, cfg) {
                        GatewayDebugLog.add(this, "SIM custom numbers updated: $it")
                    }
                }
            }
            .show()
    }

    private fun confirmClearGatewayDatabase() {
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.title_confirm_clear_database))
            .setMessage(getString(R.string.message_confirm_clear_database))
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                runCatching {
                    GatewayLocalDb(this).use { db -> db.clearPendingUploads() }
                    GatewayRuntime.resetHistorySyncCursor(this, forceFullNextSync = true)
                    GatewayDebugLog.add(this, "Gateway database cleared by user")
                    showStatus(getString(R.string.status_database_cleared))
                }.onFailure {
                    showStatus(getString(R.string.status_database_clear_failed, it.message ?: "unknown"))
                }
            }
            .show()
    }

    private fun confirmClearServerDatabase() {
        MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.title_confirm_clear_server_database))
            .setMessage(getString(R.string.message_confirm_clear_server_database))
            .setNegativeButton(android.R.string.cancel, null)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                showProgress(indeterminate = true)
                val cfg = GatewayConfigStore.loadRuntimeConfig(this)
                GatewayRuntime.clearServerData(this, cfg) { result ->
                    runOnUiThread {
                        hideProgress()
                        if (result.startsWith("Clear server data error:")) {
                            val reason = result.removePrefix("Clear server data error: ").ifBlank { "unknown" }
                            showStatus(getString(R.string.status_server_database_clear_failed, reason))
                        } else {
                            showStatus(getString(R.string.status_server_database_cleared, result))
                        }
                    }
                }
            }
            .show()
    }

    private fun ensureRuntimePermissionsForAction(required: List<String>): Boolean {
        val missing = GatewayPermissionCenter.missingRuntimePermissions(this, required)
        if (missing.isEmpty()) {
            return true
        }
        val permanentlyDenied = permanentlyDeniedPermissions(missing)
        if (permanentlyDenied.isNotEmpty()) {
            showStatus(
                getString(
                    R.string.status_runtime_permissions_permanently_denied,
                    GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
                )
            )
            showOpenAppSettingsDialog(permanentlyDenied)
            return false
        }
        showStatus(
            getString(
                R.string.status_runtime_permissions_missing,
                GatewayPermissionCenter.summarizePermissions(missing)
            )
        )
        launchRuntimePermissionRequest(missing)
        return false
    }

    private fun requestMissingRuntimePermissions() {
        val missing = PermissionAndRoleHelper.missingRuntimePermissions(this)
        if (missing.isEmpty()) {
            showStatus(getString(R.string.status_runtime_permissions_granted))
            return
        }
        showStatus(
            getString(
                R.string.status_runtime_permission_request_started,
                GatewayPermissionCenter.summarizePermissions(missing)
            )
        )
        val permanentlyDenied = permanentlyDeniedPermissions(missing)
        if (permanentlyDenied.isNotEmpty()) {
            showStatus(
                getString(
                    R.string.status_runtime_permissions_permanently_denied,
                    GatewayPermissionCenter.summarizePermissions(permanentlyDenied)
                )
            )
            showOpenAppSettingsDialog(permanentlyDenied)
            return
        }
        launchRuntimePermissionRequest(missing)
    }

    private fun requestDefaultSmsRole() {
        val intent = PermissionAndRoleHelper.buildRequestDefaultSmsRoleIntent(this)
        if (intent != null) {
            requestSmsRoleLauncher.launch(intent)
            showStatus(getString(R.string.status_sms_role_requested))
        } else {
            showStatus(
                if (PermissionAndRoleHelper.isDefaultSmsApp(this)) {
                    getString(R.string.status_sms_role_held)
                } else {
                    getString(R.string.status_sms_role_unavailable)
                }
            )
        }
    }

    private fun requestUsageAccess() {
        if (PermissionAndRoleHelper.hasUsageAccess(this)) {
            showStatus(getString(R.string.status_usage_access_granted))
            return
        }
        PermissionAndRoleHelper.openUsageAccessSettings(this)
        showStatus(getString(R.string.status_usage_access_requested))
    }

    private fun requestIgnoreBatteryOptimizations() {
        PermissionAndRoleHelper.requestIgnoreBatteryOptimizations(this)
        showStatus(getString(R.string.status_battery_optimization_requested))
    }

    private fun openAppSettings() {
        PermissionAndRoleHelper.openAppDetailsSettings(this)
        showStatus(getString(R.string.status_app_settings_opened))
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
            .setPositiveButton(R.string.action_open_app_settings) { _, _ -> openAppSettings() }
            .show()
    }

    private fun showStatus(text: CharSequence) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    }

    private fun showProgress(indeterminate: Boolean, progress: Int = 0, max: Int = 100) {
        progressBar.visibility = View.VISIBLE
        progressBar.isIndeterminate = indeterminate
        if (!indeterminate) {
            progressBar.max = max.coerceAtLeast(1)
            progressBar.setProgressCompat(progress.coerceIn(0, progressBar.max), true)
        }
    }

    private fun hideProgress() {
        progressBar.visibility = View.GONE
    }

    companion object {
        private const val PREF_PERMISSION_STATE = "gateway_permission_state"
    }
}
