FROM debian@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
# Runtime-only compatibility fixture. No compiler, RustDesk installation,
# host display, GPU device or service socket is needed by these tests.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 binutils util-linux dbus-x11 xvfb xauth x11-utils \
    libgtk-4-1 libadwaita-1-0 libegl1 libgles2 libgbm1 libgl1-mesa-dri libglx-mesa0 \
    libpulse0 libxtst6 libxcb-shm0 libxcb-randr0 libva2 libva-drm2 libdrm2 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libdbus-1-3 libsecret-1-0 \
    fonts-noto-cjk \
    && dpkg-query -W > /farpane-native-runtime-packages.txt \
    && rm -rf /var/lib/apt/lists/*
