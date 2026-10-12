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
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.view.OrientationEventListener
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import uniffi.rust_lib_bluebubbles.FtCall
import uniffi.rust_lib_bluebubbles.FtMediaSink
import uniffi.rust_lib_bluebubbles.FtVideoCodec
import java.nio.ByteBuffer
import java.util.ArrayDeque
import kotlin.concurrent.thread

private const val TAG = "FaceTimeMedia"

// must match rust ft_media: AAC-ELD 24kHz mono, 480 sample frames
private const val AUDIO_RATE = 24000
private const val AUDIO_FRAME_SAMPLES = 480
private const val AUDIO_FRAME_BYTES = AUDIO_FRAME_SAMPLES * 2
// per participant: frames to buffer before playing them (absorbs network jitter), and the most kept
private const val AUDIO_JITTER_FRAMES = 3
private const val AUDIO_MAX_QUEUED = 10

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
    private val remoteGrid: ViewGroup,
    private val localView: TextureView,
    // clockwise degrees the UI is rotated from the display's natural orientation
    private val displayRotation: () -> Int,
    // foldables: the inner screen is in use (picks which front camera to default to)
    private val isUnfolded: () -> Boolean,
    private val onEnded: () -> Unit,
) : FtMediaSink {
    var call: FtCall? = null
        // FaceTime Audio calls never touch the camera
        set(value) { field = value; if (value?.isVideo() == true) startEncoder() }

    @Volatile var micMuted = false
    @Volatile var cameraOff = false
        set(value) {
            field = value
            call?.setVideoEnabled(!value)
            if (value) stopCamera() else openCamera()
        }
    private val cameraManager get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private fun camerasFacing(facing: Int) = cameraManager.cameraIdList.filter {
        cameraManager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == facing
    }

    // foldables have two selfie cameras: the cover screen's (listed first) and the inner screen's
    private fun currentCameraId(): String? =
        if (frontCamera) camerasFacing(CameraCharacteristics.LENS_FACING_FRONT).let { it.getOrNull(if (isUnfolded() && it.size > 1) 1 else 0) }
        else camerasFacing(CameraCharacteristics.LENS_FACING_BACK).firstOrNull() // main lens, not the ultra-wide

    /** Fold state changed mid-call: the selfie camera follows the screen in use. */
    fun postureChanged() {
        handler.post {
            if (!frontCamera) return@post
            stopCamera()
            if (!cameraOff) openCamera()
        }
    }
    @Volatile var frontCamera = true
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
    private var opening = false // handler thread only

    private fun startEncoder() {
        handler.post {
            orientationListener.enable()
            openCamera()
        }
    }

    // set when the camera changes: each camera has its own timestamp clock and an encoder fed
    // timestamps that jump backwards stops producing output
    private var encoderStale = false
    @Volatile private var bitrate = VIDEO_INITIAL_BITRATE // carried over when the encoder is recreated

    // runs on handler thread; (re)creates the encoder when the camera or its size changes
    private fun ensureEncoder(width: Int, height: Int) {
        if (encoder != null && !encoderStale && width == videoWidth && height == videoHeight) return
        encoderStale = false
        encoder?.let { runCatching { it.stop() }; it.release() }
        encoderSurface?.release()
        encoder = null
        videoWidth = width
        videoHeight = height
        run {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
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

    // rotation metadata for the receiver. The back camera gets an extra 180: receivers compensate for
    // is_back themselves, and without it the rear camera showed up upside down.
    private fun outgoingRotation(): Int =
        if (frontCamera) (sensorOrientation + deviceRotation) % 360
        else (sensorOrientation - deviceRotation + 180 + 360) % 360

    fun flipCamera() {
        handler.post {
            frontCamera = !frontCamera
            stopCamera()
            if (!cameraOff) openCamera()
        }
    }

    @SuppressLint("MissingPermission") // granted before the call starts
    private fun openCamera() {
        handler.post {
            if (camera != null || opening || cameraOff) return@post
            val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val id = currentCameraId() ?: return@post
            val chars = manager.getCameraCharacteristics(id)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            // a size the camera really outputs, so nothing gets squashed into 16:9
            val sizes = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                ?.getOutputSizes(SurfaceTexture::class.java).orEmpty()
            val size = sizes.filter { it.width <= VIDEO_MAX_WIDTH && it.width * 9 == it.height * 16 }.maxByOrNull { it.width }
                ?: sizes.filter { it.width <= VIDEO_MAX_WIDTH }.maxByOrNull { it.width * it.height }
            ensureEncoder(size?.width ?: 1280, size?.height ?: 720)
            Log.i(TAG, "opening camera $id front=$frontCamera sensor=$sensorOrientation size=${videoWidth}x$videoHeight")
            val openedFront = frontCamera
            opening = true
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    opening = false
                    // flipped (or turned off) while this was opening: go to the camera wanted now
                    if (cameraOff || openedFront != frontCamera) {
                        device.close()
                        openCamera()
                        return
                    }
                    camera = device
                    startCapture(device)
                }
                override fun onDisconnected(device: CameraDevice) { opening = false; device.close(); camera = null }
                override fun onError(device: CameraDevice, error: Int) {
                    Log.e(TAG, "camera error $error")
                    opening = false
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
            if (camera != null) encoderStale = true
            session?.close(); session = null
            camera?.close(); camera = null
        }
    }

    // ---- incoming video ----
    // one tile per remote participant, each with its own view and decoder; handler thread only
    private class Tile(val view: TextureView) {
        var surface: SurfaceTexture? = null
        var codec: MediaCodec? = null
        var config: Triple<FtVideoCodec, ByteArray, Pair<Int, Int>>? = null
        val frames = ArrayDeque<Pair<ByteArray, Long>>()
        val inputs = ArrayDeque<Int>()
        var decodedSize = Pair(0, 0)
        var rotation = -1
        var mirrored = false
        var lastFrame = SystemClock.elapsedRealtime()
        var shown = true
    }
    private val tiles = HashMap<ULong, Tile>()

    private fun tile(participant: ULong): Tile = tiles.getOrPut(participant) {
        val view = TextureView(context)
        val tile = Tile(view)
        view.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                handler.post { tile.surface = surface; startDecoder(tile) }
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture) = true
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }
        view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> handler.post { fit(tile) } }
        remoteGrid.post { remoteGrid.addView(view) }
        Log.i(TAG, "video tile for $participant")
        tile
    }

    // participants who stop sending (left, camera off) give their space back until they resume
    private val sweep = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            tiles.values.filter { it.shown && now - it.lastFrame > 3000 }.forEach { setShown(it, false) }
            handler.postDelayed(this, 1000)
        }
    }
    init { handler.post(sweep) }

    private fun setShown(tile: Tile, shown: Boolean) {
        tile.shown = shown
        tile.view.post { tile.view.visibility = if (shown) View.VISIBLE else View.GONE }
    }

    override fun videoConfig(participant: ULong, codec: FtVideoCodec, csd: ByteArray, width: Int, height: Int) {
        handler.post {
            val tile = tile(participant)
            val current = tile.config
            if (tile.codec != null && current != null && current.first == codec && current.second.contentEquals(csd)) return@post
            tile.config = Triple(codec, csd, Pair(width, height))
            startDecoder(tile)
        }
    }

    // (re)starts the tile's decoder once it has both a config and a surface
    private fun startDecoder(tile: Tile) {
        val (codec, csd, size) = tile.config ?: return
        val texture = tile.surface ?: return
        tile.codec?.let { runCatching { it.stop(); it.release() } }
        tile.codec = null
        tile.inputs.clear()
        val mime = if (codec == FtVideoCodec.H264) MediaFormat.MIMETYPE_VIDEO_AVC else MediaFormat.MIMETYPE_VIDEO_HEVC
        val format = MediaFormat.createVideoFormat(mime, maxOf(size.first, 16), maxOf(size.second, 16))
        if (codec == FtVideoCodec.H264) {
            // AVC wants SPS and PPS split
            val nals = splitAnnexB(csd)
            nals.getOrNull(0)?.let { format.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
            nals.getOrNull(1)?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
        } else {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
        }
        val mc = MediaCodec.createDecoderByType(mime)
        mc.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
                if (tile.codec !== codec) return
                tile.inputs.add(index)
                feed(tile)
            }
            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                codec.releaseOutputBuffer(index, true)
            }
            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "decoder error", e)
            }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                tile.decodedSize = Pair(format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
                fit(tile)
            }
        }, handler)
        tile.codec = mc
        mc.configure(format, Surface(texture), null, 0)
        mc.start()
        Log.i(TAG, "decoder $mime ${size.first}x${size.second}")
    }

    override fun videoFrame(participant: ULong, data: ByteArray, timestampUs: ULong, rotation: Int, mirrored: Boolean) {
        handler.post {
            // frames before a config are undecodable; rust asks the sender for a keyframe
            val tile = tiles[participant]?.takeIf { it.config != null } ?: return@post
            tile.lastFrame = SystemClock.elapsedRealtime()
            if (!tile.shown) setShown(tile, true)
            // queued while the surface is coming up too, so the keyframe isn't lost
            if (tile.frames.size > 30) tile.frames.clear() // fell behind, wait for a fresh run
            tile.frames.add(Pair(data, timestampUs.toLong()))
            feed(tile)
            if (rotation != tile.rotation || mirrored != tile.mirrored) {
                Log.i(TAG, "remote $participant rotation $rotation mirrored $mirrored")
                tile.rotation = rotation
                tile.mirrored = mirrored
                fit(tile)
            }
        }
    }

    // runs on handler thread
    private fun feed(tile: Tile) {
        val codec = tile.codec ?: return
        while (tile.frames.isNotEmpty() && tile.inputs.isNotEmpty()) {
            val (data, ts) = tile.frames.poll()!!
            val index = tile.inputs.poll()!!
            try {
                val buf = codec.getInputBuffer(index) ?: continue
                buf.clear()
                buf.put(data, 0, minOf(data.size, buf.capacity()))
                codec.queueInputBuffer(index, 0, minOf(data.size, buf.capacity()), ts, 0)
            } catch (e: IllegalStateException) {
                Log.w(TAG, "decoder gone", e)
                return
            }
        }
    }

    /** Center-crop a participant's video to fill their tile; also runs when the tile resizes. */
    private fun fit(tile: Tile) {
        val (w, h) = tile.decodedSize
        if (w == 0) return
        val rotation = maxOf(tile.rotation, 0)
        val mirrored = tile.mirrored
        tile.view.post { fitTexture(tile.view, w, h, rotation, mirrored) }
    }

    // ---- audio ----
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    // each participant's decoded frames, mixed by the speaker thread
    private class AudioQueue { val frames = ArrayDeque<ShortArray>(); var playing = false }
    private val audioQueues = HashMap<ULong, AudioQueue>()
    // held so they aren't GC'd: an effect's finalizer releases it, silently turning AEC off mid-call
    private var effects: List<android.media.audiofx.AudioEffect> = emptyList()
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
        remoteGrid.post { onAudioRouteChanged(route) }
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

    // headsets win; otherwise video calls use the speaker and audio calls the earpiece, like a phone call
    @SuppressLint("MissingPermission")
    fun startAudio(video: Boolean) {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        val routes = availableRoutes()
        setAudioRoute(routes.firstOrNull { it == AudioRoute.BLUETOOTH || it == AudioRoute.WIRED }
            ?: if (video) AudioRoute.SPEAKER else AudioRoute.EARPIECE)
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)

        val minRec = AudioRecord.getMinBufferSize(AUDIO_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, AUDIO_RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(minRec, AUDIO_FRAME_BYTES * 4))
        effects = listOfNotNull(
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId) else null,
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId) else null,
        ).onEach { it.enabled = true }
        Log.i(TAG, "audio effects ${effects.map { "${it.descriptor.name}=${it.enabled}" }}")
        record = rec

        val minPlay = AudioTrack.getMinBufferSize(AUDIO_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val player = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setSampleRate(AUDIO_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build())
            .setBufferSizeInBytes(maxOf(minPlay, AUDIO_FRAME_BYTES * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setSessionId(rec.audioSessionId) // same session gives the echo canceller the far-end reference
            .build()
            .also { it.play() }
        track = player

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
        // the blocking write paces this loop at the speaker's real rate: one 20ms frame from everyone per pass
        thread(name = "FaceTimeSpeaker") {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
            val sum = IntArray(AUDIO_FRAME_SAMPLES)
            val out = ShortArray(AUDIO_FRAME_SAMPLES)
            while (audioRunning) {
                sum.fill(0)
                synchronized(audioQueues) {
                    for (q in audioQueues.values) {
                        if (!q.playing) continue
                        val frame = q.frames.poll()
                        if (frame == null) { q.playing = false; continue } // ran dry, rebuffer
                        for (i in 0 until minOf(frame.size, AUDIO_FRAME_SAMPLES)) sum[i] += frame[i]
                    }
                }
                for (i in out.indices) out[i] = sum[i].coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
                if (player.write(out, 0, out.size, AudioTrack.WRITE_BLOCKING) < 0) break
            }
        }
    }

    override fun audioFrame(participant: ULong, pcm: ByteArray) {
        // called on rust's audio thread, never block it
        val samples = ShortArray(pcm.size / 2)
        ByteBuffer.wrap(pcm).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
        synchronized(audioQueues) {
            val q = audioQueues.getOrPut(participant) { AudioQueue() }
            q.frames.add(samples)
            while (q.frames.size > AUDIO_MAX_QUEUED) q.frames.poll() // fell behind, drop the oldest
            if (q.frames.size >= AUDIO_JITTER_FRAMES) q.playing = true
        }
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
            bitrate = capped
            Log.i(TAG, "bitrate $bps -> $capped")
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, capped) })
        }
    }

    override fun ended() {
        remoteGrid.post { onEnded() }
    }

    fun release() {
        audioRunning = false
        orientationListener.disable()
        effects.forEach { it.release() }
        effects = emptyList()
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
            tiles.values.forEach { t -> t.codec?.let { runCatching { it.stop() }; it.release() } }
            tiles.clear()
            encoderSurface?.release()
            encoder = null; camera = null; session = null
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
