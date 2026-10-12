package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class FaceTimeCallStateHandler: MethodCallHandlerImpl() {

    companion object {
        const val tag = "update-call-state"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val state = call.argument<String>("state")

        // "ringing" used to preload the FaceTime web client; calls are native now
        if (state == "ringing" && call.argument<Boolean>("outgoing") == true) {
            Ringback.start()
        } else if (state == "timeout") {
            Ringback.stop()
            // finish any still ringing activity
            FaceTimeActivity.activeFaceTimeActivity?.let {
                if (!it.answered && it.isCall) {
                    it.finishAndRemoveTask()
                }
            }
        }

        result.success(null)
    }

}

/** Soft ringback while an outgoing call rings; stopped on answer (FaceTimeActivity), decline, cancel or timeout. */
object Ringback {
    private var tone: ToneGenerator? = null
    private val handler = Handler(Looper.getMainLooper())
    private val safetyStop = Runnable { stop() }

    @Synchronized
    fun start() {
        if (tone != null) return
        tone = try {
            ToneGenerator(AudioManager.STREAM_MUSIC, 35).apply { startTone(ToneGenerator.TONE_SUP_RINGTONE) }
        } catch (e: RuntimeException) {
            null // no tone is better than a crashed call
        }
        // dart times outgoing calls out after 30s; never ring past that
        handler.postDelayed(safetyStop, 35_000)
    }

    @Synchronized
    fun stop() {
        handler.removeCallbacks(safetyStop)
        tone?.let { it.stopTone(); it.release() }
        tone = null
    }
}
