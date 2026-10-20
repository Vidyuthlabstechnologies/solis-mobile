package com.solis.clinical.solis_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Microphone foreground service for a visit recording.
 *
 * Android stops microphone access for a backgrounded app unless a foreground
 * service of type "microphone" is running, so the recording keeps going when
 * the screen turns off or the clinician switches apps. The service shows an
 * ongoing notification ("SOLIS is recording this visit") with a Stop action,
 * and holds the partial wake lock for the length of the recording.
 *
 * It records nothing itself: capture stays in the Flutter engine. Stop asks
 * Flutter to stop (through [RecordingPlugin]); if no Flutter engine is
 * listening any more, the service ends itself.
 */
class RecordingService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Log.i(TAG, "Stop pressed in the notification")
            val listener = stopListener
            if (listener != null) {
                Handler(Looper.getMainLooper()).post { listener() }
            }
            shutDown()
            return START_NOT_STICKY
        }
        try {
            ensureChannel(this)
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
            acquireWakeLock()
        } catch (e: Exception) {
            // For example ForegroundServiceStartNotAllowedException or a
            // missing RECORD_AUDIO grant: recording still works while the
            // app is in the foreground.
            Log.w(TAG, "Could not start the recording foreground service: ${e.javaClass.simpleName}")
            shutDown()
        }
        // A recording is never resumed by the system after a process kill.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        running = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The app was swiped away: the Flutter recorder is gone with it.
        shutDown()
        super.onTaskRemoved(rootIntent)
    }

    private fun shutDown() {
        releaseWakeLock()
        running = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "SolisClinical::VisitRecording").apply {
            setReferenceCounted(false)
            acquire(WAKE_LOCK_CEILING_MS)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    private fun buildNotification(): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
            flags,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_recording)
            .setContentTitle("SOLIS is recording this visit")
            .setContentText("Tap to return to the visit.")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            builder.addAction(
                Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_stat_stop), "Stop", stop,
                ).build()
            )
        } else {
            @Suppress("DEPRECATION")
            builder.addAction(R.drawable.ic_stat_stop, "Stop", stop)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "SolisRecording"
        const val CHANNEL_ID = "visit_recording"
        const val NOTIFICATION_ID = 4107
        const val ACTION_START = "com.solis.clinical.recording.START"
        const val ACTION_STOP = "com.solis.clinical.recording.STOP"
        private const val WAKE_LOCK_CEILING_MS = 2 * 60 * 60 * 1000L

        /** Set by [RecordingPlugin]: asks Flutter to stop the recording. */
        @Volatile
        var stopListener: (() -> Unit)? = null

        @Volatile
        var running = false
            private set

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(CHANNEL_ID, "Visit recording", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while SOLIS records a visit."
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        /** Starts the service. False when the microphone permission is missing. */
        fun start(context: Context): Boolean {
            if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                return false
            }
            val intent = Intent(context, RecordingService::class.java).setAction(ACTION_START)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                Log.w(TAG, "startForegroundService failed: ${e.javaClass.simpleName}")
                false
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, RecordingService::class.java))
        }
    }
}
