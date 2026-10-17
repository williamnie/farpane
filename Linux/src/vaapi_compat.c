/* FFmpeg 9 may be built with newer libva headers than the target desktop.
 * Keep its existing vaMapBuffer fallback at runtime without rebuilding FFmpeg
 * or replacing the desktop's libva/driver. Only native final links use --wrap.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <va/va.h>

typedef VAStatus (*MapBuffer2)(VADisplay, VABufferID, void **, uint32_t);
static MapBuffer2 map_buffer2;
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;

static void resolve_map_buffer2(void) {
    map_buffer2 = (MapBuffer2)dlsym(RTLD_DEFAULT, "vaMapBuffer2");
}

VAStatus __wrap_vaMapBuffer2(VADisplay display, VABufferID buffer,
                           void **address, uint32_t flags) {
    pthread_once(&resolve_once, resolve_map_buffer2);
    if (map_buffer2)
        return map_buffer2(display, buffer, address, flags);
    /* Same legacy operation as FFmpeg's VA_CHECK_VERSION < 1.21 branch.
     * A real new-API error is returned above, never retried through this path.
     */
    return vaMapBuffer(display, buffer, address);
}
