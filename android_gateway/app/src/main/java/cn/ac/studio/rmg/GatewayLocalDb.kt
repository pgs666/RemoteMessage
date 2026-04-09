package cn.ac.studio.rmg

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
    val messageId: String?,
    val simSlotIndex: Int?,
    val simPhoneNumber: String?,
    val simCount: Int?
)

data class PendingUploadInput(
    val phone: String,
    val content: String,
    val timestamp: Long,
    val direction: String,
    val messageId: String?,
    val simSlotIndex: Int? = null,
    val simPhoneNumber: String? = null,
    val simCount: Int? = null
)

class GatewayLocalDb(context: Context) : SQLiteOpenHelper(context, "gateway_private.db", null, 3) {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS pending_uploads(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                phone TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                direction TEXT NOT NULL,
                message_id TEXT,
                sim_slot_index INTEGER,
                sim_phone_number TEXT,
                sim_count INTEGER
            )
            """.trimIndent()
        )
        ensureIndexes(db)
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        ensureColumns(db)
        ensureIndexes(db)
    }

    fun enqueueUpload(
        phone: String,
        content: String,
        timestamp: Long,
        direction: String,
        messageId: String?,
        simSlotIndex: Int? = null,
        simPhoneNumber: String? = null,
        simCount: Int? = null
    ) {
        val values = ContentValues().apply {
            put("phone", phone)
            put("content", content)
            put("timestamp", timestamp)
            put("direction", direction)
            put("message_id", messageId)
            put("sim_slot_index", simSlotIndex)
            put("sim_phone_number", simPhoneNumber)
            put("sim_count", simCount)
        }
        writableDatabase.insertWithOnConflict("pending_uploads", null, values, SQLiteDatabase.CONFLICT_IGNORE)
    }

    fun enqueueUploads(items: List<PendingUploadInput>) {
        if (items.isEmpty()) return

        val db = writableDatabase
        db.beginTransaction()
        try {
            items.forEach { item ->
                val values = ContentValues().apply {
                    put("phone", item.phone)
                    put("content", item.content)
                    put("timestamp", item.timestamp)
                    put("direction", item.direction)
                    put("message_id", item.messageId)
                    put("sim_slot_index", item.simSlotIndex)
                    put("sim_phone_number", item.simPhoneNumber)
                    put("sim_count", item.simCount)
                }
                db.insertWithOnConflict("pending_uploads", null, values, SQLiteDatabase.CONFLICT_IGNORE)
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun listPending(limit: Int = 200): List<PendingUpload> {
        val result = mutableListOf<PendingUpload>()
        val cursor = readableDatabase.query(
            "pending_uploads",
            arrayOf("id", "phone", "content", "timestamp", "direction", "message_id", "sim_slot_index", "sim_phone_number", "sim_count"),
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
            val simSlotIdx = it.getColumnIndex("sim_slot_index")
            val simPhoneIdx = it.getColumnIndex("sim_phone_number")
            val simCountIdx = it.getColumnIndex("sim_count")
            while (it.moveToNext()) {
                result.add(
                    PendingUpload(
                        id = it.getLong(idIdx),
                        phone = it.getString(phoneIdx) ?: "unknown",
                        content = it.getString(contentIdx) ?: "",
                        timestamp = it.getLong(tsIdx),
                        direction = it.getString(dirIdx) ?: "inbound",
                        messageId = it.getString(msgIdIdx),
                        simSlotIndex = if (simSlotIdx >= 0 && !it.isNull(simSlotIdx)) it.getInt(simSlotIdx) else null,
                        simPhoneNumber = if (simPhoneIdx >= 0) it.getString(simPhoneIdx) else null,
                        simCount = if (simCountIdx >= 0 && !it.isNull(simCountIdx)) it.getInt(simCountIdx) else null
                    )
                )
            }
        }
        return result
    }

    fun deletePending(id: Long) {
        writableDatabase.delete("pending_uploads", "id=?", arrayOf(id.toString()))
    }

    fun deletePending(ids: List<Long>) {
        if (ids.isEmpty()) return

        val db = writableDatabase
        db.beginTransaction()
        try {
            ids.forEach { id ->
                db.delete("pending_uploads", "id=?", arrayOf(id.toString()))
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    fun countPending(): Int {
        val cursor = readableDatabase.rawQuery("SELECT COUNT(1) FROM pending_uploads", null)
        cursor.use {
            return if (it.moveToFirst()) it.getInt(0) else 0
        }
    }

    fun clearPendingUploads() {
        writableDatabase.delete("pending_uploads", null, null)
    }

    private fun ensureColumns(db: SQLiteDatabase) {
        runCatching { db.execSQL("ALTER TABLE pending_uploads ADD COLUMN sim_slot_index INTEGER") }
        runCatching { db.execSQL("ALTER TABLE pending_uploads ADD COLUMN sim_phone_number TEXT") }
        runCatching { db.execSQL("ALTER TABLE pending_uploads ADD COLUMN sim_count INTEGER") }
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
