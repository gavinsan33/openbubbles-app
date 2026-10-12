package com.bluebubbles.messaging.services.facetime

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.view.OrientationEventListener
import android.view.Surface
import android.view.TextureView
import uniffi.rust_lib_bluebubbles.FtCall
import uniffi.rust_lib_bluebubbles.FtMediaSink
import uniffi.rust_lib_bluebubbles.FtVideoCodec
import java.nio.ByteBuffer
import java.util.ArrayDeque
import kotlin.concurrent.thread

private const val TAG = "FaceTimeMedia"

// must match rust ft_media: AAC-ELD 24kHz mono, 480 sample frames
private const val AUDIO_RATE = 24000
private const val AUDIO_FRAME_BYTES = 480 * 2

// camera buffers are landscape; orientation travels as per-frame metadata.
// The camera picks the closest 16:9 size it supports at or below this.
private const val VIDEO_MAX_WIDTH = 1280
private const val VIDEO_INITIAL_BITRATE = 1_000_000
// rustpush's rate control keeps climbing (seen 8.5Mbps); past ~2.5Mbps 720p HEVC gains nothing
// and the receiver starts freezing on lost packets
private const val VIDEO_MAX_BITRATE = 2_500_000

/**
 * Native FaceTime media for one call. Rust (FtCall) owns the protocol; this owns the
 * camera, the HEVC encoder, remote video decoding and the audio devices.
 */
