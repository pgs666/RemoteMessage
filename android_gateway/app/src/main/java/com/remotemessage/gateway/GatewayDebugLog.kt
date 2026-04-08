package com.remotemessage.gateway

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.CopyOnWriteArrayList

object GatewayDebugLog {
    private const val PREF_NAME = "gateway_debug_log"
    private const val KEY_TEXT = "log_text"
    private const val MAX_LINES = 120
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    fun current(context: Context): String {
        return context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(KEY_TEXT, "")
            .orEmpty()
    }

    fun add(context: Context, message: String) {
        val appContext = context.applicationContext
        val timestamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date())
        val next = buildString {
            val existing = current(appContext)
                .lineSequence()
                .filter { it.isNotBlank() }
                .takeLast(MAX_LINES - 1)
                .toMutableList()
            existing += "[$timestamp] $message"
            append(existing.joinToString("\n"))
        }

        appContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TEXT, next)
            .apply()

        mainHandler.post {
            listeners.forEach { listener -> listener(next) }
        }
    }

    fun clear(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_TEXT)
            .apply()
        mainHandler.post {
            listeners.forEach { listener -> listener("") }
        }
    }

    fun register(listener: (String) -> Unit) {
        listeners += listener
    }

    fun unregister(listener: (String) -> Unit) {
        listeners -= listener
    }
}