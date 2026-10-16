#!/usr/bin/env python3
"""仅监听回环地址的可重复远程画面负载。"""
import json
import argparse
import pathlib
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"mode": "static", "generation": 0, "ack": -1, "visible": False, "focused": False, "heartbeat": 0, "viewport": None, "animation_frames": 0}
LOCK = threading.Lock()
NATIVE = None
HTML = r'''<!doctype html><meta charset="utf-8"><title>FarPane Host A/B fixture</title>
<style>
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#152234;color:white;font:28px sans-serif}
header{height:140px;padding:24px 50px;background:#0b1420;position:relative;z-index:2}h1{font-size:36px;margin:0 0 12px}small{font-size:20px;color:#b7c9dd}
#bars{height:90px;display:flex}#bars i{flex:1}main{height:calc(100vh - 230px);position:relative;overflow:hidden}
#static{padding:50px;font-size:38px;line-height:1.8}#scroll{display:none;position:absolute;inset:0;padding:30px 60px}
#scroll article{animation:scroll 20s linear infinite;line-height:56px;white-space:pre}
#motion{display:none;position:absolute;inset:0;background:repeating-conic-gradient(#192b43 0% 25%,#264462 0% 50%) 0/80px 80px}
.tile{position:absolute;width:19vw;height:22vh;border:5px solid white;background:#ffbe3d;animation:move 8s linear infinite alternate}
.tile:nth-child(2){background:#49d7c2;animation-delay:-2s;top:23%;left:20%}.tile:nth-child(3){background:#ec6e85;animation-delay:-4s;top:48%;left:40%}
.tile:nth-child(4){background:#8c9eff;animation-delay:-6s;top:10%;left:55%}
@keyframes scroll{from{transform:translateY(0)}to{transform:translateY(-1120px)}}
@keyframes move{from{transform:translate(0,0) rotate(0)}to{transform:translate(24vw,8vh) rotate(180deg)}}
body[data-mode=scroll] #scroll,body[data-mode=motion] #motion{display:block}body:not([data-mode=static]) #static{display:none}
</style>
<body data-mode="static"><header><h1>FarPane / RustDesk Host A/B</h1><small id="label">Static · 2560 × 1440 · H.264 · 30 FPS target</small></header>
<div id="bars"><i style="background:white"></i><i style="background:#ff0"></i><i style="background:#0ff"></i><i style="background:#0f0"></i><i style="background:#f0f"></i><i style="background:red"></i><i style="background:blue"></i><i style="background:black"></i></div>
<main><div id="static">Static desktop / 静态画面<br>0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ<br>Fine text, sharp edges, solid colors.<br>缓冲区复用测试：文字、颜色、边缘保持一致。</div>
<div id="scroll"><article id="text"></article></div><div id="motion"><div class="tile"></div><div class="tile"></div><div class="tile"></div><div class="tile"></div></div></main>
<script>
document.querySelector('#text').textContent=Array.from({length:90},(_,i)=>`${String(i%20+1).padStart(2,'0')}  Remote desktop · 0123456789 · RustDesk / FarPane · 滚动文字测试`).join('\n');
let generation=-1,animationFrames=0,animationRunning=false;
function animate(){animationRunning=false;if(document.body.dataset.mode!=='static'){animationFrames++;animationRunning=true;requestAnimationFrame(animate)}}
async function tick(){try{let s=await(await fetch('/state',{cache:'no-store'})).json();
if(generation!==s.generation){generation=s.generation;document.body.dataset.mode=s.mode;animationFrames=0;if(!animationRunning&&s.mode!=='static'){animationRunning=true;requestAnimationFrame(animate)}
document.querySelector('#label').textContent=s.mode+' · 2560 × 1440 · H.264 · 30 FPS target';
for(let a of document.getAnimations())a.currentTime=0;}
await fetch('/ack',{method:'POST',body:JSON.stringify({generation,visible:!document.hidden,focused:document.hasFocus(),animationFrames,viewport:{width:innerWidth,height:innerHeight,dpr:devicePixelRatio}})});
}catch(e){}setTimeout(tick,500)}tick();
</script></body>'''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, body, content_type="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/state":
            with LOCK:
                self.reply(json.dumps(STATE).encode())
        else:
            self.reply(HTML.encode(), "text/html")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if not 0 < length <= 256:
            self.send_error(400)
            return
        data = json.loads(self.rfile.read(length))
        with LOCK:
            if self.path == "/mode" and data.get("mode") in ("static", "scroll", "motion"):
                STATE.update(mode=data["mode"], generation=STATE["generation"] + 1)
                if NATIVE is not None:
                    NATIVE.stdin.write(f"MODE {STATE['mode']} {STATE['generation']}\n")
                    NATIVE.stdin.flush()
            elif self.path == "/ack" and NATIVE is None:
                STATE.update(ack=data.get("generation"), visible=data.get("visible") is True,
                             focused=data.get('focused') is True, animation_frames=data.get('animationFrames', 0),
                             heartbeat=time.monotonic(), viewport=data.get('viewport'))
            else:
                self.send_error(400)
                return
            self.reply(json.dumps(STATE).encode())


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', action='store_true')
    args = parser.parse_args()
    if args.native:
        NATIVE = subprocess.Popen([str(pathlib.Path(__file__).with_name('rd-perf-fixture'))],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        STATE['backend'] = 'native-gl'
        def native_updates():
            for line in NATIVE.stdout:
                data = json.loads(line)
                with LOCK:
                    STATE.update(ack=data['generation'], visible=data['visible'], focused=data['focused'],
                                 animation_frames=data['animationFrames'], viewport=data['viewport'], heartbeat=time.monotonic())
        threading.Thread(target=native_updates, daemon=True).start()
    def stop_signal(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop_signal)
    print("Fixture http://127.0.0.1:47651", flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", 47651), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if NATIVE is not None:
            NATIVE.stdin.close()
            try:
                NATIVE.wait(timeout=3)
            except subprocess.TimeoutExpired:
                NATIVE.terminate()
                NATIVE.wait(timeout=3)
