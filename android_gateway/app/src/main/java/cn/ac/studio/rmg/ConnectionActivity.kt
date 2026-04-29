package cn.ac.studio.rmg

import android.content.Intent
import android.os.Bundle
import android.view.MenuItem
import android.view.View
import android.widget.EditText
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.progressindicator.LinearProgressIndicator

class ConnectionActivity : AppCompatActivity() {
    private lateinit var editServer: EditText
    private lateinit var editDeviceId: EditText
    private lateinit var editPassword: EditText
    private lateinit var editWebUiPort: EditText
    private lateinit var progressBar: LinearProgressIndicator

    private val scanOnboardingLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            if (result.resultCode != android.app.Activity.RESULT_OK) {
                return@registerForActivityResult
            }
            val text = result.data?.getStringExtra(QrScannerActivity.EXTRA_RESULT)?.trim()
            if (text.isNullOrEmpty()) {
                return@registerForActivityResult
            }
            applyOnboardingPayload(text)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        GatewayTheme.apply(this)
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_connection)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.appBar), includeTop = true, includeBottom = false)
        GatewayTheme.applyEdgeToEdgePadding(findViewById(R.id.contentScroll), includeTop = false, includeBottom = true)
        setSupportActionBar(findViewById(R.id.toolbar))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        editServer = findViewById(R.id.editServer)
        editDeviceId = findViewById(R.id.editDeviceId)
        editPassword = findViewById(R.id.editPassword)
        editWebUiPort = findViewById(R.id.editWebUiPort)
        progressBar = findViewById(R.id.progressConnection)

        title = getString(R.string.title_connection_settings)
        loadForm()

        findViewById<View>(R.id.btnScanOnboarding).setOnClickListener { launchQrScanner() }
        findViewById<View>(R.id.btnSaveConnection).setOnClickListener {
            saveFromForm(showSavedStatus = true)
        }
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            finish()
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    private fun loadForm() {
        val values = GatewayConfigStore.load(this)
        editServer.setText(values.serverBaseUrl)
        editDeviceId.setText(values.deviceId)
        editPassword.setText(values.password)
        editWebUiPort.setText(values.webUiPort)
    }

    private fun launchQrScanner() {
        scanOnboardingLauncher.launch(Intent(this, QrScannerActivity::class.java))
    }

    private fun applyOnboardingPayload(raw: String) {
        val payload = GatewayConfigStore.parseOnboardingPayload(raw)
        if (payload == null) {
            showStatus(getString(R.string.status_onboarding_invalid))
            return
        }

        editServer.setText(payload.serverBaseUrl)
        editPassword.setText(payload.gatewayToken)
        if (editDeviceId.text.toString().trim().isBlank()) {
            editDeviceId.setText(GatewayConfigStore.defaultGatewayDeviceId())
        }

        val cfg = saveFromForm(showSavedStatus = false) ?: return
        showProgress(indeterminate = true)
        GatewayRuntime.registerGateway(this, cfg) { status ->
            runOnUiThread {
                hideProgress()
                showStatus(
                    if (status.startsWith("Register error:", ignoreCase = true)) {
                        getString(R.string.status_onboarding_scan_error, status)
                    } else {
                        getString(R.string.status_onboarding_applied)
                    }
                )
            }
        }
    }

    private fun saveFromForm(showSavedStatus: Boolean): GatewayConfig? {
        val server = editServer.text.toString().trim()
        val device = editDeviceId.text.toString().trim()
        val password = editPassword.text.toString().trim()
        val portText = editWebUiPort.text.toString().trim()
        clearErrors()
        if (server.isBlank()) {
            editServer.error = getString(R.string.status_invalid_server)
            showStatus(getString(R.string.status_invalid_server))
            return null
        }
        if (device.isBlank()) {
            editDeviceId.error = getString(R.string.status_invalid_device)
            showStatus(getString(R.string.status_invalid_device))
            return null
        }
        if (password.isBlank()) {
            editPassword.error = getString(R.string.status_invalid_password)
            showStatus(getString(R.string.status_invalid_password))
            return null
        }
        if (GatewayConfigStore.normalizePort(portText) == null) {
            editWebUiPort.error = getString(R.string.status_invalid_port)
            showStatus(getString(R.string.status_invalid_port))
            return null
        }

        val cfg = GatewayConfigStore.save(
            this,
            GatewayConfigStore.Values(
                serverBaseUrl = server,
                deviceId = device,
                password = password,
                webUiPort = portText
            )
        )
        if (showSavedStatus) {
            showStatus(getString(R.string.status_saved_auto_sync))
        }
        GatewayRuntime.pushSimState(this, cfg) {
            if (showSavedStatus) {
                runOnUiThread { showStatus(getString(R.string.status_saved_auto_sync)) }
            }
        }
        return cfg
    }

    private fun clearErrors() {
        editServer.error = null
        editDeviceId.error = null
        editPassword.error = null
        editWebUiPort.error = null
    }

    private fun showStatus(text: CharSequence) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show()
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
}
