#include "rustdesk_native.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef RDNClient *(*client_create_fn)(const RDNCallbacks *, void *);
typedef void (*client_destroy_fn)(RDNClient *);
typedef int32_t (*client_connect_fn)(RDNClient *, const RDNConnectionConfig *);
typedef void (*client_disconnect_fn)(RDNClient *);
typedef int32_t (*client_request_keyframe_fn)(RDNClient *, uint32_t);
typedef int32_t (*client_send_pointer_fn)(RDNClient *, const RDNPointerEvent *);
typedef int32_t (*client_send_key_fn)(RDNClient *, const RDNKeyEvent *);
typedef int32_t (*client_send_text_fn)(RDNClient *, const uint8_t *, size_t);
typedef int32_t (*client_send_clipboard_text_fn)(RDNClient *, const uint8_t *,
                                                 size_t);
typedef int32_t (*client_send_clipboard_rich_text_fn)(
    RDNClient *, const RDNClipboardRichTextPayload *);
typedef uint32_t (*abi_version_fn)(void);
typedef const char *(*upstream_commit_fn)(void);

typedef int32_t (*host_set_config_root_fn)(const char *, const char *);
typedef int32_t (*host_create_fn)(const RdnHostCreateOptions *,
                                  const RdnHostCallbacks *, RdnHost **);
typedef int32_t (*host_start_fn)(RdnHost *);
typedef int32_t (*host_stop_fn)(RdnHost *, RdnHostStopReason);
typedef int32_t (*host_epoch_fn)(RdnHost *, uint64_t);
typedef int32_t (*host_generation_fn)(RdnHost *, uint64_t);
typedef int32_t (*host_command_fn)(RdnHost *, const uint8_t *, size_t);
typedef int32_t (*host_set_permanent_password_fn)(RdnHost *, const char *,
                                                  uint8_t *, size_t);
typedef int32_t (*host_copy_snapshot_fn)(RdnHost *, RdnHostOwnedBytes *);
typedef void (*host_free_bytes_fn)(RdnHostOwnedBytes);
typedef void (*host_destroy_fn)(RdnHost *);
typedef int32_t (*host_media_set_capabilities_fn)(
    RdnHost *, const RdnHostEncoderCapabilities *);
typedef int32_t (*host_media_submit_access_unit_fn)(
    RdnHost *, const RdnHostEncodedAccessUnit *);
typedef int32_t (*host_media_report_encoder_state_fn)(
    RdnHost *, const RdnHostEncoderState *);

struct RDNCoreLibrary {
    void *handle;
    client_create_fn client_create;
    client_destroy_fn client_destroy;
    client_connect_fn client_connect;
    client_disconnect_fn client_disconnect;
    client_request_keyframe_fn client_request_keyframe;
    client_send_pointer_fn client_send_pointer;
    client_send_key_fn client_send_key;
    client_send_text_fn client_send_text;
    client_send_clipboard_text_fn client_send_clipboard_text;
    client_send_clipboard_rich_text_fn client_send_clipboard_rich_text;
    abi_version_fn abi_version;
    upstream_commit_fn upstream_commit;
    int host_available;
    abi_version_fn host_abi_version;
    upstream_commit_fn host_upstream_commit;
    host_set_config_root_fn host_set_config_root;
    host_create_fn host_create;
    host_start_fn host_start;
    host_stop_fn host_stop;
    host_generation_fn host_recover_network_path;
    host_epoch_fn host_begin_sleep;
    host_epoch_fn host_finish_sleep;
    host_epoch_fn host_resume_after_wake;
    host_command_fn host_command;
    host_set_permanent_password_fn host_set_permanent_password;
    host_copy_snapshot_fn host_copy_snapshot;
    host_free_bytes_fn host_free_bytes;
    host_destroy_fn host_destroy;
    abi_version_fn host_media_abi_version;
    host_media_set_capabilities_fn host_media_set_capabilities;
    host_media_submit_access_unit_fn host_media_submit_access_unit;
    host_media_report_encoder_state_fn host_media_report_encoder_state;
};

static void write_error(char *error, size_t size, const char *message) {
    if (error == NULL || size == 0) return;
    snprintf(error, size, "%s", message == NULL ? "unknown loader error" : message);
}

