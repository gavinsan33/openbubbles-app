package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.graphics.Outline
import android.util.AttributeSet
import android.view.View
import android.view.ViewGroup
import android.view.ViewOutlineProvider
import kotlin.math.ceil
import kotlin.math.sqrt

/**
 * Lays out the visible children as an even grid of remote participants, FaceTime style: rounded
 * tiles with a small gap, and a short last row stretched across the width. Children are hidden,
 * never removed: detaching a TextureView destroys its surface and the decoder drawing into it.
 */
class VideoGrid(context: Context, attrs: AttributeSet?) : ViewGroup(context, attrs) {
    private val density = resources.displayMetrics.density
    private val gap = (6 * density).toInt()
    private val radius = 16 * density

    // a lone participant fills the screen edge to edge; tiles get rounded corners
    private var tiled = false
    private val tileOutline = object : ViewOutlineProvider() {
        override fun getOutline(view: View, outline: Outline) {
            outline.setRoundRect(0, 0, view.width, view.height, if (tiled) radius else 0f)
        }
    }

    override fun onViewAdded(child: View) {
        super.onViewAdded(child)
        child.outlineProvider = tileOutline
        child.clipToOutline = true
    }

    private fun shown() = (0 until childCount).map(::getChildAt).filter { it.visibility != View.GONE }

    // two people sit side by side in landscape, stacked in portrait; more get a near-square grid
    private fun columns(n: Int, width: Int, height: Int) =
        if (n == 2) (if (width > height) 2 else 1) else ceil(sqrt(n.toDouble())).toInt().coerceAtLeast(1)

    /** Each visible child's rect within a [width]x[height] grid, as (left, top, right, bottom). */
    private fun cells(n: Int, width: Int, height: Int): List<IntArray> {
        if (n == 0) return emptyList()
        if (n == 1) return listOf(intArrayOf(0, 0, width, height))
        val cols = columns(n, width, height)
        val rows = (n + cols - 1) / cols
        val h = (height - gap * (rows + 1)) / rows
        return (0 until n).map { i ->
            val row = i / cols
            // the last row may be short: its tiles share the full width
            val inRow = if (row == rows - 1) n - row * cols else cols
            val w = (width - gap * (inRow + 1)) / inRow
            val x = gap + (i % cols) * (w + gap)
            val y = gap + row * (h + gap)
            intArrayOf(x, y, x + w, y + h)
        }
    }

    override fun onMeasure(widthSpec: Int, heightSpec: Int) {
        val width = MeasureSpec.getSize(widthSpec)
        val height = MeasureSpec.getSize(heightSpec)
        setMeasuredDimension(width, height)
        val views = shown()
        val wasTiled = tiled
        tiled = views.size > 1
        if (tiled != wasTiled) views.forEach { it.invalidateOutline() }
        cells(views.size, width, height).forEachIndexed { i, c ->
            views[i].measure(MeasureSpec.makeMeasureSpec(c[2] - c[0], MeasureSpec.EXACTLY), MeasureSpec.makeMeasureSpec(c[3] - c[1], MeasureSpec.EXACTLY))
        }
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val views = shown()
        cells(views.size, r - l, b - t).forEachIndexed { i, c -> views[i].layout(c[0], c[1], c[2], c[3]) }
    }
}
