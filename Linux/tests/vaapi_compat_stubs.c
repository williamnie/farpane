/* Separate translation unit: caller must resolve through the actual ELF wrap. */
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <va/va.h>
extern atomic_uint old_calls, new_calls;
extern int pixel;
VAStatus vaMapBuffer(VADisplay display, VABufferID buffer, void **address) {
    assert(display == (VADisplay)&pixel && buffer == 73);
    atomic_fetch_add(&old_calls, 1); *address = &pixel;
    return VA_STATUS_SUCCESS;
}
#ifdef NEW_API
VAStatus vaMapBuffer2(VADisplay display, VABufferID buffer, void **address, uint32_t flags) {
    assert(display == (VADisplay)&pixel && buffer == 73);
    assert(flags == 1 || flags == 2 || flags == 3);
    atomic_fetch_add(&new_calls, 1); *address = &pixel;
    return flags == 2 ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_SUCCESS;
}
#endif
