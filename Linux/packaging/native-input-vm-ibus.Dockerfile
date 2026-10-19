# Same pinned private input VM image plus IBus, which GNOME Shell starts on
# real desktops (linux-host: ibus-daemon --panel disable, ibus-engine-simple).
# GNOME Shell then routes focused text-input key events through IBus, and
# GTK3/GTK4 clients (linux-host Chrome 155 loads GTK4 im-ibus.so) filter keys in IBus.
FROM farpane-native-input-vm:20261018@sha256:675620953da21b80eb9d9ff13968ecc96eb6408c12f643ef2d50a8e3edc5ee51
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ibus ibus-gtk3 ibus-gtk4 \
    && dpkg-query -W > /farpane-input-vm-packages.txt \
    && rm -rf /var/lib/apt/lists/*
