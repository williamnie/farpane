#!/usr/bin/env python3
"""三秒独立编码/解码验证；码流只经过管道，不保存桌面画面。"""
import fcntl
import json
import os
import pathlib
import re
import signal
import subprocess

root = pathlib.Path(__file__).resolve().parent
lock = (root/'probe.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
encode = ['ffmpeg','-hide_banner','-nostdin','-loglevel','verbose','-filter_threads','1',
          '-f','kmsgrab','-device','/dev/dri/card1','-plane_id','42','-framerate','30','-i','-',
          '-vf','hwmap=derive_device=vaapi:mode=read+direct,scale_vaapi=format=nv12',
          '-c:v','h264_vaapi','-profile:v','main','-rc_mode','CBR','-b:v','4000k','-maxrate','4000k',
          '-bufsize','4000k','-g','60','-bf','0','-async_depth','1','-enc_time_base:v','-1',
          '-fps_mode','passthrough','-frames:v','90','-an','-f','h264','pipe:1']
decode = ['ffmpeg','-hide_banner','-nostdin','-loglevel','verbose','-threads','1',
          '-f','h264','-i','pipe:0','-filter_threads','1',
          '-vf','signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-',
          '-f','null','/dev/null']
children=[]
with (root/'decode-encoder.log').open('x') as elog, (root/'decode-decoder.log').open('x') as dlog:
    try:
        enc=subprocess.Popen(encode,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=elog,start_new_session=True)
        children.append(enc)
        dec=subprocess.Popen(decode,stdin=enc.stdout,stdout=subprocess.PIPE,stderr=dlog,start_new_session=True,text=True)
        children.append(dec)
        enc.stdout.close()
        metrics,_=dec.communicate(timeout=15)
        enc.wait(timeout=3)
    finally:
        for child in children:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGKILL)
                child.wait()
    values=[float(x) for x in re.findall(r'lavfi.signalstats.YAVG=([0-9.]+)',metrics)]
    summary={'encoded_frames_requested':90,'decoded_frame_metrics':len(values),
             'encoder_exit':enc.returncode,'decoder_exit':dec.returncode,
             'mean_luma_min':min(values) if values else None,'mean_luma_max':max(values) if values else None,
             'encoded_content_saved':False,'encode_command':encode,'decode_command':decode}
    (root/'decode-validation.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary))
    assert enc.returncode == dec.returncode == 0 and len(values) == 90
