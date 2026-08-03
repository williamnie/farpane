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
typedef uint32_t (*abi_version_fn)(void);
typedef const char *(*upstream_commit_fn)(void);

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
    abi_version_fn abi_version;
    upstream_commit_fn upstream_commit;
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
    library->abi_version = (abi_version_fn)dlsym(handle, "rdn_core_abi_version");
    library->upstream_commit = (upstream_commit_fn)dlsym(handle, "rdn_core_upstream_commit");
    if (library->client_create == NULL || library->client_destroy == NULL ||
        library->client_connect == NULL || library->client_disconnect == NULL ||
        library->client_request_keyframe == NULL ||
        library->client_send_pointer == NULL || library->client_send_key == NULL ||
        library->client_send_text == NULL ||
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
