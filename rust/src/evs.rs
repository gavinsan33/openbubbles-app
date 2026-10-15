// EVS decoding for FaceTime audio. Peers on a lossy link switch from AAC to EVS (payload 108)
// for seconds at a time; we can't stop advertising EVS (iOS hangs up on join), so decode it.
// Wraps the 3GPP reference decoder (third_party/evs) through src/evs_shim.c.

use std::os::raw::{c_int, c_short, c_uchar, c_void};

use crate::ft_media::{AUDIO_FRAME_SAMPLES, AUDIO_SAMPLE_RATE};

extern "C" {
    fn evs_shim_new(output_fs: c_int) -> *mut c_void;
    fn evs_shim_free(shim: *mut c_void);
    fn evs_shim_decode(shim: *mut c_void, payload: *const c_uchar, payload_len: c_int, out: *mut c_short, out_capacity: c_int) -> c_int;
}

// the decoder can't output 24kHz; decode at 48 and halve
const DECODE_RATE: u32 = 48000;
const DECODE_FRAME: usize = (DECODE_RATE / 50) as usize;
// header-full payloads can carry several frames
const MAX_FRAMES: usize = 8;

struct Shim(*mut c_void);

impl Shim {
    fn new() -> anyhow::Result<Self> {
        let ptr = unsafe { evs_shim_new(DECODE_RATE as c_int) };
        if ptr.is_null() { return Err(anyhow::anyhow!("evs decoder init failed")) }
        Ok(Self(ptr))
    }

    /// PCM at DECODE_RATE for every frame in one RTP payload
    fn decode(&mut self, payload: &[u8]) -> anyhow::Result<Vec<i16>> {
        let mut out = vec![0i16; DECODE_FRAME * MAX_FRAMES];
        let n = unsafe { evs_shim_decode(self.0, payload.as_ptr(), payload.len() as c_int, out.as_mut_ptr(), out.len() as c_int) };
        match n {
            -2 => Err(anyhow::anyhow!("evs decoder error")),
            n if n < 0 => Err(anyhow::anyhow!("unparseable evs payload of {} bytes", payload.len())),
            n => { out.truncate(n as usize); Ok(out) },
        }
    }
}

impl Drop for Shim {
    fn drop(&mut self) {
        unsafe { evs_shim_free(self.0) };
    }
}

// only used behind the call's decoder mutex
unsafe impl Send for Shim {}

/// Halves the sample rate: low-pass below the new Nyquist, then keep every other sample
struct Decimator {
    taps: Vec<f32>,
    history: Vec<f32>,
}

impl Decimator {
    fn new() -> Self {
        // 47 tap Blackman windowed sinc, cutoff 11kHz at 48kHz
        const N: usize = 47;
        let cutoff = 11000.0 / DECODE_RATE as f64;
        let mid = (N - 1) as f64 / 2.0;
        let mut taps: Vec<f64> = (0..N).map(|i| {
            let x = i as f64 - mid;
            let sinc = if x == 0.0 { 2.0 * cutoff } else { (2.0 * std::f64::consts::PI * cutoff * x).sin() / (std::f64::consts::PI * x) };
            let w = 0.42 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / (N - 1) as f64).cos() + 0.08 * (4.0 * std::f64::consts::PI * i as f64 / (N - 1) as f64).cos();
            sinc * w
        }).collect();
        let gain: f64 = taps.iter().sum();
        taps.iter_mut().for_each(|t| *t /= gain);
        Self { taps: taps.into_iter().map(|t| t as f32).collect(), history: vec![0.0; N - 1] }
    }

    fn process(&mut self, input: &[i16]) -> Vec<i16> {
        let mut buf = std::mem::take(&mut self.history);
        buf.extend(input.iter().map(|&s| s as f32));
        let n = self.taps.len();
        let out = (0..input.len() / 2).map(|i| {
            let window = &buf[i * 2 + 1..i * 2 + 1 + n];
            let acc: f32 = window.iter().zip(&self.taps).map(|(s, t)| s * t).sum();
            acc.round().clamp(i16::MIN as f32, i16::MAX as f32) as i16
        }).collect();
        self.history = buf[buf.len() - (n - 1)..].to_vec();
        out
    }
}

/// One participant's EVS stream, decoded to our audio format (24kHz mono, 480 sample frames)
pub struct EvsDecoder {
    shim: Shim,
    decimator: Decimator,
}

impl EvsDecoder {
    pub fn new() -> anyhow::Result<Self> {
        const _: () = assert!(DECODE_RATE == AUDIO_SAMPLE_RATE * 2);
        Ok(Self { shim: Shim::new()?, decimator: Decimator::new() })
    }

