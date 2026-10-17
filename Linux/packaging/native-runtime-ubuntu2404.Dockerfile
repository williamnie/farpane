FROM ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
# Runtime-only ABI test: no Rust, FFmpeg, GTK headers or original RustDesk.
# All display/session services are private to the test container.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 binutils dbus-x11 xvfb xauth x11-utils \
    libgtk-4-1 libadwaita-1-0 libegl1 libgles2 libgbm1 libgl1-mesa-dri libglx-mesa0 \
    libpulse0 libxtst6 libxcb-shm0 libxcb-randr0 libva2 libva-drm2 libdrm2 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libdbus-1-3 libsecret-1-0 \
    fonts-noto-cjk \
    && dpkg-query -W > /farpane-native-runtime-packages.txt \
    && rm -rf /var/lib/apt/lists/*