RDNCoreLibrary *rdn_shim_open(const char *path, char *error, size_t error_size) {
    if (path == NULL || path[0] == '\0') {
        write_error(error, error_size, "core library path is empty");
        return NULL;
    }
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        write_error(error, error_size, dlerror());
        return NULL;
    }
    RDNCoreLibrary *library = calloc(1, sizeof(*library));
    if (library == NULL) {
        dlclose(handle);
        write_error(error, error_size, "core loader allocation failed");
        return NULL;
    }
    library->handle = handle;
    library->client_create = (client_create_fn)dlsym(handle, "rdn_client_create");
    library->client_destroy = (client_destroy_fn)dlsym(handle, "rdn_client_destroy");
    library->client_connect = (client_connect_fn)dlsym(handle, "rdn_client_connect");
    library->client_disconnect = (client_disconnect_fn)dlsym(handle, "rdn_client_disconnect");
    library->client_request_keyframe =
        (client_request_keyframe_fn)dlsym(handle, "rdn_client_request_keyframe");
    library->client_send_pointer =
        (client_send_pointer_fn)dlsym(handle, "rdn_client_send_pointer");
    library->client_send_key =
        (client_send_key_fn)dlsym(handle, "rdn_client_send_key");
    library->client_send_text =
        (client_send_text_fn)dlsym(handle, "rdn_client_send_text");
    library->client_send_clipboard_text = (client_send_clipboard_text_fn)dlsym(
        handle, "rdn_client_send_clipboard_text");
    library->client_send_clipboard_rich_text =
        (client_send_clipboard_rich_text_fn)dlsym(
            handle, "rdn_client_send_clipboard_rich_text");
    library->abi_version = (abi_version_fn)dlsym(handle, "rdn_core_abi_version");
    library->upstream_commit = (upstream_commit_fn)dlsym(handle, "rdn_core_upstream_commit");
    if (library->client_create == NULL || library->client_destroy == NULL ||
        library->client_connect == NULL || library->client_disconnect == NULL ||
        library->client_request_keyframe == NULL ||
        library->client_send_pointer == NULL || library->client_send_key == NULL ||
        library->client_send_text == NULL ||
        library->client_send_clipboard_text == NULL ||
        library->client_send_clipboard_rich_text == NULL ||
        library->abi_version == NULL || library->upstream_commit == NULL) {
        rdn_shim_close(library);
        write_error(error, error_size, "core library is missing required ABI symbols");
        return NULL;
    }
    if (library->abi_version() != RDN_ABI_VERSION) {
        rdn_shim_close(library);
        write_error(error, error_size, "core ABI version mismatch");
        return NULL;
    }
    /* Host Control ABI (rdn-native-host): optional surface, resolved
     * best-effort so viewer-only cores keep loading. All-or-nothing: either
     * the full host surface resolves or host_available stays 0. */
    library->host_abi_version = (abi_version_fn)dlsym(handle, "rdn_host_abi_version");
    library->host_upstream_commit =
        (upstream_commit_fn)dlsym(handle, "rdn_host_upstream_commit");
    library->host_set_config_root =
        (host_set_config_root_fn)dlsym(handle, "rdn_host_set_config_root");
    library->host_create = (host_create_fn)dlsym(handle, "rdn_host_create");
    library->host_start = (host_start_fn)dlsym(handle, "rdn_host_start");
    library->host_stop = (host_stop_fn)dlsym(handle, "rdn_host_stop");
    library->host_recover_network_path = (host_generation_fn)dlsym(
        handle, "rdn_host_recover_network_path");
    library->host_begin_sleep =
        (host_epoch_fn)dlsym(handle, "rdn_host_begin_sleep");
    library->host_finish_sleep =
        (host_epoch_fn)dlsym(handle, "rdn_host_finish_sleep");
    library->host_resume_after_wake =
        (host_epoch_fn)dlsym(handle, "rdn_host_resume_after_wake");
    library->host_command = (host_command_fn)dlsym(handle, "rdn_host_command");
    library->host_set_permanent_password =
        (host_set_permanent_password_fn)dlsym(
            handle, "rdn_host_set_permanent_password");
    library->host_copy_snapshot =
        (host_copy_snapshot_fn)dlsym(handle, "rdn_host_copy_snapshot");
    library->host_free_bytes =
        (host_free_bytes_fn)dlsym(handle, "rdn_host_free_bytes");
    library->host_destroy = (host_destroy_fn)dlsym(handle, "rdn_host_destroy");
    library->host_media_abi_version =
        (abi_version_fn)dlsym(handle, "rdn_host_media_abi_version");
    library->host_media_set_capabilities = (host_media_set_capabilities_fn)dlsym(
        handle, "rdn_host_media_set_capabilities");
    library->host_media_submit_access_unit = (host_media_submit_access_unit_fn)dlsym(
        handle, "rdn_host_media_submit_access_unit");
    library->host_media_report_encoder_state = (host_media_report_encoder_state_fn)dlsym(
        handle, "rdn_host_media_report_encoder_state");
    if (library->host_abi_version != NULL && library->host_upstream_commit != NULL &&
        library->host_set_config_root != NULL && library->host_create != NULL &&
        library->host_start != NULL && library->host_stop != NULL &&
        library->host_recover_network_path != NULL &&
        library->host_begin_sleep != NULL && library->host_finish_sleep != NULL &&
        library->host_resume_after_wake != NULL &&
        library->host_command != NULL &&
        library->host_set_permanent_password != NULL &&
        library->host_copy_snapshot != NULL &&
        library->host_free_bytes != NULL && library->host_destroy != NULL &&
        library->host_media_abi_version != NULL &&
        library->host_media_set_capabilities != NULL &&
        library->host_media_submit_access_unit != NULL &&
        library->host_media_report_encoder_state != NULL) {
        library->host_available = 1;
    }
    return library;
}

