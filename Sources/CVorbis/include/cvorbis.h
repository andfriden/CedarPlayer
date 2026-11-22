#ifndef CVORBIS_H
#define CVORBIS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decodes an Ogg Vorbis file into interleaved float32 samples.
/// Returns 0 on success, non-zero on error. The caller must free *samples.
int cvorbis_decode(const char *path, float **samples, int *frames, int *channels, int *rate);

void cvorbis_free(float *samples);

/// Opens a file for metadata/stream inspection. Returns NULL on error.
void *cvorbis_open(const char *path, int *error);

/// Reads stream properties. Frames may be 0 for streams without a known length.
/// Returns 0 on success.
int cvorbis_info(void *handle, int *channels, int *rate, long long *frames);

/// Number of Vorbis comments in the current stream.
int cvorbis_comment_count(void *handle);

/// Returns the comment at index in "KEY=value" form, or NULL.
const char *cvorbis_comment(void *handle, int index);

void cvorbis_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif
