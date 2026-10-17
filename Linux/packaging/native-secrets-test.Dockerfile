FROM sha256:9868299c8b775ccd60773a4fd06ea2a0f1da90deb01d0119e997501c4d776a91
# A private Secret Service for tests; never mount the user's bus or keyring.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gnome-keyring python3-gi dbus-x11 \
    && dpkg-query -W > /farpane-native-secrets-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
