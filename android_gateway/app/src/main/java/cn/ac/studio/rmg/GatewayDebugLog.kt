package cn.ac.studio.rmg

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
    private const val KEY_ENABLED = "log_enabled"
    private const val KEY_AUTO_CLEAR_ENABLED = "auto_clear_enabled"
    private const val KEY_AUTO_CLEAR_INTERVAL_MINUTES = "auto_clear_interval_minutes"
    private const val KEY_LAST_AUTO_CLEAR_AT = "last_auto_clear_at"
    private const val MAX_LINES = 120
    private const val DEFAULT_AUTO_CLEAR_INTERVAL_MINUTES = 24 * 60
    private const val DEFAULT_AUTO_CLEAR_ENABLED = false
    private const val MIN_AUTO_CLEAR_INTERVAL_MINUTES = 5
    private const val MAX_AUTO_CLEAR_INTERVAL_MINUTES = 7 * 24 * 60
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArrayList<(String) -> Unit>()

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    fun current(context: Context): String {
        val appContext = context.applicationContext
        enforceAutoClearIfNeeded(appContext)
        return currentRaw(appContext)
    }

    fun isEnabled(context: Context): Boolean {
        return prefs(context).getBoolean(KEY_ENABLED, true)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
        notifyListeners(current(context))
    }

    fun isAutoClearEnabled(context: Context): Boolean {
        return prefs(context).getBoolean(KEY_AUTO_CLEAR_ENABLED, DEFAULT_AUTO_CLEAR_ENABLED)
    }

    fun setAutoClearEnabled(context: Context, enabled: Boolean) {
        val editor = prefs(context).edit().putBoolean(KEY_AUTO_CLEAR_ENABLED, enabled)
        if (enabled) {
            editor.putLong(KEY_LAST_AUTO_CLEAR_AT, System.currentTimeMillis())
        }
        editor.apply()
    }

    fun getAutoClearIntervalMinutes(context: Context): Int {
        val raw = prefs(context).getInt(KEY_AUTO_CLEAR_INTERVAL_MINUTES, DEFAULT_AUTO_CLEAR_INTERVAL_MINUTES)
        return raw.coerceIn(MIN_AUTO_CLEAR_INTERVAL_MINUTES, MAX_AUTO_CLEAR_INTERVAL_MINUTES)
    }

    fun setAutoClearIntervalMinutes(context: Context, minutes: Int) {
        val normalized = minutes.coerceIn(MIN_AUTO_CLEAR_INTERVAL_MINUTES, MAX_AUTO_CLEAR_INTERVAL_MINUTES)
        prefs(context).edit()
            .putInt(KEY_AUTO_CLEAR_INTERVAL_MINUTES, normalized)
            .putLong(KEY_LAST_AUTO_CLEAR_AT, System.currentTimeMillis())
            .apply()
    }

    fun add(context: Context, message: String) {
        val appContext = context.applicationContext
        if (!isEnabled(appContext)) {
            return
        }
        enforceAutoClearIfNeeded(appContext)
        val timestamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.getDefault()).format(Date())
        val next = buildString {
            val existing = currentRaw(appContext)
                .lineSequence()
                .filter { it.isNotBlank() }
                .toList()
                .takeLast(MAX_LINES - 1)
                .toMutableList()
            existing += "[$timestamp] $message"
            append(existing.joinToString("\n"))
        }

        prefs(appContext)
            .edit()
            .putString(KEY_TEXT, next)
            .apply()

        notifyListeners(next)
    }

    fun clear(context: Context) {
        prefs(context.applicationContext)
            .edit()
            .remove(KEY_TEXT)
            .putLong(KEY_LAST_AUTO_CLEAR_AT, System.currentTimeMillis())
            .apply()
        notifyListeners("")
    }

    fun register(listener: (String) -> Unit) {
        listeners += listener
    }

    fun unregister(listener: (String) -> Unit) {
        listeners -= listener
    }

    private fun enforceAutoClearIfNeeded(context: Context) {
        if (!isAutoClearEnabled(context)) {
            return
        }
        val pref = prefs(context)
        val intervalMs = getAutoClearIntervalMinutes(context) * 60_000L
        val now = System.currentTimeMillis()
        val last = pref.getLong(KEY_LAST_AUTO_CLEAR_AT, 0L)
        if (last <= 0L) {
            pref.edit().putLong(KEY_LAST_AUTO_CLEAR_AT, now).apply()
            return
        }
        if (now - last < intervalMs) {
            return
        }
        pref.edit()
            .remove(KEY_TEXT)
            .putLong(KEY_LAST_AUTO_CLEAR_AT, now)
            .apply()
        notifyListeners("")
    }

    private fun notifyListeners(text: String) {
        mainHandler.post {
            listeners.forEach { listener -> listener(text) }
        }
    }

    private fun currentRaw(context: Context): String {
        return prefs(context)
            .getString(KEY_TEXT, "")
            .orEmpty()
    }
}
