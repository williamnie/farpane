#define _GNU_SOURCE
/* Test-only preload: report the first actual current EGL context. It does not
 * create a context, select a driver, or change the application's renderer. */
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static EGLBoolean (*real_make_current)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static pthread_once_t report_once = PTHREAD_ONCE_INIT;

static void resolve(void) {
    real_make_current = dlsym(RTLD_NEXT, "eglMakeCurrent");
    if (!real_make_current) {
        fputs("FARPANE_GL_IDENTITY_ERROR=eglMakeCurrent resolution failed\n", stderr);
        abort();
    }
}

static void report(void) {
    const GLubyte *vendor = glGetString(GL_VENDOR);
    const GLubyte *renderer = glGetString(GL_RENDERER);
    const GLubyte *version = glGetString(GL_VERSION);
    fprintf(stderr, "FARPANE_GL_VENDOR=%s\nFARPANE_GL_RENDERER=%s\nFARPANE_GL_VERSION=%s\n",
            vendor ? (const char *)vendor : "unavailable",
            renderer ? (const char *)renderer : "unavailable",
            version ? (const char *)version : "unavailable");
}

EGLBoolean eglMakeCurrent(EGLDisplay display, EGLSurface draw, EGLSurface read, EGLContext context) {
    pthread_once(&resolve_once, resolve);
    EGLBoolean result = real_make_current(display, draw, read, context);
    if (result && context != EGL_NO_CONTEXT)
        pthread_once(&report_once, report);
    return result;
}

/* GTK calls libepoxy's exported dispatch pointer, which otherwise resolves
 * libEGL through its own handle and bypasses ordinary ELF interposition. */
EGLBoolean (*epoxy_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = eglMakeCurrent;
