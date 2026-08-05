#ifndef RUSTDESK_NATIVE_H
#define RUSTDESK_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RDN_ABI_VERSION 5u

typedef struct RDNClient RDNClient;

typedef enum RDNState {
    RDN_STATE_IDLE = 0,
    RDN_STATE_CONNECTING = 1,
    RDN_STATE_TRANSPORT_READY = 2,
    RDN_STATE_AUTHENTICATED = 3,
    RDN_STATE_STREAMING = 4,
    RDN_STATE_PASSWORD_REQUIRED = 5,
    RDN_STATE_AUTHENTICATION_FAILED = 6,
    RDN_STATE_DISCONNECTED = 7,
    RDN_STATE_ERROR = 8,
    RDN_STATE_CONTROL_READY = 9,
} RDNState;

typedef enum RDNCodec {
    RDN_CODEC_UNKNOWN = 0,
    RDN_CODEC_H264 = 1,
    RDN_CODEC_H265 = 2,
} RDNCodec;

typedef enum RDNPacketFormat {
    RDN_PACKET_FORMAT_UNKNOWN = 0,
    RDN_PACKET_FORMAT_ANNEX_B = 1,
    RDN_PACKET_FORMAT_AVCC = 2,
    RDN_PACKET_FORMAT_MIXED = 3,
} RDNPacketFormat;

typedef enum RDNVideoFlags {
    RDN_VIDEO_FLAG_KEYFRAME = 1u << 0,
    RDN_VIDEO_FLAG_VPS = 1u << 1,
    RDN_VIDEO_FLAG_SPS = 1u << 2,
    RDN_VIDEO_FLAG_PPS = 1u << 3,
} RDNVideoFlags;

typedef struct RDNEncodedVideoFrame {
    uint32_t abi_version;
    RDNCodec codec;
    RDNPacketFormat packet_format;
    const uint8_t *data;
    size_t length;
    uint64_t sequence;
    uint64_t timestamp_us;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t display;
} RDNEncodedVideoFrame;

typedef struct RDNCoreMetrics {
    uint32_t abi_version;
    double remote_fps;
    int32_t network_delay_ms;
    uint64_t target_bitrate;
} RDNCoreMetrics;

typedef void (*RDNStateCallback)(void *context, RDNState state, int32_t code,
                                 const char *message);
typedef void (*RDNVideoCallback)(void *context,
                                 const RDNEncodedVideoFrame *frame);
typedef void (*RDNMetricsCallback)(void *context,
                                   const RDNCoreMetrics *metrics);

typedef struct RDNCallbacks {
    uint32_t abi_version;
    RDNStateCallback on_state;
    RDNVideoCallback on_video;
    RDNMetricsCallback on_metrics;
} RDNCallbacks;

typedef struct RDNConnectionConfig {
    uint32_t abi_version;
    const char *rendezvous_server;
    const char *server_public_key;
    const char *peer_id;
    const char *password;
    bool force_relay;
} RDNConnectionConfig;

typedef enum RDNModifierFlags {
    RDN_MODIFIER_SHIFT = 1u << 0,
    RDN_MODIFIER_CONTROL = 1u << 1,
    RDN_MODIFIER_OPTION = 1u << 2,
    RDN_MODIFIER_COMMAND = 1u << 3,
} RDNModifierFlags;

typedef enum RDNPointerKind {
    RDN_POINTER_MOVE = 0,
    RDN_POINTER_DOWN = 1,
    RDN_POINTER_UP = 2,
    RDN_POINTER_SCROLL = 3,
    RDN_POINTER_PRECISE_SCROLL = 4,
} RDNPointerKind;

typedef enum RDNPointerButtonFlags {
    RDN_POINTER_BUTTON_LEFT = 1u << 0,
    RDN_POINTER_BUTTON_RIGHT = 1u << 1,
    RDN_POINTER_BUTTON_MIDDLE = 1u << 2,
} RDNPointerButtonFlags;

typedef struct RDNPointerEvent {
    uint32_t abi_version;
    RDNPointerKind kind;
    int32_t x;
    int32_t y;
    int32_t scroll_x;
    int32_t scroll_y;
    uint32_t buttons;
    uint32_t modifiers;
} RDNPointerEvent;

