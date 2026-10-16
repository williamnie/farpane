#include <gtk/gtk.h>
#include <epoxy/gl.h>
#include <cairo.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <string.h>

static GtkWidget *window, *area;
static GLuint program, vao, base_texture, text_texture;
static int mode;
static unsigned generation;
static unsigned long long frames;
static gint64 started;
static gboolean ready;

static GLuint shader(GLenum type, const char *source) {
    GLuint id = glCreateShader(type);
    glShaderSource(id, 1, &source, NULL);
    glCompileShader(id);
    GLint ok = 0;
    glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(id, sizeof log, NULL, log);
        fprintf(stderr, "shader: %s\n", log);
        return 0;
    }
    return id;
}

static void label(cairo_t *cr, const char *text, double x, double y, int size) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("Sans");
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);
    cairo_move_to(cr, x, y);
    cairo_set_source_rgb(cr, .95, .97, 1.0);
    pango_cairo_show_layout(cr, layout);
    pango_font_description_free(font);
    g_object_unref(layout);
}

static GLuint texture(gboolean scroll) {
    int w = 2560, h = scroll ? 1120 : 1440;
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(surface);
    cairo_set_source_rgb(cr, .082, .133, .204);
    cairo_paint(cr);
    if (scroll) {
        for (int i = 0; i < 20; i++) {
            char line[192];
            snprintf(line, sizeof line, "%02d  Remote desktop · 0123456789 · RustDesk / FarPane · 滚动文字测试", i + 1);
            label(cr, line, 60, i * 56, 28);
        }
    } else {
        cairo_set_source_rgb(cr, .043, .078, .125);
        cairo_rectangle(cr, 0, 0, w, 140);
        cairo_fill(cr);
        label(cr, "FarPane / RustDesk Host A/B", 50, 24, 36);
        label(cr, "2560 × 1440 · H.264 · 30 FPS target · native GPU fixture", 50, 85, 22);
        const double colors[8][3] = {{1,1,1},{1,1,0},{0,1,1},{0,1,0},{1,0,1},{1,0,0},{0,0,1},{0,0,0}};
        for (int i = 0; i < 8; i++) {
            cairo_set_source_rgb(cr, colors[i][0], colors[i][1], colors[i][2]);
            cairo_rectangle(cr, i * 320, 140, 320, 90);
            cairo_fill(cr);
        }
        label(cr, "Static desktop / 静态画面", 50, 280, 38);
        label(cr, "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ", 50, 350, 38);
        label(cr, "Fine text, sharp edges, solid colors.", 50, 420, 38);
        label(cr, "缓冲区复用测试：文字、颜色、边缘保持一致。", 50, 490, 38);
    }
    cairo_surface_flush(surface);
    GLuint tex;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, scroll ? GL_REPEAT : GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, cairo_image_surface_get_data(surface));
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return tex;
}

static void realize(GtkGLArea *gl, gpointer unused) {
    (void)unused;
    gtk_gl_area_make_current(gl);
    GError *error = gtk_gl_area_get_error(gl);
    if (error) {
        fprintf(stderr, "GLArea: %s\n", error->message);
        return;
    }
    const char *vs = "#version 330 core\n"
        "out vec2 uv;void main(){vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));"
        "gl_Position=vec4(p[gl_VertexID],0,1);uv=(p[gl_VertexID]+1)*0.5;}";
    const char *fs = "#version 330 core\n"
        "in vec2 uv;out vec4 color;uniform sampler2D base;uniform sampler2D text;uniform int mode;uniform float t;"
        "void main(){vec2 p=vec2(uv.x,1-uv.y);float y=p.y*1440.;"
        "if(mode==0||y<230.){color=texture(base,p);return;}"
        "if(mode==1){color=texture(text,vec2(p.x,(y-230.+t*56.)/1120.));return;}"
        "vec2 q=vec2(p.x,(y-230.)/1210.);float c=mod(floor(p.x*2560./80.)+floor(y/80.),2.);"
        "vec3 rgb=mix(vec3(.098,.169,.263),vec3(.149,.267,.384),c);"
        "vec3 cs[4]=vec3[4](vec3(1,.745,.239),vec3(.286,.843,.761),vec3(.925,.431,.522),vec3(.549,.62,1));"
        "for(int i=0;i<4;i++){float z=mod(t+float(i)*2.,16.);float a=z<8.?z/8.:2.-z/8.;"
        "vec2 center=vec2(.13+float(i)*.18+.18*a,.2+float(i%3)*.24+.08*a);"
        "float r=a*3.14159265;vec2 d=(q-center)*vec2(2560.,1210.);d=mat2(cos(r),-sin(r),sin(r),cos(r))*d;"
        "vec2 edge=abs(d)-vec2(240.,150.);if(max(edge.x,edge.y)<0.)rgb=cs[i];"
        "if(max(edge.x,edge.y)<0.&&max(edge.x,edge.y)>-5.)rgb=vec3(1.);}color=vec4(rgb,1);}";
    GLuint vertex = shader(GL_VERTEX_SHADER, vs), fragment = shader(GL_FRAGMENT_SHADER, fs);
    if (!vertex || !fragment) return;
    program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    GLint ok;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) { fprintf(stderr, "shader link failed\n"); return; }
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    glGenVertexArrays(1, &vao);
    base_texture = texture(FALSE);
    text_texture = texture(TRUE);
    fprintf(stderr, "GL renderer: %s; version: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
    if (strstr((const char *)glGetString(GL_RENDERER), "llvmpipe") || strstr((const char *)glGetString(GL_RENDERER), "softpipe")) {
        fprintf(stderr, "Software GL is not a valid fixture backend\n");
        return;
    }
    ready = TRUE;
    gtk_gl_area_queue_render(gl);
}

