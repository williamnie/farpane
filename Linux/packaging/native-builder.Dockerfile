FROM sha256:17d91d2b9bc68621d5c8ab51aeb7e7cf7589d96ae5f1caddc0c7598f4bf01841
# Extend the existing isolated toolchain; FFmpeg and Rust caches stay unchanged.
# This is the hermes build image. The minimum-distro ABI gate is separate.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-4-dev libadwaita-1-dev libegl1-mesa-dev libgles2-mesa-dev \
    xvfb x11-utils dbus-x11 libgl1-mesa-dri librsvg2-bin \
    && dpkg-query -W > /farpane-native-builder-packages.txt \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fonts-noto-cjk \
    && dpkg-query -W > /farpane-native-builder-packages.txt \
    && rm -rf /var/lib/apt/lists/*