class FaceTimeMedia(
    private val context: Context,
    private val remoteView: TextureView,
    private val localView: TextureView,
    // clockwise degrees the UI is rotated from the display's natural orientation
    private val displayRotation: () -> Int,
    // foldables: the inner screen is in use (picks which front camera to default to)
    private val isUnfolded: () -> Boolean,
    private val onEnded: () -> Unit,
) : FtMediaSink {
    var call: FtCall? = null
        set(value) { field = value; value?.let { startEncoder() } }

    @Volatile var micMuted = false
    @Volatile var cameraOff = false
        set(value) {
            field = value
            call?.setVideoEnabled(!value)
            if (value) stopCamera() else openCamera()
        }
    // foldables have several front cameras (cover and inner screen), so flip cycles through all of them
    private val cameraIds: List<String> by lazy {
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        manager.cameraIdList.sortedBy {
            if (manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT) 0 else 1
        }.also { ids ->
            ids.forEach {
                val c = manager.getCameraCharacteristics(it)
                Log.i(TAG, "camera $it facing ${c.get(CameraCharacteristics.LENS_FACING)} sensor ${c.get(CameraCharacteristics.SENSOR_ORIENTATION)}")
            }
        }
    }
    private var cameraIndex = -1 // pick a default for the current fold state when the camera opens

    private val prefs get() = context.getSharedPreferences("facetime", Context.MODE_PRIVATE)
    private fun postureKey() = if (isUnfolded()) "camera_unfolded" else "camera_folded"

    // the camera last flipped to in this fold state, else the first front camera folded and the
    // second (usually the inner screen's) unfolded
    private fun defaultCameraIndex(): Int {
        prefs.getString(postureKey(), null)?.let { saved -> cameraIds.indexOf(saved).takeIf { it >= 0 }?.let { return it } }
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val fronts = cameraIds.filter { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT }
        val pick = fronts.getOrNull(if (isUnfolded() && fronts.size > 1) 1 else 0) ?: return 0
        return cameraIds.indexOf(pick)
    }

    /** Fold state changed mid-call: move to that posture's camera. */
    fun postureChanged() {
        handler.post {
            cameraIndex = defaultCameraIndex()
            stopCamera()
            if (!cameraOff) openCamera()
        }
    }
    var frontCamera = true
        private set
    private var videoWidth = 1280
    private var videoHeight = 720

    private val worker = HandlerThread("FaceTimeMedia").apply { start() }
    private val handler = Handler(worker.looper)

    // device orientation, clockwise degrees the phone is turned
    @Volatile private var deviceRotation = 0
    private val orientationListener = object : OrientationEventListener(context) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation == ORIENTATION_UNKNOWN) return
            deviceRotation = ((orientation + 45) / 90 * 90) % 360
        }
    }

    // ---- outgoing video ----
    private var encoder: MediaCodec? = null
    private var encoderSurface: Surface? = null
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var sensorOrientation = 0

    private fun startEncoder() {
        handler.post {
            orientationListener.enable()
            openCamera()
        }
    }

    // runs on handler thread; (re)creates the encoder when the camera's size changes
    private fun ensureEncoder(width: Int, height: Int) {
        if (encoder != null && width == videoWidth && height == videoHeight) return
        encoder?.let { runCatching { it.stop() }; it.release() }
        encoderSurface?.release()
        encoder = null
        videoWidth = width
        videoHeight = height
        run {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, VIDEO_INITIAL_BITRATE)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LATENCY, 1)
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            codec.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}
                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    val buf = codec.getOutputBuffer(index)
                    if (buf != null && info.size > 0) {
                        val data = ByteArray(info.size)
                        buf.position(info.offset)
                        buf.get(data)
                        val call = call
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            call?.setVideoConfig(data, width.toUInt(), height.toUInt())
                        } else if (!cameraOff) {
                            val key = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                            call?.sendVideo(data, key, info.presentationTimeUs.toULong(), outgoingRotation(), false, !frontCamera)
                        }
                    }
                    codec.releaseOutputBuffer(index, false)
                }
                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) { Log.e(TAG, "encoder error", e) }
                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {}
            }, handler)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoderSurface = codec.createInputSurface()
            codec.start()
            encoder = codec
            Log.i(TAG, "encoder ${width}x$height")
        }
    }

    // clockwise degrees the receiver must rotate our frames to be upright
    private fun outgoingRotation(): Int =
        if (frontCamera) (sensorOrientation + deviceRotation) % 360
        else (sensorOrientation - deviceRotation + 360) % 360

    fun flipCamera() {
        handler.post {
            cameraIndex = (cameraIndex + 1) % maxOf(cameraIds.size, 1)
            cameraIds.getOrNull(cameraIndex)?.let { prefs.edit().putString(postureKey(), it).apply() }
            stopCamera()
            if (!cameraOff) openCamera()
        }
    }

    @SuppressLint("MissingPermission") // granted before the call starts
    private fun openCamera() {
        handler.post {
            if (camera != null || cameraOff) return@post
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            if (cameraIndex < 0) cameraIndex = defaultCameraIndex()
            val id = cameraIds.getOrNull(cameraIndex) ?: return@post
            val chars = manager.getCameraCharacteristics(id)
            frontCamera = chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            // a size the camera really outputs, so nothing gets squashed into 16:9
            val sizes = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(SurfaceTexture::class.java).orEmpty()
            val size = sizes.filter { it.width <= VIDEO_MAX_WIDTH && it.width * 9 == it.height * 16 }.maxByOrNull { it.width }
                ?: sizes.filter { it.width <= VIDEO_MAX_WIDTH }.maxByOrNull { it.width * it.height }
            ensureEncoder(size?.width ?: 1280, size?.height ?: 720)
            Log.i(TAG, "opening camera $id front=$frontCamera sensor=$sensorOrientation size=${videoWidth}x$videoHeight")
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    camera = device
                    startCapture(device)
                }
                override fun onDisconnected(device: CameraDevice) { device.close(); camera = null }
                override fun onError(device: CameraDevice, error: Int) {
                    Log.e(TAG, "camera error $error")
                    device.close(); camera = null
                }
            }, handler)
        }
    }

    private fun startCapture(device: CameraDevice) {
        val targets = mutableListOf(encoderSurface!!)
        localView.surfaceTexture?.let {
            it.setDefaultBufferSize(videoWidth, videoHeight)
            targets.add(Surface(it))
        }
        localView.post { fitLocalPreview() }
        @Suppress("DEPRECATION")
        device.createCaptureSession(targets, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(s: CameraCaptureSession) {
                session = s
                val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    targets.forEach { addTarget(it) }
                    set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(15, 30))
                }.build()
                s.setRepeatingRequest(request, null, handler)
                requestKeyframe()
            }
            override fun onConfigureFailed(s: CameraCaptureSession) { Log.e(TAG, "capture session failed") }
        }, handler)
    }

    // camera2 already rotates (and mirrors, for front) preview buffers to the display's natural
    // orientation, so only the UI rotation is left to undo
    fun fitLocalPreview() {
        val (w, h) = if (sensorOrientation % 180 == 0) Pair(videoWidth, videoHeight) else Pair(videoHeight, videoWidth)
        fitTexture(localView, w, h, (360 - displayRotation()) % 360, false)
    }

    private fun stopCamera() {
        handler.post {
            session?.close(); session = null
            camera?.close(); camera = null
        }
    }

    // ---- incoming video ----
    private class DecoderState(val codec: MediaCodec, val mime: String, val csd: ByteArray) {
        val frames = ArrayDeque<Pair<ByteArray, Long>>()
        val inputs = ArrayDeque<Int>()
    }
    private var decoder: DecoderState? = null
    private var decodedSize = Pair(0, 0)
    private var remoteRotation = -1
    private var remoteMirrored = false

    override fun videoConfig(participant: ULong, codec: FtVideoCodec, csd: ByteArray, width: Int, height: Int) {
        handler.post {
            val mime = if (codec == FtVideoCodec.H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
            val current = decoder
            if (current != null && current.mime == mime && current.csd.contentEquals(csd)) return@post
            current?.codec?.let { runCatching { it.stop(); it.release() } }
            decoder = null
            val texture = remoteView.surfaceTexture ?: return@post
            val format = MediaFormat.createVideoFormat(mime, maxOf(width, 16), maxOf(height, 16))
            if (codec == FtVideoCodec.H264) {
                // AVC wants SPS and PPS split
                val nals = splitAnnexB(csd)
                nals.getOrNull(0)?.let { format.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
                nals.getOrNull(1)?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
            } else {
                format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
            }
            val mc = MediaCodec.createDecoderByType(mime)
            val state = DecoderState(mc, mime, csd)
            mc.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                    state.inputs.add(index)
                    feed(state)
                }
                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    codec.releaseOutputBuffer(index, true)
                }
                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    Log.e(TAG, "decoder error", e)
                }
                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    decodedSize = Pair(format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
                    fitRemote()
                }
            }, handler)
            mc.configure(format, Surface(texture), null, 0)
            mc.start()
            decoder = state
            Log.i(TAG, "decoder $mime ${width}x$height")
        }
    }

    override fun videoFrame(participant: ULong, data: ByteArray, timestampUs: ULong, rotation: Int, mirrored: Boolean) {
        handler.post {
            val state = decoder ?: return@post
            if (state.frames.size > 30) state.frames.clear() // fell behind, wait for a fresh run
            state.frames.add(Pair(data, timestampUs.toLong()))
            feed(state)
            if (rotation != remoteRotation || mirrored != remoteMirrored) {
                Log.i(TAG, "remote rotation $rotation mirrored $mirrored")
                remoteRotation = rotation
                remoteMirrored = mirrored
                fitRemote()
            }
        }
    }

    // runs on handler thread
    private fun feed(state: DecoderState) {
        while (state.frames.isNotEmpty() && state.inputs.isNotEmpty()) {
            val (data, ts) = state.frames.poll()!!
            val index = state.inputs.poll()!!
            try {
                val buf = state.codec.getInputBuffer(index) ?: continue
                buf.clear()
                buf.put(data, 0, minOf(data.size, buf.capacity()))
                state.codec.queueInputBuffer(index, 0, minOf(data.size, buf.capacity()), ts, 0)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "decoder gone", e)
                return
            }
        }
    }

    /** Center-crop the remote video to fill the view; also called when the view resizes (unfolding). */
    fun fitRemote() {
        val (w, h) = decodedSize
        if (w == 0) return
        val rotation = maxOf(remoteRotation, 0)
        val mirrored = remoteMirrored
        remoteView.post { fitTexture(remoteView, w, h, rotation, mirrored) }
    }

    // ---- audio ----
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    @Volatile private var audioRunning = false

    enum class AudioRoute(val label: String) { BLUETOOTH("Bluetooth"), WIRED("Headset"), SPEAKER("Speaker"), EARPIECE("Earpiece") }

    var audioRoute = AudioRoute.SPEAKER
        private set
    var onAudioRouteChanged: (AudioRoute) -> Unit = {}

    private val audioManager get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun routeOf(type: Int): AudioRoute? = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_HEARING_AID -> AudioRoute.BLUETOOTH
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET -> AudioRoute.WIRED
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> AudioRoute.SPEAKER
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> AudioRoute.EARPIECE
        else -> null
    }

    private fun devicesFor(route: AudioRoute): List<AudioDeviceInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audioManager.availableCommunicationDevices.filter { routeOf(it.type) == route }
        else audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).filter { routeOf(it.type) == route }

    fun availableRoutes(): List<AudioRoute> = AudioRoute.values().filter { devicesFor(it).isNotEmpty() }

    fun setAudioRoute(route: AudioRoute) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val device = devicesFor(route).firstOrNull() ?: return
            if (!audioManager.setCommunicationDevice(device)) return
        } else {
            @Suppress("DEPRECATION")
            when (route) {
                AudioRoute.BLUETOOTH -> { audioManager.isSpeakerphoneOn = false; audioManager.startBluetoothSco(); audioManager.isBluetoothScoOn = true }
                else -> {
                    audioManager.isBluetoothScoOn = false; audioManager.stopBluetoothSco()
                    audioManager.isSpeakerphoneOn = route == AudioRoute.SPEAKER
                }
            }
        }
        audioRoute = route
        Log.i(TAG, "audio route $route")
        remoteView.post { onAudioRouteChanged(route) }
    }

    fun nextAudioRoute() {
        val routes = availableRoutes()
        if (routes.isEmpty()) return
        setAudioRoute(routes[(routes.indexOf(audioRoute) + 1) % routes.size])
    }

    // a headset connecting mid-call takes over; losing the active device falls back to the speaker
    private val deviceCallback = object : android.media.AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
            added.mapNotNull { routeOf(it.type) }.firstOrNull { it == AudioRoute.BLUETOOTH || it == AudioRoute.WIRED }
                ?.let { handler.postDelayed({ setAudioRoute(it) }, 500) } // let it register as a call device
        }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
            if (removed.any { routeOf(it.type) == audioRoute }) {
                handler.postDelayed({ setAudioRoute(availableRoutes().firstOrNull { it == AudioRoute.BLUETOOTH || it == AudioRoute.WIRED } ?: AudioRoute.SPEAKER) }, 500)
            }
        }
    }

    @SuppressLint("MissingPermission")
    fun startAudio() {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        val routes = availableRoutes()
        setAudioRoute(routes.firstOrNull { it == AudioRoute.BLUETOOTH || it == AudioRoute.WIRED } ?: AudioRoute.SPEAKER)
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)

        val minRec = AudioRecord.getMinBufferSize(AUDIO_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, AUDIO_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(minRec, AUDIO_FRAME_BYTES * 4))
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId)?.enabled = true
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.enabled = true
        record = rec

        val minPlay = AudioTrack.getMinBufferSize(AUDIO_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(AUDIO_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(maxOf(minPlay, AUDIO_FRAME_BYTES * 8))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .apply { play() }

        audioRunning = true
        rec.startRecording()
        thread(name = "FaceTimeMic") {
            val frame = ByteArray(AUDIO_FRAME_BYTES)
            while (audioRunning) {
                var read = 0
                while (read < frame.size && audioRunning) {
                    val n = rec.read(frame, read, frame.size - read)
                    if (n <= 0) break
                    read += n
                }
                if (read == frame.size && !micMuted) call?.sendAudio(frame.copyOf())
            }
        }
    }

    override fun audioFrame(participant: ULong, pcm: ByteArray) {
        // called on rust's audio thread, never block it
        track?.write(pcm, 0, pcm.size, AudioTrack.WRITE_NON_BLOCKING)
    }

    // ---- control from rust ----
    override fun requestKeyframe() {
        handler.post {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        }
    }

    override fun setBitrate(bps: ULong) {
        handler.post {
            val capped = minOf(bps.toLong(), VIDEO_MAX_BITRATE.toLong()).toInt()
            Log.i(TAG, "bitrate $bps -> $capped")
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, capped) })
        }
    }

    override fun ended() {
        remoteView.post { onEnded() }
    }

    fun release() {
        audioRunning = false
        orientationListener.disable()
        record?.let { runCatching { it.stop() }; it.release() }
        record = null
        track?.let { runCatching { it.stop() }; it.release() }
        track = null
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audioManager.clearCommunicationDevice()
        @Suppress("DEPRECATION")
        if (audioRoute == AudioRoute.BLUETOOTH && Build.VERSION.SDK_INT < Build.VERSION_CODES.S) audioManager.stopBluetoothSco()
        audioManager.mode = AudioManager.MODE_NORMAL
        handler.post {
            session?.close(); camera?.close()
            encoder?.let { runCatching { it.stop() }; it.release() }
            decoder?.codec?.let { runCatching { it.stop() }; it.release() }
            encoderSurface?.release()
            encoder = null; decoder = null; camera = null; session = null
            worker.quitSafely()
        }
    }
}

