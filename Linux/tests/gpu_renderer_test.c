/* Software GLES probe, isolated from all host GPU/display sockets. */
#include "../gui/src/gpu_renderer.h"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define CHECK(x) do { if(!(x)){fprintf(stderr,"line %d: %s (%s)\n",__LINE__,#x,error);exit(1);} } while(0)
static char error[1024];
static void complete(FpGpu *gpu){
    for(int i=0;i<1000;i++){
        int result=fp_gpu_poll(gpu,error,sizeof(error));CHECK(result>=0);if(result==1)return;
        struct timespec delay={0,1000000};nanosleep(&delay,NULL);
    }CHECK(0);
}
static void pixel(const unsigned char *p,int r,int g,int b){
    CHECK(abs((int)p[0]-r)<=2);CHECK(abs((int)p[1]-g)<=2);CHECK(abs((int)p[2]-b)<=2);CHECK(p[3]==255);
}
int main(void){
    EGLDisplay display=eglGetDisplay(EGL_DEFAULT_DISPLAY);CHECK(display!=EGL_NO_DISPLAY);
    CHECK(eglInitialize(display,NULL,NULL));CHECK(eglBindAPI(EGL_OPENGL_ES_API));
    EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config;EGLint count;CHECK(eglChooseConfig(display,attrs,&config,1,&count)&&count==1);
    EGLint surface_attrs[]={EGL_WIDTH,8,EGL_HEIGHT,8,EGL_NONE};
    EGLSurface surface=eglCreatePbufferSurface(display,config,surface_attrs);CHECK(surface!=EGL_NO_SURFACE);
    EGLint context_attrs[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attrs);CHECK(context!=EGL_NO_CONTEXT);
    CHECK(eglMakeCurrent(display,surface,surface,context));
    FpGpu *gpu=fp_gpu_new(error,sizeof(error));CHECK(gpu);
    /* This test must never accidentally turn into a hardware run. */
    const char *renderer=(const char *)glGetString(GL_RENDERER);
    CHECK(renderer&&(strstr(renderer,"llvmpipe")||strstr(renderer,"softpipe")));
    printf("renderer: %s\n",renderer);
    unsigned char y[16],uv[8],pixels[64];FpGpuFrame frame={.width=4,.height=4,.chroma=1};
    /* Independent saturated red vectors distinguish BT.601/709 and range. */
    const int samples[][8]={
        {0,0,81,90,240,254,0,0},{1,0,81,90,240,255,24,0},
        {0,1,76,85,255,254,0,0},{1,1,76,85,255,255,25,0},
        {0,0,16,128,128,0,0,0},{1,0,235,128,128,255,255,255},
        {0,1,0,128,128,0,0,0},{1,1,255,128,128,255,255,255}
    };
    for(size_t i=0;i<sizeof(samples)/sizeof(samples[0]);i++){
        const int *s=samples[i];frame.matrix=s[0];frame.range=s[1];memset(y,s[2],sizeof(y));
        for(int k=0;k<8;k+=2){uv[k]=s[3];uv[k+1]=s[4];}
        CHECK(fp_gpu_test_upload(gpu,&frame,y,uv,error,sizeof(error))==0);
        CHECK(fp_gpu_test_upload(gpu,&frame,y,uv,error,sizeof(error))<0); /* Uncompleted lease cannot be reused. */
        complete(gpu);CHECK(fp_gpu_test_read(gpu,pixels,sizeof(pixels))==0);
        for(int k=0;k<16;k++)pixel(pixels+k*4,s[5],s[6],s[7]);
    }
    /* Distinct chroma columns exercise interpolation and left/center siting. */
    frame.matrix=1;frame.range=1;memset(y,128,sizeof(y));
    for(int k=0;k<8;k+=4){uv[k]=64;uv[k+1]=128;uv[k+2]=192;uv[k+3]=128;}
    frame.chroma=1;CHECK(fp_gpu_test_upload(gpu,&frame,y,uv,error,sizeof(error))==0);complete(gpu);
    CHECK(fp_gpu_test_read(gpu,pixels,sizeof(pixels))==0);int centered_blue=pixels[6];
    frame.chroma=0;CHECK(fp_gpu_test_upload(gpu,&frame,y,uv,error,sizeof(error))==0);complete(gpu);
    CHECK(fp_gpu_test_read(gpu,pixels,sizeof(pixels))==0);CHECK(pixels[6]>centered_blue+30);
    /* Conversion buffer stores source rows; the display pass flips GL's origin. */
    memset(uv,128,sizeof(uv));for(int i=0;i<16;i++)y[i]=i<8?32:224;
    CHECK(fp_gpu_test_upload(gpu,&frame,y,uv,error,sizeof(error))==0);complete(gpu);
    CHECK(fp_gpu_draw(gpu,8,8,error,sizeof(error))==0);
    unsigned char display_pixels[256];glReadPixels(0,0,8,8,GL_RGBA,GL_UNSIGNED_BYTE,display_pixels);CHECK(glGetError()==GL_NO_ERROR);
    pixel(display_pixels,224,224,224);pixel(display_pixels+7*8*4,32,32,32);
    /* Wrong-current-context queries cannot acknowledge a fence. */
    CHECK(eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT));CHECK(fp_gpu_poll(gpu,error,sizeof(error))<0);
    CHECK(eglMakeCurrent(display,surface,surface,context));fp_gpu_destroy(gpu);
    CHECK(eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT));
    eglDestroyContext(display,context);eglDestroySurface(display,surface);eglTerminate(display);
    puts("PASS: BT.601/709 limited/full, chroma siting, orientation, bounded in-flight lease, current-context fence");
    return 0;
}
