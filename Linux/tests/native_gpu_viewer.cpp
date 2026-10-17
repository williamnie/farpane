// One render node, 256x128 synthetic frames, sequential encode/decode, <=12 FPS.
// The decoder and EGL renderer are the actual canonical product implementations.
#include "../src/viewer_decode.h"
#include "../gui/src/gpu_renderer.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <gbm.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/opt.h>
}
namespace {
constexpr int W=256,H=128,N=4;
using Clock=std::chrono::steady_clock;
void require(bool b,const std::string &s){if(!b)throw std::runtime_error(s);}
void check(int result,const char *name){if(result<0){char text[128];av_strerror(result,text,sizeof(text));throw std::runtime_error(std::string(name)+": "+text);}}
struct Buffer {AVBufferRef *p=nullptr;~Buffer(){av_buffer_unref(&p);}};
struct AvFrame {AVFrame *p=av_frame_alloc();~AvFrame(){av_frame_free(&p);}};
struct AvPacket {AVPacket *p=av_packet_alloc();~AvPacket(){av_packet_free(&p);}};
struct Encoder {AVCodecContext *p=nullptr;~Encoder(){avcodec_free_context(&p);}};
struct Packet {std::vector<uint8_t> data;int64_t pts;};
std::vector<Packet> encode(int fd,bool hevc) {
    Buffer drm,device,pool;drm.p=av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_DRM);require(drm.p,"DRM allocation");
    auto *hardware=static_cast<AVHWDeviceContext *>(static_cast<void *>(drm.p->data));
    auto *drm_context=static_cast<AVDRMDeviceContext *>(hardware->hwctx);
    drm_context->fd=fcntl(fd,F_DUPFD_CLOEXEC,3);require(drm_context->fd>=0,"DRM dup");
    check(av_hwdevice_ctx_init(drm.p),"DRM init");
    check(av_hwdevice_ctx_create_derived(&device.p,AV_HWDEVICE_TYPE_VAAPI,drm.p,0),"VAAPI derive");
    pool.p=av_hwframe_ctx_alloc(device.p);require(pool.p,"Encoder pool allocation");
    auto *frames=reinterpret_cast<AVHWFramesContext *>(pool.p->data);
    frames->format=AV_PIX_FMT_VAAPI;frames->sw_format=AV_PIX_FMT_NV12;frames->width=W;frames->height=H;frames->initial_pool_size=4;
    check(av_hwframe_ctx_init(pool.p),"Encoder pool init");
    const AVCodec *codec=avcodec_find_encoder_by_name(hevc?"hevc_vaapi":"h264_vaapi");require(codec,"Encoder lookup");
    Encoder encoder;encoder.p=avcodec_alloc_context3(codec);require(encoder.p,"Encoder allocation");
    auto *ctx=encoder.p;ctx->width=W;ctx->height=H;ctx->time_base={1,12};ctx->framerate={12,1};
    ctx->pix_fmt=AV_PIX_FMT_VAAPI;ctx->bit_rate=800000;ctx->gop_size=12;ctx->max_b_frames=0;ctx->thread_count=1;
    ctx->color_range=AVCOL_RANGE_MPEG;ctx->colorspace=AVCOL_SPC_BT709;ctx->color_primaries=AVCOL_PRI_BT709;ctx->color_trc=AVCOL_TRC_BT709;
    ctx->chroma_sample_location=AVCHROMA_LOC_LEFT;ctx->hw_frames_ctx=av_buffer_ref(pool.p);
    ctx->profile=hevc?AV_PROFILE_HEVC_MAIN:AV_PROFILE_H264_HIGH;
    av_opt_set(ctx->priv_data,"rc_mode","CQP",0);av_opt_set_int(ctx->priv_data,"qp",18,0);
    check(avcodec_open2(ctx,codec,nullptr),"Encoder open");
    std::vector<Packet> packets;AvPacket packet;
    auto drain=[&](){
        while(true){int result=avcodec_receive_packet(ctx,packet.p);if(result==AVERROR(EAGAIN)||result==AVERROR_EOF)return;
            check(result,"Encode receive");packets.push_back({{packet.p->data,packet.p->data+packet.p->size},packet.p->pts});av_packet_unref(packet.p);}
    };
    for(int i=0;i<N;i++){
        auto began=Clock::now();AvFrame cpu,gpu;require(cpu.p&&gpu.p,"Frame allocation");
        cpu.p->format=AV_PIX_FMT_NV12;cpu.p->width=W;cpu.p->height=H;check(av_frame_get_buffer(cpu.p,32),"CPU test surface");
        for(int y=0;y<H;y++)for(int x=0;x<W;x++)cpu.p->data[0][y*cpu.p->linesize[0]+x]=x<W/4?16:x<W/2?235:x<3*W/4?81:128;
        for(int y=0;y<H/2;y++)for(int x=0;x<W;x+=2){bool red=x>=W/2&&x<3*W/4;cpu.p->data[1][y*cpu.p->linesize[1]+x]=red?90:128;cpu.p->data[1][y*cpu.p->linesize[1]+x+1]=red?240:128;}
        check(av_hwframe_get_buffer(pool.p,gpu.p,0),"Encoder hardware surface");check(av_hwframe_transfer_data(gpu.p,cpu.p,0),"Synthetic upload");
        gpu.p->pts=i;gpu.p->color_range=ctx->color_range;gpu.p->colorspace=ctx->colorspace;gpu.p->color_primaries=ctx->color_primaries;gpu.p->color_trc=ctx->color_trc;gpu.p->chroma_location=ctx->chroma_sample_location;
        check(avcodec_send_frame(ctx,gpu.p),"Encode send");drain();std::this_thread::sleep_until(began+std::chrono::milliseconds(84));
    }
    check(avcodec_send_frame(ctx,nullptr),"Encoder flush");drain();require(packets.size()==N,"Encoder packet count");
    return packets; // Every encoder object is destroyed before decoding starts.
}
void run(int fd,bool hevc,FpGpu *renderer){
    auto packets=encode(fd,hevc);char error[1024]={};
    std::unique_ptr<FpViewerDecoder,decltype(&fp_viewer_destroy)> decoder(fp_viewer_create(fd,hevc?2:1,error,sizeof(error)),fp_viewer_destroy);
    require(bool(decoder),std::string("Native decoder: ")+error);
    int received=0,max_error=0;std::vector<uint8_t> pixels(W*H*4);
    for(auto &packet:packets){
        auto began=Clock::now();require(fp_viewer_send(decoder.get(),packet.data.data(),packet.data.size(),packet.pts)==0,fp_viewer_error(decoder.get()));
        FpViewerFrame frame{};int result=fp_viewer_receive(decoder.get(),&frame);require(result==0,fp_viewer_error(decoder.get()));
        require(frame.width==W&&frame.height==H&&frame.pts==packet.pts&&frame.pool_size==23,"Decoder dimensions/PTS/pool contract");
        require(frame.object_count>0&&frame.object_count<=4&&frame.matrix==AVCOL_SPC_BT709&&frame.range==AVCOL_RANGE_MPEG,"Export color/object contract");
        FpGpuFrame image{};image.width=W;image.height=H;image.matrix=1;image.range=0;image.chroma=frame.chroma==AVCHROMA_LOC_CENTER?1:0;
        for(int i=0;i<2;i++){
            auto &layer=frame.layers[i];require(layer.object<frame.object_count,"Object index");auto &object=frame.objects[layer.object];
            image.planes[i]={object.fd,layer.format,uint32_t(W/(i?2:1)),uint32_t(H/(i?2:1)),layer.pitch,layer.offset,object.modifier};
        }
        require(fp_gpu_submit(renderer,&image,error,sizeof(error))==0,error);
        const auto deadline=Clock::now()+std::chrono::milliseconds(450);
        do {result=fp_gpu_poll(renderer,error,sizeof(error));require(result>=0,error);if(result==1)break;
            require(Clock::now()<deadline,"GPU fence deadline");std::this_thread::sleep_for(std::chrono::milliseconds(1));}while(true);
        // ACK only after the real GPU completion. Read back only the independent
        // RGB test target, never the decoder surface, to verify actual pixels.
        require(fp_viewer_release(decoder.get(),frame.lease)==0,"Completed lease return");
        require(fp_gpu_test_read(renderer,pixels.data(),pixels.size())==0,"GPU output pixels");
        const int expected[4][3]={{0,0,0},{255,255,255},{255,24,0},{130,130,130}};
        for(int bar=0;bar<4;bar++)for(int y:{H/4,H*3/4}){
            auto *p=&pixels[(y*W+bar*(W/4)+W/8)*4];require(p[3]==255,"Opaque GPU alpha");
            for(int c=0;c<3;c++)max_error=std::max(max_error,std::abs(int(p[c])-expected[bar][c]));
        }
        require(max_error<=10,"GPU imported pixels differ from encoded color bars");
        if(received==0)printf("%s objects=%u modifier=0x%llx pool=%u color=%d/%d/%d\n",hevc?"HEVC":"H264",frame.object_count,(unsigned long long)frame.objects[0].modifier,frame.pool_size,frame.matrix,frame.range,frame.chroma);
        ++received;std::this_thread::sleep_until(began+std::chrono::milliseconds(84));
    }
    require(received==N,"Decoder output count");printf("%s frames=%d RGB_max_error=%d completed_leases=%d\n",hevc?"HEVC":"H264",received,max_error,received);
}
}
int main(){
    setvbuf(stdout,nullptr,_IOLBF,0);av_log_set_level(AV_LOG_ERROR);
    try{
        int fd=open("/dev/dri/renderD128",O_RDWR|O_CLOEXEC);require(fd>=0,"Only renderD128 may be used");
        gbm_device *gbm=gbm_create_device(fd);require(gbm,"GBM render device");
        auto get_display=reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(eglGetProcAddress("eglGetPlatformDisplayEXT"));require(get_display,"EGL GBM platform");
        EGLDisplay display=get_display(EGL_PLATFORM_GBM_KHR,gbm,nullptr);require(display!=EGL_NO_DISPLAY,"EGL render display");require(eglInitialize(display,nullptr,nullptr),"EGL init");
        require(eglBindAPI(EGL_OPENGL_ES_API),"GLES API");
        EGLint attrs[]={EGL_SURFACE_TYPE,0,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
        EGLConfig config;EGLint count;require(eglChooseConfig(display,attrs,&config,1,&count)&&count==1,"EGL config");
        EGLint context_attrs[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};EGLContext context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attrs);require(context!=EGL_NO_CONTEXT,"GLES3 context");
        require(eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,context),"Surfaceless current context");
        printf("GL=%s version=%s EGL=%s\n",glGetString(GL_RENDERER),glGetString(GL_VERSION),eglQueryString(display,EGL_VENDOR));
        const char *ext=eglQueryString(display,EGL_EXTENSIONS);
        printf("EGL dma_import=%d modifiers=%d GL image=%d\n",ext&&strstr(ext,"EGL_EXT_image_dma_buf_import")!=nullptr,ext&&strstr(ext,"EGL_EXT_image_dma_buf_import_modifiers")!=nullptr,strstr(reinterpret_cast<const char *>(glGetString(GL_EXTENSIONS)),"GL_OES_EGL_image")!=nullptr);
        auto query_formats=reinterpret_cast<PFNEGLQUERYDMABUFFORMATSEXTPROC>(eglGetProcAddress("eglQueryDmaBufFormatsEXT"));
        EGLint advertised[256],advertised_count=0;require(query_formats&&query_formats(display,256,advertised,&advertised_count),"DMA formats query");
        printf("advertised=%d R8=%d GR88=%d\n",advertised_count,std::find(advertised,advertised+advertised_count,0x20203852)!=advertised+advertised_count,std::find(advertised,advertised+advertised_count,0x38385247)!=advertised+advertised_count);
        auto query=reinterpret_cast<PFNEGLQUERYDMABUFMODIFIERSEXTPROC>(eglGetProcAddress("eglQueryDmaBufModifiersEXT"));
        if(query)for(EGLint format:{0x20203852,0x38385247}){EGLint count=0;EGLBoolean ok=query(display,format,0,nullptr,nullptr,&count);printf("format=0x%x query=%d count=%d error=0x%x\n",format,ok,count,eglGetError());}
        auto display_attribute=reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBEXTPROC>(eglGetProcAddress("eglQueryDisplayAttribEXT"));
        auto device_string=reinterpret_cast<PFNEGLQUERYDEVICESTRINGEXTPROC>(eglGetProcAddress("eglQueryDeviceStringEXT"));
        EGLAttrib device=0;if(display_attribute&&device_string&&display_attribute(display,EGL_DEVICE_EXT,&device))printf("EGL render path=%s\n",device_string(reinterpret_cast<EGLDeviceEXT>(device),EGL_DRM_RENDER_NODE_FILE_EXT));
        for(uint32_t format:{0x20203852u,0x38385247u}){auto *bo=gbm_bo_create(gbm,16,16,format,GBM_BO_USE_LINEAR|GBM_BO_USE_RENDERING);printf("GBM linear 0x%x allocated=%d modifier=0x%llx\n",format,bo!=nullptr,(unsigned long long)(bo?gbm_bo_get_modifier(bo):~0ull));if(bo)gbm_bo_destroy(bo);}
        char error[1024]={};FpGpu *renderer=fp_gpu_new(error,sizeof(error));require(renderer,error);
        FpImportFormat formats[128];auto n=fp_gpu_formats(renderer,formats,128);require(n>0,"No DMA-BUF plane formats");
        printf("ffmpeg=%s GL=%s import_formats=%zu\n",av_version_info(),glGetString(GL_RENDERER),n);
        run(fd,false,renderer);run(fd,true,renderer);
        fp_gpu_destroy(renderer);eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroyContext(display,context);eglTerminate(display);gbm_device_destroy(gbm);close(fd);
        puts("PASS canonical VAAPI decode -> DRM_PRIME -> EGL R8/GR88 -> color shader -> GLsync -> lease return");return 0;
    }catch(const std::exception &e){fprintf(stderr,"FAIL %s\n",e.what());return 1;}
}
