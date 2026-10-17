#include "viewer_decode.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <thread>
#include <vector>
#include <unistd.h>
#include <drm_fourcc.h>
#include <libyuv.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/hwcontext_vaapi.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
}
static_assert(sizeof(FpViewerFrame) == 200, "Viewer FFI frame ABI");
static_assert(offsetof(FpViewerFrame, matrix) == 176, "Viewer FFI color offset");

namespace {
constexpr int lease_limit = 3;
// 16 reference surfaces + 4 decode/work surfaces + 3 exported references.
// FFmpeg VAAPI's nonzero initial_pool_size is a hard allocation limit.
constexpr int surface_limit = 16 + 4 + lease_limit;
constexpr int64_t pixel_limit = 2560LL * 1600;
constexpr size_t packet_limit = 16 * 1024 * 1024;
using Clock = std::chrono::steady_clock;
void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
void check(int value, const char *operation) {
    if (value < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(value, error, sizeof(error));
        throw std::runtime_error(std::string(operation) + ": " + error);
    }
}
struct FrameDelete { void operator()(AVFrame *p) const { av_frame_free(&p); } };
using Frame = std::unique_ptr<AVFrame, FrameDelete>;
Frame frame() {
    Frame result(av_frame_alloc());
    require(bool(result), "Viewer frame allocation failed");
    return result;
}
struct PacketDelete { void operator()(AVPacket *p) const { av_packet_free(&p); } };
using Packet = std::unique_ptr<AVPacket, PacketDelete>;
struct Lease { Frame source, mapped; std::vector<uint8_t> pixels; };

void validate_color(const AVFrame *source) {
    require(source->crop_left == 0 && source->crop_top == 0,
            "Viewer requires an uncropped surface origin");
    require(source->color_trc != AVCOL_TRC_SMPTE2084 && source->color_trc != AVCOL_TRC_ARIB_STD_B67,
            "HDR is unavailable in the SDR Viewer");
    require(source->colorspace == AVCOL_SPC_BT709 || source->colorspace == AVCOL_SPC_SMPTE170M ||
            source->colorspace == AVCOL_SPC_BT470BG || source->colorspace == AVCOL_SPC_UNSPECIFIED,
            "Unsupported Viewer color matrix");
}

bool completed(AVFrame *source) {
    const auto *frames = reinterpret_cast<AVHWFramesContext *>(source->hw_frames_ctx->data);
    const auto display = static_cast<AVVAAPIDeviceContext *>(frames->device_ctx->hwctx)->display;
    const auto surface = static_cast<VASurfaceID>(reinterpret_cast<uintptr_t>(source->data[3]));
    const auto deadline = Clock::now() + std::chrono::milliseconds(100);
    do {
        auto result = vaSyncSurface2(display, surface, 1000000);
        if (result == VA_STATUS_SUCCESS) return true;
        if (result == VA_STATUS_ERROR_UNIMPLEMENTED) {
            VASurfaceStatus status;
            if (vaQuerySurfaceStatus(display, surface, &status) != VA_STATUS_SUCCESS) return false;
            if (status == VASurfaceReady) return true;
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        } else if (result != VA_STATUS_ERROR_TIMEDOUT) return false;
    } while (Clock::now() < deadline);
    return false;
}
}

