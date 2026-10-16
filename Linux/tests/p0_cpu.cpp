// Exercise the existing hwcodec CPU-upload path against the same static FFmpeg.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <libyuv.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/log.h>
#include "ffmpeg_ram_ffi.h"
#include "mux_ffi.h"
}
#include "common.h"
constexpr int W=256,H=128,N=24;
#ifndef EXPECTED_FFMPEG
#define EXPECTED_FFMPEG "9.0.2"
#endif
void require(bool value,const char *what) { if(!value) throw std::runtime_error(what); }
extern "C" void hwcodec_log(int level,const char *msg) { if(level<=1) fprintf(stderr,"%s\n",msg); }
extern "C" void hwcodec_av_log_callback(int,const char *msg) { fprintf(stderr,"%s",msg); }
struct Packet { std::vector<uint8_t> bytes; int64_t pts; int key; };
void encoded(const uint8_t *data,int len,int64_t pts,int key,const void *opaque) {
    auto &packets=*static_cast<std::vector<Packet>*>(const_cast<void*>(opaque));
    packets.push_back({std::vector<uint8_t>(data,data+len),pts,key});
}
struct Decoded { int frames=0,keys=0,max_error=0; bool valid=true; };
void decoded(const void *opaque,int w,int h,int format,int stride[8],uint8_t *data[8],int key) {
    auto &out=*static_cast<Decoded*>(const_cast<void*>(opaque));
    ++out.frames; out.keys+=key!=0;
    if(w!=W || h!=H || (format!=AV_PIX_FMT_YUV420P && format!=AV_PIX_FMT_NV12)) { out.valid=false; return; }
    for(int y : {32,96}) for(int x : {32,96,160,224}) {
        int expected=x<128?16:235;
        out.max_error=std::max(out.max_error,abs(int(data[0][y*stride[0]+x])-expected));
    }
}
using CodecPtr=std::unique_ptr<void,void(*)(void*)>;
void run_codec(bool hevc,bool short_gop) {
    const char *name=hevc?"hevc_vaapi":"h264_vaapi";
    const char *decoder_name=hevc?"hevc":"h264";
    std::vector<uint8_t> bgra(W*H*4,255);
    for(int y=0;y<H;++y) for(int x=0;x<128;++x) for(int c=0;c<3;++c) bgra[(y*W+x)*4+c]=0;
    int strides[8]={},offsets[8]={},length=0;
    CodecPtr encoder(ffmpeg_ram_new_encoder(name,"",W,H,AV_PIX_FMT_NV12,64,12,short_gop?12:MAX_GOP,RC_CBR,Quality_Default,800,-1,1,-1,strides,offsets,&length,encoded),ffmpeg_ram_free_encoder);
    require(bool(encoder),"CPU upload encoder init");
    CodecPtr software(ffmpeg_ram_new_decoder(decoder_name,AV_HWDEVICE_TYPE_NONE,1,decoded),ffmpeg_ram_free_decoder);
    require(bool(software),"existing software decoder init");
    std::vector<uint8_t> yuv(length,0);
    require(libyuv::ARGBToNV12(bgra.data(),W*4,yuv.data(),strides[0],yuv.data()+offsets[0],strides[1],W,H)==0,"CPU libyuv conversion");
    std::vector<Packet> packets;
    Decoded sw;
    std::string filename=std::string("/tmp/p0-")+decoder_name+".mp4";
    CodecPtr mux(hwcodec_new_muxer(filename.c_str(),W,H,hevc,12),hwcodec_free_muxer);
    require(bool(mux),"existing recorder init");
    int count=0,keys=0;
    std::vector<Packet> all;
    for(int i=0;i<N;++i) {
        auto start=std::chrono::steady_clock::now(); packets.clear();
        require(ffmpeg_ram_encode(encoder.get(),yuv.data(),length,&packets,i*1000/12)==0,"existing encoder frame");
        require(packets.size()==1,"existing low-delay encoder packet count");
        for(auto &pkt:packets) {
            ++count; keys+=pkt.key!=0;
            require(pkt.pts==i*1000/12,"encoder PTS");
            require(ffmpeg_ram_decode(software.get(),pkt.bytes.data(),pkt.bytes.size(),&sw)==0,"existing software decode");
            require(hwcodec_write_video_frame(mux.get(),pkt.bytes.data(),pkt.bytes.size(),pkt.pts,pkt.key)==0,"existing recorder write");
            all.push_back(pkt);
        }
        std::this_thread::sleep_until(start+std::chrono::milliseconds(84));
    }
    require(hwcodec_write_tail(mux.get())==0,"recorder trailer"); mux.reset(); encoder.reset(); software.reset();
    // Sequential hardware decode, after encoder teardown: only one GPU stream.
    CodecPtr hardware(ffmpeg_ram_new_decoder(decoder_name,AV_HWDEVICE_TYPE_VAAPI,1,decoded),ffmpeg_ram_free_decoder);
    require(bool(hardware),"existing VAAPI decoder init");
    Decoded hw;
    for(auto &pkt:all) {
        auto start=std::chrono::steady_clock::now();
        require(ffmpeg_ram_decode(hardware.get(),pkt.bytes.data(),pkt.bytes.size(),&hw)==0,"existing VAAPI decode");
        std::this_thread::sleep_until(start+std::chrono::milliseconds(84));
    }
    std::ifstream file(filename,std::ios::binary); std::string bytes((std::istreambuf_iterator<char>(file)),{});
    require(bytes.size()>1000 && bytes.find("ftyp")!=std::string::npos && bytes.find("moov")!=std::string::npos && bytes.find(hevc?"hvcC":"avcC")!=std::string::npos,"recording MP4 boxes");
    printf("%s packets=%d keys=%d software=%d/%d error=%d hardware=%d/%d error=%d mp4_bytes=%zu\n",name,count,keys,sw.frames,sw.keys,sw.max_error,hw.frames,hw.keys,hw.max_error,bytes.size());
    require(count==N && keys==1 && sw.frames==N && sw.keys==(short_gop?2:1) && hw.frames==N && hw.keys==sw.keys,"frame or key flag regression");
    require(sw.valid && hw.valid && sw.max_error<=10 && hw.max_error<=10,"CPU path format/color regression");
}
int main(int argc,char **argv) {
    setvbuf(stdout,nullptr,_IOLBF,0); av_log_set_level(AV_LOG_ERROR);
    try {
        require(std::string(av_version_info())==EXPECTED_FFMPEG,"FFmpeg version");
        bool short_gop=argc==2 && std::string(argv[1])=="--short-gop";
        require(argc==1 || short_gop,"usage: p0-cpu [--short-gop]");
        printf("ffmpeg=%s gop=%s\n",av_version_info(),short_gop?"12 (non-IDR intra)":"product default");
        run_codec(false,short_gop); run_codec(true,short_gop);
        puts("PASS existing hwcodec CPU upload, software/VAAPI decode, key flags, PTS and MP4 smoke"); return 0;
    } catch(const std::exception &e) { fprintf(stderr,"FAIL %s\n",e.what()); return 1; }
}