    /// Decodes one RTP payload's worth of EVS into 480 sample frames
    pub fn decode(&mut self, payload: &[u8]) -> anyhow::Result<Vec<Vec<i16>>> {
        let pcm = match self.shim.decode(payload) {
            Err(e) => {
                // a decoder that hit an internal error can't be reused
                self.shim = Shim::new()?;
                return Err(e)
            },
            Ok(pcm) => pcm,
        };
        let half = self.decimator.process(&pcm);
        Ok(half.chunks_exact(AUDIO_FRAME_SAMPLES).map(|c| c.to_vec()).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    // EVS-MIME files (TS 26.445 A.2.6) from the reference encoder: a 16 byte header, then a ToC
    // byte and the frame for each 20ms. Expected hashes are of the reference decoder's 48kHz
    // output for the same file with -no_delay_cmp.
    const VECTORS: [(&[u8], usize, &str); 2] = [
        (include_bytes!("testdata/evs_13200.mime"), 33, "4332dea4d3ff1368ed1cba141abecb49a1e9a7a95b4b102cc6e8e680f1ac2aef"),
        (include_bytes!("testdata/evs_24400.mime"), 61, "0bdccde2bfeb074c43aa6b4469adf44fac99f3792fa927812436b41c0c902ce6"),
    ];

    fn frames(file: &[u8], frame_len: usize) -> Vec<&[u8]> {
        assert!(file.starts_with(b"#!EVS_MC1.0\n"));
        file[16..].chunks(frame_len + 1).collect()
    }

    fn hash(pcm: &[i16]) -> String {
        let bytes: Vec<u8> = pcm.iter().flat_map(|s| s.to_le_bytes()).collect();
        Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect()
    }

    // ToC + frame is the header-full payload format; the bare frame is the compact format.
    // Both have to decode exactly as the reference decoder does.
    #[test]
    fn matches_reference_decoder() {
        for (file, frame_len, expected) in VECTORS {
            for compact in [false, true] {
                let mut shim = Shim::new().unwrap();
                let mut pcm = vec![];
                for frame in frames(file, frame_len) {
                    let payload = if compact { &frame[1..] } else { frame };
                    let out = shim.decode(payload).unwrap();
                    assert_eq!(out.len(), DECODE_FRAME);
                    pcm.extend(out);
                }
                assert_eq!(hash(&pcm), expected, "frame_len={frame_len} compact={compact}");
            }
        }
    }

    #[test]
    fn decodes_to_our_audio_frames() {
        let (file, frame_len, _) = VECTORS[0];
        let mut decoder = EvsDecoder::new().unwrap();
        let mut energy = 0f64;
        for frame in frames(file, frame_len) {
            let out = decoder.decode(&frame[1..]).unwrap();
            assert_eq!(out.len(), 1);
            assert_eq!(out[0].len(), AUDIO_FRAME_SAMPLES);
            energy += out[0].iter().map(|&s| (s as f64).powi(2)).sum::<f64>();
        }
        // the test signal is loud speech-like harmonics, not silence
        assert!(energy / (50.0 * AUDIO_FRAME_SAMPLES as f64) > 1e5);
    }

    #[test]
    fn rejects_garbage_without_crashing() {
        let mut decoder = EvsDecoder::new().unwrap();
        // 40 bits is no compact frame size, and as a header-full ToC 0x7f has no valid frame type
        assert!(decoder.decode(&[0x7f; 5]).is_err());
        assert!(decoder.decode(&[]).is_err());
        // and it still works afterwards
        let (file, frame_len, _) = VECTORS[0];
        assert_eq!(decoder.decode(&frames(file, frame_len)[0][1..]).unwrap().len(), 1);
    }

    // a 1kHz tone survives halving the rate, and an 18kHz one (above the new Nyquist) doesn't
    #[test]
    fn decimator_filters_above_new_nyquist() {
        let tone = |f: f64| -> Vec<i16> { (0..4800).map(|n| ((2.0 * std::f64::consts::PI * f * n as f64 / 48000.0).sin() * 10000.0) as i16).collect() };
        let rms = |s: &[i16]| (s[200..].iter().map(|&x| (x as f64).powi(2)).sum::<f64>() / (s.len() - 200) as f64).sqrt();
        let low = Decimator::new().process(&tone(1000.0));
        let high = Decimator::new().process(&tone(18000.0));
        assert_eq!(low.len(), 2400);
        assert!((rms(&low) - 7071.0).abs() < 200.0, "1kHz rms {}", rms(&low));
        assert!(rms(&high) < 100.0, "18kHz rms {}", rms(&high));
    }
}
