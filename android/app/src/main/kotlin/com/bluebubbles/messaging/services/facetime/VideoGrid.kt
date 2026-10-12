package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.util.AttributeSet
import android.view.View
import android.view.ViewGroup
import kotlin.math.ceil
import kotlin.math.sqrt

/**
 * Lays out the visible children as an even grid of remote participants. Children are hidden,
 * never removed: detaching a TextureView destroys its surface and the decoder drawing into it.
 */
class VideoGrid(context: Context, attrs: AttributeSet?) : ViewGroup(context, attrs) {
    private fun shown() = (0 until childCount).map(::getChildAt).filter { it.visibility != View.GONE }

    // two people sit side by side in landscape, stacked in portrait; more get a near-square grid
    private fun columns(n: Int, width: Int, height: Int) =
        if (n == 2) (if (width > height) 2 else 1) else ceil(sqrt(n.toDouble())).toInt().coerceAtLeast(1)

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val width = MeasureSpec.getSize(widthSpec)
        val height = MeasureSpec.getSize(heightSpec)
        setMeasuredDimension(width, height)
        val views = shown()
        if (views.isEmpty()) return
        val cols = columns(views.size, width, height)
        val rows = (views.size + cols - 1) / cols
        views.forEach {
            it.measure(MeasureSpec.makeMeasureSpec(width / cols, MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(height / rows, MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val views = shown()
        if (views.isEmpty()) return
        val cols = columns(views.size, r - l, b - t)
        val rows = (views.size + cols - 1) / cols
        val w = (r - l) / cols
        val h = (b - t) / rows
        views.forEachIndexed { i, v ->
            val x = i % cols * w
            val y = i / cols * h
            v.layout(x, y, x + w, y + h)
        }
    }
}
