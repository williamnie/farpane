FROM ubuntu@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
# Public minimum-distro build environment. No hermes image, installed media
# archives, Rust credentials or application state are inherited. Package
# versions are recorded; apt repositories are not a bit-reproducible snapshot.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build nasm pkg-config git ca-certificates curl \
    zip unzip tar python3 perl autoconf automake libtool bison patchelf \
    clang libclang-dev libgtk-4-dev libadwaita-1-dev libsecret-1-dev \
    libegl1-mesa-dev libgles2-mesa-dev libgbm-dev libdrm-dev libva-dev \
    libpulse-dev libasound2-dev libudev-dev libdbus-1-dev \
    libx11-dev libxcb-shm0-dev libxcb-randr0-dev libxtst-dev libxfixes-dev \
    libxrandr-dev libxi-dev libxinerama-dev libxcursor-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    libssl-dev zlib1g-dev libzstd-dev libclang-rt-dev \
    xvfb xauth x11-utils dbus-x11 libgl1-mesa-dri fonts-noto-cjk \
    && dpkg-query -W > /farpane-native-source-builder-packages.txt \
    && rm -rf /var/lib/apt/lists/*
