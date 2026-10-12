package com.bluebubbles.messaging.services.facetime

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import androidx.core.view.WindowCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.databinding.ActivityFaceTimeBinding
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.notifications.DeleteNotificationHandler
import com.bluebubbles.messaging.services.rustpush.APNClient
import com.bluebubbles.messaging.services.rustpush.APNService
import kotlin.concurrent.thread

class FaceTimeActivity : Activity() {
    private lateinit var binding: ActivityFaceTimeBinding

    var isCall = false
    var answered = false
    private var notificationId = 0
    var callUuid: String? = null

    private var media: FaceTimeMedia? = null
    private var ended = false

    companion object {
        var activeFaceTimeActivity: FaceTimeActivity? = null
        private val callPermissions = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
    }

    fun endCall() {
        if (ended) return
        ended = true
        media?.call?.leave()
        finishAndRemoveTask()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        val visibility = if (isInPictureInPictureMode) View.GONE else View.VISIBLE
        binding.callControls.visibility = visibility
        binding.localVideo.visibility = visibility
    }

    private fun decline() {
        if (notificationId != 0) {
            DeleteNotificationHandler().deleteNotification(this, notificationId, Constants.newFaceTimeNotificationTag)
        }
        callUuid?.let { callUuid ->
            val client = APNClient(applicationContext)
            client.bind { service: APNService ->
                try {
                    service.pushState?.declineFacetime(callUuid)
                } finally {
                    client.destroy()
                }
            }
        }
        finishAndRemoveTask()
    }

    private fun answerCall() {
        answered = true
        if (notificationId != 0) {
            DeleteNotificationHandler().deleteNotification(this, notificationId, Constants.newFaceTimeNotificationTag)
        }
        binding.mainFrame.visibility = View.VISIBLE
        binding.splashLayout.visibility = View.GONE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            window.setBackgroundBlurRadius(0)
        }
        binding.callStatus.text = "Connecting..."

        if (callPermissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) {
            startMedia()
        } else {
            requestPermissions(callPermissions, 1)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (requestCode != 1) return
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            startMedia()
        } else {
            binding.callStatus.text = "Camera and microphone access are needed for FaceTime"
        }
    }

    private fun whenTextureReady(view: TextureView, cb: () -> Unit) {
        if (view.isAvailable) return cb()
        view.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) = cb()
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture) = true
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }
    }

    private fun startMedia() {
        if (media != null) return
        startService()
        // decoders and the camera preview need their surfaces before rust starts sending
        whenTextureReady(binding.remoteVideo) {
            whenTextureReady(binding.localVideo) {
                val guid = callUuid ?: return@whenTextureReady
                val m = FaceTimeMedia(this, binding.remoteVideo, binding.localVideo, ::displayRotationDegrees) { endCall() }
                media = m
                val client = APNClient(applicationContext)
                client.bind { service: APNService ->
                    thread(name = "FaceTimeStart") {
                        // blocks while joining the call
                        val call = service.pushState?.startFacetime(guid, m)
                        client.destroy()
                        runOnUiThread {
                            if (ended) {
                                call?.leave()
                                return@runOnUiThread
                            }
                            if (call == null) {
                                binding.callStatus.text = "Couldn't connect"
                                binding.root.postDelayed({ endCall() }, 2000)
                                return@runOnUiThread
                            }
                            binding.callStatus.text = ""
                            m.call = call
                            m.onAudioRouteChanged = { binding.speakerButton.text = it.label }
                            m.startAudio()
                        }
                    }
                }
            }
        }
    }

    private fun displayRotationDegrees(): Int {
        @Suppress("DEPRECATION")
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display?.rotation else windowManager.defaultDisplay.rotation
        return when (rotation) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    private fun setupControls() {
        // rotating, folding and unfolding all resize the preview without recreating us
        binding.localVideo.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> media?.fitLocalPreview() }

        binding.endButton.setOnClickListener { endCall() }
        binding.muteButton.setOnClickListener {
            val m = media ?: return@setOnClickListener
            m.micMuted = !m.micMuted
            binding.muteButton.text = if (m.micMuted) "Unmute" else "Mute"
        }
        binding.cameraButton.setOnClickListener {
            val m = media ?: return@setOnClickListener
            m.cameraOff = !m.cameraOff
            binding.cameraButton.text = if (m.cameraOff) "Cam on" else "Cam off"
            binding.localVideo.visibility = if (m.cameraOff) View.INVISIBLE else View.VISIBLE
        }
        binding.flipButton.setOnClickListener { media?.flipCamera() }
        // cycles Bluetooth / headset / speaker / earpiece, whichever are connected
        binding.speakerButton.setOnClickListener { media?.nextAudioRoute() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFaceTimeBinding.inflate(layoutInflater)

        activeFaceTimeActivity = this

        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // show when locked
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        binding.accept.setOnClickListener { answerCall() }
        binding.reject.setOnClickListener { decline() }
        setupControls()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val endIntent = Intent(this, FaceTimeActionReceiver::class.java)
            setPictureInPictureParams(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(2, 3))
                    .setActions(listOf(
                        RemoteAction(
                            Icon.createWithResource(this, R.drawable.call_end),
                            "End Call",
                            "End this FaceTime Call",
                            PendingIntent.getBroadcast(this, 1, endIntent, PendingIntent.FLAG_IMMUTABLE)
                        )
                    ))
                    .setAutoEnterEnabled(true)
                    .build())

            binding.remoteVideo.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                val sourceRectHint = Rect()
                v.getGlobalVisibleRect(sourceRectHint)
                setPictureInPictureParams(PictureInPictureParams.Builder().setSourceRectHint(sourceRectHint).build())
            }
        }

        setContentView(binding.root)
        handleConfig(intent.extras!!)
    }

    private var serviceStarted: Boolean = false

    private fun startService() {
        if (serviceStarted) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(Intent(this, FaceTimeInCallService::class.java))
        }
        serviceStarted = true
    }

    override fun onDestroy() {
        activeFaceTimeActivity = null
        if (!ended) {
            ended = true
            media?.call?.leave()
        }
        media?.release()
        media = null

        stopService(Intent(this, FaceTimeInCallService::class.java))
        serviceStarted = false
        super.onDestroy()
    }

    private fun handleConfig(extras: Bundle) {
        // sanitize desc
        val desc = extras.getString("desc")?.replace("[^a-zA-Z0-9, +.@:&]+".toRegex(), "") ?: "FaceTime Call"
        val isAnsweringCall = extras.containsKey("answer")
        notificationId = extras.getString("notificationId")?.toInt() ?: 0
        callUuid = extras.getString("callUuid")

        if (CreateIncomingFaceTimeNotification.avatarCache.containsKey(callUuid)) {
            val bitmap = CreateIncomingFaceTimeNotification.avatarCache.remove(callUuid)!!
            binding.avatarView.setImageBitmap(bitmap)
        }

        Log.i("FaceTime", "started activity for call $callUuid")

        val poster = extras.getString("poster")
        if (poster != null) {
            binding.posterView.setImageBitmap(BitmapFactory.decodeFile(poster))
            binding.callDescription.visibility = View.GONE
            // no background blur because we are occluded
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                window.setBackgroundBlurRadius(0)
            }
        } else {
            binding.posterView.visibility = View.GONE
        }

        if (isAnsweringCall) {
            isCall = true
            binding.callTitle.text = desc
            binding.splashLayout.visibility = View.VISIBLE
            if (extras.getBoolean("answer")) {
                answerCall()
            }
        } else {
            // joining a call that's already going
            answerCall()
        }
    }
}
