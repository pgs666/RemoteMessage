package cn.ac.studio.rmg

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

object GatewayPermissionCenter {
    fun requiredRuntimePermissions(): List<String> {
        val perms = mutableListOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.SEND_SMS,
            Manifest.permission.READ_PHONE_STATE
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            perms += Manifest.permission.READ_PHONE_NUMBERS
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms += Manifest.permission.POST_NOTIFICATIONS
        }
        return perms
    }

    fun readSmsPermissions(): List<String> = listOf(Manifest.permission.READ_SMS)

    fun sendSmsPermissions(): List<String> = listOf(Manifest.permission.SEND_SMS)

    fun missingRuntimePermissions(context: Context, required: Collection<String>): List<String> {
        return required.filter { permission ->
            ContextCompat.checkSelfPermission(context, permission) != PackageManager.PERMISSION_GRANTED
        }
    }

    fun hasAllRuntimePermissions(context: Context, required: Collection<String>): Boolean {
        return missingRuntimePermissions(context, required).isEmpty()
    }

    fun summarizePermissions(perms: Collection<String>): String {
        return perms.joinToString(", ") { perm -> perm.substringAfterLast('.') }
    }
}
