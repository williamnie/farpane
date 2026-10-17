/* Test-only GObject lifetime observer. No extra reference is held on objects.
 * The preload is enabled only for the private, ordinary-user GUI executable.
 * Counts cover intercepted public constructors, not all heap allocations. */
#define _GNU_SOURCE
#include <glib-object.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define CAPACITY 16384
#define TYPES 1024
struct record { GObject *object; const char *name; };
struct count { const char *name; unsigned count; };
static struct record objects[CAPACITY];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static unsigned long created, destroyed, overflow;
static int enabled, listener = -1;
static char socket_path[108];
static GObject *(*real_properties)(GType, guint, const char **, const GValue *);
static GObject *(*real_valist)(GType, const char *, va_list);

static void resolve(void) {
    real_properties = dlsym(RTLD_NEXT, "g_object_new_with_properties");
    real_valist = dlsym(RTLD_NEXT, "g_object_new_valist");
    if (!real_properties || !real_valist) _exit(125);
}

static void gone(gpointer data, GObject *object) {
    struct record *record = data;
    pthread_mutex_lock(&mutex);
    if (record->object == object) {
        record->object = NULL;
        destroyed++;
    }
    pthread_mutex_unlock(&mutex);
}

static GObject *observe(GObject *object) {
    if (!enabled || !object) return object;
    const char *name = G_OBJECT_TYPE_NAME(object);
    struct record *empty = NULL;
    pthread_mutex_lock(&mutex);
    for (unsigned i = 0; i < CAPACITY; i++) {
        if (objects[i].object == object) {
            pthread_mutex_unlock(&mutex);
            return object;
        }
        if (!objects[i].object && !empty) empty = &objects[i];
    }
    if (empty) {
        empty->object = object;
        empty->name = name;
        created++;
    } else overflow++;
    pthread_mutex_unlock(&mutex);
    if (empty) g_object_weak_ref(object, gone, empty);
    return object;
}

GObject *g_object_new_with_properties(GType type, guint n, const char *names[], const GValue values[]) {
    pthread_once(&resolve_once, resolve);
    return observe(real_properties(type, n, names, values));
}

GObject *g_object_new_valist(GType type, const char *first, va_list args) {
    pthread_once(&resolve_once, resolve);
    return observe(real_valist(type, first, args));
}

gpointer g_object_new(GType type, const char *first, ...) {
    pthread_once(&resolve_once, resolve);
    va_list args;
    va_start(args, first);
    gpointer object = real_valist(type, first, args);
    va_end(args);
    return observe(object);
}

static void *serve(void *unused) {
    (void)unused;
    for (;;) {
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
        if (fd < 0) return NULL;
        struct ucred peer;
        socklen_t length = sizeof(peer);
        if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) || peer.uid != getuid()) {
            close(fd);
            continue;
        }
        struct count counts[TYPES] = {0};
        unsigned types = 0, total = 0;
        pthread_mutex_lock(&mutex);
        unsigned long added = created, removed = destroyed, dropped = overflow;
        for (unsigned i = 0; i < CAPACITY; i++) {
            if (!objects[i].object) continue;
            unsigned j = 0;
            for (; j < types && strcmp(counts[j].name, objects[i].name); j++);
            if (j == TYPES) { dropped++; continue; }
            if (j == types) counts[types++].name = objects[i].name;
            counts[j].count++;
            total++;
        }
        pthread_mutex_unlock(&mutex);
        struct timeval limit = {.tv_sec = 1};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, sizeof(limit));
        char *buffer = NULL;
        size_t bytes = 0;
        FILE *out = open_memstream(&buffer, &bytes);
        if (!out) { close(fd); continue; }
        fprintf(out, "{\"pid\":%ld,\"alive\":%u,\"created\":%lu,\"destroyed\":%lu,\"overflow\":%lu,\"types\":{",
                (long)getpid(), total, added, removed, dropped);
        for (unsigned i = 0; i < types; i++)
            fprintf(out, "%s\"%s\":%u", i ? "," : "", counts[i].name, counts[i].count);
        fprintf(out, "}}\n");
        fclose(out);
        size_t sent = 0;
        while (sent < bytes) {
            ssize_t n = send(fd, buffer + sent, bytes - sent, MSG_NOSIGNAL);
            if (n <= 0) break;
            sent += (size_t)n;
        }
        free(buffer);
        close(fd);
    }
}

__attribute__((constructor)) static void initialize(void) {
    const char *directory = getenv("FARPANE_OBJECT_OBSERVER_DIR");
    char executable[512];
    ssize_t size = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
    if (!directory || getuid() == 0 || access("/.dockerenv", F_OK) || size < 8) return;
    executable[size] = '\0';
    if (strcmp(executable + size - 8, "/farpane")) return;
    if (snprintf(socket_path, sizeof(socket_path), "%s/object-observer.sock", directory)
            >= (int)sizeof(socket_path)) _exit(125);
    listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strcpy(address.sun_path, socket_path);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address))
            || chmod(socket_path, 0600) || listen(listener, 2)) _exit(125);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 256 * 1024);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    enabled = 1;
    if (pthread_create(&thread, &attr, serve, NULL)) _exit(125);
    pthread_attr_destroy(&attr);
}

__attribute__((destructor)) static void cleanup(void) {
    if (enabled) unlink(socket_path);
}
