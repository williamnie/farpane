/* Actual ELF symbol lookup with/without the optional API; no GPU is opened. */
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <va/va.h>

extern VAStatus vaMapBuffer2(VADisplay, VABufferID, void **, uint32_t);
atomic_uint old_calls, new_calls;
int pixel;
static atomic_uint lookup_calls;
extern void *__real_dlsym(void *, const char *);
void *__wrap_dlsym(void *handle, const char *symbol) {
    atomic_fetch_add(&lookup_calls, 1);
    return __real_dlsym(handle, symbol);
}
static void *exercise(void *unused) {
    (void)unused;
    for (uint32_t flags = 1; flags <= 3; ++flags) {
        void *address = NULL;
        VAStatus status = vaMapBuffer2((VADisplay)&pixel, 73, &address, flags);
#ifdef NEW_API
        assert(status == (flags == 2 ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_SUCCESS));
#else
        assert(status == VA_STATUS_SUCCESS);
#endif
        assert(address == &pixel);
    }
    return NULL;
}
int main(void) {
    pthread_t threads[8];
    for (int i = 0; i < 8; ++i) assert(pthread_create(&threads[i], NULL, exercise, NULL) == 0);
    for (int i = 0; i < 8; ++i) assert(pthread_join(threads[i], NULL) == 0);
    assert(lookup_calls == 1);
#ifdef NEW_API
    assert(new_calls == 24 && old_calls == 0);
    puts("PASS: optional API preserves all flags/results, no legacy retry on error");
#else
    assert(old_calls == 24 && new_calls == 0);
    puts("PASS: absent optional API uses legacy mapping; concurrent resolution bounded");
#endif
}
