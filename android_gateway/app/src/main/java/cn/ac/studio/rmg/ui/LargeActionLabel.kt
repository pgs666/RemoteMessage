package cn.ac.studio.rmg.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.annotation.AttrRes
import androidx.annotation.StyleRes
import androidx.core.content.ContextCompat
import cn.ac.studio.rmg.R

/**
 * Adapted from an upstream GPL-3.0 LargeActionLabel implementation.
 * This version removes databinding and uses local theme colors.
 */
class LargeActionLabel @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    @AttrRes defStyleAttr: Int = 0,
    @StyleRes defStyleRes: Int = 0
) : FrameLayout(context, attrs, defStyleAttr, defStyleRes) {
    private val iconView: ImageView
    private val textView: TextView
    private val subtextView: TextView

    var icon: Drawable?
        get() = iconView.drawable
        set(value) {
            iconView.setImageDrawable(value)
        }

    var text: CharSequence?
        get() = textView.text
        set(value) {
            textView.text = value
        }

    var subtext: CharSequence?
        get() = subtextView.text
        set(value) {
            subtextView.text = value
            subtextView.visibility = if (value.isNullOrBlank()) View.GONE else View.VISIBLE
        }

    init {
        LayoutInflater.from(context).inflate(R.layout.component_large_action_label, this, true)
        iconView = findViewById(R.id.iconView)
        textView = findViewById(R.id.textView)
        subtextView = findViewById(R.id.subtextView)

        isFocusable = true
        isClickable = true
        background = selectableItemBackground()

        context.theme.obtainStyledAttributes(attrs, R.styleable.LargeActionLabel, defStyleAttr, defStyleRes).apply {
            try {
                icon = getDrawable(R.styleable.LargeActionLabel_icon)
                text = getString(R.styleable.LargeActionLabel_text)
                subtext = getString(R.styleable.LargeActionLabel_subtext)
                iconView.imageTintList = colorStateListOrDefault(
                    getColorStateList(R.styleable.LargeActionLabel_iconTint)
                )
            } finally {
                recycle()
            }
        }
    }

    private fun colorStateListOrDefault(value: ColorStateList?): ColorStateList {
        return value ?: ColorStateList.valueOf(ContextCompat.getColor(context, R.color.rmg_icon))
    }

    private fun selectableItemBackground(): Drawable? {
        val typedArray = context.obtainStyledAttributes(intArrayOf(android.R.attr.selectableItemBackground))
        return try {
            typedArray.getDrawable(0)
        } finally {
            typedArray.recycle()
        }
    }
}
