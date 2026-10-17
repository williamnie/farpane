// Small CPU-only checks against the newly built static libraries. No desktop,
// GPU, service, hardware audio, or network access is involved.
#include <aom/aom_decoder.h>
#include <aom/aomdx.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
#include <opus/opus.h>
#include <libyuv.h>
#include <turbojpeg.h>
#include <mfx/mfxvideo.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static void require(bool value, const char* message) {
    if (!value) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main() {
    int error = 0;
    OpusEncoder* encoder = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &error);
    require(encoder && error == OPUS_OK, "Opus encoder creation");
    OpusDecoder* decoder = opus_decoder_create(16000, 1, &error);
    require(decoder && error == OPUS_OK, "Opus decoder creation");
    opus_int16 pcm[320] = {}, decoded[320] = {};
    unsigned char packet[4096];
    int length = opus_encode(encoder, pcm, 320, packet, sizeof(packet));
    require(length > 0, "Opus encode");
    require(opus_decode(decoder, packet, length, decoded, 320, 0) == 320, "Opus decode");
    opus_encoder_destroy(encoder); opus_decoder_destroy(decoder);

    unsigned char rgba[16 * 16 * 4], rgb[16 * 16 * 3], y[256], u[64], v[64];
    std::memset(rgba, 255, sizeof(rgba));
    require(libyuv::ARGBToI420(rgba, 16 * 4, y, 16, u, 8, v, 8, 16, 16) == 0,
            "libyuv RGBA conversion");
    require(y[0] == 235 && u[0] == 128 && v[0] == 128, "libyuv white levels");
    std::memset(rgb, 255, sizeof(rgb));
    tjhandle compressor = tjInitCompress(), decompressor = tjInitDecompress();
    require(compressor && decompressor, "JPEG initialization");
    unsigned char* jpeg = nullptr;
    unsigned long size = 0;
    require(tjCompress2(compressor, rgb, 16, 0, 16, TJPF_RGB, &jpeg, &size,
                        TJSAMP_444, 90, 0) == 0 && size > 0, "JPEG encode");
    std::memset(rgb, 0, sizeof(rgb));
    require(tjDecompress2(decompressor, jpeg, size, rgb, 16, 0, 16, TJPF_RGB, 0) == 0,
            "JPEG decode");
    for (unsigned char pixel : rgb) require(pixel >= 254, "JPEG white pixels");
    tjFree(jpeg); tjDestroy(compressor); tjDestroy(decompressor);

    aom_codec_ctx_t aom{};
    aom_codec_dec_cfg_t aom_cfg{};
    aom_cfg.threads = 1;
    require(aom_codec_dec_init(&aom, aom_codec_av1_dx(), &aom_cfg, 0) == AOM_CODEC_OK,
            "AV1 decoder initialization");
    require(aom_codec_destroy(&aom) == AOM_CODEC_OK, "AV1 decoder release");
    vpx_codec_ctx_t vpx{};
    vpx_codec_dec_cfg_t vpx_cfg{};
    vpx_cfg.threads = 1;
    require(vpx_codec_dec_init(&vpx, vpx_codec_vp9_dx(), &vpx_cfg, 0) == VPX_CODEC_OK,
            "VP9 decoder initialization");
    require(vpx_codec_destroy(&vpx) == VPX_CODEC_OK, "VP9 decoder release");
    mfxVersion version{};
    require(MFXQueryVersion(nullptr, &version) == MFX_ERR_INVALID_HANDLE,
            "MFX dispatcher rejects absent session without opening hardware");
    std::printf("PASS Opus PCM roundtrip; libyuv levels; JPEG pixels; AV1/VP9 decoder lifecycle; MFX no-session\n");
    std::printf("%s; AOM %s; VPX %s\n", opus_get_version_string(),
                aom_codec_version_str(), vpx_codec_version_str());
}
