// Native FaceTime media: drives rustpush's AVSession for one call and shuttles
// frames between it and Kotlin (camera/HEVC encoder, decoders, mic, speaker).
// Video is encoded/decoded by Android MediaCodec; audio is AAC-ELD done here with fdk-aac,
// since rustpush negotiates AAC (payload 104) only.

use std::{collections::HashMap, fmt::Debug, time::{Duration, Instant}, sync::atomic::AtomicU64, mem::{self, MaybeUninit}, net::IpAddr, os::raw::{c_int, c_void}, ptr, sync::{atomic::{AtomicBool, Ordering}, Arc, LazyLock, Mutex, Weak}};

use base64::Engine;
use fdk_aac::dec::{Decoder, DecoderError, Transport};
use fdk_aac_sys as sys;
use log::{info, warn};
use rustpush::{avconference::{AVControlCommand, AVSession, AnnexB, AudioParser, AudioSender, ChannelFrame, ChannelMessage, ChannelType, DecoderConfiguration, FTVideoCameraStatus, VCControlData, VCGenerateKeyFrame, VideoRotation, VideoSender}, facetime::{FTClient, FTMessage, FTSession}};

use crate::RUNTIME;

// AAC-ELD, 24kHz mono, 480 sample (20ms) frames: one frame per RTP packet
pub const AUDIO_SAMPLE_RATE: u32 = 24000;
pub const AUDIO_FRAME_SAMPLES: usize = 480;
const AUDIO_BITRATE: u32 = 32000;
// RTP clock for camera (group 1) and mic (group 2) streams
const RTP_CLOCK: u64 = 24000;

#[derive(uniffi::Enum, Clone, Copy, Debug)]
pub enum FtVideoCodec {
    H264,
    H265,
}

#[uniffi::export(with_foreign)]
pub trait FtMediaSink: Send + Sync + Debug {
    /// (re)configure the decoder for a participant's video; csd is Annex-B parameter sets
    fn video_config(&self, participant: u64, codec: FtVideoCodec, csd: Vec<u8>, width: i32, height: i32);
    /// one Annex-B access unit. rotation is clockwise degrees to display it upright
    fn video_frame(&self, participant: u64, data: Vec<u8>, timestamp_us: u64, rotation: i32, mirrored: bool);
    /// 480 samples of 24kHz mono PCM16, little endian
    fn audio_frame(&self, participant: u64, pcm: Vec<u8>);
    fn request_keyframe(&self);
    fn set_bitrate(&self, bps: u64);
    fn ended(&self);
}

struct Senders {
    video: Option<VideoSender>,
    audio: Option<AudioSender>,
    // the next keyframe must carry parameter sets
    send_config: bool,
}

// None until the library tells us which mode we're in; Some(None) is 1:1
type StreamMode = Option<Option<HashMap<u32, Vec<u32>>>>;

#[derive(uniffi::Object)]
pub struct FtCall {
    guid: String,
    ft: Arc<FTClient>,
    av: Arc<AVSession>,
    sink: Arc<dyn FtMediaSink>,
    senders: Mutex<Senders>,
    mode: Mutex<(StreamMode, bool /* has peer */)>,
    video_csd: Mutex<Option<Vec<u8>>>,
    dims: Mutex<(u16, u16)>,
    encoder: Mutex<AacEncoder>,
    // audio and video RTP timestamps share this call clock (base + elapsed at 24kHz): receivers
    // sync the streams by timestamp, and unrelated clocks left them holding our video forever
    clock_start: Instant,
    ts_base: u32,
    audio_ts: Mutex<Option<u32>>,
    // camera pts (us) -> call clock (us), fixed at the first frame
    video_pts_offset: Mutex<Option<i64>>,
    ended: AtomicBool,
    video_sent: AtomicU64,
    video_received: AtomicU64,
}

impl Debug for FtCall {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FtCall").field("guid", &self.guid).finish()
    }
}

static CALLS: LazyLock<Mutex<HashMap<String, Weak<FtCall>>>> = LazyLock::new(Default::default);

