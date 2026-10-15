// Frame-at-a-time wrapper around the 3GPP EVS reference decoder (third_party/evs), used for
// FaceTime audio that peers send as EVS. Mirrors what the reference VoIP receiver (EvsRXlib.c)
// does per frame, without its jitter buffer: the caller already buffers and paces playback.

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include "options.h"
#include "prot.h"
#include "cnst.h"
#include "evs_rtp_payload.h"

// the reference code exit()s on internal errors; build.rs redirects those calls here so a bad
// frame fails the decode call instead of killing the app
static __thread jmp_buf *evs_shim_jmp;

void evs_shim_exit(int code) {
    if (evs_shim_jmp) longjmp(*evs_shim_jmp, code ? code : 1);
    abort();
}

typedef struct {
    Decoder_State st;
    int initialized;
} EvsShim;

EvsShim *evs_shim_new(int output_fs) {
    if (output_fs != 8000 && output_fs != 16000 && output_fs != 32000 && output_fs != 48000) return NULL;
    EvsShim *s = calloc(1, sizeof(EvsShim));
    if (!s) return NULL;
    Decoder_State *st = &s->st;
    // what io_ini_dec sets up for a VoIP (RTP payload) decoder
    st->output_Fs = output_fs;
    st->codec_mode = 0; // unknown until the first frame
    st->Opt_AMR_WB = 0;
    st->Opt_VOIP = 1;
    st->bitstreamformat = VOIP_RTPDUMP;
    st->sdp_hf_only = 0;
    st->amrwb_rfc4867_flag = -1;
    st->writeFECoffset = 0;
    st->cldfbAna = st->cldfbBPF = st->cldfbSyn = NULL;
    st->hFdCngDec = NULL;
    return s;
}

void evs_shim_free(EvsShim *s) {
    if (!s) return;
    if (s->initialized) destroy_decoder(&s->st);
    free(s);
}

/// Decodes every frame in one EVS RTP payload (compact or header-full, TS 26.445 A.2) into
/// 16-bit PCM at the output rate, output_fs / 50 samples per frame. Returns the number of
/// samples written, -1 for a payload it can't parse, or -2 if the decoder hit an internal error
/// (its state is then unusable: free it and make a new one).
int evs_shim_decode(EvsShim *s, const unsigned char *payload, int payload_len, short *out, int out_capacity) {
    Decoder_State *st = &s->st;
    const int frame_samples = st->output_Fs / 50;
    jmp_buf jmp;
    jmp_buf *prev = evs_shim_jmp;
    int written = 0;
    if (payload_len <= 0 || payload_len > 0xffff) return -1;
    if (setjmp(jmp)) {
        evs_shim_jmp = prev;
        return -2;
    }
    evs_shim_jmp = &jmp;

    bool following = true;
    for (uint16_t index = 0; following; index++) {
        bool amrwb_io, qbit;
        uint16_t frame_type, frame_bits;
        // AMR-WB IO compact frames are unpacked into here; EVS primary points into the payload
        unsigned char unpacked[MAX_AU_SIZE + 2] = {0};
        unsigned char *frame = unpacked;
        float output[L_FRAME48k];

        if (written + frame_samples > out_capacity) break;
        if (!evsPayload_unpackFrame(false, (const char *)payload, (uint16_t)payload_len, index,
                                    &amrwb_io, &following, &frame_type, &qbit, &frame, &frame_bits)) {
            evs_shim_jmp = prev;
            return written > 0 ? written : -1;
        }

        if (st->codec_mode == 0) {
            // first frame: initialize, as EvsRXlib does (init_decoder resets total_brate, so parse after)
            if (s->initialized) destroy_decoder(st);
            st->ini_frame = 0;
            st->prev_use_partial_copy = 0;
            init_decoder(st);
            s->initialized = 1;
        }
        read_indices_from_djb(st, frame, frame_bits, amrwb_io, frame_type, qbit, 0, 0);

        if (st->codec_mode == MODE1) {
            if (st->Opt_AMR_WB) amr_wb_dec(st, output);
            else evs_dec(st, output, FRAMEMODE_NORMAL);
        } else if (st->codec_mode == MODE2) {
            evs_dec(st, output, st->bfi == 0 ? FRAMEMODE_NORMAL : FRAMEMODE_MISSING);
        } else {
            // still no usable mode: silence rather than garbage
            memset(output, 0, sizeof(output));
        }
        syn_output(output, (short)frame_samples, out + written);
        if (st->ini_frame < MAX_FRAME_COUNTER) st->ini_frame++;
        written += frame_samples;
    }

    evs_shim_jmp = prev;
    return written;
}
