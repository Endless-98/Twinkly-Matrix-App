package com.twinklywall.led_matrix_controller

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.provider.Settings
import android.util.DisplayMetrics
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val TAG = "TwinklyWall"
        private const val CHANNEL = "com.twinklywall.led_matrix_controller/screen_capture"
        private const val REQUEST_CODE = 100
    }

    private var captureService: ScreenCaptureService? = null
    private var serviceBound = false
    private var pendingStartResult: MethodChannel.Result? = null

    private var pendingResultCode: Int = 0
    private var pendingResultData: Intent? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            Log.d(TAG, "ServiceConnection.onServiceConnected")
            val localBinder = binder as ScreenCaptureService.LocalBinder
            captureService = localBinder.getService()
            serviceBound = true

            // The service already called startForeground + startCapture in onStartCommand.
            // Now we can report back to Flutter.
            if (captureService?.isCapturing == true) {
                Log.d(TAG, "Capture is active — reporting success to Flutter")
                pendingStartResult?.success(true)
            } else {
                // Service is running but capture didn't start — try starting it here
                Log.w(TAG, "Service bound but capture not active, attempting start...")
                val data = pendingResultData
                if (data != null && pendingResultCode == Activity.RESULT_OK) {
                    try {
                        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        val projection = manager.getMediaProjection(pendingResultCode, data)
                        if (projection != null) {
                            captureService?.startCapture(projection, this@MainActivity)
                            Log.d(TAG, "Capture started from onServiceConnected")
                            pendingStartResult?.success(true)
                        } else {
                            Log.e(TAG, "getMediaProjection returned null in onServiceConnected")
                            pendingStartResult?.error("PROJECTION_FAILED", "Failed to create MediaProjection", null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error in onServiceConnected capture start: ${e.message}", e)
                        pendingStartResult?.error("CAPTURE_ERROR", "Error: ${e.message}", null)
                    }
                } else {
                    Log.e(TAG, "No pending result data in onServiceConnected")
                    pendingStartResult?.error("NO_DATA", "No projection data available", null)
                }
            }
            pendingStartResult = null
            pendingResultData = null
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            Log.d(TAG, "ServiceConnection.onServiceDisconnected")
            captureService = null
            serviceBound = false
        }
    }

    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine")

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        // Allow OverlayService to notify Flutter when the X button is tapped
        OverlayService.onStopCastRequested = {
            methodChannel?.invokeMethod("stopCast", null)
        }

        methodChannel!!.setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel call: ${call.method}")
            when (call.method) {
                "startScreenCapture" -> {
                    val captureWidth = call.argument<Int>("width") ?: 90
                    val captureHeight = call.argument<Int>("height") ?: 50
                    Log.d(TAG, "startScreenCapture: ${captureWidth}x${captureHeight}")

                    if (captureService?.isCapturing == true) {
                        Log.d(TAG, "Already capturing, returning true")
                        result.success(true)
                    } else {
                        pendingStartResult = result
                        ScreenCaptureService.pendingCaptureWidth = captureWidth
                        ScreenCaptureService.pendingCaptureHeight = captureHeight
                        requestScreenCapture()
                    }
                }
                "stopScreenCapture" -> {
                    Log.d(TAG, "stopScreenCapture")
                    stopScreenCapture()
                    result.success(true)
                }
                "isCapturing" -> {
                    result.success(captureService?.isCapturing ?: false)
                }
                "captureScreenshot" -> {
                    val svc = captureService
                    if (svc == null) {
                        Log.w(TAG, "captureScreenshot: service is NULL (bound=$serviceBound)")
                        result.success(null)
                    } else {
                        val frame = svc.captureFrame()
                        if (frame != null) {
                            Log.d(TAG, "captureScreenshot: returning ${frame.size} bytes (native frames=${svc.nativeFrameCount})")
                        } else {
                            Log.d(TAG, "captureScreenshot: NULL (isCapturing=${svc.isCapturing}, nativeFrames=${svc.nativeFrameCount}, hasReader=${svc.hasImageReader}, hasDisplay=${svc.hasVirtualDisplay}, projectionStopped=${svc.projectionStopped})")
                        }
                        result.success(frame)
                    }
                }
                "captureDebugInfo" -> {
                    val svc = captureService
                    val info = mapOf(
                        "serviceBound" to serviceBound,
                        "serviceNull" to (svc == null),
                        "isCapturing" to (svc?.isCapturing ?: false),
                        "nativeFrameCount" to (svc?.nativeFrameCount ?: 0),
                        "hasImageReader" to (svc?.hasImageReader ?: false),
                        "hasVirtualDisplay" to (svc?.hasVirtualDisplay ?: false),
                        "hasLatestFrame" to (svc?.hasLatestFrame ?: false),
                        "projectionStopped" to (svc?.projectionStopped ?: false),
                        "listenerCallCount" to (svc?.listenerCallCount ?: 0),
                        "listenerErrorCount" to (svc?.listenerErrorCount ?: 0),
                        "lastListenerError" to (svc?.lastListenerError ?: ""),
                    )
                    Log.d(TAG, "captureDebugInfo: $info")
                    result.success(info)
                }
                "showOverlay" -> {
                    val cropLeft = (call.argument<Double>("cropLeft") ?: 0.1).toFloat()
                    val cropTop = (call.argument<Double>("cropTop") ?: 0.1).toFloat()
                    val cropWidth = (call.argument<Double>("cropWidth") ?: 0.8).toFloat()
                    val cropHeight = (call.argument<Double>("cropHeight") ?: 0.8).toFloat()
                    Log.d(TAG, "showOverlay: crop=$cropLeft,$cropTop ${cropWidth}x${cropHeight}")

                    if (!Settings.canDrawOverlays(this)) {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
                        startActivity(intent)
                        result.error("OVERLAY_PERMISSION", "Overlay permission required — please grant it and try again", null)
                        return@setMethodCallHandler
                    }

                    OverlayService.setCropState(cropLeft, cropTop, cropWidth, cropHeight)
                    val intent = Intent(this, OverlayService::class.java)
                    startService(intent)
                    result.success(true)
                }
                "hideOverlay" -> {
                    Log.d(TAG, "hideOverlay")
                    val intent = Intent(this, OverlayService::class.java)
                    intent.action = "STOP"
                    startService(intent)
                    result.success(true)
                }
                "getOverlayBubble" -> {
                    result.success(mapOf(
                        "cropLeft" to OverlayService.cropLeft.toDouble(),
                        "cropTop" to OverlayService.cropTop.toDouble(),
                        "cropWidth" to OverlayService.cropWidth.toDouble(),
                        "cropHeight" to OverlayService.cropHeight.toDouble(),
                        "active" to OverlayService.overlayActive,
                    ))
                }
                "canDrawOverlays" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestScreenCapture() {
        // On Android 14+ (API 34+), we must NOT start the foreground service before
        // having a valid MediaProjection token. So we ONLY request permission here.
        // The service will be started after the user grants permission.
        Log.d(TAG, "Requesting MediaProjection permission (API ${Build.VERSION.SDK_INT})")
        try {
            val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CODE)
            Log.d(TAG, "Permission dialog launched")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request capture permission: ${e.message}", e)
            pendingStartResult?.error("PERMISSION_ERROR", "Failed to request permission: ${e.message}", null)
            pendingStartResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        Log.d(TAG, "onActivityResult: requestCode=$requestCode, resultCode=$resultCode, hasData=${data != null}")

        if (requestCode != REQUEST_CODE) return

        if (resultCode != Activity.RESULT_OK || data == null) {
            Log.w(TAG, "User denied screen capture permission")
            pendingStartResult?.error("PERMISSION_DENIED", "User denied screen capture permission", null)
            pendingStartResult = null
            return
        }

        // User granted permission — store the result code + data for use AFTER startForeground
        Log.d(TAG, "Permission granted, starting foreground service first...")
        startAndBindService(resultCode, data)
    }

    private fun startAndBindService(resultCode: Int, data: Intent) {
        Log.d(TAG, "Starting foreground service (API ${Build.VERSION.SDK_INT})")
        try {
            // Store for onServiceConnected fallback
            pendingResultCode = resultCode
            pendingResultData = data

            // Pass resultCode + data to the service via static holders
            // The service will call startForeground() then getMediaProjection() in onStartCommand
            ScreenCaptureService.pendingResultCode = resultCode
            ScreenCaptureService.pendingResultData = data
            ScreenCaptureService.pendingActivity = this

            val serviceIntent = Intent(this, ScreenCaptureService::class.java)
            serviceIntent.putExtra("HAS_PROJECTION", true)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
            Log.d(TAG, "Service start requested")

            bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)
            Log.d(TAG, "Bind requested — will reply to Flutter in onServiceConnected")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting service: ${e.message}", e)
            pendingStartResult?.error("SERVICE_ERROR", "Failed to start service: ${e.message}", null)
            pendingStartResult = null
        }
    }

    private fun stopScreenCapture() {
        Log.d(TAG, "stopScreenCapture")
        try {
            captureService?.stopCapture()
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping capture: ${e.message}")
        }
        if (serviceBound) {
            try { unbindService(serviceConnection) } catch (_: Exception) {}
            serviceBound = false
        }
        captureService = null
        val serviceIntent = Intent(this, ScreenCaptureService::class.java)
        try { stopService(serviceIntent) } catch (_: Exception) {}
    }

    override fun onDestroy() {
        Log.d(TAG, "Activity onDestroy")
        stopScreenCapture()
        super.onDestroy()
    }
}