pub fn local_interfaces() -> Vec<IpAddr> {
    let Ok(addrs) = nix::ifaddrs::getifaddrs() else { return vec![] };
    addrs.filter(|i| i.flags.contains(nix::net::if_::InterfaceFlags::IFF_UP) && !i.flags.contains(nix::net::if_::InterfaceFlags::IFF_LOOPBACK))
        .filter_map(|i| {
            let addr = i.address?;
            if let Some(v4) = addr.as_sockaddr_in() {
                return Some(IpAddr::V4(*std::net::SocketAddrV4::from(*v4).ip()))
            }
            let v6 = *std::net::SocketAddrV6::from(*addr.as_sockaddr_in6()?).ip();
            // link-local candidates aren't routable for a call
            if (v6.segments()[0] & 0xffc0) == 0xfe80 { return None }
            Some(IpAddr::V6(v6))
        }).collect()
}

/// Join the call if we aren't in it yet (answering, or joining an active one), then attach media.
pub async fn start_call(ft: Arc<FTClient>, guid: String, sink: Arc<dyn FtMediaSink>) -> anyhow::Result<Arc<FtCall>> {
    ft.set_local_interfaces(&local_interfaces()).await;
    let mut state = ft.state.write().await;
    let session = state.sessions.get_mut(&guid).ok_or(anyhow::anyhow!("No session {guid}"))?;
    if session.connection.is_none() {
        ft.join(session, false).await?;
    }
    let av = session.connection.clone().ok_or(anyhow::anyhow!("No connection after join"))?;
    drop(state);

    let call = Arc::new(FtCall {
        guid: guid.clone(),
        ft,
        av: av.clone(),
        sink,
        senders: Mutex::new(Senders { video: None, audio: None, send_config: true }),
        mode: Mutex::new((None, false)),
        video_csd: Mutex::new(None),
        dims: Mutex::new((1280, 720)),
        encoder: Mutex::new(AacEncoder::new()?),
        clock_start: Instant::now(),
        ts_base: rand::random(),
        audio_ts: Mutex::new(None),
        video_pts_offset: Mutex::new(None),
        ended: AtomicBool::new(false),
        video_sent: AtomicU64::new(0),
        video_received: AtomicU64::new(0),
    });
    CALLS.lock().unwrap().insert(guid, Arc::downgrade(&call));

    call.attach_incoming();

    let Some(control) = av.control.lock().await.take() else {
        return Err(anyhow::anyhow!("Call already attached"))
    };
    let weak = Arc::downgrade(&call);
    RUNTIME.spawn(drive(weak, control));
    Ok(call)
}

// rustpush emits leaves through FTClient::handle; end the call screen when nobody else is left
pub async fn on_ft_message(ft: &FTClient, msg: &FTMessage) {
    let guid = match msg {
        FTMessage::LeaveEvent { guid, .. } | FTMessage::Decline { guid } | FTMessage::RespondedElsewhere { guid } => guid,
        _ => return,
    };
    let Some(call) = CALLS.lock().unwrap().get(guid).and_then(|c| c.upgrade()) else { return };
    if matches!(msg, FTMessage::LeaveEvent { .. }) {
        let my_token = Some(base64::engine::general_purpose::STANDARD.encode(ft.conn.get_token().await));
        let state = ft.state.read().await;
        let others = state.sessions.get(guid).map(|s| s.participants.values().any(|p| p.active.is_some() && p.token != my_token)).unwrap_or(false);
        if others { return }
    }
    call.finish().await;
}

async fn drive(call: Weak<FtCall>, mut control: tokio::sync::mpsc::Receiver<AVControlCommand>) {
    while let Some(cmd) = control.recv().await {
        let Some(call) = call.upgrade() else { return };
        if call.ended.load(Ordering::Relaxed) { return }
        match cmd {
            AVControlCommand::SelectStreams(streams) => {
                info!("FT select streams {streams:?}");
                call.mode.lock().unwrap().0 = Some(streams);
                call.rebuild_senders().await;
            },
            AVControlCommand::ActiveParticipants(set) => {
                info!("FT active participants {set:?}");
                let has_peer = !set.is_empty();
                let had_peer = mem::replace(&mut call.mode.lock().unwrap().1, has_peer);
                if had_peer != has_peer {
                    call.rebuild_senders().await;
                }
            },
            AVControlCommand::SelectVideoBitrate(bps) => call.sink.set_bitrate(bps as u64),
            AVControlCommand::AVControl { data: VCControlData::GenerateKeyFrame(k), participant } => {
                info!("FT keyframe requested by {participant} {k:?}");
                call.senders.lock().unwrap().send_config = true;
                call.sink.request_keyframe();
            },
            AVControlCommand::AVControl { .. } => {},
            AVControlCommand::CallFailed => {
                warn!("FT call failed");
                call.finish().await;
                return
            },
        }
    }
}

