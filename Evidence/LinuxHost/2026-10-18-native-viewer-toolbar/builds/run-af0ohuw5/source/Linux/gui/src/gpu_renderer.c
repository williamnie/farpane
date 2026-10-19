#define _GNU_SOURCE
/* EGL/GLES3 renderer. Decoder planes are sampled exactly once into an owned
 * RGBA texture. Later GTK redraws never sample a returned decoder surface. */
#include "gpu_renderer.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <limits.h>
#include <fcntl.h>
#include <gbm.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FP_R8 0x20203852u
#define FP_GR88 0x38385247u
#define FP_MAX_FORMATS 128
struct FpGpu {
    EGLDisplay display;
    EGLContext context;
    PFNEGLCREATEIMAGEKHRPROC create_image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target;
    FpImportFormat formats[FP_MAX_FORMATS];
    size_t format_count;
    GLuint convert, copy, vao, rgb, framebuffer, input[2];
    EGLImageKHR images[2];
    GLsync fence;
    int submitted;
    uint32_t width, height;
};
typedef struct {
    GLint draw, read, viewport[4], program, vao, active, textures[3];
    GLboolean blend, scissor, depth, stencil, cull, color_mask[4];
    GLfloat clear_color[4];
} Saved;
static void save(Saved *s) {
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&s->draw);
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&s->read);
    glGetIntegerv(GL_VIEWPORT,s->viewport);
    glGetIntegerv(GL_CURRENT_PROGRAM,&s->program);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING,&s->vao);
    glGetIntegerv(GL_ACTIVE_TEXTURE,&s->active);
    for(int i=0;i<3;i++){glActiveTexture(GL_TEXTURE0+i);glGetIntegerv(GL_TEXTURE_BINDING_2D,&s->textures[i]);}
    s->blend=glIsEnabled(GL_BLEND);s->scissor=glIsEnabled(GL_SCISSOR_TEST);
    s->depth=glIsEnabled(GL_DEPTH_TEST);s->stencil=glIsEnabled(GL_STENCIL_TEST);s->cull=glIsEnabled(GL_CULL_FACE);
    glGetBooleanv(GL_COLOR_WRITEMASK,s->color_mask);glGetFloatv(GL_COLOR_CLEAR_VALUE,s->clear_color);
    glDisable(GL_BLEND);glDisable(GL_SCISSOR_TEST);glDisable(GL_DEPTH_TEST);glDisable(GL_STENCIL_TEST);glDisable(GL_CULL_FACE);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
}
static void enabled(GLenum cap,GLboolean value){if(value)glEnable(cap);else glDisable(cap);}
static void restore(const Saved *s) {
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,s->draw);glBindFramebuffer(GL_READ_FRAMEBUFFER,s->read);
    glViewport(s->viewport[0],s->viewport[1],s->viewport[2],s->viewport[3]);
    glUseProgram(s->program);glBindVertexArray(s->vao);
    for(int i=0;i<3;i++){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,s->textures[i]);}
    glActiveTexture(s->active);
    enabled(GL_BLEND,s->blend);enabled(GL_SCISSOR_TEST,s->scissor);enabled(GL_DEPTH_TEST,s->depth);
    enabled(GL_STENCIL_TEST,s->stencil);enabled(GL_CULL_FACE,s->cull);
    glColorMask(s->color_mask[0],s->color_mask[1],s->color_mask[2],s->color_mask[3]);
    glClearColor(s->clear_color[0],s->clear_color[1],s->clear_color[2],s->clear_color[3]);
}
static int fail(char *error,size_t n,const char *message){if(n)snprintf(error,n,"%s",message);return -1;}
static int current(FpGpu *g){return g&&eglGetCurrentDisplay()==g->display&&eglGetCurrentContext()==g->context;}
static int extension(const char *list,const char *name) {
    if(!list)return 0;
    size_t n=strlen(name);const char *p=list;
    while((p=strstr(p,name))){if((p==list||p[-1]==' ')&&(p[n]==0||p[n]==' '))return 1;p+=n;}
    return 0;
}
static const char *vertex =
    "#version 300 es\nprecision highp float; out vec2 uv;"
    "void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2.-1.,0.,1.);}";
