#pragma once
#include <gio/gio.h>
int farpane_secret_execute(int action, const char *peer, const char *scope,
                           const char *password, GCancellable *cancel, char **output);
void farpane_secret_free(char *value);
