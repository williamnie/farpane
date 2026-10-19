FROM ubuntu@sha256:da6fc2be547864451aa253836dd926da33623312df4a9a243e35dc877c378a78
# Private guest/runner dependencies only. No host display, input or service
# device/socket is ever mounted; /dev/uinput exists only in the guest kernel.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3 python3-gi gir1.2-gtk-4.0 gir1.2-vte-2.91 \
    mutter gnome-shell dbus-x11 udev util-linux kmod e2fsprogs \
    qemu-system-x86 qemu-utils xvfb xauth x11-utils \
    libgtk-4-1 libadwaita-1-0 libsecret-1-0 \
    libegl1 libgles2 libgbm1 libgl1-mesa-dri libglx-mesa0 \
    libpulse0 libxtst6 libxcb-shm0 libxcb-randr0 libva2 libva-drm2 libdrm2 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libdbus-1-3 fonts-noto-cjk \
    && dpkg-query -W > /farpane-input-vm-packages.txt \
    && rm -rf /var/lib/apt/lists/*
# ScreenCast and Xwayland are recommended rather than hard dependencies of
# Mutter; install explicitly for the product's real clipboard/capture path.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    xwayland pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-gnome \
    && dpkg-query -W > /farpane-input-vm-packages.txt \
    && rm -rf /var/lib/apt/lists/*
