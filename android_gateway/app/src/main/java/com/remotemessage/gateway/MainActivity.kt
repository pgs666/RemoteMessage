package com.remotemessage.gateway

import android.Manifest
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

class MainActivity : ComponentActivity() {

    private lateinit var pref: SharedPreferences

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        pref = getSharedPreferences("gateway_config", Context.MODE_PRIVATE)
        val editServer = findViewById<EditText>(R.id.editServer)
        val editDeviceId = findViewById<EditText>(R.id.editDeviceId)
        val editSimSubId = findViewById<EditText>(R.id.editSimSubId)
        val textStatus = findViewById<TextView>(R.id.textStatus)
        val btnSave = findViewById<Button>(R.id.btnSave)
        val btnRegister = findViewById<Button>(R.id.btnRegister)
        val btnPollOnce = findViewById<Button>(R.id.btnPollOnce)
        val btnSyncHistory = findViewById<Button>(R.id.btnSyncHistory)
        val btnFlushPending = findViewById<Button>(R.id.btnFlushPending)

        editServer.setText(pref.getString("server_base", "http://10.0.2.2:5000") ?: "")
        editDeviceId.setText(pref.getString("device_id", "android-arm64-gateway") ?: "")
        editSimSubId.setText(pref.getString("sim_sub_id", "") ?: "")

        requestPermissionsIfNeeded()
        GatewaySyncWorker.schedule(this)

        btnSave.setOnClickListener {
            pref.edit()
                .putString("server_base", editServer.text.toString().trim())
                .putString("device_id", editDeviceId.text.toString().trim())
                .putString("sim_sub_id", editSimSubId.text.toString().trim())
                .apply()
            GatewaySyncWorker.schedule(this)
            textStatus.text = "Saved + Auto Sync scheduled"
        }

        btnRegister.setOnClickListener {
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim()
            )
            GatewayRuntime.registerGateway(this, cfg) {
                runOnUiThread { textStatus.text = it }
            }
            GatewaySyncWorker.schedule(this)
        }

        btnPollOnce.setOnClickListener {
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            GatewayRuntime.pollAndSend(this, cfg) {
                runOnUiThread { textStatus.text = it }
            }
        }

        btnSyncHistory.setOnClickListener {
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            GatewayRuntime.syncHistoricalSms(this, cfg) {
                runOnUiThread { textStatus.text = it }
            }
        }

        btnFlushPending.setOnClickListener {
            val cfg = GatewayConfig(
                serverBaseUrl = editServer.text.toString().trim(),
                deviceId = editDeviceId.text.toString().trim(),
                simSubId = editSimSubId.text.toString().trim().toIntOrNull()
            )
            Thread {
                GatewayRuntime.flushPendingUploads(this, cfg)
                runOnUiThread { textStatus.text = "Pending uploads flushed" }
            }.start()
        }
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
