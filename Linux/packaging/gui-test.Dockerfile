FROM sha256:17d91d2b9bc68621d5c8ab51aeb7e7cf7589d96ae5f1caddc0c7598f4bf01841
# Test display lives inside the container. No host display or GPU is mounted.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb x11-utils x11-apps \
    && dpkg-query -W > /gui-test-packages.txt \
    && rm -rf /var/lib/apt/lists/*
