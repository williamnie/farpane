#include "gpu_media.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>
#include <drm_fourcc.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/opt.h>
}

namespace {
using Clock = std::chrono::steady_clock;
constexpr uint64_t max_object = 256ULL * 1024 * 1024;
constexpr size_t max_packet_bytes = 16 * 1024 * 1024;
constexpr int pool_size = 4;

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
void check(int result, const char *operation) {
    if (result < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, error, sizeof(error));
        throw std::runtime_error(std::string(operation) + ": " + error);
    }
}
struct FrameDelete { void operator()(AVFrame *p) const { av_frame_free(&p); } };
using Frame = std::unique_ptr<AVFrame, FrameDelete>;
Frame new_frame() {
    Frame frame(av_frame_alloc());
    require(bool(frame), "frame allocation");
    return frame;
}
void free_descriptor(void *, uint8_t *data) {
    auto *descriptor = reinterpret_cast<AVDRMFrameDescriptor *>(data);
    close(descriptor->objects[0].fd);
    delete descriptor;
}
bool completed(AVFrame *frame, uint32_t timeout_ms) {
    if (!frame || frame->format != AV_PIX_FMT_VAAPI || !frame->hw_frames_ctx) return false;
    auto *frames = reinterpret_cast<AVHWFramesContext *>(frame->hw_frames_ctx->data);
    auto display = static_cast<AVVAAPIDeviceContext *>(frames->device_ctx->hwctx)->display;
    auto surface = static_cast<VASurfaceID>(reinterpret_cast<uintptr_t>(frame->data[3]));
    const auto deadline = Clock::now() + std::chrono::milliseconds(std::min(timeout_ms, 100u));
    do {
        const auto result = vaSyncSurface2(display, surface, 1000000);
        if (result == VA_STATUS_SUCCESS) return true;
        if (result == VA_STATUS_ERROR_UNIMPLEMENTED) {
            VASurfaceStatus state;
            if (vaQuerySurfaceStatus(display, surface, &state) != VA_STATUS_SUCCESS) return false;
            if (state == VASurfaceReady) return true;
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        } else if (result != VA_STATUS_ERROR_TIMEDOUT) {
            return false;
        }
    } while (Clock::now() < deadline);
    return false;
}
}

struct FpGpu {
    AVBufferRef *device = nullptr, *input_frames = nullptr;
    AVFilterGraph *graph = nullptr;
    AVFilterContext *source = nullptr, *sink = nullptr;
    AVCodecContext *encoder = nullptr;
    Frame input, output;
    uint32_t width, height, fourcc;
    bool in_flight = false;
    std::string error;

    FpGpu(uint32_t w, uint32_t h, uint32_t format) : width(w), height(h), fourcc(format) {}
    ~FpGpu() {
        output.reset();
        input.reset();
        avcodec_free_context(&encoder);
        avfilter_graph_free(&graph);
        av_buffer_unref(&input_frames);
        av_buffer_unref(&device);
    }

