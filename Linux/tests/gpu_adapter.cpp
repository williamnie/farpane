// Reuse the synthetic fixtures; exercise the product C ABI, not the P0 pipeline.
#define main p0_fixture_main
#include "p0_media.cpp"
#undef main
#include "../src/gpu_media.h"
#include <gbm.h>

struct TiledSource {
    int render = -1, fd = -1;
    gbm_device *device = nullptr;
    gbm_bo *bo = nullptr;
    TiledSource(uint32_t format) {
        render = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
        require(render >= 0, "tiled render node");
        device = gbm_create_device(render); require(device, "GBM device");
        bo = gbm_bo_create(device, W, H, format, GBM_BO_USE_RENDERING | GBM_BO_USE_SCANOUT);
        require(bo && gbm_bo_get_plane_count(bo) == 1 && gbm_bo_get_modifier(bo) != 0,
                "expected single-plane tiled fixture");
        fd = gbm_bo_get_fd(bo); require(fd >= 0, "GBM export");
        amdgpu_device_handle amd = nullptr; uint32_t major, minor;
        check(amdgpu_device_initialize(render, &major, &minor, &amd), "GBM metadata device");
        amdgpu_bo_import_result imported{};
        check(amdgpu_bo_import(amd, amdgpu_bo_handle_type_dma_buf_fd, fd, &imported), "GBM metadata import");
        amdgpu_bo_info info{};
        check(amdgpu_bo_query_info(imported.buf_handle, &info), "GBM metadata query");
        check(amdgpu_bo_free(imported.buf_handle), "GBM metadata release");
        check(amdgpu_device_deinitialize(amd), "GBM metadata device release");
        require(AMDGPU_TILING_GET(info.metadata.tiling_info, SWIZZLE_MODE) != 0,
                "fixture must actually be tiled, not just omit its modifier");
        printf("tiled_fixture tiling_info=%#llx\n", (unsigned long long)info.metadata.tiling_info);
        printf("tiled_fixture modifier=%#llx pitch=%u size=%lld\n",
            (unsigned long long)gbm_bo_get_modifier(bo), gbm_bo_get_stride(bo),
            (long long)lseek(fd, 0, SEEK_END));
    }
    void stamp(const Source &source, int n) {
        uint32_t stride = 0; void *token = nullptr;
        auto *p = static_cast<uint8_t *>(gbm_bo_map(bo, 0, 0, W, H, GBM_BO_TRANSFER_WRITE, &stride, &token));
        require(p, "GBM upload map");
        for (int y = 0; y < H; ++y) memcpy(p + y * stride, source.bgra.data() + y * W * 4, W * 4);
        for (int y = 64; y < 80; ++y) for (int x = 0; x < W; ++x) {
            auto *pixel = p + y * stride + x * 4;
            pixel[0] = pixel[1] = pixel[2] = ((n >> (x / 32)) & 1) ? 255 : 0;
        }
        gbm_bo_unmap(bo, token);
    }
    ~TiledSource() {
        if (fd >= 0) close(fd);
        if (bo) gbm_bo_destroy(bo);
        if (device) gbm_device_destroy(device);
        if (render >= 0) close(render);
    }
};

struct Packets {
    std::vector<std::vector<uint8_t>> bytes;
    std::vector<int64_t> pts;
    std::vector<int> keys;
};
int collect(void *opaque, const uint8_t *data, size_t size, int64_t pts, int key) {
    auto &out = *static_cast<Packets *>(opaque);
    out.bytes.emplace_back(data, data + size);
    out.pts.push_back(pts);
    out.keys.push_back(key);
    return 0;
}

