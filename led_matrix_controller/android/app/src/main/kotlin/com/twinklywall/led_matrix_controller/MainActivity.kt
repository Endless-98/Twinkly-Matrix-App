package com.twinklywall.led_matrix_controller

import android.app.Activity
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.twinklywall.led_matrix_controller/screen_capture"
        private const val REQUEST_CODE = 100
    }

    private val screenCaptureService = ScreenCaptureService()
    private lateinit var mediaProjectionManager: MediaProjectionManager
    private var mediaProjection: MediaProjection? = null
    private var pendingStartResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        mediaProjectionManager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScreenCapture" -> {
                    if (screenCaptureService.isCapturing) {
                        result.success(true)
                    } else {
                        pendingStartResult = result
                        startScreenCapture()
                    }
                }
                "stopScreenCapture" -> {
                    stopScreenCapture()
                    result.success(true)
                }
                "isCapturing" -> {
                    result.success(screenCaptureService.isCapturing)
                }
                "captureScreenshot" -> {
                    val frame = screenCaptureService.captureFrame()
                    if (frame != null) {
                        result.success(frame)
                    } else {
                        result.error("CAPTURE_FAILED", "No frame available", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startScreenCapture() {
        val intent = mediaProjectionManager.createScreenCaptureIntent()
        startActivityForResult(intent, REQUEST_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE) {
            val pendingResult = pendingStartResult
            pendingStartResult = null
            if (resultCode == Activity.RESULT_OK && data != null) {
                mediaProjection = mediaProjectionManager.getMediaProjection(resultCode, data)
                if (mediaProjection != null) {
                    screenCaptureService.startCapture(mediaProjection!!, this)
                    pendingResult?.success(true)
                }
            } else {
                pendingResult?.error("PERMISSION_DENIED", "User denied screen capture permission", null)
            }
        }
    }

    private fun stopScreenCapture() {
        screenCaptureService.stopCapture()
        mediaProjection?.stop()
        mediaProjection = null
    }
}

@RequiresApi(Build.VERSION_CODES.LOLLIPOP)
class ScreenCaptureService : Service() {
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var captureDensity: Int = 0
    private var mediaProjection: MediaProjection? = null
    private val targetWidth = 90
    private val targetHeight = 50
    var isCapturing = false
        private set

    fun startCapture(projection: MediaProjection, context: Context) {
        stopCapture()

        mediaProjection = projection
        val metrics: DisplayMetrics = context.resources.displayMetrics
        captureDensity = metrics.densityDpi
        imageReader = ImageReader.newInstance(targetWidth, targetHeight, PixelFormat.RGBA_8888, 2)

        virtualDisplay = mediaProjection?.createVirtualDisplay(
            "LEDMatrixCapture",
            targetWidth,
            targetHeight,
            captureDensity,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_PRESENTATION,
            imageReader?.surface,
            null,
            null
        )

        isCapturing = true
    }

    fun captureFrame(): ByteArray? {
        if (!isCapturing) return null
        val reader = imageReader ?: return null
        val image = reader.acquireLatestImage() ?: return null

        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val rowData = ByteArray(rowStride)
            val out = ByteArray(targetWidth * targetHeight * 3)
            var outOffset = 0

            for (y in 0 until targetHeight) {
                buffer.position(y * rowStride)
                buffer.get(rowData, 0, rowStride)

                var xOffset = 0
                for (x in 0 until targetWidth) {
                    val r = rowData[xOffset].toInt() and 0xFF
                    val g = rowData[xOffset + 1].toInt() and 0xFF
                    val b = rowData[xOffset + 2].toInt() and 0xFF

                    out[outOffset++] = r.toByte()
                    out[outOffset++] = g.toByte()
                    out[outOffset++] = b.toByte()

                    xOffset += pixelStride
                }
            }

            return out
        } catch (_: Exception) {
            return null
        } finally {
            image.close()
        }
    }

    fun stopCapture() {
        isCapturing = false
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        mediaProjection?.stop()
        mediaProjection = null
    }

    override fun onBind(intent: Intent?): IBinder? = Binder()
}
