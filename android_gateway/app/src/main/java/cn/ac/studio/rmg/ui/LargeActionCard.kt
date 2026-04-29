package cn.ac.studio.rmg.ui

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.Drawable
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.View
import android.widget.ImageView
import android.widget.TextView
import androidx.annotation.AttrRes
import androidx.core.content.ContextCompat
import cn.ac.studio.rmg.R
import com.google.android.material.card.MaterialCardView

/**
 * Adapted from an upstream GPL-3.0 LargeActionCard implementation.
 * This version removes databinding and keeps only the reusable dashboard component behavior.
 */
class LargeActionCard @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    @AttrRes defStyleAttr: Int = 0
) : MaterialCardView(context, attrs, defStyleAttr) {
    private val iconView: ImageView
    private val textView: TextView
    private val subtextView: TextView

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

    var icon: Drawable?
        get() = iconView.drawable
        set(value) {
            iconView.setImageDrawable(value)
        }

    init {
        LayoutInflater.from(context).inflate(R.layout.component_large_action_label, this, true)
        iconView = findViewById(R.id.iconView)
        textView = findViewById(R.id.textView)
        subtextView = findViewById(R.id.subtextView)

        isFocusable = true
        isClickable = true
        foreground = selectableItemBackground()

        context.theme.obtainStyledAttributes(attrs, R.styleable.LargeActionCard, defStyleAttr, 0).apply {
            try {
                icon = getDrawable(R.styleable.LargeActionCard_icon)
                text = getString(R.styleable.LargeActionCard_text)
                subtext = getString(R.styleable.LargeActionCard_subtext)
                iconView.imageTintList = colorStateListOrDefault(
                    getColorStateList(R.styleable.LargeActionCard_iconTint)
                )
            } finally {
                recycle()
            }
        }

        minimumHeight = resources.getDimensionPixelSize(R.dimen.large_action_card_min_height)
        radius = resources.getDimension(R.dimen.large_action_card_radius)
        elevation = resources.getDimension(R.dimen.large_action_card_elevation)
        if (cardBackgroundColor == ColorStateList.valueOf(0)) {
            setCardBackgroundColor(resolveColor(com.google.android.material.R.attr.colorSurface))
        }
    }

    private fun colorStateListOrDefault(value: ColorStateList?): ColorStateList {
        return value ?: ColorStateList.valueOf(resolveColor(android.R.attr.textColorPrimary))
    }

    private fun resolveColor(attr: Int): Int {
        val typedArray = context.obtainStyledAttributes(intArrayOf(attr))
        return try {
            typedArray.getColor(0, ContextCompat.getColor(context, R.color.rmg_icon))
        } finally {
            typedArray.recycle()
        }
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
