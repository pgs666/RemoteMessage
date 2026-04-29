package cn.ac.studio.rmg

import android.content.Context

object GatewayStatsStore {
    private const val PREF_NAME = "gateway_stats"
    private const val KEY_FORWARDED_COUNT = "forwarded_count"

    fun forwardedCount(context: Context): Long {
        return prefs(context).getLong(KEY_FORWARDED_COUNT, 0L)
    }

    fun addForwarded(context: Context, count: Int) {
        if (count <= 0) return
        val pref = prefs(context)
        val next = pref.getLong(KEY_FORWARDED_COUNT, 0L).saturatingAdd(count.toLong())
        pref.edit().putLong(KEY_FORWARDED_COUNT, next).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    private fun Long.saturatingAdd(other: Long): Long {
        if (other <= 0L) return this
        return if (Long.MAX_VALUE - this < other) Long.MAX_VALUE else this + other
    }
}
