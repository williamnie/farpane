#ifndef FARPANE_GPU_RENDERER_H
#define FARPANE_GPU_RENDERER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FpGpu FpGpu;
typedef struct { uint32_t format; uint64_t modifier; } FpImportFormat;
typedef struct {
    int fd;
    uint32_t format, width, height, pitch;
    uint64_t offset, modifier;
} FpPlane;
typedef struct {
    uint32_t width, height;
    FpPlane planes[2];
    int matrix, range, chroma; /* 0: BT.601 / limited / left; 1: BT.709 / full / center */
} FpGpuFrame;
/* All calls require the same current EGL/GLES3 context, on its owning thread. */
FpGpu *fp_gpu_new(char *error, size_t capacity);
size_t fp_gpu_formats(const FpGpu *, FpImportFormat *, size_t capacity);
int fp_gpu_submit(FpGpu *, const FpGpuFrame *, char *, size_t);
/* Zero-timeout GLsync query: 0 pending, 1 completed, -1 error. No ACK on failure. */
int fp_gpu_poll(FpGpu *, char *, size_t);
int fp_gpu_draw(FpGpu *, int width, int height, char *, size_t);
void fp_gpu_destroy(FpGpu *);
/* Used only by the isolated shader test; production never uploads YUV pixels. */
int fp_gpu_test_upload(FpGpu *, const FpGpuFrame *, const uint8_t *, const uint8_t *, char *, size_t);
int fp_gpu_test_read(FpGpu *, uint8_t *, size_t);
#ifdef __cplusplus
}
#endif
#endif
