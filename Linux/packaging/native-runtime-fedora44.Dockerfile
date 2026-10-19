FROM registry.fedoraproject.org/fedora@sha256:4a78eff1423dcce55cf68b8fd66e7cdca61c85978283db3ecc3089a8419fbbc0
# Runtime-only compatibility fixture. No Rust, application compiler, host
# display, GPU/input devices, system service or original RustDesk installation.
RUN dnf install -y --setopt=install_weak_deps=False --setopt=max_parallel_downloads=4 \
    python3 binutils util-linux dbus-daemon xorg-x11-server-Xvfb xorg-x11-xauth xmessage xwininfo \
    gtk4 libadwaita mesa-libEGL libglvnd-gles mesa-libgbm mesa-dri-drivers mesa-libGL \
    pulseaudio-libs libXtst libxcb libva libdrm libxkbcommon \
    gstreamer1 gstreamer1-plugins-base dbus-libs libsecret google-noto-sans-cjk-fonts \
    && rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /farpane-native-runtime-packages.txt \
    && dnf clean all
