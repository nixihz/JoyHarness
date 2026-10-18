#ifndef JOY_HARNESS_OPUS_H
#define JOY_HARNESS_OPUS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpusDecoder JHOpusDecoder;
JHOpusDecoder *jh_opus_decoder_create(int *error);
void jh_opus_decoder_destroy(JHOpusDecoder *decoder);
int jh_opus_decoder_reset(JHOpusDecoder *decoder);
int jh_opus_packet_samples(const uint8_t *packet, int length);
int jh_opus_decode(JHOpusDecoder *decoder, const uint8_t *packet, int length, float *pcm);
const char *jh_opus_error_string(int code);
const char *jh_opus_version(void);
#ifdef __cplusplus
}
#endif
#endif
