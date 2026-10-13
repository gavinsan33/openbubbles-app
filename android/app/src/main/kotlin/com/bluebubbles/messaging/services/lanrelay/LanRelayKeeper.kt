package com.bluebubbles.messaging.services.lanrelay

import android.content.Context
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// Keeps a Dart engine around while the LAN relay is enabled, so paired
/// computers can reach the phone even when the app UI is closed. Dart decides
/// which engine actually binds the port.
object LanRelayKeeper {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var loop: Job? = null

    private fun enabled(context: Context): Boolean =
        context.getSharedPreferences("FlutterSharedPreferences", 0).getBoolean("flutter.lanRelayEnabled", false)

    fun start(context: Context) {
        if (loop?.isActive == true) return
        val appContext = context.applicationContext
        loop = scope.launch {
            while (isActive) {
                tick(appContext)
                delay(30_000)
            }
        }
    }

    fun kick(context: Context) {
        val appContext = context.applicationContext
        scope.launch { tick(appContext) }
    }

    private suspend fun tick(context: Context) {
        val enabled = enabled(context)
        DartWorker.keepAlive = enabled
        if (!enabled) return
        try {
            withContext(Dispatchers.Main) {
                DartWorker.callMethod(context, "lan-relay-ensure", mapOf())
            }
        } catch (e: Exception) {
            Log.w(Constants.logTag, "LAN relay ensure failed: ${e.message}")
        }
    }
}
