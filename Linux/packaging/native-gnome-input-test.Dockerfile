FROM sha256:e107f6ec93417a8d8e71ed60889972e236d94101e79de8fd2a026de8378460c1
# Private headless GNOME for Unicode-input regression. Never a host dependency.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gnome-shell python3-gi gir1.2-gtk-4.0 \
    && dpkg-query -W > /farpane-native-gnome-input-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends mutter \
    && dpkg-query -W > /farpane-native-gnome-input-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
