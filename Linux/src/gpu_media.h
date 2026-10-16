#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FpGpu FpGpu;
typedef struct {
    int32_t fd;
    uint32_t width, height, fourcc, pitch, offset;
    uint64_t size, modifier;
} FpGpuFrame;
typedef int (*FpPacketFn)(void *, const uint8_t *, size_t, int64_t, int);

// Every context operation belongs to the same media thread. A failed operation
// may retain in-flight work; only source_done permits releasing the source lease.
FpGpu *fp_gpu_create(const char *render_node, uint32_t width, uint32_t height,
                     uint32_t fourcc, uint32_t kbps, uint32_t fps, uint32_t gop,
                     char *error, size_t error_size);
int fp_gpu_validate(const FpGpuFrame *frame);
int fp_gpu_convert(FpGpu *ctx, const FpGpuFrame *frame, int64_t pts);
int fp_gpu_source_done(FpGpu *ctx, uint32_t timeout_ms);
int fp_gpu_encode(FpGpu *ctx, FpPacketFn packet, void *opaque);
const char *fp_gpu_error(const FpGpu *ctx);
// Returns 0 while work remains unresolved; the caller must retain ctx and lease.
int fp_gpu_destroy(FpGpu *ctx);
int fp_gpu_read_rgba(const FpGpuFrame *frame, uint8_t *rgba, size_t length);

#ifdef __cplusplus
}
#endif
