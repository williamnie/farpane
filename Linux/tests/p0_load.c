#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    puts("PASS core RTLD_NOW load (no RustDesk entrypoint invoked)");
    if (dlclose(handle)) { fprintf(stderr, "dlclose: %s\n", dlerror()); return 1; }
    return 0;
}
