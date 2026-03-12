/*
 * lc3_decoder_bridge.c – Thin C wrapper around liblc3 for Dart FFI.
 *
 * Exposes a simple API to:
 *   1. Create a decoder context for given parameters
 *   2. Decode one LC3 frame → PCM S16
 *   3. Destroy the decoder context
 */

#include <stdlib.h>
#include <string.h>
#include <lc3.h>

/* Make symbols visible from the shared library */
#define EXPORT __attribute__((visibility("default")))

/* -------------------------------------------------------------------------- */
/* Opaque handle wrapping liblc3 decoder + its memory                          */
/* -------------------------------------------------------------------------- */

typedef struct {
    lc3_decoder_t decoder;
    void         *mem;
    int           dt_us;
    int           sr_hz;
    int           frame_samples;
} Lc3DecoderCtx;

/* -------------------------------------------------------------------------- */
/* Public API                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Create a decoder context.
 *
 * @param dt_us   Frame duration in µs (7500 or 10000)
 * @param sr_hz   Sample rate in Hz (8000..48000)
 * @return opaque handle, or NULL on failure
 */
EXPORT Lc3DecoderCtx *lc3_decoder_create(int dt_us, int sr_hz) {
    unsigned size = lc3_decoder_size(dt_us, sr_hz);
    if (size == 0) return NULL;

    void *mem = malloc(size);
    if (!mem) return NULL;

    lc3_decoder_t dec = lc3_setup_decoder(dt_us, sr_hz, sr_hz, mem);
    if (!dec) {
        free(mem);
        return NULL;
    }

    Lc3DecoderCtx *ctx = (Lc3DecoderCtx *)malloc(sizeof(Lc3DecoderCtx));
    if (!ctx) {
        free(mem);
        return NULL;
    }

    ctx->decoder       = dec;
    ctx->mem           = mem;
    ctx->dt_us         = dt_us;
    ctx->sr_hz         = sr_hz;
    ctx->frame_samples = lc3_frame_samples(dt_us, sr_hz);

    return ctx;
}

/**
 * Return the number of PCM samples produced per frame.
 */
EXPORT int lc3_decoder_frame_samples(const Lc3DecoderCtx *ctx) {
    return ctx ? ctx->frame_samples : 0;
}

/**
 * Decode one LC3 frame into signed-16-bit PCM.
 *
 * @param ctx       Handle from lc3_decoder_create()
 * @param in_data   LC3-encoded frame bytes
 * @param in_bytes  Number of input bytes (e.g. 40 for 32 kbps @ 10 ms)
 * @param out_pcm   Output buffer, must hold at least frame_samples * 2 bytes
 * @return 0 on success, non-zero on error
 */
EXPORT int lc3_decoder_decode_frame(
        Lc3DecoderCtx *ctx,
        const uint8_t *in_data,
        int in_bytes,
        int16_t *out_pcm) {
    if (!ctx || !out_pcm) return -1;
    if (in_data == NULL && in_bytes != 0) return -1;

    return lc3_decode(ctx->decoder, in_data, in_bytes,
                      LC3_PCM_FORMAT_S16, out_pcm, 1);
}

/**
 * Destroy the decoder and free memory.
 */
EXPORT void lc3_decoder_destroy(Lc3DecoderCtx *ctx) {
    if (!ctx) return;
    free(ctx->mem);
    free(ctx);
}
