package com.remotemessage.gateway

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Telephony
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import kotlin.math.abs

data class GatewaySimProfile(
    val subscriptionId: Int?,
    val slotIndex: Int,
    val displayName: String,
    val systemPhoneNumber: String?,
    val customPhoneNumber: String?,
    val effectivePhoneNumber: String?,
    val isCustom: Boolean
)

data class GatewaySimSnapshot(
    val simCount: Int,
    val profiles: List<GatewaySimProfile>
)

data class GatewayResolvedSimInfo(
    val subscriptionId: Int?,
    val slotIndex: Int?,
    val simPhoneNumber: String?,
    val simCount: Int
)

object GatewaySimSupport {
    private const val PREF_NAME = "gateway_config"

    fun readSnapshot(context: Context): GatewaySimSnapshot {
        val activeProfiles = readActiveProfiles(context)
        if (activeProfiles.isNotEmpty()) {
            return GatewaySimSnapshot(
                simCount = activeProfiles.size,
                profiles = activeProfiles.sortedBy { it.slotIndex }
            )
        }

        val fallbackProfiles = (0..1).mapNotNull { slotIndex ->
            val customNumber = readCustomPhoneNumber(context, slotIndex)
            if (customNumber.isNullOrBlank()) {
                null
            } else {
                GatewaySimProfile(
                    subscriptionId = null,
                    slotIndex = slotIndex,
                    displayName = "SIM ${slotIndex + 1}",
                    systemPhoneNumber = null,
                    customPhoneNumber = customNumber,
                    effectivePhoneNumber = customNumber,
                    isCustom = true
                )
            }
        }

        return GatewaySimSnapshot(
            simCount = fallbackProfiles.size,
            profiles = fallbackProfiles
        )
    }

    fun resolveForSubscriptionId(snapshot: GatewaySimSnapshot, subscriptionId: Int?): GatewayResolvedSimInfo {
        val resolved = when {
            subscriptionId != null -> snapshot.profiles.firstOrNull { it.subscriptionId == subscriptionId }
            snapshot.profiles.size == 1 -> snapshot.profiles.firstOrNull()
            else -> null
        }
        return GatewayResolvedSimInfo(
            subscriptionId = resolved?.subscriptionId ?: subscriptionId,
            slotIndex = resolved?.slotIndex,
            simPhoneNumber = resolved?.effectivePhoneNumber,
            simCount = snapshot.simCount
        )
    }

    fun resolveForSlotIndex(snapshot: GatewaySimSnapshot, slotIndex: Int?): GatewayResolvedSimInfo {
        val resolved = when {
            slotIndex != null -> snapshot.profiles.firstOrNull { it.slotIndex == slotIndex }
            snapshot.profiles.size == 1 -> snapshot.profiles.firstOrNull()
            else -> null
        }
        return GatewayResolvedSimInfo(
            subscriptionId = resolved?.subscriptionId,
            slotIndex = resolved?.slotIndex ?: slotIndex,
            simPhoneNumber = resolved?.effectivePhoneNumber,
            simCount = snapshot.simCount
        )
    }

    fun resolveForIntent(context: Context, intent: Intent): GatewayResolvedSimInfo {
        val snapshot = readSnapshot(context)
        val subId = extractSubscriptionId(intent)
        if (subId != null) {
            return resolveForSubscriptionId(snapshot, subId)
        }

        val slotIndex = extractSlotIndex(intent)
        return resolveForSlotIndex(snapshot, slotIndex)
    }