int main() {
    try {
        const int baseline = fd_count();
        for (bool implicit : {false, true}) for (bool alpha : {false, true}) {
            Source source(alpha);
            FpGpuFrame desc{source.export_fd, W, H,
                alpha ? DRM_FORMAT_ARGB8888 : DRM_FORMAT_XRGB8888, source.stride, 0, source.stride * H, 0};
            std::unique_ptr<TiledSource> tiled;
            if (implicit) {
                tiled = std::make_unique<TiledSource>(desc.fourcc);
                desc.fd = tiled->fd;
                desc.pitch = gbm_bo_get_stride(tiled->bo);
                desc.size = lseek(desc.fd, 0, SEEK_END);
                desc.modifier = DRM_FORMAT_MOD_INVALID;
            }
            require(fp_gpu_validate(&desc), "product rejected valid source");
            auto invalid = desc;
            invalid.offset = UINT32_MAX;
            require(!fp_gpu_validate(&invalid), "product accepted invalid offset");
            invalid = desc;
            invalid.size *= 2;
            require(!fp_gpu_validate(&invalid), "product accepted falsified allocation");
            invalid = desc;
            invalid.modifier = 123;
            require(!fp_gpu_validate(&invalid), "product accepted unqualified explicit modifier");
            std::vector<uint8_t> rgba(W * H * 4);
            require((fp_gpu_read_rgba(&desc, rgba.data(), rgba.size()) == 0) == !implicit,
                "raw screenshot must reject implicit layouts");
            for (int i = 0; !implicit && i < W * H; ++i) {
                require(rgba[i * 4] == source.bgra[i * 4 + 2] &&
                    rgba[i * 4 + 1] == source.bgra[i * 4 + 1] &&
                    rgba[i * 4 + 2] == source.bgra[i * 4] && rgba[i * 4 + 3] == 255,
                    "screenshot pixel mismatch");
            }
            char error[512]{};
            require(!fp_gpu_create("/nonexistent-render-node", W, H, desc.fourcc, 2000, 12, 12,
                error, sizeof(error)), "invalid device accepted");
            auto *context = fp_gpu_create("/dev/dri/renderD128", W, H, desc.fourcc, 2000, 12, 12,
                error, sizeof(error));
            require(context, error);
            Packets packets;
            const int active_fds = fd_count();
            for (int n = 0; n < 36; ++n) {
                source.stamp(n);
                if (tiled) tiled->stamp(source, n);
                const int rc = fp_gpu_convert(context, &desc, n * 83);
                require(rc == 0, fp_gpu_error(context));
                require(fp_gpu_source_done(context, 1) == 1, "source not complete before encode");
                // Reuse/mutate the source BEFORE encoding: the encoder must own its NV12 copy.
                source.stamp(255);
                if (tiled) tiled->stamp(source, 255);
                require(fp_gpu_encode(context, collect, &packets) == 0, fp_gpu_error(context));
                require(fd_count() <= active_fds + 4, "adapter FD growth");
                std::this_thread::sleep_for(std::chrono::milliseconds(83));
            }
            require(fp_gpu_convert(context, &desc, 36 * 83) == 0, fp_gpu_error(context));
            auto reject = [](void *, const uint8_t *, size_t, int64_t, int) { return -1; };
            require(fp_gpu_encode(context, reject, nullptr) != 0, "packet consumer failure was ignored");
            require(fp_gpu_source_done(context, 1) == 1, "encoding failure retained a completed source");
            require(fp_gpu_destroy(context) == 1, "adapter teardown unresolved");
            auto *decoder = avcodec_alloc_context3(avcodec_find_decoder(AV_CODEC_ID_H264));
            require(decoder, "decoder allocation");
            decoder->thread_count = 1;
            check(avcodec_open2(decoder, decoder->codec, nullptr), "decoder open");
            int decoded = 0, peak = 0, keys = 0;
            for (size_t n = 0; n < packets.bytes.size(); ++n) {
                require(packets.pts[n] == static_cast<int64_t>(n * 83), "packet PTS mismatch");
                keys += packets.keys[n];
                AVPacket *packet = av_packet_alloc();
                require(packet, "packet allocation");
                check(av_new_packet(packet, packets.bytes[n].size()), "packet storage");
                memcpy(packet->data, packets.bytes[n].data(), packets.bytes[n].size());
                check(avcodec_send_packet(decoder, packet), "decode adapter output");
                av_packet_free(&packet);
                auto out = frame();
                check(avcodec_receive_frame(decoder, out.get()), "adapter output latency");
                require(out->width == W && out->height == H, "decoded dimensions");
                require(out->colorspace == AVCOL_SPC_SMPTE170M && out->color_range == AVCOL_RANGE_MPEG &&
                    out->color_primaries == AVCOL_PRI_SMPTE170M && out->color_trc == AVCOL_TRC_SMPTE170M &&
                    out->chroma_location == AVCHROMA_LOC_LEFT, "adapter SPS VUI mismatch");
                peak = std::max(peak, flat_error(out.get(), source));
                for (int x = 16; x < W; x += 32) {
                    const int expected = ((decoded >> (x / 32)) & 1) ? 235 : 16;
                    require(abs(int(out->data[0][72 * out->linesize[0] + x]) - expected) <= 10,
                        "source reused before VPP completion or stale frame");
                }
                ++decoded;
            }
            avcodec_free_context(&decoder);
            require(decoded == 36 && keys >= 3 && peak <= 10, "packet/keyframe/color check");
            printf("product_adapter implicit=%d alpha=%d decoded=%d keys=%d color_max=%d screenshot_guard=pass\n",
                implicit, alpha, decoded, keys, peak);
        }
        require(fd_count() == baseline, "adapter leaked descriptors after teardown");
        puts("PASS product C ABI, CBR, source reuse, cold screenshot, color, PTS, IDR, packet failure and cleanup");
        return 0;
    } catch (const std::exception &error) {
        fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
