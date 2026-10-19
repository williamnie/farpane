"""Run the Rust focus-selection integration test on an owned Xvfb only."""
import os
from pathlib import Path
import subprocess
import sys
import time


def exercise(binary, output):
    assert Path('/.dockerenv').is_file() and os.geteuid()!=0
    assert not any(os.environ.get(k) for k in ('DISPLAY','WAYLAND_DISPLAY','XAUTHORITY'))
    assert not any(Path(p).exists() for p in ('/dev/uinput','/dev/dri'))
    assert binary.is_relative_to('/workspace/Build/Linux/target') and binary.is_file()
    env=dict(os.environ,DISPLAY=':93',HOME='/tmp/farpane-selector-home',
             FARPANE_PRIVATE_PASTE_TARGET_TEST='1')
    Path(env['HOME']).mkdir(mode=0o700)
    with (output/'xvfb.log').open('w') as log:
        server=subprocess.Popen(['Xvfb',':93','-screen','0','640x480x24','-nolisten','tcp','-ac'],stdout=log,stderr=subprocess.STDOUT)
        try:
            for _ in range(40):
                assert server.poll() is None
                if Path('/tmp/.X11-unix/X93').is_socket():break
                time.sleep(.05)
            assert Path('/tmp/.X11-unix/X93').is_socket()
            subprocess.run([str(binary),'farpane_native::paste_target::tests::private_x11_focus_and_application_boundary',
                '--exact','--ignored','--nocapture'],env=env,timeout=15,check=True)
        finally:
            server.terminate();server.wait(timeout=5)


if __name__=='__main__':exercise(Path(sys.argv[1]),Path(sys.argv[2]))