static gboolean render(GtkGLArea *gl, GdkGLContext *context, gpointer unused) {
    (void)gl; (void)context; (void)unused;
    if (!ready) return TRUE;
    int scale = gtk_widget_get_scale_factor(area);
    glViewport(0, 0, gtk_widget_get_allocated_width(area) * scale, gtk_widget_get_allocated_height(area) * scale);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "mode"), mode);
    glUniform1f(glGetUniformLocation(program, "t"), (g_get_monotonic_time() - started) / 1000000.);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, base_texture);
    glUniform1i(glGetUniformLocation(program, "base"), 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, text_texture);
    glUniform1i(glGetUniformLocation(program, "text"), 1);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    frames++;
    return TRUE;
}

static gboolean tick(GtkWidget *widget, GdkFrameClock *clock, gpointer unused) {
    (void)clock; (void)unused;
    if (mode != 0) gtk_gl_area_queue_render(GTK_GL_AREA(widget));
    return G_SOURCE_CONTINUE;
}

static gboolean heartbeat(gpointer unused) {
    (void)unused;
    printf("{\"generation\":%u,\"visible\":%s,\"focused\":%s,\"animationFrames\":%llu,\"viewport\":{\"width\":%d,\"height\":%d,\"dpr\":%d}}\n",
        generation, ready && gtk_widget_get_mapped(area) ? "true" : "false",
        gtk_window_is_active(GTK_WINDOW(window)) ? "true" : "false", frames,
        gtk_widget_get_allocated_width(area), gtk_widget_get_allocated_height(area), gtk_widget_get_scale_factor(area));
    fflush(stdout);
    return G_SOURCE_CONTINUE;
}

static gboolean input(GIOChannel *channel, GIOCondition condition, gpointer unused) {
    (void)unused;
    if (condition & G_IO_HUP) { gtk_main_quit(); return G_SOURCE_REMOVE; }
    gchar *line = NULL;
    while (g_io_channel_read_line(channel, &line, NULL, NULL, NULL) == G_IO_STATUS_NORMAL) {
        char name[32]; unsigned next;
        if (sscanf(line, "MODE %31s %u", name, &next) == 2) {
            mode = !strcmp(name, "scroll") ? 1 : !strcmp(name, "motion") ? 2 : 0;
            generation = next; frames = 0; started = g_get_monotonic_time();
            gtk_gl_area_queue_render(GTK_GL_AREA(area));
        }
        g_free(line); line = NULL;
    }
    g_free(line);
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
    if (!gtk_init_check(&argc, &argv)) { fprintf(stderr, "No GTK display\n"); return 1; }
    g_set_prgname("rd-perf-fixture");
    window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(window), "RustDesk A/B GPU fixture");
    gtk_window_set_default_size(GTK_WINDOW(window), 2560, 1440);
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    area = gtk_gl_area_new();
    gtk_gl_area_set_required_version(GTK_GL_AREA(area), 3, 3);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area), FALSE);
    gtk_widget_set_can_focus(area, TRUE);
    gtk_container_add(GTK_CONTAINER(window), area);
    g_signal_connect(area, "realize", G_CALLBACK(realize), NULL);
    g_signal_connect(area, "render", G_CALLBACK(render), NULL);
    g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    gtk_widget_add_tick_callback(area, tick, NULL, NULL);
    GIOChannel *channel = g_io_channel_unix_new(0);
    g_io_channel_set_flags(channel, G_IO_FLAG_NONBLOCK, NULL);
    g_io_add_watch(channel, G_IO_IN | G_IO_HUP, input, NULL);
    started = g_get_monotonic_time();
    gtk_widget_show_all(window);
    gtk_window_fullscreen(GTK_WINDOW(window));
    gtk_window_present(GTK_WINDOW(window));
    gtk_widget_grab_focus(area);
    g_timeout_add(500, heartbeat, NULL);
    gtk_main();
    g_io_channel_unref(channel);
    return 0;
}