/** Show a buffer of [bufW]x[bufH] rotated clockwise by [rotation], center cropped to fill the view. */
fun fitTexture(view: TextureView, bufW: Int, bufH: Int, rotation: Int, mirror: Boolean) {
    val vw = view.width.toFloat()
    val vh = view.height.toFloat()
    if (vw == 0f || vh == 0f) return
    val cx = vw / 2
    val cy = vh / 2
    val (cw, ch) = if (rotation % 180 == 0) Pair(bufW, bufH) else Pair(bufH, bufW)
    val scale = maxOf(vw / cw, vh / ch)
    val m = Matrix()
    // TextureView stretches the buffer to the view; undo that, then rotate and fill
    m.setScale(bufW / vw, bufH / vh, cx, cy)
    m.postRotate(rotation.toFloat(), cx, cy)
    m.postScale(if (mirror) -scale else scale, scale, cx, cy)
    view.setTransform(m)
}

/** Split Annex-B into NAL units, keeping their 4-byte start codes (what MediaCodec csd wants). */
fun splitAnnexB(data: ByteArray): List<ByteArray> {
    val starts = mutableListOf<Int>()
    var i = 0
    while (i + 3 < data.size) {
        if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
            starts.add(i); i += 4
        } else i++
    }
    return starts.mapIndexed { n, s -> data.copyOfRange(s, starts.getOrElse(n + 1) { data.size }) }
}