static const char *fragment =
    "#version 300 es\nprecision highp float; in vec2 uv; out vec4 color;"
    "uniform sampler2D yplane; uniform sampler2D uvplane;"
    "uniform vec4 levels; uniform vec4 coefficients; uniform vec2 chroma_offset;"
    "void main(){float y=(texture(yplane,uv).r-levels.x)*levels.y;"
    "vec2 c=(texture(uvplane,uv+chroma_offset).rg-vec2(128./255.))*levels.z;"
    "color=vec4(clamp(vec3(y+coefficients.x*c.y,y+coefficients.y*c.x+coefficients.z*c.y,y+coefficients.w*c.x),0.,1.),1.);}";
static const char *copy_fragment =
    "#version 300 es\nprecision highp float; in vec2 uv; out vec4 color; uniform sampler2D image;"
    "void main(){color=texture(image,vec2(uv.x,1.-uv.y));}";
static GLuint shader(GLenum type,const char *source,char *error,size_t n) {
    GLuint s=glCreateShader(type);if(!s){fail(error,n,"GL shader allocation failed");return 0;}
    glShaderSource(s,1,&source,NULL);glCompileShader(s);GLint ok=0;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok){if(n)glGetShaderInfoLog(s,(GLsizei)n,NULL,error);glDeleteShader(s);return 0;}return s;
}
static GLuint program(const char *frag,char *error,size_t n) {
    GLuint v=shader(GL_VERTEX_SHADER,vertex,error,n);if(!v)return 0;
    GLuint f=shader(GL_FRAGMENT_SHADER,frag,error,n);if(!f){glDeleteShader(v);return 0;}
    GLuint p=glCreateProgram();glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);
    glDeleteShader(v);glDeleteShader(f);GLint ok=0;glGetProgramiv(p,GL_LINK_STATUS,&ok);
    if(!ok){if(n)glGetProgramInfoLog(p,(GLsizei)n,NULL,error);glDeleteProgram(p);return 0;}return p;
}
static void parameters(void){
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
}
static void release_inputs(FpGpu *g) {
    if(g->fence){glDeleteSync(g->fence);g->fence=NULL;}
    for(int i=0;i<2;i++)if(g->images[i]){g->destroy_image(g->display,g->images[i]);g->images[i]=EGL_NO_IMAGE_KHR;}
    g->submitted=0;
}
static int probe_owned_plane(FpGpu *g,uint32_t format,uint64_t *modifier) {
    /* Some Mesa drivers advertise a format but no explicit modifiers. Do not
     * interpret that as LINEAR. Prove one exact import with a tiny GBM
     * allocation on this EGL display's own render node, without sampling it. */
    PFNEGLQUERYDISPLAYATTRIBEXTPROC display_attribute=(PFNEGLQUERYDISPLAYATTRIBEXTPROC)eglGetProcAddress("eglQueryDisplayAttribEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC device_string=(PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress("eglQueryDeviceStringEXT");
    EGLAttrib device=0;
    if(!display_attribute||!device_string||!display_attribute(g->display,EGL_DEVICE_EXT,&device))return 0;
    const char *path=device_string((EGLDeviceEXT)device,EGL_DRM_RENDER_NODE_FILE_EXT);
    if(!path||strncmp(path,"/dev/dri/renderD",16))return 0;
    int fd=open(path,O_RDWR|O_CLOEXEC);if(fd<0)return 0;
    struct stat metadata;
    if(fstat(fd,&metadata)||!S_ISCHR(metadata.st_mode)||major(metadata.st_rdev)!=226||minor(metadata.st_rdev)<128||minor(metadata.st_rdev)>255){close(fd);return 0;}
    struct gbm_device *gbm=gbm_create_device(fd);
    struct gbm_bo *bo=gbm?gbm_bo_create(gbm,16,16,format,GBM_BO_USE_LINEAR|GBM_BO_USE_RENDERING):NULL;
    uint64_t layout=bo?gbm_bo_get_modifier(bo):0;
    int plane_fd=bo?gbm_bo_get_fd(bo):-1;
    int success=0;
    if(plane_fd>=0){
        EGLint attrs[]={EGL_WIDTH,16,EGL_HEIGHT,16,EGL_LINUX_DRM_FOURCC_EXT,(EGLint)format,
            EGL_DMA_BUF_PLANE0_FD_EXT,plane_fd,EGL_DMA_BUF_PLANE0_OFFSET_EXT,0,EGL_DMA_BUF_PLANE0_PITCH_EXT,(EGLint)gbm_bo_get_stride(bo),
            EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,(EGLint)(uint32_t)layout,EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,(EGLint)(uint32_t)(layout>>32),EGL_NONE};
        EGLImageKHR image=g->create_image(g->display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,NULL,attrs);
        if(image){
            Saved saved;save(&saved);GLuint texture=0;glGenTextures(1,&texture);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);
            g->image_target(GL_TEXTURE_2D,image);success=glGetError()==GL_NO_ERROR;
            glDeleteTextures(1,&texture);restore(&saved);g->destroy_image(g->display,image);
        }
        close(plane_fd);
    }
    if(bo)gbm_bo_destroy(bo);
    if(gbm)gbm_device_destroy(gbm);
    close(fd);
    if(success)*modifier=layout; /* Preserve INVALID; never relabel it LINEAR. */
    return success;
}
FpGpu *fp_gpu_new(char *error,size_t n) {
    EGLDisplay display=eglGetCurrentDisplay();EGLContext context=eglGetCurrentContext();
    if(display==EGL_NO_DISPLAY||context==EGL_NO_CONTEXT){fail(error,n,"No current EGL context (GLX is not DMA-BUF compatible)");return NULL;}
    const char *version=(const char *)glGetString(GL_VERSION);GLint major=0;glGetIntegerv(GL_MAJOR_VERSION,&major);
    if(!version||!strstr(version,"OpenGL ES")||major<3){fail(error,n,"An EGL OpenGL ES 3 context is required");return NULL;}
    FpGpu *g=calloc(1,sizeof(*g));if(!g){fail(error,n,"Renderer allocation failed");return NULL;}
    g->display=display;g->context=context;
    Saved saved;save(&saved);
    g->convert=program(fragment,error,n);g->copy=program(copy_fragment,error,n);glGenVertexArrays(1,&g->vao);
    glGenTextures(2,g->input);
    restore(&saved);
    if(!g->convert||!g->copy||!g->vao||!g->input[0]||!g->input[1]){fp_gpu_destroy(g);return NULL;}
    const char *ext=eglQueryString(display,EGL_EXTENSIONS);
    const char *gl_ext=(const char *)glGetString(GL_EXTENSIONS);
    if(extension(ext,"EGL_EXT_image_dma_buf_import")&&extension(ext,"EGL_EXT_image_dma_buf_import_modifiers")&&extension(gl_ext,"GL_OES_EGL_image")) {
        g->create_image=(PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
        g->destroy_image=(PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
        g->image_target=(PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
        PFNEGLQUERYDMABUFFORMATSEXTPROC query_formats=(PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
        PFNEGLQUERYDMABUFMODIFIERSEXTPROC query=(PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
        EGLint advertised[256],advertised_count=0;
        if(g->create_image&&g->destroy_image&&g->image_target&&query&&query_formats&&
                query_formats(display,256,advertised,&advertised_count)&&advertised_count>=0&&advertised_count<=256){
            uint32_t formats[]={FP_R8,FP_GR88};
            for(int j=0;j<2;j++){
                int supported=0;
                for(int i=0;i<advertised_count;i++)if((uint32_t)advertised[i]==formats[j])supported=1;
                if(!supported)continue;
                EGLint count=0;EGLuint64KHR mods[64];EGLBoolean external[64];
                if(query(display,(EGLint)formats[j],64,mods,external,&count)&&count>=0&&count<=64){
                    for(int i=0;i<count;i++)if(!external[i])g->formats[g->format_count++]=(FpImportFormat){formats[j],mods[i]};
                    uint64_t proven=0;
                    if(count==0&&probe_owned_plane(g,formats[j],&proven))g->formats[g->format_count++]=(FpImportFormat){formats[j],proven};
                }
            }
        }
    }
    return g;
}
size_t fp_gpu_formats(const FpGpu *g,FpImportFormat *out,size_t n){
    if(!g)return 0;
    size_t count=g->format_count<n?g->format_count:n;
    if(out&&count)memcpy(out,g->formats,count*sizeof(*out));
    return count;
}
static int valid(FpGpu *g,const FpGpuFrame *f,char *error,size_t n){
    if(!current(g))return fail(error,n,"Renderer context is not current");
    if(g->submitted)return fail(error,n,"Prior GPU lease is still in flight");
    if(!f||!f->width||!f->height||f->width%2||f->height%2||(uint64_t)f->width*f->height>2560u*1600u)
        return fail(error,n,"Frame exceeds renderer dimensions");
    if(f->matrix<0||f->matrix>1||f->range<0||f->range>1||f->chroma<0||f->chroma>1)return fail(error,n,"Unsupported color metadata");
    return 0;
}
static int convert(FpGpu *g,const FpGpuFrame *f,char *error,size_t n){
    if(!g->rgb){glGenTextures(1,&g->rgb);glGenFramebuffers(1,&g->framebuffer);}
    glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,g->rgb);
    if(g->width!=f->width||g->height!=f->height){
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,f->width,f->height,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);parameters();
        g->width=f->width;g->height=f->height;
    }
    glBindFramebuffer(GL_FRAMEBUFFER,g->framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,g->rgb,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)return fail(error,n,"Owned RGB framebuffer is incomplete");
    glViewport(0,0,f->width,f->height);glUseProgram(g->convert);glBindVertexArray(g->vao);
    for(int i=0;i<2;i++){glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,g->input[i]);}
    glUniform1i(glGetUniformLocation(g->convert,"yplane"),0);glUniform1i(glGetUniformLocation(g->convert,"uvplane"),1);
    glUniform4f(glGetUniformLocation(g->convert,"levels"),f->range?0.f:16.f/255.f,f->range?1.f:255.f/219.f,f->range?1.f:255.f/224.f,0.f);
    const float kr=f->matrix?.2126f:.299f,kb=f->matrix?.0722f:.114f,kg=1.f-kr-kb;
    glUniform4f(glGetUniformLocation(g->convert,"coefficients"),2.f*(1.f-kr),-2.f*kb*(1.f-kb)/kg,-2.f*kr*(1.f-kr)/kg,2.f*(1.f-kb));
    glUniform2f(glGetUniformLocation(g->convert,"chroma_offset"),f->chroma?0.f:.5f/(float)f->width,0.f);
    glDrawArrays(GL_TRIANGLES,0,3);
    g->fence=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);glFlush();
    if(!g->fence||glGetError()!=GL_NO_ERROR)return fail(error,n,"GPU conversion or completion fence failed");
    return 0;
}
int fp_gpu_submit(FpGpu *g,const FpGpuFrame *f,char *error,size_t n){
    if(valid(g,f,error,n))return -1;
    if(!g->create_image||!g->image_target)return fail(error,n,"DMA-BUF import is unavailable");
    for(int i=0;i<2;i++){
        const FpPlane *p=&f->planes[i];int supported=0;
        for(size_t j=0;j<g->format_count;j++)if(g->formats[j].format==p->format&&g->formats[j].modifier==p->modifier)supported=1;
        if(!supported||p->format!=(i?FP_GR88:FP_R8)||p->width!=f->width/(i?2:1)||p->height!=f->height/(i?2:1)||p->fd<0||p->offset>INT_MAX||p->pitch>INT_MAX)
            return fail(error,n,"Unnegotiated or invalid DMA-BUF plane");
    }
    Saved saved;save(&saved);g->submitted=1;int result=0;
    for(int i=0;i<2;i++){
        const FpPlane *p=&f->planes[i];
        EGLint attrs[]={EGL_WIDTH,(EGLint)p->width,EGL_HEIGHT,(EGLint)p->height,EGL_LINUX_DRM_FOURCC_EXT,(EGLint)p->format,
            EGL_DMA_BUF_PLANE0_FD_EXT,p->fd,EGL_DMA_BUF_PLANE0_OFFSET_EXT,(EGLint)p->offset,EGL_DMA_BUF_PLANE0_PITCH_EXT,(EGLint)p->pitch,
            EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT,(EGLint)(uint32_t)p->modifier,EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT,(EGLint)(uint32_t)(p->modifier>>32),EGL_NONE};
        g->images[i]=g->create_image(g->display,EGL_NO_CONTEXT,EGL_LINUX_DMA_BUF_EXT,NULL,attrs);
        if(!g->images[i]){result=fail(error,n,"DMA-BUF EGLImage import failed");break;}
        glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,g->input[i]);
        g->image_target(GL_TEXTURE_2D,g->images[i]);parameters();
        if(glGetError()!=GL_NO_ERROR){result=fail(error,n,"EGLImage cannot be sampled as a 2D plane");break;}
    }
    if(!result)result=convert(g,f,error,n);
    restore(&saved);return result;
}
int fp_gpu_poll(FpGpu *g,char *error,size_t n){
    if(!current(g))return fail(error,n,"Fence query has no matching current context");
    if(!g->fence)return g->submitted?fail(error,n,"GPU submission has no completion fence"):1;
    GLenum result=glClientWaitSync(g->fence,0,0);
    if(result==GL_TIMEOUT_EXPIRED)return 0;
    if(result!=GL_ALREADY_SIGNALED&&result!=GL_CONDITION_SATISFIED)return fail(error,n,"GPU completion fence failed");
    release_inputs(g);return 1;
}
int fp_gpu_draw(FpGpu *g,int width,int height,char *error,size_t n){
    if(!current(g))return fail(error,n,"Draw has no matching current context");
    if(width<=0||height<=0)return 0;
    Saved saved;save(&saved);glViewport(0,0,width,height);glClearColor(0.f,0.f,0.f,1.f);glClear(GL_COLOR_BUFFER_BIT);
    if(g->rgb){
        double scale=(double)width/g->width; if((double)height/g->height<scale)scale=(double)height/g->height;
        int w=(int)(g->width*scale),h=(int)(g->height*scale);glViewport((width-w)/2,(height-h)/2,w,h);
        glUseProgram(g->copy);glBindVertexArray(g->vao);glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,g->rgb);
        glUniform1i(glGetUniformLocation(g->copy,"image"),2);glDrawArrays(GL_TRIANGLES,0,3);
    }
    GLenum result=glGetError();restore(&saved);return result==GL_NO_ERROR?0:fail(error,n,"GPU presentation failed");
}
void fp_gpu_destroy(FpGpu *g){
    if(!g)return;
    if(current(g)){
        /* Deletion retires GL-owned objects; it is NEVER a completion/ACK signal.
         * On context loss the owner retires the worker instead of recycling. */
        release_inputs(g);glDeleteTextures(2,g->input);glDeleteTextures(1,&g->rgb);glDeleteFramebuffers(1,&g->framebuffer);
        glDeleteProgram(g->convert);glDeleteProgram(g->copy);glDeleteVertexArrays(1,&g->vao);
    } else if(g->destroy_image) {
        /* EGLImages outlive a context; release those references even on context
         * loss. Driver-held references still protect submitted work. No ACK. */
        for(int i=0;i<2;i++)if(g->images[i])g->destroy_image(g->display,g->images[i]);
    }
    free(g);
}
int fp_gpu_test_upload(FpGpu *g,const FpGpuFrame *f,const uint8_t *y,const uint8_t *uv,char *error,size_t n){
    if(valid(g,f,error,n))return -1;
    Saved saved;save(&saved);GLint alignment;glGetIntegerv(GL_UNPACK_ALIGNMENT,&alignment);glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    g->submitted=1;
    for(int i=0;i<2;i++){
        glActiveTexture(GL_TEXTURE0+i);glBindTexture(GL_TEXTURE_2D,g->input[i]);
        glTexImage2D(GL_TEXTURE_2D,0,i?GL_RG8:GL_R8,f->width/(i?2:1),f->height/(i?2:1),0,i?GL_RG:GL_RED,GL_UNSIGNED_BYTE,i?uv:y);parameters();
    }
    glPixelStorei(GL_UNPACK_ALIGNMENT,alignment);int result=convert(g,f,error,n);restore(&saved);return result;
}
int fp_gpu_test_read(FpGpu *g,uint8_t *pixels,size_t n){
    if(!current(g)||!pixels||n!=(size_t)g->width*g->height*4)return -1;
    GLint before;glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&before);glBindFramebuffer(GL_READ_FRAMEBUFFER,g->framebuffer);
    glReadPixels(0,0,g->width,g->height,GL_RGBA,GL_UNSIGNED_BYTE,pixels);GLenum error=glGetError();
    glBindFramebuffer(GL_READ_FRAMEBUFFER,before);return error==GL_NO_ERROR?0:-1;
}
