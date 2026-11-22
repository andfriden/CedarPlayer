#include "cvorbis.h"
#include <stdlib.h>
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

int cvorbis_decode(const char *path, float **samples, int *frames, int *channels, int *rate) {
    if (!path || !samples || !frames || !channels || !rate) return -1;
    int ch = 0, sr = 0;
    short *data = NULL;
    int n = stb_vorbis_decode_filename(path, &ch, &sr, &data);
    if (n < 0 || !data || ch <= 0 || sr <= 0) {
        if (data) free(data);
        return -2;
    }
    float *out = (float *)malloc(sizeof(float) * (size_t)n * (size_t)ch);
    if (!out) { free(data); return -3; }
    size_t count = (size_t)n * (size_t)ch;
    for (size_t i = 0; i < count; i++) out[i] = data[i] / 32768.0f;
    free(data);
    *samples = out;
    *frames = n;
    *channels = ch;
    *rate = sr;
    return 0;
}

void cvorbis_free(float *samples) {
    free(samples);
}

void *cvorbis_open(const char *path, int *error) {
    if (!path) return NULL;
    int err = 0;
    stb_vorbis *handle = stb_vorbis_open_filename(path, &err, NULL);
    if (!handle && error) *error = err;
    return handle;
}

int cvorbis_info(void *handle, int *channels, int *rate, long long *frames) {
    if (!handle) return -1;
    stb_vorbis_info info = stb_vorbis_get_info((stb_vorbis *)handle);
    if (channels) *channels = info.channels;
    if (rate) *rate = info.sample_rate;
    if (frames) *frames = (long long)stb_vorbis_stream_length_in_samples((stb_vorbis *)handle);
    return 0;
}

int cvorbis_comment_count(void *handle) {
    if (!handle) return 0;
    stb_vorbis_comment comments = stb_vorbis_get_comment((stb_vorbis *)handle);
    return comments.comment_list_length;
}

const char *cvorbis_comment(void *handle, int index) {
    if (!handle || index < 0) return NULL;
    stb_vorbis_comment comments = stb_vorbis_get_comment((stb_vorbis *)handle);
    if (index >= comments.comment_list_length || !comments.comment_list) return NULL;
    return comments.comment_list[index];
}

void cvorbis_close(void *handle) {
    if (handle) stb_vorbis_close((stb_vorbis *)handle);
}
