package com.twinklywall.led_matrix_controller

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.*
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.*
import android.widget.FrameLayout
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Floating overlay that acts as a screen crop-region selector.
 * Aspect ratio is locked to 90:50 (curtain ratio).
 * Its position & size on screen map directly to the normalized crop rect
 * (0-1 coordinates relative to the phone screen) that Flutter reads each frame.
 */
class OverlayService : Service() {
    companion object {
        private const val TAG = "TwinklyWall.Overlay"
        // Overlay aspect ratio: landscape 90:50 matching the LED curtain.
        // The compose function independently maps X/Y from crop→bubble, so the
        // overlay should match the curtain shape on screen for intuitive UX.
        const val CURTAIN_ASPECT = 90f / 50f

        // Screen crop rect (normalized 0-1) — written by overlay, polled by Flutter
        @Volatile var cropLeft: Float = 0.1f
        @Volatile var cropTop: Float = 0.3f
        @Volatile var cropWidth: Float = 0.8f
        @Volatile var cropHeight: Float = 0.25f
        @Volatile var overlayActive: Boolean = false
        // Status bar height in pixels — set once in showOverlay(), read by syncCropToService().
        // Needed because without FLAG_LAYOUT_NO_LIMITS, layoutParams.y is relative to the
        // usable area (below status bar), but MediaProjection captures from the absolute top.
        @Volatile var statusBarHeight: Int = 0
        // Callback set by MainActivity — invoked when the X button is tapped so Flutter
        // can stop the bubble cast before the overlay service shuts down.
        var onStopCastRequested: (() -> Unit)? = null

        fun setCropState(left: Float, top: Float, width: Float, height: Float) {
            cropLeft = left; cropTop = top; cropWidth = width; cropHeight = height
        }
    }

    private var windowManager: WindowManager? = null
    private var overlayView: CropOverlayView? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "OverlayService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "STOP") {
            removeOverlay()
            stopSelf()
            return START_NOT_STICKY
        }
        showOverlay()
        return START_NOT_STICKY
    }

    private fun showOverlay() {
        if (overlayView != null) return
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val dm = resources.displayMetrics
        val screenW = dm.widthPixels
        val screenH = dm.heightPixels

        // Measure the top system bar (status bar) height once.
        // Without FLAG_LAYOUT_NO_LIMITS, the window manager positions the overlay relative
        // to the usable area (below the status bar). MediaProjection captures from y=0
        // (absolute top of screen), so we must offset cropTop by this amount.
        statusBarHeight = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .currentWindowMetrics.windowInsets
                .getInsets(WindowInsets.Type.systemBars()).top
        } else {
            val resId = resources.getIdentifier("status_bar_height", "dimen", "android")
            if (resId > 0) resources.getDimensionPixelSize(resId) else 0
        }

        val density = dm.density
        val stripH = (CropOverlayView.STRIP_HEIGHT_DP * density).toInt()

        // Compute initial crop box size with locked aspect ratio
        var cropBoxW = (cropWidth * screenW).toInt().coerceAtLeast(200)
        var cropBoxH = (cropBoxW / CURTAIN_ASPECT).toInt().coerceAtLeast(112)
        cropBoxW = (cropBoxH * CURTAIN_ASPECT).toInt()

        // Window height = crop box height + button strip above it
        val overlayW = cropBoxW
        val overlayH = cropBoxH + stripH

        val overlayX = (cropLeft * screenW).toInt()
        // Crop box starts at y=stripH inside the window.
        // Crop box top (absolute) = layoutParams.y + statusBarHeight + stripH = cropTop * screenH
        // → layoutParams.y = cropTop * screenH - statusBarHeight - stripH
        val overlayY = (cropTop * screenH - statusBarHeight - stripH).toInt().coerceAtLeast(0)

        val params = WindowManager.LayoutParams(
            overlayW,
            overlayH,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            // No FLAG_SECURE — it renders the overlay as solid BLACK in capture.
            // Instead, the overlay uses a fully transparent background so the
            // captured content shows through. At 90×50 LED resolution the thin
            // bracket handles and small buttons are sub-pixel and invisible.
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = overlayX
        params.y = overlayY

        overlayView = CropOverlayView(this, params, windowManager!!,
            onClose = {
                // Notify Flutter to stop casting before tearing down the overlay
                onStopCastRequested?.invoke()
                removeOverlay()
                stopSelf()
            },
            onBack = {
                // Bring Flutter app to front
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                launchIntent?.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                startActivity(launchIntent)
            }
        )

        windowManager?.addView(overlayView, params)
        overlayActive = true
        // Sync immediately after adding
        overlayView?.syncCropToService()
        Log.d(TAG, "Overlay shown at $overlayX,$overlayY ${overlayW}x${overlayH}")
    }

    private fun removeOverlay() {
        overlayView?.let {
            try { windowManager?.removeView(it) } catch (_: Exception) {}
        }
        overlayView = null
        overlayActive = false
        Log.d(TAG, "Overlay removed")
    }

    override fun onDestroy() {
        removeOverlay()
        super.onDestroy()
    }
}

