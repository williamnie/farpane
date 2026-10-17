/* Test-only live allocation stacks from the existing ASan runtime. This
 * replaces the test process allocator: its PSS/CPU are NOT product budgets.
 * The ordinary immutable GUI is unchanged; no sanitizer instrumentation is
 * claimed for application instructions or direct/non-malloc mappings. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void (*profile)(size_t, size_t);

static void dump(unsigned second) {
    fprintf(stderr, "FARPANE_ALLOCATION_PROFILE_BEGIN=%u\n", second);
    profile(100, 4096);
    fprintf(stderr, "FARPANE_ALLOCATION_PROFILE_END=%u\n", second);
    fflush(stderr);
}

static void delay(unsigned seconds) {
    struct timespec remaining = {.tv_sec = seconds};
    while (nanosleep(&remaining, &remaining) != 0) {}
}

static void *observe(void *unused) {
    (void)unused;
    /* One steady snapshot avoids a large early report delaying startup and
     * the next capture. Reporting itself can take several seconds. */
    delay(20); dump(20);
    return NULL;
}

__attribute__((constructor)) static void initialize(void) {
    char executable[512];
    const char *enabled = getenv("FARPANE_ALLOCATION_PROFILE");
    ssize_t size = readlink("/proc/self/exe", executable, sizeof(executable) - 1);
    if (!enabled || strcmp(enabled, "1") || getuid() == 0 || access("/.dockerenv", F_OK) || size < 8) return;
    executable[size] = '\0';
    if (strcmp(executable + size - 8, "/farpane")) return;
    profile = dlsym(RTLD_DEFAULT, "__sanitizer_print_memory_profile");
    if (!profile) _exit(125);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (pthread_create(&thread, &attr, observe, NULL)) _exit(125);
    pthread_attr_destroy(&attr);
}

#ifdef FARPANE_PROFILE_SELF_TEST
int main(void) {
    profile = dlsym(RTLD_DEFAULT, "__sanitizer_print_memory_profile");
    if (!profile) return 125;
    /* This ASan version asserts on an entirely empty heap. Keep one control
     * allocation so the second report can verify release of the large one. */
    void *control = malloc(1024);
    void *allocation = malloc(4 * 1024 * 1024);
    if (!allocation || !control) return 1;
    memset(allocation, 0x5a, 4 * 1024 * 1024);
    /* Escape the allocation so optimization cannot remove the fixture. */
    __asm__ volatile("" : : "r"(allocation), "r"(control) : "memory");
    dump(0);
    free(allocation);
    dump(1);
    free(control);
    return 0;
}
#endif
