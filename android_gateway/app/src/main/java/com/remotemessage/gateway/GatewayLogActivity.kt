package com.remotemessage.gateway

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity

class GatewayLogActivity : ComponentActivity() {
    private var paused = false
    private lateinit var textLog: TextView
    private lateinit var btnPauseRefresh: Button
    private lateinit var switchEnableLog: Switch
    private lateinit var switchAutoClear: Switch
    private lateinit var editAutoClearMinutes: EditText

    private val debugLogListener = listener@{ text: String ->
        if (paused) return@listener
        runOnUiThread {
            textLog.text = if (text.isBlank()) getString(R.string.status_debug_log_empty) else text
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_gateway_log)

        textLog = findViewById(R.id.textLogContent)
        btnPauseRefresh = findViewById(R.id.btnPauseLogRefresh)
        switchEnableLog = findViewById(R.id.switchEnableLog)
        switchAutoClear = findViewById(R.id.switchAutoClearLog)
        editAutoClearMinutes = findViewById(R.id.editAutoClearMinutes)
        val btnSaveAutoClear = findViewById<Button>(R.id.btnSaveAutoClear)
        val btnCopyLog = findViewById<Button>(R.id.btnCopyLog)
        val btnClearLogNow = findViewById<Button>(R.id.btnClearLogNow)

        title = getString(R.string.title_log_page)
        renderCurrentLog()

        switchEnableLog.isChecked = GatewayDebugLog.isEnabled(this)
        switchAutoClear.isChecked = GatewayDebugLog.isAutoClearEnabled(this)
        editAutoClearMinutes.setText(GatewayDebugLog.getAutoClearIntervalMinutes(this).toString())

        switchEnableLog.setOnCheckedChangeListener { _, checked ->
            GatewayDebugLog.setEnabled(this, checked)
            Toast.makeText(
                this,
                if (checked) getString(R.string.status_log_enabled) else getString(R.string.status_log_disabled),
                Toast.LENGTH_SHORT
            ).show()
        }

        switchAutoClear.setOnCheckedChangeListener { _, checked ->
            GatewayDebugLog.setAutoClearEnabled(this, checked)
            Toast.makeText(
                this,
                if (checked) getString(R.string.status_auto_clear_enabled) else getString(R.string.status_auto_clear_disabled),
                Toast.LENGTH_SHORT
            ).show()
        }

        btnSaveAutoClear.setOnClickListener {
            val minutes = editAutoClearMinutes.text.toString().trim().toIntOrNull()
            if (minutes == null || minutes <= 0) {
                Toast.makeText(this, getString(R.string.status_invalid_auto_clear_minutes), Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            GatewayDebugLog.setAutoClearIntervalMinutes(this, minutes)
            editAutoClearMinutes.setText(GatewayDebugLog.getAutoClearIntervalMinutes(this).toString())
            Toast.makeText(this, getString(R.string.status_auto_clear_saved), Toast.LENGTH_SHORT).show()
        }

        btnPauseRefresh.setOnClickListener {
            paused = !paused
            updatePauseRefreshButton()
            if (!paused) {
                renderCurrentLog()
            }
        }

        btnCopyLog.setOnClickListener {
            val text = textLog.text?.toString().orEmpty()
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("gateway-log", text))
            Toast.makeText(this, getString(R.string.status_log_copied), Toast.LENGTH_SHORT).show()
        }

        btnClearLogNow.setOnClickListener {
            GatewayDebugLog.clear(this)
            textLog.text = getString(R.string.status_debug_log_empty)
            Toast.makeText(this, getString(R.string.status_debug_log_cleared), Toast.LENGTH_SHORT).show()
        }
    }

    override fun onStart() {
        super.onStart()
        GatewayDebugLog.register(debugLogListener)
        if (!paused) {
            renderCurrentLog()
        }
    }

    override fun onStop() {
        GatewayDebugLog.unregister(debugLogListener)
        super.onStop()
    }

    private fun renderCurrentLog() {
        textLog.text = GatewayDebugLog.current(this).ifBlank { getString(R.string.status_debug_log_empty) }
    }

    private fun updatePauseRefreshButton() {
        btnPauseRefresh.text = if (paused) getString(R.string.btn_resume_log_refresh) else getString(R.string.btn_pause_log_refresh)
    }
}