class ScreenCaptureService : Service() {
    companion object {
        private const val TAG = "TwinklyWall.Service"
        private const val NOTIFICATION_CHANNEL_ID = "screen_capture_channel"
        private const val NOTIFICATION_ID = 1001
        var pendingCaptureWidth: Int = 90
        var pendingCaptureHeight: Int = 50
        // Static holders for passing permission result from Activity to Service
        // The service will call getMediaProjection() AFTER startForeground()
        var pendingResultCode: Int = 0
        var pendingResultData: Intent? = null
        var pendingActivity: Activity? = null
    }

    inner class LocalBinder : Binder() {
        fun getService(): ScreenCaptureService = this@ScreenCaptureService
    }

    private val binder = LocalBinder()
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private var mediaProjection: MediaProjection? = null
    private var captureWidth = 90
    private var captureHeight = 50
    private var imageThread: HandlerThread? = null
    private var imageHandler: Handler? = null

    // Frame cache — listener writes, captureFrame() reads
    @Volatile private var latestFrameBytes: ByteArray? = null

    // Diagnostic counters (all public for debug info access)
    var nativeFrameCount = 0; private set
    var listenerCallCount = 0; private set
    var listenerErrorCount = 0; private set
    var lastListenerError: String = ""; private set
    var projectionStopped = false; private set
    val hasImageReader: Boolean get() = imageReader != null
    val hasVirtualDisplay: Boolean get() = virtualDisplay != null
    val hasLatestFrame: Boolean get() = latestFrameBytes != null