    void initialize(const char *node, uint32_t kbps, uint32_t fps, uint32_t gop) {
        require(node && width >= 16 && height >= 16 && width <= 8192 && height <= 8192 &&
                !(width % 2) && !(height % 2), "unsupported dimensions");
        require(fourcc == DRM_FORMAT_XRGB8888 || fourcc == DRM_FORMAT_ARGB8888, "unsupported format");
        require(kbps > 0 && kbps <= 1000000 && fps > 0 && fps <= 120 && gop > 0 && gop <= INT32_MAX,
                "invalid encoder parameters");
        check(av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_DRM, node, nullptr, 0), "DRM device");
        input_frames = av_hwframe_ctx_alloc(device);
        require(input_frames, "DRM frames allocation");
        auto *frames = reinterpret_cast<AVHWFramesContext *>(input_frames->data);
        frames->format = AV_PIX_FMT_DRM_PRIME;
        frames->sw_format = fourcc == DRM_FORMAT_ARGB8888 ? AV_PIX_FMT_BGRA : AV_PIX_FMT_BGR0;
        frames->width = width;
        frames->height = height;
        check(av_hwframe_ctx_init(input_frames), "DRM frames init");
        graph = avfilter_graph_alloc();
        require(graph, "filter graph allocation");
        graph->nb_threads = 1;
        source = avfilter_graph_alloc_filter(graph, avfilter_get_by_name("buffer"), "source");
        require(source, "filter source allocation");
        auto *parameters = av_buffersrc_parameters_alloc();
        require(parameters, "source parameters allocation");
        parameters->hw_frames_ctx = av_buffer_ref(input_frames);
        parameters->color_space = AVCOL_SPC_RGB;
        parameters->color_range = AVCOL_RANGE_JPEG;
        const int result = av_buffersrc_parameters_set(source, parameters);
        av_buffer_unref(&parameters->hw_frames_ctx);
        av_free(parameters);
        check(result, "source parameters");
        const auto args = "video_size=" + std::to_string(width) + "x" + std::to_string(height) +
            ":pix_fmt=" + std::to_string(AV_PIX_FMT_DRM_PRIME) + ":time_base=1/1000:pixel_aspect=1/1";
        check(avfilter_init_str(source, args.c_str()), "source init");
        AVFilterContext *map = nullptr, *scale = nullptr;
        check(avfilter_graph_create_filter(&map, avfilter_get_by_name("hwmap"), "direct",
            "derive_device=vaapi:mode=read+direct", nullptr, graph), "direct hardware map");
        check(avfilter_graph_create_filter(&scale, avfilter_get_by_name("scale_vaapi"), "nv12",
            "pool_size=4:format=nv12:out_color_matrix=smpte170m:out_range=limited:"
            "out_color_primaries=smpte170m:out_color_transfer=smpte170m:out_chroma_location=left",
            nullptr, graph), "VAAPI conversion");
        check(avfilter_graph_create_filter(&sink, avfilter_get_by_name("buffersink"), "sink",
            nullptr, nullptr, graph), "filter sink");
        check(avfilter_link(source, 0, map, 0), "source link");
        check(avfilter_link(map, 0, scale, 0), "map link");
        check(avfilter_link(scale, 0, sink, 0), "sink link");
        check(avfilter_graph_config(graph, nullptr), "graph config");
        auto *pool = av_buffersink_get_hw_frames_ctx(sink);
        require(pool, "missing output frames");
        auto *output_frames = reinterpret_cast<AVHWFramesContext *>(pool->data);
        require(output_frames->initial_pool_size == pool_size &&
            static_cast<AVVAAPIFramesContext *>(output_frames->hwctx)->nb_surfaces == pool_size,
            "VAAPI pool is not bounded");
        auto *codec = avcodec_find_encoder_by_name("h264_vaapi");
        require(codec, "H264 VAAPI unavailable");
        encoder = avcodec_alloc_context3(codec);
        require(encoder, "encoder allocation");
        encoder->width = width;
        encoder->height = height;
        encoder->pix_fmt = AV_PIX_FMT_VAAPI;
        encoder->time_base = {1, 1000};
        encoder->framerate = {static_cast<int>(fps), 1};
        encoder->max_b_frames = 0;
        encoder->gop_size = static_cast<int>(gop);
        encoder->profile = AV_PROFILE_H264_HIGH;
        encoder->thread_count = 1;
        encoder->bit_rate = static_cast<int64_t>(kbps) * 1000;
        encoder->rc_max_rate = encoder->bit_rate;
        encoder->rc_buffer_size = static_cast<int>(std::min<int64_t>(encoder->bit_rate, INT32_MAX));
        encoder->color_range = AVCOL_RANGE_MPEG;
        encoder->colorspace = AVCOL_SPC_SMPTE170M;
        encoder->color_primaries = AVCOL_PRI_SMPTE170M;
        encoder->color_trc = AVCOL_TRC_SMPTE170M;
        encoder->chroma_sample_location = AVCHROMA_LOC_LEFT;
        encoder->hw_frames_ctx = av_buffer_ref(pool);
        require(encoder->hw_frames_ctx, "encoder frame pool reference");
        check(av_opt_set(encoder->priv_data, "rc_mode", "CBR", 0), "CBR");
        check(av_opt_set_int(encoder->priv_data, "async_depth", 1, 0), "async depth");
        check(avcodec_open2(encoder, codec, nullptr), "encoder open");
    }

    void convert(const FpGpuFrame &frame, int64_t pts) {
        require(!in_flight && !input && !output, "previous output still owned");
        require(fp_gpu_validate(&frame) && frame.width == width && frame.height == height &&
                frame.fourcc == fourcc, "invalid or changed source descriptor");
        input = new_frame();
        output = new_frame();
        auto descriptor = std::make_unique<AVDRMFrameDescriptor>();
        descriptor->nb_objects = descriptor->nb_layers = 1;
        auto &object = descriptor->objects[0];
        object.fd = fcntl(frame.fd, F_DUPFD_CLOEXEC, 0);
        require(object.fd >= 0, "source FD duplication");
        object.size = frame.size;
        object.format_modifier = frame.modifier;
        auto &layer = descriptor->layers[0];
        layer.format = frame.fourcc;
        layer.nb_planes = 1;
        layer.planes[0].object_index = 0;
        layer.planes[0].pitch = frame.pitch;
        layer.planes[0].offset = frame.offset;
        input->buf[0] = av_buffer_create(reinterpret_cast<uint8_t *>(descriptor.get()),
            sizeof(AVDRMFrameDescriptor), free_descriptor, nullptr, 0);
        if (!input->buf[0]) {
            close(object.fd);
            throw std::runtime_error("source buffer allocation");
        }
        descriptor.release();
        input->data[0] = input->buf[0]->data;
        input->hw_frames_ctx = av_buffer_ref(input_frames);
        require(input->hw_frames_ctx, "source frame reference");
        input->format = AV_PIX_FMT_DRM_PRIME;
        input->width = width;
        input->height = height;
        input->pts = pts;
        input->colorspace = AVCOL_SPC_RGB;
        input->color_range = AVCOL_RANGE_JPEG;
        input->color_primaries = AVCOL_PRI_SMPTE170M;
        input->color_trc = AVCOL_TRC_SMPTE170M;
        // From this point an error must not free the source until completion is known.
        in_flight = true;
        check(av_buffersrc_add_frame_flags(source, input.get(), AV_BUFFERSRC_FLAG_KEEP_REF), "source submit");
        check(av_buffersink_get_frame(sink, output.get()), "VPP output");
        require(output->format == AV_PIX_FMT_VAAPI, "unexpected software output");
        require(fp_gpu_source_done(this, 100) == 1, "source completion timeout");
    }
};