fn rotation_degrees(rotation: &VideoRotation) -> i32 {
    match rotation {
        VideoRotation::Rotate90Deg => 90,
        VideoRotation::RotateMinus90Deg => 270,
        VideoRotation::Rotate180Deg => 180,
        VideoRotation::NoRotation => 0,
    }
}

fn rotation_from_degrees(degrees: i32) -> VideoRotation {
    match degrees.rem_euclid(360) {
        90 => VideoRotation::Rotate90Deg,
        270 => VideoRotation::RotateMinus90Deg,
        180 => VideoRotation::Rotate180Deg,
        _ => VideoRotation::NoRotation,
    }
}

impl FtCall {
    async fn rebuild_senders(&self) {
        let (Some(mode), has_peer) = self.mode.lock().unwrap().clone() else { return };
        let (w, h) = *self.dims.lock().unwrap();
        let (video, audio) = match mode {
            // 1:1 senders address the peer directly and need it to be present
            None if !has_peer => (None, None),
            None => (Some(self.av.create_video_sender(1, None, &[], w, h).await), Some(self.av.create_audio_sender(2, None, &[]).await)),
            Some(groups) => {
                let video = match groups.get(&1).and_then(|s| s.split_first()) {
                    Some((first, rest)) => Some(self.av.create_video_sender(1, Some(*first), rest, w, h).await),
                    None => None,
                };
                let audio = match groups.get(&2).and_then(|s| s.split_first()) {
                    Some((first, rest)) => Some(self.av.create_audio_sender(2, Some(*first), rest).await),
                    None => None,
                };
                (video, audio)
            },
        };
        info!("FT senders video={} audio={}", video.is_some(), audio.is_some());
        if video.is_some() {
            // tell the peer our camera is on now rather than waiting for it to fetch our state
            if let Err(e) = self.av.set_video_enabled(true).await {
                warn!("FT announcing video failed {e}");
            }
        }
        let mut senders = self.senders.lock().unwrap();
        senders.video = video;
        senders.audio = audio;
        senders.send_config = true;
        drop(senders);
        self.sink.request_keyframe();
    }