    private var projectionCallback: MediaProjection.Callback? = null

    var isCapturing = false
        private set

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "onStartCommand, hasProjection=${intent?.getBooleanExtra("HAS_PROJECTION", false)}")

        // Step 1: Start foreground FIRST — Android 14+ requires this before getMediaProjection()
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            Log.d(TAG, "startForeground succeeded")
        } catch (e: Exception) {
            Log.e(TAG, "startForeground FAILED: ${e.message}", e)
            stopSelf()
            return START_NOT_STICKY
        }

        // Step 2: NOW create the MediaProjection (must be after startForeground on API 34+)
        val resultData = pendingResultData
        val resultCode = pendingResultCode
        val activity = pendingActivity
        if (resultData != null && activity != null && resultCode == Activity.RESULT_OK) {
            Log.d(TAG, "Creating MediaProjection after startForeground...")
            try {
                val manager = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val projection = manager.getMediaProjection(resultCode, resultData)
                pendingResultData = null
                pendingActivity = null
                if (projection != null) {
                    Log.d(TAG, "MediaProjection created successfully")
                    startCapture(projection, activity)
                } else {
                    Log.e(TAG, "getMediaProjection returned null")
                }
            } catch (e: Exception) {
                Log.e(TAG, "getMediaProjection FAILED: ${e.message}", e)
            }
        } else {
            Log.w(TAG, "No pending projection data in onStartCommand (resultCode=$resultCode, hasData=${resultData != null})")
        }

        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder {
        Log.d(TAG, "onBind")
        return binder
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Screen Capture",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows when screen is being captured for LED wall"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
            Log.d(TAG, "Notification channel created")
        }
    }

    private fun buildNotification(): Notification {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("TwinklyWall")
                .setContentText("Casting screen to LED wall")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("TwinklyWall")
                .setContentText("Casting screen to LED wall")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        }
    }

    fun startCapture(projection: MediaProjection, context: Context) {
        Log.d(TAG, "startCapture called, width=${pendingCaptureWidth}, height=${pendingCaptureHeight}")
        try {
            stopCapture()

            mediaProjection = projection
            captureWidth = pendingCaptureWidth
            captureHeight = pendingCaptureHeight
            nativeFrameCount = 0
            listenerCallCount = 0
            listenerErrorCount = 0
            lastListenerError = ""
            projectionStopped = false

            val metrics: DisplayMetrics = context.resources.displayMetrics
            val density = metrics.densityDpi
            Log.d(TAG, "Display density=$density, screen=${metrics.widthPixels}x${metrics.heightPixels}")

            // Register a callback to detect if the projection is silently revoked
            projectionCallback = object : MediaProjection.Callback() {
                override fun onStop() {
                    Log.e(TAG, "!!! MediaProjection.Callback.onStop() — projection was REVOKED !!!")
                    projectionStopped = true
                    isCapturing = false
                }
            }

            // Background thread for ImageReader listener AND projection callback
            imageThread = HandlerThread("ScreenCaptureThread").also { it.start() }
            imageHandler = Handler(imageThread!!.looper)

            projection.registerCallback(projectionCallback!!, imageHandler)
            Log.d(TAG, "MediaProjection callback registered")

            imageReader = ImageReader.newInstance(captureWidth, captureHeight, PixelFormat.RGBA_8888, 5)
            Log.d(TAG, "ImageReader created: ${captureWidth}x${captureHeight}, surface=${imageReader?.surface}")

            // Set up listener — caches latest frame as RGB bytes whenever VirtualDisplay produces one
            imageReader!!.setOnImageAvailableListener({ reader ->
                listenerCallCount++
                if (listenerCallCount <= 5) {
                    Log.d(TAG, "OnImageAvailable fired #$listenerCallCount")
                }
                val image = try {
                    reader.acquireLatestImage()
                } catch (e: Exception) {
                    listenerErrorCount++
                    lastListenerError = "acquireLatestImage: ${e.message}"
                    Log.e(TAG, "acquireLatestImage exception: ${e.message}")
                    null
                }
                if (image == null) {
                    if (listenerCallCount <= 5) {
                        Log.w(TAG, "OnImageAvailable: acquireLatestImage returned null (call #$listenerCallCount)")
                    }
                    return@setOnImageAvailableListener
                }
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val pixelStride = plane.pixelStride
                    val rowStride = plane.rowStride

                    if (nativeFrameCount == 0) {
                        Log.d(TAG, "First frame metadata: planes=${image.planes.size}, pixelStride=$pixelStride, rowStride=$rowStride, bufferRemaining=${buffer.remaining()}, format=${image.format}, size=${image.width}x${image.height}")
                    }

                    val rowData = ByteArray(rowStride)
                    val out = ByteArray(captureWidth * captureHeight * 3)
                    var outOffset = 0

                    for (y in 0 until captureHeight) {
                        buffer.position(y * rowStride)
                        buffer.get(rowData, 0, rowStride)

                        var xOffset = 0
                        for (x in 0 until captureWidth) {
                            val r = rowData[xOffset].toInt() and 0xFF
                            val g = rowData[xOffset + 1].toInt() and 0xFF
                            val b = rowData[xOffset + 2].toInt() and 0xFF

                            out[outOffset++] = r.toByte()
                            out[outOffset++] = g.toByte()
                            out[outOffset++] = b.toByte()

                            xOffset += pixelStride
                        }
                    }

                    latestFrameBytes = out
                    nativeFrameCount++
                    if (nativeFrameCount <= 3 || nativeFrameCount % 100 == 0) {
                        Log.d(TAG, "Frame captured #$nativeFrameCount (${out.size} bytes)")
                    }
                } catch (e: Exception) {
                    listenerErrorCount++
                    lastListenerError = "process: ${e.message}"
                    Log.e(TAG, "Frame processing error: ${e.message}", e)
                } finally {
                    image.close()
                }
            }, imageHandler)

            Log.d(TAG, "OnImageAvailableListener registered on background handler")

            // Use flag 0 instead of VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR to support
            // both full-screen and single-app capture on Android 14+ (API 34+).
            // AUTO_MIRROR can cause blank frames in single-app capture mode.
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "LEDMatrixCapture",
                captureWidth,
                captureHeight,
                density,
                0,
                imageReader?.surface,
                null,
                null
            )
            Log.d(TAG, "VirtualDisplay created: ${virtualDisplay != null}, display=${virtualDisplay?.display}")

            isCapturing = true
            Log.d(TAG, "Capture STARTED: ${captureWidth}x${captureHeight} @ density=$density, isCapturing=$isCapturing")
        } catch (e: Exception) {
            Log.e(TAG, "startCapture FAILED: ${e.message}", e)
            isCapturing = false
        }
    }

    fun captureFrame(): ByteArray? {
        if (!isCapturing) {
            Log.w(TAG, "captureFrame: not capturing")
            return null
        }
        return latestFrameBytes
    }

    fun stopCapture() {
        Log.d(TAG, "stopCapture (native frames: $nativeFrameCount, listener calls: $listenerCallCount, errors: $listenerErrorCount)")
        isCapturing = false
        latestFrameBytes = null
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.setOnImageAvailableListener(null, null)
        imageReader?.close()
        imageReader = null
        if (projectionCallback != null) {
            mediaProjection?.unregisterCallback(projectionCallback!!)
            projectionCallback = null
        }
        mediaProjection?.stop()
        mediaProjection = null
        imageThread?.quitSafely()
        imageThread = null
        imageHandler = null
    }

    override fun onDestroy() {
        Log.d(TAG, "Service onDestroy")
        stopCapture()
        super.onDestroy()
    }
}