    fun resolveForSmsRecord(
        context: Context,
        phone: String,
        content: String,
        timestamp: Long,
        inbound: Boolean
    ): GatewayResolvedSimInfo {
        val snapshot = readSnapshot(context)
        if (snapshot.profiles.isEmpty()) {
            return GatewayResolvedSimInfo(null, null, null, 0)
        }

        val baseProjection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE
        )
        val extendedProjection = arrayOf(
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE,
            "sub_id",
            "subscription_id"
        )
        val lowerBound = (timestamp - 10 * 60 * 1000L).coerceAtLeast(0L)
        val selection = "${Telephony.Sms.ADDRESS} = ? AND ${Telephony.Sms.DATE} >= ?"
        val selectionArgs = arrayOf(phone, lowerBound.toString())
        val cursor = runCatching {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                extendedProjection,
                selection,
                selectionArgs,
                "${Telephony.Sms.DATE} DESC"
            )
        }.getOrElse {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                baseProjection,
                selection,
                selectionArgs,
                "${Telephony.Sms.DATE} DESC"
            )
        } ?: return resolveForSubscriptionId(snapshot, null)

        val directMatch = cursor.use {
            findMatchingSmsSubscription(it, content, timestamp, inbound)
        }
        if (directMatch != null) {
            return resolveForSubscriptionId(snapshot, directMatch)
        }

        val broadCursor = runCatching {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                extendedProjection,
                "${Telephony.Sms.DATE} >= ?",
                arrayOf(lowerBound.toString()),
                "${Telephony.Sms.DATE} DESC"
            )
        }.getOrElse {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                baseProjection,
                "${Telephony.Sms.DATE} >= ?",
                arrayOf(lowerBound.toString()),
                "${Telephony.Sms.DATE} DESC"
            )
        }
        val broadMatch = broadCursor?.use {
            findMatchingSmsSubscription(it, content, timestamp, inbound)
        }
        if (broadMatch != null) {
            return resolveForSubscriptionId(snapshot, broadMatch)
        }

        return resolveForSubscriptionId(snapshot, null)
    }

    fun readCustomPhoneNumber(context: Context, slotIndex: Int): String? {
        return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .getString(customPhonePrefKey(slotIndex), "")
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
    }

    fun buildSummaryText(context: Context, isZh: Boolean): String {
        val snapshot = readSnapshot(context)
        if (snapshot.profiles.isEmpty()) {
            return if (isZh) {
                "未检测到可用 SIM 信息，可手动填写自定义号码。"
            } else {
                "No active SIM info detected. You can still enter custom phone numbers manually."
            }
        }

        return snapshot.profiles.joinToString("\n") { profile ->
            val label = if (isZh) "卡${profile.slotIndex + 1}" else "SIM ${profile.slotIndex + 1}"
            val display = profile.displayName.takeIf { it.isNotBlank() && !it.equals(label, ignoreCase = true) }
            val systemNumber = profile.systemPhoneNumber?.takeIf { it.isNotBlank() }
            val customNumber = profile.customPhoneNumber?.takeIf { it.isNotBlank() }
            val effectiveNumber = profile.effectivePhoneNumber?.takeIf { it.isNotBlank() }

            buildString {
                append(label)
                display?.let { append(" ($it)") }
                append(if (isZh) "：" else ": ")
                append(
                    effectiveNumber
                        ?: if (isZh) "未读取到号码" else "no number detected"
                )
                if (!systemNumber.isNullOrBlank() && systemNumber != effectiveNumber) {
                    append(if (isZh) "，系统=" else ", system=")
                    append(systemNumber)
                }
                if (!customNumber.isNullOrBlank()) {
                    append(if (isZh) "，自定义=" else ", custom=")
                    append(customNumber)
                }
            }
        }
    }

    private fun customPhonePrefKey(slotIndex: Int): String = "sim_custom_number_$slotIndex"

    private fun contentEqualsLoosely(left: String, right: String): Boolean {
        if (left == right) return true
        if (left.isBlank() || right.isBlank()) return false
        return left.contains(right) || right.contains(left)
    }

    private fun findMatchingSmsSubscription(
        cursor: android.database.Cursor,
        content: String,
        timestamp: Long,
        inbound: Boolean
    ): Int? {
        val bodyIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
        val dateIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
        val typeIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.TYPE)
        val subIdIdx = cursor.getColumnIndex("sub_id")
        val subscriptionIdIdx = cursor.getColumnIndex("subscription_id")
        val expectedType = if (inbound) Telephony.Sms.MESSAGE_TYPE_INBOX else Telephony.Sms.MESSAGE_TYPE_SENT
        var checked = 0
        while (cursor.moveToNext() && checked < 50) {
            checked++
            if (cursor.getInt(typeIdx) != expectedType) continue
            val candidateBody = cursor.getString(bodyIdx) ?: ""
            val candidateTs = cursor.getLong(dateIdx)
            if (abs(candidateTs - timestamp) > 10 * 60 * 1000L) continue
            if (!contentEqualsLoosely(candidateBody, content)) continue
            return when {
                subIdIdx >= 0 && !cursor.isNull(subIdIdx) -> cursor.getInt(subIdIdx)
                subscriptionIdIdx >= 0 && !cursor.isNull(subscriptionIdIdx) -> cursor.getInt(subscriptionIdIdx)
                else -> null
            }
        }
        return null
    }

    private fun extractSubscriptionId(intent: Intent): Int? {
        val candidates = listOf(
            SubscriptionManager.EXTRA_SUBSCRIPTION_INDEX,
            "subscription",
            "subscription_id",
            "sub_id",
            "android.telephony.extra.SUBSCRIPTION_INDEX"
        )
        return candidates.firstNotNullOfOrNull { key ->
            intent.extras?.takeIf { it.containsKey(key) }
                ?.let {
                    val value = intent.getIntExtra(key, SubscriptionManager.INVALID_SUBSCRIPTION_ID)
                    value.takeIf { subId -> subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID }
                }
        }
    }

    private fun extractSlotIndex(intent: Intent): Int? {
        val candidates = listOf(
            "slot",
            "slot_id",
            "slotIndex",
            "simSlot",
            "sim_slot_index",
            "sim_slot",
            "phone",
            "phoneId",
            "simId",
            "android.telephony.extra.SLOT_INDEX"
        )
        return candidates.firstNotNullOfOrNull { key ->
            intent.extras?.takeIf { it.containsKey(key) }
                ?.let {
                    val value = intent.getIntExtra(key, -1)
                    value.takeIf { slot -> slot >= 0 }
                }
        }
    }

    private fun readActiveProfiles(context: Context): List<GatewaySimProfile> {
        val subscriptionManager = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        val infos = runCatching {
            if (hasSubscriptionPermission(context)) {
                subscriptionManager.activeSubscriptionInfoList.orEmpty()
            } else {
                emptyList()
            }
        }.getOrDefault(emptyList())

        return infos.map { info ->
            val customNumber = readCustomPhoneNumber(context, info.simSlotIndex)
            val systemNumber = readSystemPhoneNumber(context, subscriptionManager, info)
            val effective = customNumber?.takeIf { it.isNotBlank() } ?: systemNumber?.takeIf { it.isNotBlank() }
            GatewaySimProfile(
                subscriptionId = info.subscriptionId,
                slotIndex = info.simSlotIndex,
                displayName = info.displayName?.toString()?.takeIf { it.isNotBlank() } ?: "SIM ${info.simSlotIndex + 1}",
                systemPhoneNumber = systemNumber,
                customPhoneNumber = customNumber,
                effectivePhoneNumber = effective,
                isCustom = !customNumber.isNullOrBlank()
            )
        }
    }

    private fun hasSubscriptionPermission(context: Context): Boolean {
        return hasPermission(context, Manifest.permission.READ_PHONE_STATE) ||
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || hasPermission(context, Manifest.permission.READ_PHONE_NUMBERS))
    }

    private fun hasPermission(context: Context, permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }

    @SuppressLint("MissingPermission")
    private fun readSystemPhoneNumber(context: Context, subscriptionManager: SubscriptionManager, info: SubscriptionInfo): String? {
        val fromSubscriptionManager = runCatching {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> subscriptionManager.getPhoneNumber(info.subscriptionId)
                else -> null
            }
        }.getOrNull()?.trim().takeIf { !it.isNullOrBlank() }

        val fromInfo = info.number?.trim().takeIf { !it.isNullOrBlank() }
        val fromTelephonyManager = runCatching {
            context.getSystemService(TelephonyManager::class.java)
                ?.createForSubscriptionId(info.subscriptionId)
                ?.line1Number
        }.getOrNull()?.trim().takeIf { !it.isNullOrBlank() }

        return fromSubscriptionManager ?: fromInfo ?: fromTelephonyManager
    }
}