    fn attach_incoming(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        let decoders: Mutex<HashMap<u64, Decoder>> = Mutex::new(HashMap::new());
        // participants whose video we can't decode yet, and when we last asked them for a keyframe
        let awaiting_config: Mutex<HashMap<u64, Option<Instant>>> = Mutex::new(HashMap::new());
        let asc = self.encoder.lock().unwrap().asc.clone();
        self.av.frame_handler.configure_handler(Box::new(move |msg: ChannelMessage| {
            let Some(call) = weak.upgrade() else { return };
            let participant = msg.stream.participant;
            match (msg.r#type, msg.frame) {
                (ChannelType::H264 | ChannelType::H265, ChannelFrame::Configuration(config)) => {
                    awaiting_config.lock().unwrap().insert(participant, None);
                    let (w, h) = config.get_dimens();
                    let codec = if matches!(msg.r#type, ChannelType::H264) { FtVideoCodec::H264 } else { FtVideoCodec::H265 };
                    call.sink.video_config(participant, codec, config.annex_b(), w, h);
                },
                (ChannelType::H264 | ChannelType::H265, ChannelFrame::Sample(data)) => {
                    let received = call.video_received.fetch_add(1, Ordering::Relaxed) + 1;
                    if received % 300 == 1 { info!("FT video frames received {received}") }
                    {
                        // frames without a config are undecodable (we missed their keyframe); ask again, at most every second
                        let mut awaiting = awaiting_config.lock().unwrap();
                        let entry = awaiting.entry(participant).or_insert(Some(Instant::now() - Duration::from_secs(2)));
                        if let Some(last) = entry {
                            if last.elapsed() > Duration::from_secs(1) {
                                *last = Instant::now();
                                let av = call.av.clone();
                                let request = VCGenerateKeyFrame { stream_id: msg.control_stream_id, stream_group_id: 1, fir_type: 1 };
                                info!("FT requesting keyframe from {participant} {request:?}");
                                RUNTIME.spawn(async move {
                                    if let Err(e) = av.send_control_message(participant, VCControlData::GenerateKeyFrame(request)).await {
                                        warn!("FT keyframe request failed {e}");
                                    }
                                });
                            }
                        }
                    }
                    if received % 300 == 1 {
                        // what a real Apple sender puts in the trailer, to compare with what we send
                        let meta: Vec<String> = msg.metadata.iter().map(|(k, v)| format!("{k}={v:02x?}")).collect();
                        info!("FT incoming video metadata {meta:?} camera {:?}", msg.camera_meta);
                    }
                    let (mul, div) = msg.stream.clock_conversion();
                    let rotation = msg.camera_meta.as_ref().map(|c| rotation_degrees(&c.orientation)).unwrap_or(0);
                    let mirrored = msg.camera_meta.as_ref().map(|c| c.is_mirrored).unwrap_or(false);
                    call.sink.video_frame(participant, data, msg.timestamp as u64 * mul / div, rotation, mirrored);
                },
                (ChannelType::Aac, ChannelFrame::Sample(data)) => {
                    let mut decoders = decoders.lock().unwrap();
                    let decoder = decoders.entry(participant).or_insert_with(|| {
                        let mut d = Decoder::new(Transport::Raw);
                        if let Err(e) = d.config_raw(&asc) { warn!("FT aac config {}", e.message()) }
                        d
                    });
                    for frame in AudioParser(&data) {
                        match decode_aac(decoder, frame) {
                            Ok(pcm) => call.sink.audio_frame(participant, pcm.iter().flat_map(|s| s.to_le_bytes()).collect()),
                            Err(e) => warn!("FT aac decode {} len {}", e.message(), frame.len()),
                        }
                    }
                },
                (other, _) => warn!("FT ignoring incoming {other:?}"),
            }
        }));
    }

    async fn finish(&self) {
        if self.ended.swap(true, Ordering::Relaxed) { return }
        info!("FT ending call {}", self.guid);
        {
            let mut senders = self.senders.lock().unwrap();
            senders.video = None;
            senders.audio = None;
        }
        CALLS.lock().unwrap().remove(&self.guid);
        let mut state = self.ft.state.write().await;
        if let Some(session) = state.sessions.get_mut(&self.guid) {
            if session.connection.is_some() {
                if let Err(e) = self.ft.leave(session).await {
                    warn!("FT leave failed {e}");
                }
            }
        }
        drop(state);
        self.sink.ended();
    }
}

fn decode_aac(decoder: &mut Decoder, frame: &[u8]) -> Result<Vec<i16>, DecoderError> {
    decoder.fill(frame)?;
    let mut pcm = vec![0i16; AUDIO_FRAME_SAMPLES * 2];
    decoder.decode_frame(&mut pcm)?;
    pcm.truncate(decoder.decoded_frame_size());
    Ok(pcm)
}

#[uniffi::export]
impl FtCall {
    /// encoder output with BUFFER_FLAG_CODEC_CONFIG (Annex-B VPS/SPS/PPS)
    pub fn set_video_config(self: Arc<Self>, csd: Vec<u8>, width: u32, height: u32) {
        let (width, height) = (width as u16, height as u16);
        *self.video_csd.lock().unwrap() = Some(csd);
        let old = mem::replace(&mut *self.dims.lock().unwrap(), (width, height));
        if old != (width, height) {
            info!("FT resolution now {width}x{height}");
            // senders bake in the resolution
            RUNTIME.spawn(async move { self.rebuild_senders().await });
        }
    }

