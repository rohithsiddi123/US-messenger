package com.example.us

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import android.view.WindowManager
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity(), GestureRecognizerHelper.GestureListener {

    private val GESTURE_CHANNEL = "com.example.us/gesture"
    private val GESTURE_EVENT_CHANNEL = "com.example.us/gesture_events"
    private val SCREENSHOT_EVENT_CHANNEL = "com.example.us/screenshot_events"
    private val MORSE_CHANNEL = "com.example.us/morse"

    private var cameraExecutor: ExecutorService? = null
    private var gestureHelper: GestureRecognizerHelper? = null
    private var gestureEventSink: EventChannel.EventSink? = null
    private var screenshotEventSink: EventChannel.EventSink? = null
    private var isCameraRunning = false
    private var screenshotObserver: android.database.ContentObserver? = null
    private var isScreenshotListening = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Hide from recent apps + prevent screenshots leaking
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        // Init Morse notification channel
        MorseNotificationService.init(this)

        // Request notification permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        // ── Gesture MethodChannel ──────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GESTURE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startCamera" -> {
                        if (checkCameraPermission()) {
                            startCamera(); result.success(true)
                        } else {
                            requestCameraPermission()
                            result.error("PERMISSION", "Camera permission not granted", null)
                        }
                    }
                    "stopCamera" -> { stopCamera(); result.success(true) }
                    else -> result.notImplemented()
                }
            }

        // ── Gesture EventChannel ───────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, GESTURE_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    gestureEventSink = events
                }
                override fun onCancel(arguments: Any?) { gestureEventSink = null }
            })

        // ── Screenshot EventChannel ────────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCREENSHOT_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    screenshotEventSink = events
                    startScreenshotDetection()
                }
                override fun onCancel(arguments: Any?) {
                    screenshotEventSink = null
                    stopScreenshotDetection()
                }
            })

        // ── Morse MethodChannel ────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MORSE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showMorseNotification" -> {
                        val senderName = call.argument<String>("senderName") ?: "Someone"
                        val text = call.argument<String>("text") ?: ""
                        MorseNotificationService.showMorseNotification(
                            context = applicationContext,
                            senderName = senderName,
                            messageText = text
                        )
                        result.success(true)
                    }
                    "getMorseString" -> {
                        val word = call.argument<String>("word") ?: ""
                        result.success(MorseNotificationService.getMorseString(word))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Screenshot detection ───────────────────────────────────────────────

    private fun startScreenshotDetection() {
        if (isScreenshotListening) return
        isScreenshotListening = true
        screenshotObserver = object : android.database.ContentObserver(
            android.os.Handler(android.os.Looper.getMainLooper())
        ) {
            override fun onChange(selfChange: Boolean, uri: android.net.Uri?) {
                uri?.let {
                    val path = it.toString().lowercase()
                    if (path.contains("screenshot") || path.contains("capture")) {
                        runOnUiThread { screenshotEventSink?.success("screenshot_taken") }
                    }
                }
            }
        }
        contentResolver.registerContentObserver(
            android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            true, screenshotObserver!!
        )
    }

    private fun stopScreenshotDetection() {
        screenshotObserver?.let { contentResolver.unregisterContentObserver(it) }
        screenshotObserver = null
        isScreenshotListening = false
    }

    // ── Camera ─────────────────────────────────────────────────────────────

    private fun checkCameraPermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED

    private fun requestCameraPermission() =
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 100)

    private fun startCamera() {
        if (isCameraRunning) return
        isCameraRunning = true
        cameraExecutor = Executors.newSingleThreadExecutor()
        gestureHelper = GestureRecognizerHelper(this, this)

        ProcessCameraProvider.getInstance(this).addListener({
            val cameraProvider = ProcessCameraProvider.getInstance(this).get()
            val imageAnalysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
                .also {
                    it.setAnalyzer(cameraExecutor!!) { imageProxy ->
                        gestureHelper?.detectLiveStream(imageProxy, isFrontCamera = true)
                    }
                }
            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(
                    this as LifecycleOwner,
                    CameraSelector.Builder()
                        .requireLensFacing(CameraSelector.LENS_FACING_FRONT)
                        .build(),
                    imageAnalysis
                )
            } catch (e: Exception) {
                Log.e("MainActivity", "Camera error: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun stopCamera() {
        isCameraRunning = false
        ProcessCameraProvider.getInstance(this).addListener({
            ProcessCameraProvider.getInstance(this).get().unbindAll()
        }, ContextCompat.getMainExecutor(this))
        gestureHelper?.close()
        cameraExecutor?.shutdown()
        cameraExecutor = null
    }

    // ── Gesture callbacks ──────────────────────────────────────────────────

    override fun onGestureDetected(gesture: String, confidence: Float, landmarks: List<List<FloatArray>>) {
        runOnUiThread {
            val flatLandmarks = landmarks.map { hand ->
                hand.map { lm -> mapOf("x" to lm[0], "y" to lm[1], "z" to lm[2]) }
            }
            gestureEventSink?.success(mapOf(
                "gesture" to gesture,
                "confidence" to confidence,
                "landmarks" to flatLandmarks
            ))
        }
    }

    override fun onError(error: String) {
        runOnUiThread { gestureEventSink?.error("GESTURE_ERROR", error, null) }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCamera()
        stopScreenshotDetection()
    }
}