// Optional libsecret bridge. Only the credential worker calls these functions.
// Synchronous calls always receive GCancellable; no GTK thread waits here.
#define _DEFAULT_SOURCE
#include <libsecret/secret.h>
#include <dlfcn.h>
#include <string.h>
#include "secret_service.h"

#define FUNCTIONS(X) \
    X(secret_service_get_type) X(secret_service_open_sync) \
    X(secret_service_search_sync) X(secret_collection_for_alias_sync) \
    X(secret_collection_get_locked) X(secret_item_create_sync) \
    X(secret_item_get_locked) X(secret_item_get_secret) X(secret_item_delete_sync) \
    X(secret_value_new) X(secret_value_get) X(secret_value_unref)
#define FIELD(name) __typeof__(name) *name;
static struct { void *library; FUNCTIONS(FIELD) } api;
static gsize initialized;

static gboolean load_library(void) {
    if (g_once_init_enter(&initialized)) {
        gboolean good = TRUE;
        api.library = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
        if (!api.library) good = FALSE;
#define LOAD(name) if (good) { api.name = (__typeof__(name) *)dlsym(api.library, #name); if (!api.name) good = FALSE; }
        FUNCTIONS(LOAD)
        g_once_init_leave(&initialized, good ? 1 : 2);
    }
    return initialized == 1;
}

static const SecretSchema schema = {
    .name = "org.farpane.RemotePassword.v1", .flags = SECRET_SCHEMA_NONE,
    .attributes = { { "peer", SECRET_SCHEMA_ATTRIBUTE_STRING },
                    { "scope", SECRET_SCHEMA_ATTRIBUTE_STRING }, { NULL, 0 } },
};

// 0 success, 1 absent, 2 locked/not unlocked, 3 service unavailable,
// 4 cancelled, 5 operation failed, 6 invalid/ambiguous result, 7 no default collection.
int farpane_secret_execute(int action, const char *peer, const char *scope,
                           const char *password, GCancellable *cancel, char **output) {
    *output = NULL;
    if (!load_library()) return 3;
    GError *error = NULL;
    SecretService *service = api.secret_service_open_sync(api.secret_service_get_type(),
        "org.freedesktop.secrets", SECRET_SERVICE_OPEN_SESSION, cancel, &error);
    if (!service) {
        int result = g_cancellable_is_cancelled(cancel) ? 4 : 3;
        g_clear_error(&error); return result;
    }
    GHashTable *attributes = g_hash_table_new(g_str_hash, g_str_equal);
    g_hash_table_insert(attributes, "peer", (void *)peer);
    g_hash_table_insert(attributes, "scope", (void *)scope);
    GList *items = NULL;
    int result = 5;
    if (action == 1) {
        SecretCollection *collection = api.secret_collection_for_alias_sync(service,
            SECRET_COLLECTION_DEFAULT, SECRET_COLLECTION_NONE, cancel, &error);
        if (!collection) { result = error ? 5 : 7; goto done; }
        if (api.secret_collection_get_locked(collection)) {
            g_object_unref(collection); result = 2; goto done;
        }
        SecretValue *value = api.secret_value_new(password, -1, "text/plain; charset=utf-8");
        gchar *label = g_strdup_printf("FarPane · %s", peer);
        // Use the existing collection directly: no implicit collection creation
        // or service_store's automatic Unlock retry. A concurrent desktop lock
        // is a failed operation, not permission to unlock the user's keyring.
        SecretItem *saved = api.secret_item_create_sync(collection, &schema, attributes,
            label, value, SECRET_ITEM_CREATE_REPLACE, cancel, &error);
        g_object_unref(collection);
        g_free(label); api.secret_value_unref(value);
        result = saved ? 0 : 5;
        if (saved) g_object_unref(saved);
        goto done;
    }
    if (action != 0 && action != 2) { result = 6; goto done; }
    items = api.secret_service_search_sync(service, &schema, attributes,
        SECRET_SEARCH_ALL | (action == 0 ? SECRET_SEARCH_LOAD_SECRETS : 0),
        cancel, &error);
    if (error) goto done;
    if (!items) { result = action == 0 ? 1 : 0; goto done; }
    guint count = g_list_length(items);
    if (count > 16 || (action == 0 && count != 1)) { result = 6; goto done; }
    // A locked item is not absent. Unlocking is deliberately left to the desktop
    // password manager; repeated cancelled Unlock prompts crashed our private
    // GNOME Keyring 50 provider. Do not report deletion of a locked record.
    for (GList *item = items; item; item = item->next) {
        if (api.secret_item_get_locked(item->data)) { result = 2; goto done; }
    }
    if (action == 0) {
        SecretValue *value = api.secret_item_get_secret(items->data);
        if (!value) { result = 2; goto done; }
        gsize size = 0;
        const char *text = api.secret_value_get(value, &size);
        if (size == 0 || size > 4096 || !text || memchr(text, 0, size) || !g_utf8_validate(text, size, NULL)) {
            result = 6;
        } else {
            *output = g_strndup(text, size); result = 0;
        }
        api.secret_value_unref(value);
    } else {
        for (GList *item = items; item; item = item->next) {
            if (!api.secret_item_delete_sync(item->data, cancel, &error)) goto done;
        }
        g_list_free_full(items, g_object_unref); items = NULL;
        // Include locked records in the verification, without loading secrets.
        items = api.secret_service_search_sync(service, &schema, attributes, SECRET_SEARCH_ALL, cancel, &error);
        if (!error && !items) result = 0;
    }
done:
    if (g_cancellable_is_cancelled(cancel)) result = 4;
    g_clear_error(&error);
    g_list_free_full(items, g_object_unref);
    g_hash_table_unref(attributes); g_object_unref(service);
    if (result != 0 && *output) { farpane_secret_free(*output); *output = NULL; }
    return result;
}
void farpane_secret_free(char *value) {
    if (!value) return;
    explicit_bzero(value, strlen(value));
    g_free(value);
}
