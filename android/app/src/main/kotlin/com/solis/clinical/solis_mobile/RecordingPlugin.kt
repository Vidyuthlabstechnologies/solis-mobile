package com.solis.clinical.solis_mobile

import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Channel com.solis.clinical/recording: starts and stops [RecordingService]
 * and asks for the notification permission (Android 13+) before the first
 * recording. Calls "stopRequested" on Flutter when Stop is pressed in the
 * notification.
 */
class RecordingPlugin(private val activity: Activity) {
    private var channel: MethodChannel? = null
    private var pendingPermission: MethodChannel.Result? = null

    fun register(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        RecordingService.stopListener = { ch.invokeMethod("stopRequested", null) }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(RecordingService.start(activity.applicationContext))
                "stop" -> {
                    RecordingService.stop(activity.applicationContext)
                    result.success(true)
                }
                "isRunning" -> result.success(RecordingService.running)
                "notificationsAllowed" -> result.success(notificationsAllowed())
                "requestNotificationPermission" -> requestNotificationPermission(result)
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        RecordingService.stopListener = null
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPermission?.success(notificationsAllowed())
        pendingPermission = null
    }

    private fun notificationsAllowed(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    /**
     * Asks once per install (Android shows the dialog at most twice anyway).
     * Answers true when allowed, false when denied; recording works either way.
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (notificationsAllowed()) {
            result.success(true)
            return
        }
        val prefs = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
        if (prefs.getBoolean(KEY_ASKED, false) || pendingPermission != null) {
            result.success(false)
            return
        }
        prefs.edit().putBoolean(KEY_ASKED, true).apply()
        pendingPermission = result
        activity.requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE)
    }

    /** Forwarded from MainActivity.onRequestPermissionsResult. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
        return true
    }

    companion object {
        const val CHANNEL = "com.solis.clinical/recording"
        private const val REQUEST_CODE = 4108
        private const val PREFS = "solis_recording"
        private const val KEY_ASKED = "asked_post_notifications"
    }
}
