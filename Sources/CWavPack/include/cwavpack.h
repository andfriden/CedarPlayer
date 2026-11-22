#ifndef CWAVPACK_H
#define CWAVPACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CWavpackDecoder CWavpackDecoder;

CWavpackDecoder *cwavpack_open(const char *path);
void cwavpack_close(CWavpackDecoder *decoder);

int cwavpack_info(CWavpackDecoder *decoder, int *channels, int *rate, int *bits,
                  long long *frames, int *is_float, int *is_dsd);

/// Reads up to max_frames interleaved float32 frames. Returns frames read, or -1 on error.
int cwavpack_read(CWavpackDecoder *decoder, float *samples, int max_frames);

/// Returns the length of a text tag, or 0. Writes a NUL-terminated value when buffer is large enough.
int cwavpack_tag(CWavpackDecoder *decoder, const char *key, char *buffer, int size);

/// Returns cover art bytes, allocated with malloc. The caller frees with cwavpack_free.
int cwavpack_cover(CWavpackDecoder *decoder, unsigned char **data);

void cwavpack_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
