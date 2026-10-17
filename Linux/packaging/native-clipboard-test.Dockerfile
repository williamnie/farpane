FROM sha256:9868299c8b775ccd60773a4fd06ea2a0f1da90deb01d0119e997501c4d776a91
# Test-only headless compositor. No host display, input, DRM, audio or bus mount.
# Runtime tests use WLR_BACKENDS=headless / WLR_RENDERER=pixman.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    sway wl-clipboard \
    && dpkg-query -W > /farpane-native-clipboard-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