struct FpViewerDecoder {
    AVBufferRef *drm = nullptr, *device = nullptr;
    AVCodecContext *decoder = nullptr;
    std::map<uint64_t, Lease> leases;
    uint64_t next = 0;
    bool hardware = true, initialized = false, failed = false;
    std::string error;
    vpx_codec_ctx_t vpx{};
    vpx_codec_iface_t *vpx_interface = nullptr;
    vpx_codec_iter_t vpx_iterator = nullptr;
    bool vpx_ready = false, vpx_output = false, vpx_first = true;
    int vpx_codec = 0;
    int64_t vpx_pts = 0;
    size_t vpx_bytes = 0;
    static int allocate_vpx(void *opaque, size_t size, vpx_codec_frame_buffer_t *buffer) {
        auto &self = *static_cast<FpViewerDecoder *>(opaque);
        // VP9 references and work buffers share one hard allocation budget.
        if (!size || size > 16 * 1024 * 1024 || self.vpx_bytes + size > 96 * 1024 * 1024) return -1;
        auto *data = static_cast<uint8_t *>(std::calloc(1, size));
        if (!data) return -1;
        buffer->data = data; buffer->size = size; buffer->priv = data;
        self.vpx_bytes += size;
        return 0;
    }
    static int release_vpx(void *opaque, vpx_codec_frame_buffer_t *buffer) {
        auto &self = *static_cast<FpViewerDecoder *>(opaque);
        if (buffer->priv) {
            self.vpx_bytes -= buffer->size;
            std::free(buffer->priv); buffer->priv = nullptr; buffer->data = nullptr; buffer->size = 0;
        }
        return 0;
    }
    ~FpViewerDecoder() {
        // No further decode is allowed. Export/import kernel references remain
        // valid after this generation is destroyed; they never enter a new pool.
        avcodec_free_context(&decoder);
        if (vpx_ready) vpx_codec_destroy(&vpx);
        leases.clear();
        av_buffer_unref(&device);
        av_buffer_unref(&drm);
    }
    static AVPixelFormat format(AVCodecContext *avctx, const AVPixelFormat *formats) {
        auto &self = *static_cast<FpViewerDecoder *>(avctx->opaque);
        AVBufferRef *frames_ref = nullptr;
        try {
            if (!self.hardware) {
                for (const auto *f = formats; *f != AV_PIX_FMT_NONE; ++f)
                    if (*f == AV_PIX_FMT_YUV420P || *f == AV_PIX_FMT_YUVJ420P) return *f;
                throw std::runtime_error("Software Viewer requires 8-bit YUV420 output");
            }
            require(!self.initialized, "Viewer format changed; drain and create a new generation");
            require(avctx->coded_width > 0 && avctx->coded_height > 0 &&
                    int64_t(avctx->coded_width) * avctx->coded_height <= pixel_limit,
                    "Viewer dimensions exceed the current surface budget");
            bool offered = false;
            for (const auto *f = formats; *f != AV_PIX_FMT_NONE; ++f) offered |= *f == AV_PIX_FMT_VAAPI;
            require(offered, "Codec has no VAAPI output");
            check(avcodec_get_hw_frames_parameters(avctx, self.device, AV_PIX_FMT_VAAPI,
                                                   &frames_ref), "VAAPI frame parameters");
            auto *frames = reinterpret_cast<AVHWFramesContext *>(frames_ref->data);
            require(frames->sw_format == AV_PIX_FMT_NV12, "Viewer requires 8-bit NV12 output");
            require(frames->width > 0 && frames->height > 0 &&
                    int64_t(frames->width) * frames->height <= pixel_limit,
                    "Aligned Viewer dimensions exceed the current surface budget");
            require(frames->initial_pool_size <= surface_limit, "Codec surface requirement exceeds budget");
            frames->initial_pool_size = surface_limit;
            check(av_hwframe_ctx_init(frames_ref), "VAAPI surface pool");
            av_buffer_unref(&avctx->hw_frames_ctx);
            avctx->hw_frames_ctx = frames_ref;
            self.initialized = true;
            return AV_PIX_FMT_VAAPI;
        } catch (const std::exception &e) {
            av_buffer_unref(&frames_ref);
            self.error = e.what(); self.failed = true;
            return AV_PIX_FMT_NONE;
        }
    }
    void initialize(int fd, int codec) {
        if (!hardware && (codec == 3 || codec == 4)) {
            vpx_codec = codec;
            vpx_interface = codec == 3 ? vpx_codec_vp8_dx() : vpx_codec_vp9_dx();
            vpx_codec_dec_cfg_t config{}; config.threads = 1;
            require(vpx_codec_dec_init(&vpx, vpx_interface, &config, 0) == VPX_CODEC_OK, "VPx decoder initialization failed");
            vpx_ready = true;
            if (codec == 4) require(vpx_codec_set_frame_buffer_functions(&vpx, allocate_vpx, release_vpx, this) == VPX_CODEC_OK,
                    "VP9 bounded frame buffers unavailable");
            return;
        }
        require(codec == 1 || codec == 2, "Unsupported Viewer codec");
        if (hardware) {
        struct stat metadata;
        require(fd >= 0 && fstat(fd, &metadata) == 0 && S_ISCHR(metadata.st_mode) &&
                major(metadata.st_rdev) == 226 && minor(metadata.st_rdev) >= 128 &&
                minor(metadata.st_rdev) <= 255, "Viewer requires a DRM render descriptor");
        drm = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_DRM);
        require(drm, "DRM device allocation failed");
        auto *hw = reinterpret_cast<AVDRMDeviceContext *>(reinterpret_cast<AVHWDeviceContext *>(drm->data)->hwctx);
        hw->fd = fcntl(fd, F_DUPFD_CLOEXEC, 3);
        require(hw->fd >= 0, "DRM descriptor duplication failed");
        check(av_hwdevice_ctx_init(drm), "DRM device initialization");
        check(av_hwdevice_ctx_create_derived(&device, AV_HWDEVICE_TYPE_VAAPI, drm, 0), "VAAPI device derivation");
        }
        const auto *implementation = avcodec_find_decoder(codec == 1 ? AV_CODEC_ID_H264 : AV_CODEC_ID_HEVC);
        require(implementation, "Pinned FFmpeg does not contain this decoder");
        decoder = avcodec_alloc_context3(implementation);
        require(decoder, "Viewer decoder allocation failed");
        if (hardware) {
            decoder->hw_device_ctx = av_buffer_ref(device);
            require(decoder->hw_device_ctx, "VAAPI device reference failed");
        }
        decoder->opaque = this;
        decoder->get_format = format;
        decoder->thread_count = 1;
        decoder->thread_type = 0;
        decoder->extra_hw_frames = lease_limit;
        decoder->max_pixels = pixel_limit;
        decoder->pkt_timebase = AVRational{1, 1000};
        check(avcodec_open2(decoder, implementation, nullptr), "Viewer decoder open");
    }
};