void rdn_shim_close(RDNCoreLibrary *library) {
    if (library == NULL) return;
    if (library->handle != NULL) dlclose(library->handle);
    free(library);
}

uint32_t rdn_shim_abi_version(const RDNCoreLibrary *library) {
    return library == NULL ? 0 : library->abi_version();
}

const char *rdn_shim_upstream_commit(const RDNCoreLibrary *library) {
    return library == NULL ? NULL : library->upstream_commit();
}

RDNClient *rdn_shim_client_create(const RDNCoreLibrary *library,
                                  const RDNCallbacks *callbacks,
                                  void *context) {
    return library == NULL ? NULL : library->client_create(callbacks, context);
}

void rdn_shim_client_destroy(const RDNCoreLibrary *library, RDNClient *client) {
    if (library != NULL) library->client_destroy(client);
}

int32_t rdn_shim_client_connect(const RDNCoreLibrary *library,
                                RDNClient *client,
                                const RDNConnectionConfig *config) {
    return library == NULL ? -1 : library->client_connect(client, config);
}

void rdn_shim_client_disconnect(const RDNCoreLibrary *library,
                                RDNClient *client) {
    if (library != NULL) library->client_disconnect(client);
}

int32_t rdn_shim_client_request_keyframe(const RDNCoreLibrary *library,
                                         RDNClient *client,
                                         uint32_t display) {
    return library == NULL ? -1 : library->client_request_keyframe(client, display);
}

int32_t rdn_shim_client_send_pointer(const RDNCoreLibrary *library,
                                     RDNClient *client,
                                     const RDNPointerEvent *event) {
    return library == NULL ? -1 : library->client_send_pointer(client, event);
}

int32_t rdn_shim_client_send_key(const RDNCoreLibrary *library,
                                 RDNClient *client,
                                 const RDNKeyEvent *event) {
    return library == NULL ? -1 : library->client_send_key(client, event);
}

int32_t rdn_shim_client_send_text(const RDNCoreLibrary *library,
                                  RDNClient *client, const uint8_t *utf8,
                                  size_t length) {
    return library == NULL ? -1 : library->client_send_text(client, utf8, length);
}

int32_t rdn_shim_client_send_clipboard_text(const RDNCoreLibrary *library,
                                            RDNClient *client,
                                            const uint8_t *utf8,
                                            size_t length) {
    return library == NULL ? -1
                           : library->client_send_clipboard_text(client, utf8,
                                                                 length);
}

int32_t rdn_shim_client_send_clipboard_rich_text(
    const RDNCoreLibrary *library, RDNClient *client,
    const RDNClipboardRichTextPayload *payload) {
    return library == NULL
               ? -1
               : library->client_send_clipboard_rich_text(client, payload);
}

int rdn_shim_host_available(const RDNCoreLibrary *library) {
    return library == NULL ? 0 : library->host_available;
}

uint32_t rdn_shim_host_abi_version(const RDNCoreLibrary *library) {
    return library == NULL || library->host_abi_version == NULL
               ? 0
               : library->host_abi_version();
}

