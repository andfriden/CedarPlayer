#include "cwavpack.h"
#include "wavpack.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct CWavpackDecoder {
    WavpackContext *context;
    int channels;
    int rate;
    int bits;
    int is_float;
    int is_dsd;
    long long frames;
    int32_t *buffer;
    int buffer_frames;
};

CWavpackDecoder *cwavpack_open(const char *path) {
    if (!path) return NULL;
    char error[128] = {0};
    WavpackContext *ctx = WavpackOpenFileInput(path, error, OPEN_TAGS | OPEN_WVC | OPEN_NORMALIZE | OPEN_DSD_AS_PCM, 0);
    if (!ctx) return NULL;

    CWavpackDecoder *decoder = (CWavpackDecoder *)calloc(1, sizeof(CWavpackDecoder));
    if (!decoder) { WavpackCloseFile(ctx); return NULL; }
    decoder->context = ctx;
    decoder->channels = WavpackGetNumChannels(ctx);
    decoder->rate = (int)WavpackGetSampleRate(ctx);
    decoder->bits = WavpackGetBitsPerSample(ctx);
    decoder->is_float = (WavpackGetMode(ctx) & MODE_FLOAT) != 0;
    decoder->is_dsd = (WavpackGetQualifyMode(ctx) & QMODE_DSD_AUDIO) != 0;
    decoder->frames = WavpackGetNumSamples64(ctx);
    if (decoder->channels <= 0 || decoder->rate <= 0) {
        cwavpack_close(decoder);
        return NULL;
    }
    return decoder;
}

void cwavpack_close(CWavpackDecoder *decoder) {
    if (!decoder) return;
    if (decoder->context) WavpackCloseFile(decoder->context);
    free(decoder->buffer);
    free(decoder);
}

int cwavpack_info(CWavpackDecoder *decoder, int *channels, int *rate, int *bits,
                  long long *frames, int *is_float, int *is_dsd) {
    if (!decoder) return -1;
    if (channels) *channels = decoder->channels;
    if (rate) *rate = decoder->rate;
    if (bits) *bits = decoder->bits;
    if (frames) *frames = decoder->frames;
    if (is_float) *is_float = decoder->is_float;
    if (is_dsd) *is_dsd = decoder->is_dsd;
    return 0;
}

int cwavpack_read(CWavpackDecoder *decoder, float *samples, int max_frames) {
    if (!decoder || !samples || max_frames <= 0) return -1;
    int needed = max_frames * decoder->channels;
    if (decoder->buffer_frames < max_frames) {
        int32_t *grown = (int32_t *)realloc(decoder->buffer, sizeof(int32_t) * (size_t)needed);
        if (!grown) return -1;
        decoder->buffer = grown;
        decoder->buffer_frames = max_frames;
    }
    uint32_t got = WavpackUnpackSamples(decoder->context, decoder->buffer, (uint32_t)max_frames);
    if (got == 0) return 0;
    size_t count = (size_t)got * (size_t)decoder->channels;
    if (decoder->is_float) {
        memcpy(samples, decoder->buffer, count * sizeof(float));
    } else {
        float scale = 1.0f;
        if (decoder->bits > 0 && decoder->bits < 32) {
            scale = (float)ldexp(1.0, -(decoder->bits - 1));
        } else if (decoder->bits == 32) {
            scale = 1.0f / 2147483648.0f;
        }
        for (size_t i = 0; i < count; i++) samples[i] = (float)decoder->buffer[i] * scale;
    }
    return (int)got;
}

int cwavpack_tag(CWavpackDecoder *decoder, const char *key, char *buffer, int size) {
    if (!decoder || !key) return 0;
    return WavpackGetTagItem(decoder->context, key, buffer, size);
}

int cwavpack_cover(CWavpackDecoder *decoder, unsigned char **data) {
    if (!decoder || !data) return 0;
    *data = NULL;
    int total = WavpackGetBinaryTagItem(decoder->context, "Cover Art (Front)", NULL, 0);
    if (total <= 0) return 0;
    unsigned char *raw = (unsigned char *)malloc((size_t)total);
    if (!raw) return 0;
    int copied = WavpackGetBinaryTagItem(decoder->context, "Cover Art (Front)", (char *)raw, total);
    if (copied <= 0) { free(raw); return 0; }
    unsigned char *payload = raw;
    int remaining = copied;
    for (int i = 0; i < copied; i++) {
        if (raw[i] == 0) {
            payload = raw + i + 1;
            remaining = copied - i - 1;
            break;
        }
    }
    if (remaining <= 0) { free(raw); return 0; }
    unsigned char *out = (unsigned char *)malloc((size_t)remaining);
    if (!out) { free(raw); return 0; }
    memcpy(out, payload, (size_t)remaining);
    free(raw);
    *data = out;
    return remaining;
}

void cwavpack_free(void *pointer) {
    free(pointer);
}
