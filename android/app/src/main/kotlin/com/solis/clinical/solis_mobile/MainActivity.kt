package com.solis.clinical.solis_mobile

import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val SECURITY_CHANNEL = "com.solis.clinical/security"
    private var wakeLock: PowerManager.WakeLock? = null
    private val locationHelper by lazy { LocationHelper(this) }
    private var recordingPlugin: RecordingPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Screenshots are allowed by default; the practice can block them in
        // the provider profile, which calls setScreenshotsBlocked at startup.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        com.solis.clinical.solis_mobile.speech.NativeSpeechPlugin.register(this, flutterEngine)
        IntegrityPlugin(this).register(flutterEngine)
        recordingPlugin = RecordingPlugin(this).also { it.register(flutterEngine) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SECURITY_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableFlagSecure" -> {
                    window.setFlags(
                        WindowManager.LayoutParams.FLAG_SECURE,
                        WindowManager.LayoutParams.FLAG_SECURE
                    )
                    result.success(true)
                }
                "openUrl" -> {
                    // Opens an official https page (CMS transmittals) in the
                    // browser. Only https://www.cms.gov links are accepted.
                    val url = call.argument<String>("url") ?: ""
                    if (!url.startsWith("https://www.cms.gov/")) {
                        result.success(false)
                    } else {
                        try {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            intent.addCategory(android.content.Intent.CATEGORY_BROWSABLE)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: android.content.ActivityNotFoundException) {
                            result.success(false)
                        }
                    }
                }
                "setScreenshotsBlocked" -> {
                    val blocked = call.argument<Boolean>("blocked") ?: false
                    if (blocked) {
                        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(blocked)
                }
                "checkSecurityPosture" -> {
                    val isTampered = isDeviceRooted() || android.os.Debug.isDebuggerConnected()
                    result.success(mapOf(
                        "isRooted" to isDeviceRooted(),
                        "isDebuggerAttached" to android.os.Debug.isDebuggerConnected(),
                        "flagSecureActive" to ((window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) != 0),
                        "isTampered" to isTampered
                    ))
                }
                "acquireBackgroundWakeLock" -> {
                    try {
                        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                        if (wakeLock == null) {
                            wakeLock = powerManager.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK,
                                "SolisClinical::AmbientScribeWakeLock"
                            )
                        }
                        if (wakeLock?.isHeld == false) {
                            wakeLock?.acquire(60 * 60 * 1000L) // 1 hour safety ceiling
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERR", e.message, null)
                    }
                }
                "releaseBackgroundWakeLock" -> {
                    try {
                        if (wakeLock?.isHeld == true) {
                            wakeLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERR", e.message, null)
                    }
                }
                "getGpsCoordinates" -> {
                    // Real fix with a timeout; reports "unavailable" with a reason
                    // instead of a made-up location.
                    val timeout = (call.argument<Int>("timeoutMs") ?: 10000).toLong()
                    locationHelper.current(timeout) { fix -> result.success(fix) }
                }
                "requestAppPermissions" -> {
                    try {
                        val permissionsToRequest = mutableListOf<String>()
                        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            permissionsToRequest.add(android.Manifest.permission.RECORD_AUDIO)
                        }
                        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            permissionsToRequest.add(android.Manifest.permission.ACCESS_FINE_LOCATION)
                        }
                        if (checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                            permissionsToRequest.add(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                permissionsToRequest.add(android.Manifest.permission.POST_NOTIFICATIONS)
                            }
                        }
                        if (permissionsToRequest.isNotEmpty()) {
                            requestPermissions(permissionsToRequest.toTypedArray(), 101)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PERM_ERR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        recordingPlugin?.dispose()
        recordingPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (recordingPlugin?.onRequestPermissionsResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        super.onDestroy()
    }

    /**
     * Anti-Reverse Engineering & Root Detection
     * Protects clinical IP, cryptographic keys, and patient PHI from modified environments
     */
    private fun isDeviceRooted(): Boolean {
        val paths = arrayOf(
            "/system/app/Superuser.apk",
            "/sbin/su",
            "/system/bin/su",
            "/system/xbin/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/su",
            "/su/bin/su"
        )
        for (path in paths) {
            if (File(path).exists()) return true
        }
        val buildTags = Build.TAGS
        return buildTags != null && buildTags.contains("test-keys")
    }
}