typedef enum RDNKeyCode {
    RDN_KEY_CHARACTER = 0,
    RDN_KEY_ESCAPE = 1,
    RDN_KEY_RETURN = 2,
    RDN_KEY_TAB = 3,
    RDN_KEY_BACKSPACE = 4,
    RDN_KEY_DELETE_FORWARD = 5,
    RDN_KEY_LEFT = 6,
    RDN_KEY_RIGHT = 7,
    RDN_KEY_UP = 8,
    RDN_KEY_DOWN = 9,
    RDN_KEY_SPACE = 10,
    RDN_KEY_SHIFT = 11,
    RDN_KEY_CONTROL = 12,
    RDN_KEY_OPTION = 13,
    RDN_KEY_COMMAND = 14,
    RDN_KEY_HOME = 15,
    RDN_KEY_END = 16,
    RDN_KEY_PAGE_UP = 17,
    RDN_KEY_PAGE_DOWN = 18,
    /* Native macOS hardware key position. Rust Core maps this through the
     * pinned RustDesk keyboard map mode so the remote IME sees key strokes. */
    RDN_KEY_PHYSICAL = 19,
} RDNKeyCode;

typedef struct RDNKeyEvent {
    uint32_t abi_version;
    RDNKeyCode code;
    uint32_t unicode_scalar;
    uint32_t hardware_keycode;
    bool down;
    uint32_t modifiers;
} RDNKeyEvent;

RDNClient *rdn_client_create(const RDNCallbacks *callbacks, void *context);
void rdn_client_destroy(RDNClient *client);
int32_t rdn_client_connect(RDNClient *client,
                           const RDNConnectionConfig *config);
void rdn_client_disconnect(RDNClient *client);
int32_t rdn_client_request_keyframe(RDNClient *client, uint32_t display);
int32_t rdn_client_send_pointer(RDNClient *client,
                                const RDNPointerEvent *event);
int32_t rdn_client_send_key(RDNClient *client, const RDNKeyEvent *event);
int32_t rdn_client_send_text(RDNClient *client, const uint8_t *utf8,
                             size_t length);
uint32_t rdn_core_abi_version(void);
const char *rdn_core_upstream_commit(void);

/* ------------------------------------------------------------------------ */
/* Host Control ABI (rdn-native-host, H1a scope)                             */
/* Low-frequency semantic control only: versioned JSON envelopes for        */
/* commands/events/snapshots. No raw frames and no encoded packets on this  */
/* channel; media flows through the separate Host Media ABI later (H1b).    */
/* ------------------------------------------------------------------------ */

#define RDN_HOST_ABI_VERSION 1u

/* Stable error codes; 0 is success, negatives are contract failures. */
#define RDN_HOST_OK 0
#define RDN_HOST_ERR_INVALID_ARG (-1)
#define RDN_HOST_ERR_ABI_MISMATCH (-2)
#define RDN_HOST_ERR_BAD_STATE (-3)
#define RDN_HOST_ERR_NOT_SUPPORTED (-4)
#define RDN_HOST_ERR_VALIDATION (-5)
#define RDN_HOST_ERR_INTERNAL (-6)

typedef struct RdnHost RdnHost;

typedef enum RdnHostState {
    RDN_HOST_STATE_CREATED = 0,
    RDN_HOST_STATE_STARTING = 1,
    RDN_HOST_STATE_READY = 2,
    RDN_HOST_STATE_STOPPING = 3,
    RDN_HOST_STATE_STOPPED = 4,
    RDN_HOST_STATE_ERROR = 5,
} RdnHostState;

typedef enum RdnHostStopReason {
    RDN_HOST_STOP_USER_REQUEST = 0,
    RDN_HOST_STOP_APP_EXIT = 1,
    RDN_HOST_STOP_ERROR = 2,
} RdnHostStopReason;

/* Owned UTF-8 bytes returned by rdn_host_copy_snapshot; release with
 * rdn_host_free_bytes. `length` is the valid byte count, `capacity` the
 * allocation size. */
typedef struct RdnHostOwnedBytes {
    uint8_t *data;
    size_t length;
    size_t capacity;
} RdnHostOwnedBytes;

/* Versioned JSON event envelope (§8.5). The payload pointer is only valid
 * for the duration of the call; copy if it must outlive the callback. */
typedef void (*RdnHostEventCallback)(void *context, const char *json_utf8,
                                     size_t length);

typedef struct RdnHostCallbacks {
    uint32_t abi_version;
    RdnHostEventCallback on_event;
    void *context;
} RdnHostCallbacks;

