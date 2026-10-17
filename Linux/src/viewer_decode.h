#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FpViewerDecoder FpViewerDecoder;
typedef struct {
    int32_t fd;
    uint32_t reserved;
    uint64_t size, modifier;
} FpViewerObject;
typedef struct {
    uint32_t format, object, pitch, reserved;
    uint64_t offset;
} FpViewerLayer;
typedef struct {
    uint64_t lease;
    int64_t pts;
    uint32_t width, height, object_count, pool_size;
    FpViewerObject objects[4];
    FpViewerLayer layers[2];
    int32_t matrix, range, primaries, transfer, chroma;
} FpViewerFrame;
typedef struct {
    uint64_t lease;
    int64_t pts;
    uint32_t width, height, stride, reserved;
    const uint8_t *bgra;
    size_t length;
} FpViewerCpuFrame;

// render_fd must already identify a DRM render node; no X/primary-node fallback.
// codec: 1=H.264, 2=HEVC; software additionally 3=VP8, 4=VP9 (8-bit SDR).
// Thread-confined, one decoder generation.
FpViewerDecoder *fp_viewer_create(int render_fd, int codec, char *error, size_t error_size);
FpViewerDecoder *fp_viewer_create_software(int codec, char *error, size_t error_size);
// send: 0 accepted, 1 drain output and retry the same packet, -1 fatal.
int fp_viewer_send(FpViewerDecoder *, const uint8_t *, size_t, int64_t pts);
// receive: 0 frame, 1 needs input, 2 lease limit reached, -1 fatal.
// Object FDs are borrowed until release; SCM_RIGHTS/dup creates receiver ownership.
int fp_viewer_receive(FpViewerDecoder *, FpViewerFrame *);
// Pixels are a borrowed CPU copy, valid until release; no hardware readback.
int fp_viewer_receive_software(FpViewerDecoder *, FpViewerCpuFrame *);
// Only call after proven GPU read completion, or before a frame was ever sent.
int fp_viewer_release(FpViewerDecoder *, uint64_t lease);
const char *fp_viewer_error(const FpViewerDecoder *);
// Stops this entire generation; no pool is reused, even on an unacknowledged HUP.
// Driver teardown may block: the disposable worker owns this call, never GTK.
void fp_viewer_destroy(FpViewerDecoder *);
#ifdef __cplusplus
}
#endif