    /// one HEVC access unit in Annex-B, as MediaCodec outputs it
    pub fn send_video(&self, data: Vec<u8>, keyframe: bool, timestamp_us: u64, rotation: i32, mirrored: bool, back: bool) {
        let mut senders = self.senders.lock().unwrap();
        let send_config = senders.send_config;
        let Some(video) = senders.video.as_mut() else { return };
        if send_config && !keyframe { return } // wait for the keyframe we asked for

        let mut frames = vec![];
        if keyframe {
            let Some(csd) = self.video_csd.lock().unwrap().clone() else { return };
            let (w, h) = *self.dims.lock().unwrap();
            frames.push(ChannelFrame::Configuration(DecoderConfiguration::from_annex_b_hevc(&csd, false, w, h)));
        }
        // parameter sets travel in the configuration; some encoders also inline them
        frames.extend(AnnexB::new(&data).filter(|nal| !nal.is_empty() && !(32..=34).contains(&((nal[0] >> 1) & 0x3f))).map(|nal| ChannelFrame::Sample(nal.to_vec())));

        video.camera_source = FTVideoCameraStatus { orientation: rotation_from_degrees(rotation), is_mirrored: mirrored, is_back: back, source: 0 };
        let elapsed_us = self.clock_start.elapsed().as_micros() as i64;
        let offset = *self.video_pts_offset.lock().unwrap().get_or_insert(elapsed_us - timestamp_us as i64);
        let call_us = (timestamp_us as i64 + offset).max(0) as u64;
        let timestamp = self.ts_base.wrapping_add((call_us * RTP_CLOCK / 1_000_000) as u32);
        match video.send_video_frame(frames, timestamp) {
            Ok(()) => {
                if keyframe { senders.send_config = false }
                let sent = self.video_sent.fetch_add(1, Ordering::Relaxed) + 1;
                if sent % 300 == 1 || keyframe { info!("FT video sent {sent} keyframe={keyframe} bytes={}", data.len()) }
            },
            Err(e) => warn!("FT send video {e}"),
        }
    }

    /// 480 samples of 24kHz mono PCM16 (20ms), little endian
    pub fn send_audio(&self, pcm: Vec<u8>) {
        let pcm: Vec<i16> = pcm.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
        let au = match self.encoder.lock().unwrap().encode(&pcm) {
            Ok(Some(au)) => au,
            Ok(None) => return,
            Err(e) => { warn!("FT aac encode {e}"); return },
        };
        let mut ts = self.audio_ts.lock().unwrap();
        let timestamp = *ts.get_or_insert_with(|| {
            self.ts_base.wrapping_add((self.clock_start.elapsed().as_micros() as u64 * RTP_CLOCK / 1_000_000) as u32)
        });
        *ts = Some(timestamp.wrapping_add(AUDIO_FRAME_SAMPLES as u32));
        drop(ts);

        let mut senders = self.senders.lock().unwrap();
        let Some(audio) = senders.audio.as_mut() else { return };
        let mut payload = Vec::with_capacity(au.len() + 1);
        payload.push(au.len() as u8);
        payload.extend_from_slice(&au);
        if let Err(e) = audio.send_audio_frame(&payload, timestamp) {
            warn!("FT send audio {e}");
        }
    }

    pub fn set_video_enabled(&self, enabled: bool) {
        let av = self.av.clone();
        RUNTIME.spawn(async move {
            if let Err(e) = av.set_video_enabled(enabled).await {
                warn!("FT set video {e}");
            }
        });
    }

    pub fn leave(self: Arc<Self>) {
        RUNTIME.spawn(async move { self.finish().await });
    }
}

struct AacEncoder {
    handle: sys::HANDLE_AACENCODER,
    asc: Vec<u8>,
    max_out: usize,
}

// the handle is only touched behind FtCall's mutex
unsafe impl Send for AacEncoder {}

impl Drop for AacEncoder {
    fn drop(&mut self) {
        unsafe { sys::aacEncClose(&mut self.handle) };
    }
}

impl AacEncoder {
    fn new() -> anyhow::Result<Self> {
        let check = |r: sys::AACENC_ERROR, what: &str| if r != sys::AACENC_ERROR_AACENC_OK { Err(anyhow::anyhow!("aacenc {what} failed {r}")) } else { Ok(()) };
        let mut handle: sys::HANDLE_AACENCODER = ptr::null_mut();
        unsafe {
            check(sys::aacEncOpen(&mut handle, 0, 1), "open")?;
            let mut enc = AacEncoder { handle, asc: vec![], max_out: 0 };
            for (param, value) in [
                (sys::AACENC_PARAM_AACENC_AOT, sys::AUDIO_OBJECT_TYPE_AOT_ER_AAC_ELD as u32),
                (sys::AACENC_PARAM_AACENC_SAMPLERATE, AUDIO_SAMPLE_RATE),
                (sys::AACENC_PARAM_AACENC_CHANNELMODE, 1),
                (sys::AACENC_PARAM_AACENC_GRANULE_LENGTH, AUDIO_FRAME_SAMPLES as u32),
                (sys::AACENC_PARAM_AACENC_SBR_MODE, 0),
                (sys::AACENC_PARAM_AACENC_BITRATEMODE, 0),
                (sys::AACENC_PARAM_AACENC_BITRATE, AUDIO_BITRATE),
                (sys::AACENC_PARAM_AACENC_TRANSMUX, sys::TRANSPORT_TYPE_TT_MP4_RAW as u32),
                (sys::AACENC_PARAM_AACENC_AFTERBURNER, 1),
            ] {
                check(sys::aacEncoder_SetParam(enc.handle, param, value), &format!("param {param}"))?;
            }
            check(sys::aacEncEncode(enc.handle, ptr::null(), ptr::null(), ptr::null(), ptr::null_mut()), "init")?;
            let mut info = MaybeUninit::<sys::AACENC_InfoStruct>::zeroed();
            check(sys::aacEncInfo(enc.handle, info.as_mut_ptr()), "info")?;
            let info = info.assume_init();
            enc.asc = info.confBuf[..info.confSize as usize].to_vec();
            enc.max_out = info.maxOutBufBytes as usize;
            info!("FT aac encoder frame {} asc {:02x?}", info.frameLength, enc.asc);
            Ok(enc)
        }
    }

