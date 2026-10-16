#!/usr/bin/env python3
"""Numerical audit of the current shader; NOT a macOS VideoToolbox runtime test."""
import json
from pathlib import Path
import re
import sys
root=Path(__file__).resolve().parents[2]
shader=(root/'Sources/VideoPipeline/MetalVideoRenderer.swift').read_text()
for constant in ('1.16438356','1.79274107','0.21324861','0.53290933','2.11240179'):
    if constant not in shader:
        raise SystemExit('Renderer changed; audit the shader before recalculating')
rows=[]
for match in re.finditer(r'COLOR rgb=(\d+),(\d+),(\d+) yuv=(\d+),(\d+),(\d+)',Path(sys.argv[1]).read_text()):
    r,g,b,y,u,v=map(int,match.groups())
    yy=1.16438356*(y-16)
    cb=u-127.5;cr=v-127.5
    displayed=[round(max(0,min(255,n))) for n in (yy+1.79274107*cr,yy-0.21324861*cb-0.53290933*cr,yy+2.11240179*cb)]
    rows.append({'source_rgb':[r,g,b],'measured_gpu_yuv':[y,u,v],'shader_prediction_rgb':displayed,
                 'max_channel_error':max(abs(a-b) for a,b in zip((r,g,b),displayed))})
if len(rows)!=8: raise SystemExit('Expected all eight measured color bars')
print(json.dumps({'result':'OPEN: native Mac rendering validation required',
                  'method':'Current Metal coefficients applied to measured NV12; assumes VT retains source matrix',
                  'not_measured':'VideoToolbox output attachments or native rendered pixels',
                  'rows':rows},indent=2))
