package com.bluebubbles.messaging.services.lanrelay

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.bluebubbles.messaging.Constants

/// Advertises the LAN relay over mDNS so paired computers can find the phone
/// after its IP address changes
object LanRelayNsd {
    private var listener: NsdManager.RegistrationListener? = null

    @Synchronized
    fun register(context: Context, port: Int, name: String, fingerprint: String) {
        val manager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        unregister(context)
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = "_obrelay._tcp"
            setPort(port)
            setAttribute("fp", fingerprint)
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(Constants.logTag, "LAN relay advertised as ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(Constants.logTag, "LAN relay advertise failed: $errorCode")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        listener = l
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    @Synchronized
    fun unregister(context: Context) {
        val l = listener ?: return
        listener = null
        val manager = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        try {
            manager.unregisterService(l)
        } catch (e: IllegalArgumentException) {
            // already unregistered
        }
    }
}