    fn encode(&mut self, pcm: &[i16]) -> anyhow::Result<Option<Vec<u8>>> {
        let mut out = vec![0u8; self.max_out.max(768)];
        let mut in_ptr = pcm.as_ptr() as *mut c_void;
        let mut in_id: c_int = sys::AACENC_BufferIdentifier_IN_AUDIO_DATA as c_int;
        let mut in_size: c_int = (pcm.len() * mem::size_of::<i16>()) as c_int;
        let mut in_el: c_int = mem::size_of::<i16>() as c_int;
        let mut out_ptr = out.as_mut_ptr() as *mut c_void;
        let mut out_id: c_int = sys::AACENC_BufferIdentifier_OUT_BITSTREAM_DATA as c_int;
        let mut out_size: c_int = out.len() as c_int;
        let mut out_el: c_int = 1;
        let in_desc = sys::AACENC_BufDesc { numBufs: 1, bufs: &mut in_ptr, bufferIdentifiers: &mut in_id, bufSizes: &mut in_size, bufElSizes: &mut in_el };
        let out_desc = sys::AACENC_BufDesc { numBufs: 1, bufs: &mut out_ptr, bufferIdentifiers: &mut out_id, bufSizes: &mut out_size, bufElSizes: &mut out_el };
        let in_args = sys::AACENC_InArgs { numInSamples: pcm.len() as c_int, numAncBytes: 0 };
        let mut out_args = MaybeUninit::<sys::AACENC_OutArgs>::zeroed();
        let r = unsafe { sys::aacEncEncode(self.handle, &in_desc, &out_desc, &in_args, out_args.as_mut_ptr()) };
        if r != sys::AACENC_ERROR_AACENC_OK {
            return Err(anyhow::anyhow!("encode {r}"))
        }
        let n = unsafe { out_args.assume_init() }.numOutBytes as usize;
        if n == 0 { return Ok(None) } // still filling the encoder's lookahead
        out.truncate(n);
        Ok(Some(out))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // a 480-sample ELD frame round-trips through our encoder config and decodes to 480 samples
    #[test]
    fn aac_eld_roundtrip() {
        let mut enc = AacEncoder::new().unwrap();
        let mut dec = Decoder::new(Transport::Raw);
        dec.config_raw(&enc.asc).unwrap();
        let tone: Vec<i16> = (0..AUDIO_FRAME_SAMPLES).map(|i| ((i as f32 * 0.2).sin() * 8000.0) as i16).collect();
        let mut decoded = 0;
        for _ in 0..10 {
            if let Some(au) = enc.encode(&tone).unwrap() {
                assert!(au.len() < 256, "AU must fit the 1 byte length prefix");
                let pcm = decode_aac(&mut dec, &au).unwrap();
                assert_eq!(pcm.len(), AUDIO_FRAME_SAMPLES);
                decoded += 1;
            }
        }
        assert!(decoded > 0);
    }
}
