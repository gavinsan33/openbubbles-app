package com.bluebubbles.messaging.services.facetime

import android.content.Context
import android.content.Intent
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
        if (state == "timeout") {
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