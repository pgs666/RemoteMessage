package cn.ac.studio.rmg.ui

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import cn.ac.studio.rmg.R
import kotlin.math.min

class ScannerOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {
    private val frame = RectF()
    private val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x99000000.toInt()
    }
    private val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.rmg_primary)
        strokeCap = Paint.Cap.ROUND
        strokeWidth = dp(3f)
        style = Paint.Style.STROKE
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.rmg_accent)
        strokeCap = Paint.Cap.ROUND
        strokeWidth = dp(2f)
        style = Paint.Style.STROKE
    }
    private var scanProgress = 0.15f
    private var animator: ValueAnimator? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        animator = ValueAnimator.ofFloat(0.15f, 0.85f).apply {
            duration = 1600L
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener {
                scanProgress = it.animatedValue as Float
                invalidate()
            }
            start()
        }
    }

    override fun onDetachedFromWindow() {
        animator?.cancel()
        animator = null
        super.onDetachedFromWindow()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (width == 0 || height == 0) return

        val size = min(width * 0.72f, dp(320f))
        val left = (width - size) / 2f
        val centeredTop = (height - size) / 2f - dp(28f)
        val top = centeredTop.coerceIn(dp(112f), (height - size - dp(144f)).coerceAtLeast(dp(112f)))
        frame.set(left, top, left + size, top + size)

        canvas.drawRect(0f, 0f, width.toFloat(), frame.top, maskPaint)
        canvas.drawRect(0f, frame.bottom, width.toFloat(), height.toFloat(), maskPaint)
        canvas.drawRect(0f, frame.top, frame.left, frame.bottom, maskPaint)
        canvas.drawRect(frame.right, frame.top, width.toFloat(), frame.bottom, maskPaint)

        val corner = dp(42f)
        canvas.drawLine(frame.left, frame.top, frame.left + corner, frame.top, cornerPaint)
        canvas.drawLine(frame.left, frame.top, frame.left, frame.top + corner, cornerPaint)
        canvas.drawLine(frame.right - corner, frame.top, frame.right, frame.top, cornerPaint)
        canvas.drawLine(frame.right, frame.top, frame.right, frame.top + corner, cornerPaint)
        canvas.drawLine(frame.left, frame.bottom - corner, frame.left, frame.bottom, cornerPaint)
        canvas.drawLine(frame.left, frame.bottom, frame.left + corner, frame.bottom, cornerPaint)
        canvas.drawLine(frame.right - corner, frame.bottom, frame.right, frame.bottom, cornerPaint)
        canvas.drawLine(frame.right, frame.bottom - corner, frame.right, frame.bottom, cornerPaint)

        val y = frame.top + frame.height() * scanProgress
        canvas.drawLine(frame.left + dp(22f), y, frame.right - dp(22f), y, linePaint)
    }

    private fun dp(value: Float): Float {
        return value * resources.displayMetrics.density
    }
}
