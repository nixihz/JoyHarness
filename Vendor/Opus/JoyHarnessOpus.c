// JoyHarness wrapper. The vendored upstream files are unmodified.
#include "JoyHarnessOpus.h"
#include "opus.h"

JHOpusDecoder *jh_opus_decoder_create(int *error) {
    return opus_decoder_create(48000, 1, error);
}
void jh_opus_decoder_destroy(JHOpusDecoder *decoder) {
    opus_decoder_destroy(decoder);
}
int jh_opus_decoder_reset(JHOpusDecoder *decoder) {
    return opus_decoder_ctl(decoder, OPUS_RESET_STATE);
}
int jh_opus_packet_samples(const uint8_t *packet, int length) {
    return opus_packet_get_nb_samples(packet, length, 48000);
}
int jh_opus_decode(JHOpusDecoder *decoder, const uint8_t *packet, int length, float *pcm) {
    return opus_decode_float(decoder, packet, length, pcm, 480, 0);
}
const char *jh_opus_error_string(int code) { return opus_strerror(code); }
const char *jh_opus_version(void) { return opus_get_version_string(); }
