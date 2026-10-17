FROM sha256:c84f2a454d08709fbd1734860296a1c85fc3a9a7e2c8f86be79c1b1bf321a2c1
# Test-only private PulseAudio daemon/null sinks. No host sound devices or sockets.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends pulseaudio pulseaudio-utils \
    && dpkg-query -W > /farpane-native-audio-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
