package com.example.us

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.util.Log
import androidx.camera.core.ImageProxy
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizer
import com.google.mediapipe.tasks.vision.gesturerecognizer.GestureRecognizerResult

class GestureRecognizerHelper(
    private val context: Context,
    private val listener: GestureListener
) {
    private var gestureRecognizer: GestureRecognizer? = null

    interface GestureListener {
        fun onGestureDetected(gesture: String, confidence: Float, landmarks: List<List<FloatArray>>)
        fun onError(error: String)
    }

    init {
        setupGestureRecognizer()
    }

    private fun setupGestureRecognizer() {
        try {
            val baseOptions = BaseOptions.builder()
                .setDelegate(Delegate.CPU)
                .setModelAssetPath("gesture_recognizer.task")
                .build()

            val options = GestureRecognizer.GestureRecognizerOptions.builder()
                .setBaseOptions(baseOptions)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .setNumHands(1)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setResultListener { result, _ -> processResult(result) }
                .setErrorListener { error -> listener.onError(error.message ?: "Unknown error") }
                .build()

            gestureRecognizer = GestureRecognizer.createFromOptions(context, options)
            Log.d("GestureHelper", "GestureRecognizer initialized successfully")
        } catch (e: Exception) {
            Log.e("GestureHelper", "Error initializing GestureRecognizer: ${e.message}")
            listener.onError("Init error: ${e.message}")
        }
    }

    private fun processResult(result: GestureRecognizerResult) {
        if (result.gestures().isEmpty()) return

        val gesture = result.gestures()[0]
        if (gesture.isEmpty()) return

        val topGesture = gesture[0]
        val gestureName = topGesture.categoryName()
        val confidence = topGesture.score()

        // Extract landmarks for drawing skeleton
        val landmarksList = mutableListOf<List<FloatArray>>()
        result.landmarks().forEach { handLandmarks ->
            val hand = handLandmarks.map { lm ->
                floatArrayOf(lm.x(), lm.y(), lm.z())
            }
            landmarksList.add(hand)
        }

        listener.onGestureDetected(gestureName, confidence, landmarksList)
    }

    fun detectLiveStream(imageProxy: ImageProxy, isFrontCamera: Boolean) {
        val bitmap = imageProxy.toBitmap()
        val rotatedBitmap = rotateBitmap(bitmap, imageProxy.imageInfo.rotationDegrees.toFloat(), isFrontCamera)
        val mpImage = BitmapImageBuilder(rotatedBitmap).build()

        try {
            gestureRecognizer?.recognizeAsync(mpImage, System.currentTimeMillis())
        } catch (e: Exception) {
            Log.e("GestureHelper", "Detection error: ${e.message}")
        } finally {
            imageProxy.close()
        }
    }

    private fun rotateBitmap(bitmap: Bitmap, rotationDegrees: Float, isFrontCamera: Boolean): Bitmap {
        val matrix = Matrix()
        matrix.postRotate(rotationDegrees)
        if (isFrontCamera) {
            matrix.postScale(-1f, 1f, bitmap.width / 2f, bitmap.height / 2f)
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    fun close() {
        gestureRecognizer?.close()
        gestureRecognizer = null
    }
}