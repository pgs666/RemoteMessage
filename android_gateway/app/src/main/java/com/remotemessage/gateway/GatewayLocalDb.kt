package com.remotemessage.gateway

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

data class PendingUpload(
    val id: Long,
    val phone: String,
    val content: String,
    val timestamp: Long,
    val direction: String,
    val messageId: String?
)

class GatewayLocalDb(context: Context) : SQLiteOpenHelper(context, "gateway_private.db", null, 2) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS pending_uploads(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phone TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                direction TEXT NOT NULL,
                message_id TEXT
            )
            """.trimIndent()
        )
        ensureIndexes(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        ensureIndexes(db)
    }

    fun enqueueUpload(phone: String, content: String, timestamp: Long, direction: String, messageId: String?) {
        val values = ContentValues().apply {
            put("phone", phone)
            put("content", content)
            put("timestamp", timestamp)
            put("direction", direction)
            put("message_id", messageId)
        }
        writableDatabase.insertWithOnConflict("pending_uploads", null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun listPending(limit: Int = 200): List<PendingUpload> {
        val result = mutableListOf<PendingUpload>()
        val cursor = readableDatabase.query(
            "pending_uploads",
            arrayOf("id", "phone", "content", "timestamp", "direction", "message_id"),
            null,
            null,
            null,
            null,
            "id ASC",
            limit.toString()
        )
        cursor.use {
            val idIdx = it.getColumnIndexOrThrow("id")
            val phoneIdx = it.getColumnIndexOrThrow("phone")
            val contentIdx = it.getColumnIndexOrThrow("content")
            val tsIdx = it.getColumnIndexOrThrow("timestamp")
            val dirIdx = it.getColumnIndexOrThrow("direction")
            val msgIdIdx = it.getColumnIndexOrThrow("message_id")
            while (it.moveToNext()) {
                result.add(
                    PendingUpload(
                        id = it.getLong(idIdx),
                        phone = it.getString(phoneIdx) ?: "unknown",
                        content = it.getString(contentIdx) ?: "",
                        timestamp = it.getLong(tsIdx),
                        direction = it.getString(dirIdx) ?: "inbound",
                        messageId = it.getString(msgIdIdx)
                    )
                )
            }
        }
        return result
    }

    fun deletePending(id: Long) {
        writableDatabase.delete("pending_uploads", "id=?", arrayOf(id.toString()))
    }

    private fun ensureIndexes(db: SQLiteDatabase) {
        db.execSQL(
            """
            DELETE FROM pending_uploads
            WHERE message_id IS NOT NULL
              AND id NOT IN (
                SELECT MIN(id)
                FROM pending_uploads
                WHERE message_id IS NOT NULL
                GROUP BY message_id
              )
            """.trimIndent()
        )
        db.execSQL("CREATE INDEX IF NOT EXISTS idx_pending_uploads_timestamp ON pending_uploads(timestamp)")
        db.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS idx_pending_uploads_message_id ON pending_uploads(message_id) WHERE message_id IS NOT NULL")
    }
}
