package com.solis.clinical.solis_mobile

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Real device location for the visit audit trail.
 *
 * Asks the platform for a fresh fix (GPS first, then network) with a timeout.
 * A cached fix is only used when it is recent and accurate. When no fix can be
 * had, the result says so, with the reason. It never substitutes a made-up
 * place: a fabricated location in a medical record is worse than none.
 */
class LocationHelper(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    fun current(timeoutMs: Long, callback: (Map<String, Any?>) -> Unit) {
        val lm = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (lm == null) {
            callback(unavailable("no_location_service"))
            return
        }
        val fine = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val coarse = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            callback(unavailable("permission_denied"))
            return
        }
        val enabled = lm.getProviders(true)
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER, LocationManager.FUSED_PROVIDER)
            .filter { enabled.contains(it) && (fine || it != LocationManager.GPS_PROVIDER) }
        if (providers.isEmpty()) {
            callback(unavailable("location_off"))
            return
        }

        // A recent, accurate cached fix answers immediately.
        val cached = providers.mapNotNull { p -> try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } }
            .filter { System.currentTimeMillis() - it.time < 2 * 60 * 1000 && it.accuracy <= 50f }
            .minByOrNull { it.accuracy }
        if (cached != null) {
            finish(cached, "cached", callback)
            return
        }

        val done = AtomicBoolean(false)
        val listeners = mutableListOf<LocationListener>()
        val cancels = mutableListOf<CancellationSignal>()
        var best: Location? = null

        fun complete(loc: Location?, reason: String) {
            if (!done.compareAndSet(false, true)) return
            listeners.forEach { try { lm.removeUpdates(it) } catch (_: Exception) {} }
            cancels.forEach { it.cancel() }
            if (loc != null) finish(loc, "fresh", callback) else main.post { callback(unavailable(reason)) }
        }

        main.postDelayed({
            // Timeout: use the best fix seen so far, or a stale cached one marked as such.
            val stale = providers.mapNotNull { p -> try { lm.getLastKnownLocation(p) } catch (_: SecurityException) { null } }
                .maxByOrNull { it.time }
            when {
                best != null -> complete(best, "timeout")
                stale != null -> if (done.compareAndSet(false, true)) {
                    listeners.forEach { try { lm.removeUpdates(it) } catch (_: Exception) {} }
                    cancels.forEach { it.cancel() }
                    finish(stale, "stale", callback)
                }
                else -> complete(null, "timeout")
            }
        }, timeoutMs)

        for (p in providers) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val signal = CancellationSignal()
                    cancels.add(signal)
                    lm.getCurrentLocation(p, signal, worker) { loc ->
                        if (loc != null) {
                            if (best == null || loc.accuracy < best!!.accuracy) best = loc
                            if (loc.accuracy <= 30f || p == LocationManager.GPS_PROVIDER) main.post { complete(loc, "fresh") }
                        }
                    }
                } else {
                    val listener = object : LocationListener {
                        override fun onLocationChanged(location: Location) {
                            if (best == null || location.accuracy < best!!.accuracy) best = location
                            if (location.accuracy <= 30f || p == LocationManager.GPS_PROVIDER) complete(location, "fresh")
                        }
                        @Deprecated("Deprecated in Java")
                        override fun onStatusChanged(provider: String?, status: Int, extras: android.os.Bundle?) {}
                        override fun onProviderEnabled(provider: String) {}
                        override fun onProviderDisabled(provider: String) {}
                    }
                    listeners.add(listener)
                    @Suppress("DEPRECATION")
                    lm.requestLocationUpdates(p, 0L, 0f, listener, Looper.getMainLooper())
                }
            } catch (_: SecurityException) {
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    /** Adds a street address when the platform geocoder can resolve one. */
    private fun finish(loc: Location, source: String, callback: (Map<String, Any?>) -> Unit) {
        worker.execute {
            val base = mutableMapOf<String, Any?>(
                "available" to true,
                "latitude" to loc.latitude,
                "longitude" to loc.longitude,
                "altitude" to if (loc.hasAltitude()) loc.altitude else null,
                "accuracy" to loc.accuracy.toDouble(),
                "timestamp" to loc.time,
                "provider" to loc.provider,
                "source" to source,
            )
            try {
                if (Geocoder.isPresent()) {
                    @Suppress("DEPRECATION")
                    val addresses: List<Address>? = Geocoder(context, Locale.getDefault()).getFromLocation(loc.latitude, loc.longitude, 1)
                    val a = addresses?.firstOrNull()
                    if (a != null) {
                        base["address"] = (0..a.maxAddressLineIndex).joinToString(", ") { a.getAddressLine(it) }
                        val street = listOfNotNull(a.subThoroughfare, a.thoroughfare).joinToString(" ").trim()
                        if (street.isNotEmpty()) base["street"] = street
                        base["locality"] = a.locality
                        base["adminArea"] = a.adminArea
                        base["postalCode"] = a.postalCode
                        base["countryCode"] = a.countryCode
                    }
                }
            } catch (_: Exception) {
                // Geocoding is best effort; coordinates stand on their own.
            }
            main.post { callback(base) }
        }
    }

    private fun unavailable(reason: String) = mapOf<String, Any?>("available" to false, "reason" to reason)
}
