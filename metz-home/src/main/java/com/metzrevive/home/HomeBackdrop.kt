package com.metzrevive.home

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable

/** Static curves from the user's reference; no bitmap, shader, blur or timer. */
class HomeBackdrop : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    override fun draw(canvas: Canvas) {
        val w = bounds.width().toFloat(); val h = bounds.height().toFloat()
        canvas.drawColor(0xff080f1d.toInt())
        paint.color = 0xff101f38.toInt()
        val top = Path().apply {
            moveTo(0f, 0f); lineTo(w * .24f, 0f)
            cubicTo(w * .40f, h * .30f, w * .52f, h * .55f, w, h * .36f)
            lineTo(w, 0f); close()
        }
        canvas.drawPath(top, paint)
        paint.color = 0xff0c192e.toInt()
        canvas.drawPath(Path().apply {
            moveTo(w * .38f, h); cubicTo(w * .56f, h * .72f, w * .72f, h * .69f, w, h * .74f)
            lineTo(w,h); close()
        }, paint)
    }
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(filter: ColorFilter?) { paint.colorFilter = filter }
    @Deprecated("Legacy Drawable API") override fun getOpacity() = PixelFormat.OPAQUE
}
