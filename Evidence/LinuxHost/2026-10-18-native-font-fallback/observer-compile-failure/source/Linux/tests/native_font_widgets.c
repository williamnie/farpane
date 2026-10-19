/* Read-only GTK widget observations in the private font test. No UI actions. */
#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <gdk/x11/gdkx.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char *directory;
static char previous[32];

static void string(GString *out, const char *value) {
    g_string_append_c(out, '"');
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') g_string_append_c(out, '\\');
        if (*p < 32) g_string_append_printf(out, "\\u%04x", *p);
        else g_string_append_c(out, *p);
    }
    g_string_append_c(out, '"');
}

static void walk(GtkWidget *widget, GtkWidget *root, unsigned long xid,
                 GString *out, guint *visited, guint *emitted) {
    if (++*visited > 10000) return;
    graphene_rect_t rect;
    gboolean shown = gtk_widget_get_mapped(widget) &&
        gtk_widget_compute_bounds(widget, root, &rect) &&
        rect.size.width > 0 && rect.size.height > 0 &&
        rect.origin.x >= 0 && rect.origin.y >= 0 &&
        rect.origin.x + rect.size.width <= gtk_widget_get_width(root) &&
        rect.origin.y + rect.size.height <= gtk_widget_get_height(root);
    if (shown && (GTK_IS_LABEL(widget) || GTK_IS_EDITABLE(widget) || GTK_IS_BUTTON(widget))) {
        if ((*emitted)++) g_string_append_c(out, ',');
        g_string_append(out, "{\"type\":"); string(out, G_OBJECT_TYPE_NAME(widget));
        g_string_append(out, ",\"name\":"); string(out, gtk_widget_get_name(widget));
        g_string_append_printf(out, ",\"surface_xid\":%lu,\"bounds\":[%.2f,%.2f,%.2f,%.2f]",
            xid, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        if (GTK_IS_LABEL(widget)) {
            g_string_append(out, ",\"text\":"); string(out, gtk_label_get_text(GTK_LABEL(widget)));
            PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(widget));
            g_string_append_printf(out, ",\"unknown_glyphs\":%d,\"font_runs\":[",
                                   pango_layout_get_unknown_glyphs_count(layout));
            PangoLayoutIter *it = pango_layout_get_iter(layout);
            guint runs = 0;
            do {
                PangoLayoutRun *run = pango_layout_iter_get_run_readonly(it);
                if (run && run->item->analysis.font) {
                    PangoFontDescription *desc = pango_font_describe(run->item->analysis.font);
                    char *text = pango_font_description_to_string(desc);
                    if (runs++) g_string_append_c(out, ',');
                    string(out, text); g_free(text); pango_font_description_free(desc);
                }
            } while (pango_layout_iter_next_run(it));
            pango_layout_iter_free(it);
            g_string_append_c(out, ']');
        } else if (GTK_IS_EDITABLE(widget)) {
            g_string_append(out, ",\"text\":"); string(out, gtk_editable_get_text(GTK_EDITABLE(widget)));
        }
        g_string_append_c(out, '}');
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) walk(child, root, xid, out, visited, emitted);
}

static gboolean observe(gpointer unused) {
    (void)unused;
    char *request = g_build_filename(directory, "request", NULL);
    int fd = open(request, O_RDONLY | O_CLOEXEC | O_NOFOLLOW); g_free(request);
    if (fd < 0) return G_SOURCE_CONTINUE;
    char phase[32] = {0}; ssize_t length = read(fd, phase, sizeof(phase) - 1); close(fd);
    if (length <= 0 || strcmp(previous, phase) == 0 ||
        (strcmp(phase, "home") && strcmp(phase, "alias") && strcmp(phase, "edit") && strcmp(phase, "returned")))
        return G_SOURCE_CONTINUE;
    if (!gtk_is_initialized()) return G_SOURCE_CONTINUE;
    GListModel *windows = gtk_window_get_toplevels();
    GString *out = g_string_new("{\"widgets\":["); guint visited = 0, emitted = 0;
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GtkWidget *window = g_list_model_get_item(windows, i);
        GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
        if (surface && GDK_IS_X11_SURFACE(surface))
            walk(window, window, gdk_x11_surface_get_xid(surface), out, &visited, &emitted);
        g_object_unref(window);
    }
    g_string_append_printf(out, "],\"visited\":%u,\"truncated\":%s}\n", visited, visited > 10000 ? "true" : "false");
    char *name = g_strdup_printf("%s.json", phase);
    char *target = g_build_filename(directory, name, NULL); g_free(name);
    fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd >= 0) {
        ssize_t written = write(fd, out->str, out->len);
        if (written == (ssize_t)out->len) g_strlcpy(previous, phase, sizeof(previous));
        close(fd);
    }
    g_free(target); g_string_free(out, TRUE);
    return G_SOURCE_CONTINUE;
}

__attribute__((constructor)) static void setup(void) {
    const char *mode = getenv("FARPANE_NATIVE_TEST_MODE"), *home = getenv("HOME");
    const char *path = getenv("FARPANE_FONT_WIDGET_DIR");
    if (!mode || strcmp(mode, "home-fonts") || !home || strcmp(home, "/run/farpane-native-test/user") ||
        !path || strncmp(path, "/output/run/home-", 17) || strstr(path, "..") ||
        getuid() == 0 || access("/.dockerenv", F_OK) ||
        !access("/dev/dri", F_OK) || !access("/dev/input", F_OK) ||
        !access("/dev/uinput", F_OK) || !access("/dev/kvm", F_OK)) return;
    struct stat info;
    if (lstat(path, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0777) != 0700) return;
    directory = g_strdup(path);
    g_timeout_add(100, observe, NULL);
}