extern "C" int fp_gpu_validate(const FpGpuFrame *frame) {
    if (!frame || frame->fd < 0 || frame->width < 16 || frame->height < 16 ||
        frame->width > 8192 || frame->height > 8192 || frame->width % 2 || frame->height % 2 ||
        (frame->fourcc != DRM_FORMAT_XRGB8888 && frame->fourcc != DRM_FORMAT_ARGB8888) ||
        (frame->modifier != DRM_FORMAT_MOD_LINEAR && frame->modifier != DRM_FORMAT_MOD_INVALID) ||
        frame->size == 0 || frame->size > max_object || frame->pitch < uint64_t(frame->width) * 4)
        return 0;
    const uint64_t end = uint64_t(frame->offset) + uint64_t(frame->pitch) * (frame->height - 1) +
        uint64_t(frame->width) * 4;
    if (end > frame->size) return 0;
    const off_t actual = lseek(frame->fd, 0, SEEK_END);
    return actual > 0 && static_cast<uint64_t>(actual) >= frame->size;
}

extern "C" FpGpu *fp_gpu_create(const char *node, uint32_t w, uint32_t h, uint32_t fourcc,
    uint32_t kbps, uint32_t fps, uint32_t gop, char *error, size_t capacity) {
    try {
        auto ctx = std::make_unique<FpGpu>(w, h, fourcc);
        ctx->initialize(node, kbps, fps, gop);
        return ctx.release();
    } catch (const std::exception &failure) {
        if (error && capacity) std::snprintf(error, capacity, "%s", failure.what());
        return nullptr;
    }
}
extern "C" int fp_gpu_convert(FpGpu *ctx, const FpGpuFrame *frame, int64_t pts) {
    if (!ctx || !frame) return -1;
    try { ctx->convert(*frame, pts); return 0; }
    catch (const std::exception &failure) { ctx->error = failure.what(); return -1; }
}
extern "C" int fp_gpu_source_done(FpGpu *ctx, uint32_t timeout_ms) {
    if (!ctx) return 0;
    if (!ctx->in_flight) return 1;
    if (!completed(ctx->output.get(), timeout_ms)) return 0;
    ctx->input.reset();
    ctx->in_flight = false;
    return 1;
}
extern "C" int fp_gpu_encode(FpGpu *ctx, FpPacketFn callback, void *opaque) {
    if (!ctx || !callback) return -1;
    AVPacket *packet = nullptr;
    try {
        require(!ctx->in_flight && bool(ctx->output), "encoding before source completion");
        check(avcodec_send_frame(ctx->encoder, ctx->output.get()), "encoder submit");
        ctx->output.reset();
        packet = av_packet_alloc();
        require(packet, "packet allocation");
        const auto deadline = Clock::now() + std::chrono::milliseconds(100);
        size_t bytes = 0;
        int count = 0;
        for (;;) {
            const int result = avcodec_receive_packet(ctx->encoder, packet);
            if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) break;
            check(result, "receive encoded packet");
            bytes += static_cast<size_t>(std::max(packet->size, 0));
            require(++count <= 4 && bytes <= max_packet_bytes && Clock::now() < deadline,
                    "encoded packet budget exceeded");
            require(callback(opaque, packet->data, packet->size, packet->pts,
                    (packet->flags & AV_PKT_FLAG_KEY) != 0) == 0, "packet consumer failed");
            av_packet_unref(packet);
        }
        require(count > 0, "latency-free encoder produced no packet");
        av_packet_free(&packet);
        return 0;
    } catch (const std::exception &failure) {
        av_packet_free(&packet);
        ctx->error = failure.what();
        return -1;
    }
}
extern "C" const char *fp_gpu_error(const FpGpu *ctx) {
    return ctx ? ctx->error.c_str() : "missing GPU context";
}
extern "C" int fp_gpu_destroy(FpGpu *ctx) {
    if (!ctx) return 1;
    if (!fp_gpu_source_done(ctx, 1)) return 0;
    delete ctx;
    return 1;
}
extern "C" int fp_gpu_read_rgba(const FpGpuFrame *frame, uint8_t *rgba, size_t length) {
    // An implicit layout can be tiled; only the driver may turn it into CPU pixels.
    if (!fp_gpu_validate(frame) || frame->modifier != DRM_FORMAT_MOD_LINEAR ||
        !rgba || length != uint64_t(frame->width) * frame->height * 4) return -1;
    dma_buf_sync sync{DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
    if (ioctl(frame->fd, DMA_BUF_IOCTL_SYNC, &sync) < 0) return -1;
    void *mapped = mmap(nullptr, frame->size, PROT_READ, MAP_SHARED, frame->fd, 0);
    if (mapped != MAP_FAILED) {
        const auto *source = static_cast<const uint8_t *>(mapped) + frame->offset;
        for (uint32_t y = 0; y < frame->height; ++y) {
            const auto *row = source + size_t(y) * frame->pitch;
            auto *target = rgba + size_t(y) * frame->width * 4;
            for (uint32_t x = 0; x < frame->width; ++x) {
                target[x * 4] = row[x * 4 + 2];
                target[x * 4 + 1] = row[x * 4 + 1];
                target[x * 4 + 2] = row[x * 4];
                target[x * 4 + 3] = 255;
            }
        }
        munmap(mapped, frame->size);
    }
    sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ;
    const int result = ioctl(frame->fd, DMA_BUF_IOCTL_SYNC, &sync);
    return mapped != MAP_FAILED && result == 0 ? 0 : -1;
}
