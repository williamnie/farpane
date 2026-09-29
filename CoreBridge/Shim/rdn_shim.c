#include "rustdesk_native.h"

#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rdn_symbols.h"

struct RDNCoreLibrary {
    void *handle;
    int host_available;
#define DECLARE_SYMBOL(field, symbol) __typeof__(&symbol) field;
    RDN_VIEWER_SYMBOLS(DECLARE_SYMBOL)
    RDN_HOST_SYMBOLS(DECLARE_SYMBOL)
#undef DECLARE_SYMBOL
};

static void write_error(char *error, size_t size, const char *message) {
    if (error == NULL || size == 0) return;
    snprintf(error, size, "%s", message == NULL ? "unknown loader error" : message);
}

int rdn_shim_transform_current_process_to_ui_element(void) {
    typedef OSStatus (*transform_process_type_fn)(
        const ProcessSerialNumber *, ProcessApplicationTransformState);
    void *framework = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/"
        "HIServices.framework/Versions/A/HIServices",
        RTLD_LAZY | RTLD_LOCAL);
    if (framework == NULL) return 0;
    transform_process_type_fn transform =
        (transform_process_type_fn)dlsym(framework, "TransformProcessType");
    if (transform == NULL) {
        dlclose(framework);
        return 0;
    }
    ProcessSerialNumber process = {0, kCurrentProcess};
    OSStatus status = transform(
        &process, kProcessTransformToUIElementApplication);
    dlclose(framework);
    return status == noErr;
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
    int available = 1;
#define LOAD_SYMBOL(field, symbol) \
    library->field = (__typeof__(library->field))dlsym(handle, #symbol); \
    available &= library->field != NULL;
    RDN_VIEWER_SYMBOLS(LOAD_SYMBOL)
    if (!available) {
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
    available = 1;
    RDN_HOST_SYMBOLS(LOAD_SYMBOL)
#undef LOAD_SYMBOL
    library->host_available = available;
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

int32_t rdn_shim_client_select_display(
    const RDNCoreLibrary *library, RDNClient *client,
    const RDNDisplaySelectionRequest *request) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_select_display(client, request);
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

int32_t rdn_shim_client_send_clipboard_image(
    const RDNCoreLibrary *library, RDNClient *client,
    const RDNClipboardImagePayload *payload) {
    return library == NULL
               ? -1
               : library->client_send_clipboard_image(client, payload);
}

int32_t rdn_shim_client_file_transfer_cancel(
    const RDNCoreLibrary *library, RDNClient *client,
    uint64_t session_epoch, int32_t transfer_id) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_file_transfer_cancel(
                     client, session_epoch, transfer_id);
}

int32_t rdn_shim_client_file_transfer_list_root(
    const RDNCoreLibrary *library, RDNClient *client,
    uint64_t session_epoch, int32_t request_id) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_file_transfer_list_root(
                     client, session_epoch, request_id);
}

int32_t rdn_shim_client_file_transfer_manifest_root(
    const RDNCoreLibrary *library, RDNClient *client,
    uint64_t session_epoch, int32_t request_id) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_file_transfer_manifest_root(
                     client, session_epoch, request_id);
}

int32_t rdn_shim_client_file_transfer_download_start(
    const RDNCoreLibrary *library, RDNClient *client,
    const RDNFileTransferDownloadStart *request) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_file_transfer_download_start(client, request);
}

int32_t rdn_shim_client_file_transfer_upload_start(
    const RDNCoreLibrary *library, RDNClient *client,
    const RDNFileTransferUploadStart *request) {
    return library == NULL
               ? RDN_CLIENT_ERR_INVALID_ARGUMENT
               : library->client_file_transfer_upload_start(client, request);
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
