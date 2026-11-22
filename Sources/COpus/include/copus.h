#ifndef COPUS_H
#define COPUS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct COpusDecoder COpusDecoder;

COpusDecoder *copus_open(const char *path);
void copus_close(COpusDecoder *decoder);

int copus_info(COpusDecoder *decoder, int *channels, int *rate, long long *frames);
int copus_read(COpusDecoder *decoder, float *samples, int max_frames);
int copus_tag_count(COpusDecoder *decoder);
const char *copus_tag(COpusDecoder *decoder, int index);

#ifdef __cplusplus
}
#endif

#endif
