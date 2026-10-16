// Sidecar only: synthetic render-node buffers, never KMS, IPC, or a desktop.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>
#include <amdgpu.h>
#include <amdgpu_drm.h>
#include <drm_fourcc.h>
#include <libyuv.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersrc.h>
#include <libavfilter/buffersink.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
}

constexpr int W = 256, H = 128, N = 60;
constexpr int PRE_TOL = 3, DECODE_TOL = 10;
using Clock = std::chrono::steady_clock;
void require(bool ok, const char *msg) { if (!ok) throw std::runtime_error(msg); }
void check(int ret, const char *msg) {
    if (ret >= 0) return;
    char err[AV_ERROR_MAX_STRING_SIZE]; av_strerror(ret, err, sizeof(err));
    throw std::runtime_error(std::string(msg) + ": " + err);
}
struct FrameDelete { void operator()(AVFrame *p) const { av_frame_free(&p); } };
using Frame = std::unique_ptr<AVFrame, FrameDelete>;
Frame frame() { Frame p(av_frame_alloc()); require(bool(p), "av_frame_alloc"); return p; }
int fd_count() {
    DIR *d = opendir("/proc/self/fd"); require(d, "opendir fd");
    int count = 0; while (auto *e = readdir(d)) if (e->d_name[0] != '.') ++count;
    closedir(d); return count;
}
void memory_sample(int index) {
    std::ifstream rollup("/proc/self/smaps_rollup");
    std::string line; long pss=0,priv=0;
    while(std::getline(rollup,line)) {
        std::istringstream row(line); std::string key; long kb;
        if(!(row>>key>>kb)) continue;
        if(key=="Pss:") pss=kb;
        if(key=="Private_Clean:" || key=="Private_Dirty:") priv+=kb;
    }
    require(pss>0,"PSS unavailable");
    printf("MEMORY frame=%d pss_kb=%ld private_kb=%ld fd=%d\n",index,pss,priv,fd_count());
    // Report per-client values rather than adding aliases of the same DRM fd.
    std::set<std::string> clients;
    for(int fd=0;fd<64;++fd) {
        std::ifstream info("/proc/self/fdinfo/"+std::to_string(fd));
        std::string id; std::vector<std::string> memory;
        while(std::getline(info,line)) {
            if(line.rfind("drm-client-id:",0)==0) id=line;
            if(line.rfind("drm-memory-",0)==0) memory.push_back(line);
        }
        if(!id.empty() && clients.insert(id).second) {
            printf("GPU_MEMORY frame=%d %s",index,id.c_str());
            for(auto &entry:memory) printf(" %s",entry.c_str());
            putchar('\n');
        }
    }
}
struct Source {
    int fd = -1;
    amdgpu_device_handle dev = nullptr;
    amdgpu_bo_handle bo = nullptr;
    int export_fd = -1;
    uint32_t stride = W * 4;
    std::vector<uint8_t> bgra = std::vector<uint8_t>(W * H * 4);
    std::vector<uint8_t> nv12 = std::vector<uint8_t>(W * H * 3 / 2);
    Source(bool varying_alpha=false) {
      try {
        fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC); require(fd >= 0, "render open");
        uint32_t major,minor;
        check(amdgpu_device_initialize(fd,&major,&minor,&dev),"amdgpu initialize");
        amdgpu_bo_alloc_request req{};
        req.alloc_size=stride*H; req.phys_alignment=4096;
        req.preferred_heap=AMDGPU_GEM_DOMAIN_GTT; req.flags=AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED;
        check(amdgpu_bo_alloc(dev,&req,&bo),"linear GTT allocation");
        amdgpu_bo_info info{}; check(amdgpu_bo_query_info(bo,&info),"buffer info");
        require(info.metadata.tiling_info==0 && info.metadata.size_metadata==0,"unexpected tiling metadata");
        uint32_t handle;
        check(amdgpu_bo_export(bo,amdgpu_bo_handle_type_dma_buf_fd,&handle),"export DMA-BUF");
        export_fd=static_cast<int>(handle);
        printf("source_modifier=0 planes=1 amdgpu=%u.%u stride=%u allocation=%llu\n",major,minor,stride,(unsigned long long)info.alloc_size);
        const uint8_t rgb[8][3] = {{0,0,0},{255,255,255},{255,0,0},{0,255,0},{0,0,255},{255,255,0},{0,255,255},{255,0,255}};
        for (int y=0; y<H; ++y) for (int x=0; x<W; ++x) {
            auto *p = &bgra[(y*W+x)*4]; int bar = x/32;
            if (y < 64) { p[0]=rgb[bar][2]; p[1]=rgb[bar][1]; p[2]=rgb[bar][0]; }
            else { p[0]=p[1]=p[2]=uint8_t(bar*255/7); }
            // Fine strokes in a separate strip; flat patches remain unambiguous.
            if (y >= 112) p[0]=p[1]=p[2]= ((x%8==0 || y%8==0) ? 255 : 0);
            p[3]=varying_alpha?uint8_t((bar%4)*85):255;
        }
        dma_buf_sync sync{DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
        require(ioctl(export_fd,DMA_BUF_IOCTL_SYNC,&sync)==0,"CPU write begin");
        void *mapped=nullptr;
        check(amdgpu_bo_cpu_map(bo,&mapped),"map synthetic source");
        auto *p=static_cast<uint8_t*>(mapped);
        for (int y=0; y<H; ++y) memcpy(p+y*stride, bgra.data()+y*W*4, W*4);
        check(amdgpu_bo_cpu_unmap(bo),"unmap synthetic source");
        sync.flags=DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
        require(ioctl(export_fd,DMA_BUF_IOCTL_SYNC,&sync)==0,"CPU write end");
        check(libyuv::ARGBToNV12(bgra.data(),W*4,nv12.data(),W,nv12.data()+W*H,W,W,H),"libyuv BT601");
      } catch(...) { cleanup(); throw; }
    }
    void stamp(int index) {
        dma_buf_sync sync{DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
        require(ioctl(export_fd,DMA_BUF_IOCTL_SYNC,&sync)==0,"stamp begin");
        void *mapped=nullptr; check(amdgpu_bo_cpu_map(bo,&mapped),"stamp map");
        for(int y=64;y<80;++y) for(int x=0;x<W;++x) {
            auto *p=static_cast<uint8_t*>(mapped)+y*stride+x*4;
            p[0]=p[1]=p[2]=((index>>(x/32))&1)?255:0; p[3]=255;
        }
        check(amdgpu_bo_cpu_unmap(bo),"stamp unmap");
        sync.flags=DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
        require(ioctl(export_fd,DMA_BUF_IOCTL_SYNC,&sync)==0,"stamp end");
    }
    ~Source() { cleanup(); }
    void cleanup() { if(export_fd>=0) close(export_fd); if(bo) amdgpu_bo_free(bo); if(dev) amdgpu_device_deinitialize(dev); if(fd>=0) close(fd); }
};
bool valid_descriptor(const AVDRMFrameDescriptor &d,int width,int height) {
    if(width<=0 || height<=0 || width>8192 || height>8192 || (width|height)&1 ||
       d.nb_objects!=1 || d.nb_layers!=1) return false;
    const auto &object=d.objects[0]; const auto &layer=d.layers[0]; const auto &plane=layer.planes[0];
    if(object.fd<0 || object.format_modifier!=0 || layer.nb_planes!=1 ||
       (layer.format!=DRM_FORMAT_XRGB8888 && layer.format!=DRM_FORMAT_ARGB8888) ||
       plane.object_index!=0 || plane.offset<0 || plane.pitch<width*4 ||
       object.size==0 || object.size>256ULL*1024*1024) return false;
    // Check before multiplication and against the kernel's exported object size.
    uint64_t offset=plane.offset,pitch=plane.pitch;
    if(offset>object.size || pitch>(object.size-offset)/height) return false;
    off_t size=lseek(object.fd,0,SEEK_END);
    return size>0 && object.size<=static_cast<uint64_t>(size);
}
void invalid_descriptor_tests(const AVDRMFrameDescriptor &valid) {
    require(valid_descriptor(valid,W,H),"valid descriptor rejected");
    require(!valid_descriptor(valid,0,H) && !valid_descriptor(valid,8194,H) && !valid_descriptor(valid,W-1,H),"invalid dimensions accepted");
    auto d=valid; d.nb_objects=2; require(!valid_descriptor(d,W,H),"multiple objects accepted");
    d=valid; d.nb_layers=0; require(!valid_descriptor(d,W,H),"missing layer accepted");
    d=valid; d.layers[0].nb_planes=2; require(!valid_descriptor(d,W,H),"multiple planes accepted");
    d=valid; d.objects[0].format_modifier=1; require(!valid_descriptor(d,W,H),"tiled modifier accepted");
    d=valid; d.layers[0].format=DRM_FORMAT_NV12; require(!valid_descriptor(d,W,H),"unqualified format accepted");
    d=valid; d.layers[0].planes[0].pitch=PTRDIFF_MAX; require(!valid_descriptor(d,W,H),"pitch overflow accepted");
    d=valid; d.layers[0].planes[0].offset=-1; require(!valid_descriptor(d,W,H),"negative offset accepted");
    d=valid; d.layers[0].planes[0].pitch=W*4-1; require(!valid_descriptor(d,W,H),"short stride accepted");
    d=valid; d.objects[0].size=1; require(!valid_descriptor(d,W,H),"short object accepted");
    d=valid; d.objects[0].size*=2; require(!valid_descriptor(d,W,H),"falsified object size accepted");
    d=valid; d.objects[0].fd=-1; require(!valid_descriptor(d,W,H),"missing FD accepted");
    d=valid; d.layers[0].planes[0].object_index=1; require(!valid_descriptor(d,W,H),"wrong object index accepted");
}
struct LeaseCounts { int created=0, released=0, peak=0; };
struct Lease { AVDRMFrameDescriptor desc{}; LeaseCounts *counts; };
void free_lease(void *opaque, uint8_t *) {
    auto *p=static_cast<Lease*>(opaque);
    close(p->desc.objects[0].fd); ++p->counts->released; delete p;
}
Frame import_frame(Source &source, AVBufferRef *frames, LeaseCounts &counts, int64_t pts, bool alpha=false) {
    auto p=frame(); auto lease=std::make_unique<Lease>();
    lease->counts=&counts;
    auto &d=lease->desc;
    d.nb_objects=d.nb_layers=1;
    d.objects[0].fd=fcntl(source.export_fd,F_DUPFD_CLOEXEC,0); require(d.objects[0].fd>=0,"export fd");
    d.objects[0].size=source.stride*H; d.objects[0].format_modifier=0;
    d.layers[0].format=alpha?DRM_FORMAT_ARGB8888:DRM_FORMAT_XRGB8888; d.layers[0].nb_planes=1;
    d.layers[0].planes[0].pitch=source.stride;
    p->buf[0]=av_buffer_create(reinterpret_cast<uint8_t*>(&d),sizeof(d),free_lease,lease.get(),0);
    if(!p->buf[0]) { close(d.objects[0].fd); throw std::runtime_error("lease allocation"); }
    lease.release(); ++counts.created; counts.peak=std::max(counts.peak,counts.created-counts.released);
    p->data[0]=p->buf[0]->data; p->hw_frames_ctx=av_buffer_ref(frames); require(p->hw_frames_ctx,"frame context ref");
    p->format=AV_PIX_FMT_DRM_PRIME; p->width=W; p->height=H; p->pts=pts;
    p->colorspace=AVCOL_SPC_RGB; p->color_range=AVCOL_RANGE_JPEG;
    p->color_primaries=AVCOL_PRI_SMPTE170M; p->color_trc=AVCOL_TRC_SMPTE170M;
    require(valid_descriptor(*reinterpret_cast<AVDRMFrameDescriptor*>(p->data[0]),W,H),"invalid source descriptor");
    return p;
}
bool completed(AVFrame *p, std::chrono::milliseconds budget, bool &observed_busy);
struct Pipeline {
    AVBufferRef *device=nullptr,*input_frames=nullptr;
    AVFilterGraph *graph=nullptr; AVFilterContext *src=nullptr,*sink=nullptr;
    AVCodecContext *encoder=nullptr,*decoder=nullptr;
    std::set<unsigned> surfaces;
    Frame pending_input, pending_output;
    bool submitted=false;
    int pool_size;
    Pipeline(int pool=4, bool alpha=false) : pool_size(pool) {
      try {
        check(av_hwdevice_ctx_create(&device,AV_HWDEVICE_TYPE_DRM,"/dev/dri/renderD128",nullptr,0),"drm device");
        input_frames=av_hwframe_ctx_alloc(device); require(input_frames,"drm frames");
        auto *fc=reinterpret_cast<AVHWFramesContext*>(input_frames->data);
        fc->format=AV_PIX_FMT_DRM_PRIME; fc->sw_format=alpha?AV_PIX_FMT_BGRA:AV_PIX_FMT_BGR0; fc->width=W; fc->height=H;
        check(av_hwframe_ctx_init(input_frames),"drm frames init");
        graph=avfilter_graph_alloc(); require(graph,"graph alloc"); graph->nb_threads=1;
        AVFilterContext *map=nullptr,*scale=nullptr;
        std::string args="video_size="+std::to_string(W)+"x"+std::to_string(H)+":pix_fmt="+std::to_string(AV_PIX_FMT_DRM_PRIME)+":time_base=1/1000:pixel_aspect=1/1";
        src=avfilter_graph_alloc_filter(graph,avfilter_get_by_name("buffer"),"source"); require(src,"buffer alloc");
        auto *par=av_buffersrc_parameters_alloc(); require(par,"source parameters");
        par->hw_frames_ctx=av_buffer_ref(input_frames);
        par->color_space=AVCOL_SPC_RGB; par->color_range=AVCOL_RANGE_JPEG;
        int ret=av_buffersrc_parameters_set(src,par); av_buffer_unref(&par->hw_frames_ctx); av_free(par); check(ret,"source frames");
        check(avfilter_init_str(src,args.c_str()),"buffer init");
        check(avfilter_graph_create_filter(&map,avfilter_get_by_name("hwmap"),"direct","derive_device=vaapi:mode=read+direct",nullptr,graph),"hwmap");
        std::string scale_args="pool_size="+std::to_string(pool_size)+":format=nv12:out_color_matrix=smpte170m:out_range=limited:out_color_primaries=smpte170m:out_color_transfer=smpte170m:out_chroma_location=left";
        check(avfilter_graph_create_filter(&scale,avfilter_get_by_name("scale_vaapi"),"nv12",scale_args.c_str(),nullptr,graph),"scale");
        check(avfilter_graph_create_filter(&sink,avfilter_get_by_name("buffersink"),"sink",nullptr,nullptr,graph),"sink");
        check(avfilter_link(src,0,map,0),"source link"); check(avfilter_link(map,0,scale,0),"map link"); check(avfilter_link(scale,0,sink,0),"scale link");
        check(avfilter_graph_config(graph,nullptr),"graph config");
        auto *output_fc=reinterpret_cast<AVHWFramesContext*>(av_buffersink_get_hw_frames_ctx(sink)->data);
        require(output_fc->initial_pool_size==pool_size,"fixed pool not applied");
        require(static_cast<AVVAAPIFramesContext*>(output_fc->hwctx)->nb_surfaces==pool_size,"fixed surfaces not allocated");
        auto *codec=avcodec_find_encoder_by_name("h264_vaapi"); require(codec,"h264_vaapi");
        encoder=avcodec_alloc_context3(codec); require(encoder,"encoder alloc");
        encoder->width=W; encoder->height=H; encoder->pix_fmt=AV_PIX_FMT_VAAPI;
        encoder->time_base={1,1000}; encoder->framerate={12,1}; encoder->max_b_frames=0; encoder->gop_size=30;
        encoder->profile=AV_PROFILE_H264_HIGH; encoder->thread_count=1;
        encoder->color_range=AVCOL_RANGE_MPEG; encoder->colorspace=AVCOL_SPC_SMPTE170M;
        encoder->color_primaries=AVCOL_PRI_SMPTE170M; encoder->color_trc=AVCOL_TRC_SMPTE170M;
        encoder->chroma_sample_location=AVCHROMA_LOC_LEFT;
        encoder->hw_frames_ctx=av_buffer_ref(av_buffersink_get_hw_frames_ctx(sink)); require(encoder->hw_frames_ctx,"output frames ref");
        check(av_opt_set(encoder->priv_data,"rc_mode","CQP",0),"CQP");
        check(av_opt_set_int(encoder->priv_data,"qp",18,0),"QP");
        check(av_opt_set_int(encoder->priv_data,"async_depth",1,0),"async depth");
        check(avcodec_open2(encoder,codec,nullptr),"encoder open");
        codec=avcodec_find_decoder(AV_CODEC_ID_H264); require(codec,"H264 decoder");
        decoder=avcodec_alloc_context3(codec); require(decoder,"decoder alloc"); decoder->thread_count=1;
        check(avcodec_open2(decoder,codec,nullptr),"decoder open");
      } catch(...) { cleanup(); throw; }
    }
    void submit(Frame input) {
        require(!pending_input && !pending_output,"backpressure: pending frame");
        pending_input=std::move(input); pending_output=frame(); submitted=true;
        check(av_buffersrc_add_frame_flags(src,pending_input.get(),AV_BUFFERSRC_FLAG_KEEP_REF),"source submit");
        check(av_buffersink_get_frame(sink,pending_output.get()),"VPP output");
        require(pending_output->format==AV_PIX_FMT_VAAPI,"CPU fallback detected");
        surfaces.insert(unsigned(uintptr_t(pending_output->data[3])));
        require(surfaces.size()<=static_cast<size_t>(pool_size),"surface growth");
    }
    bool finish_source(std::chrono::milliseconds budget,bool &busy) {
        require(submitted && pending_input && pending_output,"no pending work");
        if(!completed(pending_output.get(),budget,busy)) return false;
        pending_input.reset(); submitted=false;
        return true;
    }
    ~Pipeline() {
        if(submitted && pending_input) {
            try {
                bool busy=false;
                if(!pending_output || pending_output->format!=AV_PIX_FMT_VAAPI || !finish_source(std::chrono::milliseconds(100),busy))
                    throw std::runtime_error("completion unavailable");
            } catch(...) {
                // Never acknowledge or destruct a source whose GPU reader may
                // still be active. This test process is disposable; product
                // integration needs a retained owner, not process termination.
                fprintf(stderr,"unresolved GPU work retained until process teardown\n"); std::_Exit(3);
            }
        }
        pending_output.reset(); cleanup();
    }
    void cleanup() {
        avcodec_free_context(&decoder); avcodec_free_context(&encoder);
        avfilter_graph_free(&graph); av_buffer_unref(&input_frames); av_buffer_unref(&device);
    }
};
VADisplay display(AVFrame *p) {
    auto *f=reinterpret_cast<AVHWFramesContext*>(p->hw_frames_ctx->data);
    return static_cast<AVVAAPIDeviceContext*>(f->device_ctx->hwctx)->display;
}
int driver_timeouts=0;
double tiny_wait_max_ms=0;
bool completed(AVFrame *p, std::chrono::milliseconds budget, bool &observed_busy) {
    if(budget.count()<=0) return false;
    auto end=Clock::now()+budget; VADisplay d=display(p); auto id=VASurfaceID(uintptr_t(p->data[3]));
    VASurfaceStatus state; VAStatus ret=vaQuerySurfaceStatus(d,id,&state);
    require(ret==VA_STATUS_SUCCESS,"surface status"); observed_busy |= state!=VASurfaceReady;
    if(state!=VASurfaceReady) {
        auto start=Clock::now();
        ret=vaSyncSurface2(d,id,1);
        tiny_wait_max_ms=std::max(tiny_wait_max_ms,std::chrono::duration<double,std::milli>(Clock::now()-start).count());
        driver_timeouts+=ret==VA_STATUS_ERROR_TIMEDOUT;
        if(ret==VA_STATUS_SUCCESS) return true;
        require(ret==VA_STATUS_ERROR_TIMEDOUT || ret==VA_STATUS_ERROR_UNIMPLEMENTED,"tiny sync failed");
    }
    do {
        ret=vaSyncSurface2(d,id,1000000); // At most 1 ms per call, total deadline below.
        if(ret==VA_STATUS_SUCCESS) return true;
        if(ret!=VA_STATUS_ERROR_TIMEDOUT && ret!=VA_STATUS_ERROR_UNIMPLEMENTED) throw std::runtime_error(vaErrorStr(ret));
        if(ret==VA_STATUS_ERROR_UNIMPLEMENTED) {
            require(vaQuerySurfaceStatus(d,id,&state)==VA_STATUS_SUCCESS,"surface query fallback");
            if(state==VASurfaceReady) return true;
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    } while(Clock::now()<end);
    return false;
}
int flat_error(AVFrame *p,const Source &s) {
    require(p->format==AV_PIX_FMT_NV12 || p->format==AV_PIX_FMT_YUV420P,"unexpected readback format");
    int peak=0;
    for(int y : {32,88}) for(int x=16;x<W;x+=32) {
        int ey=s.nv12[y*W+x],eu=s.nv12[W*H+y/2*W+x],ev=s.nv12[W*H+y/2*W+x+1];
        int ay=p->data[0][y*p->linesize[0]+x];
        int au=p->data[1][y/2*p->linesize[1]+(p->format==AV_PIX_FMT_NV12?x:x/2)];
        int av=p->format==AV_PIX_FMT_NV12?p->data[1][y/2*p->linesize[1]+x+1]:p->data[2][y/2*p->linesize[2]+x/2];
        peak=std::max({peak,abs(ey-ay),abs(eu-au),abs(ev-av)});
    }
    return peak;
}
void lifecycle() {
    int baseline=fd_count(); LeaseCounts counts;
    for(int generation=0;generation<8;++generation) {
        {
            Source source;
            try {
                Pipeline p;
                // Two received leases; superseded but unsubmitted frames can
                // release immediately. No actual IPC is used by this harness.
                auto latest=import_frame(source,p.input_frames,counts,0);
                if(generation==0) invalid_descriptor_tests(*reinterpret_cast<AVDRMFrameDescriptor*>(latest->data[0]));
                auto replacement=import_frame(source,p.input_frames,counts,1);
                require(counts.created-counts.released==2,"two-credit fixture");
                latest=std::move(replacement); latest.reset();
                require(counts.created==counts.released,"unsubmitted release");
                auto *pool=av_buffersink_get_hw_frames_ctx(p.sink);
                std::vector<Frame> held;
                for(int i=0;i<p.pool_size;++i) { auto f=frame(); check(av_hwframe_get_buffer(pool,f.get(),0),"pool slot"); held.push_back(std::move(f)); }
                auto extra=frame(); require(av_hwframe_get_buffer(pool,extra.get(),0)==AVERROR(ENOMEM),"pool grew beyond cap");
                held.clear();
                p.submit(import_frame(source,p.input_frames,counts,generation));
                bool busy=false;
                require(!p.finish_source(std::chrono::milliseconds(0),busy),"injected deadline must fail");
                require(counts.created-counts.released==1 && fcntl(reinterpret_cast<AVDRMFrameDescriptor*>(p.pending_input->data[0])->objects[0].fd,F_GETFD)>=0,"timeout prematurely released lease");
                // Unwind after submission exercises completion before cleanup.
                throw std::runtime_error("injected post-submit failure");
            } catch(const std::runtime_error &e) {
                require(std::string(e.what())=="injected post-submit failure","unexpected lifecycle error");
            }
            require(counts.created==counts.released,"failed generation did not drain");
        }
        require(fd_count()==baseline,"generation FD leak");
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    printf("PASS lifecycle invalid_descriptors=rejected generations=8 leases=%d/%d peak=%d pool_cap=4 rejected_extra=8 injected_deadlines=8 cleanup_after_submit=8 fd=%d/%d\n",counts.created,counts.released,counts.peak,baseline,fd_count());
}
int main(int argc,char **argv) {
    setvbuf(stdout,nullptr,_IOLBF,0); av_log_set_level(AV_LOG_WARNING);
    try {
        require(std::string(av_version_info())=="9.0.2","wrong FFmpeg");
        if(argc==2 && std::string(argv[1])=="--lifecycle") { lifecycle(); return 0; }
        bool steady=argc==2 && std::string(argv[1])=="--steady";
        int frames=steady?720:N;
        bool alpha=argc==2 && std::string(argv[1])=="--argb";
        int pool=argc==2 && std::string(argv[1])=="--pool-one"?1:4;
        require(argc==1 || alpha || pool==1 || steady,"usage: p0-media [--lifecycle|--argb|--pool-one|--steady]");
        printf("ffmpeg=%s uid=%d size=%dx%d fps=12 frames=%d pre_tol=%d decoded_tol=%d\n",av_version_info(),getuid(),W,H,frames,PRE_TOL,DECODE_TOL);
        int fd_before=fd_count(), max_pre=0,max_dec=0,decoded=0,packets=0,keyframes=0;
        double min_psnr=1000; LeaseCounts leases; std::vector<double> sync_ms; bool observed_busy=false;
        {
            Source s(alpha); Pipeline p(pool,alpha); int steady_fds=0,peak_fds=0;
            auto decode=[&](AVPacket *packet) {
                check(avcodec_send_packet(p.decoder,packet),"decode send");
                auto deadline=Clock::now()+std::chrono::milliseconds(100);
                for(int count=0;;++count) { require(count<3 && Clock::now()<deadline,"decoder drain limit"); auto out=frame(); int ret=avcodec_receive_frame(p.decoder,out.get()); if(ret==AVERROR(EAGAIN)||ret==AVERROR_EOF) break; check(ret,"decode receive");
                    require(out->width==W && out->height==H,"decode dimensions");
                    require(out->colorspace==AVCOL_SPC_SMPTE170M && out->color_range==AVCOL_RANGE_MPEG && out->color_primaries==AVCOL_PRI_SMPTE170M && out->color_trc==AVCOL_TRC_SMPTE170M && out->chroma_location==AVCHROMA_LOC_LEFT,"SPS VUI mismatch");
                    for(int x=16;x<W;x+=32) {
                        int expected=((decoded>>(x/32))&1)?235:16;
                        require(abs(int(out->data[0][72*out->linesize[0]+x])-expected)<=DECODE_TOL,"mixed frame or stale sequence");
                    }
                    max_dec=std::max(max_dec,flat_error(out.get(),s));
                    double mse=0; for(int y=112;y<H;++y) for(int x=0;x<W;++x) { double e=int(out->data[0][y*out->linesize[0]+x])-int(s.nv12[y*W+x]); mse+=e*e; }
                    mse/=W*16; min_psnr=std::min(min_psnr,mse==0?100.0:10*log10(255.0*255/mse)); ++decoded;
                }
            };
            auto receive=[&] {
                AVPacket *pkt=av_packet_alloc(); require(pkt,"packet alloc");
                for(int count=0;;++count) {
                    int ret=avcodec_receive_packet(p.encoder,pkt); if(ret==AVERROR(EAGAIN)||ret==AVERROR_EOF) break;
                    check(ret,"encode receive"); require(count<2,"unbounded packet queue"); ++packets; keyframes+=(pkt->flags&AV_PKT_FLAG_KEY)!=0;
                    decode(pkt); av_packet_unref(pkt);
                }
                av_packet_free(&pkt);
            };
            for(int i=0;i<frames;++i) {
                auto start=Clock::now(); s.stamp(i);
                p.submit(import_frame(s,p.input_frames,leases,i*1000/12,alpha));
                require(leases.created-leases.released==1,"source released before completion");
                auto wait_start=Clock::now();
                if(!p.finish_source(std::chrono::milliseconds(100),observed_busy)) {
                    // A timeout is not completion. Retain the frame and lease; this
                    // standalone process exits without an ACK or unsafe destructor.
                    fprintf(stderr,"completion timeout: retaining source until process teardown\n"); std::_Exit(3);
                }
                sync_ms.push_back(std::chrono::duration<double,std::milli>(Clock::now()-wait_start).count());
                require(leases.created==leases.released,"credit not released exactly once");
                if(i==0) {
                    auto pixels=frame(); check(av_hwframe_transfer_data(pixels.get(),p.pending_output.get(),0),"cold color readback");
                    max_pre=flat_error(pixels.get(),s);
                    for(int x=16;x<W;x+=32) {
                        const auto *rgb=&s.bgra[(32*W+x)*4];
                        printf("COLOR rgb=%u,%u,%u yuv=%u,%u,%u\n",rgb[2],rgb[1],rgb[0],
                               pixels->data[0][32*pixels->linesize[0]+x],
                               pixels->data[1][16*pixels->linesize[1]+x],
                               pixels->data[1][16*pixels->linesize[1]+x+1]);
                    }
                }
                check(avcodec_send_frame(p.encoder,p.pending_output.get()),"encoder send"); p.pending_output.reset(); receive();
                int fds=fd_count(); peak_fds=std::max(peak_fds,fds); if(i==10) steady_fds=fds;
                if(i>10) require(fds<=steady_fds+1,"FD growth");
                if(steady && (i+1)%60==0) memory_sample(i+1);
                std::this_thread::sleep_until(start+std::chrono::milliseconds(84));
            }
            check(avcodec_send_frame(p.encoder,nullptr),"encode drain"); receive(); decode(nullptr);
            printf("format=%s pool_cap=%d surfaces_used=%zu fd_steady=%d fd_peak=%d\n",alpha?"AR24":"XR24",pool,p.surfaces.size(),steady_fds,peak_fds);
        }
        std::sort(sync_ms.begin(),sync_ms.end());
        printf("pre_max=%d decoded_max=%d fine_luma_psnr_min=%.2f packets=%d decoded=%d keyframes=%d leases=%d/%d peak=%d busy_observed=%d sync_p95_ms=%.3f fd_before=%d fd_after=%d\n",max_pre,max_dec,min_psnr,packets,decoded,keyframes,leases.created,leases.released,leases.peak,observed_busy,sync_ms[sync_ms.size()*95/100],fd_before,fd_count());
        require(max_pre<=PRE_TOL,"pre-encode color threshold"); require(max_dec<=DECODE_TOL,"decoded color threshold");
        require(min_psnr>=35,"fine stroke PSNR threshold"); require(decoded==frames && packets==frames && keyframes>=2,"frame/keyframe count");
        require(leases.created==leases.released && leases.peak<=2,"lease budget"); require(fd_count()==fd_before,"FD leak after teardown");
        printf("driver_timeouts=%d tiny_wait_max_ms=%.3f\n",driver_timeouts,tiny_wait_max_ms);
        puts("PASS synthetic GPU graph; real desktop tearing, GPU-hang recovery and end-to-end latency remain unverified");
        return 0;
    } catch(const std::exception &e) { fprintf(stderr,"FAIL %s\n",e.what()); return 1; }
}
