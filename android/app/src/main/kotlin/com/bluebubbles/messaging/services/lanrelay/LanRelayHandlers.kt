package com.bluebubbles.messaging.services.lanrelay

import android.content.Context
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class LanRelayNsdHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "lan-relay-nsd"
    }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        if (call.argument<Boolean>("enable") == true) {
            LanRelayNsd.register(context, call.argument<Int>("port")!!, call.argument<String>("name")!!, call.argument<String>("fp")!!)
        } else {
            LanRelayNsd.unregister(context)
        }
        result.success(null)
    }
}

class LanRelayChangedHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "lan-relay-changed"
    }

    override fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        LanRelayKeeper.kick(context)
        result.success(null)
    }
}