const char *rdn_shim_host_upstream_commit(const RDNCoreLibrary *library) {
    return library == NULL || library->host_upstream_commit == NULL
               ? NULL
               : library->host_upstream_commit();
}

int32_t rdn_shim_host_set_config_root(const RDNCoreLibrary *library,
                                      const char *app_name, const char *org) {
    return library == NULL || library->host_set_config_root == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_set_config_root(app_name, org);
}

int32_t rdn_shim_host_create(const RDNCoreLibrary *library,
                             const RdnHostCreateOptions *options,
                             const RdnHostCallbacks *callbacks,
                             RdnHost **out_host) {
    return library == NULL || library->host_create == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_create(options, callbacks, out_host);
}

int32_t rdn_shim_host_start(const RDNCoreLibrary *library, RdnHost *host) {
    return library == NULL || library->host_start == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_start(host);
}

int32_t rdn_shim_host_stop(const RDNCoreLibrary *library, RdnHost *host,
                           RdnHostStopReason reason) {
    return library == NULL || library->host_stop == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_stop(host, reason);
}

int32_t rdn_shim_host_recover_network_path(const RDNCoreLibrary *library,
                                           RdnHost *host,
                                           uint64_t path_generation) {
    return library == NULL || library->host_recover_network_path == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_recover_network_path(host, path_generation);
}

int32_t rdn_shim_host_begin_sleep(const RDNCoreLibrary *library, RdnHost *host,
                                  uint64_t epoch) {
    return library == NULL || library->host_begin_sleep == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_begin_sleep(host, epoch);
}

int32_t rdn_shim_host_finish_sleep(const RDNCoreLibrary *library, RdnHost *host,
                                   uint64_t epoch) {
    return library == NULL || library->host_finish_sleep == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_finish_sleep(host, epoch);
}

int32_t rdn_shim_host_resume_after_wake(const RDNCoreLibrary *library,
                                        RdnHost *host, uint64_t epoch) {
    return library == NULL || library->host_resume_after_wake == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_resume_after_wake(host, epoch);
}

int32_t rdn_shim_host_command(const RDNCoreLibrary *library, RdnHost *host,
                              const uint8_t *command_json, size_t length) {
    return library == NULL || library->host_command == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_command(host, command_json, length);
}

int32_t rdn_shim_host_set_permanent_password(
    const RDNCoreLibrary *library, RdnHost *host, const char *command_id,
    uint8_t *password_utf8, size_t password_length) {
    return library == NULL || library->host_set_permanent_password == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_set_permanent_password(
                     host, command_id, password_utf8, password_length);
}

int32_t rdn_shim_host_copy_snapshot(const RDNCoreLibrary *library,
                                    RdnHost *host,
                                    RdnHostOwnedBytes *out_snapshot) {
    return library == NULL || library->host_copy_snapshot == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_copy_snapshot(host, out_snapshot);
}

void rdn_shim_host_free_bytes(const RDNCoreLibrary *library,
                              RdnHostOwnedBytes bytes) {
    if (library != NULL && library->host_free_bytes != NULL) {
        library->host_free_bytes(bytes);
    }
}

void rdn_shim_host_destroy(const RDNCoreLibrary *library, RdnHost *host) {
    if (library != NULL && library->host_destroy != NULL) {
        library->host_destroy(host);
    }
}

uint32_t rdn_shim_host_media_abi_version(const RDNCoreLibrary *library) {
    return library == NULL || library->host_media_abi_version == NULL
               ? 0
               : library->host_media_abi_version();
}

int32_t rdn_shim_host_media_set_capabilities(
    const RDNCoreLibrary *library, RdnHost *host,
    const RdnHostEncoderCapabilities *capabilities) {
    return library == NULL || library->host_media_set_capabilities == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_media_set_capabilities(host, capabilities);
}

int32_t rdn_shim_host_media_submit_access_unit(
    const RDNCoreLibrary *library, RdnHost *host,
    const RdnHostEncodedAccessUnit *access_unit) {
    return library == NULL || library->host_media_submit_access_unit == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_media_submit_access_unit(host, access_unit);
}

int32_t rdn_shim_host_media_report_encoder_state(
    const RDNCoreLibrary *library, RdnHost *host,
    const RdnHostEncoderState *state) {
    return library == NULL || library->host_media_report_encoder_state == NULL
               ? RDN_HOST_ERR_NOT_SUPPORTED
               : library->host_media_report_encoder_state(host, state);
}
