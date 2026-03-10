package com.example.us

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object MorseNotificationService {

    private const val CHANNEL_ID = "us_morse_channel"
    private const val CHANNEL_NAME = "Messages"

    // Morse code timing (ms)
    private const val DOT = 100L
    private const val DASH = 300L
    private const val SYMBOL_GAP = 100L   // gap between dot/dash within a letter
    private const val LETTER_GAP = 300L   // gap between letters
    private const val WORD_GAP = 600L     // gap between words

    // Full Morse code alphabet
    private val morseAlphabet = mapOf(
        'A' to ".-",   'B' to "-...", 'C' to "-.-.", 'D' to "-..",
        'E' to ".",    'F' to "..-.", 'G' to "--.",  'H' to "....",
        'I' to "..",   'J' to ".---", 'K' to "-.-",  'L' to ".-..",
        'M' to "--",   'N' to "-.",   'O' to "---",  'P' to ".--.",
        'Q' to "--.-", 'R' to ".-.",  'S' to "...",  'T' to "-",
        'U' to "..-",  'V' to "...-", 'W' to ".--",  'X' to "-..-",
        'Y' to "-.--", 'Z' to "--..",
        '0' to "-----", '1' to ".----", '2' to "..---", '3' to "...--",
        '4' to "....-", '5' to ".....", '6' to "-....", '7' to "--...",
        '8' to "---..", '9' to "----."
    )

    fun init(context: Context) {
        createNotificationChannel(context)
    }

    private fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Secret morse code vibrations for new messages"
                enableVibration(false) // We handle vibration manually
            }
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    /**
     * Show a notification with NO message preview,
     * and vibrate the first word of the message in Morse code.
     */
    fun showMorseNotification(
        context: Context,
        senderName: String,
        messageText: String,
        notificationId: Int = System.currentTimeMillis().toInt()
    ) {
        // Extract first word only
        val firstWord = messageText.trim().split(" ").firstOrNull() ?: return

        // Build notification — no message preview shown
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setContentTitle(senderName)
            .setContentText("· · · — — — · · ·") // shows Morse dots/dashes, not real message
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setVibrate(null) // no default vibration
            .build()

        try {
            NotificationManagerCompat.from(context).notify(notificationId, notification)
        } catch (e: SecurityException) {
            // Notification permission not granted
        }

        // Vibrate first word in Morse on a background thread
        Thread {
            vibrateWord(context, firstWord)
        }.start()
    }

    private fun vibrateWord(context: Context, word: String) {
        val pattern = buildVibrationPattern(word)
        if (pattern.isEmpty()) return

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                val vibrator = vm.defaultVibrator
                vibrator.vibrate(VibrationEffect.createWaveform(pattern.toLongArray(), -1))
            } else {
                @Suppress("DEPRECATION")
                val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createWaveform(pattern.toLongArray(), -1))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(pattern.toLongArray(), -1)
                }
            }
        } catch (e: Exception) {
            // Vibrator not available
        }
    }

    /**
     * Convert a word into a vibration pattern array.
     * Pattern: [delay, vibrate, pause, vibrate, pause, ...]
     * First element is always a delay (0ms = start immediately).
     */
    private fun buildVibrationPattern(word: String): List<Long> {
        val pattern = mutableListOf<Long>()
        pattern.add(0L) // initial delay = 0

        val upperWord = word.uppercase()

        upperWord.forEachIndexed { letterIndex, char ->
            val morse = morseAlphabet[char] ?: return@forEachIndexed

            morse.forEachIndexed { symbolIndex, symbol ->
                // Vibrate
                pattern.add(if (symbol == '.') DOT else DASH)

                // Gap after each symbol (except last symbol of last letter)
                if (symbolIndex < morse.length - 1) {
                    pattern.add(SYMBOL_GAP) // gap between dots/dashes
                }
            }

            // Gap after each letter (except the last letter)
            if (letterIndex < upperWord.length - 1) {
                pattern.add(LETTER_GAP)
            }
        }

        return pattern
    }

    /**
     * Get the Morse code string for a word (for display purposes)
     */
    fun getMorseString(word: String): String {
        return word.uppercase().mapNotNull { morseAlphabet[it] }.joinToString(" ")
    }
}