extern "C" FpViewerDecoder *fp_viewer_create(int fd, int codec, char *error, size_t size) {
    try {
        auto context = std::make_unique<FpViewerDecoder>();
        context->initialize(fd, codec);
        return context.release();
    } catch (const std::exception &e) {
        if (error && size) std::snprintf(error, size, "%s", e.what());
        return nullptr;
    }
}
extern "C" FpViewerDecoder *fp_viewer_create_software(int codec, char *error, size_t size) {
    try {
        auto context = std::make_unique<FpViewerDecoder>();
        context->hardware = false;
        context->initialize(-1, codec);
        return context.release();
    } catch (const std::exception &e) {
        if (error && size) std::snprintf(error, size, "%s", e.what());
        return nullptr;
    }
}
extern "C" int fp_viewer_send(FpViewerDecoder *ctx, const uint8_t *data, size_t length, int64_t pts) {
    if (!ctx || ctx->failed) return -1;
    try {
        require(data && length && length <= packet_limit, "Invalid Viewer compressed packet length");
        if (ctx->vpx_ready) {
            if (ctx->vpx_output) return 1;
            vpx_codec_stream_info_t info{}; info.sz = sizeof(info);
            const auto peek = vpx_codec_peek_stream_info(ctx->vpx_interface, data, unsigned(length), &info);
            // VP8 can resize only on keyframes. Validate those before libvpx
            // allocates its internal reference pool. VP9 also has hard callbacks.
            const bool key = ctx->vpx_codec == 3 && !(data[0] & 1);
            if (ctx->vpx_first || key || (peek == VPX_CODEC_OK && info.w && info.h)) {
                require(peek == VPX_CODEC_OK && info.w && info.h && info.w <= 8192 && info.h <= 8192 &&
                        int64_t(info.w) * info.h <= pixel_limit, "VPx header exceeds Viewer pixel budget or lacks a keyframe");
            }
            require(vpx_codec_decode(&ctx->vpx, data, unsigned(length), nullptr, 0) == VPX_CODEC_OK, "VPx packet decode failed");
            ctx->vpx_first = false; ctx->vpx_output = true; ctx->vpx_iterator = nullptr; ctx->vpx_pts = pts;
            return 0;
        }
        Packet packet(av_packet_alloc());
        require(bool(packet), "Viewer packet allocation failed");
        check(av_new_packet(packet.get(), int(length)), "Viewer packet allocation");
        // av_new_packet includes AV_INPUT_BUFFER_PADDING_SIZE zeroed bytes.
        std::memcpy(packet->data, data, length); packet->pts = pts; packet->dts = AV_NOPTS_VALUE;
        const auto result = avcodec_send_packet(ctx->decoder, packet.get());
        if (result == AVERROR(EAGAIN)) return 1;
        if (ctx->failed) return -1; // Preserve the specific get_format failure.
        check(result, "Viewer packet decode");
        return 0;
    } catch (const std::exception &e) { ctx->error = e.what(); ctx->failed = true; return -1; }
}
extern "C" int fp_viewer_receive(FpViewerDecoder *ctx, FpViewerFrame *out) {
    if (!ctx || ctx->failed || !out || !ctx->hardware) return -1;
    if (ctx->leases.size() >= lease_limit) return 2;
    try {
        Lease lease{frame(), frame(), {}};
        const auto result = avcodec_receive_frame(ctx->decoder, lease.source.get());
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 1;
        if (ctx->failed) return -1;
        check(result, "Viewer output decode");
        auto *source = lease.source.get();
        require(source->format == AV_PIX_FMT_VAAPI && source->hw_frames_ctx,
                "Viewer output is not a VAAPI frame");
        validate_color(source);
        require(source->chroma_location == AVCHROMA_LOC_LEFT || source->chroma_location == AVCHROMA_LOC_CENTER ||
                source->chroma_location == AVCHROMA_LOC_UNSPECIFIED, "Unsupported Viewer chroma location");
        require(completed(source), "Viewer decode completion deadline exceeded");
        lease.mapped->format = AV_PIX_FMT_DRM_PRIME;
        // The pinned READ map repeats vaSyncSurface before separate-layer export.
        // A worker watchdog must cover driver calls; this is not a hard syscall timeout.
        check(av_hwframe_map(lease.mapped.get(), source, AV_HWFRAME_MAP_READ), "VAAPI DRM_PRIME export");
        const auto *desc = reinterpret_cast<AVDRMFrameDescriptor *>(lease.mapped->data[0]);
        require(desc && desc->nb_objects > 0 && desc->nb_objects <= 4 && desc->nb_layers == 2,
                "Unsupported Viewer DRM descriptor layout");
        FpViewerFrame value{};
        value.lease = ctx->next + 1;
        require(value.lease != 0, "Viewer lease id exhausted");
        value.pts = source->pts; value.width = source->width; value.height = source->height;
        value.object_count = desc->nb_objects; value.pool_size = surface_limit;
        value.matrix = source->colorspace; value.range = source->color_range;
        value.primaries = source->color_primaries; value.transfer = source->color_trc;
        value.chroma = source->chroma_location;
        for (int i = 0; i < desc->nb_objects; ++i) {
            require(desc->objects[i].fd >= 0, "Invalid Viewer exported descriptor");
            const auto flags = fcntl(desc->objects[i].fd, F_GETFD);
            require(flags >= 0 && fcntl(desc->objects[i].fd, F_SETFD, flags | FD_CLOEXEC) == 0,
                    "Viewer exported descriptor CLOEXEC failed");
            value.objects[i] = FpViewerObject{desc->objects[i].fd, 0, desc->objects[i].size, desc->objects[i].format_modifier};
        }
        for (int i = 0; i < 2; ++i) {
            const auto &layer = desc->layers[i];
            require(layer.nb_planes == 1 && layer.format == (i == 0 ? DRM_FORMAT_R8 : DRM_FORMAT_GR88),
                    "Viewer requires separate R8 and GR88 layers");
            const auto &plane = layer.planes[0];
            require(plane.object_index >= 0 && plane.object_index < desc->nb_objects &&
                    plane.pitch > 0 && plane.offset >= 0, "Invalid Viewer plane metadata");
            value.layers[i] = FpViewerLayer{layer.format, uint32_t(plane.object_index), uint32_t(plane.pitch), 0, uint64_t(plane.offset)};
        }
        ctx->leases.emplace(value.lease, std::move(lease));
        ctx->next = value.lease;
        *out = value;
        return 0;
    } catch (const std::exception &e) { ctx->error = e.what(); ctx->failed = true; return -1; }
}
extern "C" int fp_viewer_receive_software(FpViewerDecoder *ctx, FpViewerCpuFrame *out) {
    if (!ctx || ctx->failed || !out || ctx->hardware) return -1;
    if (ctx->leases.size() >= lease_limit) return 2;
    try {
        if (ctx->vpx_ready) {
            if (!ctx->vpx_output) return 1;
            const auto *image = vpx_codec_get_frame(&ctx->vpx, &ctx->vpx_iterator);
            if (!image) { ctx->vpx_output = false; return 1; }
            require(image->fmt == VPX_IMG_FMT_I420 && image->bit_depth == 8 && image->d_w && image->d_h &&
                    image->d_w <= 8192 && image->d_h <= 8192 && int64_t(image->d_w) * image->d_h <= pixel_limit,
                    "VPx Viewer requires bounded 8-bit I420 output");
            require(image->cs == VPX_CS_UNKNOWN || image->cs == VPX_CS_BT_601 || image->cs == VPX_CS_BT_709 ||
                    image->cs == VPX_CS_SMPTE_170 || image->cs == VPX_CS_SMPTE_240, "Unsupported VPx color space");
            // SMPTE 240 has a different matrix: reject rather than silently tint.
            require(image->cs != VPX_CS_SMPTE_240, "SMPTE 240 color is unavailable");
            const bool full = image->range == VPX_CR_FULL_RANGE;
            const bool hd = image->cs == VPX_CS_BT_709 || (image->cs == VPX_CS_UNKNOWN && image->d_h > 576);
            const auto *matrix = hd ? (full ? &libyuv::kYuvF709Constants : &libyuv::kYuvH709Constants)
                                    : (full ? &libyuv::kYuvJPEGConstants : &libyuv::kYuvI601Constants);
            Lease lease{};
            const auto stride = image->d_w * 4;
            lease.pixels.resize(size_t(stride) * image->d_h);
            check(libyuv::I420ToARGBMatrix(image->planes[0], image->stride[0], image->planes[1], image->stride[1],
                image->planes[2], image->stride[2], lease.pixels.data(), int(stride), matrix, int(image->d_w), int(image->d_h)),
                "VPx Viewer color conversion");
            FpViewerCpuFrame value{ctx->next + 1, ctx->vpx_pts, image->d_w, image->d_h, stride, 0, lease.pixels.data(), lease.pixels.size()};
            require(value.lease != 0, "Viewer lease id exhausted");
            ctx->leases.emplace(value.lease, std::move(lease)); ctx->next = value.lease; *out = value;
            return 0;
        }
        Lease lease{frame(), {}, {}};
        const auto result = avcodec_receive_frame(ctx->decoder, lease.source.get());
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 1;
        if (ctx->failed) return -1;
        check(result, "Software Viewer output decode");
        const auto *source = lease.source.get();
        require(source->format == AV_PIX_FMT_YUV420P || source->format == AV_PIX_FMT_YUVJ420P,
                "Software Viewer output is not 8-bit YUV420");
        require(source->width > 0 && source->height > 0 &&
                int64_t(source->width) * source->height <= pixel_limit, "Software Viewer exceeds pixel budget");
        validate_color(source);
        const bool full = source->color_range == AVCOL_RANGE_JPEG || source->format == AV_PIX_FMT_YUVJ420P;
        const bool hd = source->colorspace == AVCOL_SPC_BT709 ||
            (source->colorspace == AVCOL_SPC_UNSPECIFIED && source->height > 576);
        const auto *matrix = hd ? (full ? &libyuv::kYuvF709Constants : &libyuv::kYuvH709Constants)
                                : (full ? &libyuv::kYuvJPEGConstants : &libyuv::kYuvI601Constants);
        const auto stride = uint32_t(source->width) * 4;
        lease.pixels.resize(size_t(stride) * source->height);
        check(libyuv::I420ToARGBMatrix(source->data[0], source->linesize[0], source->data[1], source->linesize[1],
            source->data[2], source->linesize[2], lease.pixels.data(), int(stride), matrix, source->width, source->height),
            "Software Viewer color conversion");
        FpViewerCpuFrame value{ctx->next + 1, source->pts, uint32_t(source->width), uint32_t(source->height), stride, 0,
            lease.pixels.data(), lease.pixels.size()};
        require(value.lease != 0, "Viewer lease id exhausted");
        ctx->leases.emplace(value.lease, std::move(lease));
        ctx->next = value.lease; *out = value;
        return 0;
    } catch (const std::exception &e) { ctx->error = e.what(); ctx->failed = true; return -1; }
}
extern "C" int fp_viewer_release(FpViewerDecoder *ctx, uint64_t lease) {
    return ctx && lease && ctx->leases.erase(lease) == 1 ? 0 : -1;
}
extern "C" const char *fp_viewer_error(const FpViewerDecoder *ctx) {
    return ctx ? ctx->error.c_str() : "Viewer decoder is unavailable";
}
extern "C" void fp_viewer_destroy(FpViewerDecoder *ctx) { delete ctx; }