/* Reserved for future options (canonical server config); zero-initialize. */
typedef struct RdnHostCreateOptions {
    uint32_t abi_version;
} RdnHostCreateOptions;

uint32_t rdn_host_abi_version(void);
const char *rdn_host_upstream_commit(void);

/* Early config-root entry: must be the first host ABI call in the process,
 * before any RustDesk config access, and runs exactly once. */
int32_t rdn_host_set_config_root(const char *app_name, const char *org);

int32_t rdn_host_create(const RdnHostCreateOptions *options,
                        const RdnHostCallbacks *callbacks, RdnHost **out_host);
int32_t rdn_host_start(RdnHost *host);
int32_t rdn_host_stop(RdnHost *host, RdnHostStopReason reason);
int32_t rdn_host_command(RdnHost *host, const uint8_t *command_json,
                         size_t length);
int32_t rdn_host_copy_snapshot(RdnHost *host, RdnHostOwnedBytes *out_snapshot);
void rdn_host_free_bytes(RdnHostOwnedBytes bytes);
void rdn_host_destroy(RdnHost *host);

/* Runtime loader used by the Swift package so fixture-only builds do not need
 * the Rust core present. The returned error strings never contain credentials. */
typedef struct RDNCoreLibrary RDNCoreLibrary;
RDNCoreLibrary *rdn_shim_open(const char *path, char *error, size_t error_size);
void rdn_shim_close(RDNCoreLibrary *library);
uint32_t rdn_shim_abi_version(const RDNCoreLibrary *library);
const char *rdn_shim_upstream_commit(const RDNCoreLibrary *library);
RDNClient *rdn_shim_client_create(const RDNCoreLibrary *library,
                                  const RDNCallbacks *callbacks,
                                  void *context);
void rdn_shim_client_destroy(const RDNCoreLibrary *library, RDNClient *client);
int32_t rdn_shim_client_connect(const RDNCoreLibrary *library,
                                RDNClient *client,
                                const RDNConnectionConfig *config);
void rdn_shim_client_disconnect(const RDNCoreLibrary *library,
                                RDNClient *client);
int32_t rdn_shim_client_request_keyframe(const RDNCoreLibrary *library,
                                         RDNClient *client,
                                         uint32_t display);
int32_t rdn_shim_client_send_pointer(const RDNCoreLibrary *library,
                                     RDNClient *client,
                                     const RDNPointerEvent *event);
int32_t rdn_shim_client_send_key(const RDNCoreLibrary *library,
                                 RDNClient *client,
                                 const RDNKeyEvent *event);
int32_t rdn_shim_client_send_text(const RDNCoreLibrary *library,
                                  RDNClient *client, const uint8_t *utf8,
                                  size_t length);

/* Host Control ABI loader surface (rdn-native-host). rdn_shim_open tolerates
 * cores built without the host feature: rdn_shim_host_available reports whether
 * the host symbol surface resolved. */
int rdn_shim_host_available(const RDNCoreLibrary *library);
uint32_t rdn_shim_host_abi_version(const RDNCoreLibrary *library);
const char *rdn_shim_host_upstream_commit(const RDNCoreLibrary *library);
int32_t rdn_shim_host_set_config_root(const RDNCoreLibrary *library,
                                      const char *app_name, const char *org);
int32_t rdn_shim_host_create(const RDNCoreLibrary *library,
                             const RdnHostCreateOptions *options,
                             const RdnHostCallbacks *callbacks,
                             RdnHost **out_host);
int32_t rdn_shim_host_start(const RDNCoreLibrary *library, RdnHost *host);
int32_t rdn_shim_host_stop(const RDNCoreLibrary *library, RdnHost *host,
                           RdnHostStopReason reason);
int32_t rdn_shim_host_command(const RDNCoreLibrary *library, RdnHost *host,
                              const uint8_t *command_json, size_t length);
int32_t rdn_shim_host_copy_snapshot(const RDNCoreLibrary *library,
                                    RdnHost *host,
                                    RdnHostOwnedBytes *out_snapshot);
void rdn_shim_host_free_bytes(const RDNCoreLibrary *library,
                              RdnHostOwnedBytes bytes);
void rdn_shim_host_destroy(const RDNCoreLibrary *library, RdnHost *host);

#ifdef __cplusplus
}
#endif

#endif