/**
 * Transparent crop-region rectangle with corner handles, locked to 90:50 aspect.
 * Drag body to move, drag corners to resize (aspect-locked).
 * Back arrow (top-left) brings app to front, close (top-right) dismisses.
 * Corner resize always takes priority over button hits.
 */
class CropOverlayView(
    context: Context,
    private val layoutParams: WindowManager.LayoutParams,
    private val windowManager: WindowManager,
    private val onClose: () -> Unit,
    private val onBack: () -> Unit
) : FrameLayout(context) {

    // Button strip height in pixels — buttons are drawn here, ABOVE the crop box
    private val stripH = (STRIP_HEIGHT_DP * context.resources.displayMetrics.density).toInt()

    companion object {
        private const val HANDLE_HIT_PX = 72f   // large touch hit zone for corners
        private const val HANDLE_ARM_PX = 32f    // visual bracket arm length
        private const val HANDLE_STROKE = 6f
        private const val DOT_RADIUS = 10f
        private const val MIN_WIDTH_PX = 200
        private const val BTN_RADIUS = 22f       // button circle radius (drawn)
        // Height of the button strip ABOVE the crop box (density-independent pixels).
        // Buttons live in this strip, which is outside the MediaProjection capture area.
        const val STRIP_HEIGHT_DP = 52f
    }

    private enum class DragMode { NONE, MOVE, RESIZE_TL, RESIZE_TR, RESIZE_BL, RESIZE_BR }

    private var dragMode = DragMode.NONE
    private var dragStartRawX = 0f
    private var dragStartRawY = 0f
    private var dragStartOverlayX = 0
    private var dragStartOverlayY = 0
    private var dragStartOverlayW = 0
    private var dragStartOverlayH = 0

    // Paints
    // Fully transparent background — content behind the overlay is captured
    // unobstructed by MediaProjection. The brackets/buttons are visible on the
    // phone screen but invisible at 90×50 LED resolution.
    private val bgPaint = Paint().apply { color = Color.argb(0, 0, 0, 0) }
    // Low-alpha visuals — visible on phone screen but invisible at 90×50 LED resolution.
    private val borderPaint = Paint().apply {
        color = Color.argb(50, 0, 220, 255)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
    }
    private val bracketPaint = Paint().apply {
        color = Color.argb(90, 0, 220, 255)
        style = Paint.Style.STROKE
        strokeWidth = 3f
        strokeCap = Paint.Cap.ROUND
    }
    private val dotPaint = Paint().apply { color = Color.argb(90, 0, 220, 255) }
    private val dotBorderPaint = Paint().apply {
        color = Color.argb(60, 255, 255, 255)
        style = Paint.Style.STROKE
        strokeWidth = 1.5f
    }
    // Close button (red circle with X)
    private val closeBtnBgPaint = Paint().apply { color = Color.argb(220, 50, 50, 60) }
    private val closeBtnPaint = Paint().apply {
        color = Color.argb(255, 255, 80, 80)
        style = Paint.Style.STROKE
        strokeWidth = 3f
        strokeCap = Paint.Cap.ROUND
        isAntiAlias = true
    }
    // Back button (purple circle with arrow)
    private val backBtnBgPaint = Paint().apply { color = Color.argb(220, 50, 50, 60) }
    private val backBtnPaint = Paint().apply {
        color = Color.argb(255, 180, 100, 255)
        style = Paint.Style.STROKE
        strokeWidth = 3f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        isAntiAlias = true
    }

    init {
        setWillNotDraw(false)
        setBackgroundColor(Color.TRANSPARENT)
    }

    /** Writes current overlay screen position back to OverlayService as normalized 0-1 crop. */
    fun syncCropToService() {
        val dm = resources.displayMetrics
        val screenW = dm.widthPixels.toFloat()
        val screenH = dm.heightPixels.toFloat()
        val sbH = OverlayService.statusBarHeight.toFloat()
        val sH = stripH.toFloat()
        // cropLeft: window x = left edge of the crop box (no horizontal strip)
        OverlayService.cropLeft = (layoutParams.x.toFloat() / screenW).coerceIn(0f, 1f)
        // cropTop: crop box starts at stripH inside window; add statusBarHeight for absolute coords
        OverlayService.cropTop = ((layoutParams.y.toFloat() + sbH + sH) / screenH).coerceIn(0f, 1f)
        // cropWidth: window width equals crop box width
        OverlayService.cropWidth = (layoutParams.width.toFloat() / screenW).coerceIn(0.01f, 1f)
        // cropHeight: window height minus the button strip above
        OverlayService.cropHeight = ((layoutParams.height.toFloat() - sH) / screenH).coerceIn(0.01f, 1f)
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        val density = resources.displayMetrics.density
        val sH = stripH.toFloat()

        // Transparent fill for entire window (strip + crop area)
        canvas.drawRect(0f, 0f, w, h, bgPaint)

        // Separator between button strip and crop area
        val sepPaint = Paint().apply {
            color = Color.argb(60, 0, 220, 255)
            strokeWidth = 1f * density
        }
        canvas.drawLine(0f, sH, w, sH, sepPaint)

        // Crop box border (below the strip — this is the captured region)
        canvas.drawRect(2f, sH + 2f, w - 2f, h - 2f, borderPaint)

        // Corner L-brackets + dots at the four corners of the crop box
        val arm = HANDLE_ARM_PX * density
        val dotR = DOT_RADIUS * density
        val corners = arrayOf(
            floatArrayOf(0f, sH,  1f,  1f),   // top-left of crop
            floatArrayOf(w,  sH, -1f,  1f),   // top-right of crop
            floatArrayOf(0f,  h,  1f, -1f),   // bottom-left
            floatArrayOf(w,   h, -1f, -1f),   // bottom-right
        )
        for ((cx, cy, dx, dy) in corners) {
            canvas.drawLine(cx, cy, cx + arm * dx, cy, bracketPaint)
            canvas.drawLine(cx, cy, cx, cy + arm * dy, bracketPaint)
            canvas.drawCircle(cx, cy, dotR, dotPaint)
            canvas.drawCircle(cx, cy, dotR, dotBorderPaint)
        }

        // Back button — left quarter of strip (ABOVE crop area, not captured)
        val btnR = BTN_RADIUS * density
        val backCx = w * 0.25f
        val backCy = sH / 2f
        canvas.drawCircle(backCx, backCy, btnR, backBtnBgPaint)
        val arrowSize = 9f * density
        canvas.drawLine(backCx - arrowSize * 0.6f, backCy, backCx + arrowSize * 0.6f, backCy, backBtnPaint)
        canvas.drawLine(backCx - arrowSize * 0.6f, backCy, backCx - arrowSize * 0.1f, backCy - arrowSize * 0.5f, backBtnPaint)
        canvas.drawLine(backCx - arrowSize * 0.6f, backCy, backCx - arrowSize * 0.1f, backCy + arrowSize * 0.5f, backBtnPaint)

        // Close button — right quarter of strip (ABOVE crop area, not captured)
        val closeCx = w * 0.75f
        val closeCy = sH / 2f
        canvas.drawCircle(closeCx, closeCy, btnR, closeBtnBgPaint)
        val xSize = 7f * density
        canvas.drawLine(closeCx - xSize, closeCy - xSize, closeCx + xSize, closeCy + xSize, closeBtnPaint)
        canvas.drawLine(closeCx + xSize, closeCy - xSize, closeCx - xSize, closeCy + xSize, closeBtnPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val density = resources.displayMetrics.density
        val rawX = event.rawX
        val rawY = event.rawY
        val x = event.x
        val y = event.y
        val w = width.toFloat()
        val h = height.toFloat()

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                val cornerHitR = HANDLE_HIT_PX * density / 2
                val sH = stripH.toFloat()

                dragStartRawX = rawX
                dragStartRawY = rawY
                dragStartOverlayX = layoutParams.x
                dragStartOverlayY = layoutParams.y
                dragStartOverlayW = layoutParams.width
                dragStartOverlayH = layoutParams.height

                // CROP BOX CORNERS FIRST — corners of the crop area (below the strip)
                if (hitCorner(x, y, w, h, cornerHitR)) {
                    dragMode = DragMode.RESIZE_BR
                } else if (hitCorner(x, y, 0f, h, cornerHitR)) {
                    dragMode = DragMode.RESIZE_BL
                } else if (hitCorner(x, y, w, sH, cornerHitR)) {
                    dragMode = DragMode.RESIZE_TR
                } else if (hitCorner(x, y, 0f, sH, cornerHitR)) {
                    dragMode = DragMode.RESIZE_TL
                } else if (y < sH) {
                    // Button strip (above the crop box): left = back, right = close
                    if (x < w / 2) onBack() else onClose()
                    return true
                } else {
                    // Crop body → move entire window
                    dragMode = DragMode.MOVE
                }
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                val dx = (rawX - dragStartRawX).toInt()
                val dy = (rawY - dragStartRawY).toInt()

                when (dragMode) {
                    DragMode.MOVE -> {
                        layoutParams.x = dragStartOverlayX + dx
                        layoutParams.y = dragStartOverlayY + dy
                        try { windowManager.updateViewLayout(this, layoutParams) } catch (_: Exception) {}
                        syncCropToService()
                    }
                    DragMode.RESIZE_BR -> {
                        val newCropW = (dragStartOverlayW + dx).coerceAtLeast(MIN_WIDTH_PX)
                        val newCropH = (newCropW / OverlayService.CURTAIN_ASPECT).toInt()
                        layoutParams.width = newCropW
                        layoutParams.height = newCropH + stripH
                        try { windowManager.updateViewLayout(this, layoutParams) } catch (_: Exception) {}
                        syncCropToService()
                        invalidate()
                    }
                    DragMode.RESIZE_TL -> {
                        val newCropW = (dragStartOverlayW - dx).coerceAtLeast(MIN_WIDTH_PX)
                        val newCropH = (newCropW / OverlayService.CURTAIN_ASPECT).toInt()
                        val newH = newCropH + stripH
                        layoutParams.x = dragStartOverlayX + dragStartOverlayW - newCropW
                        layoutParams.y = dragStartOverlayY + dragStartOverlayH - newH
                        layoutParams.width = newCropW
                        layoutParams.height = newH
                        try { windowManager.updateViewLayout(this, layoutParams) } catch (_: Exception) {}
                        syncCropToService()
                        invalidate()
                    }
                    DragMode.RESIZE_TR -> {
                        val newCropW = (dragStartOverlayW + dx).coerceAtLeast(MIN_WIDTH_PX)
                        val newCropH = (newCropW / OverlayService.CURTAIN_ASPECT).toInt()
                        val newH = newCropH + stripH
                        layoutParams.y = dragStartOverlayY + dragStartOverlayH - newH
                        layoutParams.width = newCropW
                        layoutParams.height = newH
                        try { windowManager.updateViewLayout(this, layoutParams) } catch (_: Exception) {}
                        syncCropToService()
                        invalidate()
                    }
                    DragMode.RESIZE_BL -> {
                        val newCropW = (dragStartOverlayW - dx).coerceAtLeast(MIN_WIDTH_PX)
                        val newCropH = (newCropW / OverlayService.CURTAIN_ASPECT).toInt()
                        layoutParams.x = dragStartOverlayX + dragStartOverlayW - newCropW
                        layoutParams.width = newCropW
                        layoutParams.height = newCropH + stripH
                        try { windowManager.updateViewLayout(this, layoutParams) } catch (_: Exception) {}
                        syncCropToService()
                        invalidate()
                    }
                    DragMode.NONE -> {}
                }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                dragMode = DragMode.NONE
                syncCropToService()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun hitCorner(px: Float, py: Float, cx: Float, cy: Float, r: Float): Boolean {
        return abs(px - cx) <= r && abs(py - cy) <= r
    }
}
